;;;; Native editor-client routing for the configured Lem environment.

(in-package :lem-yath)

(defvar *configured-shutdown-error* nil)

#+linux
(defun ensure-toolkit-job-manager ()
  "Return the ready startup manager without disk or process I/O."
  (let ((manager lem-toolkit/jobs:*default-manager*))
    (unless (and manager (lem-toolkit/jobs:job-manager-ready-p manager))
      (editor-error "The Lisp job manager is unavailable; inspect the startup log"))
    manager))

(defun configure-daemon-server ()
  "Start a local listener and route child Git editors to this Lem session."
  #+(and sbcl linux)
  (progn
    (lem-daemon:start-server)
    (lem-daemon:configure-editor-environment :force-git-editor t)
    ;; Startup is the explicit blocking boundary. No command opens or
    ;; reconciles a journal while the editor is handling user input.
    (unless (and lem-toolkit/jobs:*default-manager*
                 (lem-toolkit/jobs:job-manager-ready-p lem-toolkit/jobs:*default-manager*))
      (setf lem-toolkit/jobs:*default-manager*
            (lem-toolkit/jobs:open-job-manager :name (lem-daemon:server-name))))
    (configure-native-agent)
    (lem-daemon/recovery:enable :server-name (lem-daemon:server-name) :interval 5)
    (setf *configured-shutdown-error* nil)))

(defun stop-configured-daemon-server ()
  "Release the local listener when this editor exits."
  #+(and sbcl linux)
  (handler-case
      (let ((checkpoint-error *configured-shutdown-error*))
        (unwind-protect
             (handler-case (lem-daemon/recovery:checkpoint-now)
               (error (condition)
                 (setf checkpoint-error condition)
                 (format *error-output* "~&Final recovery checkpoint failed: ~a~%" condition)))
          (unwind-protect
               (unwind-protect
                    (stop-configured-native-agent)
                 (when lem-toolkit/jobs:*default-manager*
                   (let ((manager lem-toolkit/jobs:*default-manager*))
                     (unwind-protect
                          (progn
                            (lem-toolkit/jobs:close-job-manager manager)
                            (dolist (job (lem-toolkit/jobs:list-jobs manager))
                              (when (gethash "journal-error"
                                            (lem-toolkit/jobs:job-snapshot job :include-output nil))
                                (error "Managed job journal durability is uncertain"))))
                       (setf lem-toolkit/jobs:*default-manager* nil)))))
            (lem-daemon/recovery:disable)
            (lem-daemon:stop-server)))
        (when checkpoint-error (error checkpoint-error)))
    (error (condition)
      ;; Manager globals are cleared during cleanup. Retain a failed durability
      ;; result so another stop cannot mistake absent managers for clean state.
      (setf *configured-shutdown-error* (or *configured-shutdown-error* condition))
      (error condition))))

(add-hook *exit-editor-hook* 'stop-configured-daemon-server)
(initialize-editor-feature 'configure-daemon-server)
