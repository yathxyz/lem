(in-package :lem-yath)

;; Loaded only in the disposable daemon owned by the polling race test.
(defvar *poll-test-original* (symbol-function 'file-state-signature))
(defvar *poll-test-release* (bt2:make-semaphore))
(defvar *poll-test-blocked* (bt2:make-semaphore))
(defvar *poll-test-path* nil)
(defvar *poll-test-worker* nil)
(defvar *poll-test-buffer* nil)
(defvar *poll-test-scan* nil)

(stop-safe-auto-revert-timer)
(stop-file-notify-service)
(remove-hook *pre-command-hook* 'safe-auto-revert-poll)

(setf (symbol-function 'file-state-signature)
      (lambda (path &rest arguments)
        (let ((signature (apply *poll-test-original* path arguments)))
          (when (and (equal path *poll-test-path*)
                     (string= (bt2:thread-name (bt2:current-thread))
                              "lem-yath/auto-revert-scan"))
            (setf *poll-test-worker* (bt2:current-thread))
            (bt2:signal-semaphore *poll-test-blocked*)
            (unless (bt2:wait-on-semaphore *poll-test-release* :timeout 20)
              (error "Polling test did not release its reader")))
          signature)))

(defun poll-test-open (path)
  (assert (null *safe-auto-revert-scan*))
  (setf *poll-test-buffer* (find-file-buffer path)
        *poll-test-path* path
        *poll-test-worker* nil
        *poll-test-release* (bt2:make-semaphore)
        *poll-test-blocked* (bt2:make-semaphore))
  (switch-to-buffer *poll-test-buffer*)
  ;; FIND-FILE can reconcile watches, but this fixture tests polling alone.
  (stop-file-notify-service)
  t)

(defun poll-test-start ()
  (setf *last-auto-revert-check-time* nil)
  (with-current-buffer *poll-test-buffer*
    (safe-auto-revert-poll))
  (setf *poll-test-scan* *safe-auto-revert-scan*)
  (assert *poll-test-scan*)
  t)

(defun poll-test-await ()
  (not (null (bt2:wait-on-semaphore *poll-test-blocked* :timeout 0))))

(defun poll-test-release ()
  (bt2:signal-semaphore *poll-test-release*)
  t)

(defun poll-test-finished-p ()
  (and (null *safe-auto-revert-scan*)
       (not (bt2:thread-alive-p *poll-test-worker*))))

(defun poll-test-cleanup ()
  (unless (deleted-buffer-p *poll-test-buffer*)
    (buffer-unmark *poll-test-buffer*)
    (kill-buffer *poll-test-buffer*))
  (setf *poll-test-path* nil)
  t)
