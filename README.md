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
a fresh configured Lem instead. The running editor sets `GIT_EDITOR` to the
client's non-focusing form and fills
otherwise-unset `VISUAL`/`EDITOR` for its child processes; a parent shell can
opt in with `export EDITOR=lemclient VISUAL=lemclient GIT_EDITOR=lemclient`.

## What's in the port

- vi-mode with one shared Space leader in normal and visual states; every
  feasible chord is preserved. Globally enabled Which-Key-style guidance
  composes the live global, mode, and Vi-state maps for every ordinary
  keymap-backed prefix, honors dispatcher shadowing, and shows sorted raw command or `+prefix`
  labels in width-bounded, cyclic multi-column pages capped at one quarter of
  the frame height. Once a page is visible, `C-h n/p` changes pages, `C-h d`
  toggles first-line command documentation, `C-h h` opens focused prefix help,
  `C-h u` backs up one prefix, `C-h a` aborts, and `C-h 1..9` supplies an
  argument; pre-popup `C-h` opens prefix help directly.
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
- ordinary directory visits inherit the configured hidden-detail Dirvish
  presentation, retain the visible path row, suppress its redundant blank row,
  and show the pinned ascending `name|mtime`, selected-symlink target, and
  current/total footer data. `M-x dirvish` adds the pinned full-frame shape with
  one parent pane, the active directory, and a selection-following preview;
  text reads are raw, bounded, and mode-hook-free, directories list at most 200 children, and
  binary or special files show metadata without being opened. Cancellable
  background dispatch lists at most 200 archive members without extraction,
  renders the first PDF page, converts bounded EPUB text, and reports
  image/media metadata under a 3-second/512-KiB process budget. `Return` restores
  the prior layout before visiting a file, `q` restores it without visiting,
  and `M-x dirvish-layout-toggle` keeps the directory while collapsing the
  companion panes
- Evil's visual-line policy on `SPC y v`: wrapped buffers swap screen/logical
  `j/k`, `gj/gk`, endpoints, insert/append, operators, registers, paste, and
  `V`; a patched shared geometry layer prefers Emacs-style space/tab boundaries
  with exact-width fallback for long tokens, covered by a focused ncurses gate
- evil-surround defaults (`ys`/`ds`/`cs`/Visual `S`, row-wise Visual Block
  surrounds, padded and compact pairs, XML tags, call and prefix forms) /
  exact configured evil-snipe 2.1.3 /
  comment operator (`gc`) plus Lispyville-compatible,
  delimiter-safe structural editing in Common Lisp, Clojure, Scheme/Racket,
  and Emacs Lisp buffers
- GNU-style rectangle editing: `C-x SPC` retains virtual rectangular corners;
  `C-x r k`/`M-w`/`d`/`c`/`o`/`t`/`N`/`y` cover the configured kill, copy,
  delete, clear, open, string, number, and yank workflows, while `M-j`
  duplicates the live rectangle to its right with count and one-step undo
- `SPC m e e` evaluates exactly the preceding Common Lisp form through Lem's
  native self-connected SLIME environment in Normal or Visual state; an active
  Visual selection is preserved rather than being evaluated as a region
- `M-x calc` opens a reusable, read-only GNU-style RPN stack in a compact
  bottom window and Normal state. Digit and algebraic entry use the configured
  non-Evil prompt, including transactional Escape; the common Evil-Collection
  arithmetic, stack, undo/redo, copy/yank, angle, precision, and quit bindings
  use packaged `qalc` evaluation. GNU Calc's advanced symbolic, matrix,
  programming, graphing, trail, and auxiliary interfaces remain outside the
  bounded everyday-calculator port
- GNU So Long parity protects newly visited programming, CSS/XML, and
  fundamental-equivalent files before their ordinary mode machinery runs when
  any line exceeds 10,000 UTF-8 bytes. The buffer opens wrapped and read-only
  without parsers, LSP, lint, gutters, DAP, or Paredit; `C-c C-c` restores the
  original mode and `M-x global-so-long-mode` toggles protection for later
  visits. Plain-text and document modes retain their ordinary behavior
- Files strictly larger than the configured 50 MiB threshold prompt before
  Lem reads or allocates their buffer. `y` opens normally, `n` aborts without
  creating a visited buffer, and `l` opens byte-preserving Fundamental mode
  without file hooks; literal save and external revert round-trip every byte
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
  from every one of the 24 packaged tree-sitter modes, including balanced list
  interiors inside ordinary and block strings; arbitrary Visual selections use
  their active endpoint and retain contained generated tiers for contraction.
  The configured unbound
  `M-x expreg-contract` walks backward through the generated selection sequence
  and expansion can then move forward again
- configured Avy jumps on `SPC l/a/s` use balanced `a/s/d/f/g/h/j/k/l`
  floating labels over visible line, character, and symbol targets. Normal state
  searches every ordinary or side text window, Visual stays in the current
  window, wrapped and hidden rows are respected, and the display never mutates
  source buffers. During selection, `x/X/t/m/n/y/Y/i/z` provide Avy's default
  kill, teleport, mark, copy, yank, spell-correction, and zap actions, while
  `?` shows the action keys. The flake-packaged `en_US` Aspell backend offers
  Prescient-filtered corrections for a selected word or every word on a
  selected line. In the correction prompt, `0`–`9` choose proposals, `Space`
  keeps the word once, `a` accepts it for the Lem session, `i` saves it to
  Aspell's personal dictionary shared with Emacs, and `r` opens a free-text
  replacement (also available when Aspell has no proposal)
