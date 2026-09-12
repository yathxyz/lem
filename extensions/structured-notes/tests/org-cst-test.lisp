(in-package #:lem-structured-notes/tests)

(defparameter *org-content-matrix*
  (format nil
          "#+TITLE: Matrix~%* TODO Node~%SCHEDULED: <2026-08-01 Sat>~%:PROPERTIES:~%:ID: matrix~%:END:~%~%Paragraph λ with [[id:target][link]].~%Second line.~%~%- [ ] first~%- [X] second~%~%| A | B |~%| 1 | 2 |~%#+TBLFM: $2=$1+1~%~%#+begin_src common-lisp :results value~%(+ 1 2)~%* not a heading~%#+end_src~%~%:LOGBOOK:~%CLOCK: [2026-08-01 Sat 09:00]--[2026-08-01 Sat 10:00] =>  1:00~%:END:~%~%# comment~%"))

(defun org-test-crlf (source)
  (with-output-to-string (stream)
    (loop :for character :across source
          :do (if (char= character #\Newline)
                  (progn (write-char #\Return stream)
                         (write-char #\Newline stream))
                  (write-char character stream)))))

(define-foundation-test untouched-org-cst-is-byte-identical
  (dolist (source (list *org-content-matrix*
                        (org-test-crlf *org-content-matrix*)))
    (let ((syntax (parse-org-cst source :source-id "matrix.org")))
      (assert-equal source (serialize-org-cst syntax) :test #'string=))))

(define-foundation-test org-cst-recognizes-block-content-families
  (let* ((syntax (parse-org-cst *org-content-matrix*
                                :source-id "matrix.org"))
         (elements (org-cst-document-elements syntax))
         (kinds (mapcar #'org-cst-element-kind elements)))
    (dolist (kind '(:keyword :heading :planning :property-drawer :blank
                    :paragraph :list :table :source-block :drawer :comment))
      (assert-true (member kind kinds)
                   (format nil "missing Org CST kind ~s" kind)))
    (assert-equal 1 (count :heading kinds))
    (let ((source-block (find :source-block elements
                              :key #'org-cst-element-kind)))
      (assert-equal "src" (org-cst-element-name source-block)
                    :test #'string=)
      (assert-true (search "* not a heading"
                           (org-cst-element-raw source-block))))))

(define-foundation-test org-cst-projects-exact-content-nodes
  (let* ((syntax (parse-org-cst *org-content-matrix*
                                :source-id "matrix.org"))
         (heading (find :heading (org-cst-document-elements syntax)
                        :key #'org-cst-element-kind))
         (body (org-cst-content-nodes-in-range
                syntax (org-cst-element-character-end heading)
                (length *org-content-matrix*))))
    (assert-true (every #'content-node-p body))
    (assert-true (find :paragraph body :key #'content-node-kind))
    (assert-true (find :source-block body :key #'content-node-kind))
    (assert-true (find :drawer body :key #'content-node-kind))
    (assert-true
     (every (lambda (node)
              (let ((span (content-node-span node)))
                (string= (content-node-raw node)
                         (subseq *org-content-matrix*
                                 (source-span-character-start span)
                                 (source-span-character-end span)))))
            body))
    (let* ((paragraph (find :paragraph body :key #'content-node-kind))
           (span (content-node-span paragraph)))
      (assert-true (> (- (source-span-byte-end span)
                         (source-span-byte-start span))
                      (- (source-span-character-end span)
                         (source-span-character-start span)))))))

(define-foundation-test org-cst-types-supported-native-paragraphs
  (let* ((source
           (format nil
                   "Plain prose only.~%~%Ambiguous =verbatim= remains Org.~%"))
         (syntax (parse-org-cst source :source-id "paragraphs.org"))
         (paragraphs
           (remove-if-not
            (lambda (node) (eq :paragraph (content-node-kind node)))
            (org-cst-content-nodes-in-range syntax 0 (length source)))))
    (assert-equal 2 (length paragraphs))
    (assert-equal "Plain prose only."
                  (inline-node-text
                   (first (content-node-inlines (first paragraphs))))
                  :test #'string=)
    (assert-true
     (content-node-native-commonmark-paragraph-p (first paragraphs)))
    (assert-false (content-node-inlines (second paragraphs)))
    (assert-false
     (content-node-native-commonmark-paragraph-p (second paragraphs)))))

(define-foundation-test org-cst-types-only-single-line-native-comments
  (let* ((source
           (format nil
                   "# Native comment.~%~%  # Indented stays opaque.~%~%# First.~%# Second.~%"))
         (syntax (parse-org-cst source :source-id "comments.org"))
         (comments
           (remove-if-not
            (lambda (node) (eq :comment (content-node-kind node)))
            (org-cst-content-nodes-in-range syntax 0 (length source)))))
    (assert-equal 3 (length comments))
    (assert-equal "Native comment." (content-node-text (first comments))
                  :test #'string=)
    (assert-true (content-node-native-myst-comment-p (first comments)))
    (assert-false (content-node-text (second comments)))
    (assert-false (content-node-text (third comments)))))

(define-foundation-test org-cst-types-only-supported-flat-lists
  (let* ((source
           (format nil
                   "- [ ] native~%- [X] also native~%~%  - nested stays opaque~%~%- item with continuation~%  continued prose~%"))
         (syntax (parse-org-cst source :source-id "lists.org"))
         (lists
           (remove-if-not
            (lambda (node) (eq :list (content-node-kind node)))
            (org-cst-content-nodes-in-range syntax 0 (length source)))))
    (assert-equal 3 (length lists))
    (assert-equal 2 (length (content-node-items (first lists))))
    (assert-true (content-node-native-commonmark-list-p (first lists)))
    (assert-false (content-node-items (second lists)))
    (assert-false (content-node-native-commonmark-list-p (second lists)))
    (assert-false (content-node-items (third lists)))
    (assert-true (search "continued prose"
                         (content-node-raw (third lists))))))

(define-foundation-test org-cst-types-only-portable-header-tables
  (let* ((formula-table
           (format nil
                   "| A | B |~%|---+---|~%| 1 | 2 |~%#+TBLFM: $2=$1+1~%"))
         (source (format nil "~a~%~a" *org-table-fixture* formula-table))
         (syntax (parse-org-cst source :source-id "tables.org"))
         (tables
           (remove-if-not
            (lambda (node) (eq :table (content-node-kind node)))
            (org-cst-content-nodes-in-range syntax 0 (length source)))))
    (assert-equal 2 (length tables))
    (assert-true (content-node-table (first tables)))
    (assert-true (content-node-native-gfm-table-p (first tables)))
    (assert-false (content-node-table (second tables)))
    (assert-true (search "#+TBLFM:" (content-node-raw (second tables))))))

(define-foundation-test org-cst-types-only-portable-source-blocks
  (let* ((parameterized
           (format nil
                   "#+begin_src common-lisp :results value~%(+ 1 2)~%#+end_src~%"))
         (source (format nil "~a~%~a" *org-code-fixture* parameterized))
         (syntax (parse-org-cst source :source-id "code.org"))
         (blocks
           (remove-if-not
            (lambda (node) (eq :source-block (content-node-kind node)))
            (org-cst-content-nodes-in-range syntax 0 (length source)))))
    (assert-equal 2 (length blocks))
    (assert-true (content-node-code-block (first blocks)))
    (assert-true (content-node-native-fenced-code-p (first blocks)))
    (assert-false (content-node-name (first blocks)))
    (assert-false (content-node-code-block (second blocks)))
    (assert-equal "src" (content-node-name (second blocks))
                  :test #'string=)))

(define-foundation-test org-cst-types-only-portable-quote-blocks
  (let* ((multiline
           (format nil
                   "#+begin_quote~%First line.~%Second line.~%#+end_quote~%"))
         (source (format nil "~a~%~a" *org-quote-fixture* multiline))
         (syntax (parse-org-cst source :source-id "quotes.org"))
         (blocks
           (remove-if-not
            (lambda (node)
              (member (content-node-kind node) '(:quote :block)))
            (org-cst-content-nodes-in-range syntax 0 (length source)))))
    (assert-equal 2 (length blocks))
    (assert-equal :quote (content-node-kind (first blocks)))
    (assert-true (content-node-inlines (first blocks)))
    (assert-true (content-node-native-commonmark-quote-p (first blocks)))
    (assert-false (content-node-name (first blocks)))
    (assert-equal :block (content-node-kind (second blocks)))
    (assert-false (content-node-inlines (second blocks)))
    (assert-equal "quote" (content-node-name (second blocks))
                  :test #'string=)))

(define-foundation-test org-cst-types-only-portable-generic-drawers
  (let* ((logbook (format nil ":LOGBOOK:~%CLOCK: value~%:END:~%"))
         (source (format nil "~a~%~a" *org-drawer-fixture* logbook))
         (syntax (parse-org-cst source :source-id "drawers.org"))
         (drawers
           (remove-if-not
            (lambda (node) (eq :drawer (content-node-kind node)))
            (org-cst-content-nodes-in-range syntax 0 (length source)))))
    (assert-equal 2 (length drawers))
    (assert-true (content-node-inlines (first drawers)))
    (assert-true (content-node-native-myst-drawer-p (first drawers)))
    (assert-equal "NOTES" (content-node-name (first drawers))
                  :test #'string=)
    (assert-false (content-node-inlines (second drawers)))
    (assert-equal "LOGBOOK" (content-node-name (second drawers))
                  :test #'string=)))

(define-foundation-test unclosed-org-structures-are-preserved-and-diagnosed
  (let* ((source (format nil "* Node~%#+begin_quote~%unterminated~%"))
         (syntax (parse-org-cst source :source-id "broken.org"))
         (block (find :block (org-cst-document-elements syntax)
                      :key #'org-cst-element-kind)))
    (assert-true block)
    (assert-false (org-cst-element-closed-p block))
    (assert-equal source (serialize-org-cst syntax) :test #'string=)
    (assert-true
     (find :unclosed-org-block (org-cst-document-diagnostics syntax)
           :key #'diagnostic-code)))
  (let* ((source (format nil "* Node~%:LOGBOOK:~%CLOCK: open~%"))
         (syntax (parse-org-cst source :source-id "broken-drawer.org"))
         (drawer (find :drawer (org-cst-document-elements syntax)
                       :key #'org-cst-element-kind)))
    (assert-true drawer)
    (assert-false (org-cst-element-closed-p drawer))
    (assert-equal source (serialize-org-cst syntax) :test #'string=)
    (assert-true
     (find :unclosed-org-drawer (org-cst-document-diagnostics syntax)
           :key #'diagnostic-code))))

(define-foundation-test org-cst-enforces-document-resource-limits
  (let ((lem-structured-notes::+org-cst-max-source-characters+ 8))
    (assert-equal
     :org-cst-source-limit-exceeded
     (signaled-model-code
      (lambda ()
        (parse-org-cst "* heading" :source-id "oversized.org")))))
  (let ((lem-structured-notes::+org-cst-max-source-characters+ 1024)
        (lem-structured-notes::+org-cst-max-lines+ 2))
    (assert-equal
     :org-cst-line-limit-exceeded
     (signaled-model-code
      (lambda ()
        (parse-org-cst (format nil "* one~%two~%three~%")
                       :source-id "too-many-lines.org"))))))
