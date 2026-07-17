# Lem Daily-Driver Readiness — Personal Fork Spec

**Baseline:** upstream `lem-project/lem` @ `1d8b517d` (2026-07-15).
**Fork:** `yathxyz/lem`. All work lands here as a rebaseable patchset; upstreaming individual fixes later is optional and out of scope for acceptance.
**Motivation:** a 29-agent audit (2026-07-16) of this tree, with every critical/high claim adversarially verified against code and three findings reproduced empirically (EOL corruption, encoding refusal, long-line hang). File:line references below are as of the baseline commit and may drift.

## Goal

Make Lem safe to rely on as a primary editor in a terminal-over-ssh/tmux workflow: **no silent data loss, no unrecoverable hangs, and a terminal frontend with 2026 table stakes** (paste, clipboard, color, width correctness).

## Non-goals (explicitly out of scope)

- LSP client modernization (inlay hints, workspace symbols, DAP, per-language server configs)
- Remote editing / TRAMP equivalent; server-frontend auth/TLS
- org-mode, spell-check, snippets, plugin ecosystem
- Upstream-PR polish (contract.yml ceremony, maintainer review cycles) — follow contract.yml where it is free, ignore it where it slows a personal fix

## Constraints

1. **Rebase survivability first.** Prefer small, localized diffs and new files over broad refactors. Every patch must apply cleanly after `git pull upstream main` with at most trivial conflict resolution.
2. **Correctness > features.** Each milestone-1 item ships with a rove test under `tests/` where the behavior is testable headlessly (fake-interface); terminal items get a scripted tmux verification instead.
3. Personal defaults (auto-save on, backups on) go in a fork-owned init layer (`build-init.lisp` or a new `src/ext/daily-driver-defaults.lisp` loaded from it), **not** by editing upstream defaults in place — keeps the behavioral diff separable from the mechanism diff.

---

## Milestone 0 — Environment hardening (no code, do immediately)

| ID | Requirement | Done when |
|----|-------------|-----------|
| M0-1 | Add upstream remote + fetch tags: `git remote add upstream https://github.com/lem-project/lem && git fetch upstream --tags` | `git remote -v` shows both; tags visible |
| M0-2 | Create `~/.slime-secret` (random 128-bit string, mode 0600) so the micros accept handshake authenticates | file exists; lisp-mode still connects |
| M0-3 | Always run terminal Lem inside tmux (crash/disconnect recovery layer until DS-3 lands) | habit / shell alias |
| M0-4 | Build via the Nix flake path (CI-tested, compressed image) or `make ncurses`; document chosen update loop (`git pull` + full rebuild — `make update` alone does **not** rebuild) | one-liner update script exists |

---

## Milestone 1 — Data safety (the dealbreakers)

### DS-1: Never silently discard a modified buffer on external file change

**Problem.** `ask-revert-buffer` on `*pre-command-hook*` calls `(revert-buffer t)` unconditionally when mtime changes; the prompting variant is disabled with `#+(or)` (`src/commands/file.lisp:383-401`). A `git checkout`/formatter write + one keystroke silently destroys unsaved edits.

**Required behavior.**
1. If the buffer is **unmodified**, auto-revert silently (current behavior is fine and convenient).
2. If the buffer is **modified**, MUST prompt: revert / keep buffer / diff-and-decide (diff optional, stretch). Never revert without an answer.
3. Prompting must not fire recursively or repeatedly per keystroke while the prompt is open (guard flag).

**Acceptance.** Rove test: modify buffer text, touch the file on disk with different content, run the hook, assert buffer content unchanged and prompt was invoked (fake-interface prompt stub). Manual: edit file, `touch` it from another shell, press a key — prompt appears, "keep" preserves edits.

**Files.** `src/commands/file.lisp`. **Size:** S.

### DS-2: Atomic saves

**Problem.** Saves open the target with `:if-exists :supersede` and write in place (`src/buffer/file-utils.lisp:154-158`, `src/buffer/file.lisp:168-186`). Crash/C-g/disk-full mid-write truncates the file.

**Required behavior.**
1. Save path MUST write to a temp file in the **same directory** (`.#<name>.tmp` style), fsync, then `rename(2)` over the target.
2. MUST preserve the target's permission bits; SHOULD preserve ownership when possible; MUST follow symlinks (write through to the real target, not replace the link).
3. Fallback to in-place write only when rename-over is impossible (cross-device, directory not writable) — with a visible message.

**Acceptance.** Rove tests: save preserves content byte-for-byte (reuse audit corpus method); permissions of a 0644/0755 file survive save; saving through a symlink leaves the symlink intact. Manual: `chmod 400` the directory mid-flow → clear error, original file untouched.

**Files.** `src/buffer/file-utils.lisp`, `src/buffer/file.lisp`. **Size:** M. **Risk:** encoding/EOL interaction — land after or with DS-6.