- Prescient-style filtering and persistent learned ranking in command, buffer,
  and custom prompts; `M-s a/f/i/l/P/p/r/'/c` changes anchored, fuzzy,
  initialism, literal, literal-prefix, prefix, regexp, character-fold, and
  smart-case behavior for the current Prescient-backed prompt, while
  `C-u M-s KEY` selects one filter exclusively. File prompts retain Lem's
  path-aware matching and gain the same ranking. Standard Emacs line,
  character, word, kill, yank, and transpose keys remain prompt-local while
  completion is visible
- bounded, display-only Marginalia-style context for commands, Lisp symbols,
  faces, buffers, files, loadable Lisp libraries, themes, and bookmarks; metadata
  failures do not alter candidate identity or prevent ordinary selection.
  Annotation columns use the pinned 20-column/10-cell Marginalia alignment
  policy for wide and narrow labels, while documentation and path fields use
  terminal-relative, direction-aware ellipsis. Already-open prompt popups
  reflow after terminal resizing without changing their input or focused item
- exact `M-x describe-face` selection over live Lem attributes, with effective
  theme properties in the candidate row and a styled, read-only Helpful buffer
  whose `s` command visits the defining form
- completion candidates keep display, filtering, and insertion text separate;
  final insertion and post-accept callbacks are explicit, tracked replacement
  ranges survive filtering, and stale asynchronous results are rejected
- an Embark-style, typed action dispatcher on `SPC e a` covers contiguous
  regions—including Evil Visual Blocks expanded exactly like the pinned
  Evil/Embark path—URLs, existing local files, identifiers, buffers, native mode
  menus, completion candidates, and search locations; repeating `SPC e a`
  cycles every valid target at point and wraps before dispatch, while completion-local
  `C-c a` can copy without closing the popup or accept the captured candidate
  exactly once; external URL/file opening, buffer copy/save/revert/kill, and
  ready-project LSP code actions are physically covered
- exact expansion of the configured private Org `jjs` source-block snippet and
  a bounded Yasnippet compatibility engine over the flake-pinned community corpus;
  numbered, anonymous, and nested fields, defaults, mirrors, escapes, safe
  indentation directives, safe date/filename/comment backquotes, common pure
  field transforms, six context conditions, literal choice prompts with the
  pinned initial-field auto-advance behavior, forward/reverse field navigation,
  bounded undo/redo field-session revival, and a Prescient `M-x` insertion
  prompt are supported for 2,327 definitions; 60 definitions remain
  unavailable, and arbitrary embedded Elisp is never evaluated
- LSP `insertTextFormat=Snippet` candidates enter the same field-session UI
  after `insertText`, `TextEdit`, or `InsertReplaceEdit` acceptance; direct and
  lazily resolved `additionalTextEdits` share the acceptance undo step,
  UTF-16 ranges are decoded consistently, malformed payloads fail closed, and
  server-supplied backquoted Lisp remains inert; a throwing mutation hook rolls
  the complete acceptance back to its original text, point, and undo history
- Emacs-like daily navigation/editing: region-or-line `M-j`, a persistent
  300-entry `M-g r` MRU, filterable `C-x C-b`, asynchronous persistent
  `M-s f` name search, and directory-scoped `M-s g` ripgrep with read-only,
  staged-edit results
- project.el-style navigation: persistent automatic project MRU, Git-aware
  tracked/untracked file finding, cancellable bounded asynchronous regexp search,
  and arbitrary-directory command dispatch on `SPC p f/g/p`; `SPC SPC` combines
  lexical project buffers, recent files, and saved roots in fixed, narrowable
  groups with reversible preview-on-move. Project additions, MRU promotions,
  and removals transact against the latest shared history, so simultaneous Lem
  instances do not lose or resurrect entries. The project switch menu preserves
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
- prompt Linux filesystem-notification refresh of externally changed clean
  local files without requiring a keypress, with a bounded shared-directory
  watcher plus the configured five-second global safety scan; unsupported files
  and non-file adapters rely on that scan. Directory refresh retains the exact
  selected entry, cursor column, and surviving marks. Stale-save protection
  for dirty buffers, and private cross-process persistence for file positions,
  selected directory entries,
  bookmarks, reviewed non-secret prompt histories, Vi-aware kills, and separate
  literal and regexp search rings; baseline-aware merging preserves independent
  additions without letting a stale editor resurrect entries cleared elsewhere
- retained branching undo with the configured raised payload budgets and a
  three-row Unicode Vundo UI on `SPC u`; live previews support branch, stem,
  counted and saved-node navigation, mark/diff, save, rollback, and accept
  workflows with historical source-point restoration while ordinary `u`/`C-r`
  continue along the selected branch
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
- automatic per-buffer tree-sitter highlighting from 24 packaged grammar/query
  pairs across existing language modes, with predicate-aware capture
  precedence, Unicode-safe reparsing, and the original mode parser as fallback;
  indentation, LSP, and structural editing remain owned by their normal modes
- dedicated GDScript, Just, Meson, NASM, nginx, Nushell, and Typst modes with the
  pinned filename, nginx-content, and Nu-shebang associations; GDScript, Just,
  Nu, and Typst use packaged tree-sitter highlighting while Meson and nginx
  retain bounded TextMate fallbacks. GDScript automatically connects to the
  running Godot language server using the project-derived editor-settings port
- Meson completion with the pinned global, method, and per-call keyword tables,
  Corfu documentation, idle signatures, apostrophe-only strings, and
  structure-aware two-column indentation
