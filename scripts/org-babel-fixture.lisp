(in-package :lem-yath)

(defun org-babel-test-report-path ()
  (or (uiop:getenv "LEM_YATH_ORG_BABEL_REPORT")
      (error "LEM_YATH_ORG_BABEL_REPORT is unset")))

(defun org-babel-test-log (control &rest arguments)
  (with-open-file (stream (org-babel-test-report-path)
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :append)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun org-babel-test-find (text)
  (let ((point (current-point)))
    (buffer-start point)
    (unless (search-forward-regexp point (cl-ppcre:quote-meta-chars text))
      (error "Babel test text not found: ~s" text))
    point))

(defmacro define-org-babel-test-goto (name text)
  `(define-command ,name () ()
     (move-point (current-point) (org-babel-test-find ,text))))

(define-org-babel-test-goto lem-yath-test-babel-goto-shell "printf 'shell-ok")
(define-org-babel-test-goto lem-yath-test-babel-goto-sqlite "select 'db-ok")
(define-org-babel-test-goto lem-yath-test-babel-goto-python "print('python-ok")
(define-org-babel-test-goto lem-yath-test-babel-goto-c "puts(\"c-ok")
(define-org-babel-test-goto lem-yath-test-babel-goto-directory
  "printf '%s\\n' \"$PWD\"")
(define-org-babel-test-goto lem-yath-test-babel-goto-none "touch none-created")
(define-org-babel-test-goto lem-yath-test-babel-goto-cancel
  "touch cancelled-created")
(define-org-babel-test-goto lem-yath-test-babel-goto-elisp
  "message \"must-not-run\"")
(define-org-babel-test-goto lem-yath-test-babel-goto-postgres
  "select 'pg-ok'")

(defun org-babel-test-one-line (text)
  (coerce (substitute #\| #\Newline text) 'simple-string))

(define-command lem-yath-test-babel-report () ()
  (let* ((block (org-babel-block-at-point (current-point) t))
         (headers (org-babel-effective-headers block)))
    (multiple-value-bind (start end) (org-babel-existing-result-bounds block)
      (org-babel-test-log
       "BLOCK language=~a db=~s result=~s modified=~a"
       (org-babel-block-language block)
       (org-babel-header "db" headers)
       (if start
           (org-babel-test-one-line (points-to-string start end))
           "NONE")
       (if (buffer-modified-p (current-buffer)) "yes" "no")))))

(define-command lem-yath-test-babel-binding-report () ()
  (let ((command (find-keybind (lem-core::parse-keyspec "C-c C-c"))))
    (org-babel-test-log "BINDING ~a"
                        (if (symbolp command)
                            (symbol-name command)
                            (princ-to-string command)))))

(define-command lem-yath-test-babel-table-format-report () ()
  (let ((result
          (org-babel-tabular-output
           (format nil "status~cvalue~%db-ok~cdb-ok~%" #\Tab #\Tab))))
    (org-babel-test-log "TABLE-FORMAT kind=~a length=~d text=~a"
                        (org-babel-result-kind result)
                        (length (org-babel-result-text result))
                        (org-babel-test-one-line
                         (org-babel-result-text result)))))
