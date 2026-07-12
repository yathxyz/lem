{
  description = "lem-yath: yanni's Lem editor configuration";

  inputs = {
    lem.url = "github:lem-project/lem";
    nixpkgs.follows = "lem/nixpkgs";
    yasnippet-snippets = {
      url = "github:AndreaCrotti/yasnippet-snippets/606ee926df6839243098de6d71332a697518cb86";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      lem,
      yasnippet-snippets,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" ];
      forAllSystems = lib.genAttrs systems;
      perSystem =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lemPatchedSrc = pkgs.applyPatches {
            name = "lem-yath-lem-source";
            src = lem.outPath;
            patches = [
              ./patches/lem-completion-lifecycle.patch
              ./patches/lem-transient-delay-race.patch
              ./patches/lem-transient-bottom-restore.patch
              ./patches/lem-project-lsp-workspaces.patch
              ./patches/lem-lsp-pipe-stdio.patch
              ./patches/lem-safe-revert.patch
              ./patches/lem-prompt-history-limit.patch
              ./patches/lem-undo-tree.patch
              ./patches/lem-vi-screen-line.patch
              ./patches/lem-git-worktree.patch
              ./patches/lem-hidden-lines.patch
            ];
          };
          lemNcurses = lem.packages.${system}.lem-ncurses.overrideLispAttrs (
            old:
            let
              jsonrpc = lib.findFirst (
                dependency: (dependency.pname or null) == "jsonrpc"
              ) (throw "Lem no longer exposes its JSON-RPC dependency") old.lispLibs;
              patchedJsonrpc = jsonrpc.overrideLispAttrs (_: {
                src = pkgs.applyPatches {
                  name = "lem-yath-jsonrpc-source";
                  src = jsonrpc.src;
                  patches = [ ./patches/jsonrpc-timeout-cleanup.patch ];
                };
              });
            in
            {
              src = lemPatchedSrc;
              lispLibs = map (
                dependency: if (dependency.pname or null) == "jsonrpc" then patchedJsonrpc else dependency
              ) old.lispLibs;
            }
          );
          lemLspTest = lemNcurses.overrideLispAttrs (
            old:
            let
              script = builtins.readFile old.buildScript;
              marker = ";; Dump Image";
            in
            {
              systems = old.systems ++ [ "lem-lisp-mode/v2" ];
              buildScript =
                assert lib.assertMsg (lib.hasInfix marker script)
                  "Lem build script no longer contains its dump marker";
                pkgs.writeText "build-lem-lsp-test.lisp" (
                  builtins.replaceStrings
                    [ marker ]
                    [
                      ''
                        (map nil #'asdf:register-immutable-system
                             (asdf:already-loaded-systems))

                        ;; Dump Image
                      ''
                    ]
                    script
                );
            }
          );

          coreRuntimeInputs =
            with pkgs;
            [
              bash
              black
              clang-tools
              coreutils
              curl
              diffutils
              editorconfig-core-c
              fd
              findutils
              gitMinimal
              go
              gnugrep
              gnused
              nixfmt-rfc-style
              ripgrep
              rustfmt
              which
            ]
            ++ lib.optionals pkgs.stdenv.isLinux [ xdg-utils ];

          lspRuntimeInputs = with pkgs; [
            gopls
            harper
            nixd
            pyright
            rust-analyzer
            terraform-ls
          ];

          rustRuntimeInputs = with pkgs; [
            cargo
            clippy
            rustc
          ];

          vcsRuntimeInputs = with pkgs; [ jujutsu ];

          defaultRuntimeInputs =
            coreRuntimeInputs ++ lspRuntimeInputs ++ rustRuntimeInputs ++ vcsRuntimeInputs;

          extendedRuntimeInputs =
            with pkgs;
            defaultRuntimeInputs
            ++ [
              isync
              notmuch
              postgresql
            ];

          testInputs =
            with pkgs;
            [
              bash
              python3
              tmux
            ]
            ++ coreRuntimeInputs;

          mkApp = program: description: {
            type = "app";
            inherit program;
            meta.description = description;
          };

          lemInit = pkgs.writeTextDir "init.lisp" ''
            (require :sb-posix)
            (let ((restore (uiop:getenv "LEM_YATH_WRAPPER_LEM_HOME_SET"))
                  (original (uiop:getenv "LEM_YATH_WRAPPER_LEM_HOME_VALUE")))
              (if restore
                  (setf (uiop:getenv "LEM_HOME") original)
                  (uiop:symbol-call :sb-posix :unsetenv "LEM_HOME"))
              (uiop:symbol-call :sb-posix :unsetenv "LEM_YATH_WRAPPER_LEM_HOME_SET")
              (uiop:symbol-call :sb-posix :unsetenv "LEM_YATH_WRAPPER_LEM_HOME_VALUE"))
            (load #P"${self}/lem-yath/init.lisp")
          '';

          lemYath = pkgs.writeShellApplication {
            name = "lem";
            runtimeInputs = defaultRuntimeInputs;
            text = ''
              cache_home="''${XDG_CACHE_HOME:-''${HOME:-/tmp}/.cache}"
              source_key="$(printf '%s' '${self}/lem-yath' | sha256sum | cut -c1-16)"
              asdf_cache="$cache_home/lem-yath/asdf/$source_key"
              mkdir -p "$asdf_cache"

              export ASDF_OUTPUT_TRANSLATIONS="${self}/lem-yath:$asdf_cache:/nix/store:/nix/store''${ASDF_OUTPUT_TRANSLATIONS:+:$ASDF_OUTPUT_TRANSLATIONS}"
              export LEM_YATH_SNIPPET_DIRS="${self}/lem-yath/snippets:${yasnippet-snippets}/snippets"

              # Lem loads its init file before command-line filenames, but
              # evaluates --eval after them.  Use a temporary init root for
              # configuration while restoring the caller's normal LEM_HOME
              # before the configuration itself is loaded.
              if [[ -v LEM_HOME ]]; then
                export LEM_YATH_WRAPPER_LEM_HOME_SET=1
                export LEM_YATH_WRAPPER_LEM_HOME_VALUE="$LEM_HOME"
              else
                unset LEM_YATH_WRAPPER_LEM_HOME_SET
                unset LEM_YATH_WRAPPER_LEM_HOME_VALUE
              fi
              export LEM_HOME=${lemInit}/

              # Lem stores only the final --eval argument.  Fold caller forms
              # in command-line order without changing their normal timing.
              caller_form=
              have_eval=0
              lem_args=()
              while (( "$#" )); do
                case "$1" in
                  -e|--eval)
                    if (( "$#" < 2 )); then
                      echo "lem: $1 requires a Common Lisp form" >&2
                      exit 2
                    fi
                    if (( have_eval )); then
                      caller_form="(progn $caller_form $2)"
                    else
                      caller_form=$2
                      have_eval=1
                    fi
                    shift 2
                    ;;
                  -q|--without-init-file)
                    # This is the configured wrapper, so its immutable init
                    # file is mandatory even if callers pass upstream's -q.
                    shift
                    ;;
                  *)
                    lem_args+=("$1")
                    shift
                    ;;
                esac
              done

              if (( have_eval )); then
                lem_args+=(--eval "$caller_form")
              fi

              exec ${lemNcurses}/bin/lem "''${lem_args[@]}"
            '';
          };

          realLspEnvironment = ''
            export LEM_YATH_REAL_LSP_RUST_ANALYZER=${lib.getExe pkgs.rust-analyzer}
            export LEM_YATH_REAL_LSP_PYRIGHT=${lib.getExe' pkgs.pyright "pyright-langserver"}
            export LEM_YATH_REAL_LSP_HARPER=${lib.getExe pkgs.harper}
            export LEM_YATH_REAL_LSP_NIXD=${lib.getExe pkgs.nixd}
            export LEM_YATH_REAL_LSP_NIXPKGS_SOURCE=${nixpkgs}
            export LEM_YATH_REAL_LSP_GOPLS=${lib.getExe pkgs.gopls}
            export LEM_YATH_REAL_LSP_TERRAFORM_LS=${lib.getExe pkgs.terraform-ls}
            export LEM_YATH_REAL_LSP_CARGO=${lib.getExe pkgs.cargo}
            export LEM_YATH_REAL_LSP_RUSTC=${lib.getExe' pkgs.rustc "rustc"}
            export LEM_YATH_REAL_LSP_CARGO_CLIPPY=${lib.getExe' pkgs.clippy "cargo-clippy"}
            export NIX_PATH=nixpkgs=${nixpkgs}
          '';

          mkTestAppWithLemAndInputs =
            lemPackage: extraInputs: name: script:
            let
              runner = pkgs.writeShellApplication {
                inherit name;
                runtimeInputs = [ lemPackage ] ++ testInputs ++ extraInputs;
                text = ''
                  export TERM=''${TERM:-xterm-256color}
                  export LEM_BIN=${lemPackage}/bin/lem
                  export LEM_YATH_LEM_SOURCE=${lemPatchedSrc}
                  export LEM_YATH_SOURCE=${self}/lem-yath
                  export LEM_YATH_SNIPPET_DIRS="${self}/lem-yath/snippets:${yasnippet-snippets}/snippets"
                  exec bash ${self}/scripts/${script} "$@"
                '';
              };
            in
            mkApp "${runner}/bin/${name}" "Run ${script} with flake-pinned Lem";

          mkTestAppWithLem = lemPackage: mkTestAppWithLemAndInputs lemPackage [ ];

          mkTestApp = mkTestAppWithLem lemNcurses;

          mkRealLspTestApp =
            name: script:
            let
              runner = pkgs.writeShellApplication {
                inherit name;
                runtimeInputs = [ lemYath ] ++ testInputs;
                text = ''
                  export TERM=''${TERM:-xterm-256color}
                  export LEM_BIN=${lemYath}/bin/lem
                  export LEM_YATH_LEM_SOURCE=${lemPatchedSrc}
                  export LEM_YATH_SOURCE=${self}/lem-yath
                  export LEM_YATH_SNIPPET_DIRS="${self}/lem-yath/snippets:${yasnippet-snippets}/snippets"
                  ${realLspEnvironment}
                  exec bash ${self}/scripts/${script} "$@"
                '';
              };
            in
            mkApp "${runner}/bin/${name}" "Run ${script} against the installed Lem package";

          mkCheckWithLemAndInputs =
            lemPackage: extraInputs: name: script:
            pkgs.runCommand "lem-yath-${name}-check"
              {
                nativeBuildInputs = [ lemPackage ] ++ testInputs ++ extraInputs;
              }
              ''
                export TERM=xterm-256color
                export HOME=$TMPDIR/home
                export XDG_CACHE_HOME=$TMPDIR/cache
                export LEM_BIN=${lemPackage}/bin/lem
                export LEM_YATH_CHECK_ID=nix-${name}
                export LEM_YATH_LEM_SOURCE=${lemPatchedSrc}
                export LEM_YATH_SNIPPET_DIRS="$PWD/source/lem-yath/snippets:${yasnippet-snippets}/snippets"

                mkdir -p "$HOME" "$XDG_CACHE_HOME"
                cp -R ${self} source
                chmod -R u+w source
                cd source

                bash ./scripts/${script}
                touch "$out"
              '';

          mkCheckWithLem = lemPackage: mkCheckWithLemAndInputs lemPackage [ ];

          mkCheck = mkCheckWithLem lemNcurses;

          mkRealLspCheck =
            name: script:
            pkgs.runCommand "lem-yath-${name}-check"
              {
                nativeBuildInputs = [ lemYath ] ++ testInputs;
              }
              ''
                export TERM=xterm-256color
                export HOME=$TMPDIR/home
                export XDG_CACHE_HOME=$TMPDIR/cache
                export LEM_BIN=${lemYath}/bin/lem
                export LEM_YATH_CHECK_ID=nix-${name}
                export LEM_YATH_LEM_SOURCE=${lemPatchedSrc}
                export LEM_YATH_SOURCE=${self}/lem-yath
                export LEM_YATH_SNIPPET_DIRS="$PWD/source/lem-yath/snippets:${yasnippet-snippets}/snippets"
                ${realLspEnvironment}

                mkdir -p "$HOME" "$XDG_CACHE_HOME"
                cp -R ${self} source
                chmod -R u+w source
                cd source

                bash ./scripts/${script}
                touch "$out"
              '';
        in
        rec {
          packages = {
            default = lemYath;
            lem-yath = lemYath;
            lem-ncurses = lemNcurses;
          };

          apps = {
            default = mkApp "${lemYath}/bin/lem" "Run yanni's configured Lem (ncurses)";
            lem-yath = apps.default;
            lem-upstream = mkApp "${lemNcurses}/bin/lem" "Run upstream Lem ncurses without config";
            compile-check = mkTestApp "lem-yath-compile-check" "compile-check.sh";
            boot-test = mkTestApp "lem-yath-boot-test" "boot-test.sh";
            completion-test = mkTestApp "lem-yath-completion-test" "completion-test.sh";
            completion-lifecycle-test = mkTestApp "lem-yath-completion-lifecycle-test" "completion-lifecycle-test.sh";
            auto-completion-test = mkTestApp "lem-yath-auto-completion-test" "auto-completion-test.sh";
            orderless-completion-test = mkTestApp "lem-yath-orderless-completion-test" "orderless-completion-test.sh";
            snippet-test = mkTestApp "lem-yath-snippet-test" "snippet-test.sh";
            lsp-snippet-test = mkTestApp "lem-yath-lsp-snippet-test" "lsp-snippet-test.sh";
            interactive-test = mkTestApp "lem-yath-interactive-test" "interactive-test.sh";
            structural-test = mkTestAppWithLem lemYath "lem-yath-structural-test" "structural-test.sh";
            screen-line-test = mkTestAppWithLem lemYath "lem-yath-screen-line-test" "screen-line-test.sh";
            notes-test = mkTestApp "lem-yath-notes-test" "notes-test.sh";
            org-test = mkTestAppWithLem lemYath "lem-yath-org-test" "org-test.sh";
            org-operator-test = mkTestAppWithLem lemYath "lem-yath-org-operator-test" "org-operator-test.sh";
            agenda-test = mkTestAppWithLem lemYath "lem-yath-agenda-test" "agenda-test.sh";
            editing-test = mkTestApp "lem-yath-editing-test" "editing-test.sh";
            formatting-test = mkTestApp "lem-yath-formatting-test" "formatting-test.sh";
            prompt-completion-test = mkTestApp "lem-yath-prompt-completion-test" "prompt-completion-test.sh";
            daily-workflows-test = mkTestApp "lem-yath-daily-workflows-test" "daily-workflows-test.sh";
            project-navigation-test = mkTestApp "lem-yath-project-navigation-test" "project-navigation-test.sh";
            persistence-test = mkTestApp "lem-yath-persistence-test" "persistence-test.sh";
            electric-editing-test = mkTestApp "lem-yath-electric-editing-test" "electric-editing-test.sh";
            ui-parity-test = mkTestAppWithLem lemYath "lem-yath-ui-parity-test" "ui-parity-test.sh";
            vcs-test = mkTestAppWithLemAndInputs lemYath vcsRuntimeInputs "lem-yath-vcs-test" "vcs-test.sh";
            vundo-test = mkTestApp "lem-yath-vundo-test" "vundo-test.sh";
            actions-test = mkTestApp "lem-yath-actions-test" "actions-test.sh";
            llm-keybinding-test = mkTestApp "lem-yath-llm-keybinding-test" "llm-keybinding-test.sh";
            cursor-state-test = mkTestApp "lem-yath-cursor-state-test" "cursor-state-test.sh";
            snipe-test = mkTestApp "lem-yath-snipe-test" "snipe-test.sh";
            lsp-project-test = mkTestAppWithLem lemLspTest "lem-yath-lsp-project-test" "lsp-project-test.sh";
            real-lsp-test = mkRealLspTestApp "lem-yath-real-lsp-test" "real-lsp-test.sh";
          };

          checks = {
            package = lemYath;
            compile = mkCheck "compile" "compile-check.sh";
            boot = mkCheck "boot" "boot-test.sh";
            completion = mkCheck "completion" "completion-test.sh";
            completion-lifecycle = mkCheck "completion-lifecycle" "completion-lifecycle-test.sh";
            auto-completion = mkCheck "auto-completion" "auto-completion-test.sh";
            orderless-completion = mkCheck "orderless-completion" "orderless-completion-test.sh";
            snippets = mkCheck "snippets" "snippet-test.sh";
            lsp-snippets = mkCheck "lsp-snippets" "lsp-snippet-test.sh";
            structural = mkCheckWithLem lemYath "structural" "structural-test.sh";
            screen-line = mkCheckWithLem lemYath "screen-line" "screen-line-test.sh";
            notes = mkCheck "notes" "notes-test.sh";
            org = mkCheckWithLem lemYath "org" "org-test.sh";
            org-operator = mkCheckWithLem lemYath "org-operator" "org-operator-test.sh";
            agenda = mkCheckWithLem lemYath "agenda" "agenda-test.sh";
            editing = mkCheck "editing" "editing-test.sh";
            formatting = mkCheck "formatting" "formatting-test.sh";
            prompt-completion = mkCheck "prompt-completion" "prompt-completion-test.sh";
            daily-workflows = mkCheck "daily-workflows" "daily-workflows-test.sh";
            project-navigation = mkCheck "project-navigation" "project-navigation-test.sh";
            persistence = mkCheck "persistence" "persistence-test.sh";
            electric-editing = mkCheck "electric-editing" "electric-editing-test.sh";
            ui-parity = mkCheckWithLem lemYath "ui-parity" "ui-parity-test.sh";
            vcs = mkCheckWithLemAndInputs lemYath vcsRuntimeInputs "vcs" "vcs-test.sh";
            vundo = mkCheck "vundo" "vundo-test.sh";
            actions = mkCheck "actions" "actions-test.sh";
            llm-keybinding = mkCheck "llm-keybinding" "llm-keybinding-test.sh";
            cursor-state = mkCheck "cursor-state" "cursor-state-test.sh";
            snipe = mkCheck "snipe" "snipe-test.sh";
            lsp-project = mkCheckWithLem lemLspTest "lsp-project" "lsp-project-test.sh";
            real-lsp = mkRealLspCheck "real-lsp" "real-lsp-test.sh";
            parity-ledger =
              pkgs.runCommand "lem-yath-parity-ledger-check" { nativeBuildInputs = [ pkgs.python3 ]; }
                ''
                  cd ${self}
                  python3 ./scripts/check-parity-ledger.py
                  touch "$out"
                '';
          };

          devShells.default = pkgs.mkShell {
            packages = [ lemNcurses ] ++ extendedRuntimeInputs ++ testInputs ++ [ pkgs.nixfmt-rfc-style ];
            shellHook = ''
              export LEM_BIN=${lemNcurses}/bin/lem
              export LEM_YATH_SOURCE=$PWD/lem-yath
              export LEM_YATH_SNIPPET_DIRS="$PWD/lem-yath/snippets:${yasnippet-snippets}/snippets"
            '';
          };

          formatter = pkgs.nixfmt-rfc-style;
        };

      all = forAllSystems perSystem;
    in
    {
      packages = lib.mapAttrs (_: value: value.packages) all;
      apps = lib.mapAttrs (_: value: value.apps) all;
      checks = lib.mapAttrs (_: value: value.checks) all;
      devShells = lib.mapAttrs (_: value: value.devShells) all;
      formatter = lib.mapAttrs (_: value: value.formatter) all;
    };
}