- nginx editing with the pinned double-quote/comment syntax, directive,
  rewrite-result, variable, constant, and block-context highlighting,
  backward-scanned four-column indentation, newline-and-indent, and a final
  newline on save unless EditorConfig explicitly disables it
- relative line numbers in programming buffers only, matching the Emacs
  `prog-mode` scope while leaving prose and utility buffers clean
- the current Modus Vivendi Tinted palette, truncated long lines, no global
  current-line highlight or startup tab header, `C-x t 2` tabs on demand, and
  six Modus-matched delimiter depths in Common Lisp buffers
- quiet no-file startup into the configured empty Org `*scratch*` buffer with
  buffer-local LLM conversation mode and `C-c Return`; replies stream at the
  tracked send position and leave the next `* ` prompt. Later sends reconstruct
  separate user/assistant turns, and Org user text—including selected regions
  and source/result pairs—is converted to bounded Markdown before dispatch.
  Fixed-width User/Assistant badges mark semantic turns, the modeline reports
  the role at point, assistant spans receive a terminal-safe tint, and a
  synthetic cursor follows streamed chunks without entering the transcript;
  `M-x lem-yath-llm-role-visuals-toggle` controls the role presentation.
  `M-x lem-yath-llm-request-trace-toggle` records opt-in request, backend,
  chunk-size, completion, abort, and kill metadata, and
  `M-x lem-yath-llm-request-trace-open` opens the newest record in a read-only
  `*gptel-requests*` viewer. Trace records include only a normalized
  160-character prompt preview—never credentials, headers, payloads, response
  text, or tool data. Logs remain below
  `XDG_CACHE_HOME` and all installed configuration FASLs are prebuilt by Nix;
  installed-wrapper gates cover cold AOT readiness, a 10-second repeated-start
  budget, tracked insertion, abort, and read-only fallback
- `C-x C-b` grouped like the effective Ibuffer setup: ordered, first-match
  org/tramp/emacs/ediff/dired/terminal/help headings, hidden empty groups, and a
  Default tail. The default view includes mark/status, fixed-width elided name,
  right-aligned size, fixed-width elided mode, and file columns. Return collapses
  or expands a heading. The effective Evil-Collection `o a/v/s/f/m`, `o i`, and comma sort controls
  work inside every group, while backtick rotates between the detailed and
  compact name/file formats. Evil-Collection-style `s m/n/f/b/.` enter live,
  case-insensitive regexp filters for mode, name, full filename, basename, or
  extension; Return pushes the filter and Escape cancels pending input.
  `s RET` completes over all registered exact major modes (including
  comma-separated choices), `s M` includes active parent modes, `s *` selects
  GNU-style starred names, `s E` selects live process owners, `s F` matches
  file or working directories, `s </>` apply strict character-size limits,
  and `s c` matches buffer content case-insensitively. Content scanning skips
  buffers above 16 million characters.
  `m/u/Backspace/U/t/~`
  manage ordinary `>` marks, `d` assigns distinct `D` deletion marks, `x`
  executes those deletions, and `S` saves marked buffers. The starred
  `* *`/`* s`, `* m`, `* u`, `* r`, `* /`, `* e`, `* h`, and `* z` catalog
  marks visible special, modified, unsaved, read-only, directory, dissociated,
  help, or compressed-file buffers. `* M` marks an exact used major mode, while
  `% n/m/f/g` mark visible rows by name, displayed mode, file, or bounded
  content regexp; invalid regexps change no marks. `.` marks buffers whose last
  window display was strictly more than the configurable 72-hour default ago;
  buffers never displayed in a window remain unmarked.
  `{`/`}` traverse
  ordinary marks; `M`, `T`, and `R` toggle modified/read-only state or rename
  marked buffers uniquely, `V` confirms once before safely reverting the
  ordinary-marked buffers (or implicitly marking the current row), and `X`
  buries the focused buffer. Deletion-marked buffers are excluded from those
  ordinary-mark operations. `gj/gk`,
  Tab/backtab, `C-j/C-k`, `]]/[[`, and `q` provide the corresponding modal row,
  group, and quit navigation. `M-j` completes over the displayed group headings
  without changing collapse state. `C-o` displays the focused buffer in another
  ordinary window while retaining chooser focus, and `M-o` visits it in a sole
  ordinary window. `A`/`gv` stack ordinary-marked buffers in balanced windows;
  `gV` places them side by side. Those view commands exclude `D` and fall back
  to the unmarked current row. `gR` redisplays the captured snapshot, `gr`
  rebuilds it from live buffers without losing marks or filters, `yb/yf` copy
  the focused buffer name or visiting filename, and `go` visits it in another
  window. `-` and `+` stage session-local hide and force-show name regexps;
  `gR` leaves the current rows unchanged and `gr` activates them, with show
  rules overriding hide rules and ordinary filters. `K` hides visible
  ordinary-marked rows through `gR`; `gr` restores those rows unmarked while
  preserving unrelated `D` marks. `J` and `M-g` complete over the snapshot, reveal collapsed target
  groups, and respect the active Ibuffer filter stack. `=` opens a focused,
  read-only unified diff for ordinary-marked file buffers or the unmarked
  current row; it ignores non-file and deletion-marked buffers and fails
  without replacing the prior diff when an associated file is missing. The
  filter stack also supports modified and visiting-file filters on `s i/v`,
  top-filter negation and removal on `s !/p`, and complete disable on `s /`.
  `O` and the effective Evil-Collection chord `M-s a C-o` run a persistent,
  smart-case Occur over ordinary marks in GNU's reverse display order, exclude
  `D`, and visibly mark the current row when no ordinary marks exist. The
  read-only `*Occur*` result supports multiline matches, numeric context,
  same-line grouping, live source points, Return/`g o` visits,
  `M-Return` no-select display, and `gj/gk` or `C-j/C-k` match navigation while
  leaving the chooser selected when first displayed. Invalid regexps preserve
  the previous result, zero matches remove it, and killed sources fail closed.
  `M-s a C-s` and `M-s a M-C-s` start literal or regexp incremental search over
  explicit ordinary marks in display order, excluding `D`. Input pauses in the
  first buffer; `C-s`/`C-r` continue and wrap through the marked set, Return
  keeps the match and search history, and `C-g` restores the first buffer's
  starting point.
  Evil Collection's `Q` and `I` run smart-case literal or regexp
  query-replace over ordinary marks in display order, excluding `D` and
  visibly marking the current row when no ordinary marks exist. Each buffer is
  queried from its beginning with the chooser hidden; `y`/Space replaces,
  `n`/Backspace skips, `!` replaces the rest of only that buffer, `q`/Return
  moves on, and `.` replaces once before moving on. The chooser, focus, marks,
  source window, and point return afterward, and each affected buffer is one
  undo unit. Lowercase searches transfer lower, all-caps, or initial-cap case
  patterns; uppercase searches are case-sensitive and keep exact replacement
  case. Regexp replacement expands `\&`, `\1`–`\9`, `\\`, and a per-buffer
  `\#` count. Read-only sets, invalid regexps or replacement directives, and
  regexps with empty matches fail before mutation. GNU Lisp-evaluated `\,`,
  per-match `\?` editing, zero-width replacement, and advanced interactive
  actions remain gaps.
