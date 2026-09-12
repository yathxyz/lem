(in-package #:lem-structured-notes/tests)

(defparameter *lsm-fixture*
  (format nil
          "---~%lem:~%  profile: \"lsm/1\"~%  document-id: \"document:lsm-fixture\"~%---~%~%# Project~%~%## Write CalDAV tests~%~%:::{lem-task}~%id: \"node:caldav-tests\"~%state: TODO~%priority: A~%tags: [calendar, testing]~%scheduled: \"2026-07-27T09:00:00[Europe/Dublin]\"~%deadline: \"2026-07-31\"~%future-field: preserve-me~%:::~%~%```markdown~%# This is code, not a heading~%```~%"))

(defun parse-lsm-fixture (&optional (source *lsm-fixture*))
  (parse-source (make-instance 'lsm-provider) source
                :source-id "fixture.md"
                :revision "rev-1"))

(define-foundation-test untouched-lsm-cst-is-byte-identical
  (let* ((snapshot (parse-lsm-fixture))
         (syntax (source-snapshot-syntax-tree snapshot)))
    (assert-true (lsm-syntax-document-p syntax))
    (assert-equal *lsm-fixture* (serialize-lsm-syntax syntax)
                  :test #'string=)
    (assert-equal (length *lsm-fixture*)
                  (cst-node-character-end
                   (car (last (lsm-syntax-document-nodes syntax)))))))

(define-foundation-test lsm-parser-projects-hierarchy-and-task
  (let* ((snapshot (parse-lsm-fixture))
         (document (source-snapshot-document snapshot))
         (root (find "Project" (semantic-document-nodes document)
                     :key #'semantic-node-title :test #'string=))
         (task-node (find-semantic-node document "node:caldav-tests")))
    (assert-equal 2 (length (semantic-document-nodes document)))
    (assert-true root)
    (assert-true task-node)
    (assert-equal (semantic-node-id root)
                  (semantic-node-parent-id task-node)
                  :test #'string=)
    (assert-equal "TODO" (task-facet-state (semantic-node-task task-node))
                  :test #'string=)
    (assert-equal '("calendar" "testing") (semantic-node-tags task-node))
    (assert-equal :zoned
                  (temporal-value-kind
                   (task-facet-scheduled (semantic-node-task task-node))))
    (assert-equal "Europe/Dublin"
                  (temporal-value-timezone-id
                   (task-facet-scheduled (semantic-node-task task-node)))
                  :test #'string=)))

(define-foundation-test fenced-heading-text-does-not-create-node
  (let* ((snapshot (parse-lsm-fixture))
         (document (source-snapshot-document snapshot)))
    (assert-false
     (find "This is code, not a heading"
           (semantic-document-nodes document)
           :key #'semantic-node-title :test #'string=))))

(define-foundation-test task-directive-remains-opaque-evidence
  (let* ((snapshot (parse-lsm-fixture))
         (node (find-semantic-node (source-snapshot-document snapshot)
                                   "node:caldav-tests"))
         (extension (first (semantic-node-extensions node))))
    (assert-true extension)
    (assert-true
     (search "future-field: preserve-me"
             (opaque-extension-raw-value extension)))))

(define-foundation-test missing-or-newer-lsm-profile-is-refused
  (assert-signals
   'semantic-model-error
   (lambda ()
     (parse-lsm-fixture
      (format nil "---~%lem:~%  document-id: doc~%---~%# Title~%"))))
  (assert-signals
   'semantic-model-error
   (lambda ()
     (parse-lsm-fixture
      (format nil
              "---~%lem:~%  profile: lsm/2~%  document-id: doc~%---~%# Title~%")))))

(define-foundation-test lsm-document-parser-enforces-resource-limits
  (let ((lem-structured-notes::+lsm-source-max-characters+ 8))
    (assert-equal
     :lsm-source-limit-exceeded
     (signaled-model-code (lambda () (parse-lsm-fixture *lsm-fixture*)))))
  (let ((lem-structured-notes::+lsm-source-max-characters+ 4096)
        (lem-structured-notes::+lsm-source-max-lines+ 3))
    (assert-equal
     :lsm-line-limit-exceeded
     (signaled-model-code (lambda () (parse-lsm-fixture *lsm-fixture*)))))
  (let ((lem-structured-notes::+lsm-directive-max-depth+ 2))
    (assert-equal
     :lsm-directive-depth-limit-exceeded
     (signaled-model-code
      (lambda ()
        (parse-lsm-fixture
         (format nil
                 "---~%lem:~%  profile: lsm/1~%  document-id: deep~%---~%# Node~%:::{outer}~%:::{inner}~%:::{third}~%:::~%:::~%:::~%")))))))

(define-foundation-test unclosed-fence-is-preserved-and-diagnosed
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: doc~%---~%# Title~%```text~%unterminated~%"))
         (snapshot (parse-lsm-fixture source))
         (diagnostics (source-snapshot-diagnostics snapshot)))
    (assert-equal source
                  (serialize-lsm-syntax
                   (source-snapshot-syntax-tree snapshot))
                  :test #'string=)
    (assert-true
     (find :unclosed-fence diagnostics :key #'diagnostic-code))))

(define-foundation-test utf8-source-spans-carry-byte-offsets
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: unicode~%---~%# Éire~%"))
         (snapshot (parse-lsm-fixture source))
         (node (first (semantic-document-nodes
                       (source-snapshot-document snapshot))))
         (span (semantic-node-span node)))
    (assert-true (> (source-span-byte-end span)
                    (source-span-character-end span)))))

(define-foundation-test crlf-newlines-round-trip-exactly
  (let* ((lf (format nil
                     "---~%lem:~%  profile: lsm/1~%  document-id: crlf~%---~%# Title~%"))
         (crlf (with-output-to-string (stream)
                 (loop :for character :across lf
                       :do (if (char= character #\Newline)
                               (write-string (string #\Return) stream)
                               nil)
                           (write-char character stream))))
         (snapshot (parse-lsm-fixture crlf))
         (syntax (source-snapshot-syntax-tree snapshot)))
    (assert-equal :crlf (lsm-syntax-document-newline syntax))
    (assert-equal crlf (serialize-lsm-syntax syntax) :test #'string=)))

(define-foundation-test lsm-task-state-edit-is-planned-and-source-preserving
  (let* ((provider (make-instance 'lsm-provider))
         (snapshot (parse-source provider *lsm-fixture*
                                 :source-id "fixture.md" :revision "rev-1"))
         (operation
           (make-edit-operation :kind :set-task-state
                                :target-id "node:caldav-tests"
                                :payload "DONE"))
         (plan (plan-source-edit provider snapshot operation))
         (updated (apply-source-edit provider plan snapshot
                                     :new-revision "rev-2"))
         (updated-source
           (serialize-lsm-syntax (source-snapshot-syntax-tree updated)))
         (updated-node
           (find-semantic-node (source-snapshot-document updated)
                               "node:caldav-tests")))
    (assert-equal "TODO" (task-facet-state
                           (semantic-node-task
                            (find-semantic-node
                             (source-snapshot-document snapshot)
                             "node:caldav-tests")))
                  :test #'string=)
    (assert-equal "DONE" (task-facet-state (semantic-node-task updated-node))
                  :test #'string=)
    (assert-true (task-facet-done-p (semantic-node-task updated-node)))
    (let* ((needle "state: DONE")
           (position (search needle updated-source)))
      (assert-true position)
      (assert-equal
       *lsm-fixture*
       (concatenate 'string
                    (subseq updated-source 0 position)
                    "state: TODO"
                    (subseq updated-source (+ position (length needle))))
       :test #'string=))))

(define-foundation-test stale-lsm-task-state-plan-is-refused
  (let* ((provider (make-instance 'lsm-provider))
         (snapshot (parse-source provider *lsm-fixture*
                                 :source-id "fixture.md" :revision "rev-1"))
         (plan
           (plan-source-edit
            provider snapshot
            (make-edit-operation :kind :set-task-state
                                 :target-id "node:caldav-tests"
                                 :payload "DONE")))
         (changed-source
           (concatenate 'string *lsm-fixture* (format nil "~%<!-- changed -->")))
         (changed (parse-source provider changed-source
                                :source-id "fixture.md" :revision "rev-2")))
    (assert-signals
     'stale-source
     (lambda ()
       (apply-source-edit provider plan changed :new-revision "rev-3")))))

(define-foundation-test lsm-task-state-edit-coexists-with-node-directive
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: coexist~%---~%~%# Task~%~%:::{lem-node}~%id: \"node:task\"~%future: keep~%:::~%~%:::{lem-task}~%state: TODO~%workflow: \"org/default\"~%done: false~%:::~%"))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source
                         :source-id "coexist.md" :revision "coexist/1"))
         (plan
           (plan-source-edit
            provider snapshot
            (make-edit-operation :kind :set-task-state
                                 :target-id "node:task"
                                 :payload '(:state "DONE" :done-p t))))
         (updated
           (apply-source-edit provider plan snapshot
                              :new-revision "coexist/2"))
         (updated-source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree updated))))
    (assert-true (search "state: DONE" updated-source))
    (assert-true (search "done: true" updated-source))
    (assert-true (search "future: keep" updated-source))
    (assert-equal
     "DONE"
     (task-facet-state
      (semantic-node-task
       (find-semantic-node
        (source-snapshot-document updated) "node:task")))
     :test #'string=)))

(define-foundation-test lsm-task-state-batch-ensures-selected-headings-atomically
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: task-batch~%---~%~%"
                    "# Existing task~%~%"
                    ":::{lem-node}~%id: \"batch:existing\"~%:::~%~%"
                    ":::{lem-task}~%state: WAITING~%"
                    "workflow: \"org/default\"~%done: false~%:::~%~%"
                    "Existing body remains exact.~%~%"
                    "# Plain heading~%~%"
                    ":::{lem-node}~%id: \"batch:plain\"~%:::~%~%"
                    "Plain body remains exact.~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source
                         :source-id "task-batch.md" :revision "batch/1"))
         (plan
           (plan-lsm-task-state-batch
            snapshot '("batch:existing" "batch:plain") "TODO"
            :done-p nil))
         (updated
           (apply-source-edit provider plan snapshot
                              :new-revision "batch/2"))
         (output
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree updated))))
    (assert-equal 2 (length (edit-plan-operations plan)))
    (dolist (node-id '("batch:existing" "batch:plain"))
      (let ((task
              (semantic-node-task
               (find-semantic-node
                (source-snapshot-document updated) node-id))))
        (assert-true task)
        (assert-equal "org/default" (task-facet-workflow-id task)
                      :test #'string=)
        (assert-equal "TODO" (task-facet-state task) :test #'string=)
        (assert-false (task-facet-done-p task))))
    (assert-equal
     2
     (loop :with start = 0
           :for position = (search ":::{lem-task}" output :start2 start)
           :while position
           :count t
           :do (setf start (+ position (length ":::{lem-task}")))))
    (assert-true (search "Existing body remains exact." output))
    (assert-true (search "Plain body remains exact." output))
    (assert-equal
     1
     (loop :with start = 0
           :for position = (search "state: TODO" output :start2 start)
           :while position
           :count t
           :do (setf start (+ position (length "state: TODO")))))))

(define-foundation-test lsm-task-state-batch-refuses-unsafe-or-stale-selection
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: task-batch-errors~%---~%~%# Heading~%~%:::{lem-node}~%id: \"batch:error\"~%:::~%"))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source
                         :source-id "task-batch-errors.md"
                         :revision "batch-errors/1"))
         (plan
           (plan-lsm-task-state-batch
            snapshot '("batch:error") "TODO" :done-p nil))
         (changed
           (parse-source provider
                         (concatenate
                          'string source (format nil "~%<!-- changed -->~%"))
                         :source-id "task-batch-errors.md"
                         :revision "batch-errors/2"))
         (other-workflow
           (parse-source
            provider
            (format nil
                    (concatenate
                     'string source "~%:::{lem-task}~%state: OPEN~%"
                     "workflow: other~%done: false~%:::~%"))
            :source-id "task-batch-errors.md"
            :revision "batch-errors/other")))
    (dolist (targets
             (list nil '("missing") '("batch:error" "batch:error")))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (plan-lsm-task-state-batch snapshot targets "TODO" :done-p nil))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (plan-lsm-task-state-batch
        snapshot '("batch:error") "unsafe state" :done-p nil)))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (plan-source-edit
        provider other-workflow
        (make-edit-operation
         :kind :ensure-task-state :target-id "batch:error"
         :payload '(:state "TODO" :done-p nil)))))
    (assert-signals
     'stale-source
     (lambda ()
       (apply-source-edit provider plan changed
                          :new-revision "batch-errors/3")))))

(define-foundation-test lsm-task-planning-batch-is-atomic-and-source-preserving
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: planning-batch~%---~%~%"
                    "# First~%~%"
                    ":::{lem-node}~%id: \"planning:first\"~%:::~%~%"
                    ":::{lem-task}~%state: TODO~%"
                    "workflow: \"org/default\"~%done: false~%"
                    "scheduled: \"2026-07-28T09:30:00\"~%"
                    "deadline: 2026-08-01~%"
                    "future: keep-first~%:::~%~%"
                    "First body remains exact.~%~%"
                    "# Second~%~%"
                    ":::{lem-node}~%id: \"planning:second\"~%:::~%~%"
                    ":::{lem-task}~%state: WAITING~%"
                    "workflow: \"org/default\"~%done: false~%"
                    "scheduled: 2026-07-29~%"
                    "deadline: 2026-08-02~%"
                    "future: keep-second~%:::~%~%"
                    "Second body remains exact.~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "planning-batch.md"
                         :revision "planning-batch/1"))
         (first-temporal
           (make-temporal-value
            :kind :floating :local-value "2026-09-03T09:30:00"
            :precision :second :original-lexeme nil))
         (second-temporal
           (make-temporal-value
            :kind :date :local-value "2026-09-04"
            :precision :date :original-lexeme "2026-09-04"))
         (plan
           (plan-lsm-task-planning-batch
            snapshot :set-task-scheduled
            (list (list "planning:first" first-temporal)
                  (list "planning:second" second-temporal))))
         (updated
           (apply-source-edit provider plan snapshot
                              :new-revision "planning-batch/2"))
         (cookie-plan
           (plan-lsm-task-planning-batch
            updated :set-task-scheduled-delay
            '(("planning:first" "-2d")
              ("planning:second" "-3d"))))
         (with-cookies
           (apply-source-edit provider cookie-plan updated
                              :new-revision "planning-batch/3"))
         (output
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree with-cookies))))
    (assert-equal 2 (length (edit-plan-operations plan)))
    (assert-equal 2 (length (edit-plan-operations cookie-plan)))
    (dolist (expected
             `(("planning:first" ,first-temporal "-2d" "2026-08-01")
               ("planning:second" ,second-temporal "-3d" "2026-08-02")))
      (destructuring-bind (node-id scheduled delay deadline) expected
        (let ((task
                (semantic-node-task
                 (find-semantic-node
                  (source-snapshot-document with-cookies) node-id))))
          (assert-true task)
          (let ((actual (task-facet-scheduled task)))
            (assert-equal (temporal-value-kind scheduled)
                          (temporal-value-kind actual))
            (assert-equal (temporal-value-local-value scheduled)
                          (temporal-value-local-value actual)
                          :test #'string=)
            (assert-equal (temporal-value-precision scheduled)
                          (temporal-value-precision actual)))
          (assert-equal delay (task-facet-scheduled-delay task)
                        :test #'string=)
          (assert-equal deadline
                        (temporal-value-local-value
                         (task-facet-deadline task))
                        :test #'string=))))
    (assert-true (search "future: keep-first" output))
    (assert-true (search "future: keep-second" output))
    (assert-true (search "First body remains exact." output))
    (assert-true (search "Second body remains exact." output))))

(define-foundation-test lsm-task-planning-batch-refuses-invalid-or-stale-input
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: planning-batch-errors~%---~%~%"
                    "# Task~%~%"
                    ":::{lem-node}~%id: \"planning:error\"~%:::~%~%"
                    ":::{lem-task}~%state: TODO~%"
                    "workflow: \"org/default\"~%done: false~%:::~%~%"
                    "# Plain~%~%"
                    ":::{lem-node}~%id: \"planning:plain\"~%:::~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source
                         :source-id "planning-batch-errors.md"
                         :revision "planning-batch-errors/1"))
         (date
           (make-temporal-value
            :kind :date :local-value "2026-09-04"
            :precision :date :original-lexeme "2026-09-04"))
         (plan
           (plan-lsm-task-planning-batch
            snapshot :set-task-scheduled
            (list (list "planning:error" date))))
         (changed
           (parse-source provider
                         (concatenate 'string source "~%<!-- changed -->~%")
                         :source-id "planning-batch-errors.md"
                         :revision "planning-batch-errors/2")))
    (dolist (arguments
             (list
              (list :set-task-scheduled nil)
              (list :unsupported
                    (list (list "planning:error" date)))
              (list :set-task-scheduled
                    (list (list "planning:error" date)
                          (list "planning:error" date)))
              (list :set-task-scheduled
                    (list (list "planning:plain" date)))
              (list :set-task-scheduled
                    (list (list "missing" date)))))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (plan-lsm-task-planning-batch
          snapshot (first arguments) (second arguments)))))
    (assert-signals
     'stale-source
     (lambda ()
       (apply-source-edit provider plan changed
                          :new-revision "planning-batch-errors/3")))))

(define-foundation-test lsm-typed-timestamp-edits-are-source-preserving
  (labels ((date (value)
             (make-temporal-value
              :kind :date :local-value value :precision :date
              :original-lexeme value))
           (floating (value)
             (make-temporal-value
              :kind :floating :local-value value :precision :minute)))
    (let* ((source
             (format nil
                     (concatenate
                      'string
                      "---~%lem:~%  profile: lsm/1~%"
                      "  document-id: typed-timestamps~%---~%~%"
                      "# New event~%~%"
                      ":::{lem-task}~%state: TODO~%done: false~%"
                      "future-task: exact~%:::~%~%"
                      "New event body remains exact.~%~%"
                      "# Existing event~%~%"
                      ":::{lem-node}~%id: timestamp:existing~%"
                      "inactive-dates: [\"2026-08-01\"]~%"
                      "future-node: exact~%:::~%~%"
                      ":::{lem-event}~%"
                      "start: \"2026-08-02T09:00\"~%"
                      "location: \"Library\"~%"
                      "recurrence-rules: [\"FREQ=WEEKLY;COUNT=2\"]~%"
                      "recurrence-policy: fixed~%"
                      "future-event: exact~%:::~%~%"
                      "Existing event body remains exact.~%")))
           (provider (make-instance 'lsm-provider))
           (snapshot
             (parse-source provider source :source-id "timestamps.md"
                           :revision "timestamps/1"))
           (new-node
             (first
              (semantic-document-nodes
               (source-snapshot-document snapshot))))
           (created-event
             (make-event-facet
              :start (floating "2026-09-03T10:15:00")
              :end (floating "2026-09-03T11:45:00")))
           (create-plan
             (plan-source-edit
              provider snapshot
              (make-edit-operation
               :kind :set-event-interval
               :target-id (semantic-node-id new-node)
               :payload created-event)))
           (created
             (apply-source-edit provider create-plan snapshot
                                :new-revision "timestamps/2"))
           (existing
             (find-semantic-node
              (source-snapshot-document created) "timestamp:existing"))
           (prior-event (semantic-node-event existing))
           (updated-event
             (make-event-facet
              :start (floating "2026-09-04T13:00:00")
              :end (floating "2026-09-04T14:30:00")
              :location (event-facet-location prior-event)
              :recurrence (event-facet-recurrence prior-event)))
           (event-plan
             (plan-source-edit
              provider created
              (make-edit-operation
               :kind :set-event-interval
               :target-id "timestamp:existing"
               :payload updated-event)))
           (with-event
             (apply-source-edit provider event-plan created
                                :new-revision "timestamps/3"))
           (inactive
             (append
              (semantic-node-inactive-dates
               (find-semantic-node
                (source-snapshot-document with-event) "timestamp:existing"))
              (list (date "2026-09-05"))))
           (inactive-plan
             (plan-source-edit
              provider with-event
              (make-edit-operation
               :kind :set-inactive-dates
               :target-id "timestamp:existing"
               :payload inactive)))
           (updated
             (apply-source-edit provider inactive-plan with-event
                                :new-revision "timestamps/4"))
           (output
             (lsm-syntax-document-source
              (source-snapshot-syntax-tree updated)))
           (created-node
             (find-semantic-node
              (source-snapshot-document updated)
              (semantic-node-id new-node)))
           (updated-node
             (find-semantic-node
              (source-snapshot-document updated) "timestamp:existing")))
      (assert-true (semantic-node-event created-node))
      (assert-equal
       "2026-09-03T11:45:00"
       (temporal-value-local-value
        (event-facet-end (semantic-node-event created-node)))
       :test #'string=)
      (assert-equal "Library"
                    (event-facet-location (semantic-node-event updated-node))
                    :test #'string=)
      (assert-equal
       '("FREQ=WEEKLY;COUNT=2")
       (recurrence-rules
        (event-facet-recurrence (semantic-node-event updated-node))))
      (assert-equal 2 (length (semantic-node-inactive-dates updated-node)))
      (dolist (phrase '("future-task: exact" "future-node: exact"
                        "future-event: exact"
                        "New event body remains exact."
                        "Existing event body remains exact."))
        (assert-true (search phrase output :test #'char=))))))

(define-foundation-test lsm-typed-timestamp-edits-refuse-bulk-or-stale-input
  (labels ((date (value)
             (make-temporal-value
              :kind :date :local-value value :precision :date
              :original-lexeme value)))
    (let* ((source
             (format nil
                     (concatenate
                      'string
                      "---~%lem:~%  profile: lsm/1~%"
                      "  document-id: timestamp-errors~%---~%~%"
                      "# Node~%~%:::{lem-node}~%id: timestamp:error~%"
                      "inactive-dates: [\"2026-08-01\"]~%:::~%")))
           (provider (make-instance 'lsm-provider))
           (snapshot
             (parse-source provider source :source-id "timestamp-errors.md"
                           :revision "timestamp-errors/1"))
           (replacement (list (date "2026-08-01") (date "2026-08-02")))
           (plan
             (plan-source-edit
              provider snapshot
              (make-edit-operation
               :kind :set-inactive-dates
               :target-id "timestamp:error" :payload replacement)))
           (changed
             (parse-source provider (concatenate 'string source "~%changed~%")
                           :source-id "timestamp-errors.md"
                           :revision "timestamp-errors/2")))
      (dolist (payload
               (list nil
                     (list (date "2026-08-02") (date "2026-08-03"))
                     (list (date "2026-08-01") "untyped")))
        (assert-signals
         'semantic-model-error
         (lambda ()
           (plan-source-edit
            provider snapshot
            (make-edit-operation
             :kind :set-inactive-dates
             :target-id "timestamp:error" :payload payload)))))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (plan-source-edit
          provider snapshot
          (make-edit-operation
           :kind :set-event-interval
           :target-id "timestamp:error"
           :payload
           (make-event-facet
            :start (date "2026-08-03") :location "unexpected")))))
      (assert-signals
       'stale-source
       (lambda ()
         (apply-source-edit provider plan changed
                            :new-revision "timestamp-errors/3"))))))

(define-foundation-test
    lsm-heading-insertion-is-after-subtree-persistent-and-source-preserving
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: heading-insertion~%---~%~%"
                    "# Root~%~%:::{lem-node}~%id: heading:root~%"
                    "future-root: exact~%:::~%~%"
                    "## Child~%~%:::{lem-node}~%id: heading:child~%:::~%~%"
                    "Child body remains exact.~%~%"
                    "# Existing sibling~%~%:::{lem-node}~%"
                    "id: heading:sibling~%:::~%~%"
                    "Sibling body remains exact.~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "headings.md"
                         :revision "headings/1"))
         (todo-operation
           (make-edit-operation
            :kind :insert-heading-after-subtree
            :target-id "heading:child"
            :payload '(:new-node-id "heading:todo" :task-p t)))
         (todo-plan (plan-source-edit provider snapshot todo-operation))
         (with-todo
           (apply-source-edit provider todo-plan snapshot
                              :new-revision "headings/2"))
         (plain-operation
           (make-edit-operation
            :kind :insert-heading-after-subtree
            :target-id "heading:root"
            :payload '(:new-node-id "heading:plain" :task-p nil)))
         (plain-plan
           (plan-source-edit provider with-todo plain-operation))
         (updated
           (apply-source-edit provider plain-plan with-todo
                              :new-revision "headings/3"))
         (document (source-snapshot-document updated))
         (todo (find-semantic-node document "heading:todo"))
         (plain (find-semantic-node document "heading:plain"))
         (output
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree updated))))
    (assert-true todo)
    (assert-equal 2 (semantic-node-level todo))
    (assert-equal "heading:root" (semantic-node-parent-id todo)
                  :test #'string=)
    (assert-equal "" (semantic-node-title todo) :test #'string=)
    (assert-equal "TODO"
                  (task-facet-state (semantic-node-task todo))
                  :test #'string=)
    (assert-false (task-facet-done-p (semantic-node-task todo)))
    (assert-true plain)
    (assert-equal 1 (semantic-node-level plain))
    (assert-false (semantic-node-parent-id plain))
    (assert-false (semantic-node-task plain))
    (let ((child-body (search "Child body remains exact." output))
          (todo-heading (search "id: \"heading:todo\"" output))
          (plain-heading (search "id: \"heading:plain\"" output))
          (sibling (search "# Existing sibling" output)))
      (assert-true (and child-body todo-heading plain-heading sibling
                        (< child-body todo-heading plain-heading sibling))))
    (dolist (phrase '("future-root: exact"
                      "Child body remains exact."
                      "Sibling body remains exact."))
      (assert-true (search phrase output :test #'char=)))
    (let* ((no-final-newline
             (string-right-trim
              '(#\Newline #\Return)
              (format nil
                      (concatenate
                       'string
                       "---~%lem:~%  profile: lsm/1~%"
                       "  document-id: heading-eof~%---~%~%"
                       "# EOF~%~%:::{lem-node}~%id: heading:eof~%:::"))))
           (eof-snapshot
             (parse-source provider no-final-newline
                           :source-id "heading-eof.md"
                           :revision "heading-eof/1"))
           (eof-plan
             (plan-source-edit
              provider eof-snapshot
              (make-edit-operation
               :kind :insert-heading-after-subtree
               :target-id "heading:eof"
               :payload '(:new-node-id "heading:eof-sibling" :task-p nil))))
           (eof-updated
             (apply-source-edit provider eof-plan eof-snapshot
                                :new-revision "heading-eof/2"))
           (eof-output
             (lsm-syntax-document-source
              (source-snapshot-syntax-tree eof-updated))))
      (assert-true
       (search (format nil ":::~%~%# ~%") eof-output :test #'char=))
      (assert-true
       (find-semantic-node
        (source-snapshot-document eof-updated) "heading:eof-sibling")))))

(define-foundation-test
    lsm-heading-insertion-refuses-malformed-duplicate-forged-or-stale-input
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: heading-errors~%---~%~%"
                    "# Node~%~%:::{lem-node}~%id: heading:error~%:::~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "heading-errors.md"
                         :revision "heading-errors/1"))
         (operation
           (make-edit-operation
            :kind :insert-heading-after-subtree
            :target-id "heading:error"
            :payload '(:new-node-id "heading:new" :task-p nil)))
         (plan (plan-source-edit provider snapshot operation))
         (changed
           (parse-source provider (concatenate 'string source "~%changed~%")
                         :source-id "heading-errors.md"
                         :revision "heading-errors/2"))
         (forged-metadata (copy-list (edit-plan-metadata plan))))
    (setf (getf forged-metadata :replacement) "# forged")
    (dolist (target-and-payload
             (list
              (list "missing" '(:new-node-id "heading:new" :task-p nil))
              (list "heading:error" nil)
              (list "heading:error" '(:new-node-id "heading:new"))
              (list "heading:error"
                    '(:new-node-id "heading:new" :task-p :maybe))
              (list "heading:error"
                    (list :new-node-id (format nil "bad~%id") :task-p nil))
              (list "heading:error"
                    '(:new-node-id "heading:error" :task-p nil))))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (plan-source-edit
          provider snapshot
          (make-edit-operation
           :kind :insert-heading-after-subtree
           :target-id (first target-and-payload)
           :payload (second target-and-payload))))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (apply-source-edit
        provider
        (make-edit-plan
         :provider provider
         :source-id (edit-plan-source-id plan)
         :base-revision (edit-plan-base-revision plan)
         :base-content-fingerprint
         (edit-plan-base-content-fingerprint plan)
         :base-metadata-fingerprint
         (edit-plan-base-metadata-fingerprint plan)
         :operations (edit-plan-operations plan)
         :metadata forged-metadata)
        snapshot :new-revision "heading-errors/forged")))
    (assert-signals
     'stale-source
     (lambda ()
       (apply-source-edit provider plan changed
                          :new-revision "heading-errors/3")))))

(define-foundation-test
    lsm-context-editing-preserves-typed-empty-list-and-table-structure
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: context-editing~%---~%~%"
                    "# Context~%~%:::{lem-node}~%id: context:node~%:::~%~%"
                    "- [ ] First~%- Second~%~%"
                    "| Name | Value |~%| --- | --- |~%| A | B |~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "context.md"
                         :revision "context/1"))
         (toggle
           (make-edit-operation
            :kind :toggle-list-checkbox :target-id "context:node"
            :payload (list :item-start (search "- [ ] First" source))))
         (toggle-plan (plan-source-edit provider snapshot toggle))
         (toggled
           (apply-source-edit provider toggle-plan snapshot
                              :new-revision "context/2"))
         (toggled-source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree toggled)))
         (insert-list
           (make-edit-operation
            :kind :insert-context-line :target-id "context:node"
            :payload
            (list :kind :list
                  :anchor-start (search "- Second" toggled-source)
                  :above-p t)))
         (insert-list-plan
           (plan-source-edit provider toggled insert-list))
         (with-list
           (apply-source-edit provider insert-list-plan toggled
                              :new-revision "context/3"))
         (with-list-source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree with-list)))
         (insert-table-after-header
           (make-edit-operation
            :kind :insert-context-line :target-id "context:node"
            :payload
            (list :kind :table
                  :anchor-start (search "| Name | Value |" with-list-source)
                  :above-p nil)))
         (header-plan
           (plan-source-edit provider with-list insert-table-after-header))
         (with-header-row
           (apply-source-edit provider header-plan with-list
                              :new-revision "context/4"))
         (with-header-source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree with-header-row)))
         (insert-table-above-data
           (make-edit-operation
            :kind :insert-context-line :target-id "context:node"
            :payload
            (list :kind :table
                  :anchor-start (search "| A | B |" with-header-source)
                  :above-p t)))
         (data-plan
           (plan-source-edit provider with-header-row
                             insert-table-above-data))
         (updated
           (apply-source-edit provider data-plan with-header-row
                              :new-revision "context/5"))
         (output
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree updated)))
         (node
           (find-semantic-node
            (source-snapshot-document updated) "context:node"))
         (list-content
           (find :list (semantic-node-body node)
                 :key (lambda (content)
                        (and (content-node-p content)
                             (content-node-kind content)))))
         (table-content
           (find :table (semantic-node-body node)
                 :key (lambda (content)
                        (and (content-node-p content)
                             (content-node-kind content))))))
    (assert-true (search "- [x] First" output :test #'char=))
    (assert-true (search (format nil "- [x] First~%- ~%- Second")
                         output :test #'char=))
    (assert-equal 3 (length (content-node-items list-content)))
    (assert-false (list-item-inlines
                   (second (content-node-items list-content))))
    (assert-equal 4
                  (length
                   (table-data-rows (content-node-table table-content))))
    (assert-true
     (search
      (format nil
              "| Name | Value |~%| --- | --- |~%|  |  |~%|  |  |~%| A | B |")
      output :test #'char=))))

(define-foundation-test
    lsm-context-editing-refuses-schema-forgery-and-stale-input
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: context-errors~%---~%~%"
                    "# Context~%~%:::{lem-node}~%id: context:error~%:::~%~%"
                    "- Plain~%~%| H |~%| --- |~%| D |~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "context-errors.md"
                         :revision "context-errors/1"))
         (operation
           (make-edit-operation
            :kind :insert-context-line :target-id "context:error"
            :payload
            (list :kind :list :anchor-start (search "- Plain" source)
                  :above-p nil)))
         (plan (plan-source-edit provider snapshot operation))
         (changed
           (parse-source provider (concatenate 'string source "~%changed~%")
                         :source-id "context-errors.md"
                         :revision "context-errors/2"))
         (forged (copy-list (edit-plan-metadata plan))))
    (setf (getf forged :replacement) "- forged")
    (dolist (invalid
             (list
              (make-edit-operation
               :kind :toggle-list-checkbox :target-id "context:error"
               :payload (list :item-start (search "- Plain" source)))
              (make-edit-operation
               :kind :insert-context-line :target-id "context:error"
               :payload
               (list :kind :table :anchor-start (search "| H |" source)
                     :above-p t))
              (make-edit-operation
               :kind :insert-context-line :target-id "context:error"
               :payload '(:kind :list :anchor-start -1 :above-p nil))
              (make-edit-operation
               :kind :insert-context-line :target-id "missing"
               :payload '(:kind :list :anchor-start 0 :above-p nil))))
      (assert-signals
       'semantic-model-error
       (lambda () (plan-source-edit provider snapshot invalid))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (apply-source-edit
        provider
        (make-edit-plan
         :provider provider
         :source-id (edit-plan-source-id plan)
         :base-revision (edit-plan-base-revision plan)
         :base-content-fingerprint
         (edit-plan-base-content-fingerprint plan)
         :base-metadata-fingerprint
         (edit-plan-base-metadata-fingerprint plan)
         :operations (edit-plan-operations plan)
         :metadata forged)
        snapshot :new-revision "context-errors/forged")))
    (assert-signals
     'stale-source
     (lambda ()
       (apply-source-edit provider plan changed
                          :new-revision "context-errors/3")))))

(define-foundation-test
    lsm-horizontal-structural-editing-shifts-exact-heading-markers
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: horizontal-headings~%---~%~%"
                    "# Root~%~%:::{lem-node}~%id: heading:root~%:::~%~%"
                    "## Child~%~%:::{lem-node}~%id: heading:child~%:::~%~%"
                    "Child body stays exact.~%~%"
                    "### Grandchild~%~%:::{lem-node}~%id: heading:grand~%:::~%~%"
                    "## Sibling~%~%:::{lem-node}~%id: heading:sibling~%:::~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "headings.md"
                         :revision "headings/1"))
         (document (source-snapshot-document snapshot))
         (child (find-semantic-node document "heading:child"))
         (grand (find-semantic-node document "heading:grand"))
         (operation
           (make-edit-operation
            :kind :shift-heading-levels :target-id "heading:child"
            :payload
            (list
             :heading-starts
             (mapcar
              (lambda (node)
                (source-span-character-start (semantic-node-span node)))
              (list child grand))
             :direction 1)))
         (plan (plan-source-edit provider snapshot operation))
         (updated
           (apply-source-edit provider plan snapshot
                              :new-revision "headings/2"))
         (updated-source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree updated)))
         (updated-document (source-snapshot-document updated))
         (updated-child
           (find-semantic-node updated-document "heading:child"))
         (updated-grand
           (find-semantic-node updated-document "heading:grand")))
    (assert-equal 3 (semantic-node-level updated-child))
    (assert-equal 4 (semantic-node-level updated-grand))
    (assert-equal "heading:root" (semantic-node-parent-id updated-child)
                  :test #'string=)
    (assert-equal "heading:child" (semantic-node-parent-id updated-grand)
                  :test #'string=)
    (assert-true (search "Child body stays exact." updated-source))
    (assert-true (search "## Sibling" updated-source))
    (let* ((promote
             (make-edit-operation
              :kind :shift-heading-levels :target-id "heading:child"
              :payload
              (list
               :heading-starts
               (mapcar
                (lambda (node)
                  (source-span-character-start (semantic-node-span node)))
                (list updated-child updated-grand))
               :direction -1)))
           (restored
             (apply-source-edit
              provider (plan-source-edit provider updated promote) updated
              :new-revision "headings/3")))
      (assert-equal
       source
       (lsm-syntax-document-source
        (source-snapshot-syntax-tree restored))
       :test #'string=))))

(define-foundation-test
    lsm-horizontal-structural-editing-moves-exact-gfm-columns
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: horizontal-table~%---~%~%"
                    "# Table~%~%:::{lem-node}~%id: table:node~%:::~%~%"
                    "| A  | Longer | Z |~%"
                    "| :--- | ---: | :---: |~%"
                    "| 1 | two | 3 |~%"
                    "| four | 5 | six |~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "table.md"
                         :revision "table/1"))
         (node
           (find-semantic-node
            (source-snapshot-document snapshot) "table:node"))
         (content
           (find :table (semantic-node-body node)
                 :key (lambda (candidate)
                        (and (content-node-p candidate)
                             (content-node-kind candidate)))))
         (table-start
           (source-span-character-start (content-node-span content)))
         (operation
           (make-edit-operation
            :kind :move-table-column :target-id "table:node"
            :payload
            (list :table-start table-start :column 1 :direction -1)))
         (plan (plan-source-edit provider snapshot operation))
         (updated
           (apply-source-edit provider plan snapshot
                              :new-revision "table/2"))
         (output
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree updated))))
    (assert-true (search "| Longer  | A | Z |" output :test #'char=))
    (assert-true (search "| ---: | :--- | :---: |" output :test #'char=))
    (assert-true (search "| two | 1 | 3 |" output :test #'char=))
    (assert-true (search "| 5 | four | six |" output :test #'char=))
    (let* ((updated-node
             (find-semantic-node
              (source-snapshot-document updated) "table:node"))
           (updated-content
             (find :table (semantic-node-body updated-node)
                   :key (lambda (candidate)
                          (and (content-node-p candidate)
                               (content-node-kind candidate)))))
           (move-back
             (make-edit-operation
              :kind :move-table-column :target-id "table:node"
              :payload
              (list
               :table-start
               (source-span-character-start
                (content-node-span updated-content))
               :column 0 :direction 1)))
           (restored
             (apply-source-edit
              provider (plan-source-edit provider updated move-back) updated
              :new-revision "table/3")))
      (assert-equal
       source
       (lsm-syntax-document-source
        (source-snapshot-syntax-tree restored))
       :test #'string=))))

(define-foundation-test
    lsm-horizontal-structural-editing-refuses-invalid-forged-and-stale-input
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: horizontal-errors~%---~%~%"
                    "# Root~%~%:::{lem-node}~%id: horizontal:root~%:::~%~%"
                    "## Child~%~%:::{lem-node}~%id: horizontal:child~%:::~%~%"
                    "| A | B |~%| --- | --- |~%| 1 | 2 |~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "horizontal-errors.md"
                         :revision "horizontal-errors/1"))
         (root
           (find-semantic-node
            (source-snapshot-document snapshot) "horizontal:root"))
         (child
           (find-semantic-node
            (source-snapshot-document snapshot) "horizontal:child"))
         (operation
           (make-edit-operation
            :kind :shift-heading-levels :target-id "horizontal:child"
            :payload
            (list
             :heading-starts
             (list
              (source-span-character-start (semantic-node-span child)))
             :direction 1)))
         (plan (plan-source-edit provider snapshot operation))
         (changed
           (parse-source provider (concatenate 'string source "changed")
                         :source-id "horizontal-errors.md"
                         :revision "horizontal-errors/changed"))
         (forged-metadata (copy-tree (edit-plan-metadata plan))))
    (setf (third (first (getf forged-metadata :patches))) "######")
    (dolist (invalid
             (list
              (make-edit-operation
               :kind :shift-heading-levels :target-id "horizontal:root"
               :payload
               (list
                :heading-starts
                (list
                 (source-span-character-start (semantic-node-span root)))
                :direction -1))
              (make-edit-operation
               :kind :shift-heading-levels :target-id "horizontal:child"
               :payload '(:heading-starts (5 4) :direction 1))
              (make-edit-operation
               :kind :move-table-column :target-id "horizontal:child"
               :payload
               (list :table-start (search "| A | B |" source)
                     :column 0 :direction -1))
              (make-edit-operation
               :kind :move-table-column :target-id "horizontal:child"
               :payload '(:table-start 0 :column -1 :direction 1))))
      (assert-signals
       'semantic-model-error
       (lambda () (plan-source-edit provider snapshot invalid))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (apply-source-edit
        provider
        (make-edit-plan
         :provider provider
         :source-id (edit-plan-source-id plan)
         :base-revision (edit-plan-base-revision plan)
         :base-content-fingerprint
         (edit-plan-base-content-fingerprint plan)
         :base-metadata-fingerprint
         (edit-plan-base-metadata-fingerprint plan)
         :operations (edit-plan-operations plan)
         :metadata forged-metadata)
        snapshot :new-revision "horizontal-errors/forged")))
    (assert-signals
     'stale-source
     (lambda ()
       (apply-source-edit provider plan changed
                          :new-revision "horizontal-errors/stale")))))

(define-foundation-test
    lsm-vertical-structural-editing-moves-exact-heading-subtrees
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: vertical-headings~%---~%~%"
                    "# Root~%~%:::{lem-node}~%id: vertical:root~%:::~%~%"
                    "## First~%~%:::{lem-node}~%id: vertical:first~%:::~%~%"
                    "First body.~%~%"
                    "### Child~%~%:::{lem-node}~%id: vertical:child~%:::~%~%"
                    "## Second~%~%:::{lem-node}~%id: vertical:second~%:::~%~%"
                    "Second body.~%~%"
                    "## Third~%~%:::{lem-node}~%id: vertical:third~%:::~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "vertical-headings.md"
                         :revision "vertical-headings/1"))
         (first
           (find-semantic-node
            (source-snapshot-document snapshot) "vertical:first"))
         (operation
           (make-edit-operation
            :kind :move-structural-unit :target-id "vertical:first"
            :payload
            (list :kind :heading
                  :starts
                  (list
                   (source-span-character-start
                    (semantic-node-span first)))
                  :direction 1)))
         (updated
           (apply-source-edit
            provider (plan-source-edit provider snapshot operation) snapshot
            :new-revision "vertical-headings/2"))
         (updated-source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree updated)))
         (updated-document (source-snapshot-document updated))
         (updated-first
           (find-semantic-node updated-document "vertical:first")))
    (assert-true (< (search "## Second" updated-source)
                    (search "## First" updated-source)))
    (assert-true (< (search "### Child" updated-source)
                    (search "## Third" updated-source)))
    (assert-equal "vertical:first"
                  (semantic-node-parent-id
                   (find-semantic-node updated-document "vertical:child"))
                  :test #'string=)
    (let* ((restore
             (make-edit-operation
              :kind :move-structural-unit :target-id "vertical:first"
              :payload
              (list :kind :heading
                    :starts
                    (list
                     (source-span-character-start
                      (semantic-node-span updated-first)))
                    :direction -1)))
           (restored
             (apply-source-edit
              provider (plan-source-edit provider updated restore) updated
              :new-revision "vertical-headings/3")))
      (assert-equal
       source
       (lsm-syntax-document-source
        (source-snapshot-syntax-tree restored))
       :test #'string=))))

(define-foundation-test
    lsm-vertical-structural-editing-moves-flat-list-items-and-gfm-data-rows
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: vertical-content~%---~%~%"
                    "# Content~%~%:::{lem-node}~%id: vertical:content~%:::~%~%"
                    "- one~%- two~%- three~%~%"
                    "| H | V |~%| --- | --- |~%"
                    "| one | 1 |~%| two | 2 |~%| three | 3 |~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "vertical-content.md"
                         :revision "vertical-content/1"))
         (list-operation
           (make-edit-operation
            :kind :move-structural-unit :target-id "vertical:content"
            :payload
            (list :kind :list :starts (list (search "- two" source))
                  :direction -1)))
         (list-updated
           (apply-source-edit
            provider (plan-source-edit provider snapshot list-operation) snapshot
            :new-revision "vertical-content/2"))
         (list-source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree list-updated)))
         (row-operation
           (make-edit-operation
            :kind :move-structural-unit :target-id "vertical:content"
            :payload
            (list :kind :table :starts (list (search "| two |" list-source))
                  :direction -1)))
         (row-updated
           (apply-source-edit
            provider
            (plan-source-edit provider list-updated row-operation)
            list-updated :new-revision "vertical-content/3"))
         (row-source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree row-updated))))
    (assert-true
     (search (format nil "- two~%- one~%- three") list-source))
    (assert-true
     (search (format nil
                     "| H | V |~%| --- | --- |~%| two | 2 |~%| one | 1 |")
             row-source))))

(define-foundation-test
    lsm-vertical-structural-editing-refuses-boundary-forged-and-stale-input
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: vertical-errors~%---~%~%"
                    "# Root~%~%:::{lem-node}~%id: vertical:error~%:::~%~%"
                    "- one~%- two~%~%"
                    "| H | V |~%| --- | --- |~%| one | 1 |~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "vertical-errors.md"
                         :revision "vertical-errors/1"))
         (valid
           (make-edit-operation
            :kind :move-structural-unit :target-id "vertical:error"
            :payload
            (list :kind :list :starts (list (search "- two" source))
                  :direction -1)))
         (plan (plan-source-edit provider snapshot valid))
         (changed
           (parse-source provider (concatenate 'string source "changed")
                         :source-id "vertical-errors.md"
                         :revision "vertical-errors/changed"))
         (forged (copy-tree (edit-plan-metadata plan))))
    (setf (getf forged :replacement) (format nil "- forged~%- one~%"))
    (dolist (invalid
             (list
              (make-edit-operation
               :kind :move-structural-unit :target-id "vertical:error"
               :payload
               (list :kind :list :starts (list (search "- one" source))
                     :direction -1))
              (make-edit-operation
               :kind :move-structural-unit :target-id "vertical:error"
               :payload
               (list :kind :table :starts (list (search "| H |" source))
                     :direction 1))
              (make-edit-operation
               :kind :move-structural-unit :target-id "vertical:error"
               :payload '(:kind :list :starts (9 8) :direction 1))
              (make-edit-operation
               :kind :move-structural-unit :target-id "missing"
               :payload '(:kind :list :starts (0) :direction 1))))
      (assert-signals
       'semantic-model-error
       (lambda () (plan-source-edit provider snapshot invalid))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (apply-source-edit
        provider
        (make-edit-plan
         :provider provider
         :source-id (edit-plan-source-id plan)
         :base-revision (edit-plan-base-revision plan)
         :base-content-fingerprint
         (edit-plan-base-content-fingerprint plan)
         :base-metadata-fingerprint
         (edit-plan-base-metadata-fingerprint plan)
         :operations (edit-plan-operations plan)
         :metadata forged)
        snapshot :new-revision "vertical-errors/forged")))
    (assert-signals
     'stale-source
     (lambda ()
       (apply-source-edit provider plan changed
                          :new-revision "vertical-errors/stale")))))

(define-foundation-test
    lsm-shift-meta-table-structure-inserts-and-deletes-exact-columns-and-rows
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: shift-meta-table~%---~%~%"
                    "# Table~%~%:::{lem-node}~%id: shift-meta:table~%:::~%~%"
                    "| Head | Value | Keep |~%"
                    "| :--- | ---: | :---: |~%"
                    "| a | b | c |~%| d | e | f |~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "shift-meta-table.md"
                         :revision "shift-meta-table/1"))
         (table-start (search "| Head" source))
         (insert-column
           (make-edit-operation
            :kind :mutate-table-structure :target-id "shift-meta:table"
            :payload
            (list :table-start table-start :axis :column
                  :action :insert :index 1)))
         (with-column
           (apply-source-edit
            provider (plan-source-edit provider snapshot insert-column) snapshot
            :new-revision "shift-meta-table/2"))
         (column-source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree with-column))))
    (assert-true
     (search
      (format nil
              (concatenate
               'string
               "| Head |  | Value | Keep |~%"
               "| :--- | --- | ---: | :---: |~%"
               "| a |  | b | c |~%| d |  | e | f |"))
      column-source))
    (let* ((delete-column
             (make-edit-operation
              :kind :mutate-table-structure :target-id "shift-meta:table"
              :payload
              (list :table-start table-start :axis :column
                    :action :delete :index 1)))
           (without-column
             (apply-source-edit
              provider
              (plan-source-edit provider with-column delete-column)
              with-column :new-revision "shift-meta-table/3")))
      (assert-equal
       source
       (lsm-syntax-document-source
        (source-snapshot-syntax-tree without-column))
       :test #'string=)
      (let* ((insert-row
               (make-edit-operation
                :kind :mutate-table-structure :target-id "shift-meta:table"
                :payload
                (list :table-start table-start :axis :row
                      :action :insert :index 1)))
             (with-row
               (apply-source-edit
                provider
                (plan-source-edit provider without-column insert-row)
                without-column :new-revision "shift-meta-table/4"))
             (row-source
               (lsm-syntax-document-source
                (source-snapshot-syntax-tree with-row))))
        (assert-true
         (search
          (format nil
                  "| :--- | ---: | :---: |~%|  |  |  |~%| a | b | c |")
          row-source))
        (let* ((delete-row
                 (make-edit-operation
                  :kind :mutate-table-structure
                  :target-id "shift-meta:table"
                  :payload
                  (list :table-start table-start :axis :row
                        :action :delete :index 1)))
               (restored
                 (apply-source-edit
                  provider (plan-source-edit provider with-row delete-row)
                  with-row :new-revision "shift-meta-table/5")))
          (assert-equal
           source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree restored))
           :test #'string=))))))

(define-foundation-test
    lsm-shift-meta-table-structure-refuses-schema-forged-and-stale-input
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: shift-meta-errors~%---~%~%"
                    "# Table~%~%:::{lem-node}~%id: shift-meta:error~%:::~%~%"
                    "| A | B |~%| --- | --- |~%| one | two |~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source :source-id "shift-meta-errors.md"
                         :revision "shift-meta-errors/1"))
         (table-start (search "| A |" source))
         (valid
           (make-edit-operation
            :kind :mutate-table-structure :target-id "shift-meta:error"
            :payload
            (list :table-start table-start :axis :column
                  :action :insert :index 1)))
         (plan (plan-source-edit provider snapshot valid))
         (changed
           (parse-source provider (concatenate 'string source "changed")
                         :source-id "shift-meta-errors.md"
                         :revision "shift-meta-errors/changed"))
         (forged (copy-tree (edit-plan-metadata plan))))
    (setf (third (first (getf forged :patches))) " forged |")
    (dolist (invalid
             (list
              (make-edit-operation
               :kind :mutate-table-structure :target-id "shift-meta:error"
               :payload
               (list :table-start table-start :axis :row
                     :action :delete :index 0))
              (make-edit-operation
               :kind :mutate-table-structure :target-id "shift-meta:error"
               :payload
               (list :table-start table-start :axis :column
                     :action :insert :index 2))
              (make-edit-operation
               :kind :mutate-table-structure :target-id "shift-meta:error"
               :payload '(:table-start 0 :axis :column :action :rename :index 0))
              (make-edit-operation
               :kind :mutate-table-structure :target-id "missing"
               :payload
               (list :table-start table-start :axis :column
                     :action :delete :index 0))))
      (assert-signals
       'semantic-model-error
       (lambda () (plan-source-edit provider snapshot invalid))))
    (let* ((single-source
             (format nil
                     (concatenate
                      'string
                      "---~%lem:~%  profile: lsm/1~%"
                      "  document-id: shift-meta-single~%---~%~%"
                      "# Table~%~%:::{lem-node}~%id: shift-meta:single~%:::~%~%"
                      "| A |~%| --- |~%| one |~%")))
           (single
             (parse-source provider single-source
                           :source-id "shift-meta-single.md"
                           :revision "shift-meta-single/1")))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (plan-source-edit
          provider single
          (make-edit-operation
           :kind :mutate-table-structure :target-id "shift-meta:single"
           :payload
           (list :table-start (search "| A |" single-source)
                 :axis :column :action :delete :index 0))))))
    (assert-signals
     'semantic-model-error
     (lambda ()
       (apply-source-edit
        provider
        (make-edit-plan
         :provider provider
         :source-id (edit-plan-source-id plan)
         :base-revision (edit-plan-base-revision plan)
         :base-content-fingerprint
         (edit-plan-base-content-fingerprint plan)
         :base-metadata-fingerprint
         (edit-plan-base-metadata-fingerprint plan)
         :operations (edit-plan-operations plan)
         :metadata forged)
        snapshot :new-revision "shift-meta-errors/forged")))
    (assert-signals
     'stale-source
     (lambda ()
       (apply-source-edit provider plan changed
                          :new-revision "shift-meta-errors/stale")))))

(define-foundation-test lsm-agenda-note-is-newest-first-and-source-preserving
  (let* ((source
           (format nil
                   (concatenate
                    'string
                    "---~%lem:~%  profile: lsm/1~%"
                    "  document-id: notes~%---~%~%"
                    "# Task~%~%"
                    ":::{lem-node}~%id: \"node:task\"~%:::~%~%"
                    ":::{lem-task}~%state: TODO~%"
                    "workflow: \"org/default\"~%done: false~%:::~%~%"
                    "- Note taken on [2026-07-27 Mon 08:00]~%"
                    "Ordinary body remains exact.~%")))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source
                         :source-id "notes.md" :revision "notes/1"))
         (operation
           (make-edit-operation
            :kind :add-agenda-note :target-id "node:task"
            :payload
            (list :timestamp "[2026-07-28 Tue 09:30]"
                  :text (format nil "First line~%# still note text"))))
         (plan (plan-source-edit provider snapshot operation))
         (updated
           (apply-source-edit provider plan snapshot
                              :new-revision "notes/2"))
         (updated-source
           (lsm-syntax-document-source
            (source-snapshot-syntax-tree updated)))
         (inserted
           (format nil
                   (concatenate
                    'string
                    "- Note taken on [2026-07-28 Tue 09:30]  ~%"
                    "  First line~%  # still note text~%")))
         (prior (search "- Note taken on [2026-07-27" updated-source))
         (new (search inserted updated-source)))
    (assert-true new)
    (assert-true prior)
    (assert-true (< new prior))
    (assert-equal
     source
     (concatenate 'string
                  (subseq updated-source 0 new)
                  (subseq updated-source (+ new (length inserted))))
     :test #'string=)
    (assert-equal
     "Task"
     (semantic-node-title
      (find-semantic-node
       (source-snapshot-document updated) "node:task"))
     :test #'string=)
    (let* ((forged-metadata (copy-list (edit-plan-metadata plan)))
           (forged
             (make-edit-plan
              :provider provider :source-id "notes.md"
              :base-revision "notes/1"
              :base-content-fingerprint
              (source-snapshot-content-fingerprint snapshot)
              :base-metadata-fingerprint
              (source-snapshot-metadata-fingerprint snapshot)
              :operations (list operation)
              :metadata
              (progn
                (setf (getf forged-metadata :replacement) "forged")
                forged-metadata))))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (apply-source-edit provider forged snapshot
                            :new-revision "notes/forged"))))))

(define-foundation-test invalid-lsm-agenda-note-input-fails-closed
  (let* ((source
           (format nil
                   "---~%lem:~%  profile: lsm/1~%  document-id: note~%---~%# Task~%"))
         (provider (make-instance 'lsm-provider))
         (snapshot
           (parse-source provider source
                         :source-id "note.md" :revision "note/1"))
         (node (first (semantic-document-nodes
                       (source-snapshot-document snapshot)))))
    (dolist (payload
             (list
              '(:timestamp "[2026-07-28 Mon 09:30]" :text "wrong weekday")
              (list :timestamp "[2026-07-28 Tue 09:30]"
                    :text (format nil "unsafe~ctext" #\Return))
              '(:timestamp "[2026-07-28 Tue 09:30]" :text "x"
                :text "duplicate")))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (plan-source-edit
          provider snapshot
          (make-edit-operation
           :kind :add-agenda-note
           :target-id (semantic-node-id node)
           :payload payload)))))))

(defun parse-lsm-identity-source (source &optional (revision "identity/1"))
  (let ((provider (make-instance 'lsm-provider)))
    (values provider
            (parse-source provider source
                          :source-id "identity.md" :revision revision))))

(define-foundation-test lsm-node-id-plan-creates-persistent-directive
  (let ((source
          (format nil
                  "---~%lem:~%  profile: lsm/1~%  document-id: identity-doc~%---~%~%# Heading~%~%Body stays exact.~%")))
    (multiple-value-bind (provider snapshot)
        (parse-lsm-identity-source source)
      (let* ((old-node
               (first (semantic-document-nodes
                       (source-snapshot-document snapshot))))
             (old-id (semantic-node-id old-node)))
        (multiple-value-bind (persistent-id plan)
            (plan-lsm-node-id snapshot old-id :proposed-id "node:persistent")
          (assert-equal "node:persistent" persistent-id :test #'string=)
          (assert-true plan)
          (let* ((updated
                   (apply-source-edit provider plan snapshot
                                      :new-revision "identity/2"))
                 (updated-source
                   (lsm-syntax-document-source
                    (source-snapshot-syntax-tree updated)))
                 (node
                   (find-semantic-node
                    (source-snapshot-document updated) persistent-id)))
            (assert-true node)
            (assert-equal "Heading" (semantic-node-title node) :test #'string=)
            (assert-true (search "id: \"node:persistent\"" updated-source))
            (assert-true (search "Body stays exact." updated-source))))))))

(define-foundation-test lsm-node-id-plan-preserves-unknown-node-fields
  (let ((source
          (format nil
                  "---~%lem:~%  profile: lsm/1~%  document-id: identity-doc~%---~%~%# Heading~%~%:::{lem-node}~%future-field: keep-exact~%:::~%~%Body.~%")))
    (multiple-value-bind (provider snapshot)
        (parse-lsm-identity-source source)
      (let ((derived-id
              (semantic-node-id
               (first (semantic-document-nodes
                       (source-snapshot-document snapshot))))))
        (multiple-value-bind (persistent-id plan)
            (plan-lsm-node-id snapshot derived-id
                              :proposed-id "node:with-future")
          (let ((updated
                  (apply-source-edit provider plan snapshot
                                     :new-revision "identity/2")))
            (assert-equal "node:with-future" persistent-id :test #'string=)
            (assert-true
             (search "future-field: keep-exact"
                     (lsm-syntax-document-source
                      (source-snapshot-syntax-tree updated))))))))))

(define-foundation-test lsm-node-id-plan-reuses-declared-identity
  (let ((source
          (format nil
                  "---~%lem:~%  profile: lsm/1~%  document-id: identity-doc~%---~%~%# Heading~%~%:::{lem-node}~%id: \"node:fixed\"~%:::~%")))
    (multiple-value-bind (provider snapshot)
        (parse-lsm-identity-source source)
      (declare (ignore provider))
      (multiple-value-bind (persistent-id plan)
          (plan-lsm-node-id snapshot "node:fixed")
        (assert-equal "node:fixed" persistent-id :test #'string=)
        (assert-false plan)))))

(define-foundation-test lsm-node-id-plan-refuses-collision-and-stale-source
  (let ((source
          (format nil
                  "---~%lem:~%  profile: lsm/1~%  document-id: identity-doc~%---~%~%# Derived~%~%# Taken~%~%:::{lem-node}~%id: \"node:taken\"~%:::~%")))
    (multiple-value-bind (provider snapshot)
        (parse-lsm-identity-source source)
      (let ((derived-id
              (semantic-node-id
               (first (semantic-document-nodes
                       (source-snapshot-document snapshot))))))
        (assert-signals
         'semantic-model-error
         (lambda ()
           (plan-lsm-node-id snapshot derived-id
                             :proposed-id "node:taken")))
        (dolist (proposed (list nil "" (format nil "bad~%id")))
          (assert-signals
           'semantic-model-error
           (lambda ()
             (plan-lsm-node-id snapshot derived-id
                               :proposed-id proposed))))
        (multiple-value-bind (persistent-id plan)
            (plan-lsm-node-id snapshot derived-id
                              :proposed-id "node:new")
          (declare (ignore persistent-id))
          (let ((changed
                  (parse-source provider
                                (concatenate 'string source "changed")
                                :source-id "identity.md"
                                :revision "identity/changed")))
            (assert-signals
             'stale-source
             (lambda ()
               (apply-source-edit provider plan changed
                                  :new-revision "identity/2")))))))))

(define-foundation-test lsm-node-id-batch-is-atomic-and-reuses-existing-id
  (let ((source
          (format nil
                  "---~%lem:~%  profile: lsm/1~%  document-id: identity-doc~%---~%~%# Parent~%~%## Child~%~%# Fixed~%~%:::{lem-node}~%id: fixed-id~%:::~%")))
    (multiple-value-bind (provider snapshot)
        (parse-lsm-identity-source source)
      (let* ((nodes
               (semantic-document-nodes
                (source-snapshot-document snapshot)))
             (targets (mapcar #'semantic-node-id nodes)))
        (multiple-value-bind (persistent-ids plan)
            (plan-lsm-node-id-batch
             snapshot targets '("parent-id" "child-id" nil))
          (assert-equal '("parent-id" "child-id" "fixed-id")
                        persistent-ids :test #'equal)
          (assert-true plan)
          (let* ((updated
                   (apply-source-edit provider plan snapshot
                                      :new-revision "identity/batch"))
                 (document (source-snapshot-document updated))
                 (parent (find-semantic-node document "parent-id"))
                 (child (find-semantic-node document "child-id"))
                 (updated-source
                   (lsm-syntax-document-source
                    (source-snapshot-syntax-tree updated)))
                 (first-directive (search ":::{lem-node}" updated-source))
                 (second-directive
                   (and first-directive
                        (search ":::{lem-node}" updated-source
                                :start2 (1+ first-directive))))
                 (third-directive
                   (and second-directive
                        (search ":::{lem-node}" updated-source
                                :start2 (1+ second-directive)))))
            (assert-true parent)
            (assert-true child)
            (assert-equal "parent-id" (semantic-node-parent-id child)
                          :test #'string=)
            (assert-equal '("child-id") (semantic-node-child-ids parent)
                          :test #'equal)
            (assert-true first-directive)
            (assert-true second-directive)
            (assert-true third-directive)
            (assert-false
             (search ":::{lem-node}" updated-source
                     :start2 (1+ third-directive)))))))))

(define-foundation-test lsm-node-id-batch-refuses-invalid-shapes
  (let ((source
          (format nil
                  "---~%lem:~%  profile: lsm/1~%  document-id: identity-doc~%---~%~%# One~%~%# Two~%")))
    (multiple-value-bind (provider snapshot)
        (parse-lsm-identity-source source)
      (declare (ignore provider))
      (let ((targets
              (mapcar #'semantic-node-id
                      (semantic-document-nodes
                       (source-snapshot-document snapshot)))))
        (assert-signals
         'semantic-model-error
         (lambda ()
           (plan-lsm-node-id-batch snapshot targets '("only-one"))))
        (assert-signals
         'semantic-model-error
         (lambda ()
           (plan-lsm-node-id-batch snapshot targets '("same" "same"))))
        (assert-signals
         'semantic-model-error
         (lambda ()
           (plan-lsm-node-id-batch snapshot targets '(nil "two"))))))))
