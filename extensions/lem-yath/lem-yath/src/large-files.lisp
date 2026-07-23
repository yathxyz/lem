;;;; Configured confirmation before opening unusually large local files.

(in-package :lem-yath)

(defvar *large-file-warning-threshold* (* 50 1024 1024))

(defun large-file-regular-file-size (filename)
  "Return FILENAME's byte size when it is a local regular file."
  #+sbcl
  (ignore-errors
    (let ((stat (sb-posix:stat (uiop:native-namestring filename))))
      (when (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
               sb-posix:s-ifreg)
        (sb-posix:stat-size stat))))
  #-sbcl
  (declare (ignore filename))
  #-sbcl
  nil)

(defun large-file-readable-p (filename)
  "Whether FILENAME can be opened for a byte read without consuming it."
  (handler-case
      (progn
        (with-open-file (stream filename
                                :direction :input
                                :element-type '(unsigned-byte 8))
          (declare (ignore stream)))
        t)
    (error () nil)))

(defun large-file-open-choice (filename size)
  "Read Emacs's yes, no, or literal choice for FILENAME of byte SIZE."
  (loop
    :for choice :=
      (char-downcase
       (prompt-for-character
        (format nil "File ~a is large (~a), really open? [y/n/l] "
                (file-namestring filename)
                (completion-human-readable-size size))))
    :do
       (case choice
         (#\y (return :normal))
         (#\n (return :abort))
         (#\l (return :literal))
         (#\?
          (message
           "y opens normally; n aborts; l opens literal bytes in Fundamental mode"))
         (otherwise
          (message "Choose y, n, or l")))))

(defun large-file-before-find-file (filename temporary)
  "Apply the configured large-file policy before Lem reads FILENAME."
  ;; Temporary reads are noninteractive implementation details in Lem.  Their
  ;; callers must impose their own bounds rather than prompting from a worker.
  (unless temporary
    (let ((size (large-file-regular-file-size filename)))
      (when (and *large-file-warning-threshold*
                 size
                 (> size *large-file-warning-threshold*)
                 (large-file-readable-p filename))
        (case (large-file-open-choice filename size)
          (:normal nil)
          (:abort (error 'editor-abort))
          (:literal
           ;; Latin-1 maps every octet to one character.  Fixed LF handling
           ;; prevents CR/LF normalization, so an unchanged save round-trips
           ;; arbitrary bytes exactly.
           (setf *find-file-read-options*
                 '(:literal t :external-format :latin-1 :end-of-line :lf))))))))

(defun install-large-file-warning ()
  (remove-hook *before-find-file-hook* 'large-file-before-find-file)
  (add-hook *before-find-file-hook* 'large-file-before-find-file))

(install-large-file-warning)
