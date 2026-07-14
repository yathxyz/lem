# Port map: every declared Emacs package → its Lem disposition

This is a package-level orientation only. The authoritative status and test
evidence live in `docs/parity-ledger.tsv`; a package row here can summarize
several independently exact, approximate, or missing behaviors.

Status legend:
- **lem-builtin** — feature ships in the Lem image; configured/enabled by the port
- **ported** — reimplemented in Common Lisp in this repo (`lem-yath/src/...`)
- **n/a** — Emacs-plumbing with no meaning in Lem (or unused in the Emacs config itself)
- **partial** — core workflow ported, listed aspects missing
- **gap** — no Lem counterpart; not faithfully portable in scope (reason given)

| Emacs package | Status | Lem equivalent / location |
|---|---|---|
| evil | lem-builtin+ported/partial | `lem-vi-mode`, enabled in `src/vi.lisp`; `src/cursor-state.lisp` supplies the configured cursors and buffer-local Emacs state. `SPC y v` activates the patched conditional screen/logical policy for `j/k`, `gj/gk`, `0/g0`, `$/g$`, `I/A`, `D/C`, line operators/registers, paste, and `V`, restoring ordinary logical-line behavior when disabled (`patches/lem-vi-screen-line.patch`, `scripts/screen-line-test.sh`). Lem's display-width row breaking remains an approximation of Emacs word wrapping. |
| evil-collection | lem-builtin | vi-mode's own mode integrations |
| evil-surround | ported/partial | standard `ys`/`ds`/`cs`, visual `S`, row-wise Visual Block surrounds, common delimiter padding, tags, and ordinary/prefix call prompts. Character deletion/change chooses the narrowest balanced enclosure, keeps code/string/comment/Lisp-fence delimiters in safe domains, ignores escapes and syntax decoys, preflights both edits, and fails closed on malformed or multi-character block-string delimiters. Mode-local custom pair functions and full minibuffer editing remain gaps (`src/vi.lisp`, `scripts/surround-test.sh`) |
| evil-snipe | ported | configured 2.1.3 behavior: visible `s/S/f/F/t/T`, whole-visible `;`/`,` and transient pair repeats, exact inclusive/exclusive operators, counts/dot/jumplist behavior, leading-whitespace skipping, and incremental/final faces (`src/vi.lisp`, `scripts/snipe-test.sh`) |
| evil-nerd-commenter | ported | `g c` operator (`src/vi.lisp`) |
| evil-org | ported/partial | native `.org` buffers provide mode-local folding, visible-line motion, GNU-style `gh/gl/gk/gj/gH` element-tree navigation across the bounded parser, Org-aware `o/O`, the configured `0/$/I/A` endpoint and insertion policy, context-dispatched Meta editing, and all eight active `ae/ie`, `aE/iE`, `ar/ir`, `aR/iR` operator/Visual text objects. Always-active `(`/`)` motions match the pinned double-space sentence model, including wrapped prose and Org table field boundaries with GNU count behavior; `{`/`}` traverse headings, prose, flat and complex lists, formula-owning tables, affiliated keywords, drawers, block paragraphs, and clock groups. All three motion families preserve counts, Normal/Visual behavior, and Evil's context-sensitive characterwise/linewise operator shape; empty elements and malformed blocks remain no-ops. Normal `d` retains Evil motions, counts, registers, undo, and `ds`, while repairing safe nested ordered-list segments (including `[@N]` cookies) and terminal-profile headline-tag alignment; unsupported continuation, tab-structured, or mixed-marker repairs abort before mutation. Normal one-character `x/X` preserves Org table width, whereas counted and Visual deletion and operator-pending Snipe retain their stock behavior. Normal, doubled, counted, and Visual `<`/`>` ranges context-dispatch like pinned Evil-Org: selected headings change one level, safe list-item ranges reindent with ordered-list repair, the first top-level list item triggers the literal one-column whole-list rule, a same-line table range moves by its selected cell boundaries while short counted motions still move once, doubled table operators and ordinary text shift four columns, and every edit remains one undo step. Top-level heading promotion, unsafe list ranges, and formula-owning table-column moves abort before mutation. The separate boundary model covers conservative inline objects/cells, bracket/plain links, paragraphs/rows/flat blocks, point-sensitive items/lists, formula-owning tables, sections/headlines, count anchoring/ancestry, owned post-blank, exact char/line shapes, reverse Visual ranges, and class-specific fail-closed unsafe-list, drawer/orphan-property, nested/unclosed-block, and unsupported-inline contexts without shadowing normal `a/i`, stock words, surround, or Snipe. With the pinned `org-special-ctrl-a/e=nil`, `I` uses column zero for real headings/items and indentation elsewhere, including list lookalikes in source blocks; `A` remains at literal line end. `M-h/l` targets one heading/list item/table column or prose word; `M-k/j` moves heading/list trees or rows; `M-H/L` uses tree/column scope; `M-K/J` handles a table row or literal non-CLOCK line. Region-aware Meta behavior, richer Org syntax and destructive repair outside the bounded parser, and shift-control/calendar semantics remain gaps (`src/org/`, `scripts/org-test.sh`, `scripts/org-operator-test.sh`). |
| general (SPC leader) | ported/partial | normal and visual states share one described Space-leader keymap with exact binding verification and delayed continuation help; remaining capability gaps are listed in `docs/vi-parity.md` |
| vertico | ported/lem-builtin | prompt candidates open immediately without mutating input or eagerly accepting a synchronous singleton, show up to 20 rows, and cycle with `C-n`/`C-p`; `Tab` inserts the focus while retaining the prompt, one `Return` accepts and submits, and `M-p`/`M-n` traverse prompt history (`src/completion.lisp`, `scripts/completion-test.sh`) |
| orderless | ported/partial | ordinary-buffer completion has escaped-space components, whole-query smart case, any-order literal/regexp filtering, and `~ % = ^ ! ,` affix dispatch through `M-Space`. `%` reproduces pinned directional character folding for Unicode diacritics, compatibility forms, and ASCII quote variants through candidate `filterText`. CL-PPCRE still differs from Emacs regexp syntax. The pinned `&` annotation style is minibuffer-only upstream and has no effective path in the configured Vertico-Prescient minibuffer pipeline, so adding it to Lem's ordinary popup would diverge (`src/orderless.lisp`, `src/auto-completion.lisp`, `patches/lem-completion-lifecycle.patch`, `scripts/orderless-completion-test.sh`) |
| marginalia | ported/partial | `src/annotations.lisp` adds bounded display-only metadata to the supported prompt categories: M-x shows active bindings and command documentation; `src/help.lisp` shows callable type/signature/docs and variable type/bounded or censored value/docs; ordinary/project buffers show state, size, mode, and path; ordinary/recent/project files show local modes, size, age/date, and conditional owner; `load-library` shows loaded state, literal ASDF version/description, and source directory; `load-theme` shows active state, inheritance, and direct role count; bookmark prompts show target type/path, exact line/column, and bounded nearby context without visiting the file. Exact acceptance, display-only filtering, stale-bookmark fallback, package-qualified identity, and secret censoring are TUI-tested. Faces/packages, dynamic alignment, category-aware truncation, and remote fields remain gaps. |
| consult | ported/partial | `src/project.lisp` supplies persistent project MRU, tracked+untracked annotated file selection, bounded asynchronous regexp search, and Emacs-style switch dispatch on `SPC p f/g/p`. `src/project-picker.lisp` makes `SPC SPC` a grouped Project Buffer/File/Root picker with fixed source order, `b/f/r Space` narrowing, empty-Backspace widening, group rotation, identity-preserving duplicate labels, and reversible preview-on-move. `src/project-outline.lisp` reproduces the audited Emacs-Lisp-tree `consult-outline`: an exact, non-evaluated `.dir-locals.el` declaration activates Normal/Emacs-state `C-c i`, line-numbered source-order headings, Prescient filtering, reversible recentered preview, one-key abort, match-column acceptance, and Vi jumplist return (`scripts/project-outline-test.sh`). The switch menu preserves `f/g/d/v/e/o`: `v` opens Git through Legit at the selected root, while `e` uses Lem's rooted terminal and `o` uses rooted M-x-style command execution, approximations of `project-eshell` and `project-any-command`. Unopened-file previews deliberately remain raw UTF-8 text, avoid file/mode/switch/kill hooks, and skip undecodable, binary, or over-1-MiB files because generic Lem major-mode activation is not isolated from parser and hook side effects; ordinary window-display hooks can still run. |
| consult-eglot | ported/partial | `src/workspace-symbol.lisp` gives `SPC p s` one `LSP Symbols:` prompt with Consult's 3-character minimum and 0.2/0.5-second debounce/throttle defaults, query-preserving history, request cancellation plus stale-generation rejection, server-order Prescient filtering, kind/container/root-relative-file annotations, kind groups, the pinned case-sensitive kind-key-plus-Space narrowing map and empty-Backspace widening, reversible recentered preview, exact C-g rollback, one-Return acceptance, and Vi `C-o` return. Lem captures one project workspace rather than aggregating multiple Eglot servers, cannot consume the package's nonstandard server-score field, and uses a matched-line highlight instead of Pulsar (`scripts/lsp-project-test.sh`). |
| corfu (TTY via Emacs 31) | ported/partial | Lem has an ncurses popup, correct display/filter/insert metadata, tracked ranges, stale-result rejection, the configured 3-character/0.2-second automatic trigger, provider-aware `preselect=valid`, exact-candidate fronting, non-cycling navigation, a display-only selected-candidate preview, selected `Tab`/`Return`, commit-before-input, non-accepting `M-Space`, staged `Escape`, one-stage `C-g`, and undo-honest input reset. The preview is a safe one-row float rather than an inline overlay and is suppressed for unrepresentable multiline/wrapped edits; Corfu's wider command surface remains a gap (`src/auto-completion.lisp`, `patches/lem-completion-lifecycle.patch`, `patches/lem-completion-validity.patch`, `patches/lem-completion-observer-change-group.patch`, `patches/lem-completion-presentation-focus.patch`, `scripts/auto-completion-test.sh`, `scripts/completion-lifecycle-test.sh`). |
| cape | ported/partial | automatic same-major-mode dabbrev and path-aware file-at-point fallbacks are context-dispatched and TUI-tested; recognized paths use file completion while other tokens use dabbrev, rather than merging the two nonexclusive Cape pools. Raw dabbrev candidates feed Orderless, while Cape's broader provider library is not ported. |
| yasnippet (+ snippets) | ported/partial | the configured private Org `jjs` source-block snippet is exact, and `src/snippets.lisp` uses the audited data-only subset of the 2,387 definitions at pinned `yasnippet-snippets` commit `606ee926df6839243098de6d71332a697518cb86`; numbered, anonymous, and nested fields, defaults, repeated placeholders, mirrors, escapes, `${0:...}`, `$0`, safe indentation directives, field navigation, a Prescient `M-x lem-yath-insert-snippet` selector, and common Eglot LSP snippet sessions work, while executable definitions and strict TextMate choices/variables/transforms remain unavailable |
| prescient (+vertico-) | ported/partial | prompt literal/regexp/initialism filtering and persistent recency/frequency ranking are implemented; interactive toggles and char folding remain gaps |
| embark (+consult) | ported/partial | `SPC e a` opens a typed, extensible action dispatcher for contiguous regions, URLs, existing local files, identifiers, buffers, native mode menus, focused completion candidates, and search/location rows. Outside completion, all unique targets are retained in provider order; repeating the same `SPC e a` chord cycles and wraps before the next one-key action. Completion-local `C-c a` can copy in place or accept once (`src/actions.lisp`). Act-all, collect/export/live views, arbitrary Embark action-map composition, and richer embark-consult adapters remain gaps. |
| wgrep | lem-builtin+patched/partial | grep result rows are editable and write through immediately to source buffers; ordinary source-buffer save persists them. Point-preserving updates and lifecycle-owned preview timers keep rapid Vi editing stable, and Escape leaves Insert/Visual state before dismissing the UI (`patches/lem-grep-writeback.patch`, `patches/lem-peek-source-timer.patch`, `src/project.lisp`, `scripts/project-navigation-test.sh`). Unlike wgrep, there is no explicit staged edit mode with finish/abort commands. |
| eglot + eglot-booster | lem-builtin+ported/partial | `lem-lsp-mode` uses a native JSON-RPC client, so Eglot Booster is unnecessary. The installed application packages rust-analyzer, pyright, harper-ls, csharp-ls, nixd, gopls, terraform-ls, JDTLS, `nixfmt` from nixfmt-rfc-style, and google-java-format; an installed-wrapper ncurses gate performs real handshakes and process-cleanup checks. Stdio servers use real pipes with stderr isolated from JSON-RPC. Lem advertises and answers `workspace/configuration`, accepts capability registration, acknowledges work-done progress creation, and supports LSP 3.17 pull diagnostics. Ordinary local-file workspaces are isolated by stable server identity + canonical root, pending starts deduplicate and time out, save-as/mode changes rebind explicit ownership, restart/shutdown is project-scoped and graceful, and server cwd/init options are frozen to the project. Python deliberately retains a registered, manually enabled Pyright spec because the Emacs configuration has no Python Eglot hook. Lem still differs in language-root selection, Nix settings delivery, Go/Terraform transport, progress presentation, and filesystem-watch delivery; resolved completion documentation/detail and completion commands also remain gaps. |
| flycheck (+rust) | ported/partial | `src/lint.lisp` enables a cancellable checker in programming buffers outside LSP ownership, runs on mode enable/save/newline/500 ms idle change, and reuses LSP overlays, popup, list, and navigation. Packaged chains cover Ruff then Mypy, Clang, Cargo `test --no-run`, gofmt/vet/build-or-test, Bash syntax, `python -m json.tool`, and `nix-instantiate --parse`; SOPS plaintext, temporary, and read-only buffers are refused. `C-c ! c/n/p/l` and `M-g n/p` preserve the effective Flycheck/error-navigation bindings. The arbitrary Flycheck checker catalog, checker selection/verification, compiled output buffer, and explain/copy commands are not ported. |
| apheleia | ported/partial | `SPC b f` formats unsaved buffer text through a mapped CLI/in-process backend, with ready LSP fallback only when manual formatting has no usable mapped backend; mapped programming modes with an available backend format synchronously before the ordinary save, so the final text reaches disk through one write before LSP `didSave`. Formatter hunks, ws-butler, and EditorConfig normalization form one retained transaction: formatter hunk read-only conflicts are rejected before mutation, later normalization conflicts or safe hook/finalizer errors roll back coherently, and an unsafe rollback aborts saving with visibly dirty truncated history. A failed formatter contributes no output, but ordinary save normalization still runs (`src/formatting.lisp`, `patches/lem-after-change-undo.patch`, `scripts/formatting-test.sh`, `scripts/vundo-test.sh`). The registry is broad but finite, and async formatting, formatter prompts, and Apheleia-style per-project backend overrides are absent |
| dape (DAP debugging) | gap | Lem has no DAP client |
| treesit-auto / tree-sitter-langs / tsc / grammars | ported/partial | `src/tree-sitter.lisp` automatically installs a distinct parser in eligible buffers for 19 packaged grammar/query pairs: Bash, C, C#, Clojure, CSS, Go, HTML, Java, JavaScript, JSON, Lua, Markdown, Nix, Python, Rust, TOML, TypeScript, TSX, and YAML. It retains each mode's normal indentation and falls back to its TextMate parser on activation failure. Query highlighting approximates Emacs font-lock level 3; injection/locals scope processing, incremental reparsing, and languages without an existing Lem mode remain gaps (`scripts/tree-sitter-test.sh`). |
| nix-mode | lem-builtin+ported/partial | Packaged **nixd** with flake-derived nixpkgs/options and packaged `nixfmt` from nixfmt-rfc-style (`src/ide.lisp`). Lem sends these as initialization options and roots at a Nix marker; Emacs uses workspace configuration at its project.el root and its declared daemon PATH normally supplies no formatter candidate. |
| rust-mode | lem-builtin+ported/partial | Packaged **rust-analyzer**, cargo, rustc, rustfmt, and clippy auto-start and are installed-wrapper tested; Lem uses the nearest Cargo.toml rather than Emacs's project.el root. |
| go-mode | lem-builtin+partial | Packaged **gopls** is handshake-tested through the upstream TCP spec rooted at go.mod; Emacs uses boosted stdio at its project.el root, and Lem adds completeUnimported and fuzzy-matcher initialization options. |
| markdown-mode / markdown-ts-mode | ported/partial | Packaged **harper-ls --stdio** is handshake-tested. Lem has one Markdown mode rooted at `.git`; Emacs hooks both ordinary and tree-sitter modes at their project.el roots. |
| csharp-mode / csharp-ts-mode | ported/partial | `.cs` and `.csx` files use a native C# mode with C-like indentation, automatic query-based tree-sitter highlighting with a TextMate fallback, and packaged **csharp-ls** at the nearest `.sln`, `.csproj`, or `.git` root. Installed-wrapper gates compile the C# grammar/query and obtain a real semantic error via pull diagnostics. Tree-sitter does not drive indentation or the wider mode semantics, and progress UI and filesystem-watch notifications remain absent. |
| (python via pyright) | ported/partial | Packaged **pyright-langserver --stdio** remains registered and is handshake-tested after explicit `M-x lsp-mode`. It does not auto-start, matching the absence of a Python Eglot hook; Ruff and Mypy provide default Python diagnostics until Pyright is enabled. |
| terraform-mode | lem-builtin+partial | Packaged **terraform-ls** is handshake-tested through upstream Lem's TCP spec with `.git` fallback; Emacs uses boosted stdio at its project.el root. |
| clojure-ts-mode / cider | lem-builtin+partial | Lem supplies Clojure mode, tree-sitter highlighting, clojure-lsp integration, and an nREPL REPL. Exact CIDER parity is not a target: CIDER is installed in the Emacs profile but has no explicit configuration. |
| eglot-java | ported | `M-x lem-yath-java-lsp` manually starts packaged JDTLS without a Java hook, sends the configured Google Java style URL, and isolates JDTLS data by canonical project root. Packaged google-java-format backs `SPC b f` and format-on-save; the real-server and formatting TUI gates cover both paths. |
| gdscript-mode | gap | no Godot mode/LSP in Lem |
| nasm-mode | lem-builtin | `lem-asm-mode` |
| just-mode / meson-mode / nginx-mode / nushell-ts-mode / typst-ts-mode | gap | open as fundamental (no Lem modes) |
| yaml-mode | lem-builtin | `lem-yaml-mode` |
| sqlite3 | n/a | elisp FFI library |
| lispy / lispyville | ported | Paredit in Common Lisp, Clojure, Scheme/Racket, and Elisp; delimiter-safe Vim operators, atom motions, slurp/barf, drag, splice, split, raise, transpose, convolute, and list insertion/opening (`src/structural.lisp`, `scripts/structural-test.sh`); wrapped-row delimiter safety and Lispyville's screen-row character-register quirk are covered by `scripts/screen-line-test.sh`; plus full SLIME via micros |
| magit | lem-builtin | `lem/legit` (status/stage/commit/branch/push/pull/stash/rebase); `SPC g G` |
| magit-todos | ported/partial | `src/git.lisp` adds a navigable TODO/FIXME section to Legit Git status through a small pinned-upstream status hook. The synchronous `git grep` scan is deliberately limited to tracked nonbinary files, 200 results, 1 MiB, and five seconds; it does not reproduce magit-todos keyword customization or grouping (`scripts/vcs-test.sh`). |
| forge | gap | no GitHub/GitLab integration |
| git-gutter | lem-builtin+ported | `src/git.lisp` wraps `lem-git-gutter` in a buffer-local programming-mode lifecycle. The installed-wrapper VCS gate proves real add/modify/delete markers in a linked worktree, exclusion from prose/utility buffers, composition with other gutters, and no reserved blank column for a clean line. |
| git-timemachine | ported/partial | `SPC g t` opens rename-aware history at the translated source point; `C-k`/`C-j`, `g t g`, `g t t`, and `q` match the audited older/newer/numeric/fuzzy/return workflow under `scripts/vcs-test.sh`. The Evil-collection hash-copy and blame commands are not implemented. |
| majutsu (jj) | ported/partial | packaged `jj` powers smart `SPC g g` dispatch and forced `SPC g J`, but only in a repository-specific, read-only status/log view (`src/git.lisp`); this is not a Majutsu porcelain and has no mutation UI. |
| org (capture) | ported | `SPC o` → inbox/todo/readlist with CREATED property (`src/notes.lisp`) |
| org-roam | ported/partial | bounded fresh file+heading node index with ID/title/alias/inherited-tag completion, exact find/random visits, and Org ID insertion (`src/roam.lisp`). Missing titles enter the configured note/concept/project/source/Markdown capture dispatcher; disk creation and deferred insertion occur only on `C-c C-c`, with `C-c C-k` abort (`src/roam-capture.lisp`, `scripts/roam-test.sh`). No persistent DB, backlinks, or autosync. |
| md-roam | partial | pinned front-matter ID/title/`ROAM_ALIASES`/Zettlr-tag indexing, `[[Title]]` insertion, and the configured YAML-front-matter Markdown capture template share the roam workflow; no mixed-format graph DB, backlink/wiki-link UI, or duplicate-title disambiguation beyond pinned md-roam behavior |
| org-roam-dailies | ported | `SPC n r d t` / `SPC n r d d` (`src/notes.lisp`) |
| org-journal | ported | `SPC n j j`, same file layout + timestamp headings |
| org-agenda / org-super-agenda | ported/partial | `SPC m a` scans the same existing `$WORKDIR`, `$PUBLIC_ORG_DIR`, and public `mcp/` roots as Emacs, using only top-level non-hidden `.org` files; it groups overdue/today/upcoming/unscheduled TODO entries plus ordinary, timed, ranged, and repeating active-timestamp events, excludes COMMENT/ARCHIVE trees and non-semantic timestamp contexts, provides Return/g/q navigation with coalesced asynchronous refreshes, matches Evil-Org agenda `t` with the configured one-key TODO selector and `J`/`K` with GNU Org's default A/B/C priority transitions, preserves GNU Org's `C-c C-s`/`C-c C-d` schedule/deadline chords, provides completion-backed, aligned local-tag replacement/clearing on Evil-Org `ct` and GNU Org `C-c C-q`, durably moves a complete subtree to the default adjacent `_archive` file on Evil-Org `dA` (`da` confirms) plus GNU Org's archive chords, and matches the current nil-target GNU `C-c C-w` policy by completing over same-file level-one headings and moving the selected subtree to the target's final-child position. Agenda `I/O` preserves the effective state split: Vi state controls one global Org-style clock, while C-z Emacs state starts concurrent clocks on the current or bulk-marked rows and stops marked clocks—or all semantic clocks across agenda files when nothing is marked. Evil/base bulk mark keys render `>` and retain exact live source points across insertions and refreshes. Mutations validate their source headings and save immediately; refile also rechecks the chosen target, while archive writes the destination before deleting the source and records Org's default context properties (`src/apps/agenda.lisp`, `src/apps/agenda-archive.lisp`, `src/apps/agenda-refile.lisp`, `src/apps/agenda-clock.lisp`, `scripts/agenda-test.sh`, `scripts/agenda-clock-test.sh`). Diary sexps, hour repeaters, full time-grid/range presentation, planning removal/delay-cookie forms, configurable/cross-file refile targets and creation/copy/reverse or prefix/cache variants, custom archive destinations/local archive sibling or tag commands, the arbitrary `x`/`B` bulk-action dispatcher, clock goto/cancel/report and prefix variants, and the wider Org agenda UI remain gaps. |
| org-modern / org-download / org-ref / org-contrib / ob-async / ob-dsq / engrave-faces / cdlatex | gap | the native Org subset applies terminal semantic faces, but has no org-modern glyph composition, image/download workflow, bibliography integration, Babel/source execution, LaTeX preview, or publishing/export engine |
| citar / ebib / reftex | ported (citar) | bib parse + open file/url/note, `SPC y o` (`src/apps/citar.lisp`); ebib/reftex gap |
| gptel | partial | OpenRouter streaming exists, but presets, model discovery, conversation/tool semantics, handoff, transforms, and tracing remain open |
| gptel-claude-code / gptel-codex / gptel-grok-build | partial | CLI process backends exist without rich agent-event rendering and backend-specific semantics |
| gptel-chatgpt-codex / gptel-grok-build-oauth | gap | OAuth/PKCE token flows out of scope |
| gptel-tooling / gptel-stability | partial | some parts are Emacs hardening, but user-visible agent tools and project/MCP behavior are not yet ported |
| claude-code.el | lem-builtin | `lem-claude-code` extension, `C-c c` |
| monet | partial | Lem ships an MCP **server** + Claude Code integration natively |
| mcp.el | partial | `lem-mcp-server` (Lem as server); no generic MCP client hub |
| notmuch | partial | search/read/refresh daily path exists; composition, sending, attachments/PDF preview, and the Salta bridge do not |
| elfeed + elfeed-protocol | ported | Miniflux Fever API reader (`src/apps/elfeed.lisp`) |
| devdocs | ported | devdocs.io index lookup + text rendering, `SPC h d` (`src/apps/devdocs.lisp`) |
| pdf-tools | gap | terminal frontend; PDFs open externally (xdg-open) |
| nov (EPUB) | gap | no EPUB rendering |
| vterm | lem-builtin | `lem-terminal` (libvterm), `M-x terminal` |
| pgmacs / pg | ported | psql-backed query/table viewer (`src/apps/pg.lisp`) |
| salta.el | partial | six primary Supabase/PostgREST workflows exist; the notmuch payment-email bridge and some UI semantics remain open |
| helpful | ported/partial | `SPC h k` selects any fbound Lisp symbol—not merely Lem commands—and shows its callable type, signature, package, and documentation; `SPC h v` does the same for bound variables with bounded Marginalia-compatible secret censoring. `SPC h K` and `SPC h b` retain core key/binding help. Source links, references, callers, and richer cross-reference navigation remain gaps (`src/help.lisp`, `scripts/help-test.sh`). |
| which-key | ported/partial | global guidance snapshots every active ordinary keymap-backed prefix across global, dynamic mode, and Vi-state maps, using live dispatcher lookup to preserve shadowing. Initial and nested pages each wait a fresh second, then render sorted raw command/`+prefix` labels in multi-column snapshots capped at 25% of frame height; fast dispatch, Escape, reload, stale timers, and cyclic maps are covered in `scripts/ui-parity-test.sh`. Exact Emacs `C-h` paging, page/column layout, separators/default replacements, and echo-area presentation remain absent. |
| transient | lem-builtin | `lem/transient`; native transient menus remain isolated from global prefix guidance, opening after the upstream 500ms delay and refreshing nested menus immediately (`scripts/ui-parity-test.sh`) |
| multiple-cursors | lem-builtin | core multi-cursors (`M-C`, isearch add-cursor); Emacs config only used it internally |
| expreg | ported/partial | repeated `SPC v` expands lexical subword → symbol → Python/JSON syntax nodes, with whitespace-sensitive balanced-list interiors and enclosing-pair tiers both in code and inside parser-bounded ordinary/block strings, plus a paragraph fallback in parserless modes (`src/vi.lisp`, `scripts/expreg-test.sh`). Arbitrary forward and reverse Visual selections generate from their active endpoint, skip contained candidates into contraction history, and never invent the arbitrary range as a tier. `M-x expreg-contract`, declared but unbound in the Emacs configuration, walks backward through the generated buffer-local sequence; `SPC v` then moves forward again. Parser results and contraction state are valid only for the unchanged buffer. Other languages retain textual fallback, and malformed error fragments use useful containing nodes rather than Expreg's partial error ranges. |
| vundo | ported/partial | `SPC u` opens a three-row Unicode retained tree with live preview, branch/stem/saved-node navigation, mark/diff, save, rollback, and accept (`src/vundo.lisp`, `patches/lem-undo-tree.patch`, `scripts/vundo-test.sh`); numeric prefixes and debug keys `i`/`D` are absent |
| pulsar | n/a | jump recentering is default behavior |
| indent-bars | ported/partial | programming buffers render display-only, depth-colored `│` guides at mode/EditorConfig indentation levels, including contextual blank lines and tab-expanded columns; multiline strings retain only their opening-context depth. `M-x lem-yath-toggle-indent-guides` is buffer-local (`src/indent-guides.lisp`, `patches/lem-display-line-transformer.patch`, `scripts/indent-guides-test.sh`). Ncurses characters and the native Modus projection approximate Emacs' pixel stipple, face blending, and GUI behavior. |
| rainbow-delimiters | ported/partial | `src/ui.lisp` colors every syntax-table delimiter pair by depth in programming buffers, excluding strings, comments, and escaped delimiters. All nine default depths plus distinct unmatched and mismatched faces use the active Modus palette, and show-paren remains active. Individual Lem syntax tables can still classify language constructs differently from Emacs (`scripts/ui-parity-test.sh`). |
| display-line-numbers (built-in) | ported | relative numbers render in saved and unsaved programming buffers, compose with other gutters, and stay out of prose and utility buffers (`src/ui.lisp`, `scripts/ui-parity-test.sh`) |
| centered-view-mode (custom) | ported | `SPC y c` toggles a buffer-local `Center` mode at configurable width 100. A narrow pinned display API supplies balanced per-window margins to drawing, wrapping, horizontal scrolling, and screen-line geometry; resize, split, narrow-window, reload, continuation-row, and restoration behavior are covered by `scripts/centered-view-test.sh` (`src/centered-view.lisp`, `patches/lem-centered-content-width.patch`). |
| truncate-lines / visual-line-mode / hl-line-mode (built-ins) | ported/partial | `src/ui.lisp` starts with long lines truncated and disables Lem's upstream current-line highlight, matching the active Emacs baseline; `SPC y v` retains buffer-local wrap toggling and activates the configured modal row policy (`scripts/ui-parity-test.sh`, `scripts/screen-line-test.sh`). Emacs word-wrap and Lem display-width wrapping can choose different row boundaries. |
| tab-bar / winner-mode (built-ins) | ported/partial | no tab header is shown at startup; `C-x t 2` lazily enables Lem's frame multiplexer and creates a tab. `C-c Left` / `C-c Right` traverse a bounded, frame-local Winner-style history of ordinary split topology, proportions, buffers, selection, and view positions while preserving live buffer points (`src/window-history.lisp`, `scripts/window-history-test.sh`). Lem's tabs remain frame-multiplexer approximations, and transient/side/attached windows are deliberately outside the history. |
| dirvish | ported/partial | Ordinary directory visits use Lem's full-buffer `directory-mode` with the pinned hidden-details presentation: compact names and one display-only, right-aligned six-cell file-size/direct-child-count field (`src/dirvish.lisp`, `patches/lem-directory-buffer-clean.patch`, `scripts/dirvish-test.sh`). Native exact-path visiting and file operations remain intact, refreshes stay clean/read-only, and terminal resize recomputes alignment. Dirvish preview dispatchers, header/mode-line segments, layout switching, subtree/collapse extensions, and wider integrations remain absent; Lem's Filer is a separate side tree. |
| find-name-dired (built-in) | ported/partial | `M-s f` asynchronously fills a persistent, read-only `*Find*` buffer with safely escaped exact-path rows (`src/find-name.lisp`). It matches the pinned Dirvish default presentation with a display-only, right-aligned six-cell size field (direct child count for directories), including resize-safe alignment. Dired `m`/`u`/`U`/`t`, `C`/`R`/`D`, marked-or-current targeting, overwrite and top-level recursive copy/delete confirmation, refresh retention, and request-local cancellation are covered in the real TUI; the wider Dired operation surface remains a gap. |
| electric-pair-mode / delete-selection-mode (built-ins) | ported/partial | syntax-table delimiter/quote pairing plus Unicode smart quotes, local balance reuse/skip, numeric prefixes, ordinary region replacement, Emacs-style opener/quote region wrapping, and preflighted adjacent-pair Backspace in Emacs or Vi insert editing; pair deletion preserves completion, prompt, snippet, Paredit, read-only, kill-ring, undo, and Vi-state lifecycles. An unmatched embedded quote is escaped to keep the Lisp string valid instead of reproducing Lispy's raw interior quote, while full forward balance scanning, negative-prefix paired Backspace, Emacs's destructive wide-selection quirk, and zero-result prompt recovery remain gaps (`src/electric-pair.lisp`, `scripts/electric-editing-test.sh`) |
| ws-butler | ported | track changed programming-buffer lines and trim only those lines on save (`src/editing.lisp`); EditorConfig `trim_trailing_whitespace=true` additionally normalizes the whole buffer, while false/absent retains touched-line cleanup |
| ibuffer | ported/partial | `C-x C-b` keeps Lem's native marked multi-column chooser but partitions its recency-ordered snapshot with the configured exclusive first-match org/tramp/emacs/ediff/dired/terminal/help groups, omits empty groups, and places unmatched buffers under `Default`. Each group has an Ibuffer-style `[ name ]` heading; Return collapses it to `[ name ... ]` or expands it, and heading rows cannot be marked, saved, or killed. Live filtering temporarily shows only selectable matches; Return selection, marked save/kill, control-character-safe labels, and reload are retained (`src/buffer-list.lisp`, `scripts/buffer-list-test.sh`). Ibuffer's wider sorting/filter/format command surface is absent. |
| bookmarks (built-in) | ported | `lem-bookmark` retains `SPC b m` / `SPC RET`; its jump prompt adds display-only target type, abbreviated path, exact line/column, and bounded line context without opening unvisited files, while stale targets degrade to missing-path metadata. `src/bookmarks.lisp` restores bookmarks at startup and saves them through the private atomic persistence transaction at clean exit. A three-way merge preserves independent additions and respects local updates/deletions across stale editor processes (`scripts/bookmark-test.sh`). |
| avy | ported/partial | `SPC l/a/s` provide visible line, character, and symbol-start selection with balanced `a/s/d/f/g/h/j/k/l` floating labels, normal all-window and Visual current-window scope, closest case-folded character ordering, punctuation-aware symbols, wrapped/hidden-row handling, resize invalidation, raw-digit line fallback, cancellation, jumplist integration, and source non-mutation (`src/avy.lisp`, `scripts/avy-test.sh`). Default `x/X/t/m/n/y/Y/i/z/?` dispatch/help, exotic display and syntax geometry, and exact Emacs minibuffer presentation remain gaps. |
| gcmh / no-littering / use-package / direnv / sops | n/a or ported/partial | SBCL needs no Emacs GC hack and no-littering/use-package do not map directly. Direnv is isolated in `src/direnv.lisp`: the current eligible buffer selects Lem's global process environment, explicit `direnv-allow` is available without auto-authorization, and `PATH` affects future subprocesses (`scripts/direnv-test.sh`). `src/sops.lisp` transparently decrypts existing local SOPS text files, installs an encrypting save writer, inhibits format-on-save, and fails closed on decryption errors (`scripts/sops-test.sh`); guided new-file creation and input-type overrides remain absent. |
| editorconfig | ported/partial | the official CLI resolves hierarchy/inheritance for every steady-state local file buffer; Lem maps indentation, line endings, write charset, fill column, trailing whitespace, and final-newline policy (`src/editorconfig.lisp`, `scripts/formatting-test.sh`). Charset is applied only to subsequent writes, not initial decoding |
| auto-revert / savehist / save-place / recentf (built-ins) | ported/partial | `src/persistence.lisp` safely polls every file buffer before commands, transactionally reloads only clean readable files up to a 64 MiB safety cap, protects stale saves, restores up to 600 local-file positions, and atomically persists bookmarks, allowlisted non-secret prompt histories, a 120-entry live/40-entry saved Vi-aware kill ring, and separate 16-entry literal/regexp search rings; recentf remains a 300-file MRU on `M-g r`. Idle-time/filesystem notifications, larger automatic reloads, directory-buffer positions, and broad non-file stale adapters remain gaps |
| modus-vivendi-tinted (built-in) / doom-themes | ported/partial | the active Emacs startup theme is recreated natively in `src/theme.lisp`; resolved semantic colors are tested, while ncurses rendering is limited by the terminal color model and Lem has fewer face roles. `doom-themes` remains declared but inactive. |
| notmuch-outlook / business-visual profile / nodes-org-sync | gap | host-gated bespoke integrations, out of scope |

