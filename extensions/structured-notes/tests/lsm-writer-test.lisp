(in-package #:lem-structured-notes/tests)

(defun canonical-writer-document ()
  (let* ((child
           (make-semantic-node
            :id "node:deep"
            :level 7
            :title "Deep task"
            :parent-id "node:root"
            :tags '("calendar" "testing")
            :properties (list (cons "NOTE" "quoted \"value\"")
                              (cons "MULTILINE"
                                    (format nil "first~%second")))
            :calendar-bindings
            (list
             (make-calendar-binding
              :id "binding:task" :node-id "node:deep"
              :projection-kind :task :account-id "personal"
              :calendar-id "work" :uid "todo-42"
              :ownership :organizer :write-policy :bidirectional)
             (make-calendar-binding
              :id "binding:instance" :node-id "node:deep"
              :projection-kind :event :uid "event-42"
              :recurrence-id
              (make-temporal-value
               :kind :utc :local-value "2026-08-01T09:00:00Z")
              :ownership :server :write-policy :read-only))
            :task
            (make-task-facet
             :workflow-id "org/default"
             :state "FINISHED"
             :done-p t
             :priority "B"
             :effort "PT2H"
             :scheduled
             (make-temporal-value
              :kind :zoned
              :local-value "2026-08-01T09:00:00"
              :timezone-id "Europe/Dublin"
              :gap-policy :reject)
             :recurrence
             (make-recurrence :policy :completion-relative
                              :original-lexeme ".+1w"))))
         (root
           (make-semantic-node
            :id "node:root" :level 1 :title "Root"
            :child-ids '("node:deep")
            :event
            (make-event-facet
             :start
             (make-temporal-value
              :kind :zoned :local-value "2026-08-03T09:00:00"
              :timezone-id "Europe/Dublin" :gap-policy :reject)
             :end
             (make-temporal-value
              :kind :zoned :local-value "2026-08-03T10:00:00"
              :timezone-id "Europe/Dublin" :gap-policy :reject)
             :status "CONFIRMED" :location "Room 4"
             :url "https://example.test/events/42"
             :transparency :opaque
             :recurrence
             (make-recurrence
              :rules '("FREQ=WEEKLY;BYDAY=MO,TU")
              :dates
              (list
               (make-temporal-value
                :kind :date :local-value "2026-08-05")
               (make-recurrence-period
                :start
                (make-temporal-value
                 :kind :zoned :local-value "2026-08-06T09:00:00"
                 :timezone-id "Europe/Dublin" :gap-policy :reject)
                :end
                (make-temporal-value
                 :kind :zoned :local-value "2026-08-06T11:00:00"
                 :timezone-id "Europe/Dublin" :gap-policy :reject))
               (make-recurrence-period
                :start
                (make-temporal-value
                 :kind :utc :local-value "2026-08-07T09:00:00Z")
                :duration "PT3H"))
              :exception-dates
              (list (make-temporal-value
                     :kind :date :local-value "2026-08-10"))
              :policy :fixed
              :original-lexeme "FREQ=WEEKLY;BYDAY=MO,TU")))))
    (make-semantic-document
     :id "document:writer"
     :source-uri "generated"
     :format :virtual
     :profile "semantic/1"
     :nodes (list root child)
     :root-ids '("node:root")
     :source-revision "rev-1")))

(define-foundation-test canonical-lsm-writer-round-trips-supported-semantics
  (let* ((document (canonical-writer-document))
         (source (render-lsm-document document :newline :crlf))
         (provider (make-instance 'lsm-provider))
         (snapshot (parse-source provider source
                                 :source-id "writer.md" :revision "rev-2"))
         (parsed (source-snapshot-document snapshot))
         (node (find-semantic-node parsed "node:deep"))
         (root (find-semantic-node parsed "node:root")))
    (assert-equal :crlf
                  (lsm-syntax-document-newline
                   (source-snapshot-syntax-tree snapshot)))
    (assert-equal "document:writer" (semantic-document-id parsed)
                  :test #'string=)
    (assert-true node)
    (assert-equal 7 (semantic-node-level node))
    (assert-equal '("calendar" "testing") (semantic-node-tags node))
    (assert-equal "quoted \"value\""
                  (cdr (assoc "NOTE" (semantic-node-properties node)
                              :test #'string=))
                  :test #'string=)
    (assert-equal (format nil "first~%second")
                  (cdr (assoc "MULTILINE" (semantic-node-properties node)
                              :test #'string=))
                  :test #'string=)
    (assert-equal :completion-relative
                  (recurrence-policy
                   (task-facet-recurrence (semantic-node-task node))))
    (assert-equal "FINISHED" (task-facet-state (semantic-node-task node))
                  :test #'string=)
    (assert-true (task-facet-done-p (semantic-node-task node)))
    (assert-equal :zoned
                  (temporal-value-kind
                   (task-facet-scheduled (semantic-node-task node))))
    (let ((bindings (semantic-node-calendar-bindings node)))
      (assert-equal 2 (length bindings))
      (assert-equal :task
                    (calendar-binding-projection-kind (first bindings)))
      (assert-equal "personal"
                    (calendar-binding-account-id (first bindings))
                    :test #'string=)
      (assert-equal :bidirectional
                    (calendar-binding-write-policy (first bindings)))
      (assert-equal :utc
                    (temporal-value-kind
                     (calendar-binding-recurrence-id (second bindings)))))
    (let* ((event (semantic-node-event root))
           (recurrence (event-facet-recurrence event)))
      (assert-true event)
      (assert-equal :zoned
                    (temporal-value-kind (event-facet-start event)))
      (assert-equal "Room 4" (event-facet-location event) :test #'string=)
      (assert-equal '("FREQ=WEEKLY;BYDAY=MO,TU")
                    (recurrence-rules recurrence))
      (assert-equal 3 (length (recurrence-dates recurrence)))
      (let ((explicit (second (recurrence-dates recurrence)))
            (nominal (third (recurrence-dates recurrence))))
        (assert-true (recurrence-period-p explicit))
        (assert-equal
         "Europe/Dublin"
         (temporal-value-timezone-id (recurrence-period-start explicit))
         :test #'string=)
        (assert-true (recurrence-period-end explicit))
        (assert-equal "PT3H" (recurrence-period-duration nominal)
                      :test #'string=))
      (assert-equal 1 (length (recurrence-exception-dates recurrence))))))

(define-foundation-test invalid-lsm-recurrence-period-fails-closed
  (dolist
      (value
       '("2026-08-06T09:00:00Z/"
         "/PT1H"
         "2026-08-06T09:00:00Z/-PT1H"
         "2026-08-06T09:00:00Z/PT1H/extra"
         "2026-08-06T10:00:00Z/2026-08-06T09:00:00Z"))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (lem-structured-notes::parse-lsm-recurrence-date value)))))

(define-foundation-test canonical-lsm-writer-refuses-unhandled-content
  (let* ((node
           (make-semantic-node
            :id "node:body" :level 1 :title "Body"
            :body (list (make-content-node :kind :opaque
                                           :source-format :lsm
                                           :raw "content"))))
         (document
           (make-semantic-document
            :id "document:body"
            :source-uri "generated"
            :format :virtual
            :profile "semantic/1"
            :nodes (list node)
            :root-ids '("node:body")
            :source-revision "rev-1")))
    (assert-signals 'semantic-model-error
                    (lambda () (render-lsm-document document)))
    (let ((extension-document
            (make-semantic-document
             :id "document:extension"
             :source-uri "generated"
             :format :virtual
             :profile "semantic/1"
             :nodes nil
             :root-ids nil
             :source-revision "rev-1"
             :extensions
             (list
              (make-opaque-extension
               :namespace "urn:test:opaque"
               :raw-value "must survive")))))
      (assert-signals 'semantic-model-error
                      (lambda ()
                        (render-lsm-document extension-document))))))

(define-foundation-test canonical-lsm-writer-refuses-silent-coercions
  (labels ((document-with-node (id node &key metadata)
             (make-semantic-document
              :id id :source-uri "generated" :format :virtual
              :profile "semantic/1" :metadata metadata
              :nodes (list node) :root-ids (list (semantic-node-id node))
              :source-revision "rev-1")))
    (let ((plain (make-semantic-node :id "node:plain" :level 1
                                     :title "Plain")))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (render-lsm-document
          (document-with-node "document:metadata" plain
                              :metadata '(("author" . "Yanni")))))))
    (let ((attributed
            (make-semantic-node
             :id "node:attributed" :level 1 :title "Attributed"
             :body
             (list (make-content-node
                    :kind :paragraph :source-format :org :raw "text"
                    :attributes '(("role" . "note")))))))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (render-lsm-document
          (document-with-node "document:attributes" attributed)))))
    (let ((typed-property
            (make-semantic-node
             :id "node:property" :level 1 :title "Property"
             :properties (list (cons "COUNT" 3)))))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (render-lsm-document
          (document-with-node "document:property" typed-property)))))))

(define-foundation-test canonical-lsm-writer-preserves-opaque-org-content
  (let* ((raw (format nil
                      "Paragraph with \"quotes\", \\slashes, and ~c control.~%~%- [ ] item~%"
                      (code-char 1)))
         (node
           (make-semantic-node
            :id "node:org-body" :level 1 :title "Org body"
            :body
            (list (make-content-node :kind :paragraph
                                     :source-format :org
                                     :raw raw))))
         (document
           (make-semantic-document
            :id "document:org-body" :source-uri "generated"
            :format :org :profile "org/test" :nodes (list node)
            :root-ids '("node:org-body") :source-revision "rev-1"))
         (lsm (render-lsm-document document))
         (snapshot
           (parse-source (make-instance 'lsm-provider) lsm
                         :source-id "body.md" :revision "rev-2"))
         (parsed-node
           (find-semantic-node (source-snapshot-document snapshot)
                               "node:org-body"))
         (content (first (semantic-node-body parsed-node))))
    (assert-true content)
    (assert-equal :org (content-node-source-format content))
    (assert-equal :paragraph (content-node-kind content))
    (assert-equal raw (content-node-raw content) :test #'string=)))

(define-foundation-test canonical-lsm-writer-preserves-opaque-org-preamble
  (let* ((raw (format nil "#+TITLE: Exact~%#+CATEGORY: Research~%"))
         (document
           (make-semantic-document
            :id "document:preamble" :source-uri "generated"
            :format :org :profile "org/test"
            :preamble
            (list (make-content-node :kind :keyword
                                     :source-format :org :raw raw))
            :nodes nil :root-ids nil :source-revision "rev-1"))
         (lsm (render-lsm-document document))
         (snapshot
           (parse-source (make-instance 'lsm-provider) lsm
                         :source-id "preamble.md" :revision "rev-2"))
         (preamble
           (semantic-document-preamble
            (source-snapshot-document snapshot))))
    (assert-equal 1 (length preamble))
    (assert-equal :keyword (content-node-kind (first preamble)))
    (assert-equal raw (content-node-raw (first preamble)) :test #'string=)))

(define-foundation-test canonical-lsm-writer-emits-native-plain-paragraph
  (let* ((content
           (multiple-value-bind (inlines valid-p)
               (parse-org-paragraph-inlines
                (format nil "Plain prose only.~%") :source-id "plain.org")
             (assert-true valid-p)
             (make-content-node :kind :paragraph :source-format :org
                                :raw (format nil "Plain prose only.~%")
                                :inlines inlines)))
         (node
           (make-semantic-node :id "node:plain" :level 1 :title "Plain"
                               :body (list content)))
         (document
           (make-semantic-document
            :id "document:plain" :source-uri "plain.org" :format :org
            :profile "org/test" :nodes (list node)
            :root-ids '("node:plain") :source-revision "rev-1"))
         (source (render-lsm-document document))
         (parsed
           (source-snapshot-document
            (parse-source (make-instance 'lsm-provider) source
                          :source-id "plain.md" :revision "rev-2")))
         (parsed-content
           (first (semantic-node-body
                   (find-semantic-node parsed "node:plain")))))
    (assert-true (search "Plain prose only." source))
    (assert-false (search "lem-org-opaque" source))
    (assert-equal :commonmark
                  (content-node-source-format parsed-content))
    (assert-equal "Plain prose only."
                  (inline-node-text
                   (first (content-node-inlines parsed-content)))
                  :test #'string=)
    (assert-true (semantic-document-equivalent-p document parsed))))

(define-foundation-test canonical-lsm-writer-emits-rich-native-inlines
  (multiple-value-bind (inlines valid-p)
      (parse-org-paragraph-inlines *org-inline-fixture*
                                   :source-id "rich.org")
    (assert-true valid-p)
    (let* ((content
             (make-content-node :kind :paragraph :source-format :org
                                :raw *org-inline-fixture* :inlines inlines))
           (node (make-semantic-node :id "node:rich" :level 1 :title "Rich"
                                     :body (list content)))
           (document
             (make-semantic-document
              :id "document:rich" :source-uri "rich.org" :format :org
              :profile "org/test" :nodes (list node)
              :root-ids '("node:rich") :source-revision "rev-1"))
           (source (render-lsm-document document))
           (parsed
             (source-snapshot-document
              (parse-source (make-instance 'lsm-provider) source
                            :source-id "rich.md" :revision "rev-2"))))
      (assert-true
       (search "Plain **bold** *italic* `code` [site](https://example.com)."
               source))
      (assert-false (search "lem-org-opaque" source))
      (assert-true (semantic-document-equivalent-p document parsed)))))

(define-foundation-test canonical-lsm-writer-emits-native-task-list
  (multiple-value-bind (items valid-p)
      (parse-org-list-items *org-list-fixture* :source-id "tasks.org")
    (assert-true valid-p)
    (let* ((content
             (make-content-node :kind :list :source-format :org
                                :raw *org-list-fixture* :items items))
           (node (make-semantic-node :id "node:tasks" :level 1
                                     :title "Tasks" :body (list content)))
           (document
             (make-semantic-document
              :id "document:tasks" :source-uri "tasks.org" :format :org
              :profile "org/test" :nodes (list node)
              :root-ids '("node:tasks") :source-revision "rev-1"))
           (source (render-lsm-document document))
           (parsed
             (source-snapshot-document
              (parse-source (make-instance 'lsm-provider) source
                            :source-id "tasks.md" :revision "rev-2"))))
      (assert-true (search "- [ ] First **strong** item." source))
      (assert-true
       (search "- [x] Second [linked](id:target) item." source))
      (assert-false (search "lem-org-opaque" source))
      (assert-true (semantic-document-equivalent-p document parsed)))))

(define-foundation-test canonical-lsm-writer-emits-native-gfm-table
  (multiple-value-bind (table valid-p)
      (parse-org-table-data *org-table-fixture* :source-id "table.org")
    (assert-true valid-p)
    (let* ((content
             (make-content-node :kind :table :source-format :org
                                :raw *org-table-fixture* :table table))
           (node (make-semantic-node :id "node:table" :level 1
                                     :title "Table" :body (list content)))
           (document
             (make-semantic-document
              :id "document:table" :source-uri "table.org" :format :org
              :profile "org/test" :nodes (list node)
              :root-ids '("node:table") :source-revision "rev-1"))
           (source (render-lsm-document document))
           (parsed
             (source-snapshot-document
              (parse-source (make-instance 'lsm-provider) source
                            :source-id "table.md" :revision "rev-2"))))
      (assert-true (search "| Name | Value |" source))
      (assert-true (search "| --- | --- |" source))
      (assert-true (search "| Alpha | **strong** |" source))
      (assert-false (search "lem-org-opaque" source))
      (assert-true (semantic-document-equivalent-p document parsed)))))

(define-foundation-test canonical-lsm-writer-emits-native-fenced-code
  (multiple-value-bind (code-block valid-p)
      (parse-org-source-block-data *org-code-fixture*
                                   :source-id "code.org")
    (assert-true valid-p)
    (let* ((content
             (make-content-node :kind :source-block :source-format :org
                                :raw *org-code-fixture*
                                :code-block code-block))
           (node (make-semantic-node :id "node:code" :level 1
                                     :title "Code" :body (list content)))
           (document
             (make-semantic-document
              :id "document:code" :source-uri "code.org" :format :org
              :profile "org/test" :nodes (list node)
              :root-ids '("node:code") :source-revision "rev-1"))
           (source (render-lsm-document document))
           (parsed
             (source-snapshot-document
              (parse-source (make-instance 'lsm-provider) source
                            :source-id "code.md" :revision "rev-2")))
           (parsed-content
             (first (semantic-node-body
                     (find-semantic-node parsed "node:code")))))
      (assert-true
       (search
        (format nil "````common-lisp~%(format t \"hello\")~%```~%````~%")
        source))
      (assert-false (search "lem-org-opaque" source))
      (assert-equal :commonmark
                    (code-block-data-source-format
                     (content-node-code-block parsed-content)))
      (assert-true (semantic-document-equivalent-p document parsed)))))

(define-foundation-test canonical-lsm-writer-emits-native-blockquote
  (multiple-value-bind (inlines valid-p)
      (parse-org-quote-inlines *org-quote-fixture*
                               :source-id "quote.org")
    (assert-true valid-p)
    (let* ((content
             (make-content-node :kind :quote :source-format :org
                                :raw *org-quote-fixture* :inlines inlines))
           (node (make-semantic-node :id "node:quote" :level 1
                                     :title "Quote" :body (list content)))
           (document
             (make-semantic-document
              :id "document:quote" :source-uri "quote.org" :format :org
              :profile "org/test" :nodes (list node)
              :root-ids '("node:quote") :source-revision "rev-1"))
           (source (render-lsm-document document))
           (parsed
             (source-snapshot-document
              (parse-source (make-instance 'lsm-provider) source
                            :source-id "quote.md" :revision "rev-2"))))
      (assert-true
       (search "> Quoted **strong** and [linked](id:target)." source))
      (assert-false (search "lem-org-opaque" source))
      (assert-true (semantic-document-equivalent-p document parsed)))))

(define-foundation-test canonical-lsm-writer-emits-native-myst-drawer
  (multiple-value-bind (name inlines valid-p)
      (parse-org-drawer-inlines *org-drawer-fixture*
                                :source-id "drawer.org")
    (assert-true valid-p)
    (let* ((content
             (make-content-node :kind :drawer :source-format :org
                                :raw *org-drawer-fixture*
                                :name name :inlines inlines))
           (node (make-semantic-node :id "node:drawer" :level 1
                                     :title "Drawer" :body (list content)))
           (document
             (make-semantic-document
              :id "document:drawer" :source-uri "drawer.org" :format :org
              :profile "org/test" :nodes (list node)
              :root-ids '("node:drawer") :source-revision "rev-1"))
           (source (render-lsm-document document))
           (parsed
             (source-snapshot-document
              (parse-source (make-instance 'lsm-provider) source
                            :source-id "drawer.md" :revision "rev-2"))))
      (assert-true (search ":::{lem-drawer}" source))
      (assert-true (search "name: NOTES" source))
      (assert-true
       (search "content: Remember **strong** and [linked](id:target)."
               source))
      (assert-false (search "lem-org-opaque" source))
      (assert-true (semantic-document-equivalent-p document parsed)))))

(define-foundation-test canonical-lsm-writer-emits-native-myst-comment
  (let* ((content
           (make-content-node :kind :comment :source-format :org
                              :raw (format nil "# Hidden note.~%")
                              :text "Hidden note."))
         (node
           (make-semantic-node :id "node:comment" :level 1 :title "Comment"
                               :body (list content)))
         (document
           (make-semantic-document
            :id "document:comment" :source-uri "comment.org" :format :org
            :profile "org/test" :nodes (list node)
            :root-ids '("node:comment") :source-revision "rev-1"))
         (source (render-lsm-document document))
         (parsed
           (source-snapshot-document
            (parse-source (make-instance 'lsm-provider) source
                          :source-id "comment.md" :revision "rev-2")))
         (parsed-content
           (first (semantic-node-body
                   (find-semantic-node parsed "node:comment")))))
    (assert-true (search (format nil "% Hidden note.~%") source))
    (assert-false (search "lem-org-opaque" source))
    (assert-equal :myst (content-node-source-format parsed-content))
    (assert-equal :comment (content-node-kind parsed-content))
    (assert-equal "Hidden note." (content-node-text parsed-content)
                  :test #'string=)
    (assert-true (semantic-document-equivalent-p document parsed))))

(define-foundation-test canonical-lsm-writer-round-trips-typed-inactive-dates
  (let* ((day
           (make-temporal-value :kind :date :local-value "2026-07-28"))
         (range
           (make-recurrence-period
            :start
            (make-temporal-value
             :kind :floating :local-value "2026-07-29T09:00:00"
             :precision :minute)
            :end
            (make-temporal-value
             :kind :floating :local-value "2026-07-29T10:30:00"
             :precision :minute)))
         (node
           (make-semantic-node
            :id "node:inactive" :level 1 :title "Inactive dates"
            :inactive-dates (list day range)))
         (document
           (make-semantic-document
            :id "document:inactive" :source-uri "inactive.org" :format :org
            :profile "org/test" :nodes (list node)
            :root-ids '("node:inactive") :source-revision "rev-1"))
         (source (render-lsm-document document))
         (parsed
           (source-snapshot-document
            (parse-source (make-instance 'lsm-provider) source
                          :source-id "inactive.md" :revision "rev-2"))))
    (assert-true (search "inactive-dates:" source)
                 "canonical LSM omitted inactive-dates")
    (assert-true
     (lem-structured-notes::equivalent-list-p
      (semantic-node-inactive-dates node)
      (semantic-node-inactive-dates
       (find-semantic-node parsed "node:inactive"))
      #'lem-structured-notes::recurrence-date-equivalent-p)
     (format nil "parsed inactive-dates changed typed values:~%~s~%~s~%~a"
             (semantic-node-inactive-dates node)
             (semantic-node-inactive-dates
              (find-semantic-node parsed "node:inactive"))
             source))
    (assert-true (semantic-document-equivalent-p document parsed)
                 "parsed inactive-dates changed semantic equivalence")
    (assert-equal
     2
     (length
      (semantic-node-inactive-dates
       (find-semantic-node parsed "node:inactive"))))))

(define-foundation-test canonical-lsm-writer-round-trips-node-aliases
  (let* ((node
           (make-semantic-node
            :id "node:aliases" :level 1 :title "Canonical title"
            :aliases '("Two words" "Short")))
         (document
           (make-semantic-document
            :id "document:aliases" :source-uri "aliases.org" :format :org
            :profile "org/test" :nodes (list node)
            :root-ids '("node:aliases") :source-revision "rev-1"))
         (source (render-lsm-document document))
         (parsed
           (source-snapshot-document
            (parse-source (make-instance 'lsm-provider) source
                          :source-id "aliases.md" :revision "rev-2")))
         (parsed-node (find-semantic-node parsed "node:aliases")))
    (assert-true
     (search "aliases: [\"Two words\", \"Short\"]" source)
     "canonical LSM omitted typed aliases")
    (assert-equal '("Two words" "Short")
                  (semantic-node-aliases parsed-node))
    (assert-true (semantic-document-equivalent-p document parsed))))

(define-foundation-test canonical-lsm-writer-round-trips-node-references
  (let* ((references
           (list
            (make-node-reference :kind :citation :value "source-key")
            (make-node-reference
             :kind :url :value "https://example.test/source")))
         (node
           (make-semantic-node
            :id "node:references" :level 1 :title "References"
            :references references))
         (document
           (make-semantic-document
            :id "document:references" :source-uri "references.org"
            :format :org :profile "org/test" :nodes (list node)
            :root-ids '("node:references") :source-revision "rev-1"))
         (source (render-lsm-document document))
         (parsed
           (source-snapshot-document
            (parse-source (make-instance 'lsm-provider) source
                          :source-id "references.md" :revision "rev-2")))
         (parsed-node (find-semantic-node parsed "node:references")))
    (assert-true (search "citation-refs: [\"source-key\"]" source))
    (assert-true
     (search "url-refs: [\"https://example.test/source\"]" source))
    (assert-equal references (semantic-node-references parsed-node)
                  :test #'equalp)
    (assert-true (semantic-document-equivalent-p document parsed))))

(define-foundation-test ordinary-markdown-date-link-is-not-an-inactive-date
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: links~%---~%~%# Link~%~%:::{lem-node}~%id: \"node:link\"~%:::~%~%[2026-07-28](https://example.test/)~%"))
         (document
           (source-snapshot-document
            (parse-source (make-instance 'lsm-provider) source
                          :source-id "links.md" :revision "rev-1"))))
    (assert-false
     (semantic-node-inactive-dates
      (find-semantic-node document "node:link")))))

(define-foundation-test canonical-lsm-preserves-safe-opaque-frontmatter-and-source
  (let* ((frontmatter
           (format nil
                   "id: legacy-node~%title: Legacy title~%custom:~%  nested: true~%"))
         (body (format nil "# Legacy-looking body~%~%{{ unknown syntax }}~%"))
         (content
           (make-content-node :kind :opaque :source-format :commonmark
                              :raw body))
         (extension
           (make-opaque-extension
            :namespace "urn:lem:lsm:frontmatter:yaml"
            :media-type "application/yaml"
            :raw-value frontmatter :ordering-anchor :frontmatter
            :provenance :local))
         (node
           (make-semantic-node :id "legacy-node" :level 1
                               :title "Legacy title" :body (list content)))
         (document
           (make-semantic-document
            :id "legacy-node" :source-uri "legacy.md" :format :markdown
            :profile "legacy-roam/1" :nodes (list node)
            :root-ids '("legacy-node") :source-revision "rev-1"
            :extensions (list extension)))
         (source (render-lsm-document document))
         (parsed
           (source-snapshot-document
            (parse-source (make-instance 'lsm-provider) source
                          :source-id "canonical.md" :revision "rev-2"))))
    (assert-true (search frontmatter source)
                 "canonical LSM dropped preserved YAML frontmatter")
    (assert-true (search ":::{lem-source-opaque}" source))
    (assert-true (search "format: commonmark" source))
    (assert-true (semantic-document-equivalent-p document parsed))
    (let ((raw
            (opaque-extension-raw-value
             (first (semantic-document-extensions parsed)))))
      (assert-equal frontmatter raw :test #'string=)))
  (dolist (frontmatter
           ((lambda (newline)
              (list
               (format nil "api_token: exposed~a" newline)
               (format nil "custom: {safe: true, api_token: exposed}~a"
                       newline)
               (format nil "lem:~a  profile: hostile~a" newline newline)
               (format nil "\"lem\" : hostile~a" newline)
               (format nil "---~a" newline)))
            (string #\Newline)))
    (let* ((extension
             (make-opaque-extension
              :namespace "urn:lem:lsm:frontmatter:yaml"
              :media-type "application/yaml"
              :raw-value frontmatter :ordering-anchor :frontmatter
              :provenance :local))
           (node (make-semantic-node :id "unsafe" :level 1 :title "Unsafe"))
           (document
             (make-semantic-document
              :id "unsafe" :source-uri "unsafe.md" :format :markdown
              :profile "legacy-roam/1" :nodes (list node)
              :root-ids '("unsafe") :source-revision "rev-1"
              :extensions (list extension))))
      (assert-signals 'semantic-model-error
                      (lambda () (render-lsm-document document))))))