- project-scoped LSP lifecycle: canonical-root isolation, in-flight startup
  deduplication and timeout, explicit buffer ownership with save-as migration,
  project-wide restart, bounded shutdown/disposal, graceful exit when responsive,
  Eglot-style aggregate work-done percentages in every attached buffer's
  modeline with independent two-second completion expiry,
  Eglot-compatible dynamic `workspace/didChangeWatchedFiles` registration
  backed by bounded Linux inotify watches, including LSP globs,
  `RelativePattern`, watch-kind masks, open-buffer suppression, newly created
  directories, and complete unregister/restart/exit teardown,
  and a one-prompt `SPC p s` workspace-symbol search with Consult's minimum
  input, debounce/throttle timing, annotated kind groups, project-scoped
  fan-out across every active language server, progressive score-ranked
  results, isolated server failures, all-request cancellation, case-sensitive
  kind-key-plus-Space narrowing with empty-Backspace widening,
  source-workspace-aware reversible preview, and Vi-jumplist acceptance;
  optional Lisp-v2 connections remain globally selected when loaded
- generic `M-x imenu` for Eglot document symbols, Lisp-family definitions,
  native Org headings, native Markdown headings and footnotes, and nested
  Python functions/classes plus native Java, C, C++, Rust, Go, GDScript, Typst,
  Terraform, Just, and NASM declarations
  when no ready LSP symbol provider is available, with GNU Imenu's successive hierarchy
  prompts, Prescient filtering, exact source placement, configured
  recenter-only feedback, and Vi `C-o` return
- installed LSP stack for Rust, Python, Markdown, C#, Nix, Go, Terraform, and
  Java, with Python and Java deliberately enabled manually: rust-analyzer,
  pyright, harper-ls, csharp-ls,
  flake-aware nixd, gopls, terraform-ls, and JDTLS, plus the Rust toolchain
  required by rust-analyzer. Rust, Python, Markdown, C#, Nix, Go, and Terraform
  use the configured project.el Git root, including merged submodules and
  separate linked worktrees, with their language marker as a non-Git fallback;
  nixd receives the flake-derived outer `nixd` settings through its real
  `workspace/configuration` request; Go and Terraform use Eglot's stdio commands
  rather than upstream TCP specs
- a Dape-compatible DAP client on the stock `C-x C-a` prefix, with global
  source, conditional, hit-count, log, and function breakpoints; threads,
  stacks, scopes, variables, watches, evaluation and REPL buffers; stepping,
  restart, run-to-cursor, memory and disassembly requests; and interactive
  `runInTerminal` input. The installed debugpy, Delve, LLDB, and GDB presets
  are exercised against real Python, Go, C, C++, and Rust programs
