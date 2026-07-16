# lem-yath: emacs → lem

A faithful port of my Nix-managed Emacs configuration
(`~/proj/nix/computer/home/config/emacs`, ~9,100 lines of elisp, ~100 packages)
to [Lem](https://github.com/lem-project/lem), the Common Lisp editor —
terminal (ncurses) frontend, multi-threaded SBCL image.

## Layout

| Path | Purpose |
|---|---|
| `lem-yath/` | The port: ASDF system `lem-yath` (core modules in `src/`, app ports in `src/apps/`) |
| `docs/emacs-inventory.md` | Extracted feature inventory of the Emacs config |
| `docs/parity-ledger.tsv` | Behavior-level parity audit with explicit evidence, divergence, and blockers |
| `docs/lem-capabilities.md` | Survey of Lem's real APIs (grounded in source) |
| `docs/port-map.md` | Emacs package → Lem equivalent mapping + gap report |
| `docs/vi-parity.md` | Vim/Evil behavior matrix, evidence, and remaining gaps |
| `docs/structural-editing.md` | Lispy/Lispyville key themes, safety model, and TUI evidence |
| `docs/porting-conventions.md` | Hard rules every module follows |
| `scripts/` | tmux-based TUI test harness |

## Run

The flake pins upstream Lem and exposes this port as a runnable app. The
wrapper binary is named `lem`, so installing it gives the configured editor
under the usual name (unconfigured upstream stays reachable as `nix run
.#lem-upstream`):

```sh
nix run
```

For development, the dev shell puts the flake-pinned upstream `lem` on PATH
and points `LEM_YATH_SOURCE` at the working tree:

```sh
nix develop
lem -q --eval '(load #P"lem-yath/init.lisp")'
```

The wrapper starts Lem without the user's normal init file and loads
`lem-yath/init.lisp`. Nix compiles every configuration component ahead of time;
the installed editor loads immutable `.fasl` files without compiling into the
user cache. A direct development load still redirects ASDF output under
`XDG_CACHE_HOME` instead of writing beside the sources.

The installed package also provides `lemclient`. A configured Lem running in
tmux publishes an owner-only local socket and its pane, so shell and Git edit
requests can reuse that editor:

```sh
lemclient file.txt
lemclient +42:3 file.txt other.txt
lemclient --no-wait file.txt
```

A waiting file shows the `Server` minor mode. `ZZ` or `C-c C-c` saves and
finishes that file, `C-x #` finishes an already clean file, and `ZQ` or
`C-c C-k` aborts the complete request without discarding unsaved buffer text.
With no files, `lemclient` attaches to the current editor buffer. From another
pane in the same tmux server it switches to Lem while the request is active and
then restores the originating pane. If no reusable pane is available it starts
a fresh configured Lem instead. The running editor sets `GIT_EDITOR` and fills
otherwise-unset `VISUAL`/`EDITOR` for its child processes; a parent shell can
opt in with `export EDITOR=lemclient VISUAL=lemclient GIT_EDITOR=lemclient`.

## What's in the port

- vi-mode with one shared Space leader in normal and visual states; every
  feasible chord is preserved. Globally enabled Which-Key-style guidance
  composes the live global, mode, and Vi-state maps for every ordinary
  keymap-backed prefix, honors dispatcher shadowing, and shows sorted raw command or `+prefix`
  labels in multi-column snapshots capped at one quarter of the frame height.
  Both the initial page and each nested page wait a fresh idle second, while
  native Lem transients keep their 500ms opening delay and immediate nesting
- state-aware terminal cursors and a genuine buffer-local Evil-style Emacs
  state on `C-z`: red-box normal, green-bar insert, cyan-box Emacs, portable
  visual/replace shapes, Emacs mark semantics, GNU Emacs undo on `C-/`, `C-_`,
  and `C-x u`, and exact prior-state return
- a host-gated office-document profile in its own module: `workwin` starts with
  a calm light semantic theme, compact modeline, shape-only cursors, disabled
  jump pulses, and centered/wrapped 88-column Org, Markdown/EPUB, text,
  Notmuch-message, feed-entry, and DevDocs buffers. `M-x business-visual-mode`
  permits an explicit trial on another host and toggle-off restores the prior
  theme and per-buffer presentation exactly; ncurses-specific font and frame
  limitations remain documented
- an Evil-aware in-editor terminal on `M-x vterm` (with `M-x terminal` retained):
  new sessions start in Insert, Escape enters a live read-only Normal view,
  `i/I/a/A` return to raw input, Normal `p/P` and Return send to the child, and
  `C-c C-z` toggles whether Escape goes to the child. The Nix build patches the
  native terminal to spawn directly in the literal buffer directory without a
  shell command string and to terminate and reap the child on buffer cleanup
- an `emacsclient`-style `lemclient` backed by an owner-private local Unix
  socket: blocking and no-wait file requests, `+LINE:COLUMN`, multi-file
  progression, clean finish, save-and-finish, recoverable abort, and tmux-pane
  handoff all reuse the running ncurses editor. It intentionally does not
  emulate graphical frame creation, arbitrary Lisp evaluation, or a headless
  editor daemon
- Winner-style window history on `C-c Left` / `C-c Right`: each tab frame keeps
  a bounded 200-layout route over split topology, proportions, displayed
  buffers, selection, and scroll state while retaining live buffer points;
  restored proportions adapt to terminal resizes
- Evil's visual-line policy on `SPC y v`: wrapped buffers swap screen/logical
  `j/k`, `gj/gk`, endpoints, insert/append, operators, registers, paste, and
  `V`, with a focused ncurses gate; Lem hard-wraps at display width rather than
  preferring Emacs word boundaries
- evil-surround defaults (`ys`/`ds`/`cs`/Visual `S`, row-wise Visual Block
  surrounds, padded and compact pairs, XML tags, call and prefix forms) /
  exact configured evil-snipe 2.1.3 /
  comment operator (`gc`) plus Lispyville-compatible,
  delimiter-safe structural editing in Common Lisp, Clojure, Scheme/Racket,
  and Emacs Lisp buffers
- `SPC m e e` evaluates exactly the preceding Common Lisp form through Lem's
  native self-connected SLIME environment in Normal or Visual state; an active
  Visual selection is preserved rather than being evaluated as a region
- Emacs 31-style asynchronous compilation on `SPC c c`, seeded with its exact
  `make -k -jN` default and launched in the originating buffer's directory and
  Direnv-aware environment; the save prompt includes the configured `d` diff,
  output streams live with stateful ANSI styling and navigable diagnostics, and
  Evil Collection's `gj`/`gk`, `[[`/`]]`, Return, `go`, and global `M-g n/p`
  behavior is retained; `go` preserves the log even if the remembered origin
  window was deleted. `gr` recompiles exactly and `C-c C-k` interrupts the
  validated process group. A pinned, minimal-environment guardian broker
  receives the command and captured environment over a private pipe, keeps
  project values out of its argv, and controls a separately anchored command
  group—Lem stores and signals no command PGID. An out-of-group watchdog
  parents and pins the anchor, killing the command group if the broker dies;
  the broker remains responsive if a command stops its parent or whole group.
  A gated exec queues readiness before project startup code can run and drops
  unrelated inherited descriptors before Bash starts.
  Cleanup rejects stale output, terminates validated same-group descendants,
  joins its reader, and reaps the broker; terminal status does not wait for a
  descendant that merely retains inherited stdout
- Expreg-style `SPC v` region growth through lexical tiers and syntax nodes
  from every one of the 23 packaged tree-sitter modes, including balanced list
  interiors inside ordinary and block strings; arbitrary Visual selections use
  their active endpoint and retain contained generated tiers for contraction.
  The configured unbound
  `M-x expreg-contract` walks backward through the generated selection sequence
  and expansion can then move forward again
- configured Avy jumps on `SPC l/a/s` use balanced `a/s/d/f/g/h/j/k/l`
  floating labels over visible line, character, and symbol targets. Normal state
  searches every ordinary or side text window, Visual stays in the current
  window, wrapped and hidden rows are respected, and the display never mutates
  source buffers. During selection, `x/X/t/m/n/y/Y/z` provide Avy's default
  kill, teleport, mark, copy, yank, and zap actions, while `?` shows the action
  keys; `i` reports that no spell backend is configured
- Prescient-style literal/regexp/initialism filtering and persistent learned
  ranking in command, buffer, and custom prompts; file prompts retain Lem's
  path-aware matching and gain the same ranking
- bounded, display-only Marginalia-style context for commands, Lisp symbols,
  buffers, files, loadable Lisp libraries, themes, and bookmarks; metadata
  failures do not alter candidate identity or prevent ordinary selection
- completion candidates keep display, filtering, and insertion text separate;
  final insertion and post-accept callbacks are explicit, tracked replacement
  ranges survive filtering, and stale asynchronous results are rejected
- an Embark-style, typed action dispatcher on `SPC e a` covers contiguous
  regions, URLs, existing local files, identifiers, buffers, native mode menus,
  completion candidates, and search locations; repeating `SPC e a` cycles every
  valid target at point and wraps before dispatch, while completion-local
  `C-c a` can copy without closing the popup or accept the captured candidate
  exactly once
- exact expansion of the configured private Org `jjs` source-block snippet and
  a bounded Yasnippet compatibility engine over the flake-pinned community corpus;
  numbered, anonymous, and nested fields, defaults, mirrors, escapes, safe
  indentation directives, safe date/filename/comment backquotes, common pure
  field transforms, six context conditions, forward/reverse field navigation,
  and a Prescient `M-x` insertion prompt are supported for 2,318 definitions;
  69 definitions remain unavailable, and arbitrary embedded Elisp is never evaluated
- LSP `insertTextFormat=Snippet` candidates enter the same field-session UI
  after `insertText`, `TextEdit`, or `InsertReplaceEdit` acceptance; direct and
  lazily resolved `additionalTextEdits` share the acceptance undo step,
  UTF-16 ranges are decoded consistently, malformed payloads fail closed, and
  server-supplied backquoted Lisp remains inert
- Emacs-like daily navigation/editing: region-or-line `M-j`, a persistent
  300-entry `M-g r` MRU, filterable `C-x C-b`, and asynchronous persistent
  `M-s f` name search with property-backed Return and persistent q/revisit behavior
- project.el-style navigation: persistent automatic project MRU, Git-aware
  tracked/untracked file finding, cancellable bounded asynchronous regexp search,
  and arbitrary-directory command dispatch on `SPC p f/g/p`; `SPC SPC` combines
  lexical project buffers, recent files, and saved roots in fixed, narrowable
  groups with reversible preview-on-move. The project switch menu preserves
  `f/g/d/v/e/o`, with root-correct Git status and close terminal/M-x
  approximations for Emacs's Eshell and arbitrary-command entries
- the Emacs configuration tree's directory-local `C-c i` opens a
  Consult-style Elisp outline in Normal and Emacs states: line-numbered
  headings retain source order, Prescient filtering previews and recenters
  matches, `C-g` restores the exact point/view, Return records a Vi jump, and
  the `.dir-locals.el` declaration is parsed as bounded data without evaluation
- current-buffer Direnv integration is implemented in `src/direnv.lisp`: file
  buffers, derived process-oriented modes, and explicitly marked process output
  buffers update Lem's global process environment, so `PATH` lookup and future
  terminals, formatters, language servers, and other subprocesses use the
  selected directory's environment. Selected file opens provision that
  environment during initial mode hooks without letting direct background file
  loads retarget the editor. Authorization remains explicit through `M-x
  direnv-allow`; `.envrc` files are never allowed automatically. `$WORKDIR`
  remains a separately initialized, startup-cached notes root in
  `src/workspace.lisp` (`scripts/direnv-test.sh`).
- safe global refresh of externally changed clean files, stale-save protection
  for dirty buffers, and private cross-process persistence for file positions,
  bookmarks, reviewed non-secret prompt histories, Vi-aware kills, and separate
  literal and regexp search rings
- retained branching undo with the configured raised payload budgets and a
  three-row Unicode Vundo UI on `SPC u`; live previews support branch, stem,
  saved-node, mark/diff, save, rollback, and accept workflows while ordinary
  `u`/`C-r` continue along the selected branch
- global syntax-aware delimiter/quote pairing and self-insert selection
  replacement, including region wrapping without taking keys away from Paredit or Vi
- official-CLI EditorConfig resolution for steady-state local file buffers,
  including indentation, line endings, write charset, fill column, whitespace,
  and final-newline policy; charset changes affect subsequent writes, and
  `trim_trailing_whitespace=false` or an absent property leaves ws-butler's
  touched-line cleanup in place
- synchronous, CLI-first Apheleia-style formatting for a finite set of
  programming modes: `SPC b f` formats without saving, while normal saves run a
  mapped formatter, when available and successful, before LSP observes the
  final buffer; commands use direct argument vectors with a timeout, and only
  manual formatting can fall back to a ready LSP formatter when no mapped
  backend is available
- Flycheck-style non-LSP diagnostics in programming buffers, with the configured
  Ruff-to-Mypy, Clang, Cargo, gofmt/vet/build, Bash, JSON, and Nix checker
  chains; checks run on mode enable, save, newline, or 500 ms idle change,
  reuse the LSP overlay/list/navigation UI, refuse SOPS plaintext, and yield
  diagnostics completely while an LSP workspace owns the buffer
- automatic per-buffer tree-sitter highlighting from 23 packaged grammar/query
  pairs across existing language modes, with predicate-aware capture
  precedence, Unicode-safe reparsing, and the original mode parser as fallback;
  indentation, LSP, and structural editing remain owned by their normal modes
- dedicated GDScript, Just, Meson, nginx, Nushell, and Typst modes with the
  pinned filename, nginx-content, and Nu-shebang associations; GDScript, Just,
  Nu, and Typst use packaged tree-sitter highlighting while Meson and nginx
  retain bounded TextMate fallbacks. GDScript automatically connects to the
  running Godot language server using the project-derived editor-settings port
- relative line numbers in programming buffers only, matching the Emacs
  `prog-mode` scope while leaving prose and utility buffers clean
- the current Modus Vivendi Tinted palette, truncated long lines, no global
  current-line highlight or startup tab header, `C-x t 2` tabs on demand, and
  six Modus-matched delimiter depths in Common Lisp buffers
- quiet no-file startup into the configured empty Org `*scratch*` buffer, with
  logs below `XDG_CACHE_HOME` and all installed configuration FASLs prebuilt by
  Nix; an installed-wrapper gate covers cold AOT readiness and a 10-second
  repeated-start budget
- `C-x C-b` grouped like the effective Ibuffer setup: ordered, first-match
  org/tramp/emacs/ediff/dired/terminal/help headings, hidden empty groups, and a
  Default tail. Return collapses or expands a heading, while live filtering,
  marks, save/kill, and Return selection remain available
- project-scoped LSP lifecycle: canonical-root isolation, in-flight startup
  deduplication and timeout, explicit buffer ownership with save-as migration,
  project-wide restart, bounded shutdown/disposal, graceful exit when responsive,
  and a one-prompt `SPC p s` workspace-symbol search with Consult's minimum
  input, debounce/throttle timing, annotated kind groups, cancellable incremental
  requests, case-sensitive kind-key-plus-Space narrowing with empty-Backspace
  widening, reversible preview, and Vi-jumplist acceptance; optional Lisp-v2
  connections remain globally selected when loaded
- installed LSP stack for Rust, Python, Markdown, C#, Nix, Go, Terraform, and
  Java, with Python and Java deliberately enabled manually: rust-analyzer,
  pyright, harper-ls, csharp-ls,
  flake-aware nixd, gopls, terraform-ls, and JDTLS, plus the Rust toolchain
  required by rust-analyzer
- a Dape-compatible DAP client on the stock `C-x C-a` prefix, with global
  source, conditional, hit-count, log, and function breakpoints; threads,
  stacks, scopes, variables, watches, evaluation and REPL buffers; stepping,
  restart, run-to-cursor, memory and disassembly requests; and interactive
  `runInTerminal` input. The installed debugpy, Delve, LLDB, and GDB presets
  are exercised against real Python, Go, C, C++, and Rust programs
- Legit (Magit approximation) plus packaged `jj` smart dispatch on `SPC g g`;
  the Jujutsu side is a row-aware porcelain with Majutsu-compatible describe,
  new, edit, undo/redo, confirmed abandon, diff, refresh, and navigation keys,
  while programming buffers get buffer-local Git markers and Git status includes
  navigable tracked-file
  TODO/FIXME rows, and `SPC g t` supplies the audited git-timemachine
  revision-navigation workflow. Legit's Vi-normal file/hunk staging, commit,
  push/pull, branch, and stash workflows are driven end-to-end against isolated
  real remotes by the VCS acceptance gate. Packaged `gh` also backs
  command-accessible GitHub Forge lists, detail views, multiline creation and
  comments, close/reopen actions, external browsing, and cache-only Legit
  status previews without taking ownership of credentials
- metadata-aware Org file/heading and pinned md-roam node completion with
  find/insert/random workflows. A typed missing title opens the configured
  one-key `n/c/p/s/m` roam capture templates; `C-c C-c` finalizes the new Org
  or Markdown note and any deferred link, while `C-c C-k` aborts without a
  file. Root-level roam dailies, journal, and i/t/r capture operate over
  `$WORKDIR`, with public TODO capture over `$PUBLIC_ORG_DIR`
- `M-x org-roam-buffer-toggle` opens the familiar persistent `*org-roam*`
  backlink view in the configured 0.4-width right-side window. It follows the
  nearest file or ID-bearing heading without rescanning on cursor movement,
  includes every Org ID-link occurrence plus resolved md-roam title/alias wiki
  links, and adds Org-roam's separate `Reflinks:` section for citation keys and
  HTTP(S) links matching file or heading `ROAM_REFS`. Both sections show source
  title, outline, and bounded preview; `Return` visits the exact source link or
  citation in the main window. Saving a roam note while the panel is visible
  asynchronously refreshes its bounded snapshot, `g` remains the manual
  refresh for out-of-band changes, and `q` closes the panel without stealing
  or deleting a side window that another feature has replaced
- in-buffer Org scheduling and deadlines on GNU Org's `C-c C-s` and
  `C-c C-d`. The prompt shows the existing date or today as its default,
  accepts absolute dates plus signed day/week/month/year offsets, and uses a
  doubled sign relative to the existing field. A universal prefix removes the
  selected field; edits remain unsaved like the current Emacs Org-buffer path
- ordinary active and inactive Org timestamps on GNU Org's `C-c .` and
  `C-c !`. They insert or replace ISO/relative dates, optional times and time
  ranges, preserve repeater/warning suffixes, accept a universal prefix to
  include the current time, and insert the current timestamp directly with a
  double universal prefix. `Shift-Left`/`Shift-Right` and the terminal-safe
  `C-c Left`/`C-c Right` move a timestamp by days or cycle a heading's TODO
  state according to context
- GNU Org source-block editing on `C-c '`. The block body opens without its
  delimiters in the configured language mode while preserving indentation and
  Org's protective-comma convention. `C-c '` writes back and exits, `C-c C-k`
  aborts, and `C-x C-s` writes back, saves the Org file, and keeps editing;
  ordinary exit remains an unsaved one-step Org-buffer edit
- configured Org Babel execution on `C-c C-c` for Bash/Shell, Python, C/C++,
  Nix, SQLite, and PostgreSQL SQL blocks. Shell, Python, C, Nix, and SQL ask
  before running; SQLite follows the Emacs configuration's trusted-note
  exemption. Results replace an adjacent `#+RESULTS:` atomically as colon
  output or Org database tables, `:results none` stays buffer-silent, `:dir`
  and preamble header properties are honored, and execution inherits the
  active Direnv environment. Emacs Lisp blocks fail explicitly rather than
  being mis-evaluated as Common Lisp
- configured Org HTML export and publishing through `C-c C-e`: `h h` exports
  the live buffer beside its source, while the publishing branch and
  `lem-yath-org-publish` reproduce the recursive `org-roam-notes`, `static`,
  and composite projects. Publishing is incremental, forceable, cancellable,
  and backgrounded; Org ID and `.org` file links become relative HTML links,
  assets retain the configured `$WORKDIR` layout, and every output is an
  atomic bounded write. Pandoc supplies the broad Org-to-HTML conversion, so
  the result is deliberately not claimed to be byte- or CSS-compatible with
  GNU Org's `ox-html`
- a grouped Org agenda over the exact existing work/public/public-MCP roots,
  with top-level file scope, ordinary and repeating active-timestamp events,
  modal Return/g/q navigation, and Evil-Org-style `t` fast TODO selection plus
  `J`/`K` GNU Org priority cycling, `C-c C-s`/`C-c C-d` planning edits, and
  `ct`/`C-c C-q` completion-backed local-tag replacement and clearing,
  all with immediate source persistence. Evil-Org `dA` archives a complete
  subtree to Org's default sibling `_archive` file, while `da` confirms first;
  archive metadata and both files are persisted destination-first. GNU Org's
  `C-c C-w` completes over the current file's level-one headings and
  refiles the selected complete subtree as the target's final child. Agenda
  clocking preserves the effective state split in the Emacs setup: Vi `I/O`
  controls one GNU Org-style global clock, while C-z Emacs-state `I/O` starts
  concurrent delegated clocks on the current or bulk-marked rows and closes
  marked clocks—or every open clock across agenda files when nothing is
  marked. Evil/base mark keys render `>` prefixes and keep live source points
  across clock insertions and agenda refreshes.
- streaming OpenRouter LLM client plus native Claude/Codex/Grok JSON event
  backends, with per-backend session resume, rendered agent activity, guarded
  single-request lifecycle, abort (`SPC g a`), and fresh-session (`SPC g n`)
- gptel-style `SPC g l`/`SPC g L` menu with private named presets and
  region-or-buffer handoff to Claude or ChatGPT; the built-in `quick-lookup`
  preset matches the Emacs startup model, system prompt, temperature, and
  token cap, `project-readonly` opts OpenRouter into the configured five-tool
  project inspection loop, `web-readonly` adds the fetch MCP server,
  `github-readonly` adds the configured read-only GitHub MCP toolsets when a
  token is available, and `grok-build` selects the native Grok CLI backend
- project-aware `C-c c` Claude Code buffer that opens ready for input, prefers
  the configured `ccr code` argv with a `claude` fallback, renders native text
  and tool events, and resumes the same session on later prompts. It starts an
  authenticated loopback MCP bridge through a private mode-0600 config so
  Claude can inspect the live editor and submit whole-buffer `openDiff`
  proposals; focused `y` accepts one undoable edit and `q` rejects it. The
  Claude allowlist excludes direct mutation, arbitrary editor commands, Lisp
  evaluation, and unrestricted `file://` resources
- app ports under `lem-yath/src/apps/`: agenda, citar, devdocs, elfeed
  (Miniflux fever), notmuch, PDF/EPUB documents, pg, salta, timemachine,
  llm-cli, llm-presets, claude-code
- ordinary `.pdf` and `.epub` opens stay inside Lem: PDFs expose bounded
  Poppler text one page at a time, while EPUBs become bounded Markdown with
  chapter navigation. Both are read-only, never visit or overwrite the binary
  source, and retain `o` for the desktop viewer; Notmuch PDF attachment rows
  use the same ephemeral reader and remove their private extraction on `q`.
  The terminal path deliberately omits pixel layout, images, CSS, annotations,
  forms, and other visual-only document semantics
- `M-x pgmacs` prompts for a password-free libpq connection string, lists
  PostgreSQL tables, and opens bounded psql-backed query results; `g` refreshes
  and `q` returns to the source buffer, while `.pgpass` supplies credentials

Saved LLM presets live in `$XDG_CONFIG_HOME/lem-yath/llm-presets.json` (or
`~/.config/lem-yath/llm-presets.json`) with private directory and file modes.
They retain the local-tool opt-in and configured MCP server names as well as
backend, model, system message, temperature, and token cap.
`project-readonly` captures the originating
project before opening the shared output buffer and exposes only
`project_root`, `list_project_files`, `search_project`, `read_project_file`,
and the Lem/Common Lisp translation of `read_emacs_symbol`. Calls are bounded,
file reads require canonical in-project regular UTF-8 text, and no write,
arbitrary-command, or shell tool exists.
`web-readonly` and `github-readonly` reuse that bounded model loop while
starting persistent newline-delimited stdio MCP sessions. The fetch path uses
the pinned `uvx mcp-server-fetch`; GitHub uses direct Docker argv, normalizes
the token only in its restricted child environment, passes only the configured
`context,repos,issues,pull_requests,users` toolsets to a read-only container,
and never places the token in argv. MCP tools are namespaced as
`mcp__SERVER__TOOL`, results remain visible, and LLM abort also interrupts a
blocked server call. `M-x lem-yath-llm-mcp-connect-server`,
`lem-yath-llm-mcp-connect-default`, `lem-yath-llm-mcp-status`, and
`lem-yath-llm-mcp-stop-all` provide the configured hub lifecycle.
The handoff menu preserves the Emacs 13,000-character context cap and prefers
the active region; ChatGPT handoffs also copy the exact prompt to the kill
ring. `SPC g i` retains the separate ad-hoc instruction prompt.

### DAP quick start

Open a saved source file, put point on an executable line, press `C-x C-a b`
to toggle a breakpoint, then `C-x C-a d` to choose and start an adapter.
`debugpy` launches the current Python file and `dlv` launches the nearest
jj/Git root (or the source directory outside version control). For Rust, C,
or C++, build a debuggable file named `a.out` at that same resolved root before
choosing `lldb-dap` or `gdb`.

The main runtime keys retain Dape's defaults: `n` steps over, `s` steps in,
`o` steps out, `c` continues, `p` pauses, `i` opens the session view, `x`
evaluates an expression, `R` opens the REPL, `r` restarts, and `q` terminates
the foreground session. Every key follows the `C-x C-a` prefix. A Lem instance
already running when this source changes must be restarted to load the update.

See `docs/port-map.md` for the per-package disposition and known divergences.
Use `docs/parity-ledger.tsv` for behavior-level planning: its dispositions are
`exact`, `approximation`, `gap`, `n-a`, and `unassessed`. The validator accepts
`exact` only with automated evidence or an explicitly approved manual record.

## Testing

`nix flake check` runs the package, compile, boot, asynchronous compilation,
integrated terminal, reusable editor server/client,
prompt and in-buffer completion, completion-lifecycle, automatic-completion,
Embark-style actions,
editing, formatting, Orderless completion, snippets, LSP snippets, real installed
language-server handshakes (including an external Godot TCP server), tree-sitter
highlighting, real DAP adapter
workflows, daily-workflows, Direnv environment switching,
electric-editing, grouped-buffer-list, UI parity, host-gated business presentation,
project navigation and outline, VCS and Forge,
persistence, bookmarks,
retained undo/Vundo, project-scoped LSP lifecycle, LLM key dispatch,
credential-free backend streaming/resume, private preset persistence, web
handoff, read-only fetch/GitHub MCP client sessions, integrated Claude Code
interaction, and authenticated MCP diff review,
cursor/state parity, evil-snipe and Avy parity, screen-line/Evil parity, notes,
roam, roam backlinks, native Org, Org planning/timestamps, agenda, agenda-clock, and
parity-ledger checks. The ledger can also be
validated directly, and the
interactive TUI checks are exposed as flake apps:

```sh
nix flake check
python3 scripts/check-parity-ledger.py
nix run .#compile-check
nix run .#compilation-test
nix run .#terminal-test
nix run .#server-test
nix run .#boot-test
nix run .#startup-test
nix run .#completion-test
nix run .#prompt-completion-test
nix run .#completion-lifecycle-test
nix run .#auto-completion-test
nix run .#actions-test
nix run .#llm-keybinding-test
nix run .#llm-backend-test
nix run .#llm-workflow-test
nix run .#llm-tools-test
nix run .#claude-code-test
nix run .#claude-bridge-test
nix run .#cursor-state-test
nix run .#snipe-test
nix run .#avy-test
nix run .#screen-line-test
nix run .#orderless-completion-test
nix run .#snippet-test
nix run .#lsp-snippet-test
nix run .#lsp-project-test
nix run .#real-lsp-test
nix run .#gdscript-test
nix run .#tree-sitter-test
nix run .#dap-test
nix run .#project-navigation-test
nix run .#project-outline-test
nix run .#persistence-test
nix run .#bookmark-test
nix run .#vundo-test
nix run .#editing-test
nix run .#formatting-test
nix run .#daily-workflows-test
nix run .#direnv-test
nix run .#electric-editing-test
nix run .#ui-parity-test
nix run .#business-visual-test
nix run .#vcs-test
nix run .#jj-porcelain-test
nix run .#forge-test
nix run .#documents-test
nix run .#citar-test
nix run .#devdocs-test
nix run .#pg-test
nix run .#elfeed-test
nix run .#notmuch-test
nix run .#salta-test
nix run .#notes-test
nix run .#roam-test
nix run .#roam-backlink-test
nix run .#org-test
nix run .#org-planning-test
nix run .#org-timestamp-test
nix run .#org-source-edit-test
nix run .#agenda-test
nix run .#agenda-clock-test
nix run .#interactive-test
nix run .#structural-test
nix run .#lisp-eval-test
```

The underlying scripts remain parallel-safe via `LEM_YATH_CHECK_ID` and accept
`LEM_BIN`/`LEM_YATH_SOURCE` overrides for direct debugging.

To keep builds and real TUI sessions off a weaker laptop, mirror the current
worktree to the dedicated cache directory on `ex44` and run the full gate there:

```sh
./scripts/test-on-ex44.sh
```

Pass `check`, `compile`, `compilation`, `terminal`, `server`, `boot`, `completion`, `prompt-completion`,
`completion-lifecycle`, `auto-completion`, `actions`, `editing`,
`daily-workflows`, `direnv`, `llm-keybinding`, `llm-backend`, `llm-workflow`, `llm-tools`, `claude-code`, `lisp-eval`, `orderless-completion`, `snippets`, `lsp-snippets`,
`lsp-project`, `real-lsp`, `tree-sitter`, `dap`, `project-navigation`, `project-outline`, `persistence`, `bookmarks`,
`vundo`, `electric-editing`, `ui-parity`, `business-visual`, `cursor-state`, `snipe`, `avy`,
`documents`, `notmuch`, `interactive`, `structural`, `roam`, `roam-backlinks`, or
`notes` to run only that gate.
`LEM_YATH_TEST_HOST` and `LEM_YATH_REMOTE_ROOT` override the SSH host and remote
cache directory.
