(in-package #:lem-structured-notes/tests)

(defparameter *org-list-fixture*
  (format nil
          "- [ ] First *strong* item.~%- [X] Second [[id:target][linked]] item.~%"))

(defparameter *org-table-fixture*
  (format nil
          "| Name | Value |~%|------+-------|~%| Alpha | *strong* |~%| Beta | [[id:target][linked]] |~%"))

(defparameter *org-code-fixture*
  (format nil
          "#+begin_src common-lisp~%(format t \"hello\")~%```~%#+end_src~%"))

(defparameter *org-quote-fixture*
  (format nil
          "#+begin_quote~%Quoted *strong* and [[id:target][linked]].~%#+end_quote~%"))

(defparameter *org-drawer-fixture*
  (format nil
          ":NOTES:~%Remember *strong* and [[id:target][linked]].~%:END:~%"))

(define-foundation-test list-model-validates-order-checkbox-and-inlines
  (let* ((inline (make-inline-node :kind :text :source-format :org
                                   :raw "item" :text "item"))
         (item (make-list-item :source-format :org :raw "- item"
                               :ordered-p nil :checkbox :unchecked
                               :inlines (list inline))))
    (assert-false (list-item-ordered-p item))
    (assert-equal :unchecked (list-item-checkbox item)))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (make-list-item
      :source-format :org :raw "1. item" :ordered-p t :ordinal nil
      :inlines (list (make-inline-node :kind :text :source-format :org
                                       :raw "item" :text "item")))))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (make-content-node
      :kind :paragraph :source-format :org :raw "paragraph"
      :items
      (list (make-list-item
             :source-format :org :raw "- item" :ordered-p nil
             :inlines (list (make-inline-node
                             :kind :text :source-format :org
                             :raw "item" :text "item"))))))))

