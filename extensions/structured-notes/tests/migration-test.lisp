(in-package #:lem-structured-notes/tests)

(define-foundation-test lsm-migration-plan-proves-supported-semantics
  (let* ((provider (make-instance 'fixture-provider))
         (snapshot (fixture-snapshot provider))
         (plan (plan-lsm-migration snapshot "fixture.md"))
         (report (migration-plan-report plan)))
    (assert-true
     (semantic-document-equivalent-p
      (source-snapshot-document snapshot)
      (source-snapshot-document (migration-plan-preview-snapshot plan))))
    (assert-equal :ready (migration-report-status report))
    (assert-equal :write-new-file (migration-report-disposition report))
    (assert-equal 2 (migration-report-node-count report))
    (assert-equal 1 (migration-report-task-count report))
    (assert-equal 0 (migration-report-opaque-content-count report))
    (assert-equal 0 (cdr (assoc :loss
                                (migration-report-loss-risk-counts report))))
    (assert-true (search "lem-task" (migration-plan-target-source plan)))))

(define-foundation-test lsm-migration-plan-reports-opaque-org-content
  (let* ((provider (make-instance 'fixture-provider))
         (content (make-content-node :kind :paragraph :source-format :org
                                     :raw (format nil "Exact Org.~%")))
         (node (make-semantic-node :id "node:opaque" :level 1
                                   :title "Opaque" :body (list content)))
         (document
           (make-semantic-document
            :id "document:opaque" :source-uri "fixture.org" :format :org
            :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:opaque") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document document :content-fingerprint "fixture-content:opaque"
            :metadata-fingerprint "fixture-metadata:1"))
         (report
           (migration-plan-report
            (plan-lsm-migration snapshot "fixture-opaque.md"))))
    (assert-equal :ready-with-opaque-content
                  (migration-report-status report))
    (assert-equal 1 (migration-report-opaque-content-count report))))

(define-foundation-test lsm-migration-plan-reports-native-paragraph-separately
  (let* ((provider (make-instance 'fixture-provider))
         (content
           (multiple-value-bind (inlines valid-p)
               (parse-org-paragraph-inlines
                (format nil "Plain prose only.~%") :source-id "fixture.org")
             (assert-true valid-p)
             (make-content-node :kind :paragraph :source-format :org
                                :raw (format nil "Plain prose only.~%")
                                :inlines inlines)))
         (node (make-semantic-node :id "node:native" :level 1
                                   :title "Native" :body (list content)))
         (document
           (make-semantic-document
            :id "document:native" :source-uri "fixture.org" :format :org
            :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:native") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document document :content-fingerprint "fixture-content:native"
            :metadata-fingerprint "fixture-metadata:1"))
         (plan (plan-lsm-migration snapshot "fixture-native.md"))
         (report (migration-plan-report plan)))
    (assert-equal :ready (migration-report-status report))
    (assert-equal 0 (migration-report-opaque-content-count report))
    (assert-false (search "lem-org-opaque"
                          (migration-plan-target-source plan)))))

(define-foundation-test lsm-migration-plan-reports-native-comment-separately
  (let* ((provider (make-instance 'fixture-provider))
         (content
           (make-content-node :kind :comment :source-format :org
                              :raw (format nil "# Hidden note.~%")
                              :text "Hidden note."))
         (node (make-semantic-node :id "node:comment" :level 1
                                   :title "Comment" :body (list content)))
         (document
           (make-semantic-document
            :id "document:comment" :source-uri "fixture.org" :format :org
            :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:comment") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document document :content-fingerprint "fixture-content:comment"
            :metadata-fingerprint "fixture-metadata:1"))
         (plan (plan-lsm-migration snapshot "fixture-comment.md"))
         (report (migration-plan-report plan)))
    (assert-equal :ready (migration-report-status report))
    (assert-equal 0 (migration-report-opaque-content-count report))
    (assert-true (search (format nil "% Hidden note.~%")
                         (migration-plan-target-source plan)))))

(define-foundation-test lsm-migration-plan-reports-native-list-separately
  (let* ((provider (make-instance 'fixture-provider))
         (raw (format nil "- [ ] one~%- [X] two~%"))
         (content
           (multiple-value-bind (items valid-p)
               (parse-org-list-items raw :source-id "fixture.org")
             (assert-true valid-p)
             (make-content-node :kind :list :source-format :org
                                :raw raw :items items)))
         (node (make-semantic-node :id "node:list" :level 1
                                   :title "List" :body (list content)))
         (document
           (make-semantic-document
            :id "document:list" :source-uri "fixture.org" :format :org
            :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:list") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document document :content-fingerprint "fixture-content:list"
            :metadata-fingerprint "fixture-metadata:1"))
         (plan (plan-lsm-migration snapshot "fixture-list.md"))
         (report (migration-plan-report plan)))
    (assert-equal :ready (migration-report-status report))
    (assert-equal 0 (migration-report-opaque-content-count report))
    (assert-true (search (format nil "- [ ] one~%- [x] two~%")
                         (migration-plan-target-source plan)))))

(define-foundation-test lsm-migration-plan-reports-native-table-separately
  (let* ((provider (make-instance 'fixture-provider))
         (content
           (multiple-value-bind (table valid-p)
               (parse-org-table-data *org-table-fixture*
                                     :source-id "fixture.org")
             (assert-true valid-p)
             (make-content-node :kind :table :source-format :org
                                :raw *org-table-fixture* :table table)))
         (node (make-semantic-node :id "node:table" :level 1
                                   :title "Table" :body (list content)))
         (document
           (make-semantic-document
            :id "document:table" :source-uri "fixture.org" :format :org
            :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:table") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document document :content-fingerprint "fixture-content:table"
            :metadata-fingerprint "fixture-metadata:1"))
         (plan (plan-lsm-migration snapshot "fixture-table.md"))
         (report (migration-plan-report plan)))
    (assert-equal :ready (migration-report-status report))
    (assert-equal 0 (migration-report-opaque-content-count report))
    (assert-true (search "| --- | --- |"
                         (migration-plan-target-source plan)))))

(define-foundation-test lsm-migration-plan-reports-native-code-separately
  (let* ((provider (make-instance 'fixture-provider))
         (content
           (multiple-value-bind (code-block valid-p)
               (parse-org-source-block-data *org-code-fixture*
                                            :source-id "fixture.org")
             (assert-true valid-p)
             (make-content-node :kind :source-block :source-format :org
                                :raw *org-code-fixture*
                                :code-block code-block)))
         (node (make-semantic-node :id "node:code" :level 1
                                   :title "Code" :body (list content)))
         (document
           (make-semantic-document
            :id "document:code" :source-uri "fixture.org" :format :org
            :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:code") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document document :content-fingerprint "fixture-content:code"
            :metadata-fingerprint "fixture-metadata:1"))
         (plan (plan-lsm-migration snapshot "fixture-code.md"))
         (report (migration-plan-report plan)))
    (assert-equal :ready (migration-report-status report))
    (assert-equal 0 (migration-report-opaque-content-count report))
    (assert-true
     (search (format nil "````common-lisp~%(format t \"hello\")~%")
             (migration-plan-target-source plan)))))

(define-foundation-test lsm-migration-plan-reports-native-quote-separately
  (let* ((provider (make-instance 'fixture-provider))
         (content
           (multiple-value-bind (inlines valid-p)
               (parse-org-quote-inlines *org-quote-fixture*
                                        :source-id "fixture.org")
             (assert-true valid-p)
             (make-content-node :kind :quote :source-format :org
                                :raw *org-quote-fixture* :inlines inlines)))
         (node (make-semantic-node :id "node:quote" :level 1
                                   :title "Quote" :body (list content)))
         (document
           (make-semantic-document
            :id "document:quote" :source-uri "fixture.org" :format :org
            :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:quote") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document document :content-fingerprint "fixture-content:quote"
            :metadata-fingerprint "fixture-metadata:1"))
         (plan (plan-lsm-migration snapshot "fixture-quote.md"))
         (report (migration-plan-report plan)))
    (assert-equal :ready (migration-report-status report))
    (assert-equal 0 (migration-report-opaque-content-count report))
    (assert-true
     (search "> Quoted **strong** and [linked](id:target)."
             (migration-plan-target-source plan)))))

(define-foundation-test lsm-migration-plan-reports-native-drawer-separately
  (let* ((provider (make-instance 'fixture-provider))
         (content
           (multiple-value-bind (name inlines valid-p)
               (parse-org-drawer-inlines *org-drawer-fixture*
                                         :source-id "fixture.org")
             (assert-true valid-p)
             (make-content-node :kind :drawer :source-format :org
                                :raw *org-drawer-fixture*
                                :name name :inlines inlines)))
         (node (make-semantic-node :id "node:drawer" :level 1
                                   :title "Drawer" :body (list content)))
         (document
           (make-semantic-document
            :id "document:drawer" :source-uri "fixture.org" :format :org
            :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:drawer") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document document :content-fingerprint "fixture-content:drawer"
            :metadata-fingerprint "fixture-metadata:1"))
         (plan (plan-lsm-migration snapshot "fixture-drawer.md"))
         (report (migration-plan-report plan)))
    (assert-equal :ready (migration-report-status report))
    (assert-equal 0 (migration-report-opaque-content-count report))
    (assert-true (search ":::{lem-drawer}"
                         (migration-plan-target-source plan)))))

(define-foundation-test lsm-migration-proves-mixed-supported-content-tree
  (let* ((provider (make-instance 'fixture-provider))
         (raw
           (format nil
                   "Plain *strong* and [[id:target][linked]].~%~%- [ ] First item.~%~%| Name | Value |~%|------+-------|~%| Alpha | *strong* |~%~%#+begin_src lisp~%(+ 1 2)~%#+end_src~%~%#+begin_quote~%Quoted *strong*.~%#+end_quote~%~%:NOTES:~%Remember *strong*.~%:END:~%~%# Hidden note.~%~%:LOGBOOK:~%CLOCK: exact fallback~%:END:~%"))
         (syntax (parse-org-cst raw :source-id "mixed.org"))
         (body (org-cst-content-nodes-in-range syntax 0 (length raw)))
         (node (make-semantic-node :id "node:mixed" :level 1
                                   :title "Mixed" :body body))
         (document
           (make-semantic-document
            :id "document:mixed" :source-uri "mixed.org" :format :org
            :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:mixed") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "mixed.org" :revision "rev-1"
            :document document :syntax-tree syntax
            :content-fingerprint raw :metadata-fingerprint "metadata:mixed"))
         (plan (plan-lsm-migration snapshot "mixed.md"))
         (target (migration-plan-target-source plan))
         (report (migration-plan-report plan)))
    (assert-true
     (semantic-document-equivalent-p
      document
      (source-snapshot-document (migration-plan-preview-snapshot plan))))
    (assert-equal :ready-with-opaque-content
                  (migration-report-status report))
    (assert-true (plusp (migration-report-opaque-content-count report)))
    (dolist (fragment
             '("Plain **strong** and [linked](id:target)."
               "- [ ] First item."
               "| Name | Value |"
               "```lisp"
               "> Quoted **strong**."
               ":::{lem-drawer}"
               "% Hidden note."
               "name: \"LOGBOOK\""))
      (assert-true (search fragment target)
                   (format nil "missing mixed migration fragment ~s"
                           fragment)))))

(define-foundation-test integer-priority-round-trips-through-migration
  (let* ((provider (make-instance 'fixture-provider))
         (task (make-task-facet :workflow-id "org/default" :state "TODO"
                                :priority 3))
         (node (make-semantic-node :id "node:typed-priority" :level 1
                                   :title "Typed priority" :task task))
         (document
           (make-semantic-document
            :id "document:typed-priority" :source-uri "fixture.org"
            :format :org :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:typed-priority") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document document :content-fingerprint "fixture-content:typed"
            :metadata-fingerprint "fixture-metadata:1")))
    (let* ((plan (plan-lsm-migration snapshot "typed-priority.md"))
           (preview
             (source-snapshot-document
              (migration-plan-preview-snapshot plan)))
           (preview-task
             (semantic-node-task
              (find-semantic-node preview "node:typed-priority"))))
      (assert-equal 3 (task-facet-priority preview-task)))))

(define-foundation-test recurrence-period-round-trips-through-migration
  (let* ((provider (make-instance 'fixture-provider))
         (period
           (make-recurrence-period
            :start
            (make-temporal-value
             :kind :zoned :local-value "2026-08-06T09:00:00"
             :timezone-id "Europe/Dublin" :gap-policy :reject)
            :duration "P1D"))
         (event
           (make-event-facet
            :start (make-temporal-value
                    :kind :utc :local-value "2026-08-01T09:00:00Z")
            :recurrence (make-recurrence :dates (list period)
                                         :policy :fixed)))
         (node
           (make-semantic-node :id "node:period" :level 1
                               :title "Period" :event event))
         (document
           (make-semantic-document
            :id "document:period" :source-uri "fixture.org"
            :format :org :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:period") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document document :content-fingerprint "fixture-content:period"
            :metadata-fingerprint "fixture-metadata:1"))
         (plan (plan-lsm-migration snapshot "period.md"))
         (preview
           (source-snapshot-document
            (migration-plan-preview-snapshot plan)))
         (preview-period
           (first
            (recurrence-dates
             (event-facet-recurrence
              (semantic-node-event
               (find-semantic-node preview "node:period")))))))
    (assert-true (recurrence-period-p preview-period))
    (assert-equal "Europe/Dublin"
                  (temporal-value-timezone-id
                   (recurrence-period-start preview-period))
                  :test #'string=)
    (assert-equal "P1D" (recurrence-period-duration preview-period)
                  :test #'string=)))

(define-foundation-test semantic-mismatch-refuses-migration-plan
  (let* ((provider (make-instance 'fixture-provider))
         (scheduled
           (make-temporal-value
            :kind :zoned :local-value "2026-10-25T01:30:00"
            :timezone-id "Europe/Dublin" :fold 1 :gap-policy :later))
         (task
           (make-task-facet :workflow-id "org/default" :state "TODO"
                            :scheduled scheduled))
         (node
           (make-semantic-node :id "node:fold" :level 1
                               :title "Ambiguous local time" :task task))
         (document
           (make-semantic-document
            :id "document:fold" :source-uri "fixture.org"
            :format :org :profile "org/fixture-1" :nodes (list node)
            :root-ids '("node:fold") :source-revision "rev-1"))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document document :content-fingerprint "fixture-content:fold"
            :metadata-fingerprint "fixture-metadata:1")))
    (assert-signals
     'migration-equivalence-error
     (lambda () (plan-lsm-migration snapshot "fold.md")))))

(define-foundation-test stale-source-refuses-migration-application
  (let* ((provider (make-instance 'fixture-provider))
         (base (fixture-snapshot provider))
         (plan (plan-lsm-migration base "fixture.md")))
    (dolist (current
             (list
              (fixture-snapshot provider :revision "rev-2")
              (fixture-snapshot provider
                                :fingerprint "fixture-content:changed")
              (fixture-snapshot
               provider :metadata-fingerprint "fixture-metadata:changed")))
      (assert-signals
       'stale-source
       (lambda ()
         (apply-migration-plan-to-stream plan current
                                         (make-string-output-stream)))))))

(define-foundation-test risky-migration-diagnostics-require-review
  (let* ((provider (make-instance 'fixture-provider))
         (diagnostic
           (make-diagnostic
            :severity :warning :code :ambiguous-source
            :message "Source interpretation needs a decision."
            :loss-risk :approximation))
         (snapshot
           (make-source-snapshot
            :provider provider :source-id "fixture.org" :revision "rev-1"
            :document (fixture-document)
            :content-fingerprint "fixture-content:1"
            :metadata-fingerprint "fixture-metadata:1"
            :diagnostics (list diagnostic)))
         (plan (plan-lsm-migration snapshot "fixture.md"))
         (report (migration-plan-report plan)))
    (assert-equal :review-required (migration-report-status report))
    (assert-equal 1 (cdr (assoc :approximation
                                (migration-report-loss-risk-counts report))))
    (assert-signals
     'migration-error
     (lambda ()
       (apply-migration-plan-to-stream plan snapshot
                                       (make-string-output-stream))))))

(define-foundation-test migration-application-writes-exact-new-file-once
  (with-test-sync-store (directory)
    (ensure-directories-exist (merge-pathnames "placeholder" directory))
    (let* ((provider (make-instance 'fixture-provider))
           (snapshot (fixture-snapshot provider))
           (target (merge-pathnames "migration.md" directory))
           (plan
             (plan-lsm-migration snapshot (uiop:native-namestring target))))
      (assert-false (probe-file target))
      (write-migration-plan-file plan snapshot)
      (assert-true (probe-file target))
      (assert-equal
       (migration-plan-target-source plan)
       (with-open-file (stream target :direction :input
                                      :external-format :utf-8)
         (let ((content (make-string (file-length stream))))
           (read-sequence content stream)
           content))
       :test #'string=)
      (let ((before
              (with-open-file (stream target :direction :input
                                             :external-format :utf-8)
                (let ((content (make-string (file-length stream))))
                  (read-sequence content stream)
                  content))))
        (assert-signals
         'migration-target-exists
         (lambda () (write-migration-plan-file plan snapshot)))
        (assert-equal
         before
         (with-open-file (stream target :direction :input
                                        :external-format :utf-8)
           (let ((content (make-string (file-length stream))))
             (read-sequence content stream)
             content))
         :test #'string=)))))

(defun test-read-migration-file (pathname)
  (with-open-file (stream pathname :direction :input :external-format :utf-8)
    (let ((content (make-string (file-length stream))))
      (read-sequence content stream)
      content)))

(defun test-write-migration-file (pathname content)
  (with-open-file (stream pathname :direction :output
                                  :if-exists :error
                                  :if-does-not-exist :create
                                  :external-format :utf-8)
    (write-string content stream)
    (finish-output stream)))

(define-foundation-test migration-file-application-recovers-every-publish-cut
  (with-test-sync-store (directory)
    (ensure-directories-exist (merge-pathnames "placeholder" directory))
    (let* ((provider (make-instance 'fixture-provider))
           (snapshot (fixture-snapshot provider)))
      (dolist (case '((:temporary-fsynced nil)
                      (:target-published t)
                      (:directory-fsynced t)))
        (let* ((boundary (first case))
               (published-p (second case))
               (target
                 (merge-pathnames
                  (format nil "cut-~(~a~).md" boundary) directory))
               (plan
                 (plan-lsm-migration
                  snapshot (uiop:native-namestring target))))
          (let ((lem-structured-notes::*migration-file-boundary-hook*
                  (lambda (observed ignored-target)
                    (declare (ignore ignored-target))
                    (when (eq observed boundary)
                      (error "injected migration persistence cut")))))
            (assert-signals
             'error
             (lambda () (resume-migration-plan-file plan snapshot))))
          (assert-equal published-p (not (null (probe-file target))))
          (when published-p
            (assert-equal (migration-plan-target-source plan)
                          (test-read-migration-file target)
                          :test #'string=))
          (multiple-value-bind (report disposition)
              (resume-migration-plan-file plan snapshot)
            (assert-true (migration-report-p report))
            (assert-equal (if published-p :already-complete :created)
                          disposition))
          (multiple-value-bind (report disposition)
              (resume-migration-plan-file plan snapshot)
            (assert-true (migration-report-p report))
            (assert-equal :already-complete disposition))
          (assert-equal :removed (rollback-migration-plan-file plan))
          (assert-false (probe-file target))
          (assert-equal :absent (rollback-migration-plan-file plan))))
      (let* ((target (merge-pathnames "rollback-cut.md" directory))
             (plan
               (plan-lsm-migration snapshot (uiop:native-namestring target))))
        (resume-migration-plan-file plan snapshot)
        (let ((lem-structured-notes::*migration-file-boundary-hook*
                (lambda (observed ignored-target)
                  (declare (ignore ignored-target))
                  (when (eq observed :target-unlinked)
                    (error "injected rollback persistence cut")))))
          (assert-signals
           'error
           (lambda () (rollback-migration-plan-file plan))))
        (assert-false (probe-file target))
        (assert-equal :absent (rollback-migration-plan-file plan))))))

(define-foundation-test migration-resume-and-rollback-refuse-divergent-races
  (with-test-sync-store (directory)
    (ensure-directories-exist (merge-pathnames "placeholder" directory))
    (let* ((provider (make-instance 'fixture-provider))
           (snapshot (fixture-snapshot provider))
           (target (merge-pathnames "raced.md" directory))
           (plan
             (plan-lsm-migration snapshot (uiop:native-namestring target)))
           (foreign (format nil "user-created content must survive~%")))
      (let ((lem-structured-notes::*migration-file-boundary-hook*
              (lambda (observed ignored-target)
                (declare (ignore ignored-target))
                (when (eq observed :temporary-fsynced)
                  (test-write-migration-file target foreign)))))
        (assert-signals
         'migration-target-exists
         (lambda () (resume-migration-plan-file plan snapshot))))
      (assert-equal foreign (test-read-migration-file target) :test #'string=)
      (assert-signals
       'migration-target-exists
       (lambda () (resume-migration-plan-file plan snapshot)))
      (assert-signals
       'migration-target-exists
       (lambda () (rollback-migration-plan-file plan)))
      (assert-equal foreign (test-read-migration-file target) :test #'string=)
      (delete-file target)
      (resume-migration-plan-file plan snapshot)
      #+(and sbcl unix)
      (let ((alias (merge-pathnames "linked-copy.md" directory)))
        (sb-posix:link (uiop:native-namestring target)
                       (uiop:native-namestring alias))
        (assert-signals
         'migration-target-exists
         (lambda () (rollback-migration-plan-file plan)))
        (assert-true (probe-file target))
        (assert-true (probe-file alias))
        (delete-file alias))
      (assert-equal :removed (rollback-migration-plan-file plan)))))

(define-foundation-test migration-target-must-differ-from-source
  (let* ((provider (make-instance 'fixture-provider))
         (snapshot (fixture-snapshot provider)))
    (assert-signals
     'migration-error
     (lambda () (plan-lsm-migration snapshot "fixture.org")))))

(define-foundation-test legacy-markdown-frontmatter-migrates-losslessly-to-lsm
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%id: legacy-node~%title: Legacy title~%"
                    "tags: [#project, @deep-work]~%"
                    "ROAM_ALIASES: [\"Legacy Alias\", Bare]~%"
                    "ROAM_REFS: @legacy-cite https://example.test/legacy~%"
                    "custom:~%  nested: true~%---~%~%"
                    "A body with [a link](https://example.test/body).~%"
                    "{{ unknown syntax }}~%")))
         (provider (make-instance 'legacy-markdown-provider))
         (snapshot
           (parse-source provider source :source-id "legacy.md"
                         :revision "legacy/rev-1"))
         (document (source-snapshot-document snapshot))
         (node (find-semantic-node document "legacy-node"))
         (plan (plan-lsm-migration snapshot "canonical.md"))
         (target (migration-plan-target-source plan))
         (preview
           (source-snapshot-document (migration-plan-preview-snapshot plan))))
    (assert-equal :markdown (semantic-document-format document))
    (assert-equal '("Legacy Alias" "Bare")
                  (semantic-node-aliases node))
    (assert-equal '("project" "deep-work" "legacy-cite")
                  (semantic-node-tags node))
    (assert-equal '(:citation :url)
                  (mapcar #'node-reference-kind
                          (semantic-node-references node)))
    (assert-equal :ready-with-opaque-content
                  (migration-report-status (migration-plan-report plan)))
    (assert-true (search "custom:" target))
    (assert-true (search "  nested: true" target))
    (assert-true (search ":::{lem-source-opaque}" target))
    (assert-true (search "{{ unknown syntax }}" target))
    (assert-true (semantic-document-equivalent-p document preview))
    (let ((stream (make-string-output-stream)))
      (apply-migration-plan-to-stream plan snapshot stream)
      (assert-equal target (get-output-stream-string stream) :test #'string=)))
  (let* ((newline (format nil "~c~c" #\Return #\Newline))
         (body (format nil "Body keeps CRLF.~aSecond line.~a" newline newline))
         (source
           (format nil
                   "---~aid: crlf-node~atitle: CRLF~acustom: exact~a---~a~a"
                   newline newline newline newline newline body))
         (snapshot
           (parse-source (make-instance 'legacy-markdown-provider) source
                         :source-id "crlf.md" :revision "rev-1"))
         (plan (plan-lsm-migration snapshot "crlf-lsm.md"))
         (target (migration-plan-target-source plan))
         (preview
           (source-snapshot-document (migration-plan-preview-snapshot plan))))
    (assert-equal :crlf
                  (semantic-document-newline
                   (source-snapshot-document snapshot)))
    (assert-true (search (format nil "custom: exact~a" newline) target))
    (assert-equal :crlf (semantic-document-newline preview))
    (assert-equal
     body
     (content-node-raw
      (first (semantic-node-body (find-semantic-node preview "crlf-node"))))
     :test #'string=))
  (dolist (source
           (list
            (format nil "---~%title: Missing ID~%---~%")
            (format nil "---~%id: duplicate~%id: duplicate~%title: Bad~%---~%")
            (format nil "---~%id: secret~%title: Bad~%api_token: exposed~%---~%")
            (format nil
                    "---~%lem:~%  profile: lsm/1~%id: explicit~%title: Bad~%---~%")))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (parse-source (make-instance 'legacy-markdown-provider) source
                     :source-id "invalid.md" :revision "rev-1")))))
