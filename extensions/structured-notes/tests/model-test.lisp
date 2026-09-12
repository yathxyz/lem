(in-package #:lem-structured-notes/tests)

(defun fixture-date (&optional (value "2026-07-23"))
  (make-temporal-value :kind :date :local-value value))

(defun fixture-task ()
  (make-task-facet
   :workflow-id "org/default"
   :state "TODO"
   :done-p nil
   :priority "A"
   :progress 25
   :scheduled (fixture-date)
   :recurrence
   (make-recurrence :policy :completion-relative
                    :original-lexeme ".+1w")))

(defun fixture-document (&key (revision "rev-1"))
  (let* ((child
           (make-semantic-node
            :id "node:child"
            :level 2
            :title "Implement model"
            :parent-id "node:root"
            :task (fixture-task)
            :span (make-source-span :source-id "fixture.org"
                                    :character-start 10
                                    :character-end 42
                                    :byte-start 10
                                    :byte-end 42)))
         (root
           (make-semantic-node
            :id "node:root"
            :level 1
            :title "Project"
            :child-ids '("node:child")
            :span (make-source-span :source-id "fixture.org"
                                    :character-start 0
                                    :character-end 9
                                    :byte-start 0
                                    :byte-end 9))))
    (make-semantic-document
     :id "document:fixture"
     :source-uri "file:///fixture.org"
     :format :org
     :profile "org/fixture-1"
     :nodes (list root child)
     :root-ids '("node:root")
     :source-revision revision)))

(define-foundation-test temporal-kinds-remain-distinct
  (let ((date (fixture-date))
        (floating
          (make-temporal-value :kind :floating
                               :local-value "2026-07-23T09:00:00"))
        (utc
          (make-temporal-value :kind :utc
                               :local-value "2026-07-23T08:00:00Z"))
        (zoned
          (make-temporal-value :kind :zoned
                               :local-value "2026-07-23T09:00:00"
                               :timezone-id "Europe/Dublin"
                               :fold 0
                               :gap-policy :reject)))
    (assert-equal :date (temporal-value-kind date))
    (assert-equal :floating (temporal-value-kind floating))
    (assert-equal :utc (temporal-value-kind utc))
    (assert-equal :zoned (temporal-value-kind zoned))
    (assert-equal "Europe/Dublin" (temporal-value-timezone-id zoned)
                  :test #'string=)))

(define-foundation-test temporal-kind-invariants-fail-closed
  (assert-signals
   'semantic-model-error
   (lambda ()
     (make-temporal-value :kind :floating
                          :local-value "2026-07-23T09:00:00"
                          :timezone-id "Europe/Dublin")))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (make-temporal-value :kind :zoned
                          :local-value "2026-07-23T09:00:00")))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (make-temporal-value :kind :date
                          :local-value "2026-07-23"
                          :precision :second))))

