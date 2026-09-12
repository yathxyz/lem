(in-package #:lem-structured-notes/tests)

(defun test-notes-workspace ()
  (resolve-notes-workspace "/srv/notes"
                           :launch-directory #P"/tmp/launch/"
                           :home-directory #P"/tmp/home/"))

(define-foundation-test native-lsm-node-id-generation-is-random-shaped-and-fail-closed
  (let* ((entropy
           (make-array 16 :element-type '(unsigned-byte 8)
                          :initial-contents
                          '(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)))
         (original (copy-seq entropy))
         (lem-structured-notes::*notes-node-id-random-data-function*
           (lambda (count)
             (assert-equal 16 count)
             entropy)))
    (assert-equal "00010203-0405-4607-8809-0a0b0c0d0e0f"
                  (generate-lsm-node-id) :test #'string=)
    (assert-equal original entropy :test #'equalp))
  (let ((lem-structured-notes::*notes-node-id-random-data-function*
          (lambda (count)
            (declare (ignore count))
            (make-array 15 :element-type '(unsigned-byte 8)
                           :initial-element 0))))
    (assert-signals 'notes-workflow-error #'generate-lsm-node-id))
  (let ((lem-structured-notes::*notes-node-id-random-data-function*
          (lambda (count)
            (declare (ignore count))
            (error "entropy unavailable"))))
    (assert-signals 'notes-workflow-error #'generate-lsm-node-id)))

(define-foundation-test notes-workspace-resolution-matches-shared-root-policy
  (flet ((root (configured)
           (notes-workspace-root
            (resolve-notes-workspace
             configured :launch-directory #P"/tmp/launch/base/"
             :home-directory #P"/tmp/home/person/"))))
    (assert-equal #P"/tmp/home/person/work/" (root nil))
    (assert-equal #P"/tmp/home/person/work/" (root ""))
    (assert-equal #P"/tmp/launch/base/notes/" (root "notes"))
    (assert-equal #P"/tmp/launch/notes/" (root "../notes"))
    (assert-equal #P"/srv/notes/" (root "/srv/notes"))
    (assert-equal #P"/tmp/home/person/notes/" (root "~/notes"))
    (assert-signals
     'notes-workflow-error
     (lambda () (root "~another/notes")))
    (assert-signals
     'notes-workflow-error
     (lambda () (root "../../../../../../escape")))))

(define-foundation-test native-lsm-daily-plan-is-canonical-and-reusable
  (let* ((workspace (test-notes-workspace))
         (plan (plan-lsm-daily-note workspace "2024-02-29"))
         (source (notes-document-plan-output-source plan))
         (snapshot
           (parse-source
            (make-instance 'lsm-provider) source
            :source-id (namestring (notes-document-plan-target-path plan))
            :revision "daily-test/1"))
         (document (source-snapshot-document snapshot))
         (node (find-semantic-node document "daily:2024-02-29")))
    (assert-true (notes-document-plan-created-p plan))
    (assert-equal :daily (notes-document-plan-kind plan))
    (assert-equal #P"/srv/notes/roam/2024-02-29.md"
                  (notes-document-plan-target-path plan))
    (assert-equal "daily:2024-02-29"
                  (notes-document-plan-document-id plan) :test #'string=)
    (assert-true node)
    (assert-equal "2024-02-29" (semantic-node-title node) :test #'string=)
    (assert-equal source (apply-notes-document-plan plan nil) :test #'string=)
    (let ((reuse
            (plan-lsm-daily-note workspace "2024-02-29"
                                 :current-source source)))
      (assert-false (notes-document-plan-created-p reuse))
      (assert-equal source (notes-document-plan-output-source reuse)
                    :test #'string=))))

(define-foundation-test native-lsm-daily-plan-rejects-invalid-or-wrong-document
  (let ((workspace (test-notes-workspace)))
    (dolist (date '("2023-02-29" "2026-02-30" "2026-13-01" "2026-7-10"
                    " 2026-07-10" "../../etc/x" "2026-07-10/evil"))
      (assert-signals
       'notes-workflow-error
       (lambda () (plan-lsm-daily-note workspace date))))
    (let ((wrong
            (notes-document-plan-output-source
             (plan-lsm-daily-note workspace "2026-07-11"))))
      (assert-signals
       'notes-workflow-error
       (lambda ()
         (plan-lsm-daily-note workspace "2026-07-10"
                              :current-source wrong))))))

(define-foundation-test native-lsm-journal-plan-appends-stably
  (let* ((workspace (test-notes-workspace))
         (time (encode-universal-time 0 30 9 10 7 2026 0))
         (first (plan-lsm-journal-entry workspace time :timezone 0))
         (first-source (notes-document-plan-output-source first))
         (second
           (plan-lsm-journal-entry
            workspace time :timezone 0 :current-source first-source))
         (second-source (notes-document-plan-output-source second))
         (snapshot
           (parse-source
            (make-instance 'lsm-provider) second-source
            :source-id (namestring (notes-document-plan-target-path second))
            :revision "journal-test/2"))
         (document (source-snapshot-document snapshot))
         (root (find-semantic-node document "journal:20260710"))
         (first-entry
           (find-semantic-node document "journal:20260710:entry:0001"))
         (second-entry
           (find-semantic-node document "journal:20260710:entry:0002")))
    (assert-equal #P"/srv/notes/roam/journal/20260710.md"
                  (notes-document-plan-target-path first))
    (assert-true (notes-document-plan-created-p first))
    (assert-false (notes-document-plan-created-p second))
    (assert-true (and root first-entry second-entry))
    (assert-equal "Fri, 2026-07-10" (semantic-node-title root) :test #'string=)
    (assert-equal "09:30" (semantic-node-title first-entry) :test #'string=)
    (assert-equal "09:30" (semantic-node-title second-entry) :test #'string=)
    (assert-equal "journal:20260710" (semantic-node-parent-id first-entry)
                  :test #'string=)
    (assert-equal "journal:20260710" (semantic-node-parent-id second-entry)
                  :test #'string=)
    (assert-equal first-source (subseq second-source 0 (length first-source))
                  :test #'string=)
    (assert-equal second-source
                  (apply-notes-document-plan second first-source)
                  :test #'string=)
    (assert-signals
     'notes-workflow-error
     (lambda () (apply-notes-document-plan second
                                           (concatenate 'string first-source
                                                        "intervening"))))))

(define-foundation-test native-lsm-journal-plan-rejects-wrong-root
  (let* ((workspace (test-notes-workspace))
         (first-time (encode-universal-time 0 30 9 10 7 2026 0))
         (other-time (encode-universal-time 0 30 9 11 7 2026 0))
         (wrong
           (notes-document-plan-output-source
            (plan-lsm-journal-entry workspace other-time :timezone 0))))
    (assert-signals
     'notes-workflow-error
     (lambda ()
       (plan-lsm-journal-entry workspace first-time :timezone 0
                               :current-source wrong)))))

(defun captured-node-from-plan (plan revision)
  (let* ((snapshot
           (parse-source
            (make-instance 'lsm-provider)
            (notes-document-plan-output-source plan)
            :source-id (namestring (notes-document-plan-target-path plan))
            :revision revision))
         (document (source-snapshot-document snapshot)))
    (values (find-semantic-node
             document (notes-document-plan-focus-node-id plan))
            document)))

(define-foundation-test native-lsm-capture-plans-work-targets-and-task-state
  (let* ((workspace (test-notes-workspace))
         (time (encode-universal-time 5 30 9 10 7 2026 0))
         (inbox
           (plan-lsm-capture workspace "i" "Inbox item" time :timezone 0))
         (todo
           (plan-lsm-capture workspace "t" "Task item" time :timezone 0))
         (reading
           (plan-lsm-capture workspace "r" "Book item" time :timezone 0)))
    (assert-equal #P"/srv/notes/inbox.md"
                  (notes-document-plan-target-path inbox))
    (assert-equal #P"/srv/notes/todo.md"
                  (notes-document-plan-target-path todo))
    (assert-equal #P"/srv/notes/readlist.md"
                  (notes-document-plan-target-path reading))
    (multiple-value-bind (inbox-node inbox-document)
        (captured-node-from-plan inbox "capture/inbox")
      (assert-equal "capture:work:inbox"
                    (semantic-document-id inbox-document) :test #'string=)
      (assert-equal "capture:work:inbox"
                    (semantic-node-parent-id inbox-node) :test #'string=)
      (assert-false (semantic-node-task inbox-node))
      (assert-equal
       '("created" . "2026-07-10T09:30:05")
       (first (semantic-node-properties inbox-node))))
    (dolist (plan (list todo reading))
      (multiple-value-bind (node document)
          (captured-node-from-plan plan "capture/task")
        (declare (ignore document))
        (assert-true (semantic-node-task node))
        (assert-equal "TODO" (task-facet-state (semantic-node-task node))
                      :test #'string=)
        (assert-false (task-facet-done-p (semantic-node-task node)))))))

(define-foundation-test native-lsm-capture-reuses-source-with-distinct-ids
  (let* ((workspace (test-notes-workspace))
         (time (encode-universal-time 0 30 9 10 7 2026 0))
         (first
           (plan-lsm-capture workspace "t" "First" time :timezone 0))
         (first-source (notes-document-plan-output-source first))
         (second
           (plan-lsm-capture
            workspace "t" "Second" time :timezone 0
            :current-source first-source))
         (second-source (notes-document-plan-output-source second)))
    (assert-equal "capture:work:todo:entry:0001"
                  (notes-document-plan-focus-node-id first) :test #'string=)
    (assert-equal "capture:work:todo:entry:0002"
                  (notes-document-plan-focus-node-id second) :test #'string=)
    (assert-equal first-source (subseq second-source 0 (length first-source))
                  :test #'string=)
    (assert-equal second-source
                  (apply-notes-document-plan second first-source)
                  :test #'string=)))

(define-foundation-test native-lsm-capture-round-trips-editable-markdown-body
  (let* ((workspace (test-notes-workspace))
         (time (encode-universal-time 0 30 9 10 7 2026 0))
         (body
           (format nil
                   "Context with *emphasis*.~%~%- First item~%- Second item~%~%```text~%literal payload~%```~%"))
         (plan
           (plan-lsm-capture workspace "t" "Body task" time :timezone 0
                             :body-source body)))
    (multiple-value-bind (node document)
        (captured-node-from-plan plan "capture/body")
      (declare (ignore document))
      (assert-equal '(:paragraph :list :source-block)
                    (mapcar #'content-node-kind (semantic-node-body node)))
      (assert-equal "Context with "
                    (inline-node-text
                     (first
                      (content-node-inlines
                       (first (semantic-node-body node)))))
                    :test #'string=)
      (assert-equal 2
                    (length
                     (content-node-items
                      (second (semantic-node-body node)))))
      (assert-equal "literal payload"
                    (string-right-trim
                     '(#\Newline #\Return)
                     (code-block-data-code
                      (content-node-code-block
                       (third (semantic-node-body node)))))
                    :test #'string=))
    (assert-true (search "Context with *emphasis*."
                         (notes-document-plan-output-source plan)))
    (assert-true (search "- First item"
                         (notes-document-plan-output-source plan)))
    (assert-true (search "```text"
                         (notes-document-plan-output-source plan)))))

(define-foundation-test native-lsm-capture-body-fails-closed-on-injection-and-limits
  (let ((workspace (test-notes-workspace))
        (time (encode-universal-time 0 30 9 10 7 2026 0)))
    (dolist (body
             (list nil
                   (format nil "unsafe~cbody" #\Null)
                   (format nil "# Injected child~%")
                   (format nil
                           ":::{lem-task}~%state: DONE~%done: true~%:::~%")))
      (assert-signals
       'notes-workflow-error
       (lambda ()
         (plan-lsm-capture workspace "i" "Unsafe body" time :timezone 0
                           :body-source body))))
    (dolist (body
             (list (make-string 1048577 :initial-element #\x)
                   (make-string 350000 :initial-element #\U+2603)))
      (assert-signals
       'notes-workflow-error
       (lambda ()
         (plan-lsm-capture workspace "i" "Oversized body" time :timezone 0
                           :body-source body))))))

(define-foundation-test native-lsm-public-capture-is-explicit-and-top-level
  (let* ((workspace (test-notes-workspace))
         (public
           (resolve-notes-workspace
            "/srv/public-notes" :launch-directory #P"/tmp/launch/"
            :home-directory #P"/tmp/home/"))
         (time (encode-universal-time 0 30 9 10 7 2026 0)))
    (assert-signals
     'notes-workflow-error
     (lambda ()
       (plan-lsm-capture workspace "p" "Public item" time :timezone 0)))
    (let ((plan
            (plan-lsm-capture
             workspace "p" "Public item" time :timezone 0
             :public-workspace public)))
      (assert-equal #P"/srv/public-notes/inbox.md"
                    (notes-document-plan-target-path plan))
      (multiple-value-bind (node document)
          (captured-node-from-plan plan "capture/public")
        (assert-equal "capture:public:inbox"
                      (semantic-document-id document) :test #'string=)
        (assert-false (semantic-node-parent-id node))
        (assert-true (member (semantic-node-id node)
                             (semantic-document-root-ids document)
                             :test #'string=))
        (assert-equal "TODO" (task-facet-state (semantic-node-task node))
                      :test #'string=)))))

(define-foundation-test native-lsm-capture-preserves-safe-origin-context
  (let* ((workspace (test-notes-workspace))
         (public
           (resolve-notes-workspace
            "/srv/public-notes" :launch-directory #P"/tmp/launch/"
            :home-directory #P"/tmp/home/"))
         (time (encode-universal-time 0 30 9 10 7 2026 0))
         (origin
           (make-notes-capture-origin
            :provider :org :scope :work :path "agenda/work.org"
            :node-id "org-node-42" :date "2026-07-10"))
         (plan
           (plan-lsm-capture workspace "t" "Context task" time :timezone 0
                             :origin origin)))
    (assert-equal :org (notes-capture-origin-provider origin))
    (assert-equal :work (notes-capture-origin-scope origin))
    (assert-equal "agenda/work.org" (notes-capture-origin-path origin)
                  :test #'string=)
    (assert-equal "org-node-42" (notes-capture-origin-node-id origin)
                  :test #'string=)
    (assert-equal "2026-07-10" (notes-capture-origin-date origin)
                  :test #'string=)
    (multiple-value-bind (node document)
        (captured-node-from-plan plan "capture/origin")
      (declare (ignore document))
      (assert-equal
       '(("created" . "2026-07-10T09:30:00")
         ("capture-origin-provider" . "org")
         ("capture-origin-scope" . "work")
         ("capture-origin-path" . "agenda/work.org")
         ("capture-origin-node-id" . "org-node-42")
         ("capture-origin-date" . "2026-07-10"))
       (semantic-node-properties node)))
    (assert-signals
     'notes-workflow-error
     (lambda ()
       (plan-lsm-capture workspace "p" "Must not leak" time :timezone 0
                         :public-workspace public :origin origin)))
    (let* ((public-origin
             (make-notes-capture-origin
              :provider :lsm :scope :public :path "mcp/published.md"
              :node-id "public-node"))
           (public-plan
             (plan-lsm-capture
              workspace "p" "Public context" time :timezone 0
              :public-workspace public :origin public-origin)))
      (multiple-value-bind (node document)
          (captured-node-from-plan public-plan "capture/public-origin")
        (declare (ignore document))
        (assert-equal "public"
                      (cdr (assoc "capture-origin-scope"
                                  (semantic-node-properties node)
                                  :test #'string=))
                      :test #'string=)))))

(define-foundation-test native-lsm-capture-refuses-unsafe-origin-context
  (flet ((origin (&rest arguments)
           (apply #'make-notes-capture-origin
                  (append arguments
                          '(:provider :lsm :scope :work :path "agenda.md"
                            :node-id "node-1")))))
    (dolist (provider '(:icalendar :unknown nil))
      (assert-signals 'notes-workflow-error
                      (lambda () (origin :provider provider))))
    (dolist (scope '(:private :unknown nil))
      (assert-signals 'notes-workflow-error
                      (lambda () (origin :scope scope))))
    (dolist (path (list "" "/absolute.md" "\\absolute.md"
                        "a\\b.md" "." ".." "a/./b.md" "a/../b.md"
                        "a//b.md" "a/" (format nil "a~cb.md" #\Tab)))
      (assert-signals 'notes-workflow-error
                      (lambda () (origin :path path))))
    (dolist (node-id (list "" (format nil "node~cid" #\Newline)
                           (make-string 4097 :initial-element #\x)))
      (assert-signals 'notes-workflow-error
                      (lambda () (origin :node-id node-id))))
    (dolist (date '("2023-02-29" "2026-7-10" "../../2026-07-10"))
      (assert-signals 'notes-workflow-error
                      (lambda () (origin :date date))))))

(define-foundation-test native-lsm-capture-preserves-local-file-origin
  (let* ((workspace (test-notes-workspace))
         (time (encode-universal-time 0 30 9 10 7 2026 0))
         (origin
           (make-notes-capture-origin
            :provider :file :scope :work :path "drafts/context.txt"
            :node-id nil))
         (plan
           (plan-lsm-capture workspace "i" "File context" time :timezone 0
                             :origin origin)))
    (multiple-value-bind (node document)
        (captured-node-from-plan plan "capture/file-origin")
      (declare (ignore document))
      (assert-equal "file"
                    (cdr (assoc "capture-origin-provider"
                                (semantic-node-properties node)
                                :test #'string=))
                    :test #'string=)
      (assert-equal "drafts/context.txt"
                    (cdr (assoc "capture-origin-path"
                                (semantic-node-properties node)
                                :test #'string=))
                    :test #'string=)
      (assert-false
       (assoc "capture-origin-node-id" (semantic-node-properties node)
              :test #'string=)))))

(define-foundation-test native-lsm-capture-refuses-unsafe-input-and-wrong-file
  (let* ((workspace (test-notes-workspace))
         (time (encode-universal-time 0 30 9 10 7 2026 0))
         (inbox-source
           (notes-document-plan-output-source
            (plan-lsm-capture workspace "i" "Inbox item" time
                              :timezone 0))))
    (dolist (key '("" "x" "tt"))
      (assert-signals
       'notes-workflow-error
       (lambda ()
         (plan-lsm-capture workspace key "Title" time :timezone 0))))
    (dolist (title (list "" (format nil "line one~%line two")))
      (assert-signals
       'notes-workflow-error
       (lambda ()
         (plan-lsm-capture workspace "i" title time :timezone 0))))
    (assert-signals
     'notes-workflow-error
     (lambda ()
       (plan-lsm-capture workspace "t" "Wrong file" time :timezone 0
                         :current-source inbox-source)))))
