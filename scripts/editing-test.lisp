(in-package :lem-yath)

;; A test-only programming mode avoids starting a real language server while
;; retaining the mode ancestry used to distinguish code from prose.
(define-major-mode editing-test-programming-mode
    lem/language-mode:language-mode
    (:name "Editing Test Programming"))

(defun editing-test-file (name)
  (merge-pathnames name
                   (uiop:ensure-directory-pathname
                    (uiop:getenv "LEM_YATH_EDITING_TEST_ROOT"))))

(defun editing-test-write-file (path contents)
  (alexandria:write-string-into-file contents path :if-exists :supersede))

(defun editing-test-file-contents (path)
  (alexandria:read-file-into-string path))

(defun editing-test-open-buffer (path mode)
  (let ((buffer (find-file-buffer path)))
    (change-buffer-mode buffer mode)
    buffer))

(defun editing-test-insert-at-line-end (buffer line text)
  (with-point ((point (buffer-start-point buffer)))
    (line-offset point (1- line))
    (line-end point)
    (insert-string point text)))

(defun editing-test-delete-on-line (buffer line text)
  (with-point ((point (buffer-start-point buffer)))
    (line-offset point (1- line))
    (unless (search-forward point text)
      (error "Could not find ~s on line ~d" text line))
    (character-offset point (- (length text)))
    (delete-character point (length text))))