## Behavioral divergences worth knowing

- **Visual-line row geometry**: the configured Evil screen/logical-line policy
  is ported and TUI-tested. Emacs `visual-line-mode` wraps preferentially at
  word boundaries, whereas Lem wraps at display width, so commands can
  encounter different displayed-row boundaries.
- **Display palette and delimiters**: Lem retains the configured Modus hex
  values for its available semantic attributes, but ncurses maps them through
  the terminal's color capabilities. Nested colors cover six cycling depths in
  Common Lisp only; other modes retain matching-pair highlighting rather than
  Emacs's all-`prog-mode` rainbow coverage.
- **Tabs and layout history**: startup correctly has no tab row and `C-x t 2`
  creates one on demand. The frame multiplexer remains an approximation of
  Emacs tabs, but each frame now has independent, bounded Winner-style ordinary
  window history on `C-c Left` / `C-c Right`. Floating, prompt, side, header,
  and attached windows retain subsystem ownership rather than entering history;
  configurations containing dead or boring buffers are skipped as a unit.
- **Surround grammar**: standard `ys`/`ds`/`cs` and visual `S` work, including
  row-wise Visual Block edits, common padded delimiters, tags, call forms, and
  syntax-context-aware balanced character pairs. Mode-local custom pairs, full
  minibuffer editing, and multi-character delimiter editing remain absent;
  Python triple-quote edits fail closed.
