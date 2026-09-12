(in-package #:lem-structured-notes)

(defstruct (caldav-write-representation-evidence
            (:constructor %make-caldav-write-representation-evidence
                (kind preference-evidence read-outcome diagnostics)))
  (kind :not-requested
        :type (member :not-requested :ignored :resource :invalid
                      :not-applicable)
        :read-only t)
  (preference-evidence nil
                       :type (or null caldav-return-preference-evidence)
                       :read-only t)
  (read-outcome nil :type (or null caldav-read-outcome) :read-only t)
  (diagnostics nil :type list :read-only t))

(defun caldav-write-preference-diagnostic (code message body-length)
  (make-diagnostic
   :severity :fatal :code code :message message :loss-risk :loss
   :span (make-source-span
          :source-id "caldav-write-return-representation"
          :character-start 0 :character-end 0
          :byte-start 0 :byte-end body-length)))

(defun caldav-write-representation-content-location-valid-p (intent headers)
  (let ((content-location
          (caldav-single-response-header headers "Content-Location"
                                         :validated-p t)))
    (or
     (null content-location)
     (handler-case
         (let ((resolved
                 (resolve-dav-href
                  (resolve-caldav-discovery-location
                   content-location (caldav-write-intent-href intent))
                  (caldav-write-intent-href intent)))
               (target
                 (resolve-dav-href (caldav-write-intent-href intent)
                                   (caldav-write-intent-href intent))))
           (and (dav-resolved-href-fetchable-p resolved)
                (equal (dav-resolved-href-resource-key resolved)
                       (dav-resolved-href-resource-key target))))
       (semantic-model-error () nil)))))

(defun classify-caldav-write-representation
    (intent status headers body-octets
     &key (max-body-octets 16777216))
  "Validate an applied RFC 8144 PUT representation through the GET boundary."
  (unless (caldav-write-intent-p intent)
    (model-error :invalid-caldav-write-intent intent
                 "returned representation requires its write intent"))
  (unless (vectorp body-octets)
    (model-error :invalid-caldav-response-body body-octets
                 "returned representation must be an octet vector"))
  (let ((body-length (length body-octets)))
    (handler-case
        (let* ((preference
                 (classify-caldav-return-preference
                  (caldav-write-intent-headers intent) headers))
               (application
                 (caldav-return-preference-evidence-kind preference)))
          (cond
            ((not (eq :representation
                      (caldav-write-intent-return-preference intent)))
             (%make-caldav-write-representation-evidence
              :not-requested preference nil nil))
            ((eq :ignored application)
             (%make-caldav-write-representation-evidence
              :ignored preference nil nil))
            ((not (eq :applied application))
             (%make-caldav-write-representation-evidence
              :invalid preference nil
              (list
               (caldav-write-preference-diagnostic
                :invalid-caldav-preference-application
                "response does not prove application of return=representation"
                body-length))))
            ((or (not (member (caldav-write-intent-operation intent)
                              '(:create :update)))
                 (not (member status '(200 201 412))))
             (%make-caldav-write-representation-evidence
              :not-applicable preference nil nil))
            ((not (caldav-write-representation-content-location-valid-p
                   intent headers))
             (%make-caldav-write-representation-evidence
              :invalid preference nil
              (list
               (caldav-write-preference-diagnostic
                :mismatched-caldav-representation-content-location
                "returned Content-Location does not identify the PUT resource"
                body-length))))
            (t
             (let ((outcome
                     (classify-caldav-get-response
                      (make-caldav-get-intent
                       :href (caldav-write-intent-href intent))
                      200 headers body-octets
                      :max-body-octets max-body-octets)))
               (if (and
                    (eq :resource (caldav-read-outcome-kind outcome))
                    (or
                     (null (caldav-write-intent-schedule-tag intent))
                     (caldav-read-outcome-schedule-tag outcome)))
                   (%make-caldav-write-representation-evidence
                    :resource preference outcome nil)
                   (%make-caldav-write-representation-evidence
                    :invalid preference outcome
                    (or
                     (copy-list (caldav-read-outcome-diagnostics outcome))
                     (list
                      (caldav-write-preference-diagnostic
                       :incomplete-caldav-returned-representation
                       "applied representation lacks complete validator evidence"
                       body-length)))))))))
      (semantic-model-error (condition)
        (%make-caldav-write-representation-evidence
         :invalid nil nil
         (list
          (caldav-write-preference-diagnostic
           (semantic-model-error-code condition)
           (semantic-model-error-message condition) body-length)))))))

(defun classify-caldav-write-response
    (intent status headers &optional (body-octets #()))
  "Classify a write and use a returned representation only when fully proven."
  (let* ((base (%classify-caldav-write-response intent status headers))
         (representation
           (classify-caldav-write-representation
            intent status headers body-octets)))
    (if (and
         (eq :success (caldav-write-outcome-kind base))
         (member (caldav-write-intent-operation intent) '(:create :update))
         (eq :representation (caldav-write-intent-return-preference intent))
         (member (caldav-write-representation-evidence-kind representation)
                 '(:ignored :invalid :not-applicable)))
        (%make-caldav-write-outcome
         (caldav-write-outcome-kind base)
         (caldav-write-outcome-status base)
         (caldav-write-outcome-entity-tag base)
         (caldav-write-outcome-schedule-tag base)
         (caldav-write-outcome-location base)
         t
         (caldav-write-outcome-conflict base))
        base)))

(defun caldav-write-returned-representation-input
    (intent response &key (max-body-octets 16777216))
  "Return the validated atomic representation input, or NIL for fallback."
  (unless (caldav-write-response-record-p response)
    (model-error :invalid-caldav-write-response-record response
                 "returned representation requires an exact durable response"))
  (let ((evidence
          (classify-caldav-write-representation
           intent
           (caldav-write-response-record-status response)
           (caldav-write-response-record-headers response)
           (caldav-write-response-record-body-octets response)
           :max-body-octets max-body-octets)))
    (and (eq :resource
             (caldav-write-representation-evidence-kind evidence))
         (caldav-read-outcome-calendar-input
          (caldav-write-representation-evidence-read-outcome evidence)))))

(defun caldav-write-conflict-returned-representation-input
    (intent response &key (max-body-octets 16777216))
  "Return a validated RFC 8144 412 current representation, or NIL.

The durable response remains a precondition conflict regardless of whether
the optional representation is usable. This function only supplies exact
current-server-state input to conflict handling; it never authorizes replay or
converts the failed write to success."
  (unless (caldav-write-response-record-p response)
    (model-error :invalid-caldav-write-response-record response
                 "conflict representation requires an exact durable response"))
  (unless (= 412 (caldav-write-response-record-status response))
    (model-error :invalid-caldav-write-conflict-response-status
                 (caldav-write-response-record-status response)
                 "conflict representation consumption requires status 412"))
  (caldav-write-returned-representation-input
   intent response :max-body-octets max-body-octets))
