# lem-yath app-module porting conventions

You are implementing ONE file under `lem-yath/src/apps/<name>.lisp`, replacing
its stub. It is a component of the `lem-yath` ASDF system (see `lem-yath/lem-yath.asd`)
and loads into the nix-built `lem-ncurses` image.

## Hard rules

1. **Only real APIs.** Every Lem symbol you call MUST be verified against the
   actual source in `vendor/lem/` (grep it) or the verified reference
   `docs/lem-capabilities.md`. Lem is NOT Emacs: there is no `with-current-buffer`,
   no `save-excursion`, different point/buffer APIs. When in doubt, read
   `vendor/lem/src/` and existing `vendor/lem/extensions/`.
2. **Package**: file starts with a `;;;;` header comment then `(in-package :lem-yath)`.
   Reference other packages with single colon only for verified exports;
   `package::symbol` only when the symbol exists but isn't exported.
3. **Threading**: the editor runs on one thread. Background work uses
   `bt2:make-thread`; ALL buffer/UI mutations from workers must go through
   `(send-event (lambda () ...))`. Prefer the existing helpers.
4. **No new dependencies.** Available in the image: `alexandria`, `yason`
   (JSON), `cl-ppcre`, `str`, `quri`, `bordeaux-threads` (`bt2:`), `uiop`.
   There is NO dexador/drakma — do HTTP with `curl` via
   `uiop:launch-program`/`uiop:run-program`.
5. **Graceful degradation**: missing binary, credentials, network, or file must
   produce `(message "...")` and a clean return — never an unhandled error,
   never a hang. Wrap external parsing in `handler-case`.
6. **CL style**: docstrings on every command; `defvar`/`defparameter` knobs at
   top; no dead code; small functions; follow `vendor/lem/STYLEGUIDE.md`.

## Helpers already in `:lem-yath` (src/base.lisp, src/llm.lisp, src/notes.lisp)

- `(workdir)` → `$WORKDIR` or `~/work` as a directory pathname.
- `(find-up start name)` → walk up to the dir containing file/dir `name`.
- `(executable-find name)` → full path or NIL.
- `(orderless-filter input candidates :key fn)` → fuzzy candidate filter;
  combine with `prompt-for-string :completion-function`.
- `(stream-to-buffer command buffer-name :directory d :clear t :on-exit fn)`
  → run process async, stream output into a buffer; returns immediately.
- `(append-text buffer string)` / `(append-line buffer string)` → thread-safe
  buffer appends.
- `(llm-stream prompt)` and `*llm-model*` / `*llm-buffer-name*` for LLM work.

## Commands & keybindings

- Commands: `(define-command lem-yath-<area>-<verb> () () "docstring" ...)`.
- Leader bindings go at the END of your file, e.g.
  `(define-key lem-vi-mode:*normal-keymap* "Leader y o" 'lem-yath-citar-open)`.
  The leader is SPC. Don't touch keys outside your assignment.
- For list UIs: create a buffer, `(setf (buffer-read-only-p buffer) t)` after
  filling, and define a dedicated major mode with a keymap binding `Return`,
  `q` (quit-active-window), `n`/`p` as appropriate. See
  `vendor/lem/src/ext/grep.lisp` and `vendor/lem/extensions/legit/` for
  in-tree patterns. A simple read-only buffer with positional `Return`
  handling is acceptable; don't over-engineer.

## Definition of done (enforced)

From the repo root, BOTH must pass (use a unique id to avoid collisions):

```sh
LEM_YATH_CHECK_ID=<yourname> ./scripts/compile-check.sh   # must end with LOAD OK, no ERROR
LEM_YATH_CHECK_ID=<yourname> ./scripts/boot-test.sh       # must print BOOT TEST PASSED
```

Zero compile warnings about undefined functions/variables are tolerated for
YOUR file. If your feature can be exercised non-interactively (e.g. parsing a
file, hitting a local CLI), add a quick `--eval`-driven check via tmux
(pattern: scripts/compile-check.sh) and run it.

Report at the end: what you implemented, what you intentionally left out, and
any behavioral differences from the Emacs original.