- **Formatting lifecycle**: mapped programming modes with an available,
  successful backend format synchronously before the ordinary save, so the
  formatted state reaches disk through that single write before LSP `didSave`.
  External commands use stdin and direct argument vectors under a timeout. CLI
  launch, timeout, nonzero-exit, and output-limit failures occur before buffer
  mutation, contribute no formatter output, and do not fall back to LSP;
  transactional ws-butler and EditorConfig normalization still runs. Successful
  diff application and save normalization share a retained change group;
  formatter hunk read-only ranges are preflighted, while mutation-hook or
  normalization errors
  replay coherent inverse notifications and restore exact buffer/history state.
  A safely missed touched-line cleanup remains pending for a later save.
  If cancellation itself becomes unsafe, Lem fails visibly dirty with truncated
  history and aborts the ordinary save. Safe formatter failures continue that
  one save after retrying save normalization without formatter output. LSP
  fallback is manual-only when no mapped
  backend is usable. There is no async worker, formatter prompt, or
  Apheleia-style per-project backend table.
- **EditorConfig scope**: matching is delegated to the official CLI, but Lem
  maps only the documented core properties. A charset rule cannot re-decode an
  already opened file and affects later writes only; UTF-16BE/LE writes do not
  add a BOM. `trim_trailing_whitespace=false` does not disable ws-butler's
  touched-line policy. Direnv is a separate module and can change executable
  lookup for later formatting runs through the process-wide `PATH`.
