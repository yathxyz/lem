(in-package :lem/buffer/file)

(defvar *find-file-hook* '())
(defvar *before-find-file-hook* '())
(defvar *find-file-read-options* nil)

(define-editor-variable before-save-hook '())
(define-editor-variable after-save-hook '())
(define-editor-variable find-file-literally nil)
(define-editor-variable write-file-function nil)

(defvar *external-format-function* nil)
(defvar *find-directory-function* nil)
(defvar *default-external-format* :detect-encoding)

(defvar *mixed-eol-notification-function* nil
  "Function of one argument (the filename string) called once by
INSERT-FILE-CONTENTS when a file's lines do not all share the detected
end-of-line style and are therefore normalized to it on save. Used to surface a
one-time, non-blocking message. NIL disables the notification.")

(defvar *encoding-fallback-external-format* :latin-1
  "External format used by FIND-FILE-BUFFER to re-read a file when the detected
encoding fails to decode it. Latin-1 maps all 256 byte values, so decoding never
fails and the bytes are preserved on round-trip.")

(defvar *encoding-fallback-notification-function* nil
  "Function of two arguments (the filename string and the fallback external
format) called by FIND-FILE-BUFFER when the detected encoding fails to decode a
file and it is re-opened under *ENCODING-FALLBACK-EXTERNAL-FORMAT* instead of
being refused. Used to surface a one-time, non-blocking message. NIL disables
the notification.")

(define-condition encoding-read-error (editor-error)
  ((condition :initarg :condition)
   (filename :initarg :filename
             :reader encoding-read-error-filename))
  (:report (lambda (c s)
             (with-slots (filename) c
               (format s "Couldn't read this file: ~A" filename)))))

(defun %encoding-read (encoding point stream stream-filename)
  (let ((end-of-line (encoding-end-of-line encoding))
        (mixed-eol-p nil))
    (loop
      (multiple-value-bind (str eof-p)
          (handler-bind ((error (lambda (e)
                                  (error 'encoding-read-error
                                         :condition e
                                         :filename stream-filename))))
            (read-line stream nil))
        (cond
          (eof-p
           (when str
             (insert-string point str))
           (return))
          (t
           (let ((end nil))
             ;; READ-LINE consumes the LF; for a CRLF pair the CR is left as the
             ;; final character. In a CRLF file strip that CR only when it is
             ;; actually present -- never remove a real character. A line that
             ;; lacks the CR is an LF-only line: keep it intact and flag the
             ;; file as mixed so save-time normalization can be announced.
             #+sbcl
             (when (eq end-of-line :crlf)
               (if (and (< 0 (length str))
                        (char= (char str (1- (length str))) #\return))
                   (setf end (1- (length str)))
                   (setf mixed-eol-p t)))
             (insert-string point
                            (if end
                                (subseq str 0 end)
                                str))
             (insert-character point #\newline))))))
    (when (and mixed-eol-p *mixed-eol-notification-function*)
      (funcall *mixed-eol-notification-function* stream-filename))))

(defun insert-file-contents (point filename
                             &key (external-format *default-external-format*)
                                  (end-of-line :auto))
  (when (eql external-format :detect-encoding)
    (if *external-format-function*
        (multiple-value-setq (external-format end-of-line)
          (funcall *external-format-function* filename))
        (setf external-format :utf-8)))
  (let* ((encoding (encoding external-format end-of-line))
         (use-internal-p (typep encoding 'internal-encoding)))
    (with-point ((point point :left-inserting))
      (with-open-virtual-file (stream filename
                                      :element-type (unless use-internal-p
                                                      '(unsigned-byte 8))
                                      :external-format (and use-internal-p external-format)
                                      :direction :input)
        (if use-internal-p
            (%encoding-read encoding point stream filename)
            (encoding-read encoding
                           stream
                           (encoding-read-detect-eol
                            (lambda (c)
                              (when c (insert-character point (code-char c)))))))))
    encoding))

(defun detect-file-end-of-line (filename)
  "Detect FILENAME's end-of-line style using *EXTERNAL-FORMAT-FUNCTION*, whose
end-of-line detection never fails. Returns :AUTO when no detector is configured
or detection is inconclusive."
  (or (and *external-format-function*
           (ignore-errors (nth-value 1 (funcall *external-format-function* filename))))
      :auto))

(defun insert-file-contents-as (point filename external-format)
  "Insert the contents of FILENAME at POINT decoded as EXTERNAL-FORMAT, with the
end-of-line style auto-detected. Returns the encoding used.

Unlike INSERT-FILE-CONTENTS with :DETECT-ENCODING, EXTERNAL-FORMAT is applied
unconditionally. Latin-1 in particular maps all 256 byte values, so it never
fails and preserves the file's bytes on round-trip."
  (insert-file-contents point filename
                        :external-format external-format
                        :end-of-line (detect-file-end-of-line filename)))

(defun find-file-buffer (filename &key temporary (enable-undo-p t) (syntax-table nil syntax-table-p))
  (when (pathnamep filename)
    (setf filename (namestring filename)))
  (setf filename (expand-file-name filename))
  (unless (uiop:directory-exists-p (directory-namestring filename))
    (error 'directory-does-not-exist :directory (directory-namestring filename)))
  (alexandria:when-let (it (probe-file filename)) (setf filename (namestring it)))
  (cond ((uiop:directory-pathname-p filename)
         (if *find-directory-function*
             (funcall *find-directory-function* filename)
             (editor-error "~A is a directory" filename)))
        ((and (not temporary)
              (find filename (buffer-list) :key #'buffer-filename :test #'equal)))
        (t
         (let ((*find-file-read-options* nil))
           ;; Run before allocating a buffer or reading any file content.  A
           ;; callback may abort or select bounded read options for this visit.
           (run-hooks *before-find-file-hook* filename temporary)
           (let* ((name (file-namestring filename))
                (buffer (make-buffer (if temporary
                                         name
                                         (if (get-buffer name)
                                             (unique-buffer-name name)
                                             name))
                                     :enable-undo-p nil
                                     :temporary temporary)))
             (setf (buffer-filename buffer) filename
                   (variable-value 'find-file-literally :buffer buffer)
                   (not (null (getf *find-file-read-options* :literal))))
           (when (probe-file filename)
             (let ((*inhibit-modification-hooks* t))
               (let ((encoding
                       (handler-case
                           (insert-file-contents
                            (buffer-start-point buffer) filename
                            :external-format
                            (getf *find-file-read-options* :external-format
                                  *default-external-format*)
                            :end-of-line
                            (getf *find-file-read-options* :end-of-line :auto))
                         (encoding-read-error ()
                           ;; The detected encoding could not decode the file.
                           ;; Rather than deleting the buffer and refusing to
                           ;; open it, discard any partially decoded text and
                           ;; re-read losslessly under the fallback external
                           ;; format (latin-1), which maps all 256 byte values.
                           (erase-buffer buffer)
                           (prog1 (insert-file-contents-as
                                   (buffer-start-point buffer)
                                   filename
                                   *encoding-fallback-external-format*)
                             (when *encoding-fallback-notification-function*
                               (funcall *encoding-fallback-notification-function*
                                        filename
                                        *encoding-fallback-external-format*)))))))
                 (setf (buffer-encoding buffer) encoding)))
             (buffer-mark-saved buffer))
           (buffer-start (buffer-point buffer))
           (when enable-undo-p (buffer-enable-undo buffer))
           (when syntax-table-p (setf (buffer-syntax-table buffer) syntax-table))
           (update-changed-disk-date buffer)
             (unless (variable-value 'find-file-literally :default buffer)
               (run-hooks *find-file-hook* buffer))
             (values buffer t))))))

(defun write-to-file-without-write-hook (buffer filename)
  (write-region-to-file (buffer-start-point buffer)
                        (buffer-end-point buffer) filename))

(defun run-before-save-hooks (buffer)
  (run-hooks (make-per-buffer-hook :var 'before-save-hook :buffer buffer)
             buffer))

(defun run-after-save-hooks (buffer)
  (run-hooks (make-per-buffer-hook :var 'after-save-hook :buffer buffer)
             buffer))

(defun call-with-write-hook (buffer function &optional mark-saved-p)
  (run-before-save-hooks buffer)
  ;; A saved identity must name a stable undo node.  Commit an active
  ;; transaction before external I/O so a splice refusal cannot happen after
  ;; the file has already changed.
  (when mark-saved-p
    (alexandria:when-let
        ((group (lem/buffer/internal::buffer-%active-change-group buffer)))
      (buffer-accept-change-group group)))
  (funcall function)
  ;; Mark the exact bytes just written before after-save hooks are allowed to
  ;; create a new dirty descendant.
  (when mark-saved-p
    (buffer-mark-saved buffer))
  (update-changed-disk-date buffer)
  (run-after-save-hooks buffer))

(defmacro with-write-hook (buffer &body body)
  `(call-with-write-hook ,buffer (lambda () ,@body)))

(defun write-to-file (buffer filename &optional mark-saved-p)
  (call-with-write-hook
   buffer
   (lambda ()
     (alexandria:if-let ((writer (buffer-value buffer 'write-file-function)))
       (funcall writer buffer filename)
       (write-to-file-without-write-hook buffer filename)))
   mark-saved-p))

(defun %write-region-to-file (end-of-line out)
  (lambda (string eof-p)
    (princ string out)
    (unless eof-p
      #+sbcl
      (case end-of-line
        ((:crlf)
         (princ #\return out)
         (princ #\newline out))
        ((:lf)
         (princ #\newline out))
        ((:cr)
         (princ #\return out)))
      #-sbcl
      (princ #\newline out))))

(defun %%write-region-to-file (encoding out)
  (let ((f (encoding-write encoding out))
        (end-of-line (encoding-end-of-line encoding)))
    (lambda (string eof-p)
      (loop :for c :across string
            :do (funcall f c))
      (unless eof-p
        (ecase end-of-line
          ((:crlf)
           (funcall f #\return)
           (funcall f #\newline))
          ((:lf :auto)
           (funcall f #\newline))
          ((:cr)
           (funcall f #\return)))))))

(defun write-region-to-file (start end filename)
  (let* ((buffer (point-buffer start))
         (encoding (buffer-encoding buffer))
         (use-internal (or (typep encoding 'internal-encoding) (null encoding)))
         (check (encoding-check encoding)))
    (when check
      (map-region start end check)) ;; throw condition?
    (write-file-atomically
     filename
     (lambda (out)
       (map-region start end
                   (if use-internal
                       (%write-region-to-file (if encoding
                                                  (encoding-end-of-line encoding)
                                                  :lf)
                                              out)
                       (%%write-region-to-file encoding out))))
     :element-type (unless use-internal '(unsigned-byte 8))
     :external-format (if (and use-internal encoding)
                          (encoding-external-format encoding)))))

(defun file-write-date* (buffer)
  (if (probe-file (buffer-filename buffer))
      (file-write-date (buffer-filename buffer))))

(defun update-changed-disk-date (buffer)
  (setf (buffer-last-write-date buffer)
        (file-write-date* buffer)))

(defun changed-disk-p (buffer)
  (and (buffer-filename buffer)
       (probe-file (buffer-filename buffer))
       (not (eql (buffer-last-write-date buffer)
                 (file-write-date* buffer)))))
