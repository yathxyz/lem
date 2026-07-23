(defpackage :lem/emergency-save
  (:use :cl :lem)
  (:documentation
   "DS-8 mechanism: emergency checkpoint of modified buffers when the process is
about to die. The terminating-signal machinery is registered by the ncurses
frontend only; this file just provides the frontend-agnostic, signal-safe entry
point it calls, so the behaviour can be unit-tested without a live terminal. See
SPEC.md, DS-8.")
  (:export :emergency-checkpoint)
  #+sbcl
  (:lock t))
(in-package :lem/emergency-save)

(defun emergency-checkpoint ()
  "Best-effort checkpoint of every modified file-backed buffer, reusing the DS-3
checkpoint mechanism. Intended to run from a terminating-signal handler on a dying
process: it never signals (a failure to checkpoint one buffer must not prevent the
process from exiting) and returns NIL."
  (when (some (lambda (buffer)
                (mode-active-p buffer 'lem/checkpoint:checkpoint-mode))
              (buffer-list))
    (ignore-errors (lem/checkpoint:checkpoint-modified-buffers)))
  nil)