- **Direnv process scope**: `src/direnv.lisp` follows the exact directory of the
  current eligible buffer rather than the Git/project root, while
  `src/workspace.lisp` keeps the notes `$WORKDIR` fixed at startup. An
  unwind-protected `execute-find-file :around` provisionally supplies the
  destination environment to initial mode hooks for selected opens, then the
  switch hook makes it current; direct background `find-file-buffer` loads do
  not retarget the editor. Derived process modes and explicitly marked
  process/compilation buffers participate, while arbitrary scratch buffers do
  not. Updates are synchronous, bounded by a 300-second safety timeout and
  streaming 4 MiB limits per output stream, and affect Lem's global SBCL
  environment and future subprocesses only. Prevalidated changes and any
  rollback are applied sequentially, not atomically: existing processes keep
  their launch environment, and worker threads may observe an intermediate
  multi-variable state or whichever buffer environment is active when they
  launch. `scripts/direnv-test.sh` supplies the focused ncurses evidence.
- **SOPS file scope**: `src/sops.lisp` recognizes existing local YAML, JSON,
  dotenv, INI, and text files through `sops filestatus`. Successful opens keep
  plaintext only in the live buffer; the patched buffer-local writer sends it
  to `sops encrypt --filename-override` and writes only returned ciphertext.
  Failed decrypts remain read-only and retry through revert; failed encryption
  leaves both the prior disk ciphertext and modified plaintext buffer intact.
  The integration is synchronous, has no guided creation command or custom
  input-type map, and uses persistence polling rather than file notifications.