### DS-3: Checkpoint auto-save + crash recovery

**Problem.** `auto-save-mode` saves **over the real file** and unmarks the buffer (`src/ext/auto-save.lisp:30-32`); there are no swap/recovery files and no recovery command. A crash or dropped ssh session loses everything since the last manual save.

**Required behavior.**
1. New checkpoint mechanism (replace or bypass current auto-save): every N seconds / K keystrokes, write modified buffers to `$XDG_DATA_HOME/lem/autosave/<hashed-path>#` — never to the real file, never clearing the modified flag.
2. Checkpoint deleted on successful manual save; stale checkpoints survive crashes.
3. `recover-file` command: on `find-file`, if a newer checkpoint exists, offer recovery (prompt: recover / ignore / delete checkpoint).
4. Enabled by default in the fork's init layer (per Constraint 3).

**Acceptance.** Rove: modify buffer → trigger checkpoint → assert real file untouched, checkpoint exists, buffer still modified; manual save removes checkpoint. Manual: `kill -9` the editor with unsaved edits, restart, `find-file` → recovery prompt restores the edits.

**Files.** new `src/ext/` file (fork-owned — minimal upstream diff), hook into save path. **Size:** M-L. Highest-value single item in the spec.

### DS-4: Backup-on-save default

**Problem.** `~`-suffix backups exist but only under auto-save-mode with `*make-backup-files*` (default nil) (`src/ext/auto-save.lisp:13,33-35`).

**Required behavior.** First save of a session per file MUST copy the pre-save content to `<file>~` (or centralized `$XDG_DATA_HOME/lem/backups/`, pick one), independent of auto-save-mode. Enabled via fork init layer.

**Acceptance.** Rove: open, edit, save → backup holds original bytes; second save does not overwrite the backup.

**Files.** save path + fork init layer. **Size:** S. Depends on DS-2 landing shape.

### DS-5: Clobber protection on save

**Problem.** `save-buffer` never checks `changed-disk-p` (`src/commands/file.lisp:272-283`) — saving over a file another process modified silently discards that process's changes.

**Required behavior.** If file mtime is newer than at load/last-save time, prompt "file changed on disk; really save?" before writing.

**Acceptance.** Rove: load, externally rewrite the file, `save-buffer` → prompt invoked; declining leaves disk file intact.

**Files.** `src/commands/file.lisp` (uses existing `changed-disk-p`, `src/buffer/file.lisp:188-200`). **Size:** S.

### DS-6: Mixed-EOL round-trip must never delete characters

**Problem.** Empirically reproduced: a CRLF-first file containing LF-only lines gets the **last character of every LF line deleted** on save (`two`→`tw`). Read path strips the final char of every line assuming `\r` (`src/buffer/file.lisp:36-43`); write path re-appends one uniform EOL (`:140-150`); detection takes the first EOL seen (`src/file.lisp:120`).

**Required behavior.**
1. Read path MUST strip a trailing `\r` only when actually present — never blind final-char removal.
2. Mixed-EOL files: either (a) preserve per-line EOLs byte-exactly on round-trip, or (b) normalize to the detected dominant EOL **with a visible one-time message** naming the file mixed. Option (b) is acceptable; silent character deletion is not.
3. A no-op open→save MUST be byte-identical for all single-EOL files (LF, CRLF, CR, missing trailing newline).

**Acceptance.** Rove test with the audit corpus: LF, CRLF, CR, mixed-both-orders, no-trailing-newline — assert byte-identical round-trip (or documented normalization with zero character loss). This is the regression test that must never be skipped.

**Files.** `src/buffer/file.lisp`. **Size:** M. **Risk:** touches the hottest I/O path; extensive corpus test is the mitigation.

### DS-7: Encoding fallback + explicit override

**Problem.** Empirically reproduced: detection is hardwired to inquisitor's `:jp` scheme (`src/file.lisp:118-122`); Latin-1, UTF-16, and UTF-8-with-one-bad-byte files misdetect, decoding fails, and `find-file-buffer` deletes the buffer and errors (`src/buffer/file.lisp:97-101`). Such files are **unopenable** — no override command exists.

**Required behavior.**
1. New command `revert-buffer-with-encoding` (and `find-file` prompt on decode failure): open with an explicitly named external format instead of refusing.
2. On decode failure, offer latin-1 (never fails, byte-preserving) as the fallback rather than deleting the buffer.
3. Detection scheme SHOULD be an editor variable (`:jp` default upstream, `:utf-8`-first for the fork).
4. Read-only raw/lossy view for genuinely binary files is a stretch goal, not required.

**Acceptance.** Rove: Latin-1 and invalid-UTF-8 corpus files open via fallback with no buffer deletion; explicit-encoding command decodes Latin-1 correctly; UTF-8 files still auto-detect. Round-trip of the fallback-opened file preserves bytes.

