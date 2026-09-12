(in-package #:lem-structured-notes/tests)

(defclass fixture-provider (source-provider) ())

(defmethod source-provider-format ((provider fixture-provider))
  (declare (ignore provider))
  :org)

(defmethod source-provider-profile ((provider fixture-provider))
  (declare (ignore provider))
  "org/fixture-1")

(defmethod source-content-fingerprint ((provider fixture-provider) source)
  (declare (ignore provider))
  (format nil "fixture-content:~d" (length source)))

(defmethod source-metadata-fingerprint ((provider fixture-provider) source)
  (declare (ignore provider source))
  "fixture-metadata:1")

(defmethod parse-source ((provider fixture-provider) source
                         &key source-id revision)
  (declare (ignore source))
  (let ((document (fixture-document :revision revision)))
    (make-source-snapshot
     :provider provider
     :source-id source-id
     :revision revision
     :document document
     :content-fingerprint "fixture-content:1"
     :metadata-fingerprint "fixture-metadata:1")))

(defmethod plan-source-edit ((provider fixture-provider) snapshot operation
                             &key &allow-other-keys)
  (make-edit-plan
   :provider provider
   :source-id (source-snapshot-source-id snapshot)
   :base-revision (source-snapshot-revision snapshot)
   :base-content-fingerprint
   (source-snapshot-content-fingerprint snapshot)
   :base-metadata-fingerprint
   (source-snapshot-metadata-fingerprint snapshot)
   :operations (list operation)))

(defmethod apply-source-edit ((provider fixture-provider) plan current-snapshot
                              &key &allow-other-keys)
  (declare (ignore provider))
  (assert-edit-plan-current plan current-snapshot)
  :applied)

(defun fixture-snapshot (provider &key (revision "rev-1")
                                      (fingerprint "fixture-content:1")
                                      (metadata-fingerprint
                                        "fixture-metadata:1"))
  (make-source-snapshot
   :provider provider
   :source-id "fixture.org"
   :revision revision
   :document (fixture-document :revision revision)
   :content-fingerprint fingerprint
   :metadata-fingerprint metadata-fingerprint))

(define-foundation-test provider-default-enumeration-is-format-neutral
  (let* ((provider (make-instance 'fixture-provider))
         (snapshot (fixture-snapshot provider)))
    (assert-equal 2 (length (enumerate-nodes provider snapshot)))
    (assert-equal 1 (length (enumerate-tasks provider snapshot)))
    (assert-equal "node:child"
                  (semantic-node-id (first (enumerate-tasks provider snapshot)))
                  :test #'string=)))

(define-foundation-test resolution-is-bound-to-source-revision
  (let* ((provider (make-instance 'fixture-provider))
         (snapshot (fixture-snapshot provider))
         (location (resolve-node provider snapshot "node:child")))
    (assert-true location)
    (assert-equal "fixture.org" (source-location-source-id location)
                  :test #'string=)
    (assert-equal "rev-1" (source-location-revision location)
                  :test #'string=)
    (assert-true (source-location-span location))))

(define-foundation-test current-edit-plan-can-be-applied
  (let* ((provider (make-instance 'fixture-provider))
         (snapshot (fixture-snapshot provider))
         (operation
           (make-edit-operation :kind :set-task-state
                                :target-id "node:child"
                                :payload "DONE"))
         (plan (plan-source-edit provider snapshot operation)))
    (assert-true (assert-edit-plan-current plan snapshot))
    (assert-equal :applied (apply-source-edit provider plan snapshot))))

(define-foundation-test revision-change-refuses-edit-plan
  (let* ((provider (make-instance 'fixture-provider))
         (base (fixture-snapshot provider))
         (current (fixture-snapshot provider :revision "rev-2"))
         (plan
           (plan-source-edit
            provider base
            (make-edit-operation :kind :set-title
                                 :target-id "node:child"
                                 :payload "Changed"))))
    (let ((condition
            (assert-signals
             'stale-source
             (lambda () (apply-source-edit provider plan current)))))
      (assert-equal "rev-1" (stale-source-expected-revision condition)
                    :test #'string=)
      (assert-equal "rev-2" (stale-source-actual-revision condition)
                    :test #'string=))))

(define-foundation-test fingerprint-change-refuses-edit-plan
  (let* ((provider (make-instance 'fixture-provider))
         (base (fixture-snapshot provider))
         (current (fixture-snapshot provider
                                    :fingerprint "fixture-content:changed"))
         (plan
           (plan-source-edit
            provider base
            (make-edit-operation :kind :set-title
                                 :target-id "node:child"
                                 :payload "Changed"))))
    (assert-signals
     'stale-source
     (lambda () (apply-source-edit provider plan current)))))

(define-foundation-test metadata-change-refuses-edit-plan
  (let* ((provider (make-instance 'fixture-provider))
         (base (fixture-snapshot provider))
         (current (fixture-snapshot
                   provider :metadata-fingerprint "fixture-metadata:changed"))
         (plan
           (plan-source-edit
            provider base
            (make-edit-operation :kind :set-title
                                 :target-id "node:child"
                                 :payload "Changed"))))
    (assert-signals
     'stale-source
     (lambda () (apply-source-edit provider plan current)))))

(define-foundation-test provider-mismatch-refuses-resolution
  (let* ((owner (make-instance 'fixture-provider))
         (other (make-instance 'fixture-provider))
         (snapshot (fixture-snapshot owner)))
    (assert-signals
     'source-adapter-error
     (lambda () (enumerate-nodes other snapshot)))))

(define-foundation-test abstract-provider-fails-closed
  (let ((provider (make-instance 'source-provider)))
    (assert-signals
     'unsupported-source-operation
     (lambda ()
       (parse-source provider "" :source-id "empty" :revision "rev-1")))))