- **Org editing scope**: `.org` files use the native lem-yath Org mode. Its
  TUI-tested boundary covers semantic faces, non-destructive local/global
  folding, atomic hidden-line motion and reveal, safe heading insertion, the
  complete configured TODO cycle with immediate saving, reload/multi-buffer
  cleanup, checklist continuation/toggling, relative file links, table
  row/cell targeting and alignment, and complete-subtree transforms. It is not
  GNU Org: Evil-Org themes beyond the bounded active text objects and the
  wider operator/endpoint themes,
  timestamps/scheduling/deadlines, source editing/execution, richer list/table
  transforms, org-modern glyphs, and an initial Org scratch buffer remain
  absent.
- **Completion previews**: the grouped project picker and directory-local
  Elisp outline provide reversible Consult-style preview. Generic command,
  file, buffer, and LSP-symbol prompts still do not preview their targets.
- **Undo accounting**: the configured 2,080,000 / 3,120,000 / 48,000,000
  Vundo budgets are applied to copied UTF-8 edit payload, not Emacs heap usage.
  Lem additionally caps retained history at 65,536 nodes, 262,144 edits, and
  128 MiB of UTF-8 route-validation work. Retained nodes do not store
  historical point values, so preview point is replay-derived. Vundo movement has no numeric-prefix
  variants or `i`/`D` debug commands. Speculative rectangle/Copilot-style paths
  do not yet use the constrained retained-undo change-group API, so their
  intermediate transactions remain in history.
