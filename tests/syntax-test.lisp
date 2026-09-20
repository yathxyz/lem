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


(deftest partial-parse-custom-delimiters
  ;; Letters and non-ASCII characters can carry syntax too. Ordinary-run
  ;; scanning must stop at the first character of each multi-character opener.
  (let* ((table (lem/buffer/syntax-table:make-syntax-table
                 :paren-pairs '((#\a . #\z) (#\λ . #\ω))
                 :string-quote-chars '(#\q) :escape-chars '(#\e)
                 :fence-chars '(#\f) :line-comment-string "cc"
                 :block-comment-pairs '(("bb" . "dd"))
                 :block-string-pairs '(("ss" . "tt"))))
         (buffer (lem:make-buffer nil :temporary t :syntax-table table)))
    (unwind-protect
         (dolist (case '(("word a word" nil 1 nil)
                         ("word a word z" nil 0 nil)
                         ("word λ word" nil 1 nil)
                         ("word λ word ω" nil 0 nil)
                         ("wordqrest" :string 0 4)
                         ("wordfrest" :fence 0 4)
                         ("wordeqrest" nil 0 nil)
                         ("wordssrest" :block-string 0 4)
                         ("wordssresttt" nil 0 nil)
                         ("wordbbrest" :block-comment 0 4)
                         ("wordbbrestdd" nil 0 nil)
                         ("word cc rest" :line-comment 0 5)))
           (destructuring-bind (text type depth token-column) case
             (lem:erase-buffer buffer)
             (lem:insert-string (lem:buffer-point buffer) text)
             (dolist (comment-stop '(nil t))
               (lem:with-point ((from (lem:buffer-start-point buffer))
                                (to (lem:buffer-end-point buffer)))
                 (let* ((state (lem:parse-partial-sexp from to nil comment-stop))
                        (stopped (and comment-stop (or (search "bb" text) (search "cc" text))))
                        (token (lem:pps-state-token-start-point state)))
                   (ok (eq (if stopped nil type) (lem:pps-state-type state)))
                   (ok (= depth (lem:pps-state-paren-depth state)))
                   (ok (eql (unless stopped token-column)
                            (and token (lem:point-charpos token))))
                   (when stopped
                     (ok (= stopped (lem:point-charpos from)))))))))
      (lem:delete-buffer buffer))))

(deftest partial-parse-ordinary-span-boundaries
  (let* ((text (format nil "0123456789漢字😀~%0123456789~%0123456789"))
         (buffer (lem:make-buffer nil :temporary t :syntax-table lem-lisp-syntax:*syntax-table*)))
    (unwind-protect
         (progn
           (lem:insert-string (lem:buffer-point buffer) text)
           (lem:with-point ((from (lem:buffer-start-point buffer))
                            (to (lem:buffer-start-point buffer)))
             (ok (loop :for start :from 0 :to (length text)
                       :always (loop :for end :from start :to (length text)
                                     :always (progn
                                               (lem:move-to-position from (1+ start))
                                               (lem:move-to-position to (1+ end))
                                               (let ((state (lem:parse-partial-sexp from to)))
                                                 (and (lem:point= from to)
                                                      (null (lem:pps-state-type state))
                                                      (zerop (lem:pps-state-paren-depth state)))))))
                 "ordinary spans preserve every requested endpoint, including newlines and EOF")))
      (lem:delete-buffer buffer))))


(deftest partial-parse-string-span-boundaries
  (dolist (delimiter '(#\" #\|))
    (let* ((text (format nil "~c0123456789漢字😀~%ab\\~ccd~%0123456789~c"
                         delimiter delimiter delimiter))
           (escape (position #\\ text))
           (table (lem/buffer/syntax-table:make-syntax-table :fence-chars '(#\|)))
           (buffer (lem:make-buffer nil :temporary t :syntax-table table)))
      (unwind-protect
           (progn
             (lem:insert-string (lem:buffer-point buffer) text)
             (lem:with-point ((from (lem:buffer-start-point buffer))
                              (to (lem:buffer-start-point buffer)))
               (ok (loop :for end :from 0 :to (length text)
                         :always (progn
                                   (lem:buffer-start from)
                                   (lem:move-to-position to (1+ end))
                                   (let* ((state (lem:parse-partial-sexp from to))
                                          (inside (< 0 end (length text)))
                                          (token (lem:pps-state-token-start-point state)))
                                     (and (= (lem:position-at-point from)
                                             (+ 1 end (if (= end (1+ escape)) 1 0)))
                                          (eq (lem:pps-state-type state)
                                              (when inside (if (char= delimiter #\") :string :fence)))
                                          (eql (and token (lem:position-at-point token))
                                               (when inside 1))))))
                   "span scanning preserves string/fence state and escape overshoot at every endpoint")))
        (lem:delete-buffer buffer)))))

(deftest partial-parse-empty-openers
  (dolist (kind '(:line :block-comment :block-string))
    (let* ((table (apply #'lem/buffer/syntax-table:make-syntax-table
                         (ecase kind
                           (:line (list :line-comment-string ""))
                           (:block-comment (list :block-comment-pairs '(("" . "END"))))
                           (:block-string (list :block-string-pairs '(("" . "END")))))))
           (buffer (lem:make-buffer nil :temporary t :syntax-table table)))
      (unwind-protect
           (progn
             (lem:insert-string (lem:buffer-point buffer) "WORDEND")
             (lem:with-point ((from (lem:buffer-start-point buffer))
                              (to (lem:buffer-end-point buffer)))
               ;; Stop before an empty block-comment opener: entering that
               ;; pre-existing scanner cannot advance past its empty token.
               (let ((state (lem:parse-partial-sexp from to nil (eq kind :block-comment))))
                 (ok (eq (ecase kind (:line :line-comment) (:block-comment nil)
                             (:block-string :block-string))
                         (lem:pps-state-type state)))
                 (ok (= (if (member kind '(:line :block-comment)) 0 7) (lem:point-charpos from))))))
        (lem:delete-buffer buffer)))))

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

(deftest syntax-checkpoint-boundaries
  (let ((buffer (lem:make-buffer nil :temporary t
                                    :syntax-table lem-lisp-syntax:*syntax-table*)))
    (unwind-protect
         (progn
           (lem:insert-string (lem:buffer-point buffer)
                              (with-output-to-string (out)
                                (dotimes (i 140) (write-line "()" out))))
           ;; A checkpoint exactly on TO's line is intermediate only when TO
           ;; is past column zero. Also cover nonzero FROM columns and EOF.
           (dolist (case '((1 0 1 0 ((1 0)))
                           (1 0 1 1 ((1 1)))
                           (1 0 64 0 ((64 0)))
                           (1 0 65 0 ((65 0)))
                           (1 0 65 1 ((65 1) (65 0)))
                           (1 0 66 1 ((66 1) (65 0)))
                           (3 1 67 0 ((67 0)))
                           (3 1 67 1 ((67 1) (67 0)))
                           (3 1 131 0 ((131 0) (67 0)))
                           (3 1 132 1 ((132 1) (131 0) (67 0)))
                           (135 1 140 2 ((140 2)))
                           (135 1 141 0 ((141 0)))))
             (destructuring-bind (from-line from-column to-line to-column expected) case
               (lem:with-point ((from (lem:buffer-start-point buffer))
                                (to (lem:buffer-start-point buffer))
                                (cursor (lem:buffer-start-point buffer)))
                 (lem:line-offset from (1- from-line) from-column)
                 (lem:line-offset to (1- to-line) to-column)
                 (let* ((state (lem:parse-partial-sexp cursor from))
                        (tail (list (cons (lem:copy-point from :temporary) state))))
                   (multiple-value-bind (actual checkpoints)
                       (lem/buffer/internal::parse-with-ppss-checkpoints from to state tail)
                     (lem:buffer-start cursor)
                     (ok (equal (parse-state-description (lem:parse-partial-sexp cursor to))
                                (parse-state-description actual)))
                     (ok (equal expected
                                (loop :for rest :on checkpoints :until (eq rest tail)
                                      :for point := (caar rest)
                                      :collect (list (lem:line-number-at-point point)
                                                     (lem:point-charpos point)))))
                     (ok (eq tail (nthcdr (length expected) checkpoints)))
                     (ok (equal (list from-line from-column to-line to-column)
                                (list (lem:line-number-at-point from) (lem:point-charpos from)
                                      (lem:line-number-at-point to) (lem:point-charpos to))))))))))
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