(with-open-file (out (uiop:getenv "LEM_YATH_EDITING_REPORT")
                     :direction :output
                     :if-exists :supersede
                     :if-does-not-exist :create)
  (let ((failures 0))
    (labels ((check (condition label)
               (format out "~a ~a~%" (if condition "PASS" "FAIL") label)
               (unless condition (incf failures))))
      (handler-case
          (progn
            (let* ((path (editing-test-file "program.fixture"))
                   (initial (format nil
                                    "untouched dirty  ~%insert touched~%delete touched X  ~%stable~%"))
                   (expected (format nil
                                     "untouched dirty  ~%insert touched~%delete touched~%stable~%")))
              (editing-test-write-file path initial)
              (let ((buffer (editing-test-open-buffer
                             path 'editing-test-programming-mode)))
                (check (subtypep (buffer-major-mode buffer)
                                 'lem/language-mode:language-mode)
                       "fixture-is-programming-mode")
                (check (programming-buffer-p buffer)
                       "fixture-passes-programming-predicate")

                ;; Exercise both change paths used by touched-line tracking.
                (editing-test-insert-at-line-end buffer 2 "   ")
                (editing-test-delete-on-line buffer 3 "X")
                (check (= 2 (length (touched-line-points buffer)))
                       "insertion-and-deletion-lines-tracked")
                (check (buffer-modified-p buffer)
                       "program-buffer-dirty-before-save")

                (save-buffer buffer)
                (let ((saved (editing-test-file-contents path)))
                  (check (string= saved expected)
                         "program-save-trims-only-touched-lines")
                  (check (search "untouched dirty  " saved)
                         "program-save-preserves-untouched-dirty-line")
                  (check (null (search "insert touched " saved))
                         "insertion-touched-line-trimmed")
                  (check (null (search "delete touched " saved))
                         "deletion-touched-line-trimmed"))
                (check (not (buffer-modified-p buffer))
                       "program-buffer-clean-after-save")
                (check (null (touched-line-points buffer))
                       "tracking-points-cleared-after-save")

                ;; A clean save must be a no-op.  This is also the observable
                ;; contract that per-save touched-line tracking was reset.
                (let ((saved (editing-test-file-contents path))
                      (tick (buffer-modified-tick buffer)))
                  (check (null (save-buffer buffer))
                         "clean-second-save-skipped")
                  (check (string= saved (editing-test-file-contents path))
                         "clean-second-save-preserves-file")
                  (check (= tick (buffer-modified-tick buffer))
                         "clean-second-save-preserves-buffer-tick")
                  (check (not (buffer-modified-p buffer))
                         "clean-second-save-leaves-buffer-clean"))

                ;; Seed whitespace on a line touched in the previous save
                ;; without firing change hooks, then touch a different line.
                ;; If the previous tracking set leaked across saves, line 2
                ;; will be trimmed again.
                (let ((lem-core::*inhibit-modification-hooks* t))
                  (editing-test-insert-at-line-end buffer 2 "  "))
                (editing-test-insert-at-line-end buffer 4 "  ")
                (save-buffer buffer)
                (let ((saved (editing-test-file-contents path)))
                  (check (search (format nil "insert touched  ~%") saved)
                         "tracking-reset-forgets-previously-touched-line")
                  (check (null (search "stable " saved))
                         "tracking-reset-trims-newly-touched-line"))))

            (let* ((path (editing-test-file "multiline.fixture"))
                   (initial (format nil
                                    "multi untouched  ~%body~%multi tail  ~%"))
                   (expected (format nil
                                     "multi untouched  ~%body left~%right~%multi tail  ~%")))
              (editing-test-write-file path initial)
              (let ((buffer (editing-test-open-buffer
                             path 'editing-test-programming-mode)))
                (editing-test-insert-at-line-end buffer 2
                                                 (format nil " left  ~%right  "))
                (check (= 2 (length (touched-line-points buffer)))
                       "multiline-insertion-tracks-each-new-line")
                (save-buffer buffer)
                (check (string= expected (editing-test-file-contents path))
                       "multiline-insertion-trims-only-new-lines")))

            (let* ((path (editing-test-file "revert.fixture"))
                   (external (format nil
                                     "revert untouched  ~%revert touched~%revert tail  ~%"))
                   (expected (format nil
                                     "revert untouched  ~%revert touched~%revert tail  ~%")))
              (editing-test-write-file path (format nil "old contents~%"))
              (let ((buffer (editing-test-open-buffer
                             path 'editing-test-programming-mode)))
                (editing-test-write-file path external)
                (lem-core/commands/file:sync-buffer-with-file-content buffer)
                (check (not (buffer-modified-p buffer))
                       "revert-leaves-buffer-clean")
                (check (touched-line-points buffer)
                       "revert-exercises-change-hooks")
                (editing-test-insert-at-line-end buffer 2 "   ")
                (check (= 1 (length (touched-line-points buffer)))
                       "first-post-revert-edit-starts-new-tracking-epoch")
                (save-buffer buffer)
                (check (string= expected (editing-test-file-contents path))
                       "post-revert-save-preserves-untouched-dirty-lines")))

            (let* ((path (editing-test-file "failed-save.fixture"))
                   (expected (format nil "failure untouched  ~%failure touched~%")))
              (editing-test-write-file
               path (format nil "failure untouched  ~%failure touched~%"))
              (let ((buffer (editing-test-open-buffer
                             path 'editing-test-programming-mode))
                    (failed nil))
                (editing-test-insert-at-line-end buffer 2 "  ")
                (handler-case
                    (lem/buffer/file::call-with-write-hook
                     buffer (lambda () (error "intentional write failure")))
                  (error () (setf failed t)))
                (check failed "write-failure-propagates")
                (check (touched-line-points buffer)
                       "write-failure-retains-tracking-points")
                (save-buffer buffer)
                (check (null (touched-line-points buffer))
                       "successful-retry-clears-tracking-points")
                (check (string= expected (editing-test-file-contents path))
                       "successful-retry-preserves-selective-trimming")))

            (let ((buffer (make-buffer "*editing-markup-predicate*")))
              (unwind-protect
                   (progn
                     (setf (buffer-major-mode buffer)
                           'lem-markdown-mode:markdown-mode)
                     (check (typep (ensure-mode-object
                                    (buffer-major-mode buffer))
                                   'lem/language-mode:language-mode)
                            "markdown-inherits-language-mode")
                     (check (not (programming-buffer-p buffer))
                            "markdown-excluded-from-programming-predicate"))
                (delete-buffer buffer)))

            (let ((buffer (make-buffer "*editing-html-predicate*")))
              (unwind-protect
                   (progn
                     (setf (buffer-major-mode buffer)
                           'lem-html-mode:html-mode)
                     (check (not (programming-buffer-p buffer))
                            "html-excluded-through-xml-mode-parent"))
                (delete-buffer buffer)))

            (let* ((path (editing-test-file "prose.fixture"))
                   (initial (format nil
                                    "prose untouched  ~%prose inserted~%prose delete X  ~%"))
                   (expected (format nil
                                     "prose untouched  ~%prose inserted  ~%prose delete   ~%")))
              (editing-test-write-file path initial)
              (let ((buffer (editing-test-open-buffer
                             path
                             'lem/buffer/fundamental-mode:fundamental-mode)))
                (check (not (subtypep (buffer-major-mode buffer)
                                      'lem/language-mode:language-mode))
                       "fixture-is-prose-mode")
                (editing-test-insert-at-line-end buffer 2 "  ")
                (editing-test-delete-on-line buffer 3 "X")
                (save-buffer buffer)
                (check (string= expected (editing-test-file-contents path))
                       "prose-save-preserves-trailing-whitespace")
                (check (not (buffer-modified-p buffer))
                       "prose-buffer-clean-after-save"))))
        (error (condition)
          (format out "FAIL unhandled-error: ~a~%" condition)
          (incf failures)))
      (format out "SUMMARY ~a (~d failure~:p)~%"
              (if (zerop failures) "PASS" "FAIL") failures))))