- **Embark scope**: completion uses `C-c a` because the ncurses input path cannot
  represent `C-.` distinctly. Repeating `SPC e a` cycles and wraps through the
  typed targets at point, but the dispatcher does not yet provide act-all,
  collect/export/live views, arbitrary Embark action-map composition, or the
  wider embark-consult adapter set.
- **Find-name results** persist after opening a match and are safe for spaces,
  control characters, and shell-looking patterns. They provide Dired-style
  marks plus copy, rename, and confirmed deletion. The compact rows reproduce
  the pinned Dirvish default six-cell size/direct-child-count attribute without
  mutating buffer text; Dired's broader chmod/chown/link/shell/compress command
  surface remains absent.
- **Ordinary directory visits** now share that pinned Dirvish presentation in
  full-buffer `directory-mode`: hidden details, compact names, and a resize-safe
  right-edge size/direct-child-count field. Lem's native marks and file actions
  retain exact row identity. Filer remains a separate side tree, and Dirvish's
  optional preview, layout, subtree, header/mode-line, and integration layers are
  not ported.
- **Buffer list UI**: `C-x C-b` now has the exact configured first-match group
  partition, empty-group policy, and collapsible heading presentation. Live
  name filtering hides headings so every result remains directly selectable,
  and Ibuffer's wider interactive sorting, filtering, and format controls are
  not reproduced.
