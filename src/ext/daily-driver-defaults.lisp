(defpackage :lem/daily-driver-defaults
  (:use :cl :lem)
  (:documentation
   "Fork-owned personal defaults for the daily-driver patchset. This layer only
flips defaults; it defines no new mechanism. Keeping it separate keeps the
behavioral diff isolated from the upstream mechanism diff so both rebase
cleanly. See SPEC.md, constraint 3.")
  #+sbcl
  (:lock t))
(in-package :lem/daily-driver-defaults)

;;; DS-7: encoding detection scheme.
;;;
;;; Upstream detects with inquisitor's :JP scheme (UTF-8, then Shift_JIS /
;;; EUC-JP). Every scheme tries UTF-8 first, so UTF-8 files are unaffected; the
;;; scheme only decides which legacy encoding is attempted for non-UTF-8 files.
;;; For a Western daily driver, :TR (UTF-8, then ISO-8859-9 / CP1254) is the
;;; closest inquisitor equivalent to "UTF-8 first, Latin fallback": Latin-1 text
;;; decodes cleanly instead of misdetecting as Japanese, and anything the
;;; detected encoding still cannot decode falls back to latin-1 losslessly via
;;; FIND-FILE-BUFFER.
(setf (variable-value 'lem-core:detect-encoding-scheme :global) :tr)

;;; DS-4: back up each file's pre-save content to <file>~ once per session,
;;; independent of auto-save-mode. Upstream keeps this off.
(setf lem/backup-on-save:*backup-on-save* t)
(add-hook (variable-value 'before-save-hook :global t)
          'lem/backup-on-save:backup-on-save)

;;; PI-2: large-file guard. Files above this size open in fundamental mode with
;;; syntax highlighting and expensive mode hooks off, after a y/n prompt on the
;;; find-file path. Upstream ships this disabled (threshold NIL).
(setf (variable-value 'lem-core:large-file-threshold :global) (* 30 1024 1024))

;;; TF-2: OSC 52 clipboard. Always emit OSC 52 from the terminal frontend so a
;;; kill/copy reaches the local system clipboard over ssh+tmux, where there is no
;;; local clipboard tool to shell out to. Upstream defaults to :FALLBACK (OSC 52
;;; only when no local tool works); for the ssh/tmux daily-driver workflow the
;;; terminal is the clipboard bridge, so make it unconditional. Requires the
;;; outer terminal's `set-clipboard on` and, inside tmux, `allow-passthrough on`.
(setf (variable-value 'lem-core:clipboard-osc52 :global) t)

;;; TF-5: terminal mouse support. Enable mouse reporting so clicking moves point
;;; and the wheel scrolls; the terminal frontend reads MOUSE-MODE at startup and
;;; emits the xterm enable sequences. Upstream ships this off so the terminal
;;; keeps native selection by default; TOGGLE-MOUSE flips it at runtime.
(setf (variable-value 'lem-core:mouse-mode :global) t)

;;; DS-3: crash-recovery checkpoints. Periodically snapshot modified file-backed
;;; buffers to $XDG_DATA_HOME/lem/autosave/ without touching the real file, delete
;;; the snapshot on a successful save, and offer recovery on find-file when a
;;; newer snapshot survives a crash. Upstream ships this off.
(lem/checkpoint:checkpoint-mode t)

;;; SPEC-VK VK-4: paranoid edit engine. The kernel-backed edit engine's mode is
;;; a BUILD-time default, not a load-time flip (tests and plain builds must stay
;;; :release), so it is wired where the image is built rather than here:
;;; `scripts/daily-driver-update.sh` sets LEM_PARANOID=1, which makes
;;; `scripts/build-ncurses.lisp` push :lem-paranoid onto *features* before
;;; compiling, and `lem/buffer/internal:*edit-engine-mode*` then defaults to
;;; :paranoid (per-edit certified wf-buffer checks on the edited region).
;;; Toggle: drop LEM_PARANOID from daily-driver-update.sh (or build plain
;;; `make ncurses`) once the VK-4 swap has soaked; runtime escape hatch:
;;; (setf lem/buffer/internal:*edit-engine-mode* :release).
