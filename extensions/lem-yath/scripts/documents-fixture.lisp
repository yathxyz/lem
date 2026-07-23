(in-package :lem-yath)

(defvar *documents-test-report* (uiop:getenv "LEM_YATH_DOCUMENTS_REPORT"))
(defvar *documents-test-source-buffer* (current-buffer))
(defvar *documents-test-source-text* (buffer-text (current-buffer)))
(defvar *documents-test-pdf* (uiop:getenv "LEM_YATH_DOCUMENTS_PDF"))
(defvar *documents-test-epub* (uiop:getenv "LEM_YATH_DOCUMENTS_EPUB"))
(defvar *documents-test-fifo* (uiop:getenv "LEM_YATH_DOCUMENTS_FIFO"))
(defvar *documents-test-large* (uiop:getenv "LEM_YATH_DOCUMENTS_LARGE"))
(defvar *documents-test-oversized* (uiop:getenv "LEM_YATH_DOCUMENTS_OVERSIZED"))
(defvar *documents-test-slow* (uiop:getenv "LEM_YATH_DOCUMENTS_SLOW"))
(defvar *documents-test-fake-bin*
  (uiop:getenv "LEM_YATH_DOCUMENTS_FAKE_BIN"))
(setf (uiop:getenv "PATH")
      (format nil "~a:~a" *documents-test-fake-bin* (uiop:getenv "PATH")))

(defun documents-test-yes-no (value)
  (if value "yes" "no"))

(defun documents-test-log (control &rest arguments)
  (with-open-file (stream *documents-test-report* :direction :output
                          :if-exists :append :if-does-not-exist :create)
    (apply #'format stream (concatenate 'string control "~%") arguments)))

(defun documents-test-key-command (map keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find map (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun documents-test-keys-p (kind)
  (let ((map (ecase kind
               (:pdf *document-pdf-mode-keymap*)
               (:epub *document-epub-mode-keymap*))))
    (and
     (eq (documents-test-key-command map "n")
         (if (eq kind :pdf)
             'lem-yath-document-next-page
             'lem-yath-document-next-chapter))
     (eq (documents-test-key-command map "p")
         (if (eq kind :pdf)
             'lem-yath-document-previous-page
             'lem-yath-document-previous-chapter))
     (eq (documents-test-key-command map "g")
         (if (eq kind :pdf)
             'lem-yath-document-goto-page
             'lem-yath-document-goto-chapter))
     (eq (documents-test-key-command map "r")
         'lem-yath-document-refresh)
     (eq (documents-test-key-command map "o")
         'lem-yath-document-open-externally)
     (eq (documents-test-key-command map "q")
         'lem-yath-document-quit))))

(defun documents-test-source-exact-p ()
  (and (not (deleted-buffer-p *documents-test-source-buffer*))
       (string= *documents-test-source-text*
                (buffer-text *documents-test-source-buffer*))))

(defun documents-test-current-chapter ()
  (let ((line (line-number-at-point (current-point))))
    (or (car (find line
                   (buffer-value (current-buffer) 'document-chapters)
                   :key #'cdr :test #'=))
        "none")))

(defun documents-test-supported-buffer-count ()
  (count-if
   (lambda (buffer)
     (member (buffer-value buffer 'document-kind) '(:pdf :epub)))
   (buffer-list)))

(define-command lem-yath-documents-test-report () ()
  (let* ((buffer (current-buffer))
         (kind (buffer-value buffer 'document-kind))
         (text (buffer-text buffer)))
    (documents-test-log
     "STATE kind=~a mode=~a page=~a pages=~a chapter=~a readonly=~a safe=~a unvisited=~a recent=~a keys=~a revert=~a count=~d source=~a"
     (or kind "none")
     (case (buffer-major-mode buffer)
       (document-pdf-mode "pdf")
       (document-epub-mode "epub")
       (otherwise "other"))
     (or (buffer-value buffer 'document-page) "none")
     (or (buffer-value buffer 'document-pages) "none")
     (if (eq kind :epub) (documents-test-current-chapter) "none")
     (documents-test-yes-no (buffer-read-only-p buffer))
     (documents-test-yes-no
      (and (not (find #\Null text))
           (not (find (code-char 27) text))
           (not (find (code-char 127) text))
           (not (find (code-char 159) text))))
     (documents-test-yes-no
      (and (null (buffer-filename buffer))
           (string= (document-source-pathname buffer)
                    (ecase kind
                      (:pdf *documents-test-pdf*)
                      (:epub *documents-test-epub*)))))
     (documents-test-yes-no
      (member (document-source-pathname buffer)
              (lem-core/commands/file:recent-files)
              :test #'string=))
     (documents-test-yes-no
      (and kind (documents-test-keys-p kind)))
     (documents-test-yes-no
      (eq (lem-core/commands/file:revert-buffer-function buffer)
          #'document-revert-buffer))
     (documents-test-supported-buffer-count)
     (documents-test-yes-no (documents-test-source-exact-p)))))

(define-command lem-yath-documents-test-open-pdf () ()
  (handler-case
      (find-file *documents-test-pdf*)
    (error (condition)
      (documents-test-log "OPEN-ERROR pdf ~s ~a"
                          (type-of condition) condition)
      (message "PDF fixture open failed: ~a" condition))))

(define-command lem-yath-documents-test-open-epub () ()
  (handler-case
      (find-file *documents-test-epub*)
    (error (condition)
      (documents-test-log "OPEN-ERROR epub ~s ~a"
                          (type-of condition) condition)
      (message "EPUB fixture open failed: ~a" condition))))

(define-command lem-yath-documents-test-source () ()
  (switch-to-buffer *documents-test-source-buffer*))

(defun documents-test-refusal (label pathname &key output-limit timeout)
  (handler-case
      (let ((*document-epub-output-limit*
              (or output-limit *document-epub-output-limit*))
            (*document-process-timeout*
              (or timeout *document-process-timeout*)))
        (find-file pathname)
        (documents-test-log "REFUSED ~a=no" label))
    (error ()
      (documents-test-log "REFUSED ~a=yes source=~a"
                          label
                          (documents-test-yes-no
                           (documents-test-source-exact-p))))))

(define-command lem-yath-documents-test-refuse-fifo () ()
  (documents-test-refusal "fifo" *documents-test-fifo*))

(define-command lem-yath-documents-test-refuse-large () ()
  (documents-test-refusal "large" *documents-test-large*))

(define-command lem-yath-documents-test-refuse-output () ()
  (documents-test-refusal "output" *documents-test-oversized*
                          :output-limit 256))

(define-command lem-yath-documents-test-refuse-timeout () ()
  (documents-test-refusal "timeout" *documents-test-slow* :timeout 1))

(define-key *global-keymap* "F1" 'lem-yath-documents-test-report)
(define-key *global-keymap* "F2" 'lem-yath-documents-test-source)
(define-key *global-keymap* "F3" 'lem-yath-documents-test-open-pdf)
(define-key *global-keymap* "F4" 'lem-yath-documents-test-open-epub)
(define-key *global-keymap* "F6" 'lem-yath-documents-test-refuse-fifo)
(define-key *global-keymap* "F7" 'lem-yath-documents-test-refuse-large)
(define-key *global-keymap* "F8" 'lem-yath-documents-test-refuse-output)
(define-key *global-keymap* "F9" 'lem-yath-documents-test-refuse-timeout)

(documents-test-log "READY")
