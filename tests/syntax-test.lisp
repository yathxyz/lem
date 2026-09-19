(defpackage :lem-tests/syntax-test
  (:use :cl :rove)
  (:import-from :lem-tests/utilities
                :sample-file)
  (:import-from :lem-lisp-mode)
  (:import-from :lem))
(in-package :lem-tests/syntax-test)

(defun parse-state-description (state)
  (let ((token (lem:pps-state-token-start-point state)))
    (list (lem:pps-state-type state)
          (and token (list (lem:line-number-at-point token) (lem:point-charpos token)))
          (lem:pps-state-end-char state)
          (lem:pps-state-block-comment-depth state)
          (lem:pps-state-block-pair state)
          (lem:pps-state-paren-stack state)
          (lem:pps-state-paren-depth state))))

(defun cached-syntax-matches-fresh-parse-p (buffer)
  (lem:with-point ((point (lem:buffer-end-point buffer))
                   (from (lem:buffer-start-point buffer)))
    ;; Populate checkpoints first, then query descending lines and advancing
    ;; columns, including positions inside tokens and multiline strings/comments.
    (lem:syntax-ppss point)
    (loop
      (dotimes (column 3)
        (lem:line-offset point 0 (min column (length (lem:line-string point))))
        (lem:buffer-start from)
        (let* ((expected (parse-state-description (lem:parse-partial-sexp from point)))
               (actual (parse-state-description (lem:syntax-ppss point))))
          (unless (equal expected actual)
            (format t "~&Syntax mismatch at ~D:~D: expected ~S, got ~S~%"
                    (lem:line-number-at-point point) (lem:point-charpos point)
                    expected actual)
            (return-from cached-syntax-matches-fresh-parse-p nil))))
      (unless (lem:line-offset point -1 0)
        (return t)))))

(deftest syntax-cache-incomplete-tokens
  (dolist (text '("#|x|#" "\"a\\\"b\""))
    (let* ((buffer (lem:make-buffer nil :temporary t
                                       :syntax-table lem-lisp-syntax:*syntax-table*))
           (point (lem:buffer-point buffer)))
      (unwind-protect
           (progn
             (lem:insert-string point text)
             (lem:with-point ((from (lem:buffer-start-point buffer)))
               (dotimes (column (1+ (length text)))
                 (lem:line-offset point 0 column)
                 (lem:buffer-start from)
                 (let ((expected (parse-state-description (lem:parse-partial-sexp from point))))
                   (ok (equal expected (parse-state-description (lem:syntax-ppss point))))))))
        (lem:delete-buffer buffer)))))

(deftest syntax-checkpoints-match-fresh-parsing
  (let* ((buffer (lem:make-buffer nil :temporary t
                                     :syntax-table lem-lisp-syntax:*syntax-table*))
         (point (lem:buffer-point buffer)))
    (unwind-protect
         (progn
           (lem:insert-string
            point
            (with-output-to-string (out)
              (format out "(~%\"start~%")
              (dotimes (i 75) (write-line "escaped \\\" ; ( ) 漢字😀" out))
              (format out "finish\"~%#| outer~%#| inner~%")
              (dotimes (i 90) (write-line "; ( ) \" comment" out))
              (format out "|#~%|#~%")
              (dotimes (i 30) (write-line "(tail \"semi;colon\") ; end" out))
              (write-char #\) out)))
           (lem:clear-buffer-edit-history buffer)
           (ok (cached-syntax-matches-fresh-parse-p buffer))
           ;; Edits both before and after existing checkpoints must trim the
           ;; affected suffix. Removing a quote changes subsequent parse state.
           (lem:move-to-line point 2)
           (lem:delete-character point 1)
           (lem:buffer-undo-boundary buffer)
           (ok (cached-syntax-matches-fresh-parse-p buffer))
           (lem:buffer-undo point)
           (ok (cached-syntax-matches-fresh-parse-p buffer))
           (lem:move-to-line point 130)
           (lem:insert-string point (format nil "|#~%"))
           (lem:buffer-undo-boundary buffer)
           (ok (cached-syntax-matches-fresh-parse-p buffer))
           (lem:buffer-undo point)
           (ok (cached-syntax-matches-fresh-parse-p buffer)))
      (lem:delete-buffer buffer))))

(deftest form-offset
  (let ((lem-lisp-mode/test-api:*disable-self-connect* t))
    (testing "skip comment"
      (let* ((buffer (lem:find-file-buffer (sample-file "syntax-sample.lisp")
                                                :temporary t
                                                :enable-undo-p nil
                                                :syntax-table lem-lisp-syntax:*syntax-table*))
             (point (lem:buffer-point buffer)))
        (lem:with-point ((point point))
          (lem:buffer-start point)
          (lem:form-offset point 1)
          (lem:form-offset point -1)
          (ok (lem:start-buffer-p point)))
        (lem:with-point ((point point))
          (lem:buffer-start point)
          (lem:line-end point)
          (lem:form-offset point 1)
          (ok (equal (lem:symbol-string-at-point point) "bar")))))))

(defparameter +scan-lists-sample-text+
  (string-trim '(#\space #\newline) "
\(a
 (b
  c)
 d)
"))

(deftest scan-lists
  (let ((lem-lisp-mode/test-api:*disable-self-connect* t))
    (testing "limit-point"
      (let* ((buffer (lem:make-buffer nil
                                           :temporary t
                                           :enable-undo-p nil
                                           :syntax-table lem-lisp-syntax:*syntax-table*))
             (point (lem:buffer-point buffer)))
        (lem:insert-string point +scan-lists-sample-text+)
        (lem:with-point ((point point)
                              (limit-point point))
          (testing "forward"
            (assert (lem:search-forward (lem:buffer-start limit-point) "c)"))
            (lem:buffer-start point)
            (ok (and (null (lem:scan-lists point 1 0 t limit-point))
                     (lem:start-buffer-p point)))
            (ok (and (eq point (lem:scan-lists point 1 0 t))
                     (= 4 (lem:line-number-at-point point))
                     (= 3 (lem:point-charpos point)))))
          (testing "backward"
            (lem:buffer-end point)
            (assert (lem:search-forward (lem:buffer-start limit-point) "(b"))
            (ok (and (null (lem:scan-lists point -1 0 t limit-point))
                     (lem:end-buffer-p point)))
            (ok (and (eq point (lem:scan-lists point -1 0 t))
                     (lem:start-buffer-p point)))))))))

(deftest contains-line-comment-character-in-block-comment-or-string
  (dolist (text (list (uiop:strcat #\" #\newline ";" #\")
                      (uiop:strcat "x" "#|" #\newline ";" "|#")))

    ;; Arrange
    (let ((lem-lisp-mode/test-api:*disable-self-connect* t))
      (let* ((buffer (lem:make-buffer nil
                                           :temporary t
                                           :enable-undo-p nil
                                           :syntax-table lem-lisp-syntax:*syntax-table*))
             (point (lem:buffer-point buffer)))
        (lem:insert-string point text)
        (lem:buffer-end point)

        ;; Act
        (let ((got (lem:form-offset point -1)))
          (ok (eq point got))

          ;; Assertion
          (ok (lem:point= (lem:buffer-start-point buffer) point)))))))
