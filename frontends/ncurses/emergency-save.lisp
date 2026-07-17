(defpackage :lem-ncurses/emergency-save
  (:use :cl)
  (:export :install-emergency-save-handlers))
(in-package :lem-ncurses/emergency-save)

;;; DS-8: emergency save on SIGTERM/SIGHUP.
;;;
;;; When the terminal Lem process is asked to terminate (a `kill`, a closing ssh
;;; session sending SIGHUP, a system shutdown sending SIGTERM), checkpoint every
;;; modified buffer first so the DS-3 crash-recovery flow can restore the edits on
;;; the next start. The handler is deliberately minimal: it runs on an arbitrary
;;; thread while the process is dying, so it does a best-effort checkpoint and then
;;; re-raises the original signal with its default disposition, terminating the
;;; process as it normally would. It does not attempt curses teardown from the
;;; signal handler (that path is prone to hanging); a terminal left in raw mode is
;;; recoverable with `reset`, lost edits are not.
;;;
;;; Registration lives in the ncurses frontend, so no other frontend is affected.

#+sbcl
(defun handle-terminating-signal (signal)
  "Checkpoint modified buffers (best effort), then re-raise SIGNAL with its default
disposition so the process terminates."
  (lem/emergency-save:emergency-checkpoint)
  (sb-sys:enable-interrupt signal :default)
  (sb-unix:unix-kill (sb-unix:unix-getpid) signal))

(defun install-emergency-save-handlers ()
  "Register SIGTERM/SIGHUP handlers that checkpoint modified buffers before the
process dies. Must be called at editor startup (signal handlers do not survive an
image dump). Registration failures are swallowed so a platform lacking these
signals still starts the editor."
  #+sbcl
  (ignore-errors
   (dolist (signal (list sb-unix:sigterm sb-unix:sighup))
     (let ((signal signal))
       (sb-sys:enable-interrupt
        signal
        (lambda (sig info context)
          (declare (ignore info context))
          (handle-terminating-signal sig))))))
  nil)