- **Persistence scope**: clean local files are polled globally every five
  seconds and whenever selected; no filesystem notification backend is present.
  File positions exclude temporary VCS commit files, but directory-buffer
  positions are not saved. Shared/unnamed, SQL/compile, credential-like, and
  unknown prompt histories deliberately remain memory-only, and non-file auto-revert requires an
  explicit buffer-local stale/revert adapter. Persistence is default-deny for
  prompt names and applies per-entry and 32 MiB aggregate budgets; oversized
  kills or query strings remain live but are not written. Concurrent merging
  preserves additions, while a stale process can resurrect a history clear.
- **Rectangle duplication**: `M-j` matches line and contiguous-region behavior,
  including Vi character/line selections. It also matches the pinned Evil
  V-BLOCK behavior: the block is not an Emacs rectangle or ordinary active
  region, so the cursor line is duplicated while the block and both corners
  remain live. A separate Emacs-style `rectangle-mark-mode` and its
  duplicate-to-the-right behavior remain absent.
- **Electric-pair scope**: syntax-table pairs, Unicode smart quotes, numeric
  prefixes, escapes, local syntax-safe closer reuse/skip, and preflighted
  adjacent-pair Backspace are covered. Full forward balance scanning across
  forms, negative-prefix paired Backspace, Emacs's orientation-dependent
  destructive behavior for selections wider than one delimiter, and recovery after a zero-
  result prompt query remain open.
