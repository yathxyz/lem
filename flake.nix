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
            patches = [ ./patches/lem-completion-lifecycle.patch ];
          };
          lemNcurses = lem.packages.${system}.lem-ncurses.overrideLispAttrs (_: {
            src = lemPatchedSrc;
          });

          coreRuntimeInputs =
            with pkgs;
            [
              coreutils
              curl
              fd
              findutils
              gitMinimal
              gnugrep
              gnused
              ripgrep
              which
            ]
            ++ lib.optionals pkgs.stdenv.isLinux [ xdg-utils ];

          extendedRuntimeInputs =
            with pkgs;
            coreRuntimeInputs
            ++ [
              harper
              isync
              jujutsu
              nixd
              notmuch
              postgresql
              pyright
              rust-analyzer
            ];

          testInputs =
            with pkgs;
            [
              bash
              tmux
            ]
            ++ coreRuntimeInputs;

          mkApp = program: description: {
            type = "app";
            inherit program;
            meta.description = description;
          };

          lemYath = pkgs.writeShellApplication {
            name = "lem";
            runtimeInputs = coreRuntimeInputs;
            text = ''
              cache_home="''${XDG_CACHE_HOME:-''${HOME:-/tmp}/.cache}"
              asdf_cache="$cache_home/lem-yath/asdf"
              mkdir -p "$asdf_cache"

              export ASDF_OUTPUT_TRANSLATIONS="${self}/lem-yath:$asdf_cache:/nix/store:/nix/store''${ASDF_OUTPUT_TRANSLATIONS:+:$ASDF_OUTPUT_TRANSLATIONS}"
              export LEM_YATH_SNIPPET_DIRS="${self}/lem-yath/snippets:${yasnippet-snippets}/snippets"
              exec ${lemNcurses}/bin/lem -q --eval '(load #P"${self}/lem-yath/init.lisp")' "$@"
            '';
          };

          mkTestApp =
            name: script:
            let
              runner = pkgs.writeShellApplication {
                inherit name;
                runtimeInputs = [ lemNcurses ] ++ testInputs;
                text = ''
                  export TERM=''${TERM:-xterm-256color}
                  export LEM_BIN=${lemNcurses}/bin/lem
                  export LEM_YATH_SOURCE=${self}/lem-yath
                  export LEM_YATH_SNIPPET_DIRS="${self}/lem-yath/snippets:${yasnippet-snippets}/snippets"
                  exec bash ${self}/scripts/${script} "$@"
                '';
              };
            in
            mkApp "${runner}/bin/${name}" "Run ${script} with flake-pinned Lem";

          mkCheck =
            name: script:
            pkgs.runCommand "lem-yath-${name}-check"
              {
                nativeBuildInputs = [ lemNcurses ] ++ testInputs;
              }
              ''
                export TERM=xterm-256color
                export HOME=$TMPDIR/home
                export XDG_CACHE_HOME=$TMPDIR/cache
                export LEM_BIN=${lemNcurses}/bin/lem
                export LEM_YATH_CHECK_ID=nix-${name}
                export LEM_YATH_SNIPPET_DIRS="$PWD/source/lem-yath/snippets:${yasnippet-snippets}/snippets"

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
            interactive-test = mkTestApp "lem-yath-interactive-test" "interactive-test.sh";
            structural-test = mkTestApp "lem-yath-structural-test" "structural-test.sh";
            notes-test = mkTestApp "lem-yath-notes-test" "notes-test.sh";
            editing-test = mkTestApp "lem-yath-editing-test" "editing-test.sh";
            prompt-completion-test = mkTestApp "lem-yath-prompt-completion-test" "prompt-completion-test.sh";
            daily-workflows-test = mkTestApp "lem-yath-daily-workflows-test" "daily-workflows-test.sh";
            electric-editing-test = mkTestApp "lem-yath-electric-editing-test" "electric-editing-test.sh";
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
            notes = mkCheck "notes" "notes-test.sh";
            editing = mkCheck "editing" "editing-test.sh";
            prompt-completion = mkCheck "prompt-completion" "prompt-completion-test.sh";
            daily-workflows = mkCheck "daily-workflows" "daily-workflows-test.sh";
            electric-editing = mkCheck "electric-editing" "electric-editing-test.sh";
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