- Legit (Magit approximation) plus packaged `jj` smart dispatch on `SPC g g`;
  the Jujutsu side is a row-aware porcelain with a Majutsu-compatible shared
  multiline editor for describe and working-copy commit, prompt-based `o` plus
  direct `O`/`I`/`A` child/before/after creation, working-copy and
  relationship-aware log navigation, Majutsu-compatible `a` absorb with
  selected or prompted endpoints, fileset scoping, and immutable override,
  Majutsu-style squash with selected or prompted endpoints, filesets,
  keep-emptied/immutable controls, and native file/hunk/changed-line selection, edit,
  confirmed selected-row rebase with branch/subtree/exact/insert modes,
  Majutsu-compatible `_` revert with source-revset and onto/after/before controls,
  `R` restore with row toggles, arbitrary revsets, filesets, descendant control,
  and a native `- i` file/hunk/changed-line selector,
  Majutsu-compatible `y` placement and immediate `Y` duplicate workflows,
  a read-only `S` split view with file, hunk, and changed-line selection plus
  destination and parallel-layout controls,
  visible local bookmarks with create/set/move/rename/delete/forget/list,
  undo/redo, confirmed abandon, diff, refresh, and navigation keys,
  while programming buffers get buffer-local Git markers and Git status includes
  navigable tracked-file
  TODO/FIXME rows, and `SPC g t` supplies the complete configured
  Evil-collection git-timemachine map, including revision selection, hash copy,
  and blame. Legit's Vi-normal file/hunk staging, commit,
  push/pull, branch, and stash workflows are driven end-to-end against isolated
  real remotes by the VCS acceptance gate. Interactive reword/fixup uses an
  owner-private, signal-free sequence-editor handshake and Git's real commit
  editor through the reusable Lem client; consecutive reword sessions are
  physically covered. An `edit` stop can be changed and staged through Legit,
  amended with Magit's `c a` in a prefilled commit buffer, and completed with
  `r c`. Ordinary commits use the matching `c c` dispatch. Magit's core
  cherry-pick dispatch is also present in status and diff panes: `A A` picks
  or continues, `A a` applies without committing or aborts, and `A s` skips
  an active conflicting pick; unmerged files remain visible and stageable in
  Legit while the sequence is stopped.
  Packaged `gh` also backs
  command-accessible GitHub Forge lists, detail views, multiline creation and
  comments, close/reopen actions, external browsing, and cache-only Legit
  status previews without taking ownership of credentials
- metadata-aware Org file/heading and pinned md-roam node completion with
  find/insert/random workflows. A typed missing title opens the configured
  one-key `n/c/p/s/m` roam capture templates; `C-c C-c` finalizes the new Org
  or Markdown note and any deferred link, while `C-c C-k` aborts without a
  file. In Markdown notes below the roam root, `C-c C-o` follows a unique
  `[[Title]]`, `[[label|Alias]]`, or `[[ID]]` and opens the same non-inserting
  capture flow for a missing target; ambiguous, escaped, and fenced targets
  fail closed. From Normal state, `C-z C-u C-c C-o` supplies the source
  package's other-window prefix behavior. Root-level roam dailies operate over
  `$WORKDIR`; Normal or Visual `SPC n j j` opens the configured compact-date
  journal buffer, retains one exact daily title, and appends a text-ready
  `* HH:MM ` entry in Normal state
- `SPC o` opens the configured one-key `i/t/p/r` Org capture selector and an
  editable Org buffer at `%?`. Active Visual text and a local file/line source
  link fill `%i` and `%a`; `C-c C-c` safely inserts and saves the selected
  inbox, TODO, public TODO, or reading target, while `C-c C-k` aborts and
  restores the exact origin state
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
  selected field. An active Visual region applies the command to every nested
  headline with one prompt per headline; `C-z` preserves that region for
  universal-prefix removal. Edits remain unsaved like the current Emacs
  Org-buffer path
- ordinary active and inactive Org timestamps on GNU Org's `C-c .` and
  `C-c !`. They insert or replace ISO/relative dates, optional times and time
  ranges, preserve repeater/warning suffixes, accept a universal prefix to
  include the current time, and insert the current timestamp directly with a
  double universal prefix. `Shift-Left`/`Shift-Right` and the terminal-safe
  `C-c Left`/`C-c Right` move a timestamp by days or cycle a heading's TODO
  state according to context
- the active `org-modern-mode` hook as a display-only terminal projection:
  fold-state heading symbols, TODO/priority/tag labels, list bullets and
  checkboxes, tables and rules, block/keyword markers, timestamps, and targets
  render without changing source bytes or cursor cells. Source-block bodies
  remain literal, and `M-x org-modern-mode` toggles the presentation per buffer
- the configured `M-x org-download-yank` and `M-x org-download-clipboard`
  workflows. URL or local `file:` images receive org-download's timestamped
  names under startup-cached `$WORKDIR/media/`, a seconds-precise
  `#+DOWNLOADED:` annotation, and a source-relative Org link. Linux clipboard
  capture selects `wl-paste` on Wayland or `xclip` otherwise and creates the
  current heading ID. Transfers use direct argument vectors, time and size
  bounds, signature validation, private temporary files, and an atomic
  one-step buffer edit; undo removes the ID/annotation/link but retains the
  captured file, matching org-download's cross-resource boundary
- GNU Org source-block editing on `C-c '`. The block body opens without its
  delimiters in the configured language mode while preserving indentation and
  Org's protective-comma convention. `C-c '` writes back and exits, `C-c C-k`
  aborts, and `C-x C-s` writes back, saves the Org file, and keeps editing;
  ordinary exit remains an unsaved one-step Org-buffer edit
- configured Org Babel execution on `C-c C-c` for Bash/Shell, Python, C/C++,
  Nix, SQLite, PostgreSQL SQL, and DSQ blocks. DSQ accepts ordinary files,
  mixed ordered file inputs, local or cross-file named Org tables, and named
  source results; the pinned `:cache`, `:convert-numbers`, `:header`, `:hlines`,
  `:null-value`, and `:false-value` controls are retained. Shell, Python, C,
  Nix, SQL, and DSQ ask
  before running; SQLite follows the Emacs configuration's trusted-note
  exemption. Results replace an adjacent `#+RESULTS:` atomically as colon
  output or Org database tables, `:results none` stays buffer-silent, `:dir`
  and preamble header properties are honored, and execution inherits the
  active Direnv environment. DSQ references are converted through bounded
  typed temporary files and every backend uses direct argument vectors.
  Emacs Lisp blocks fail explicitly rather than being mis-evaluated as Common
  Lisp
