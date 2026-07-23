;;;; In-editor document readers for PDF and EPUB files.
;;;;
;;;; Lem's ncurses frontend cannot reproduce pdf-tools' pixel renderer or
;;;; nov's HTML layout.  These modes keep the daily reading path inside Lem:
;;;; PDFs are extracted one page at a time with Poppler, and EPUBs are
;;;; converted to bounded GitHub-flavoured Markdown with Pandoc.  Both retain
;;;; a direct, explicit external-viewer escape hatch for visual material.

(in-package :lem-yath)

(defparameter *document-input-byte-limit* (* 512 1024 1024)
  "Largest PDF or EPUB source accepted by the in-editor readers.")

(defparameter *document-pdf-info-output-limit* (* 1024 1024))
(defparameter *document-pdf-page-output-limit* (* 2 1024 1024))
(defparameter *document-epub-output-limit* (* 16 1024 1024))
(defparameter *document-process-timeout* 30)

(defvar *document-pdf-mode-keymap*
  (make-keymap :description '*document-pdf-mode-keymap*))
(defvar *document-epub-mode-keymap*
  (make-keymap :description '*document-epub-mode-keymap*))

(defun document-reader-mode-enable ()
  (setf (buffer-read-only-p (current-buffer)) t
        (variable-value 'line-wrap :buffer (current-buffer)) t))

(define-major-mode document-pdf-mode nil
    (:name "PDF"
     :keymap *document-pdf-mode-keymap*)
  (document-reader-mode-enable))

(define-major-mode document-epub-mode lem-markdown-mode:markdown-mode
    (:name "EPUB"
     :keymap *document-epub-mode-keymap*)
  (document-reader-mode-enable))

(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode document-pdf-mode))
  (list *document-pdf-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode document-epub-mode))
  (list *document-epub-mode-keymap*))

(define-file-type ("pdf") document-pdf-mode)
(define-file-type ("epub") document-epub-mode)

(defun document-path-kind (pathname)
  "Return :PDF or :EPUB for a supported PATHNAME, independent of case."
  (let ((type (string-downcase (or (pathname-type (pathname pathname)) ""))))
    (cond ((string= type "pdf") :pdf)
          ((string= type "epub") :epub))))

(defun document-regular-file-size (pathname)
  "Return PATHNAME's byte size after requiring a finite regular file."
  #+sbcl
  (let ((stat (sb-posix:stat (uiop:native-namestring pathname))))
    (unless (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
               sb-posix:s-ifreg)
      (editor-error "Document is not a regular file: ~a" pathname))
    (sb-posix:stat-size stat))
  #-sbcl
  (declare (ignore pathname))
  #-sbcl
  (editor-error "Document readers require the supported SBCL runtime"))

(defun document-normalize-pathname (pathname)
  "Return an existing, canonical, size-bounded document pathname."
  (let ((path (or (ignore-errors (truename pathname))
                  (editor-error "Document does not exist: ~a" pathname))))
    (let ((size (document-regular-file-size path)))
      (unless (<= 0 size *document-input-byte-limit*)
        (editor-error "Document exceeds the ~d MiB reader limit: ~a"
                      (floor *document-input-byte-limit* 1048576) path)))
    path))

(defun document-program (name)
  (or (executable-find name)
      (editor-error "~a is unavailable; cannot read this document" name)))

(defun document-run (program arguments output-limit directory)
  "Run PROGRAM with ARGUMENTS under document-specific time and output bounds."
  (let ((*project-process-timeout* *document-process-timeout*))
    (multiple-value-bind (stdout stderr status)
        (run-project-program
         (cons (uiop:native-namestring (document-program program)) arguments)
         :directory directory
         :output-limit output-limit)
      (declare (ignore stderr))
      (unless (and (integerp status) (zerop status))
        (editor-error "~a could not read the document (exit ~a)"
                      program status))
      stdout)))

(defun document-safe-display-text (text)
  "Remove terminal control characters from converter-produced TEXT."
  (with-output-to-string (stream)
    (loop :for character :across text
          :for code := (char-code character)
          :do (cond
                ((or (char= character #\Newline)
                     (char= character #\Tab))
                 (write-char character stream))
                ((char= character #\Return))
                ((or (< code 32) (<= 127 code 159)))
                (t (write-char character stream))))))

(defun document-ascii-integer (text)
  (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
    (when (and (plusp (length text))
               (<= (length text) 9)
               (every (lambda (character)
                        (char<= #\0 character #\9))
                      text))
      (parse-integer text))))

(defun document-pdf-info-field (info field)
  (loop :for line :in (cl-ppcre:split "\\r?\\n" info)
        :for colon := (position #\: line)
        :when (and colon
                   (string-equal field
                                 (string-trim '(#\Space #\Tab)
                                              (subseq line 0 colon))))
          :return (string-trim '(#\Space #\Tab) (subseq line (1+ colon)))))

(defun document-read-pdf-info (pathname)
  "Return page count, title and author reported by pdfinfo."
  (let* ((directory (directory-namestring pathname))
         (info (document-safe-display-text
                (document-run
                 "pdfinfo" (list (uiop:native-namestring pathname))
                 *document-pdf-info-output-limit* directory)))
         (pages (document-ascii-integer
                 (or (document-pdf-info-field info "Pages") ""))))
    (unless (and pages (plusp pages))
      (editor-error "pdfinfo did not report a positive page count"))
    (values pages
            (document-pdf-info-field info "Title")
            (document-pdf-info-field info "Author"))))

(defun document-read-pdf-page (pathname page)
  (let ((native (uiop:native-namestring pathname)))
    (document-safe-display-text
     (document-run
      "pdftotext"
      (list "-f" (princ-to-string page)
            "-l" (princ-to-string page)
            "-layout" "-nopgbrk" "-enc" "UTF-8"
            native "-")
      *document-pdf-page-output-limit*
      (directory-namestring pathname)))))

(defun document-pdf-buffer-text (pathname page pages title author page-text)
  (with-output-to-string (stream)
    (format stream "PDF: ~a~%" (file-namestring pathname))
    (when (and title (plusp (length title)))
      (format stream "Title: ~a~%" title))
    (when (and author (plusp (length author)))
      (format stream "Author: ~a~%" author))
    (format stream "Page ~d of ~d~%~a~2%"
            page pages (make-string 72 :initial-element #\-))
    (if (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                    page-text)))
        (write-string page-text stream)
        (write-string "[This page has no extractable text.]" stream))
    (terpri stream)))

(defun document-read-epub (pathname)
  (document-safe-display-text
   (document-run
    "pandoc"
    (list "--sandbox" "--from=epub" "--to=gfm" "--wrap=none"
          (uiop:native-namestring pathname))
    *document-epub-output-limit*
    (directory-namestring pathname))))

(defun document-epub-buffer-text (pathname content)
  (format nil "EPUB: ~a~%~a~2%~a~%"
          (file-namestring pathname)
          (make-string 72 :initial-element #\-)
          content))

(defun document-markdown-heading (line)
  "Return a Markdown heading title from LINE, or NIL."
  (let ((count 0)
        (length (length line)))
    (loop :while (and (< count length)
                      (< count 6)
                      (char= (char line count) #\#))
          :do (incf count))
    (when (and (plusp count)
               (< count length)
               (char= (char line count) #\Space))
      (let ((title (string-trim '(#\Space #\Tab #\#)
                                (subseq line (1+ count)))))
        (and (plusp (length title)) title)))))

(defun document-epub-chapters (text)
  (loop :for line :in (cl-ppcre:split "\\r?\\n" text)
        :for line-number :from 1
        :for title := (document-markdown-heading line)
        :when title
          :collect (cons (format nil "~d  ~a" line-number title)
                         line-number)))

(defun document-existing-buffer (pathname)
  (let ((native (uiop:native-namestring pathname)))
    (find native (buffer-list)
          :key (lambda (buffer)
                 (alexandria:when-let
                     ((filename (buffer-value buffer 'document-source-path)))
                   (ignore-errors
                     (uiop:native-namestring (truename filename)))))
          :test #'string=)))

(defun document-source-pathname (&optional (buffer (current-buffer)))
  "Return BUFFER's canonical document source pathname."
  (or (buffer-value buffer 'document-source-path)
      (editor-error "This buffer has no document source")))

(defun document-record-file-history (pathname)
  "Record PATHNAME in Lem's ordinary recent-file history."
  (let ((history (lem-core/commands/file:file-history)))
    (lem/common/history:add-history
     history (uiop:native-namestring pathname)
     :allow-duplicates nil :move-to-top t)
    (lem/common/history:save-file history)))

(defun document-replace-buffer-text (buffer text)
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (insert-string (buffer-point buffer) text)
    (buffer-start (buffer-point buffer))
    (buffer-unmark buffer))
  (setf (buffer-read-only-p buffer) t)
  buffer)

(defun document-make-buffer (pathname mode text &key ephemeral-p)
  "Create a read-only document BUFFER without decoding or visiting its source.

The binary source is deliberately kept out of `buffer-filename'.  Lem's force
save path writes a buffer's displayed text directly to that filename, so a
converted view must never be able to overwrite its PDF or EPUB source."
  (let* ((native (uiop:native-namestring pathname))
         (buffer (make-buffer
                  (unique-buffer-name (file-namestring pathname))
                  :directory (directory-namestring pathname)
                  :enable-undo-p nil
                  :temporary ephemeral-p)))
    (setf (buffer-value buffer 'document-source-path) native
          (buffer-value buffer 'document-ephemeral-p) ephemeral-p)
    (document-replace-buffer-text buffer text)
    (change-buffer-mode buffer mode)
    (unless ephemeral-p
      (document-record-file-history pathname))
    (setf (lem-core/commands/file:revert-buffer-function buffer)
          #'document-revert-buffer)
    (buffer-unmark buffer)
    (setf (buffer-read-only-p buffer) t)
    buffer))

(defun document-open-pdf-buffer (pathname &key ephemeral-p)
  (multiple-value-bind (pages title author)
      (document-read-pdf-info pathname)
    (let* ((page 1)
           (page-text (document-read-pdf-page pathname page))
           (buffer
             (document-make-buffer
              pathname 'document-pdf-mode
              (document-pdf-buffer-text
               pathname page pages title author page-text)
              :ephemeral-p ephemeral-p)))
      (setf (buffer-value buffer 'document-kind) :pdf
            (buffer-value buffer 'document-page) page
            (buffer-value buffer 'document-pages) pages
            (buffer-value buffer 'document-title) title
            (buffer-value buffer 'document-author) author)
      buffer)))

(defun document-open-epub-buffer (pathname)
  (let* ((text (document-epub-buffer-text pathname
                                          (document-read-epub pathname)))
         (buffer (document-make-buffer pathname 'document-epub-mode text)))
    (setf (buffer-value buffer 'document-kind) :epub
          (buffer-value buffer 'document-chapters)
          (document-epub-chapters text))
    buffer))

(defun document-open-buffer (pathname kind &key ephemeral-p)
  (let ((pathname (document-normalize-pathname pathname)))
    (or (and (not ephemeral-p) (document-existing-buffer pathname))
        (ecase kind
          (:pdf (document-open-pdf-buffer pathname :ephemeral-p ephemeral-p))
          (:epub (document-open-epub-buffer pathname))))))

(defmethod execute-find-file
    (executor (mode (eql 'document-pdf-mode)) pathname)
  (declare (ignore executor mode))
  (document-open-buffer pathname :pdf))

(defmethod execute-find-file
    (executor (mode (eql 'document-epub-mode)) pathname)
  (declare (ignore executor mode))
  (document-open-buffer pathname :epub))

;; Lem's extension association is case-sensitive.  Intercept otherwise
;; unassociated mixed-case PDF/EPUB names without changing core matching for
;; unrelated files.
(defmethod execute-find-file
    (executor (mode null) pathname)
  (case (document-path-kind pathname)
    (:pdf (document-open-buffer pathname :pdf))
    (:epub (document-open-buffer pathname :epub))
    (otherwise (call-next-method))))

(defun document-refresh-pdf-buffer (buffer &optional requested-page)
  (let ((pathname
          (document-normalize-pathname (document-source-pathname buffer))))
    (multiple-value-bind (pages title author)
        (document-read-pdf-info pathname)
      (let* ((page (max 1 (min pages
                               (or requested-page
                                   (buffer-value buffer 'document-page)
                                   1))))
             (page-text (document-read-pdf-page pathname page)))
        (document-replace-buffer-text
         buffer
         (document-pdf-buffer-text
          pathname page pages title author page-text))
        (setf (buffer-value buffer 'document-page) page
              (buffer-value buffer 'document-pages) pages
              (buffer-value buffer 'document-title) title
              (buffer-value buffer 'document-author) author)
        (message "PDF page ~d of ~d" page pages)))))

(defun document-refresh-epub-buffer (buffer)
  (let* ((pathname
           (document-normalize-pathname (document-source-pathname buffer)))
         (point (buffer-point buffer))
         (line (line-number-at-point point))
         (column (point-column point))
         (text (document-epub-buffer-text pathname
                                          (document-read-epub pathname))))
    (document-replace-buffer-text buffer text)
    (setf (buffer-value buffer 'document-chapters)
          (document-epub-chapters text))
    (move-to-line point line)
    (move-to-column point column)
    (message "EPUB refreshed")))

(defun document-revert-buffer (buffer)
  (case (buffer-value buffer 'document-kind)
    (:pdf (document-refresh-pdf-buffer buffer))
    (:epub (document-refresh-epub-buffer buffer))
    (otherwise (editor-error "This is not a document reader buffer")))
  t)

(define-command lem-yath-document-next-page () ()
  "Show the next PDF page."
  (let* ((buffer (current-buffer))
         (page (or (buffer-value buffer 'document-page) 1))
         (pages (or (buffer-value buffer 'document-pages) 1)))
    (if (< page pages)
        (document-refresh-pdf-buffer buffer (1+ page))
        (message "Already at the last PDF page"))))

(define-command lem-yath-document-previous-page () ()
  "Show the previous PDF page."
  (let* ((buffer (current-buffer))
         (page (or (buffer-value buffer 'document-page) 1)))
    (if (> page 1)
        (document-refresh-pdf-buffer buffer (1- page))
        (message "Already at the first PDF page"))))

(define-command lem-yath-document-goto-page () ()
  "Prompt for a PDF page number."
  (let* ((buffer (current-buffer))
         (pages (or (buffer-value buffer 'document-pages) 1))
         (value (prompt-for-string
                 (format nil "PDF page (1-~d): " pages)
                 :initial-value
                 (princ-to-string
                  (or (buffer-value buffer 'document-page) 1))))
         (page (document-ascii-integer value)))
    (if (and page (<= 1 page pages))
        (document-refresh-pdf-buffer buffer page)
        (message "Page must be between 1 and ~d" pages))))

(define-command lem-yath-document-last-page () ()
  "Show the final PDF page."
  (let ((buffer (current-buffer)))
    (document-refresh-pdf-buffer
     buffer (or (buffer-value buffer 'document-pages) 1))))

(defun document-move-epub-chapter (direction)
  (let* ((point (current-point))
         (line (line-number-at-point point))
         (chapters (buffer-value (current-buffer) 'document-chapters))
         (chapter
           (if (plusp direction)
               (find-if (lambda (entry) (> (cdr entry) line)) chapters)
               (find-if (lambda (entry) (< (cdr entry) line))
                        chapters :from-end t))))
    (if chapter
        (progn
          (move-to-line point (cdr chapter))
          (back-to-indentation point)
          (message "~a" (car chapter)))
        (message "No ~:[previous~;next~] EPUB chapter"
                 (plusp direction)))))

(define-command lem-yath-document-next-chapter () ()
  "Move to the next EPUB heading."
  (document-move-epub-chapter 1))

(define-command lem-yath-document-previous-chapter () ()
  "Move to the previous EPUB heading."
  (document-move-epub-chapter -1))

(define-command lem-yath-document-goto-chapter () ()
  "Choose an EPUB heading and move to it."
  (let ((chapters (buffer-value (current-buffer) 'document-chapters)))
    (if (null chapters)
        (message "This EPUB has no converted chapter headings")
        (let* ((labels (mapcar #'car chapters))
               (choice
                 (prompt-for-string
                  "EPUB chapter: "
                  :completion-function
                  (lambda (string) (prescient-filter string labels))
                  :test-function (lambda (string)
                                   (find string labels :test #'string=))))
               (line (cdr (assoc choice chapters :test #'string=))))
          (when line
            (move-to-line (current-point) line)
            (back-to-indentation (current-point)))))))

(define-command lem-yath-document-refresh () ()
  "Re-read the current PDF or EPUB from disk."
  (document-revert-buffer (current-buffer)))

(define-command lem-yath-document-open-externally () ()
  "Open the current document in the desktop default viewer."
  (let ((pathname (document-normalize-pathname
                   (document-source-pathname (current-buffer)))))
    (open-with-xdg (uiop:native-namestring pathname))))

(define-command lem-yath-document-quit () ()
  "Quit this reader, deleting an ephemeral attachment buffer when applicable."
  (if (buffer-value (current-buffer) 'document-ephemeral-p)
      (let* ((buffer (current-buffer))
             (return-buffer
               (buffer-value buffer 'document-return-buffer))
             (return-pop-state
               (buffer-value buffer 'document-return-pop-state)))
        (if (and return-buffer (not (deleted-buffer-p return-buffer)))
            (progn
              (switch-to-buffer return-buffer nil)
              (setf (lem-core::window-pop-to-buffer-state (current-window))
                    return-pop-state)
              (delete-buffer buffer))
            (quit-active-window t)))
      (quit-active-window)))

(define-key *document-pdf-mode-keymap* "n" 'lem-yath-document-next-page)
(define-key *document-pdf-mode-keymap* "p" 'lem-yath-document-previous-page)
(define-key *document-pdf-mode-keymap* "PageDown" 'lem-yath-document-next-page)
(define-key *document-pdf-mode-keymap* "PageUp" 'lem-yath-document-previous-page)
(define-key *document-pdf-mode-keymap* "g" 'lem-yath-document-goto-page)
(define-key *document-pdf-mode-keymap* "G" 'lem-yath-document-last-page)
(define-key *document-pdf-mode-keymap* "r" 'lem-yath-document-refresh)
(define-key *document-pdf-mode-keymap* "o" 'lem-yath-document-open-externally)
(define-key *document-pdf-mode-keymap* "q" 'lem-yath-document-quit)

(define-key *document-epub-mode-keymap* "n" 'lem-yath-document-next-chapter)
(define-key *document-epub-mode-keymap* "p" 'lem-yath-document-previous-chapter)
(define-key *document-epub-mode-keymap* "PageDown" 'lem-yath-document-next-chapter)
(define-key *document-epub-mode-keymap* "PageUp" 'lem-yath-document-previous-chapter)
(define-key *document-epub-mode-keymap* "g" 'lem-yath-document-goto-chapter)
(define-key *document-epub-mode-keymap* "r" 'lem-yath-document-refresh)
(define-key *document-epub-mode-keymap* "o" 'lem-yath-document-open-externally)
(define-key *document-epub-mode-keymap* "q" 'lem-yath-document-quit)
