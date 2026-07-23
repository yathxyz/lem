(in-package :lem-yath)

(let ((directory (uiop:getenv "LEM_YATH_ORG_PUBLISH_TEST_BIN")))
  (when (and directory (plusp (length directory)))
    (setf (uiop:getenv "PATH")
          (format nil "~a:~a" directory (or (uiop:getenv "PATH") "")))))

(defun org-publish-test-report-path ()
  (or (uiop:getenv "LEM_YATH_ORG_PUBLISH_REPORT")
      (error "LEM_YATH_ORG_PUBLISH_REPORT is unset")))

(defun org-publish-test-log (control &rest arguments)
  (with-open-file (stream (org-publish-test-report-path)
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :append)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(define-command lem-yath-test-org-publish-bindings () ()
  (dolist (keys '("C-c C-e"))
    (let ((command (find-keybind (lem-core::parse-keyspec keys))))
      (org-publish-test-log "BINDING ~a ~a" keys
                            (if (symbolp command)
                                (symbol-name command)
                                (princ-to-string command))))))

(define-command lem-yath-test-org-publish-insert-live-text () ()
  (insert-string (buffer-end-point (current-buffer))
                 (format nil "~%Live unsaved marker.~%"))
  (message "Inserted live export marker"))

(defun org-publish-test-run-core ()
  (alexandria:when-let ((mode (uiop:getenv "LEM_YATH_ORG_PUBLISH_CORE_MODE")))
    (handler-case
        (let* ((force-p (string= mode "force"))
               (plan (org-publish-make-plan "org-roam" force-p))
               (request
                 (make-live-project-request
                  1 (capture-project-request-origin))))
          (when (string= mode "cancel")
            (cancel-project-request request))
          (handler-case
              (let ((counts (org-publish-run-plan plan request)))
                (org-publish-test-log
                 "CORE html-written=~d html-skipped=~d static-written=~d static-skipped=~d unresolved=~d ambiguous=~d"
                 (org-publish-counts-html-written counts)
                 (org-publish-counts-html-skipped counts)
                 (org-publish-counts-static-written counts)
                 (org-publish-counts-static-skipped counts)
                 (org-publish-counts-unresolved-links counts)
                 (org-publish-counts-ambiguous-links counts)))
            (project-request-cancelled ()
              (org-publish-test-log "CORE-CANCELLED"))))
      (error (condition)
        (org-publish-test-log "CORE-ERROR ~a" condition)))))

(org-publish-test-run-core)