- configured Org HTML export and publishing through `C-c C-e`: `h h` exports
  the live buffer beside its source, while the publishing branch and
  `lem-yath-org-publish` reproduce the recursive `org-roam-notes`, `static`,
  and composite projects. Publishing is incremental, forceable, cancellable,
  and backgrounded; Org ID and `.org` file links become relative HTML links,
  assets retain the configured `$WORKDIR` layout, and every output is an
  atomic bounded write. Pandoc supplies the broad Org-to-HTML conversion, so
  the result is deliberately not claimed to be byte- or CSS-compatible with
  GNU Org's `ox-html`
- host-gated Org-to-nodes projection in the separate `org/nodes-sync.lisp`
  module. On allowed hosts (default `nova`), saving a canonical `.org` file
  below startup-cached `$WORKDIR` asynchronously runs the existing
  `nodes-org-sync --quiet --file FILE` projector. Syncthing conflict files and
  symlink escapes are inert. Automatic actionable-heading IDs remain off by
  default; `M-x lem-yath-org-nodes-ensure-actionable-heading-ids` is the
  explicit opt-in path, and failures stay in `*nodes-org-sync*`
- a grouped Org agenda over the exact existing work/public/public-MCP roots,
  with top-level file scope, ordinary and repeating active-timestamp events,
  modal Return/`gr`/q navigation, Evil-Org `Tab`/`g Tab`/Shift-Return source
  visits in another window, decoration-skipping `gj`/`gk` and `C-j`/`C-k`
  item motion, and Evil-Org-style `t` fast TODO selection plus
  `J`/`K` GNU Org priority cycling. Evil-Org `dd` and GNU `C-k` durably delete
  complete source subtrees, while `ce`, GNU `e`, and `C-c C-x e` set validated
  Effort properties. Agenda `H`/`L` and the GNU shifted-arrow routes move
  planning or ordinary-event timestamps by days, hours, or five-minute units,
  including ranges and repeated-unit continuation. `C-c C-s`/`C-c C-d` edit
  planning fields. Evil-Org `p` (or GNU `>` in Emacs state) edits the exact
  planning or event timestamp through the shared Org date reader, preserves
  active delimiters, time ranges, repeaters, and warning suffixes, and leaves
  the source buffer unsaved as configured Emacs does. Agenda refreshes include
  immutable snapshots of modified live Org buffers, so the edit remains visible
  without exposing editor buffers to the background worker. Evil-Org `u` undoes
  the newest registered agenda mutation in its live source buffer without
  saving: autosaved TODO/priority/planning/tag edits therefore leave disk at the
  post-command state, bulk actions unwind one source row at a time, and archive
  undo restores the source while retaining the already-saved archive copy.
  Explicit `gr` starts a fresh remote-undo history, matching pinned Org.
  `ct`/`C-c C-q`
  provide completion-backed local-tag
  replacement and clearing. Planning and tag commands persist immediately.
  Evil-Org
  `dA` archives a complete
  subtree to Org's default sibling `_archive` file, while `da` confirms first;
  archive metadata and both files are persisted destination-first. GNU Org's
  `C-c C-w` completes over the current file's level-one headings and
  refiles the selected complete subtree as the target's final child. Agenda
  clocking preserves the effective state split in the Emacs setup: Vi `I/O`
  controls one GNU Org-style global clock, while C-z Emacs-state `I/O` starts
  concurrent delegated clocks on the current or bulk-marked rows and closes
  marked clocks—or every open clock across agenda files when nothing is
  marked. Evil-Org `cg` and base-map `J` jump to the clocked agenda row or its
  source in another window; Evil-Org `cc` and base-map `X` cancel the active
  clock as an undoable unsaved source edit. Evil-Org `cr` and base-map `R`
  toggle a source-linked, two-level clock report for the displayed agenda
  horizon. Evil-Org `gD` selects day, week, fortnight, month, year, or reset
  views; `[[`/`]]` move by that span, `.` returns to today, and `gd` uses the
  shared Org date reader. Each non-summary view renders one section per date,
  including empty dates, and clock reports follow the selected range.
  Evil/base mark keys render `>` prefixes and keep live source points
  across clock insertions and agenda refreshes. Evil-Org `x` and base-map `B`
  dispatch one shared TODO, tag add/remove, schedule, deadline, default archive,
  or same-file refile action across those marks, falling back to the current row
  when none are marked. Marks clear only after a successful supported action.
- streaming OpenRouter LLM client plus native Claude/Codex/Grok JSON event
  backends, with source-position Org conversations, tagged assistant/user spans,
  typed history reconstruction, bounded Org-to-Markdown user prompts,
  per-buffer session resume, rendered agent activity, guarded request lifecycle,
  abort (`SPC g a`), fresh-session (`SPC g n`), and killed-buffer process/marker
  cleanup. Stateless APIs receive the reconstructed turns; stateful CLI and
  OAuth sessions retain provider-owned history without duplicating it. Ordinary
  buffers retain the shared Markdown transcript, which is also the
  non-destructive read-only fallback
- cached OpenRouter model discovery matching the Emacs setup: startup uses the
  private on-disk catalog immediately (or falls back to `openrouter/auto` and
  `openrouter/free`), then refreshes asynchronously after five idle seconds.
  Authenticated sessions use `/models/user`; keyless sessions use `/models`.
  `SPC g L`, then `m` (or compact `SPC g l`, `m`, `m`), selects a discovered
  model, and
  `M-x lem-yath-openrouter-refresh-models` refreshes explicitly
