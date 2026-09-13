;;;; Explicit structured-note commands beside the existing Org workflows.

(in-package :lem-yath)

(defvar *native-notes-workspaces* nil)
(defvar *native-notes-work-root* nil)
(defvar *native-notes-public-root* nil)
(defvar *native-notes-setup-error* nil)
(defvar *native-notes-status-buffer* nil)

(defun configure-native-notes ()
  "Pin notes roots at startup; unavailable notes storage does not stop editing."
  (unless *native-notes-workspaces*
    (setf *native-notes-setup-error* nil)
    (handler-case
        (let ((public (uiop:getenvp "PUBLIC_ORG_DIR")))
          (setf *native-notes-work-root* (workdir)
                *native-notes-public-root*
                (when public
                  (uiop:ensure-directory-pathname
                   (expand-file-name public (uiop:getcwd)))))
          (setf *native-notes-workspaces*
                (lem-structured-notes/lem-adapter:configure-lem-notes-workspaces
                 :work-root *native-notes-work-root*
                 :public-root *native-notes-public-root*)))
      (error (condition)
        (setf *native-notes-setup-error*
              (format nil "Notes workspace setup unavailable (~a). Check WORKDIR and optional PUBLIC_ORG_DIR."
                      (type-of condition))))))
  *native-notes-workspaces*)

(define-command lem-yath-notes-status () ()
  "Inspect the startup-pinned structured-notes roots without opening note files."
  (let ((buffer
          (if (and *native-notes-status-buffer*
                   (eq *native-notes-status-buffer* (get-buffer (buffer-name *native-notes-status-buffer*)))
                   (null (buffer-filename *native-notes-status-buffer*)))
              *native-notes-status-buffer*
              (setf *native-notes-status-buffer*
                    (make-buffer (unique-buffer-name "*Notes workspace*") :enable-undo-p nil)))))
    (with-inhibit-read-only ()
      (erase-buffer buffer)
      (insert-string
       (buffer-point buffer)
       (with-output-to-string (out)
         (format out "Structured notes: ~a~%Configured work root: ~a~%Configured public root: ~a~%~%"
                 (if *native-notes-workspaces* "ready" "unavailable")
                 (or *native-notes-work-root* "not configured")
                 (or *native-notes-public-root* "not configured"))
         (when *native-notes-setup-error*
           (format out "~a~%~%" *native-notes-setup-error*))
         (format out "Explicit LSM commands create unsaved edits. Existing Org commands and bindings remain available.~%")))
      (buffer-start (buffer-point buffer)))
    (setf (buffer-read-only-p buffer) t)
    (buffer-mark-saved buffer)
    (pop-to-buffer buffer)))

(initialize-editor-feature 'configure-native-notes)
