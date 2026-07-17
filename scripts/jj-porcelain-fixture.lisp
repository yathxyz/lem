(in-package :lem-yath)

(defvar *jj-porcelain-test-report*
  (uiop:getenv "LEM_YATH_JJ_PORCELAIN_REPORT"))
(defvar *jj-porcelain-test-root*
  (uiop:ensure-directory-pathname
   (uiop:getenv "LEM_YATH_JJ_PORCELAIN_ROOT")))
(defvar *jj-porcelain-test-source-buffer* (current-buffer))

(defun jj-porcelain-test-yes-no (value)
  (if value "yes" "no"))

(defun jj-porcelain-test-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across (or string "")
          :do (case character
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (#\Space (write-char #\_ stream))
                (otherwise (write-char character stream))))))

(defun jj-porcelain-test-key-command (keys)
  (alexandria:when-let
      ((prefix
         (lem-core::keymap-find *lem-yath-jj-view-keymap*
                                (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun jj-porcelain-test-keys-p ()
  (every
   (lambda (binding)
     (eq (second binding)
         (jj-porcelain-test-key-command (first binding))))
   '(("c" lem-yath-jj-describe)
     ("o" lem-yath-jj-new)
     ("s" lem-yath-jj-squash)
     ("r" lem-yath-jj-rebase)
     ("b" lem-yath-jj-bookmark)
     ("e" lem-yath-jj-edit)
     ("u" lem-yath-jj-undo)
     ("C-r" lem-yath-jj-redo)
     ("x" lem-yath-jj-abandon)
     ("d" lem-yath-jj-show)
     ("Return" lem-yath-jj-show)
     ("C-j" lem-yath-jj-next-revision)
     ("C-k" lem-yath-jj-previous-revision)
     ("g r" lem-yath-jj-refresh)
     ("g j" lem-yath-jj-next-revision)
     ("g k" lem-yath-jj-previous-revision)
     ("?" lem-yath-jj-help)
     ("q" lem-yath-jj-quit))))

(defun jj-porcelain-test-row-count (buffer)
  (with-point ((point (buffer-start-point buffer)))
    (loop :with count := 0
          :do (when (jj-row-revision point) (incf count))
          :while (line-offset point 1)
          :finally (return count))))

(define-command lem-yath-jj-porcelain-test-report () ()
  (let* ((buffer (current-buffer))
         (root (buffer-value buffer *lem-yath-jj-root-key*))
         (kind (buffer-value buffer *lem-yath-jj-view-kind-key*))
         (row (jj-row-revision))
         (revision
           (or row
               (and (eq kind :show)
                    (buffer-value buffer *lem-yath-jj-revision-key*))))
         (description
           (and root revision
                (ignore-errors (jj-description root revision)))))
    (with-open-file (stream *jj-porcelain-test-report*
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :create)
      (format
       stream
       "STATE kind=~a row=~a description=~a rows=~d root=~a read-only=~a mode=~a keys=~a source=~a source-live=~a~%"
       (if kind (string-downcase (symbol-name kind)) "none")
       (jj-porcelain-test-yes-no row)
       (if description (jj-porcelain-test-encode description) "none")
       (if (eq kind :log) (jj-porcelain-test-row-count buffer) 0)
       (jj-porcelain-test-yes-no
        (and root
             (ignore-errors
               (equal (truename root)
                      (truename *jj-porcelain-test-root*)))))
       (jj-porcelain-test-yes-no (buffer-read-only-p buffer))
       (jj-porcelain-test-yes-no
        (mode-active-p buffer 'lem-yath-jj-view-mode))
       (jj-porcelain-test-yes-no (jj-porcelain-test-keys-p))
       (jj-porcelain-test-yes-no
        (eq buffer *jj-porcelain-test-source-buffer*))
       (jj-porcelain-test-yes-no
        (not (deleted-buffer-p *jj-porcelain-test-source-buffer*)))))))

(define-key *global-keymap* "F1" 'lem-yath-jj-porcelain-test-report)
