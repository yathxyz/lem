;;;; Test setup and observations only. The configured image owns every product
;;;; system, workspace, command, checkpoint writer, and recovery operation.
(defpackage :lem-native-notes-fixture
  (:use :cl)
  (:local-nicknames (:notes :lem-structured-notes)
                    (:adapter :lem-structured-notes/lem-adapter)))
(in-package :lem-native-notes-fixture)

(defvar *time* (encode-universal-time 0 30 9 14 9 2026 0))
(defvar *buffer-ids* (make-hash-table :test #'eq))
(defvar *next-buffer-id* 0)
(defvar *saved-environment* nil)
(defvar *file-hook-calls* 0)

(defun object (&rest pairs)
  (let ((result (make-hash-table :test #'equal)))
    (loop for (key value) on pairs by #'cddr do (setf (gethash key result) value))
    result))
(defun json (value) (with-output-to-string (stream) (yason:encode value stream)))

(defun install ()
  ;; Only the two documented test clock seams are replaced. Workspace setup
  ;; belongs to startup; this fixture never configures or repairs it.
  (setf (symbol-function 'adapter::lem-notes-now) (lambda () *time*)
        (symbol-function 'adapter::lem-notes-today) (lambda () "2026-09-14"))
  t)

(defun roots ()
  (let ((context (adapter:lem-current-notes-workspaces)))
    (object "work" (uiop:native-namestring
                    (notes:notes-workspace-root
                     (adapter:lem-notes-workspace-context-workspace context)))
            "public" (let ((public (adapter:lem-notes-workspace-context-public-workspace context)))
                       (when public (uiop:native-namestring (notes:notes-workspace-root public))))
            "host_identity" (eq context lem-yath::*native-notes-workspaces*))))

(defun prompt-label ()
  (let ((prompt (lem-core::frame-prompt-window (lem:current-frame))))
    (if prompt
        (lem/prompt-window::prompt-buffer-prompt-string (lem:window-buffer prompt)) "")))

(defun state (&optional (buffer (lem:current-buffer)))
  (object "name" (lem:buffer-name buffer)
          "identity" (or (gethash buffer *buffer-ids*)
                         (setf (gethash buffer *buffer-ids*) (incf *next-buffer-id*)))
          "filename" (lem:buffer-filename buffer)
          "text" (lem:buffer-text buffer)
          "tick" (lem:buffer-modified-tick buffer)
          "modified" (not (null (lem:buffer-modified-p buffer)))
          "read_only" (not (null (lem:buffer-read-only-p buffer)))
          "point" (lem:position-at-point (lem:current-point))))

(defun show-buffer (name &key end)
  (let ((buffer (or (lem:get-buffer name) (error "Missing fixture buffer"))))
    (lem:switch-to-buffer buffer)
    (when end (lem:buffer-end (lem:current-point)))
    (lem:redraw-display :force t)
    t))

(defun point-at (needle)
  (let ((position (search needle (lem:buffer-text (lem:current-buffer)))))
    (assert position () "Fixture source does not contain the selected text")
    (lem:move-to-position (lem:current-point) (1+ position))
    (lem:redraw-display :force t)
    t))

(defun new-scratch ()
  (let ((buffer (lem:make-buffer (lem:unique-buffer-name "*Native notes scratch*"))))
    (lem:switch-to-buffer buffer)
    (lem:redraw-display :force t)
    (lem:buffer-name buffer)))

(defun file-identities ()
  (coerce (loop for buffer in (lem:buffer-list)
                when (lem:buffer-filename buffer)
                  collect (lem:buffer-filename buffer))
          'vector))

(defun current-node-id ()
  (multiple-value-bind (snapshot context) (adapter:lem-current-lsm-snapshot (lem:current-buffer))
    (declare (ignore context))
    (notes:semantic-node-id (adapter:lem-current-lsm-node (lem:current-buffer) snapshot))))

(defun org-routes ()
  (coerce
   (loop for (state keymap) in (list (list "normal" lem-vi-mode:*normal-keymap*)
                                     (list "visual" lem-vi-mode:*visual-keymap*))
         append (loop for keys in '("n r d t" "n r d d" "n j j" "o")
                      collect (object "state" state "keys" keys
                                      "command" (symbol-name (lem-yath::leader-binding-command keymap keys)))))
   'vector))

(defun change-environment (work public)
  (assert (null *saved-environment*) () "Environment fixture is already active")
  (setf *saved-environment* (list (uiop:getenv "WORKDIR") (uiop:getenv "PUBLIC_ORG_DIR"))
        (uiop:getenv "WORKDIR") work
        (uiop:getenv "PUBLIC_ORG_DIR") public)
  t)
(defun restore-environment ()
  (when *saved-environment*
    (setf (uiop:getenv "WORKDIR") (first *saved-environment*)
          (uiop:getenv "PUBLIC_ORG_DIR") (second *saved-environment*)
          *saved-environment* nil))
  t)

(defun unexpected-file-hook (&rest arguments)
  (declare (ignore arguments))
  (incf *file-hook-calls*)
  (error "Recovery must not visit a file or activate file hooks"))
(defun guard-file-hooks ()
  (setf *file-hook-calls* 0)
  (lem:add-hook lem:*before-find-file-hook* 'unexpected-file-hook)
  (lem:add-hook lem:*find-file-hook* 'unexpected-file-hook)
  t)

(defun recovery-origin ()
  (let ((origin (lem-daemon/recovery:buffer-recovery-origin (lem:current-buffer))))
    (object "id" (getf origin :id) "filename" (getf origin :filename)
            "status" (symbol-name (getf origin :disk-status)))))

(defun recovered-buffer-name (id)
  (loop for buffer in (lem:buffer-list)
        when (equal id (getf (lem-daemon/recovery:buffer-recovery-origin buffer) :id))
          return (lem:buffer-name buffer)))
