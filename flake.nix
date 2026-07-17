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
              ./patches/lem-completion-detail-accessor.patch
              ./patches/lem-transient-delay-race.patch
              ./patches/lem-transient-bottom-restore.patch
              ./patches/lem-project-lsp-workspaces.patch
              ./patches/lem-lsp-buffer-lifecycle-hooks.patch
              ./patches/lem-lsp-pipe-stdio.patch
              ./patches/lem-lsp-json-type-error.patch
              ./patches/lem-lsp-workspace-symbol-score.patch
              ./patches/lem-grep-writeback.patch
              ./patches/lem-peek-source-timer.patch
              ./patches/lem-safe-revert.patch
              ./patches/lem-prompt-history-limit.patch
              ./patches/lem-undo-tree.patch
              ./patches/lem-completion-observer-change-group.patch
              ./patches/lem-after-change-undo.patch
              ./patches/lem-undo-state-point.patch
              ./patches/lem-completion-presentation-focus.patch
              ./patches/lem-completion-groups.patch
              ./patches/lem-completion-marginalia-layout.patch
              ./patches/lem-vi-screen-line.patch
              ./patches/lem-centered-content-width.patch
              ./patches/lem-word-boundary-wrap.patch
              ./patches/lem-git-worktree.patch
              ./patches/lem-legit-status-sections.patch
              ./patches/lem-hidden-lines.patch
              ./patches/lem-buffer-write-function.patch
              ./patches/lem-display-line-transformer.patch
              ./patches/lem-directory-buffer-clean.patch
              ./patches/lem-completion-validity.patch
              ./patches/lem-terminal-safe-cwd.patch
              ./patches/lem-mcp-server-secure.patch
              ./patches/lem-before-find-file.patch
              ./patches/lem-kill-buffer-query.patch
              ./patches/lem-completion-repaint.patch
            ];
          };
          terminalSo = pkgs.stdenv.mkDerivation {
            pname = "lem-yath-terminal-so";
            version = "0.1.0";
            src = "${lemPatchedSrc}/extensions/terminal";
            buildInputs = [ pkgs.libvterm-neovim ];
            buildPhase = ''
              $CC -shared -fPIC -o terminal.so terminal.c \
                -I${pkgs.libvterm-neovim}/include \
                -L${pkgs.libvterm-neovim}/lib -lvterm \
                -lutil
            '';
            installPhase = ''
              mkdir -p $out/lib
              cp terminal.so $out/lib/
            '';
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
              nativeLibs = map (
                dependency: if (dependency.pname or null) == "lem-terminal-so" then terminalSo else dependency
              ) old.nativeLibs;
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

          treeSitterGrammars = pkgs.tree-sitter-grammars;
          javascriptHighlights = pkgs.concatText "lem-yath-javascript-highlights.scm" [
            "${treeSitterGrammars.tree-sitter-javascript}/queries/highlights.scm"
            "${treeSitterGrammars.tree-sitter-javascript}/queries/highlights-params.scm"
            "${treeSitterGrammars.tree-sitter-javascript}/queries/highlights-jsx.scm"
          ];
          typescriptHighlights = pkgs.concatText "lem-yath-typescript-highlights.scm" [
            "${treeSitterGrammars.tree-sitter-javascript}/queries/highlights.scm"
            "${treeSitterGrammars.tree-sitter-typescript.src}/queries/highlights.scm"
          ];
          tsxHighlights = pkgs.concatText "lem-yath-tsx-highlights.scm" [
            "${treeSitterGrammars.tree-sitter-javascript}/queries/highlights.scm"
            "${treeSitterGrammars.tree-sitter-javascript}/queries/highlights-jsx.scm"
            "${treeSitterGrammars.tree-sitter-typescript.src}/queries/highlights.scm"
          ];
          treeSitterSpecs = [
            {
              name = "bash";
              grammar = treeSitterGrammars.tree-sitter-bash;
            }
            {
              name = "c";
              grammar = treeSitterGrammars.tree-sitter-c;
            }
            {
              name = "c_sharp";
              grammar = treeSitterGrammars.tree-sitter-c-sharp;
            }
            {
              name = "clojure";
              grammar = treeSitterGrammars.tree-sitter-clojure;
            }
            {
              name = "css";
              grammar = treeSitterGrammars.tree-sitter-css;
            }
            {
              name = "go";
              grammar = treeSitterGrammars.tree-sitter-go;
            }
            {
              name = "gdscript";
              grammar = treeSitterGrammars.tree-sitter-gdscript;
              query = ./queries/gdscript-highlights.scm;
            }
            {
              name = "html";
              grammar = treeSitterGrammars.tree-sitter-html;
            }
            {
              name = "java";
              grammar = treeSitterGrammars.tree-sitter-java;
            }
            {
              name = "javascript";
              grammar = treeSitterGrammars.tree-sitter-javascript;
              query = javascriptHighlights;
            }
            {
              name = "json";
              grammar = treeSitterGrammars.tree-sitter-json;
            }
            {
              name = "just";
              grammar = treeSitterGrammars.tree-sitter-just;
              query = "${treeSitterGrammars.tree-sitter-just}/queries/just/highlights.scm";
            }
            {
              name = "lua";
              grammar = treeSitterGrammars.tree-sitter-lua;
            }
            {
              name = "markdown";
              grammar = treeSitterGrammars.tree-sitter-markdown;
            }
            {
              name = "nix";
              grammar = treeSitterGrammars.tree-sitter-nix;
            }
            {
              name = "nu";
              grammar = treeSitterGrammars.tree-sitter-nu;
              query = "${treeSitterGrammars.tree-sitter-nu}/queries/nu/highlights.scm";
            }
            {
              name = "python";
              grammar = treeSitterGrammars.tree-sitter-python;
            }
            {
              name = "rust";
              grammar = treeSitterGrammars.tree-sitter-rust;
            }
            {
              name = "toml";
              grammar = treeSitterGrammars.tree-sitter-toml;
            }
            {
              name = "typescript";
              grammar = treeSitterGrammars.tree-sitter-typescript;
              query = typescriptHighlights;
            }
            {
              name = "tsx";
              grammar = treeSitterGrammars.tree-sitter-tsx;
              query = tsxHighlights;
            }
            {
              name = "typst";
              grammar = treeSitterGrammars.tree-sitter-typst;
              query = "${treeSitterGrammars.tree-sitter-typst}/queries/typst/highlights.scm";
            }
            {
              name = "yaml";
              grammar = treeSitterGrammars.tree-sitter-yaml;
            }
          ];
          treeSitterBundle = pkgs.linkFarm "lem-yath-tree-sitter-bundle" (
            lib.concatMap (spec: [
              {
                name = "${spec.name}/parser";
                path = "${spec.grammar}/parser";
              }
              {
                name = "${spec.name}/highlights.scm";
                path = spec.query or "${spec.grammar}/queries/highlights.scm";
              }
            ]) treeSitterSpecs
          );

          devPython = pkgs.python3.withPackages (pythonPackages: [
            pythonPackages.debugpy
          ]);

          aspellRuntime = pkgs.aspellWithDicts (dictionaries: [ dictionaries.en ]);

          coreRuntimeInputs =
            with pkgs;
            [
              aspellRuntime
              bash
              black
              clang
              clang-tools
              coreutils
              curl
              diffutils
              direnv
              editorconfig-core-c
              fd
              findutils
              gitMinimal
              gnumake
              go
              google-java-format
              gnugrep
              gnused
              nixfmt-rfc-style
              mypy
              ripgrep
              ruff
              rustfmt
              sops
              which
            ]
            ++ lib.optionals pkgs.stdenv.isLinux [
              wl-clipboard
              xclip
              xdg-utils
            ];

          dapRuntimeInputs = with pkgs; [
            delve
            gdb
            lldb_19
            devPython
          ];

          lspRuntimeInputs = with pkgs; [
            csharp-ls
            gopls
            harper
            jdt-language-server
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

          vcsRuntimeInputs = with pkgs; [
            gh
            jujutsu
          ];

          mailRuntimeInputs = with pkgs; [
            isync
            notmuch
          ];

          defaultRuntimeInputs =
            coreRuntimeInputs
            ++ dapRuntimeInputs
            ++ lspRuntimeInputs
            ++ rustRuntimeInputs
            ++ vcsRuntimeInputs
            ++ (with pkgs; [
              docker-client
              uv
              pandoc
              poppler-utils
              postgresql
              sqlite
              libqalculate
            ]);

          extendedRuntimeInputs = defaultRuntimeInputs ++ mailRuntimeInputs;

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

          lemClient = pkgs.writeShellApplication {
            name = "lemclient";
            runtimeInputs = with pkgs; [
              coreutils
              gnugrep
              socat
              tmux
            ];
            text = builtins.readFile ./scripts/lemclient.sh;
          };

          lemYathAotScript = pkgs.writeText "compile-lem-yath-aot.lisp" ''
            (in-package :cl-user)

            (labels ((finish (text status)
                       (with-open-file
                           (stream (uiop:getenv "LEM_YATH_AOT_REPORT")
                                   :direction :output
                                   :if-exists :supersede
                                   :if-does-not-exist :create)
                         (write-line text stream))
                       (uiop:quit status)))
              (handler-case
                  (progn
                    (asdf:load-asd #P"${self}/lem-yath/lem-yath.asd")
                    (asdf:load-system "lem-yath")
                    (finish "AOT OK" 0))
                (error (condition)
                  (finish (format nil "AOT ERROR: ~A" condition) 1))))
          '';

          lemYathAot =
            pkgs.runCommand "lem-yath-aot-fasls"
              {
                nativeBuildInputs = [
                  lemNcurses
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.tmux
                ]
                ++ defaultRuntimeInputs;
              }
              ''
                mkdir -p "$out" "$TMPDIR/home" "$TMPDIR/cache"
                export HOME="$TMPDIR/home"
                export XDG_CACHE_HOME="$TMPDIR/cache"
                export TERM=xterm-256color
                export LEM_YATH_AOT_REPORT="$TMPDIR/aot-report"
                export LEM_YATH_CLIENT=${lemClient}/bin/lemclient
                export LEM_YATH_RUNTIME_PATH="${lib.makeBinPath defaultRuntimeInputs}"
                export LEM_YATH_GUARDIAN_PYTHON=${lib.getExe' pkgs.python3 "python3"}
                export LEM_YATH_MCP_FETCH_PROGRAM=${lib.getExe' pkgs.uv "uvx"}
                export LEM_YATH_MCP_DOCKER_PROGRAM=${lib.getExe pkgs.docker-client}
                export LEM_YATH_TREE_SITTER_BUNDLE=${treeSitterBundle}
                export LEM_YATH_SNIPPET_DIRS="${self}/lem-yath/snippets:${yasnippet-snippets}/snippets"
                export ASDF_OUTPUT_TRANSLATIONS="${self}/lem-yath:$out:/nix/store:/nix/store"

                socket="lem-yath-aot-$$"
                form='(load #P"${lemYathAotScript}")'
                printf -v command '%q ' \
                  ${lemNcurses}/bin/lem -q \
                  --log-filename "$TMPDIR/lem.log" \
                  --eval "$form"
                tmux -L "$socket" new-session -d -s build -x 160 -y 45 "$command"

                for _ in $(seq 1 600); do
                  [ -f "$LEM_YATH_AOT_REPORT" ] && break
                  tmux -L "$socket" has-session -t build 2>/dev/null || break
                  sleep 0.1
                done
                tmux -L "$socket" kill-server 2>/dev/null || true

                if ! grep -Fxq 'AOT OK' "$LEM_YATH_AOT_REPORT" 2>/dev/null; then
                  cat "$LEM_YATH_AOT_REPORT" 2>/dev/null || true
                  cat "$TMPDIR/lem.log" 2>/dev/null || true
                  exit 1
                fi

                expected=$(find ${self}/lem-yath/src -type f -name '*.lisp' | wc -l)
                actual=$(find "$out" -type f -name '*.fasl' | wc -l)
                if [ "$actual" -ne "$expected" ]; then
                  echo "expected $expected lem-yath FASLs, built $actual" >&2
                  exit 1
                fi
              '';

          lemYathEditor = pkgs.writeShellApplication {
            name = "lem";
            runtimeInputs = defaultRuntimeInputs;
            text = ''
              export LEM_YATH_CLIENT=${lemClient}/bin/lemclient
              export LEM_YATH_ALTERNATE_EDITOR="$0"
              export LEM_YATH_RUNTIME_PATH="${lib.makeBinPath defaultRuntimeInputs}"
              export LEM_YATH_ASPELL_PROGRAM=${lib.getExe' aspellRuntime "aspell"}
              export LEM_YATH_TIMEOUT_PROGRAM=${lib.getExe' pkgs.coreutils "timeout"}
              export LEM_YATH_GUARDIAN_PYTHON=${lib.getExe' pkgs.python3 "python3"}
              export LEM_YATH_LEM_SOURCE=${lemPatchedSrc}
              export LEM_YATH_MCP_FETCH_PROGRAM="''${LEM_YATH_MCP_FETCH_PROGRAM:-${lib.getExe' pkgs.uv "uvx"}}"
              export LEM_YATH_MCP_DOCKER_PROGRAM="''${LEM_YATH_MCP_DOCKER_PROGRAM:-${lib.getExe pkgs.docker-client}}"
              export LEM_YATH_TREE_SITTER_BUNDLE=${treeSitterBundle}
              export LEM_YATH_AOT_FASL_ROOT=${lemYathAot}

              cache_home="''${XDG_CACHE_HOME:-''${HOME:-/tmp}/.cache}"
              export ASDF_OUTPUT_TRANSLATIONS="${self}/lem-yath:${lemYathAot}:/nix/store:/nix/store''${ASDF_OUTPUT_TRANSLATIONS:+:$ASDF_OUTPUT_TRANSLATIONS}"
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
              have_log_filename=0
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
                  --log-filename)
                    have_log_filename=1
                    lem_args+=("$1")
                    shift
                    if (( "$#" )); then
                      lem_args+=("$1")
                      shift
                    fi
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

              if (( ! have_log_filename )); then
                lem_args+=(--log-filename "$cache_home/lem-yath/debug.log")
              fi

              exec ${lemNcurses}/bin/lem "''${lem_args[@]}"
            '';
          };

          lemYath = pkgs.symlinkJoin {
            name = "lem-yath";
            paths = [
              lemYathEditor
              lemClient
            ];
          };

          realLspEnvironment = ''
            export LEM_YATH_REAL_LSP_RUST_ANALYZER=${lib.getExe pkgs.rust-analyzer}
            export LEM_YATH_REAL_LSP_PYRIGHT=${lib.getExe' pkgs.pyright "pyright-langserver"}
            export LEM_YATH_REAL_LSP_HARPER=${lib.getExe pkgs.harper}
            export LEM_YATH_REAL_LSP_CSHARP=${lib.getExe pkgs.csharp-ls}
            export LEM_YATH_REAL_LSP_NIXD=${lib.getExe pkgs.nixd}
            export LEM_YATH_REAL_LSP_NIXPKGS_SOURCE=${nixpkgs}
            export LEM_YATH_REAL_LSP_GOPLS=${lib.getExe pkgs.gopls}
            export LEM_YATH_REAL_LSP_TERRAFORM_LS=${lib.getExe pkgs.terraform-ls}
            export LEM_YATH_REAL_LSP_JDTLS=${lib.getExe pkgs.jdt-language-server}
            export LEM_YATH_REAL_LSP_GOOGLE_JAVA_FORMAT=${lib.getExe pkgs.google-java-format}
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
                  export LEM_UPSTREAM_BIN=${lemNcurses}/bin/lem
                  export LEM_YATH_LEM_SOURCE=${lemPatchedSrc}
                  export LEM_YATH_SOURCE=${self}/lem-yath
                  export LEM_YATH_RUNTIME_PATH="${lib.makeBinPath defaultRuntimeInputs}"
                  export LEM_YATH_ASPELL_PROGRAM=${lib.getExe' aspellRuntime "aspell"}
                  export LEM_YATH_TIMEOUT_PROGRAM=${lib.getExe' pkgs.coreutils "timeout"}
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
                export LC_ALL=C.UTF-8
                export HOME=$TMPDIR/home
                export XDG_CACHE_HOME=$TMPDIR/cache
                export LEM_BIN=${lemPackage}/bin/lem
                export LEM_UPSTREAM_BIN=${lemNcurses}/bin/lem
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
                export LC_ALL=C.UTF-8
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
            compilation-test = mkTestAppWithLem lemYath "lem-yath-compilation-test" "compilation-test.sh";
            terminal-test = mkTestAppWithLem lemYath "lem-yath-terminal-test" "terminal-test.sh";
            server-test = mkTestAppWithLemAndInputs lemYath [
              pkgs.socat
              pkgs.util-linux
            ] "lem-yath-server-test" "server-test.sh";
            boot-test = mkTestApp "lem-yath-boot-test" "boot-test.sh";
            startup-test = mkTestAppWithLem lemYath "lem-yath-startup-test" "startup-test.sh";
            completion-test = mkTestApp "lem-yath-completion-test" "completion-test.sh";
            completion-lifecycle-test = mkTestApp "lem-yath-completion-lifecycle-test" "completion-lifecycle-test.sh";
            auto-completion-test = mkTestApp "lem-yath-auto-completion-test" "auto-completion-test.sh";
            orderless-completion-test = mkTestApp "lem-yath-orderless-completion-test" "orderless-completion-test.sh";
            snippet-test = mkTestApp "lem-yath-snippet-test" "snippet-test.sh";
            lsp-snippet-test = mkTestApp "lem-yath-lsp-snippet-test" "lsp-snippet-test.sh";
            interactive-test = mkTestApp "lem-yath-interactive-test" "interactive-test.sh";
            expreg-test = mkTestApp "lem-yath-expreg-test" "expreg-test.sh";
            surround-test = mkTestApp "lem-yath-surround-test" "surround-test.sh";
            structural-test = mkTestAppWithLem lemYath "lem-yath-structural-test" "structural-test.sh";
            screen-line-test = mkTestAppWithLem lemYath "lem-yath-screen-line-test" "screen-line-test.sh";
            notes-test = mkTestApp "lem-yath-notes-test" "notes-test.sh";
            roam-test = mkTestApp "lem-yath-roam-test" "roam-test.sh";
            roam-backlink-test = mkTestAppWithLem lemYath "lem-yath-roam-backlink-test" "roam-backlink-test.sh";
            org-test = mkTestAppWithLem lemYath "lem-yath-org-test" "org-test.sh";
            org-modern-test =
              mkTestAppWithLem lemYath "lem-yath-org-modern-test"
                "org-modern-test.sh";
            org-download-test =
              mkTestAppWithLem lemYath "lem-yath-org-download-test"
                "org-download-test.sh";
            org-planning-test = mkTestAppWithLem lemYath "lem-yath-org-planning-test" "org-planning-test.sh";
            org-timestamp-test = mkTestAppWithLem lemYath "lem-yath-org-timestamp-test" "org-timestamp-test.sh";
            org-source-edit-test =
              mkTestAppWithLem lemYath "lem-yath-org-source-edit-test"
                "org-source-edit-test.sh";
            org-babel-test = mkTestAppWithLemAndInputs lemYath [
              pkgs.postgresql
            ] "lem-yath-org-babel-test" "org-babel-test.sh";
            org-publish-test = mkTestAppWithLemAndInputs lemYath [
              pkgs.pandoc
            ] "lem-yath-org-publish-test" "org-publish-test.sh";
            org-nodes-sync-test =
              mkTestAppWithLem lemYath "lem-yath-org-nodes-sync-test"
                "org-nodes-sync-test.sh";
            org-operator-test = mkTestAppWithLem lemYath "lem-yath-org-operator-test" "org-operator-test.sh";
            agenda-test = mkTestAppWithLem lemYath "lem-yath-agenda-test" "agenda-test.sh";
            agenda-undo-test = mkTestAppWithLem lemYath "lem-yath-agenda-undo-test" "agenda-undo-test.sh";
            agenda-clock-test = mkTestAppWithLem lemYath "lem-yath-agenda-clock-test" "agenda-clock-test.sh";
            agenda-bulk-test = mkTestAppWithLem lemYath "lem-yath-agenda-bulk-test" "agenda-bulk-test.sh";
            agenda-filter-test =
              mkTestAppWithLem lemYath "lem-yath-agenda-filter-test" "agenda-filter-test.sh";
            agenda-view-test =
              mkTestAppWithLem lemYath "lem-yath-agenda-view-test" "agenda-view-test.sh";
            editing-test = mkTestApp "lem-yath-editing-test" "editing-test.sh";
            formatting-test = mkTestApp "lem-yath-formatting-test" "formatting-test.sh";
            prompt-completion-test = mkTestApp "lem-yath-prompt-completion-test" "prompt-completion-test.sh";
            daily-workflows-test = mkTestApp "lem-yath-daily-workflows-test" "daily-workflows-test.sh";
            dirvish-test = mkTestAppWithLem lemYath "lem-yath-dirvish-test" "dirvish-test.sh";
            calc-test = mkTestAppWithLem lemYath "lem-yath-calc-test" "calc-test.sh";
            so-long-test = mkTestAppWithLem lemYath "lem-yath-so-long-test" "so-long-test.sh";
            large-file-test = mkTestAppWithLem lemYath "lem-yath-large-file-test" "large-file-test.sh";
            buffer-list-test = mkTestAppWithLem lemYath "lem-yath-buffer-list-test" "buffer-list-test.sh";
            direnv-test = mkTestApp "lem-yath-direnv-test" "direnv-test.sh";
            project-navigation-test = mkTestApp "lem-yath-project-navigation-test" "project-navigation-test.sh";
            project-outline-test =
              mkTestAppWithLem lemYath "lem-yath-project-outline-test"
                "project-outline-test.sh";
            persistence-test = mkTestApp "lem-yath-persistence-test" "persistence-test.sh";
            bookmark-test = mkTestApp "lem-yath-bookmark-test" "bookmark-test.sh";
            electric-editing-test = mkTestApp "lem-yath-electric-editing-test" "electric-editing-test.sh";
            ui-parity-test = mkTestAppWithLem lemYath "lem-yath-ui-parity-test" "ui-parity-test.sh";
            indent-guides-test = mkTestAppWithLem lemYath "lem-yath-indent-guides-test" "indent-guides-test.sh";
            centered-view-test = mkTestAppWithLem lemYath "lem-yath-centered-view-test" "centered-view-test.sh";
            business-visual-test =
              mkTestAppWithLem lemYath "lem-yath-business-visual-test"
                "business-visual-test.sh";
            window-history-test =
              mkTestAppWithLem lemYath "lem-yath-window-history-test"
                "window-history-test.sh";
            help-test = mkTestApp "lem-yath-help-test" "help-test.sh";
            sops-test = mkTestApp "lem-yath-sops-test" "sops-test.sh";
            vcs-test = mkTestAppWithLemAndInputs lemYath vcsRuntimeInputs "lem-yath-vcs-test" "vcs-test.sh";
            jj-porcelain-test =
              mkTestAppWithLemAndInputs lemYath vcsRuntimeInputs "lem-yath-jj-porcelain-test"
                "jj-porcelain-test.sh";
            forge-test =
              mkTestAppWithLemAndInputs lemYath vcsRuntimeInputs "lem-yath-forge-test"
                "forge-test.sh";
            documents-test = mkTestAppWithLemAndInputs lemYath [
              pkgs.pandoc
              pkgs.poppler-utils
            ] "lem-yath-documents-test" "documents-test.sh";
            citar-test = mkTestAppWithLem lemYath "lem-yath-citar-test" "citar-test.sh";
            devdocs-test = mkTestAppWithLem lemYath "lem-yath-devdocs-test" "devdocs-test.sh";
            pg-test = mkTestAppWithLemAndInputs lemYath [ pkgs.postgresql ] "lem-yath-pg-test" "pg-test.sh";
            elfeed-test = mkTestAppWithLem lemYath "lem-yath-elfeed-test" "elfeed-test.sh";
            notmuch-test =
              mkTestAppWithLemAndInputs lemYath mailRuntimeInputs "lem-yath-notmuch-test"
                "notmuch-test.sh";
            salta-test = mkTestAppWithLem lemYath "lem-yath-salta-test" "salta-test.sh";
            vundo-test = mkTestApp "lem-yath-vundo-test" "vundo-test.sh";
            actions-test = mkTestApp "lem-yath-actions-test" "actions-test.sh";
            llm-keybinding-test = mkTestApp "lem-yath-llm-keybinding-test" "llm-keybinding-test.sh";
            llm-conversation-test =
              mkTestAppWithLem lemYath "lem-yath-llm-conversation-test"
                "llm-conversation-test.sh";
            llm-backend-test = mkTestAppWithLem lemYath "lem-yath-llm-backend-test" "llm-backend-test.sh";
            llm-http-test = mkTestAppWithLem lemYath "lem-yath-llm-http-test" "llm-http-test.sh";
            llm-oauth-test = mkTestAppWithLem lemYath "lem-yath-llm-oauth-test" "llm-oauth-test.sh";
            llm-workflow-test = mkTestAppWithLem lemYath "lem-yath-llm-workflow-test" "llm-workflow-test.sh";
            llm-tools-test = mkTestAppWithLem lemYath "lem-yath-llm-tools-test" "llm-tools-test.sh";
            llm-mcp-test =
              mkTestAppWithLemAndInputs lemYath [ pkgs.python3 ]
                "lem-yath-llm-mcp-test" "llm-mcp-test.sh";
            claude-code-test = mkTestAppWithLem lemYath "lem-yath-claude-code-test" "claude-code-test.sh";
            claude-bridge-test = mkTestAppWithLem lemYath "lem-yath-claude-bridge-test" "claude-bridge-test.sh";
            lisp-eval-test = mkTestApp "lem-yath-lisp-eval-test" "lisp-eval-test.sh";
            cursor-state-test = mkTestApp "lem-yath-cursor-state-test" "cursor-state-test.sh";
            snipe-test = mkTestApp "lem-yath-snipe-test" "snipe-test.sh";
            avy-test = mkTestApp "lem-yath-avy-test" "avy-test.sh";
            lsp-project-test = mkTestAppWithLem lemLspTest "lem-yath-lsp-project-test" "lsp-project-test.sh";
            real-lsp-test = mkRealLspTestApp "lem-yath-real-lsp-test" "real-lsp-test.sh";
            gdscript-test = mkTestAppWithLem lemYath "lem-yath-gdscript-test" "gdscript-test.sh";
            lint-test = mkTestAppWithLemAndInputs lemYath rustRuntimeInputs "lem-yath-lint-test" "lint-test.sh";
            tree-sitter-test = mkTestAppWithLem lemYath "lem-yath-tree-sitter-test" "tree-sitter-test.sh";
            dap-test = mkTestAppWithLemAndInputs lemYath (
              dapRuntimeInputs ++ rustRuntimeInputs
            ) "lem-yath-dap-test" "dap-test.sh";
          };

          checks = {
            package = lemYath;
            compile = mkCheck "compile" "compile-check.sh";
            compilation = mkCheckWithLem lemYath "compilation" "compilation-test.sh";
            terminal = mkCheckWithLem lemYath "terminal" "terminal-test.sh";
            server = mkCheckWithLemAndInputs lemYath [ pkgs.socat pkgs.util-linux ] "server" "server-test.sh";
            boot = mkCheck "boot" "boot-test.sh";
            startup = mkCheckWithLem lemYath "startup" "startup-test.sh";
            completion = mkCheck "completion" "completion-test.sh";
            completion-lifecycle = mkCheck "completion-lifecycle" "completion-lifecycle-test.sh";
            auto-completion = mkCheck "auto-completion" "auto-completion-test.sh";
            orderless-completion = mkCheck "orderless-completion" "orderless-completion-test.sh";
            snippets = mkCheck "snippets" "snippet-test.sh";
            lsp-snippets = mkCheck "lsp-snippets" "lsp-snippet-test.sh";
            interactive = mkCheck "interactive" "interactive-test.sh";
            expreg = mkCheck "expreg" "expreg-test.sh";
            surround = mkCheck "surround" "surround-test.sh";
            structural = mkCheckWithLem lemYath "structural" "structural-test.sh";
            screen-line = mkCheckWithLem lemYath "screen-line" "screen-line-test.sh";
            notes = mkCheck "notes" "notes-test.sh";
            roam = mkCheck "roam" "roam-test.sh";
            roam-backlinks = mkCheckWithLem lemYath "roam-backlinks" "roam-backlink-test.sh";
            org = mkCheckWithLem lemYath "org" "org-test.sh";
            org-modern = mkCheckWithLem lemYath "org-modern" "org-modern-test.sh";
            org-download = mkCheckWithLem lemYath "org-download" "org-download-test.sh";
            org-planning = mkCheckWithLem lemYath "org-planning" "org-planning-test.sh";
            org-timestamp = mkCheckWithLem lemYath "org-timestamp" "org-timestamp-test.sh";
            org-source-edit = mkCheckWithLem lemYath "org-source-edit" "org-source-edit-test.sh";
            org-babel = mkCheckWithLemAndInputs lemYath [ pkgs.postgresql ] "org-babel" "org-babel-test.sh";
            org-publish = mkCheckWithLemAndInputs lemYath [ pkgs.pandoc ] "org-publish" "org-publish-test.sh";
            org-nodes-sync = mkCheckWithLem lemYath "org-nodes-sync" "org-nodes-sync-test.sh";
            org-operator = mkCheckWithLem lemYath "org-operator" "org-operator-test.sh";
            agenda = mkCheckWithLem lemYath "agenda" "agenda-test.sh";
            agenda-undo = mkCheckWithLem lemYath "agenda-undo" "agenda-undo-test.sh";
            agenda-clock = mkCheckWithLem lemYath "agenda-clock" "agenda-clock-test.sh";
            agenda-bulk = mkCheckWithLem lemYath "agenda-bulk" "agenda-bulk-test.sh";
            agenda-filter = mkCheckWithLem lemYath "agenda-filter" "agenda-filter-test.sh";
            agenda-view = mkCheckWithLem lemYath "agenda-view" "agenda-view-test.sh";
            editing = mkCheck "editing" "editing-test.sh";
            formatting = mkCheck "formatting" "formatting-test.sh";
            prompt-completion = mkCheck "prompt-completion" "prompt-completion-test.sh";
            daily-workflows = mkCheck "daily-workflows" "daily-workflows-test.sh";
            dirvish = mkCheckWithLem lemYath "dirvish" "dirvish-test.sh";
            calc = mkCheckWithLem lemYath "calc" "calc-test.sh";
            so-long = mkCheckWithLem lemYath "so-long" "so-long-test.sh";
            large-file = mkCheckWithLem lemYath "large-file" "large-file-test.sh";
            buffer-list = mkCheckWithLem lemYath "buffer-list" "buffer-list-test.sh";
            direnv = mkCheck "direnv" "direnv-test.sh";
            project-navigation = mkCheck "project-navigation" "project-navigation-test.sh";
            project-outline = mkCheckWithLem lemYath "project-outline" "project-outline-test.sh";
            persistence = mkCheck "persistence" "persistence-test.sh";
            bookmarks = mkCheck "bookmarks" "bookmark-test.sh";
            electric-editing = mkCheck "electric-editing" "electric-editing-test.sh";
            ui-parity = mkCheckWithLem lemYath "ui-parity" "ui-parity-test.sh";
            indent-guides = mkCheckWithLem lemYath "indent-guides" "indent-guides-test.sh";
            centered-view = mkCheckWithLem lemYath "centered-view" "centered-view-test.sh";
            business-visual = mkCheckWithLem lemYath "business-visual" "business-visual-test.sh";
            window-history = mkCheckWithLem lemYath "window-history" "window-history-test.sh";
            help = mkCheck "help" "help-test.sh";
            sops = mkCheck "sops" "sops-test.sh";
            vcs = mkCheckWithLemAndInputs lemYath vcsRuntimeInputs "vcs" "vcs-test.sh";
            jj-porcelain =
              mkCheckWithLemAndInputs lemYath vcsRuntimeInputs "jj-porcelain"
                "jj-porcelain-test.sh";
            forge = mkCheckWithLemAndInputs lemYath vcsRuntimeInputs "forge" "forge-test.sh";
            documents = mkCheckWithLemAndInputs lemYath [
              pkgs.pandoc
              pkgs.poppler-utils
            ] "documents" "documents-test.sh";
            citar = mkCheckWithLem lemYath "citar" "citar-test.sh";
            devdocs = mkCheckWithLem lemYath "devdocs" "devdocs-test.sh";
            pg = mkCheckWithLemAndInputs lemYath [ pkgs.postgresql ] "pg" "pg-test.sh";
            elfeed = mkCheckWithLem lemYath "elfeed" "elfeed-test.sh";
            notmuch = mkCheckWithLemAndInputs lemYath mailRuntimeInputs "notmuch" "notmuch-test.sh";
            salta = mkCheckWithLem lemYath "salta" "salta-test.sh";
            vundo = mkCheck "vundo" "vundo-test.sh";
            actions = mkCheck "actions" "actions-test.sh";
            llm-keybinding = mkCheck "llm-keybinding" "llm-keybinding-test.sh";
            llm-conversation =
              mkCheckWithLem lemYath "llm-conversation"
                "llm-conversation-test.sh";
            llm-backend = mkCheckWithLem lemYath "llm-backend" "llm-backend-test.sh";
            llm-http = mkCheckWithLem lemYath "llm-http" "llm-http-test.sh";
            llm-oauth = mkCheckWithLem lemYath "llm-oauth" "llm-oauth-test.sh";
            llm-workflow = mkCheckWithLem lemYath "llm-workflow" "llm-workflow-test.sh";
            llm-tools = mkCheckWithLem lemYath "llm-tools" "llm-tools-test.sh";
            llm-mcp =
              mkCheckWithLemAndInputs lemYath [ pkgs.python3 ]
                "llm-mcp" "llm-mcp-test.sh";
            claude-code = mkCheckWithLem lemYath "claude-code" "claude-code-test.sh";
            claude-bridge = mkCheckWithLem lemYath "claude-bridge" "claude-bridge-test.sh";
            lisp-eval = mkCheck "lisp-eval" "lisp-eval-test.sh";
            cursor-state = mkCheck "cursor-state" "cursor-state-test.sh";
            snipe = mkCheck "snipe" "snipe-test.sh";
            avy = mkCheck "avy" "avy-test.sh";
            lsp-project = mkCheckWithLem lemLspTest "lsp-project" "lsp-project-test.sh";
            real-lsp = mkRealLspCheck "real-lsp" "real-lsp-test.sh";
            gdscript = mkCheckWithLem lemYath "gdscript" "gdscript-test.sh";
            lint = mkCheckWithLemAndInputs lemYath rustRuntimeInputs "lint" "lint-test.sh";
            tree-sitter = mkCheckWithLem lemYath "tree-sitter" "tree-sitter-test.sh";
            dap = mkCheckWithLemAndInputs lemYath (dapRuntimeInputs ++ rustRuntimeInputs) "dap" "dap-test.sh";
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