- native `chatgpt-codex` and `grok-oauth` HTTP backends with the configured
  `codex-agentic` and `grok-build-oauth-agentic` five-tool presets. ChatGPT
  Codex shares and safely refreshes `~/.codex/auth.json`, streams the Responses
  API, and offers `M-x lem-yath-chatgpt-codex-login` for PKCE login. Its
  Emacs-matching model catalog loads a private cache immediately, then probes
  `gpt-5.4`, `gpt-5.3-codex`, `gpt-5.2-codex`, and `gpt-5-codex` after five
  idle seconds without opening a login browser. HTTP 200 and rate-limited 429
  candidates remain selectable; `M-x lem-yath-chatgpt-codex-refresh-models`
  refreshes explicitly. Grok reads
  `~/.grok/auth.json` and asks the official `grok` CLI to refresh an expiring
  session. On SSH, Codex login needs local forwarding for callback port 1455
- gptel-style compact `SPC g l` preset/handoff menu and full `SPC g L`
  request menu. Compact `m` opens the full menu; it controls system
  instructions, backend, catalog model, provider-default or explicit
  temperature/token limits, supported tool policy, presets, send/abort/new
  session, and request tracing. The full menu also keeps gptel's one-shot
  response destinations: `e` sends the completed response to the echo area,
  `b` inserts at point in another buffer, `g` creates or extends a typed Org
  LLM session, `k` copies to the kill ring, and `.` restores the ordinary
  destination before Return sends. `J` opens a read-only, credential-free
  normalized JSON preview of the effective prompt, context, messages, model,
  limits, tools, and destination without dispatching. With a Visual selection,
  `r` prompts for a rewrite and stages the provider response without changing
  source text. Its focused terminal preview supports `A` accept, `K` reject,
  `r` iterate, `D` unified diff, `M` conflict-marker merge, and `q` keep
  pending; acceptance is one ordinary undo step. At point in an Assistant
  response the same full menu adds `Space` to mark its exact semantic span,
  `M-Return` to regenerate it with its captured backend/model/request settings,
  `P`/`N` to rotate bounded response history, and `E` for a terminal unified
  comparison with the previous variant. Rotation and its semantic metadata are
  one ordinary undo step. Transcript-backed HTTP providers can regenerate;
  native Claude Code, Codex, and Grok CLI sessions fail closed because their
  provider-owned resumable history cannot safely rewind. In an Org LLM
  conversation backed by Claude Code, `C-c C-f` forks the active project
  session at the nearest preceding Assistant boundary and `C-c C-b` selects a
  registered project session. Sending from an earlier point before an existing
  same-session continuation performs the equivalent fork automatically; later
  continuations belonging to the old branch do not cause repeated forks.
  Forks truncate a private Claude JSONL history,
  append its new continuation marker, and update `sessions-index.json`
  transactionally without touching the source session. Native Claude requests
  run from the originating buffer's canonical Git root, pre-approve the
  configured Bash/Read/Edit/Write/Glob/Grep/WebFetch/WebSearch/Agent tool set,
  and pass the first safe owned regular MCP config from project `.mcp.json` or
  `~/.claude/.mcp.json`. Inherited Org `CC_CWD` and `CC_ALLOWED_TOOLS`
  properties override the process/session directory and tool list at the
  current heading, matching the Emacs backend. Git roots resolving to `/` or
  the home directory, invalid property paths/tool lists, and symlinked or
  group/world-writable MCP files fail closed. Claude activity uses the same
  `#+begin_cc_thinking`, `#+begin_cc_tool`, and
  `#+begin_cc_tool_result` Org blocks as the Emacs backend. Completed thinking
  and tool-result blocks collapse without changing transcript text; tool blocks
  collapse only above the configured eight-line threshold. Conversation-local
  `C-c C-t` toggles every tool result and retains ordinary Org TODO behavior
  when no Claude result block exists. Private named presets and
  region-or-buffer handoff to Claude or ChatGPT remain in the compact menu; the built-in `quick-lookup`
  preset matches the Emacs startup model, system prompt, temperature, and
  token cap, `project-readonly` opts OpenRouter into the configured five-tool
  project inspection loop, `web-readonly` adds the fetch MCP server,
  `github-readonly` adds the configured read-only GitHub MCP toolsets when a
  token is available, `grok-build` selects the native Grok CLI backend,
  `codex-agentic` selects native ChatGPT Codex, and
  `grok-build-oauth-agentic` selects the Grok OAuth proxy
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
  llm-cli, llm-http, llm-oauth, llm-presets, claude-code
