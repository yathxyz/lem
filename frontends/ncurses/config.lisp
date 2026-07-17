(defpackage :lem-ncurses/config
  (:use :cl
        :lem)
  (:export :escape-delay
           :truecolor))
(in-package :lem-ncurses/config)

;; Escape key delay: how long (ms) to wait for a byte following ESC before
;; treating ESC as a standalone key rather than the start of a meta chord or a
;; CSI escape sequence. Raised from 100 to 200 so that M-x (ESC then x) and
;; modified arrows survive ssh/network latency instead of splitting into a bare
;; ESC followed by a literal key.
;;
;; Interplay with tmux: tmux's own `escape-time` (default 500ms, often set to
;; 10) governs how long tmux buffers a lone ESC before forwarding it. This Lem
;; variable governs Lem's wait for the *next* byte after that ESC arrives, so
;; the two stack. Keep tmux `escape-time` small (10-50ms) and rely on this
;; variable for the human/network delay. Read at use time via variable-value,
;; so `(setf (variable-value 'lem-ncurses/config:escape-delay :global) N)` takes
;; effect without a rebuild.
(define-editor-variable escape-delay 200
  "Milliseconds to wait for a byte after ESC before treating ESC as a standalone key.")

;; 24-bit (direct) color output. Read once at frontend startup (term-init), so
;; setting it from init.lisp works but flipping it mid-session does not.
;; :auto enables direct color when COLORTERM is truecolor/24bit or the
;; terminal's own terminfo already advertises a direct-color palette; t forces
;; the attempt (falls back to 256 colors when unsupported); nil forces 256-color
;; quantization. In every mode the terminal's palette registers are left alone.
(define-editor-variable truecolor :auto
  "Direct 24-bit color output: t to force on, nil to force off, :auto to detect.")
