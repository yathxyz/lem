(in-package #:lem-structured-notes)

(define-condition source-adapter-error (error)
  ((provider
    :initarg :provider
    :reader source-adapter-error-provider)
   (message
    :initarg :message
    :reader source-adapter-error-message))
  (:report
   (lambda (condition stream)
     (format stream "Source adapter error~@[ in ~s~]: ~a"
             (source-adapter-error-provider condition)
             (source-adapter-error-message condition)))))

(define-condition unsupported-source-operation (source-adapter-error)
  ((operation
    :initarg :operation
    :reader unsupported-source-operation-operation))
  (:report
   (lambda (condition stream)
     (format stream "Source provider ~s does not implement ~s"
             (source-adapter-error-provider condition)
             (unsupported-source-operation-operation condition)))))

(define-condition stale-source (source-adapter-error)
  ((expected-revision
    :initarg :expected-revision
    :reader stale-source-expected-revision)
   (actual-revision
    :initarg :actual-revision
    :reader stale-source-actual-revision)
   (expected-fingerprint
    :initarg :expected-fingerprint
    :reader stale-source-expected-fingerprint)
   (actual-fingerprint
    :initarg :actual-fingerprint
    :reader stale-source-actual-fingerprint)
   (expected-metadata-fingerprint
    :initarg :expected-metadata-fingerprint
    :reader stale-source-expected-metadata-fingerprint)
   (actual-metadata-fingerprint
    :initarg :actual-metadata-fingerprint
    :reader stale-source-actual-metadata-fingerprint))
  (:report
   (lambda (condition stream)
     (format stream
             "Refusing stale source edit: planned revision/content/metadata ~s/~s/~s, current ~s/~s/~s"
             (stale-source-expected-revision condition)
             (stale-source-expected-fingerprint condition)
             (stale-source-expected-metadata-fingerprint condition)
             (stale-source-actual-revision condition)
             (stale-source-actual-fingerprint condition)
             (stale-source-actual-metadata-fingerprint condition)))))

(defclass source-provider () ()
  (:documentation
   "Base class for format adapters. Providers parse, plan, and atomically apply."))

(defgeneric source-provider-format (provider)
  (:documentation "Return the provider's semantic document format keyword."))

(defgeneric source-provider-profile (provider)
  (:documentation "Return the exact source profile version handled."))

(defgeneric parse-source (provider source &key source-id revision)
  (:documentation
   "Parse SOURCE and return a validated SOURCE-SNAPSHOT without mutation."))

(defgeneric enumerate-nodes (provider snapshot)
  (:documentation "Return the semantic nodes present in SNAPSHOT."))

(defgeneric enumerate-tasks (provider snapshot)
  (:documentation "Return task-bearing semantic nodes present in SNAPSHOT."))

(defgeneric resolve-node (provider snapshot node-id)
  (:documentation
   "Resolve NODE-ID to a revision-bound SOURCE-LOCATION, or NIL."))

(defgeneric plan-source-edit (provider snapshot operation &key)
  (:documentation
   "Return an EDIT-PLAN without changing the source or live buffer."))

(defgeneric apply-source-edit (provider plan current-snapshot &key)
  (:documentation
   "Apply PLAN atomically after proving CURRENT-SNAPSHOT is not stale."))

(defgeneric render-source-node (provider node &key)
  (:documentation "Render a new semantic NODE in the provider's source syntax."))

(defgeneric source-content-fingerprint (provider source)
  (:documentation
   "Return a stable content fingerprint. Production providers use a secure hash."))

(defgeneric source-metadata-fingerprint (provider source)
  (:documentation
   "Return a stable fingerprint for source metadata relevant to safe editing."))

(defmethod source-provider-format ((provider source-provider))
  (error 'unsupported-source-operation
         :provider provider
         :operation 'source-provider-format
         :message "provider format is required"))

(defmethod source-provider-profile ((provider source-provider))
  (error 'unsupported-source-operation
         :provider provider
         :operation 'source-provider-profile
         :message "provider profile is required"))

(defmethod parse-source ((provider source-provider) source
                         &key source-id revision)
  (declare (ignore source source-id revision))
  (error 'unsupported-source-operation
         :provider provider
         :operation 'parse-source
         :message "source parser is required"))

(defmethod plan-source-edit ((provider source-provider) snapshot operation
                             &key &allow-other-keys)
  (declare (ignore snapshot operation))
  (error 'unsupported-source-operation
         :provider provider
         :operation 'plan-source-edit
         :message "edit planning is not implemented"))

(defmethod apply-source-edit ((provider source-provider) plan current-snapshot
                              &key &allow-other-keys)
  (declare (ignore plan current-snapshot))
  (error 'unsupported-source-operation
         :provider provider
         :operation 'apply-source-edit
         :message "atomic edit application is not implemented"))

(defmethod render-source-node ((provider source-provider) node
                               &key &allow-other-keys)
  (declare (ignore node))
  (error 'unsupported-source-operation
         :provider provider
         :operation 'render-source-node
         :message "node rendering is not implemented"))

(defmethod source-content-fingerprint ((provider source-provider) source)
  (declare (ignore source))
  (error 'unsupported-source-operation
         :provider provider
         :operation 'source-content-fingerprint
         :message "content fingerprinting is required"))

(defmethod source-metadata-fingerprint ((provider source-provider) source)
  (declare (ignore source))
  (error 'unsupported-source-operation
         :provider provider
         :operation 'source-metadata-fingerprint
         :message "metadata fingerprinting is required"))

(defstruct (source-snapshot
            (:constructor %make-source-snapshot
                (provider source-id revision document syntax-tree
                 content-fingerprint metadata-fingerprint diagnostics)))
  (provider nil :type source-provider :read-only t)
  (source-id "" :type string :read-only t)
  (revision "" :type string :read-only t)
  (document nil :type semantic-document :read-only t)
  (syntax-tree nil :read-only t)
  (content-fingerprint "" :type string :read-only t)
  (metadata-fingerprint "" :type string :read-only t)
  (diagnostics nil :type list :read-only t))

(defun make-source-snapshot
    (&key provider source-id revision document content-fingerprint
          metadata-fingerprint syntax-tree (diagnostics nil))
  (unless (typep provider 'source-provider)
    (model-error :invalid-source-provider provider
                 "snapshot provider must be a source provider"))
  (require-non-empty-string source-id :invalid-source-id "snapshot source ID")
  (require-non-empty-string revision :invalid-source-revision
                            "snapshot revision")
  (unless (semantic-document-p document)
    (model-error :invalid-snapshot-document document
                 "snapshot document must be a semantic document"))
  (unless (string= revision (semantic-document-source-revision document))
    (model-error :snapshot-revision-mismatch revision
                 "snapshot and document source revisions must match"))
  (unless (eq (source-provider-format provider)
              (semantic-document-format document))
    (model-error :snapshot-format-mismatch (semantic-document-format document)
                 "snapshot document format differs from provider format"))
  (unless (string= (source-provider-profile provider)
                   (semantic-document-profile document))
    (model-error :snapshot-profile-mismatch (semantic-document-profile document)
                 "snapshot document profile differs from provider profile"))
  (dolist (node (semantic-document-nodes document))
    (let ((span (semantic-node-span node)))
      (when (and span
                 (not (string= source-id (source-span-source-id span))))
        (model-error :snapshot-span-source-mismatch
                     (source-span-source-id span)
                     "node span belongs to a different source"))))
  (require-non-empty-string content-fingerprint :invalid-content-fingerprint
                            "content fingerprint")
  (require-non-empty-string metadata-fingerprint
                            :invalid-metadata-fingerprint
                            "metadata fingerprint")
  (let ((diagnostics
          (copy-proper-list diagnostics :invalid-diagnostics
                            "snapshot diagnostics")))
    (unless (every #'diagnostic-p diagnostics)
      (model-error :invalid-diagnostic diagnostics
                   "every snapshot diagnostic must be a diagnostic"))
    (%make-source-snapshot provider source-id revision document syntax-tree
                           content-fingerprint metadata-fingerprint
                           diagnostics)))

(defstruct (source-location
            (:constructor %make-source-location
                (source-id node-id revision span)))
  (source-id "" :type string :read-only t)
  (node-id "" :type string :read-only t)
  (revision "" :type string :read-only t)
  (span nil :type (or null source-span) :read-only t))

(defun make-source-location (&key source-id node-id revision span)
  (require-non-empty-string source-id :invalid-source-id "location source ID")
  (require-non-empty-string node-id :invalid-node-id "location node ID")
  (require-non-empty-string revision :invalid-source-revision
                            "location revision")
  (unless (or (null span) (source-span-p span))
    (model-error :invalid-source-span span
                 "location span must be a source span or NIL"))
  (%make-source-location source-id node-id revision span))

(defstruct (edit-operation
            (:constructor %make-edit-operation (kind target-id payload)))
  (kind :replace-content :type keyword :read-only t)
  (target-id "" :type string :read-only t)
  payload)

(defun make-edit-operation (&key kind target-id payload)
  (unless (keywordp kind)
    (model-error :invalid-edit-kind kind "edit kind must be a keyword"))
  (require-non-empty-string target-id :invalid-edit-target "edit target ID")
  (%make-edit-operation kind target-id payload))

(defstruct (archive-context
            (:constructor %make-archive-context
                (timestamp source-id outline-path category task-state
                 inherited-tags)))
  (timestamp "" :type string :read-only t)
  (source-id "" :type string :read-only t)
  (outline-path "" :type string :read-only t)
  (category "" :type string :read-only t)
  (task-state nil :type (or null string) :read-only t)
  (inherited-tags nil :type list :read-only t))

(defun archive-context-safe-text-p (value &key (allow-empty-p t))
  (and (stringp value)
       (or allow-empty-p (plusp (length value)))
       (<= (length value) 4096)
       (not (find-if (lambda (character)
                       (member character '(#\Null #\Newline #\Return)))
                     value))))

(defun make-archive-context
    (&key timestamp source-id (outline-path "") (category "") task-state
          (inherited-tags nil))
  "Create bounded format-neutral provenance for one archived subtree."
  (unless (and (archive-context-safe-text-p timestamp :allow-empty-p nil)
               (archive-context-safe-text-p source-id :allow-empty-p nil)
               (archive-context-safe-text-p outline-path)
               (archive-context-safe-text-p category)
               (or (null task-state)
                   (archive-context-safe-text-p task-state
                                                :allow-empty-p nil))
               (proper-list-p inherited-tags)
               (<= (length inherited-tags) 64)
               (every (lambda (tag)
                        (archive-context-safe-text-p tag :allow-empty-p nil))
                      inherited-tags)
               (= (length inherited-tags)
                  (length (remove-duplicates inherited-tags :test #'string=))))
    (model-error :invalid-archive-context
                 (list timestamp source-id outline-path category task-state
                       inherited-tags)
                 "archive context must contain bounded single-line provenance"))
  (%make-archive-context
   (copy-seq timestamp) (copy-seq source-id) (copy-seq outline-path)
   (copy-seq category) (and task-state (copy-seq task-state))
   (mapcar #'copy-seq inherited-tags)))

(defstruct (edit-plan
            (:constructor %make-edit-plan
                (provider source-id base-revision base-content-fingerprint
                 base-metadata-fingerprint operations metadata)))
  (provider nil :type source-provider :read-only t)
  (source-id "" :type string :read-only t)
  (base-revision "" :type string :read-only t)
  (base-content-fingerprint "" :type string :read-only t)
  (base-metadata-fingerprint "" :type string :read-only t)
  (operations nil :type list :read-only t)
  (metadata nil :type list :read-only t))

(defun make-edit-plan
    (&key provider source-id base-revision base-content-fingerprint operations
          base-metadata-fingerprint (metadata nil))
  (unless (typep provider 'source-provider)
    (model-error :invalid-source-provider provider
                 "edit plan provider must be a source provider"))
  (require-non-empty-string source-id :invalid-source-id "edit source ID")
  (require-non-empty-string base-revision :invalid-source-revision
                            "edit base revision")
  (require-non-empty-string base-content-fingerprint
                            :invalid-content-fingerprint
                            "edit base content fingerprint")
  (require-non-empty-string base-metadata-fingerprint
                            :invalid-metadata-fingerprint
                            "edit base metadata fingerprint")
  (let ((operations (copy-proper-list operations :invalid-edit-operations
                                      "edit operations"))
        (metadata (copy-proper-list metadata :invalid-edit-metadata
                                    "edit metadata")))
    (unless operations
      (model-error :empty-edit-plan operations
                   "an edit plan must contain at least one operation"))
    (unless (every #'edit-operation-p operations)
      (model-error :invalid-edit-operation operations
                   "every edit plan operation must be an edit operation"))
    (%make-edit-plan provider source-id base-revision
                     base-content-fingerprint base-metadata-fingerprint
                     operations metadata)))

(defstruct (source-archive-plan
            (:constructor %make-source-archive-plan
                (provider source-node-id context source-plan destination-plan
                 destination-created-p)))
  (provider nil :type source-provider :read-only t)
  (source-node-id "" :type string :read-only t)
  (context nil :type archive-context :read-only t)
  (source-plan nil :type edit-plan :read-only t)
  (destination-plan nil :type edit-plan :read-only t)
  (destination-created-p nil :type boolean :read-only t))

(defun make-source-archive-plan
    (&key provider source-node-id context source-plan destination-plan
          (destination-created-p nil))
  (unless (and (typep provider 'source-provider)
               (archive-context-p context)
               (edit-plan-p source-plan)
               (edit-plan-p destination-plan)
               (eq provider (edit-plan-provider source-plan))
               (eq provider (edit-plan-provider destination-plan))
               (member destination-created-p '(nil t))
               (not (string= (edit-plan-source-id source-plan)
                             (edit-plan-source-id destination-plan))))
    (model-error :invalid-source-archive-plan
                 (list provider source-plan destination-plan)
                 "archive plan requires two distinct exact plans for one provider"))
  (require-non-empty-string source-node-id :invalid-archive-source-node-id
                            "archive source node ID")
  (%make-source-archive-plan
   provider (copy-seq source-node-id) context source-plan destination-plan
   destination-created-p))

(defgeneric plan-source-archive
    (provider source-snapshot source-node-id destination-snapshot context
     &key &allow-other-keys)
  (:documentation
   "Plan one exact cross-source archive without mutating either snapshot."))

(defgeneric apply-source-archive
    (provider plan source-snapshot destination-snapshot
     &key source-revision destination-revision &allow-other-keys)
  (:documentation
   "Apply an exact archive plan in memory and return source then destination."))

(defun archived-subtree-node-shape (document node)
  "Return the expected top-level archive hierarchy for NODE's subtree."
  (let ((delta (- 1 (semantic-node-level node))))
    (loop :for candidate :in (semantic-node-subtree-nodes document node)
          :collect
          (list (semantic-node-id candidate)
                (+ delta (semantic-node-level candidate))
                (if (eq candidate node)
                    nil
                    (semantic-node-parent-id candidate))
                (semantic-node-title candidate)))))

(defun archive-append-payload-values (payload)
  (unless (and (proper-list-p payload) (evenp (length payload)))
    (model-error :invalid-archive-append-payload payload
                 "archive append payload must be one bounded property list"))
  (let ((keys (loop :for tail :on payload :by #'cddr :collect (first tail)))
        (entry-source (getf payload :entry-source))
        (node-shape (getf payload :node-shape)))
    (unless (and (= (length keys) (length (remove-duplicates keys)))
                 (equal (sort (copy-list keys) #'string-lessp
                              :key #'symbol-name)
                        '(:ENTRY-SOURCE :NODE-SHAPE))
                 (stringp entry-source) (plusp (length entry-source))
                 (<= (length entry-source) (* 1024 1024))
                 (proper-list-p node-shape) node-shape
                 (every
                  (lambda (item)
                    (and (proper-list-p item) (= 4 (length item))
                         (stringp (first item)) (plusp (length (first item)))
                         (integerp (second item)) (plusp (second item))
                         (or (null (third item))
                             (and (stringp (third item))
                                  (plusp (length (third item)))))
                         (stringp (fourth item))))
                  node-shape))
      (model-error :invalid-archive-append-payload payload
                   "archive append payload has invalid source or hierarchy"))
    (values entry-source node-shape)))

(defun source-with-archive-entry (source entry-source)
  "Return SOURCE with ENTRY-SOURCE separated as one final top-level subtree."
  (let* ((prototype (if (plusp (length source)) source entry-source))
         (newline
           (ecase (source-newline-style prototype)
             (:lf (string #\Newline))
             (:cr (string #\Return))
             (:crlf (format nil "~c~c" #\Return #\Newline))))
         (source-newline-p
           (and (plusp (length source))
                (member (char source (1- (length source)))
                        '(#\Newline #\Return))))
         (entry-newline-p
           (and (plusp (length entry-source))
                (member (char entry-source (1- (length entry-source)))
                        '(#\Newline #\Return))))
         (prefix
           (cond
             ((zerop (length source)) "")
             (source-newline-p newline)
             (t (concatenate 'string newline newline)))))
    (concatenate 'string source prefix entry-source
                 (if entry-newline-p "" newline))))

(defun make-archive-destination-plan
    (provider destination-snapshot operation destination-source)
  "Return the exact append plan for one already-rendered archive entry."
  (multiple-value-bind (entry-source node-shape)
      (archive-append-payload-values (edit-operation-payload operation))
    (let ((document (source-snapshot-document destination-snapshot)))
      (dolist (item node-shape)
        (when (find-semantic-node document (first item))
          (model-error :duplicate-archive-destination-node (first item)
                       "archive destination already contains a moved node")))
      (let* ((updated-source
               (source-with-archive-entry destination-source entry-source))
             (position (length destination-source))
             (replacement (subseq updated-source position)))
        (make-edit-plan
         :provider provider
         :source-id (source-snapshot-source-id destination-snapshot)
         :base-revision (source-snapshot-revision destination-snapshot)
         :base-content-fingerprint
         (source-snapshot-content-fingerprint destination-snapshot)
         :base-metadata-fingerprint
         (source-snapshot-metadata-fingerprint destination-snapshot)
         :operations (list operation)
         :metadata
         (list :patch-start position :patch-end position
               :replacement replacement
               :expected-archived-nodes (copy-tree node-shape)))))))

(defun make-provider-source-archive-plan
    (provider source-snapshot node destination-snapshot context entry-source
     destination-source &key destination-created-p)
  "Assemble exact source deletion and destination append plans."
  (unless (and (eq provider (source-snapshot-provider source-snapshot))
               (eq provider (source-snapshot-provider destination-snapshot))
               (string= (archive-context-source-id context)
                        (source-snapshot-source-id source-snapshot)))
    (model-error :mismatched-archive-snapshots
                 (list source-snapshot destination-snapshot context)
                 "archive snapshots and context must belong to one provider"))
  (let* ((node-shape
           (archived-subtree-node-shape
            (source-snapshot-document source-snapshot) node))
         (source-operation
           (make-edit-operation :kind :delete-node-subtree
                                :target-id (semantic-node-id node)
                                :payload nil))
         (destination-operation
           (make-edit-operation
            :kind :append-archived-subtree
            :target-id (semantic-node-id node)
            :payload (list :entry-source entry-source
                           :node-shape node-shape)))
         (source-plan
           (plan-source-edit provider source-snapshot source-operation))
         (destination-plan
           (make-archive-destination-plan
            provider destination-snapshot destination-operation
            destination-source)))
    (make-source-archive-plan
     :provider provider :source-node-id (semantic-node-id node)
     :context context :source-plan source-plan
     :destination-plan destination-plan
     :destination-created-p destination-created-p)))

(defun archived-node-shape-present-p (snapshot shape)
  (every
   (lambda (item)
     (destructuring-bind (node-id level parent-id title) item
       (let ((node
               (find-semantic-node
                (source-snapshot-document snapshot) node-id)))
         (and node (= level (semantic-node-level node))
              (equal parent-id (semantic-node-parent-id node))
              (string= title (semantic-node-title node))))))
   shape))

(defmethod apply-source-archive
    ((provider source-provider) plan source-snapshot destination-snapshot
     &key source-revision destination-revision &allow-other-keys)
  (unless (and (source-archive-plan-p plan)
               (eq provider (source-archive-plan-provider plan))
               (eq provider (source-snapshot-provider source-snapshot))
               (eq provider (source-snapshot-provider destination-snapshot)))
    (model-error :invalid-source-archive-application plan
                 "archive application requires its exact provider snapshots"))
  (require-non-empty-string source-revision :invalid-source-revision
                            "archive source successor revision")
  (require-non-empty-string destination-revision :invalid-source-revision
                            "archive destination successor revision")
  (let ((canonical
          (plan-source-archive
           provider source-snapshot
           (source-archive-plan-source-node-id plan)
           destination-snapshot (source-archive-plan-context plan)
           :destination-created-p
           (source-archive-plan-destination-created-p plan))))
    (unless (and
             (equalp (source-archive-plan-source-plan plan)
                     (source-archive-plan-source-plan canonical))
             (equalp (source-archive-plan-destination-plan plan)
                     (source-archive-plan-destination-plan canonical)))
      (model-error :invalid-source-archive-plan plan
                   "archive plan does not match its exact two-source bases")))
  (let* ((destination
           (apply-source-edit
            provider (source-archive-plan-destination-plan plan)
            destination-snapshot :new-revision destination-revision))
         (source
           (apply-source-edit
            provider (source-archive-plan-source-plan plan)
            source-snapshot :new-revision source-revision))
         (shape
           (getf
            (edit-plan-metadata
             (source-archive-plan-destination-plan plan))
            :expected-archived-nodes)))
    (when (find-semantic-node
           (source-snapshot-document source)
           (source-archive-plan-source-node-id plan))
      (model-error :inconsistent-source-archive-deletion plan
                   "archive source retained the moved root"))
    (unless (archived-node-shape-present-p destination shape)
      (model-error :inconsistent-source-archive-destination plan
                   "archive destination lost the moved hierarchy"))
    (values source destination)))

(defmethod enumerate-nodes ((provider source-provider)
                            (snapshot source-snapshot))
  (unless (eq provider (source-snapshot-provider snapshot))
    (error 'source-adapter-error
           :provider provider
           :message "snapshot belongs to a different provider"))
  (copy-list (semantic-document-nodes
              (source-snapshot-document snapshot))))

(defmethod enumerate-tasks ((provider source-provider)
                            (snapshot source-snapshot))
  (remove-if-not #'semantic-node-task
                 (enumerate-nodes provider snapshot)))

(defmethod resolve-node ((provider source-provider)
                         (snapshot source-snapshot) node-id)
  (unless (eq provider (source-snapshot-provider snapshot))
    (error 'source-adapter-error
           :provider provider
           :message "snapshot belongs to a different provider"))
  (let ((node (find-semantic-node (source-snapshot-document snapshot) node-id)))
    (when node
      (make-source-location
       :source-id (source-snapshot-source-id snapshot)
       :node-id node-id
       :revision (source-snapshot-revision snapshot)
       :span (semantic-node-span node)))))

(defun assert-edit-plan-current (plan snapshot)
  "Return true when PLAN can safely target SNAPSHOT; otherwise signal stale."
  (unless (and (edit-plan-p plan) (source-snapshot-p snapshot))
    (error 'source-adapter-error
           :provider nil
           :message "staleness check requires an edit plan and snapshot"))
  (unless (and (eq (edit-plan-provider plan)
                   (source-snapshot-provider snapshot))
               (string= (edit-plan-source-id plan)
                        (source-snapshot-source-id snapshot)))
    (error 'source-adapter-error
           :provider (edit-plan-provider plan)
           :message "edit plan and snapshot identify different sources"))
  (unless (and (string= (edit-plan-base-revision plan)
                        (source-snapshot-revision snapshot))
               (string= (edit-plan-base-content-fingerprint plan)
                        (source-snapshot-content-fingerprint snapshot))
               (string= (edit-plan-base-metadata-fingerprint plan)
                        (source-snapshot-metadata-fingerprint snapshot)))
    (error 'stale-source
           :provider (edit-plan-provider plan)
           :message "source changed after edit planning"
           :expected-revision (edit-plan-base-revision plan)
           :actual-revision (source-snapshot-revision snapshot)
           :expected-fingerprint (edit-plan-base-content-fingerprint plan)
           :actual-fingerprint
           (source-snapshot-content-fingerprint snapshot)
           :expected-metadata-fingerprint
           (edit-plan-base-metadata-fingerprint plan)
           :actual-metadata-fingerprint
           (source-snapshot-metadata-fingerprint snapshot)))
  t)