- the Notmuch port accepts real bare thread IDs, marks rendered mail read, and
  mirrors the configured Evil-collection triage keys. Search buffers use `a`
  to archive, `d`/`!`/`=` to toggle deleted/unread/flagged, and `+`/`-` for
  tags; show buffers retain message-level `a`/`x`/`d`/`=`/`+`/`-` plus
  thread-level `A`/`X`. Mutations are bounded direct argv calls and update the
  read-only view only after Notmuch succeeds. New/reply composition completes
  `To`, `Cc`, and `Bcc` from recipients in mail sent by the configured Notmuch
  identities after the ordinary three-character Corfu delay. Lookup is
  asynchronous, bounded, cancellable, and cached per composition; accepting a
  candidate replaces only the current comma-separated address token. In a
  composition, `C-c C-a` prompts for a regular local file and inserts the
  familiar visible MML part marker; `C-c C-c` converts those markers into a
  bounded `multipart/mixed` message before STARTTLS submission and exact sent
  FCC. Attachment paths are never shell-expanded; submission refuses
  non-regular marker paths and files changed while being read, and both
  individual and aggregate payloads are capped at 7 MiB. Stock Notmuch draft
  lifecycle is retained: `C-x C-s` snapshots a MIME draft in place,
  `C-c C-p` postpones it, and `e` resumes a shown `tag:draft` message with
  attachment bytes restored into owner-private temporary files. A resave
  hides the previous version only after the replacement is durable; a send
  retires the draft only after SMTP and sent FCC succeed. In a shown message,
  `cf` prepares Notmuch's ordinary inline-forward shape with the stock
  included headers, `References`, delimiters, and regular attachment bytes.
  Forward state survives save/postpone/resume; successful SMTP/FCC applies
  `+forwarded`. For signed or encrypted source MIME, the same `cf` route keeps
  the source byte-exact in a private `forwarded-message.eml` attachment instead
  of invalidating its protection through Emacs's default decode/re-encode
  path; that attachment survives postpone/resume and the ordinary send/FCC/tag
  lifecycle. Received MIME leaves are selectable attachment rows: Return
  previews PDFs in-editor and otherwise prompts to save the exact decoded
  bytes, while `. s` explicitly saves any selected part. The prompt proposes
  a path-safe MIME basename and remembers the last directory; confirmed
  overwrites use a same-directory mode-0600 staging file and atomic rename,
  and symlink or non-regular destinations fail closed
- ordinary `.pdf` and `.epub` opens stay inside Lem: PDFs expose bounded
  Poppler text one page at a time, while EPUBs become bounded Markdown with
  chapter navigation. Both are read-only, never visit or overwrite the binary
  source, and retain `o` for the desktop viewer; Notmuch PDF attachment rows
  use the same ephemeral reader and remove their private extraction on `q`,
  while non-PDF rows retain the configured save-default behavior.
  The terminal path deliberately omits pixel layout, images, CSS, annotations,
  forms, and other visual-only document semantics
- `M-x pgmacs` prompts for a password-free libpq connection string, lists
  PostgreSQL tables, and opens bounded psql-backed query results; `g` refreshes
  and `q` returns to the source buffer, while `.pgpass` supplies credentials

Saved LLM presets live in `$XDG_CONFIG_HOME/lem-yath/llm-presets.json` (or
`~/.config/lem-yath/llm-presets.json`) with private directory and file modes.
They retain the local-tool opt-in and configured MCP server names as well as
backend, model, system message, temperature, and token cap.
The OpenRouter catalog lives in
`$XDG_CACHE_HOME/lem-yath/openrouter/models.json` (or
`~/.cache/lem-yath/openrouter/models.json`) and uses the same private
directory/file ownership checks and atomic replacement. Set
`LEM_YATH_OPENROUTER_MODEL_REFRESH=0` to disable only the automatic idle
refresh; cached selection and the explicit refresh command remain available.
The ChatGPT Codex catalog uses
`$XDG_CACHE_HOME/lem-yath/chatgpt-codex/models.json` (or
`~/.cache/lem-yath/chatgpt-codex/models.json`) with the same private atomic
cache boundary. `LEM_YATH_CODEX_MODEL_CACHE` overrides that path, and
`LEM_YATH_CODEX_MODEL_REFRESH=0` disables its automatic idle probes without
disabling cached selection or the explicit refresh command.
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
credential-free backend streaming/resume, cached OpenRouter and ChatGPT Codex
model discovery,
private preset persistence, web
handoff, read-only fetch/GitHub MCP client sessions, integrated Claude Code
interaction, and authenticated MCP diff review,
cursor/state parity, evil-snipe and Avy parity, screen-line/Evil parity, notes,
roam, roam backlinks, native Org, Org-modern projection, Org image
capture/download, planning/timestamps, agenda, agenda-undo, agenda-clock, and
agenda-bulk, agenda-filter, agenda-view, and parity-ledger checks. The ledger can also be
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
nix run .#llm-models-test
nix run .#llm-codex-models-test
nix run .#llm-backend-test
nix run .#llm-http-test
nix run .#llm-oauth-test
nix run .#llm-workflow-test
nix run .#llm-tools-test
nix run .#org-nodes-sync-test
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
nix run .#calc-test
nix run .#so-long-test
nix run .#large-file-test
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
nix run .#org-modern-test
nix run .#org-download-test
nix run .#org-planning-test
nix run .#org-timestamp-test
nix run .#org-source-edit-test
nix run .#agenda-test
nix run .#agenda-undo-test
nix run .#agenda-clock-test
nix run .#agenda-bulk-test
nix run .#agenda-filter-test
nix run .#agenda-view-test
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
`daily-workflows`, `direnv`, `llm-keybinding`, `llm-models`, `llm-codex-models`, `llm-backend`, `llm-workflow`, `llm-tools`, `claude-code`, `lisp-eval`, `orderless-completion`, `snippets`, `lsp-snippets`,
`lsp-project`, `real-lsp`, `tree-sitter`, `dap`, `project-navigation`, `project-outline`, `persistence`, `bookmarks`,
`vundo`, `electric-editing`, `ui-parity`, `business-visual`, `cursor-state`, `snipe`, `avy`,
`documents`, `notmuch`, `interactive`, `structural`, `roam`, `roam-backlinks`,
`org-modern`, `org-download`, `agenda`, `agenda-undo`, `agenda-filter`, `agenda-view`, `dirvish`, `window-history`, or `notes` to run only
that gate.
`LEM_YATH_TEST_HOST` and `LEM_YATH_REMOTE_ROOT` override the SSH host and remote
cache directory.
