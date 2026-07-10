;;;; UI: relative line numbers (display-line-numbers-type 'relative),
;;;; tab bar (tab-bar-mode), show-paren/highlight-line are Lem defaults.
;;;; The Emacs config loads no color theme by default, so neither do we.

(in-package :lem-yath)

(setf lem/line-numbers:*relative-line* t)
(setf (variable-value 'lem/line-numbers:line-numbers :global) t)

;; tab-bar-mode equivalent (tmux-like frame tabs). Toggled after init:
;; the frame isn't fully set up while the init file loads.
(add-hook *after-init-hook*
          (lambda ()
            (ignore-errors
              (uiop:symbol-call :lem/frame-multiplexer :toggle-frame-multiplexer))))