- **In-buffer Orderless scope**: automatic mode/Cape completion supports
  multi-component matching and Corfu's `M-Space` separator. CL-PPCRE differs
  from Emacs regexp syntax, `%` character folding and `&` annotation dispatch
  remain absent, and initialism is scoped to deterministic ASCII boundaries.
- **Snippet scope**: `Tab`, `Shift-Tab`, `C-g`, `C-d`, and `Backspace` provide
  the tested field-session workflow, with completion, Vi, and Paredit retaining
  their intended precedence. Root and table inheritance plus common filename
  mappings expose the pinned community data without executing Emacs Lisp. LSP
  format-2 candidates use the same safe session after tracked final acceptance;
  plain format stays literal, malformed payloads preserve the prefix, and
  backquoted server text is inert. Acceptance-time completion resolve supports
  lazy `additionalTextEdits`; direct and resolved edits remain plain, are
  validated against the primary range and each other, and share one undo step
  with the primary insertion. Resolve failure or a bad additional batch falls
  back to the original primary completion.
  Stacked active sessions, direct snippet bindings, redo-time session revival,
  strict TextMate variables/choices/transforms, resolved documentation/detail,
  CompletionList item defaults, completion commands, and native transactional
  rollback after arbitrary mutation-hook errors remain gaps. LSP document
  positions consistently use the originating workspace's advertised UTF-16
  encoding, including edits, diagnostics, navigation, symbols, and completion.
  BibTeX expansion deterministically omits automatic indentation; this
  approximates the intended steady-state text rather than reproducing Emacs'
  transient indentation calls.
