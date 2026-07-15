(in-package :lem-yath)

(defvar *org-source-edit-test-snapshot* 0)

(defun org-source-edit-test-directory ()
  (uiop:ensure-directory-pathname
   (or (uiop:getenv "LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS")
       (error "LEM_YATH_ORG_SOURCE_EDIT_SNAPSHOTS is unset"))))

(defun org-source-edit-test-log (control &rest arguments)
  (with-open-file
      (stream (merge-pathnames "report" (org-source-edit-test-directory))
              :direction :output
              :if-does-not-exist :create
              :if-exists :append)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun org-source-edit-test-binding-name (keys)
  (let ((binding (find-keybind (lem-core::parse-keyspec keys))))
    (if (symbolp binding)
        (symbol-name binding)
        (princ-to-string binding))))

(defun org-source-edit-test-find (text)
  (let ((point (current-point)))
    (buffer-start point)
    (unless (search-forward-regexp point (cl-ppcre:quote-meta-chars text))
      (error "Source-edit test text not found: ~s" text))
    point))

(defmacro define-org-source-edit-test-goto (name text)
  `(define-command ,name () ()
     (move-point (current-point) (org-source-edit-test-find ,text))))

(define-org-source-edit-test-goto lem-yath-test-source-edit-goto-commit
  "print(\"old\")")
(define-org-source-edit-test-goto lem-yath-test-source-edit-goto-protected
  "protected heading")
(define-org-source-edit-test-goto lem-yath-test-source-edit-goto-abort
  "abort-original")
(define-org-source-edit-test-goto lem-yath-test-source-edit-goto-save
  "save-original")
(define-org-source-edit-test-goto lem-yath-test-source-edit-goto-stale
  "stale-original")
(define-org-source-edit-test-goto lem-yath-test-source-edit-goto-read-only
  "read-only-original")
(define-org-source-edit-test-goto lem-yath-test-source-edit-goto-heading
  "Source editing")

(define-command lem-yath-test-source-edit-bindings () ()
  (dolist (keys '("C-c '" "C-c C-k" "C-x C-s"))
    (org-source-edit-test-log "BINDING ~a ~a"
                              keys
                              (org-source-edit-test-binding-name keys)))
  (message "Source edit bindings captured"))

(define-command lem-yath-test-source-edit-report () ()
  (let* ((buffer (current-buffer))
         (session (org-source-edit-session-for-buffer buffer))
         (origin (and session
                      (org-source-edit-session-origin-buffer session))))
    (org-source-edit-test-log
     "CURRENT mode=~a edit=~a modified=~a origin-modified=~a"
     (symbol-name (buffer-major-mode buffer))
     (if (mode-active-p buffer 'org-source-edit-mode) "yes" "no")
     (if (buffer-modified-p buffer) "yes" "no")
     (cond
       ((null origin) "none")
       ((buffer-modified-p origin) "yes")
       (t "no"))))
  (message "Source edit state captured"))

(define-command lem-yath-test-source-edit-point-report () ()
  (org-source-edit-test-log "POINT column=~d text=~s modified=~a"
                            (point-charpos (current-point))
                            (line-string (current-point))
                            (if (buffer-modified-p (current-buffer))
                                "yes"
                                "no"))
  (message "Source edit point captured"))

(define-command lem-yath-test-source-edit-snapshot () ()
  (incf *org-source-edit-test-snapshot*)
  (with-open-file
      (stream (merge-pathnames
               (format nil "state-~d" *org-source-edit-test-snapshot*)
               (org-source-edit-test-directory))
              :direction :output
              :if-does-not-exist :create
              :if-exists :supersede)
    (write-string
     (points-to-string (buffer-start-point (current-buffer))
                       (buffer-end-point (current-buffer)))
     stream))
  (message "Source edit snapshot ~d" *org-source-edit-test-snapshot*))

(define-command lem-yath-test-source-edit-read-only () ()
  (setf (buffer-read-only-p (current-buffer)) t)
  (message "Source buffer read-only"))

(define-command lem-yath-test-source-edit-writable () ()
  (setf (buffer-read-only-p (current-buffer)) nil)
  (message "Source buffer writable"))

(define-command lem-yath-test-source-edit-external-change () ()
  (let* ((session (or (org-source-edit-session-for-buffer)
                      (error "Not in a source edit buffer")))
         (origin (org-source-edit-session-origin-buffer session))
         (point (copy-point (org-source-edit-session-body-start session)
                            :temporary)))
    (with-current-buffer origin
      (insert-string point (format nil "external-change~%")))
    (message "Source body changed externally")))

(define-command lem-yath-test-source-edit-reload-cleanup () ()
  (org-source-edit-cleanup-for-reload)
  (message "Source edit reload cleanup complete"))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F12" 'lem-yath-test-source-edit-point-report)
  (define-key keymap "F11" 'lem-yath-test-source-edit-reload-cleanup))