**Files.** `src/file.lisp`, `src/buffer/file.lisp`, new command in `src/commands/file.lisp`. **Size:** M.

### DS-8 (stretch): Emergency save on SIGTERM/SIGHUP

**Required behavior.** On SIGTERM/SIGHUP, checkpoint all modified buffers (DS-3 mechanism) before exiting. SBCL signal handling in the ncurses frontend only.

**Acceptance.** Manual: unsaved edits, `kill -TERM` → checkpoints exist, recovery works. **Size:** S once DS-3 exists. **Risk:** signal handlers + curses teardown ordering; acceptable to drop if flaky.

---

## Milestone 2 — Pathological input must not brick the session

### PI-1: Long-line highlighting cap and interruptible syntax scan

**Problem.** Empirically measured: 3.8MB single-line JS never opens (killed at 14 min CPU); scan is ~O(n²) in line length (100KB→9.4s, 500KB→194s); the scan runs inside `without-interrupts` (`src/buffer/internal/syntax-parser.lisp:35`) so **C-g cannot abort it** (`src/buffer/interrupt.lisp:16-34`); the whole physical line is the atomic unit (`src/buffer/internal/tmlanguage.lisp:433-439`).

**Required behavior.**
1. Lines longer than a threshold (editor variable, default ~10,000 chars) MUST be excluded from tmlanguage syntax scanning (rendered unhighlighted), like Emacs `so-long` / VS Code's tokenization cap.
2. C-g MUST be able to abort any syntax scan: either check the interrupt flag between pattern iterations, or restructure so the scan runs outside `without-interrupts` in bounded chunks.
3. Opening any file, regardless of line structure, MUST reach an editable state in bounded time.

**Acceptance.** Scripted tmux test (reuse audit methodology): 3.8MB single-line file opens < 5s and keystroke echo < 100ms; C-g during a deliberately slow scan returns to the prompt < 1s. Rove: threshold variable respected; normal multi-line files still highlight.

**Files.** `src/buffer/internal/tmlanguage.lisp`, `src/buffer/internal/syntax-parser.lisp`, `src/syntax-scanner.lisp`. **Size:** M. **Risk:** interrupt-safety of partial scans — prefer the cap (1) first, interruptibility (2) second.

### PI-2: Large-file guard

**Required behavior.** Files above a size threshold (default ~30MB, editor variable) open in fundamental mode with highlighting and expensive hooks off, after a y/n prompt. Rationale: 50MB log measured at 8.8s open / 816MB RSS with highlighting machinery active.

**Acceptance.** Manual: 50MB file prompts and opens fast; threshold configurable; small files unaffected.

**Files.** `find-file` path. **Size:** S.

---

## Milestone 3 — Terminal frontend table stakes