(define-foundation-test org-list-parser-projects-items-checkboxes-and-spans
  (multiple-value-bind (items valid-p)
      (parse-org-list-items *org-list-fixture* :source-id "list.org"
                            :character-base 10 :byte-base 10)
    (assert-true valid-p)
    (assert-equal 2 (length items))
    (assert-equal '(:unchecked :checked)
                  (mapcar #'list-item-checkbox items))
    (assert-equal :strong
                  (inline-node-kind
                   (second (list-item-inlines (first items)))))
    (assert-equal 10
                  (source-span-character-start
                   (list-item-span (first items)))))
  (multiple-value-bind (items valid-p)
      (parse-org-list-items (format nil "- Éire~%- second~%")
                            :source-id "utf8-list.org")
    (assert-true valid-p)
    (let ((span (list-item-span (second items))))
      (assert-true (> (source-span-byte-start span)
                      (source-span-character-start span))))))

(define-foundation-test org-gfm-list-round-trip-is-semantic
  (multiple-value-bind (org-items valid-p)
      (parse-org-list-items *org-list-fixture* :source-id "list.org")
    (assert-true valid-p)
    (let ((lines (render-commonmark-list-lines org-items)))
      (assert-equal
       '("- [ ] First **strong** item."
         "- [x] Second [linked](id:target) item.")
       lines)
      (multiple-value-bind (markdown-items markdown-valid-p)
          (parse-commonmark-list-items
           (format nil "~{~a~%~}" lines) :source-id "list.md")
        (assert-true markdown-valid-p)
        (assert-true (list-items-equivalent-p org-items markdown-items))))))

(define-foundation-test unsupported-org-lists-remain-untyped
  (dolist (source
           (list (format nil "  - nested~%")
                 (format nil "* column-zero Org heading~%")
                 (format nil "- term :: description~%")
                 (format nil "- term~c::~cdescription~%" #\Tab #\Tab)
                 (format nil "- [-] partial~%")
                 (format nil "- [@4] counter cookie~%")
                 (format nil "- [X]missing checkbox separator~%")
                 (format nil "- first~%  continuation~%")
                 (format nil "- unordered~%1. ordered~%")
                 (format nil "- ambiguous =verbatim=~%")))
    (multiple-value-bind (items valid-p)
        (parse-org-list-items source :source-id "unsupported.org")
      (assert-false valid-p)
      (assert-false items))))

(define-foundation-test lsm-parser-groups-consecutive-native-list-lines
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: list-doc~%---~%# Node~%~%:::{lem-node}~%id: node:list~%:::~%~%- [ ] First item.~%- [x] Second item.~%"))
         (document
           (source-snapshot-document
            (parse-source (make-instance 'lsm-provider) source
                          :source-id "list.md" :revision "rev-1")))
         (body (semantic-node-body (first (semantic-document-nodes document))))
         (list-content (first body)))
    (assert-equal 1 (length body))
    (assert-equal :list (content-node-kind list-content))
    (assert-equal 2 (length (content-node-items list-content)))
    (assert-true (content-node-native-commonmark-list-p list-content))))

(define-foundation-test lsm-parser-does-not-type-lists-with-lazy-continuations
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: lazy-list~%---~%# Node~%~%- First line~%lazy continuation~%"))
         (body
           (semantic-node-body
            (first
             (semantic-document-nodes
              (source-snapshot-document
               (parse-source (make-instance 'lsm-provider) source
                             :source-id "lazy.md" :revision "rev-1")))))))
    (assert-false (find-if #'content-node-items body))
    (assert-equal :opaque (content-node-kind (first body)))))

(define-foundation-test mismatched-list-source-evidence-fails-closed
  (multiple-value-bind (items valid-p)
      (parse-org-list-items (format nil "- Different item.~%")
                            :source-id "mismatch.org")
    (assert-true valid-p)
    (let* ((content
             (make-content-node :kind :list :source-format :org
                                :raw (format nil "- Original item.~%")
                                :items items))
           (node (make-semantic-node :id "node:list-mismatch" :level 1
                                     :title "Mismatch"
                                     :body (list content)))
           (document
             (make-semantic-document
              :id "document:list-mismatch" :source-uri "mismatch.org"
              :format :org :profile "org/test" :nodes (list node)
              :root-ids '("node:list-mismatch")
              :source-revision "rev-1")))
      (assert-signals 'semantic-model-error
                      (lambda () (render-lsm-document document))))))

(define-foundation-test table-model-validates-rectangular-rows
  (let* ((cell (make-table-cell :source-format :org :raw "A"
                                :inlines
                                (list (make-inline-node
                                       :kind :text :source-format :org
                                       :raw "A" :text "A"))))
         (row (make-table-row :source-format :org :raw "| A |"
                              :cells (list cell)))
         (table (make-table-data :alignments '(:default)
                                 :rows (list row))))
    (assert-equal 1 (length (table-data-rows table))))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (make-table-data
      :alignments '(:default :default)
      :rows (list (make-table-row
                   :source-format :org :raw "| A |"
                   :cells (list (make-table-cell
                                 :source-format :org :raw "A"))))))))

