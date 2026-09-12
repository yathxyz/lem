(in-package #:lem-structured-notes/tests)

(defparameter *org-inline-fixture*
  (concatenate 'string
               "Plain *bold* /italic/ ~code~ [[https://example.com][site]]."
               (string #\Newline)))

(define-foundation-test inline-model-validates-leaves-and-containers
  (let* ((text (make-inline-node :kind :text :source-format :org
                                 :raw "bold" :text "bold"))
         (strong (make-inline-node :kind :strong :source-format :org
                                   :raw "*bold*" :children (list text))))
    (assert-equal :strong (inline-node-kind strong))
    (assert-equal "bold" (inline-node-text (first (inline-node-children strong)))
                  :test #'string=))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (make-inline-node :kind :link :source-format :org
                       :raw "[[missing-destination]]"
                       :children
                       (list (make-inline-node :kind :text :source-format :org
                                               :raw "label" :text "label"))))))

(define-foundation-test org-inline-parser-projects-typed-source-spans
  (multiple-value-bind (nodes valid-p)
      (parse-org-paragraph-inlines *org-inline-fixture*
                                   :source-id "inline.org"
                                   :character-base 10 :byte-base 10)
    (assert-true valid-p)
    (assert-equal '(:text :strong :text :emphasis :text :code :text :link
                    :text)
                  (mapcar #'inline-node-kind nodes))
    (let ((strong (find :strong nodes :key #'inline-node-kind))
          (link (find :link nodes :key #'inline-node-kind)))
      (assert-equal "*bold*" (inline-node-raw strong) :test #'string=)
      (assert-equal "https://example.com" (inline-node-destination link)
                    :test #'string=)
      (assert-equal 16
                    (source-span-character-start (inline-node-span strong)))))
  (multiple-value-bind (nodes valid-p)
      (parse-org-paragraph-inlines
       (format nil "Éire *bold*.~%") :source-id "utf8-inline.org")
    (assert-true valid-p)
    (let ((span (inline-node-span
                 (find :strong nodes :key #'inline-node-kind))))
      (assert-true (> (source-span-byte-start span)
                      (source-span-character-start span))))))

(define-foundation-test org-commonmark-inline-round-trip-is-semantic
  (multiple-value-bind (org-nodes org-valid-p)
      (parse-org-paragraph-inlines *org-inline-fixture*
                                   :source-id "inline.org")
    (assert-true org-valid-p)
    (let ((markdown (render-commonmark-inlines org-nodes)))
      (assert-equal
       "Plain **bold** *italic* `code` [site](https://example.com)."
       markdown :test #'string=)
      (multiple-value-bind (markdown-nodes markdown-valid-p)
          (parse-commonmark-paragraph-inlines markdown
                                              :source-id "inline.md")
        (assert-true markdown-valid-p)
        (assert-true
         (inline-nodes-equivalent-p org-nodes markdown-nodes))))))

(define-foundation-test ambiguous-inline-syntax-remains-untyped
  (dolist (source
           (list (format nil "Org =verbatim= stays opaque.~%")
                 (format nil "Timestamp <2026-08-01 Sat> stays opaque.~%")
                 (format nil "Footnote [fn:source] stays opaque.~%")
                 (format nil "Citation [cite:@source] stays opaque.~%")
                 (format nil "Statistics [50%] stay opaque.~%")
                 (format nil "Broken *emphasis stays opaque.~%")))
    (multiple-value-bind (nodes valid-p)
        (parse-org-paragraph-inlines source :source-id "ambiguous.org")
      (assert-false valid-p)
      (assert-false nodes)))
  (dolist (source (list (format nil "- list item~%")
                        (format nil "1. list item~%")
                        (format nil "---~%")
                        (format nil "===~%")))
    (multiple-value-bind (nodes valid-p)
        (parse-commonmark-paragraph-inlines source :source-id "block.md")
      (assert-false valid-p)
      (assert-false nodes)))
  (dolist (source
           (list (format nil "{role}`value`~%")
                 (format nil "<span>raw HTML</span>~%")
                 (format nil "&amp; entity~%")
                 (format nil "![image](image.png)~%")))
    (multiple-value-bind (nodes valid-p)
        (parse-commonmark-paragraph-inlines source :source-id "extended.md")
      (assert-false valid-p)
      (assert-false nodes))))

(define-foundation-test mismatched-inline-source-evidence-fails-closed
  (let* ((wrong-inline
           (make-inline-node :kind :text :source-format :org
                             :raw "Different" :text "Different"))
         (content
           (make-content-node :kind :paragraph :source-format :org
                              :raw (format nil "Original.~%")
                              :inlines (list wrong-inline)))
         (node (make-semantic-node :id "node:mismatch" :level 1
                                   :title "Mismatch" :body (list content)))
         (document
           (make-semantic-document
            :id "document:mismatch" :source-uri "mismatch.org" :format :org
            :profile "org/test" :nodes (list node)
            :root-ids '("node:mismatch") :source-revision "rev-1")))
    (assert-signals 'semantic-model-error
                    (lambda () (render-lsm-document document)))))

(define-foundation-test block-like-inline-rendering-fails-closed
  (let* ((raw (format nil "1. item~%"))
         (inlines
           (multiple-value-bind (nodes valid-p)
               (parse-org-paragraph-inlines raw :source-id "block-like.org")
             (assert-true valid-p)
             nodes))
         (content
           (make-content-node :kind :paragraph :source-format :org
                              :raw raw :inlines inlines))
         (node (make-semantic-node :id "node:block-like" :level 1
                                   :title "Block-like" :body (list content)))
         (document
           (make-semantic-document
            :id "document:block-like" :source-uri "block-like.org"
            :format :org :profile "org/test" :nodes (list node)
            :root-ids '("node:block-like") :source-revision "rev-1")))
    (assert-signals 'semantic-model-error
                    (lambda () (render-lsm-document document)))))