All items verified by a scripted tmux/xterm checklist (no headless assertion possible — CI's fake-interface discards rendering).

### TF-1: Bracketed paste

**Problem.** No support anywhere (grep confirms); pastes replay as keystrokes through auto-indent and any ESC byte in the paste is interpreted as a key. ncurses input path has no paste concept (`frontends/ncurses/input.lisp:114-144`).

**Required behavior.** Enable mode 2004 on init (and disable on suspend/exit); parse `ESC[200~`…`ESC[201~`; insert payload as literal text bypassing keymaps/auto-indent/abbrev; the whole paste is **one undo unit**. The server frontend's `paste-using-mode` (`frontends/server/main.lisp:803-811`) shows the core-side insertion pattern to reuse.

**Acceptance.** tmux script: paste a multi-line Lisp snippet with leading whitespace into lisp-mode — buffer content is byte-identical to the clipboard; single C-/ undoes it; pasting text containing `ESC` does not trigger commands. **Size:** M.

### TF-2: OSC 52 clipboard

**Problem.** Clipboard chain is local-exec only (`frontends/ncurses/clipboard.lisp:7-15`); on a headless ssh box there is no system clipboard at all.

**Required behavior.** Copy: emit OSC 52 (base64, chunked under the common 100KB terminal cap, tmux passthrough wrapping when `$TMUX` set). It becomes the **first** fallback when no local tool works, or is explicitly selected via editor variable. Paste via OSC 52 read is NOT required (most terminals disable it); paste is TF-1's job.

**Acceptance.** tmux-over-ssh script: kill text in Lem on a remote host → local system clipboard contains it (verify in kitty or alacritty + tmux with `set -g allow-passthrough on` noted in docs). **Size:** S-M.

### TF-3: 24-bit color

**Problem.** Capped at 256 colors with nearest-HSV quantization, and Lem **mutates the terminal's global palette registers 8-255** via `init-color` (`frontends/ncurses/term.lisp:41-57,326-339`), leaking a corrupted palette into the enclosing session.

**Required behavior.**
1. When `COLORTERM=truecolor|24bit` or terminfo advertises RGB, emit direct-color SGR (38;2/48;2) — via ncurses extended color pairs if the linked ncurses supports it, else direct escape output.
2. In the 256-color fallback, STOP redefining palette registers; quantize only.
3. Palette state restored on exit/suspend in any path that still touches it.

**Acceptance.** tmux script: truecolor theme renders with distinct RGB values (capture with `tmux capture-pane -e`); after quitting Lem, other panes' colors are unchanged. **Size:** M-L. **Risk:** the biggest terminal item; consider cl-charms extended-pair support first.

### TF-4: Unicode width correctness

**Problem.** Hand-maintained ~Unicode-10 east-asian table (`src/common/character/eastasian.lisp:7-35`); `char-width` returns 1 for everything unknown **including combining marks and ZWJ** (`src/common/character/string-width-utils.lisp:62-75`) — modern emoji and diacritics misalign columns.

**Required behavior.** Regenerate the width table from current Unicode `EastAsianWidth.txt` (check in the generator script); combining marks (Mn/Me) and ZWJ MUST be width 0; emoji presentation sequences width 2. Ambiguous-width configurable (existing behavior preserved).

**Acceptance.** Rove: width assertions for a sample set (é as e+U+0301, 🧪 U+1F9EA, 🫠 U+1FAE0, family ZWJ sequence, CJK). tmux: a line containing these renders with the cursor landing where the terminal thinks it should. **Size:** M (mostly table generation).

### TF-5: Mouse support in the default build

**Problem.** The SGR-1006 decoder lives in `contrib/mouse-sgr1006/`, referenced by no `.asd` in the build (`frontends/ncurses/input.lisp:130-134` calls it via `uiop:symbol-call` into a package absent from the image); `*mouse-mode*` is 0 on unix (`frontends/ncurses/term.lisp:25`).

**Required behavior.** Bundle the decoder into `lem-ncurses.asd`; expose a `toggle-mouse` command / editor variable (default on in fork init layer). Clicking moves point; wheel scrolls; mouse can be disabled for terminal-native selection.

**Acceptance.** tmux `send-keys` SGR sequences: click positions cursor, no crash when sequences arrive with mouse off. **Size:** S.

### TF-6: Key decoding resilience

**Problem.** Hardcoded ncurses extended keycodes (`frontends/ncurses/key.lisp:71-83,114`), one-family CSI parser (`input.lisp:49-109`), fixed 100ms ESC timeout (`config.lisp:8`) that splits `M-x` into `ESC x` under ssh latency; cursor-shape changes fork a `printf` subprocess per toggle (`term.lisp:483-494`).

**Required behavior.**
1. ESC timeout becomes an editor variable (raise default to 200ms; document tmux `escape-time` interplay).
2. CSI parser extended to the full `CSI 1;<mod>` family plus modified Home/End/PgUp/PgDn/F-keys (`CSI <n>;<mod>~`).
3. Cursor-shape writes DECSCUSR directly to the tty instead of forking `printf`.
4. Kitty keyboard protocol is a non-goal.

**Acceptance.** tmux script sending raw sequences: C-Up, M-Left, S-F5, C-PgDn all decode to the right key events (assert via a test command that echoes the last key); vi-mode insert/normal toggle shows no subprocess in `strace -f -e execve`. **Size:** M.

---

## Sequencing & goal definition

```
M0 (day 1)  →  DS-1, DS-5 (small, immediate safety)
            →  DS-6, DS-7 (I/O correctness, shared corpus tests)
            →  DS-2, then DS-4 (atomic save foundation, then backups)
            →  DS-3 (recovery — highest value, needs the save-path dust settled)
            →  PI-1, PI-2
            →  TF-1..TF-6 (independent of each other; TF-1/TF-2 first, TF-3 last)
DS-8 opportunistic after DS-3.
```

**The goal is met when:** every DS and PI acceptance criterion passes (rove suite green + manual checks), TF-1 through TF-5 pass the tmux checklist, and the patchset rebases cleanly onto current upstream main. At that point terminal Lem meets or beats the Vim data-safety baseline and cannot be hung by input — the two audit dealbreakers.

**Tracking:** GitHub milestones `M1 Data safety`, `M2 Pathological input`, `M3 Terminal frontend` on `yathxyz/lem`, one issue per requirement ID, each linking to its section here.

## Standing risks

- **Rebase drift:** upstream is active (~40 commits/month). Mitigation: constraint 1, plus a monthly `git fetch upstream && git rebase` habit; the rove corpus tests catch upstream regressions to patched behavior.
- **Bus factor 1 upstream:** if upstream stalls, this fork's patchset is self-sufficient for the daily-driver bar; nothing here depends on upstream cooperation.
- **Line-number drift:** all file:line cites are baseline-commit references, not live anchors.
