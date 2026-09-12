(eval-when (:compile-toplevel :load-toplevel :execute)
  #+(and sbcl unix) (require :sb-posix))

(in-package #:lem-structured-notes)

(define-condition migration-error (error)
  ((message
    :initarg :message
    :reader migration-error-message))
  (:report
   (lambda (condition stream)
     (format stream "Migration error: ~a" (migration-error-message condition)))))

(define-condition migration-equivalence-error (migration-error)
  ((source-document
    :initarg :source-document)
   (preview-document
    :initarg :preview-document)))

(define-condition migration-target-exists (migration-error)
  ((target-id
    :initarg :target-id
    :reader migration-target-exists-target-id))
  (:report
   (lambda (condition stream)
     (format stream "Refusing to overwrite migration target ~s"
             (migration-target-exists-target-id condition)))))

(defun equivalent-list-p (left right predicate)
  (and (= (length left) (length right))
       (every predicate left right)))

(defun temporal-value-equivalent-p (left right)
  (or (and (null left) (null right))
      (and (temporal-value-p left)
           (temporal-value-p right)
           (eq (temporal-value-kind left) (temporal-value-kind right))
           (string= (temporal-value-local-value left)
                    (temporal-value-local-value right))
           (equal (temporal-value-timezone-id left)
                  (temporal-value-timezone-id right))
           (eql (temporal-value-fold left) (temporal-value-fold right))
           (eq (temporal-value-gap-policy left)
               (temporal-value-gap-policy right))
           (eq (temporal-value-precision left)
               (temporal-value-precision right)))))

(defun recurrence-date-equivalent-p (left right)
  (or (temporal-value-equivalent-p left right)
      (and (recurrence-period-p left)
           (recurrence-period-p right)
           (temporal-value-equivalent-p
            (recurrence-period-start left)
            (recurrence-period-start right))
           (temporal-value-equivalent-p
            (recurrence-period-end left)
            (recurrence-period-end right))
           (equal (recurrence-period-duration left)
                  (recurrence-period-duration right)))))

(defun recurrence-equivalent-p (left right)
  (or (and (null left) (null right))
      (and (recurrence-p left)
           (recurrence-p right)
           (equal (recurrence-rules left) (recurrence-rules right))
           (equivalent-list-p (recurrence-dates left)
                              (recurrence-dates right)
                              #'recurrence-date-equivalent-p)
           (equivalent-list-p (recurrence-exception-dates left)
                              (recurrence-exception-dates right)
                              #'temporal-value-equivalent-p)
           (eq (recurrence-policy left) (recurrence-policy right)))))

(defun task-facet-equivalent-p (left right)
  (or (and (null left) (null right))
      (and (task-facet-p left)
           (task-facet-p right)
           (string= (task-facet-workflow-id left)
                    (task-facet-workflow-id right))
           (string= (task-facet-state left) (task-facet-state right))
           (eql (task-facet-done-p left) (task-facet-done-p right))
           (equal (task-facet-priority left) (task-facet-priority right))
           (eql (task-facet-progress left) (task-facet-progress right))
           (equal (task-facet-effort left) (task-facet-effort right))
           (temporal-value-equivalent-p (task-facet-scheduled left)
                                        (task-facet-scheduled right))
           (equal (task-facet-scheduled-delay left)
                  (task-facet-scheduled-delay right))
           (temporal-value-equivalent-p (task-facet-deadline left)
                                        (task-facet-deadline right))
           (temporal-value-equivalent-p (task-facet-closed left)
                                        (task-facet-closed right))
           (equal (task-facet-deadline-warning left)
                  (task-facet-deadline-warning right))
           (recurrence-equivalent-p (task-facet-recurrence left)
                                    (task-facet-recurrence right))
           (equalp (task-facet-dependencies left)
                   (task-facet-dependencies right))
           (equalp (task-facet-logs left) (task-facet-logs right)))))

(defun event-facet-equivalent-p (left right)
  (or (and (null left) (null right))
      (and (event-facet-p left)
           (event-facet-p right)
           (temporal-value-equivalent-p (event-facet-start left)
                                        (event-facet-start right))
           (temporal-value-equivalent-p (event-facet-end left)
                                        (event-facet-end right))
           (equal (event-facet-duration left) (event-facet-duration right))
           (equal (event-facet-status left) (event-facet-status right))
           (equal (event-facet-location left) (event-facet-location right))
           (equal (event-facet-url left) (event-facet-url right))
           (eq (event-facet-transparency left)
               (event-facet-transparency right))
           (recurrence-equivalent-p (event-facet-recurrence left)
                                    (event-facet-recurrence right)))))

(defun content-node-equivalent-p (left right)
  (and (content-node-p left)
       (content-node-p right)
       (eq (content-node-kind left) (content-node-kind right))
       (equal (content-node-name left) (content-node-name right))
       (equalp (content-node-attributes left)
               (content-node-attributes right))
       (cond
         ((or (content-node-code-block left)
              (content-node-code-block right))
          (and (content-node-code-block left)
               (content-node-code-block right)
               (code-block-data-equivalent-p
                (content-node-code-block left)
                (content-node-code-block right))))
         ((or (content-node-table left) (content-node-table right))
          (and (content-node-table left)
               (content-node-table right)
               (table-data-equivalent-p (content-node-table left)
                                        (content-node-table right))))
         ((or (content-node-items left) (content-node-items right))
          (and (content-node-items left)
               (content-node-items right)
               (list-items-equivalent-p (content-node-items left)
                                        (content-node-items right))))
         ((or (content-node-inlines left) (content-node-inlines right))
          (and (content-node-inlines left)
               (content-node-inlines right)
               (inline-nodes-equivalent-p (content-node-inlines left)
                                          (content-node-inlines right))))
         ((or (content-node-text left) (content-node-text right))
          (and (content-node-text left)
               (content-node-text right)
               (string= (content-node-text left)
                        (content-node-text right))))
         (t
          (and (eq (content-node-source-format left)
                   (content-node-source-format right))
               (string= (content-node-raw left)
                        (content-node-raw right)))))))

(defun calendar-binding-equivalent-p (left right)
  (and (calendar-binding-p left)
       (calendar-binding-p right)
       (string= (calendar-binding-id left) (calendar-binding-id right))
       (string= (calendar-binding-node-id left)
                (calendar-binding-node-id right))
       (eq (calendar-binding-projection-kind left)
           (calendar-binding-projection-kind right))
       (equal (calendar-binding-account-id left)
              (calendar-binding-account-id right))
       (equal (calendar-binding-calendar-id left)
              (calendar-binding-calendar-id right))
       (equal (calendar-binding-uid left) (calendar-binding-uid right))
       (temporal-value-equivalent-p (calendar-binding-recurrence-id left)
                                    (calendar-binding-recurrence-id right))
       (eq (calendar-binding-ownership left)
           (calendar-binding-ownership right))
       (eq (calendar-binding-write-policy left)
           (calendar-binding-write-policy right))))

(defun generated-lsm-evidence-p (extension)
  (let ((prefix "urn:lem:lsm:directive:")
        (namespace (opaque-extension-namespace extension)))
    (and (<= (length prefix) (length namespace))
         (string= prefix namespace :end2 (length prefix)))))

(defun opaque-extension-equivalent-p (left right)
  (and (opaque-extension-p left)
       (opaque-extension-p right)
       (string= (opaque-extension-namespace left)
                (opaque-extension-namespace right))
       (equal (opaque-extension-media-type left)
              (opaque-extension-media-type right))
       (equal (opaque-extension-owner-id left)
              (opaque-extension-owner-id right))
       (equalp (opaque-extension-raw-value left)
               (opaque-extension-raw-value right))
       (equalp (opaque-extension-ordering-anchor left)
               (opaque-extension-ordering-anchor right))
       (equalp (opaque-extension-provenance left)
               (opaque-extension-provenance right))))

(defun extensions-equivalent-p (left right)
  (let ((left (remove-if #'generated-lsm-evidence-p left))
        (right (remove-if #'generated-lsm-evidence-p right)))
    (equivalent-list-p left right #'opaque-extension-equivalent-p)))

(defun semantic-node-equivalent-p (left right)
  (and (semantic-node-p left)
       (semantic-node-p right)
       (string= (semantic-node-id left) (semantic-node-id right))
       (= (semantic-node-level left) (semantic-node-level right))
       (string= (semantic-node-title left) (semantic-node-title right))
       (equivalent-list-p (semantic-node-body left)
                          (semantic-node-body right)
                          #'content-node-equivalent-p)
       (equal (semantic-node-parent-id left)
              (semantic-node-parent-id right))
       (equal (semantic-node-child-ids left)
              (semantic-node-child-ids right))
       (equal (semantic-node-aliases left) (semantic-node-aliases right))
       (equalp (semantic-node-references left)
               (semantic-node-references right))
       (equal (semantic-node-tags left) (semantic-node-tags right))
       (equalp (semantic-node-properties left)
               (semantic-node-properties right))
       (event-facet-equivalent-p (semantic-node-event left)
                                 (semantic-node-event right))
       (task-facet-equivalent-p (semantic-node-task left)
                                (semantic-node-task right))
       (equivalent-list-p (semantic-node-inactive-dates left)
                          (semantic-node-inactive-dates right)
                          #'recurrence-date-equivalent-p)
       (equivalent-list-p (semantic-node-calendar-bindings left)
                          (semantic-node-calendar-bindings right)
                          #'calendar-binding-equivalent-p)
       (extensions-equivalent-p (semantic-node-extensions left)
                                (semantic-node-extensions right))))

(defun semantic-document-equivalent-p (left right)
  "Whether LEFT and RIGHT have the same user-visible neutral semantics.

Source location, syntax profile, revision, diagnostics, and generated LSM
directive evidence are deliberately excluded. All renderable semantic fields
are compared, including exact opaque Org content."
  (and (semantic-document-p left)
       (semantic-document-p right)
       (string= (semantic-document-id left) (semantic-document-id right))
       (equivalent-list-p (semantic-document-preamble left)
                          (semantic-document-preamble right)
                          #'content-node-equivalent-p)
       (equalp (semantic-document-metadata left)
               (semantic-document-metadata right))
       (equivalent-list-p (semantic-document-nodes left)
                          (semantic-document-nodes right)
                          #'semantic-node-equivalent-p)
       (equal (semantic-document-root-ids left)
              (semantic-document-root-ids right))
       (eq (semantic-document-newline left)
           (semantic-document-newline right))
       (eq (semantic-document-encoding left)
           (semantic-document-encoding right))
       (extensions-equivalent-p (semantic-document-extensions left)
                                (semantic-document-extensions right))))

(defstruct (migration-report
            (:constructor %make-migration-report
                (status disposition source-id target-id node-count task-count
                 opaque-content-count diagnostics loss-risk-counts)))
  (status :ready :type keyword :read-only t)
  (disposition :write-new-file :type keyword :read-only t)
  (source-id "" :type string :read-only t)
  (target-id "" :type string :read-only t)
  (node-count 0 :type (integer 0) :read-only t)
  (task-count 0 :type (integer 0) :read-only t)
  (opaque-content-count 0 :type (integer 0) :read-only t)
  (diagnostics nil :type list :read-only t)
  (loss-risk-counts nil :type list :read-only t))

(defstruct (migration-plan
            (:constructor %make-migration-plan
                (source-snapshot target-id target-source preview-snapshot
                 report)))
  (source-snapshot nil :type source-snapshot :read-only t)
  (target-id "" :type string :read-only t)
  (target-source "" :type string :read-only t)
  (preview-snapshot nil :type source-snapshot :read-only t)
  (report nil :type migration-report :read-only t))

(defun document-content-nodes (document)
  (append (semantic-document-preamble document)
          (loop :for node :in (semantic-document-nodes document)
                :append (semantic-node-body node))))

(defun diagnostic-risk-counts (diagnostics)
  (loop :for risk :in '(:none :approximation :loss :security)
        :collect (cons risk
                       (count risk diagnostics
                              :key #'diagnostic-loss-risk :test #'eq))))

(defun risky-diagnostics-p (diagnostics)
  (some (lambda (diagnostic)
          (not (eq :none (diagnostic-loss-risk diagnostic))))
        diagnostics))

(defun plan-lsm-migration (snapshot target-id)
  "Dry-run SNAPSHOT into canonical LSM, reparse it, and prove equivalence."
  (unless (source-snapshot-p snapshot)
    (error 'migration-error :message "migration planning requires a source snapshot"))
  (require-non-empty-string target-id :invalid-migration-target
                            "migration target ID")
  (when (string= target-id (source-snapshot-source-id snapshot))
    (error 'migration-error
           :message "migration target must differ from the source ID"))
  (let* ((source-document (source-snapshot-document snapshot))
         (target-source (render-lsm-document source-document))
         (provider (make-instance 'lsm-provider))
         (preview
           (parse-source provider target-source
                         :source-id target-id
                         :revision "migration-preview/1"))
         (preview-document (source-snapshot-document preview)))
    (unless (semantic-document-equivalent-p source-document preview-document)
      (error 'migration-equivalence-error
             :message "rendered LSM did not preserve neutral document semantics"
             :source-document source-document
             :preview-document preview-document))
    (let* ((diagnostics
             (append (copy-list (source-snapshot-diagnostics snapshot))
                     (copy-list (source-snapshot-diagnostics preview))))
           (opaque-count
             (count-if #'canonical-lsm-opaque-content-p
                       (document-content-nodes source-document)))
           (status
             (cond
               ((risky-diagnostics-p diagnostics) :review-required)
               ((plusp opaque-count) :ready-with-opaque-content)
               (t :ready)))
           (report
             (%make-migration-report
              status :write-new-file
              (source-snapshot-source-id snapshot) target-id
              (length (semantic-document-nodes source-document))
              (count-if #'semantic-node-task
                        (semantic-document-nodes source-document))
              opaque-count diagnostics
              (diagnostic-risk-counts diagnostics))))
      (%make-migration-plan snapshot target-id target-source preview report))))

(defun assert-migration-plan-current (plan current-snapshot)
  "Return true if CURRENT-SNAPSHOT is exactly the source used for PLAN."
  (unless (and (migration-plan-p plan)
               (source-snapshot-p current-snapshot))
    (error 'migration-error
           :message "staleness check requires a migration plan and source snapshot"))
  (let ((base (migration-plan-source-snapshot plan)))
    (unless (and (eq (source-snapshot-provider base)
                     (source-snapshot-provider current-snapshot))
                 (string= (source-snapshot-source-id base)
                          (source-snapshot-source-id current-snapshot)))
      (error 'migration-error
             :message "migration plan and snapshot identify different sources"))
    (unless (and (string= (source-snapshot-revision base)
                          (source-snapshot-revision current-snapshot))
                 (string= (source-snapshot-content-fingerprint base)
                          (source-snapshot-content-fingerprint current-snapshot))
                 (string= (source-snapshot-metadata-fingerprint base)
                          (source-snapshot-metadata-fingerprint current-snapshot)))
      (error 'stale-source
             :provider (source-snapshot-provider base)
             :message "source changed after migration planning"
             :expected-revision (source-snapshot-revision base)
             :actual-revision (source-snapshot-revision current-snapshot)
             :expected-fingerprint (source-snapshot-content-fingerprint base)
             :actual-fingerprint
             (source-snapshot-content-fingerprint current-snapshot)
             :expected-metadata-fingerprint
             (source-snapshot-metadata-fingerprint base)
             :actual-metadata-fingerprint
             (source-snapshot-metadata-fingerprint current-snapshot))))
  t)

(defun ensure-migration-plan-applicable (plan)
  (when (eq :review-required
            (migration-report-status (migration-plan-report plan)))
    (error 'migration-error
           :message "migration diagnostics require review before application"))
  plan)

(defun apply-migration-plan-to-stream (plan current-snapshot stream)
  "Write PLAN to STREAM only after checking the current source snapshot."
  (unless (and (streamp stream) (output-stream-p stream))
    (error 'migration-error :message "migration target must be an output stream"))
  (assert-migration-plan-current plan current-snapshot)
  (ensure-migration-plan-applicable plan)
  (write-string (migration-plan-target-source plan) stream)
  (finish-output stream)
  (migration-plan-report plan))

(defun migration-target-pathname (plan)
  (handler-case
      (uiop:ensure-absolute-pathname
       (pathname (migration-plan-target-id plan)) (uiop:getcwd))
    (error ()
      (error 'migration-error
             :message "migration target ID is not a valid file pathname"))))

(defun signal-existing-migration-target (plan)
  (error 'migration-target-exists
         :message "migration output is create-only"
         :target-id (migration-plan-target-id plan)))

(defvar *migration-file-boundary-hook*
  (lambda (boundary target)
    (declare (ignore boundary target))))

(defun call-migration-file-boundary-hook (boundary target)
  (funcall *migration-file-boundary-hook* boundary target))

(defun migration-directory-pathname (target)
  (uiop:pathname-directory-pathname target))

#+(and sbcl unix)
(defun migration-native-namestring (pathname)
  (uiop:native-namestring pathname))

#+(and sbcl unix)
(defun migration-lstat-if-present (pathname)
  (handler-case
      (sb-posix:lstat (migration-native-namestring pathname))
    (sb-posix:syscall-error (condition)
      (if (= (sb-posix:syscall-errno condition) sb-posix:enoent)
          nil
          (error condition)))))

#+(and sbcl unix)
(defun migration-stat-signature (stat)
  (list (sb-posix:stat-dev stat)
        (sb-posix:stat-ino stat)
        (sb-posix:stat-mode stat)
        (sb-posix:stat-uid stat)
        (sb-posix:stat-nlink stat)
        (sb-posix:stat-size stat)
        (sb-posix:stat-mtime stat)
        (sb-posix:stat-ctime stat)))

#+(and sbcl unix)
(defun validate-migration-directory (directory)
  (let* ((native
           (string-right-trim '(#\/) (migration-native-namestring directory)))
         (stat (sb-posix:lstat (if (zerop (length native)) "/" native))))
    (unless (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                    sb-posix:s-ifdir)
                 (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                 (zerop (logand (sb-posix:stat-mode stat) #o022)))
      (error 'migration-error
             :message
             "migration target directory must be owned by this user, not a symlink, and not group/world writable")))
  directory)

#+(and sbcl unix)
(defun fsync-migration-directory (directory)
  (let ((descriptor nil))
    (unwind-protect
         (progn
           (setf descriptor
                 (sb-posix:open
                  (migration-native-namestring directory)
                  (logior sb-posix:o-rdonly sb-posix:o-nofollow) 0))
           (sb-posix:fsync descriptor))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor))))))

#+(and sbcl unix)
(defun migration-target-octets (plan)
  (sb-ext:string-to-octets (migration-plan-target-source plan)
                           :external-format :utf-8))

#+(and sbcl unix)
(defun migration-temporary-pathname (target)
  (uiop:parse-native-namestring
   (format nil "~a.lem-migration.~a.tmp"
           (migration-native-namestring target)
           (generate-caldav-opaque-resource-name))))

#+(and sbcl unix)
(defun write-migration-temporary-file (temporary octets)
  (let ((descriptor nil)
        (stream nil))
    (unwind-protect
         (progn
           (setf descriptor
                 (sb-posix:open
                  (migration-native-namestring temporary)
                  (logior sb-posix:o-creat sb-posix:o-excl
                          sb-posix:o-wronly sb-posix:o-nofollow)
                  #o600))
           (sb-posix:fchmod descriptor #o600)
           (setf stream
                 (sb-sys:make-fd-stream
                  descriptor :output t :element-type '(unsigned-byte 8)
                  :buffering :full
                  :name (migration-native-namestring temporary)))
           (write-sequence octets stream)
           (finish-output stream)
           (sb-posix:fsync descriptor)
           (close stream)
           (setf stream nil descriptor nil)
           temporary)
      (when stream
        (ignore-errors (close stream :abort t))
        (setf stream nil descriptor nil))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor))))))

#+(and sbcl unix)
(defun migration-target-exact-p (plan target expected)
  "Return whether TARGET is a stable, owner-controlled exact PLAN result.

The second value is the final file status, used to guard rollback."
  (let ((descriptor nil)
        (stream nil))
    (unwind-protect
         (progn
           (setf descriptor
                 (sb-posix:open
                  (migration-native-namestring target)
                  (logior sb-posix:o-rdonly sb-posix:o-nonblock
                          sb-posix:o-nofollow)
                  0))
           (let* ((before (sb-posix:fstat descriptor))
                  (path-before (sb-posix:lstat
                                (migration-native-namestring target)))
                  (signature (migration-stat-signature before)))
             (unless (and
                      (= (logand (sb-posix:stat-mode before) sb-posix:s-ifmt)
                         sb-posix:s-ifreg)
                      (= (sb-posix:stat-uid before) (sb-posix:getuid))
                      (equal signature
                             (migration-stat-signature path-before)))
               (signal-existing-migration-target plan))
             (unless (= (sb-posix:stat-size before) (length expected))
               (return-from migration-target-exact-p
                 (values nil before)))
             (let ((fd descriptor))
               (setf stream
                     (sb-sys:make-fd-stream
                      fd :input t :element-type '(unsigned-byte 8)
                      :buffering :full
                      :name (migration-native-namestring target))
                     descriptor nil)
               (let ((actual
                       (make-array (length expected)
                                   :element-type '(unsigned-byte 8)))
                     (count 0))
                 (loop :while (< count (length actual))
                       :for next := (read-sequence actual stream :start count)
                       :do (when (= next count)
                             (signal-existing-migration-target plan))
                           (setf count next))
                 (unless (eq :end-of-file
                             (read-byte stream nil :end-of-file))
                   (signal-existing-migration-target plan))
                 (let ((after (sb-posix:fstat fd))
                       (path-after
                         (sb-posix:lstat
                          (migration-native-namestring target))))
                   (unless (and
                            (equal signature
                                   (migration-stat-signature after))
                            (equal signature
                                   (migration-stat-signature path-after)))
                     (signal-existing-migration-target plan))
                   (values (equalp expected actual) after))))))
      (when stream
        (ignore-errors (close stream :abort t)))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor))))))

#+(and sbcl unix)
(defun publish-migration-plan-file (plan target directory expected)
  (let ((temporary (migration-temporary-pathname target))
        (temporary-created-p nil))
    (unwind-protect
         (progn
           (write-migration-temporary-file temporary expected)
           (setf temporary-created-p t)
           (call-migration-file-boundary-hook :temporary-fsynced target)
           (handler-case
               (sb-posix:link (migration-native-namestring temporary)
                              (migration-native-namestring target))
             (sb-posix:syscall-error (condition)
               (if (= (sb-posix:syscall-errno condition) sb-posix:eexist)
                   (signal-existing-migration-target plan)
                   (error condition))))
           (call-migration-file-boundary-hook :target-published target)
           (fsync-migration-directory directory)
           (call-migration-file-boundary-hook :directory-fsynced target)
           (sb-posix:unlink (migration-native-namestring temporary))
           (setf temporary-created-p nil)
           (fsync-migration-directory directory)
           (migration-plan-report plan))
      (when temporary-created-p
        (ignore-errors
          (sb-posix:unlink (migration-native-namestring temporary)))))))

(defun write-migration-plan-file (plan current-snapshot)
  "Durably create PLAN's complete target exactly once, without replacement."
  (assert-migration-plan-current plan current-snapshot)
  (ensure-migration-plan-applicable plan)
  #+(and sbcl unix)
  (let* ((target (migration-target-pathname plan))
         (directory (migration-directory-pathname target)))
    (handler-case
        (progn
          (validate-migration-directory directory)
          (when (migration-lstat-if-present target)
            (signal-existing-migration-target plan))
          (publish-migration-plan-file
           plan target directory (migration-target-octets plan)))
      (migration-error (condition)
        (error condition))
      (sb-posix:syscall-error (condition)
        (error 'migration-error
               :message (format nil "cannot publish migration target: ~a"
                                condition)))))
  #-(and sbcl unix)
  (error 'migration-error
         :message
         "durable migration file application requires SBCL POSIX primitives"))

(defun resume-migration-plan-file (plan current-snapshot)
  "Idempotently finish PLAN, accepting only an absent or byte-identical target.

Return the migration report and either :CREATED or :ALREADY-COMPLETE."
  (assert-migration-plan-current plan current-snapshot)
  (ensure-migration-plan-applicable plan)
  #+(and sbcl unix)
  (let* ((target (migration-target-pathname plan))
         (directory (migration-directory-pathname target))
         (expected (migration-target-octets plan)))
    (validate-migration-directory directory)
    (labels ((accept-existing-target ()
               (multiple-value-bind (exact-p stat)
                   (migration-target-exact-p plan target expected)
                 (declare (ignore stat))
                 (unless exact-p
                   (signal-existing-migration-target plan))
                 (values (migration-plan-report plan) :already-complete))))
      (if (migration-lstat-if-present target)
          (accept-existing-target)
          (handler-case
              (values (write-migration-plan-file plan current-snapshot)
                      :created)
            (migration-target-exists ()
              ;; Another process may have published this same plan after the
              ;; absence check. Accept it only after exact stable comparison.
              (accept-existing-target))))))
  #-(and sbcl unix)
  (error 'migration-error
         :message "migration resume requires SBCL POSIX primitives"))

(defun rollback-migration-plan-file (plan)
  "Remove only PLAN's stable, byte-identical, singly linked target.

Return :REMOVED or :ABSENT. Divergent, linked, non-regular, symlinked, or
foreign-owned targets are never removed."
  (unless (migration-plan-p plan)
    (error 'migration-error :message "migration rollback requires a plan"))
  #+(and sbcl unix)
  (let* ((target (migration-target-pathname plan))
         (directory (migration-directory-pathname target))
         (expected (migration-target-octets plan)))
    (validate-migration-directory directory)
    (unless (migration-lstat-if-present target)
      (return-from rollback-migration-plan-file :absent))
    (multiple-value-bind (exact-p stat)
        (migration-target-exact-p plan target expected)
      (unless (and exact-p (= 1 (sb-posix:stat-nlink stat)))
        (signal-existing-migration-target plan))
      (let ((current (sb-posix:lstat (migration-native-namestring target))))
        (unless (equal (migration-stat-signature stat)
                       (migration-stat-signature current))
          (signal-existing-migration-target plan)))
      (sb-posix:unlink (migration-native-namestring target))
      (call-migration-file-boundary-hook :target-unlinked target)
      (fsync-migration-directory directory)
      :removed))
  #-(and sbcl unix)
  (error 'migration-error
         :message "migration rollback requires SBCL POSIX primitives"))
