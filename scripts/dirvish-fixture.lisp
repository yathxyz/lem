(in-package :lem-yath)

(defvar *dirvish-test-report* (uiop:getenv "LEM_YATH_DIRVISH_REPORT"))
(defvar *dirvish-test-root*
  (uiop:ensure-directory-pathname (uiop:getenv "LEM_YATH_DIRVISH_ROOT")))
(defvar *dirvish-test-source*
  (or (uiop:getenv "LEM_YATH_DIRVISH_SOURCE")
      (merge-pathnames "src/dirvish.lisp"
                       (asdf:system-source-directory "lem-yath"))))

(defun dirvish-test-log (control &rest arguments)
  (with-open-file (stream *dirvish-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun dirvish-test-visible (string)
  (substitute #\. #\Space string))

(defun dirvish-test-basename (pathname)
  (if (uiop:directory-pathname-p pathname)
      (string-right-trim
       "/" (lem/directory-mode/file:pathname-directory-last-name pathname))
      (file-namestring pathname)))

(defun dirvish-test-row (basename)
  (with-point ((line (buffer-start-point (current-buffer))))
    (loop
      (let ((pathname (lem/directory-mode/internal:get-pathname line)))
        (when (and pathname
                   (string= basename (dirvish-test-basename pathname)))
          (let* ((active-modes
                   (lem-core::get-active-modes-class-instance
                    (current-buffer)))
                 (lem-core::*active-modes* active-modes)
                 (logical-line
                   (lem-core::create-logical-line
                    line nil active-modes (current-window))))
            (return
              (list (lem-core::logical-line-string logical-line)
                    (text-property-at line :dirvish-size)
                    (line-string line)
                    pathname)))))
      (unless (line-offset line 1)
        (return nil)))))

(defun dirvish-test-open-directory ()
  (switch-to-buffer
   (lem/directory-mode/internal:directory-buffer *dirvish-test-root*)))

(define-command lem-yath-test-dirvish-record () ()
  (dirvish-test-open-directory)
  (destructuring-bind (file-line file-size file-source file-path)
      (dirvish-test-row "size.bin")
    (declare (ignore file-path))
    (destructuring-bind (directory-line directory-size directory-source
                         directory-path)
        (dirvish-test-row "child")
      (declare (ignore directory-path))
      (dirvish-test-log
       (concatenate
        'string
        "DISPLAY width=~d file-cells=~d file-tail=~a file-size=~a "
        "file-source=~a directory-cells=~d directory-tail=~a "
        "directory-size=~a directory-source=~a modified=~a readonly=~a")
       (lem-core::window-body-width (current-window))
       (lem/common/character:string-width file-line)
       (dirvish-test-visible (subseq file-line (- (length file-line) 6)))
       (dirvish-test-visible file-size)
       (dirvish-test-visible file-source)
       (lem/common/character:string-width directory-line)
       (dirvish-test-visible
        (subseq directory-line (- (length directory-line) 6)))
       (dirvish-test-visible directory-size)
       (dirvish-test-visible directory-source)
       (if (buffer-modified-p (current-buffer)) "yes" "no")
       (if (buffer-read-only-p (current-buffer)) "yes" "no")))))

(define-command lem-yath-test-dirvish-visit () ()
  (dirvish-test-open-directory)
  (destructuring-bind (line size source pathname)
      (dirvish-test-row "open.txt")
    (declare (ignore line size source))
    (find-file pathname)
    (dirvish-test-log
     "VISIT file=~a text=~a"
     (file-namestring (buffer-filename (current-buffer)))
     (string-right-trim '(#\Newline #\Return) (buffer-text (current-buffer))))))

(define-command lem-yath-test-dirvish-reload () ()
  (load *dirvish-test-source*)
  (load *dirvish-test-source*)
  (dirvish-test-open-directory)
  (lem/directory-mode/internal:update-buffer (current-buffer))
  (dirvish-test-log
   "RELOAD inserters=~d exact=~a transformer=~a"
   (length lem/directory-mode/internal:*file-entry-inserters*)
   (if (equal lem/directory-mode/internal:*file-entry-inserters*
              (list #'insert-dirvish-directory-entry))
       "yes" "no")
   (if (eq (variable-value
            'lem-core::display-line-transform-function :global)
           'transform-lem-yath-display-line)
       "yes" "no")))

(define-key *global-keymap* "F2" 'lem-yath-test-dirvish-record)
(define-key *global-keymap* "F3" 'lem-yath-test-dirvish-visit)
(define-key *global-keymap* "F4" 'lem-yath-test-dirvish-reload)

(dirvish-test-open-directory)
(dirvish-test-log
 "STATIC mode=~a inserters=~d exact=~a bytes=~a count=~a"
 (buffer-major-mode (current-buffer))
 (length lem/directory-mode/internal:*file-entry-inserters*)
 (if (equal lem/directory-mode/internal:*file-entry-inserters*
            (list #'insert-dirvish-directory-entry))
     "yes" "no")
 (dirvish-test-visible (dirvish-human-readable 1536 1024))
 (dirvish-test-visible (dirvish-human-readable 3 1000)))
(dirvish-test-log "READY")
