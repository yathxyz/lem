(in-package :lem-yath)

(defvar *citar-test-fake-bin* (uiop:getenv "LEM_YATH_CITAR_FAKE_BIN"))
(setf (uiop:getenv "PATH")
      (format nil "~a:~a" *citar-test-fake-bin* (uiop:getenv "PATH")))

(defvar *citar-test-report* (uiop:getenv "LEM_YATH_CITAR_REPORT"))
(defvar *citar-test-source-buffer* (current-buffer))
(defvar *citar-test-source-text* (buffer-text (current-buffer)))

(defun citar-test-yes-no (value)
  (if value "yes" "no"))

(defun citar-test-log (control &rest arguments)
  (with-open-file (stream *citar-test-report* :direction :output
                          :if-exists :append :if-does-not-exist :create)
    (apply #'format stream (concatenate 'string control "~%") arguments)))

(defun citar-test-entry (key)
  (find key (citar-entries) :key (lambda (entry) (getf entry :key))
                            :test #'string=))

(defun citar-test-parser-p ()
  (let ((duplicate (citar-test-entry "dup"))
        (escaped (citar-test-entry "escaped"))
        (nested (citar-test-entry "nested")))
    (and duplicate
         (string= "Node Preferred" (getf duplicate :title))
         escaped
         (string= "The \\\"Quoted\\\" Result" (getf escaped :title))
         (string= "2026" (getf escaped :year))
         nested
         (string= "Nested {Group} Title" (getf nested :title))
         (string= "2027" (getf nested :year)))))

(defun citar-test-safe-p ()
  (and (null (citar-note-path "../escape"))
       (null (citar-note-path "link"))
       (null (citar-note-path "*"))
       (not (citar-http-url-p "--help"))
       (not (citar-http-url-p "mailto:test@example.invalid"))
       (citar-http-url-p "https://example.invalid")))

(defun citar-test-current-file ()
  (alexandria:when-let ((filename (buffer-filename (current-buffer))))
    (uiop:native-namestring (truename filename))))

(define-command lem-yath-citar-test-report () ()
  (citar-test-log
   "STATE current=~a parser=~a safe=~a source-live=~a source-exact=~a"
   (or (citar-test-current-file) "none")
   (citar-test-yes-no (citar-test-parser-p))
   (citar-test-yes-no (citar-test-safe-p))
   (citar-test-yes-no (not (deleted-buffer-p *citar-test-source-buffer*)))
   (citar-test-yes-no
    (and (not (deleted-buffer-p *citar-test-source-buffer*))
         (string= *citar-test-source-text*
                  (buffer-text *citar-test-source-buffer*))))))

(define-command lem-yath-citar-test-source () ()
  (unless (deleted-buffer-p *citar-test-source-buffer*)
    (switch-to-buffer *citar-test-source-buffer*)))

(define-key *global-keymap* "F4" 'lem-yath-citar-test-report)
(define-key *global-keymap* "F5" 'lem-yath-citar-test-source)

(citar-test-log "EXEC xdg-open=~a" (executable-find "xdg-open"))
(citar-test-log "READY")