(define-foundation-test recurrence-period-retains-one-finish-form
  (let* ((start
           (make-temporal-value
            :kind :zoned :local-value "2026-07-23T09:00:00"
            :timezone-id "Europe/Dublin" :gap-policy :reject))
         (end
           (make-temporal-value
            :kind :zoned :local-value "2026-07-23T10:00:00"
            :timezone-id "Europe/Dublin" :gap-policy :reject))
         (explicit (make-recurrence-period :start start :end end))
         (nominal
           (make-recurrence-period :start start :duration "P1DT2H")))
    (assert-equal start (recurrence-period-start explicit))
    (assert-equal end (recurrence-period-end explicit))
    (assert-false (recurrence-period-duration explicit))
    (assert-equal "P1DT2H" (recurrence-period-duration nominal)
                  :test #'string=)
    (assert-true
     (first (recurrence-dates
             (make-recurrence :dates (list explicit nominal)))))))

(define-foundation-test semantic-node-aliases-are-bounded-by-model-shape
  (let ((node
          (make-semantic-node
           :id "node:aliases" :level 1 :title "Aliases"
           :aliases '("Long name" "Short"))))
    (assert-equal '("Long name" "Short")
                  (semantic-node-aliases node)))
  (dolist (aliases '(("") ("valid" 7)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (make-semantic-node
        :id "node:invalid-alias" :level 1 :title "Aliases"
        :aliases aliases)))))

(define-foundation-test semantic-node-references-retain-kind-and-value
  (let* ((citation
           (make-node-reference :kind :citation :value "source-key"))
         (url
           (make-node-reference
            :kind :url :value "https://example.test/source"))
         (node
           (make-semantic-node
            :id "node:references" :level 1 :title "References"
            :references (list citation url))))
    (assert-equal :citation (node-reference-kind citation))
    (assert-equal "https://example.test/source"
                  (node-reference-value url) :test #'string=)
    (assert-equal (list citation url) (semantic-node-references node)))
  (dolist (arguments
           '((:kind :unknown :value "key")
             (:kind :citation :value "bad key")
             (:kind :url :value "ftp://example.test/source")
             (:kind :url :value "https://example.test/bad path")))
    (assert-signals
     'semantic-model-error
     (lambda () (apply #'make-node-reference arguments)))))

(define-foundation-test invalid-recurrence-period-fails-closed
  (let ((start
          (make-temporal-value
           :kind :utc :local-value "2026-07-23T09:00:00Z"))
        (end
          (make-temporal-value
           :kind :utc :local-value "2026-07-23T10:00:00Z")))
    (dolist
        (thunk
         (list
          (lambda () (make-recurrence-period :start (fixture-date)
                                              :duration "PT1H"))
          (lambda () (make-recurrence-period :start start))
          (lambda () (make-recurrence-period :start start :end end
                                              :duration "PT1H"))
          (lambda () (make-recurrence-period :start end :end start))
          (lambda () (make-recurrence-period :start start
                                              :duration "-PT1H"))))
      (assert-signals 'semantic-model-error thunk))
    (dolist (duration '("Pgarbage" "P1Y" "PT1H20S" "PT0S"))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (make-recurrence-period :start start :duration duration))))))

(define-foundation-test source-spans-are-half-open-and-bounded
  (let ((span (make-source-span :source-id "note.md"
                                :character-start 4
                                :character-end 9
                                :byte-start 4
                                :byte-end 12)))
    (assert-equal 4 (source-span-character-start span))
    (assert-equal 9 (source-span-character-end span))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (make-source-span :source-id "note.md"
                         :character-start 9
                         :character-end 4)))))

(define-foundation-test valid-hierarchy-and-task-lookup
  (let ((document (fixture-document)))
    (assert-equal 2 (length (semantic-document-nodes document)))
    (let ((task-node (find-semantic-node document "node:child")))
      (assert-true task-node)
      (assert-equal "TODO"
                    (task-facet-state (semantic-node-task task-node))
                    :test #'string=))))

(define-foundation-test duplicate-node-identities-are-rejected
  (let ((first (make-semantic-node :id "duplicate" :level 1 :title "A"))
        (second (make-semantic-node :id "duplicate" :level 1 :title "B")))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (make-semantic-document
        :id "document:duplicate"
        :source-uri "file:///duplicate.md"
        :format :lsm
        :profile "lsm/1"
        :nodes (list first second)
        :root-ids '("duplicate")
        :source-revision "rev-1")))))

(define-foundation-test broken-hierarchy-is-rejected
  (let ((orphan
          (make-semantic-node :id "orphan" :level 2 :title "Orphan"
                              :parent-id "missing")))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (make-semantic-document
        :id "document:orphan"
        :source-uri "file:///orphan.org"
        :format :org
        :profile "org/fixture-1"
        :nodes (list orphan)
        :root-ids nil
        :source-revision "rev-1")))))

(define-foundation-test calendar-binding-identity-is-separate
  (let* ((binding
           (make-calendar-binding
            :id "binding:1"
            :node-id "node:1"
            :projection-kind :event
            :account-id "personal"
            :calendar-id "work"
            :uid "calendar-uid-1"
            :ownership :organizer
            :write-policy :bidirectional))
         (node
           (make-semantic-node :id "node:1" :level 1 :title "Meeting"
                               :calendar-bindings (list binding)))
         (document
           (make-semantic-document
            :id "document:binding"
            :source-uri "file:///binding.md"
            :format :lsm
            :profile "lsm/1"
            :nodes (list node)
            :root-ids '("node:1")
            :source-revision "rev-1")))
    (declare (ignore document))
    (assert-false (string= (semantic-node-id node)
                           (calendar-binding-uid binding)))
    (assert-equal "node:1" (calendar-binding-node-id binding)
                  :test #'string=)))

(define-foundation-test event-facet-keeps-calendar-semantics-format-neutral
  (let* ((start
           (make-temporal-value :kind :utc
                                :local-value "2026-08-01T09:00:00Z"))
         (finish
           (make-temporal-value :kind :utc
                                :local-value "2026-08-01T10:00:00Z"))
         (recurrence
           (make-recurrence :rules '("FREQ=WEEKLY;BYDAY=MO")
                            :policy :fixed))
         (event
           (make-event-facet
            :start start :end finish :status "CONFIRMED"
            :location "Room 4" :url "https://example.test/events/1"
            :transparency :opaque :recurrence recurrence)))
    (assert-equal :utc (temporal-value-kind (event-facet-start event)))
    (assert-equal "Room 4" (event-facet-location event) :test #'string=)
    (assert-equal '("FREQ=WEEKLY;BYDAY=MO")
                  (recurrence-rules (event-facet-recurrence event)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (make-event-facet :end finish :duration "PT1H")))))

(define-foundation-test opaque-extensions-preserve-raw-values
  (let* ((octets #(88 45 70 79 79 58 98 97 114))
         (extension
           (make-opaque-extension
            :namespace "urn:example:calendar"
            :media-type "text/calendar"
            :owner-id "node:1"
            :raw-value octets
            :ordering-anchor '(:after "SUMMARY")
            :provenance :remote)))
    (assert-true
     (eq octets (opaque-extension-raw-value extension))
     "opaque bytes must remain available without reinterpretation")))

(define-foundation-test constructor-copies-identity-lists
  (let* ((children (list "node:child"))
         (root (make-semantic-node :id "node:root" :level 1 :title "Root"
                                   :child-ids children)))
    (setf (car children) "corrupted")
    (assert-equal '("node:child") (semantic-node-child-ids root))))

(define-foundation-test paragraph-inlines-are-kind-specific
  (let* ((inline
           (make-inline-node :kind :text :source-format :org
                             :raw "Plain prose." :text "Plain prose."))
         (paragraph
           (make-content-node :kind :paragraph :source-format :org
                              :raw (format nil "Plain prose.~%")
                              :inlines (list inline))))
    (assert-equal "Plain prose."
                  (inline-node-text (first (content-node-inlines paragraph)))
                  :test #'string=)
    (assert-true (content-node-native-commonmark-paragraph-p paragraph)))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (make-content-node :kind :list :source-format :org
                        :raw (format nil "- item~%")
                        :inlines
                        (list (make-inline-node
                               :kind :text :source-format :org
                               :raw "item" :text "item"))))))

(define-foundation-test comment-text-is-source-neutral
  (let ((comment
          (make-content-node :kind :comment :source-format :org
                             :raw (format nil "# Hidden note.~%")
                             :text "Hidden note.")))
    (assert-true (content-node-native-myst-comment-p comment))
    (assert-equal "Hidden note." (content-node-text comment)
                  :test #'string=)))