(define-foundation-test org-gfm-table-round-trip-is-semantic
  (multiple-value-bind (org-table valid-p)
      (parse-org-table-data *org-table-fixture* :source-id "table.org")
    (assert-true valid-p)
    (assert-equal 3 (length (table-data-rows org-table)))
    (let ((lines (render-gfm-table-lines org-table)))
      (assert-equal
       '("| Name | Value |"
         "| --- | --- |"
         "| Alpha | **strong** |"
         "| Beta | [linked](id:target) |")
       lines)
      (multiple-value-bind (gfm-table gfm-valid-p)
          (parse-gfm-table-data (format nil "~{~a~%~}" lines)
                                :source-id "table.md")
        (assert-true gfm-valid-p)
        (assert-true (table-data-equivalent-p org-table gfm-table)))))
  (multiple-value-bind (table valid-p)
      (parse-gfm-table-data
       (format nil "| Left | Right |~%| :--- | ---: |~%| a | b |~%"))
    (assert-true valid-p)
    (assert-equal '(:left :right) (table-data-alignments table)))
  (multiple-value-bind (table valid-p)
      (parse-gfm-table-data
       (format nil "| A | B |~%| --- | --- |~%| a \\| b | c |~%"))
    (assert-true valid-p)
    (assert-equal "a | b"
                  (inline-node-text
                   (first
                    (table-cell-inlines
                     (first (table-row-cells
                             (second (table-data-rows table)))))))
                  :test #'string=))
  (multiple-value-bind (table valid-p)
      (parse-org-table-data
       (format nil "| Éire | B |~%|------+---|~%| row | cell |~%")
       :source-id "utf8-table.org")
    (assert-true valid-p)
    (let ((span (table-row-span (second (table-data-rows table)))))
      (assert-true (> (source-span-byte-start span)
                      (source-span-character-start span))))))

(define-foundation-test unsupported-org-tables-remain-untyped
  (dolist (source
           (list (format nil "| A | B |~%| 1 | 2 |~%")
                 (format nil "| A | B |~%|---|~%| 1 | 2 |~%")
                 (format nil "| A | B |~%|---+---|~%| 1 |~%")
                 (format nil "| A | B |~%|---+---|~%| 1 | 2 |~%#+TBLFM: $2=$1~%")
                 (format nil "| A | B |~%|---+---|~%| 1 | 2 |~%|---+---|~%")
                 (format nil "| A | B |~%|---+---|~%| # | recalculated |~%")
                 (format nil "| A | B |~%|---+---|~%| / | < |~%")
                 (format nil "| <l> | B |~%|---+---|~%| 1 | 2 |~%")))
    (multiple-value-bind (table valid-p)
        (parse-org-table-data source :source-id "unsupported-table.org")
      (assert-false valid-p)
      (assert-false table))))

(define-foundation-test lsm-parser-groups-native-gfm-table-lines
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: table-doc~%---~%# Node~%~%| A | B |~%| :--- | ---: |~%| one | two |~%"))
         (body
           (semantic-node-body
            (first
             (semantic-document-nodes
              (source-snapshot-document
               (parse-source (make-instance 'lsm-provider) source
                             :source-id "table.md" :revision "rev-1"))))))
         (content (first body)))
    (assert-equal 1 (length body))
    (assert-equal :table (content-node-kind content))
    (assert-equal '(:left :right)
                  (table-data-alignments (content-node-table content)))
    (assert-true (content-node-native-gfm-table-p content))))

(define-foundation-test mismatched-table-source-evidence-fails-closed
  (multiple-value-bind (table valid-p)
      (parse-org-table-data *org-table-fixture* :source-id "table.org")
    (assert-true valid-p)
    (let* ((content
             (make-content-node
              :kind :table :source-format :org
              :raw (format nil "| Other | Data |~%|-------+------|~%| x | y |~%")
              :table table))
           (node (make-semantic-node :id "node:table-mismatch" :level 1
                                     :title "Mismatch" :body (list content)))
           (document
             (make-semantic-document
              :id "document:table-mismatch" :source-uri "table.org"
              :format :org :profile "org/test" :nodes (list node)
              :root-ids '("node:table-mismatch")
              :source-revision "rev-1")))
      (assert-signals 'semantic-model-error
                      (lambda () (render-lsm-document document))))))

(define-foundation-test code-block-model-validates-normalized-code
  (let ((block
          (make-code-block-data
           :source-format :org :raw *org-code-fixture*
           :language "common-lisp" :code (format nil "(+ 1 2)~%"))))
    (assert-equal "common-lisp" (code-block-data-language block)
                  :test #'string=))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (make-code-block-data :source-format :org :raw "raw"
                           :language "lisp" :code "not terminated"))))

(define-foundation-test org-fenced-code-round-trip-is-semantic
  (multiple-value-bind (org-code valid-p)
      (parse-org-source-block-data *org-code-fixture*
                                   :source-id "code.org")
    (assert-true valid-p)
    (assert-equal "common-lisp" (code-block-data-language org-code)
                  :test #'string=)
    (assert-equal (format nil "(format t \"hello\")~%```~%")
                  (code-block-data-code org-code) :test #'string=)
    (let ((lines (render-commonmark-fenced-code-lines org-code)))
      (assert-equal "````common-lisp" (first lines) :test #'string=)
      (assert-equal "````" (car (last lines)) :test #'string=)
      (multiple-value-bind (markdown-code markdown-valid-p)
          (parse-commonmark-fenced-code-data
           (format nil "~{~a~%~}" lines) :source-id "code.md")
        (assert-true markdown-valid-p)
        (assert-true
         (code-block-data-equivalent-p org-code markdown-code)))))
  (multiple-value-bind (code valid-p)
      (parse-commonmark-fenced-code-data
       (concatenate 'string "~~~python" (string #\Newline)
                    "print(1)" (string #\Newline)
                    "~~~programlisting" (string #\Newline)))
    (assert-false valid-p)
    (assert-false code)))

(define-foundation-test parameterized-org-source-blocks-remain-untyped
  (dolist (source
           (list (format nil
                         "#+begin_src common-lisp :results value~%(+ 1 2)~%#+end_src~%")
                 (format nil
                         "#+begin_src common lisp~%(+ 1 2)~%#+end_src~%")
                 (format nil
                         "  #+begin_src lisp~%(+ 1 2)~%  #+end_src~%")
                 (format nil "#+begin_src lisp~%(+ 1 2)~%")))
    (multiple-value-bind (code valid-p)
        (parse-org-source-block-data source :source-id "opaque-code.org")
      (assert-false valid-p)
      (assert-false code))))

(define-foundation-test lsm-parser-projects-native-fenced-code
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: code-doc~%---~%# Node~%~%```lisp~%(+ 1 2)~%```~%"))
         (body
           (semantic-node-body
            (first
             (semantic-document-nodes
              (source-snapshot-document
               (parse-source (make-instance 'lsm-provider) source
                             :source-id "code.md" :revision "rev-1"))))))
         (content (first body)))
    (assert-equal 1 (length body))
    (assert-equal :source-block (content-node-kind content))
    (assert-equal "lisp"
                  (code-block-data-language
                   (content-node-code-block content))
                  :test #'string=)
    (assert-true (content-node-native-fenced-code-p content))))

(define-foundation-test myst-code-cell-round-trip-is-typed-and-canonical
  (let ((source
          (format nil
                  "::::{code-cell} bash~%:dir: ./subdir~%:results: replace~%~%printf 'cell-ok\\n'~%:::~%::::~%")))
    (multiple-value-bind (cell valid-p)
        (parse-myst-code-cell-data source :source-id "cell.md")
      (assert-true valid-p)
      (assert-equal :myst (code-block-data-source-format cell))
      (assert-equal "bash" (code-block-data-language cell) :test #'string=)
      (assert-equal (format nil "printf 'cell-ok\\n'~%:::~%")
                    (code-block-data-code cell) :test #'string=)
      (assert-equal '(("dir" . "./subdir") ("results" . "replace"))
                    (code-block-data-attributes cell))
      (let ((rendered (format nil "~{~a~%~}"
                              (render-myst-code-cell-lines cell))))
        (assert-equal source rendered :test #'string=)
        (multiple-value-bind (reparsed reparsed-p)
            (parse-myst-code-cell-data rendered :source-id "cell.md")
          (assert-true reparsed-p)
          (assert-true (code-block-data-equivalent-p cell reparsed)))))))

(define-foundation-test lsm-parser-projects-standard-myst-code-cells
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: cell-doc~%---~%# Node~%~%:::{code-cell} python~%:results: none~%~%:body-option: inert-code~%print('ok')~%:::~%"))
         (snapshot
           (parse-source (make-instance 'lsm-provider) source
                         :source-id "cell.md" :revision "rev-1"))
         (content
           (first
            (semantic-node-body
             (first
              (semantic-document-nodes
               (source-snapshot-document snapshot)))))))
    (assert-equal :source-block (content-node-kind content))
    (assert-equal :myst (content-node-source-format content))
    (assert-equal "code-cell" (content-node-name content) :test #'string=)
    (assert-true (content-node-native-myst-code-cell-p content))
    (assert-true (content-node-native-code-block-p content))
    (let ((cst
            (find "code-cell"
                  (lsm-syntax-document-nodes
                   (source-snapshot-syntax-tree snapshot))
                  :key #'cst-node-name :test #'string=)))
      (assert-true cst)
      (assert-equal '(("results" . "none")) (cst-node-fields cst)))))

(define-foundation-test mismatched-code-block-source-evidence-fails-closed
  (multiple-value-bind (code valid-p)
      (parse-org-source-block-data *org-code-fixture*
                                   :source-id "code.org")
    (assert-true valid-p)
    (let* ((content
             (make-content-node
              :kind :source-block :source-format :org
              :raw (format nil "#+begin_src lisp~%(different)~%#+end_src~%")
              :code-block code))
           (node (make-semantic-node :id "node:code-mismatch" :level 1
                                     :title "Mismatch" :body (list content)))
           (document
             (make-semantic-document
              :id "document:code-mismatch" :source-uri "code.org"
              :format :org :profile "org/test" :nodes (list node)
              :root-ids '("node:code-mismatch")
              :source-revision "rev-1")))
      (assert-signals 'semantic-model-error
                      (lambda () (render-lsm-document document))))))

(define-foundation-test org-commonmark-quote-round-trip-is-semantic
  (multiple-value-bind (org-inlines valid-p)
      (parse-org-quote-inlines *org-quote-fixture*
                               :source-id "quote.org")
    (assert-true valid-p)
    (let ((rendered (render-commonmark-quote-line org-inlines)))
      (assert-equal
       "> Quoted **strong** and [linked](id:target)." rendered
       :test #'string=)
      (multiple-value-bind (markdown-inlines markdown-valid-p)
          (parse-commonmark-quote-inlines
           (format nil "~a~%" rendered) :source-id "quote.md")
        (assert-true markdown-valid-p)
        (assert-true
         (inline-nodes-equivalent-p org-inlines markdown-inlines))))))

(define-foundation-test unsupported-org-quote-blocks-remain-untyped
  (dolist (source
           (list
            (format nil
                    "#+begin_quote :role note~%Text.~%#+end_quote~%")
            (format nil
                    "#+begin_quote~%First.~%Second.~%#+end_quote~%")
            (format nil
                    "#+begin_quote~%- nested list item~%#+end_quote~%")
            (format nil
                    "  #+begin_quote~%Text.~%  #+end_quote~%")
            (format nil "#+begin_quote~%Unclosed.~%")))
    (multiple-value-bind (inlines valid-p)
        (parse-org-quote-inlines source :source-id "opaque-quote.org")
      (assert-false valid-p)
      (assert-false inlines))))

(define-foundation-test lsm-parser-projects-native-commonmark-quote
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: quote-doc~%---~%# Node~%~%> Quoted **strong** text.~%"))
         (body
           (semantic-node-body
            (first
             (semantic-document-nodes
              (source-snapshot-document
               (parse-source (make-instance 'lsm-provider) source
                             :source-id "quote.md" :revision "rev-1"))))))
         (content (first body)))
    (assert-equal 1 (length body))
    (assert-equal :quote (content-node-kind content))
    (assert-equal :commonmark (content-node-source-format content))
    (assert-true (content-node-native-commonmark-quote-p content))))

(define-foundation-test lsm-parser-retains-multiline-blockquote-opaquely
  (dolist (quote-raw
           (list (format nil "> First line.~%> Second line.~%")
                 (format nil "> First line.~%lazy continuation~%")))
    (let* ((source
             (format nil
                     "---~%lem:~%  profile: lsm/1~%  document-id: quote-doc~%---~%# Node~%~%~a"
                     quote-raw))
           (body
             (semantic-node-body
              (first
               (semantic-document-nodes
                (source-snapshot-document
                 (parse-source (make-instance 'lsm-provider) source
                               :source-id "quote.md" :revision "rev-1")))))))
      (assert-equal 2 (length body))
      (assert-true (every (lambda (content)
                            (eq :opaque (content-node-kind content)))
                          body))
      (assert-true (every (lambda (content)
                            (eq :lsm (content-node-source-format content)))
                          body)))))

(define-foundation-test mismatched-quote-source-evidence-fails-closed
  (multiple-value-bind (inlines valid-p)
      (parse-org-quote-inlines *org-quote-fixture*
                               :source-id "quote.org")
    (assert-true valid-p)
    (let* ((content
             (make-content-node
              :kind :quote :source-format :org
              :raw (format nil
                           "#+begin_quote~%Different.~%#+end_quote~%")
              :inlines inlines))
           (node (make-semantic-node :id "node:quote-mismatch" :level 1
                                     :title "Mismatch" :body (list content)))
           (document
             (make-semantic-document
              :id "document:quote-mismatch" :source-uri "quote.org"
              :format :org :profile "org/test" :nodes (list node)
              :root-ids '("node:quote-mismatch")
              :source-revision "rev-1")))
      (assert-signals 'semantic-model-error
                      (lambda () (render-lsm-document document))))))

(define-foundation-test org-myst-drawer-round-trip-is-semantic
  (multiple-value-bind (name org-inlines valid-p)
      (parse-org-drawer-inlines *org-drawer-fixture*
                                :source-id "drawer.org")
    (assert-true valid-p)
    (assert-equal "NOTES" name :test #'string=)
    (let ((rendered
            (format nil "~{~a~%~}"
                    (render-myst-drawer-lines name org-inlines))))
      (assert-true (search "content: Remember **strong**" rendered))
      (multiple-value-bind (parsed-name markdown-inlines markdown-valid-p)
          (parse-myst-drawer-inlines rendered :source-id "drawer.md")
        (assert-true markdown-valid-p)
        (assert-equal name parsed-name :test #'string=)
        (assert-true
         (inline-nodes-equivalent-p org-inlines markdown-inlines))))))

(define-foundation-test unsupported-org-drawers-remain-untyped
  (dolist (source
           (list
            (format nil ":LOGBOOK:~%CLOCK: value~%:END:~%")
            (format nil ":PROPERTIES:~%:ID: value~%:END:~%")
            (format nil ":NOTES:~%First.~%Second.~%:END:~%")
            (format nil ":NOTES:~%- nested list item~%:END:~%")
            (format nil "  :NOTES:~%Text.~%  :END:~%")
            (format nil ":BAD.NAME:~%Text.~%:END:~%")))
    (multiple-value-bind (name inlines valid-p)
        (parse-org-drawer-inlines source :source-id "opaque-drawer.org")
      (assert-false valid-p)
      (assert-false name)
      (assert-false inlines))))

(define-foundation-test lsm-parser-projects-native-myst-drawer
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: drawer-doc~%---~%# Node~%~%:::{lem-drawer}~%name: NOTES~%content: Remember **strong**.~%:::~%"))
         (body
           (semantic-node-body
            (first
             (semantic-document-nodes
              (source-snapshot-document
               (parse-source (make-instance 'lsm-provider) source
                             :source-id "drawer.md" :revision "rev-1"))))))
         (content (first body)))
    (assert-equal 1 (length body))
    (assert-equal :drawer (content-node-kind content))
    (assert-equal :myst (content-node-source-format content))
    (assert-equal "NOTES" (content-node-name content) :test #'string=)
    (assert-true (content-node-native-myst-drawer-p content))))

(define-foundation-test mismatched-drawer-source-evidence-fails-closed
  (multiple-value-bind (name inlines valid-p)
      (parse-org-drawer-inlines *org-drawer-fixture*
                                :source-id "drawer.org")
    (assert-true valid-p)
    (let* ((content
             (make-content-node
              :kind :drawer :source-format :org
              :raw (format nil ":OTHER:~%Different.~%:END:~%")
              :name name :inlines inlines))
           (node (make-semantic-node :id "node:drawer-mismatch" :level 1
                                     :title "Mismatch" :body (list content)))
           (document
             (make-semantic-document
              :id "document:drawer-mismatch" :source-uri "drawer.org"
              :format :org :profile "org/test" :nodes (list node)
              :root-ids '("node:drawer-mismatch")
              :source-revision "rev-1")))
      (assert-signals 'semantic-model-error
                      (lambda () (render-lsm-document document))))))
