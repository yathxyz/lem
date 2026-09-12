(in-package #:lem-structured-notes)

(defstruct (ical-effective-duration
            (:constructor %make-ical-effective-duration
                (kind seconds nominal-days nominal-subday-seconds)))
  (kind :exact :type (member :exact :nominal) :read-only t)
  (seconds 0 :type (integer 0) :read-only t)
  (nominal-days 0 :type (integer 0) :read-only t)
  (nominal-subday-seconds 0 :type (integer 0) :read-only t))

(defstruct (ical-recurrence-instance
            (:constructor %make-ical-recurrence-instance
                (recurrence-id actual-start actual-finish effective-duration
                 status item)))
  (recurrence-id nil :type temporal-value :read-only t)
  (actual-start nil :type (or null temporal-value) :read-only t)
  (actual-finish nil :type (or null temporal-value) :read-only t)
  (effective-duration nil :type (or null ical-effective-duration)
                      :read-only t)
  (status :generated :type keyword :read-only t)
  (item nil :type ical-calendar-item :read-only t))

(defstruct (ical-recurrence-series-expansion
            (:constructor %make-ical-recurrence-series-expansion
                (uid kind master instances)))
  (uid "" :type string :read-only t)
  (kind :event :type keyword :read-only t)
  (master nil :type ical-calendar-item :read-only t)
  (instances nil :type list :read-only t))

(defstruct (ical-rscale-family-rejection
            (:constructor %make-ical-rscale-family-rejection
                (uid kind recurrence-scale items)))
  (uid "" :type string :read-only t)
  (kind :event :type keyword :read-only t)
  (recurrence-scale "" :type string :read-only t)
  (items nil :type list :read-only t))

(defun ical-series-cancelled-p (item)
  (let ((status (ical-calendar-item-status item)))
    (and status (string-equal status "CANCELLED"))))

(defun ical-series-duration-value-seconds (duration)
  (* (ical-duration-value-sign duration)
     (+ (* (ical-duration-value-weeks duration) 7 86400)
        (* (ical-duration-value-days duration) 86400)
        (* (ical-duration-value-hours duration) 3600)
        (* (ical-duration-value-minutes duration) 60)
        (ical-duration-value-seconds duration))))

(defun ical-series-nominal-effective-duration (duration)
  (let ((days
          (+ (* (ical-duration-value-weeks duration) 7)
             (ical-duration-value-days duration)))
        (subday
          (+ (* (ical-duration-value-hours duration) 3600)
             (* (ical-duration-value-minutes duration) 60)
             (ical-duration-value-seconds duration))))
    (%make-ical-effective-duration
     :nominal (ical-series-duration-value-seconds duration) days subday)))

(defun ical-series-item-finish (item)
  (if (eq :event (ical-calendar-item-kind item))
      (ical-calendar-item-end item)
      (ical-calendar-item-due item)))

(defun ical-series-resolved-seconds
    (temporal timezone-provider &optional floating-timezone-id)
  (let ((normalized
          (ical-recurrence-normalize-explicit-leap-second
           temporal :timezone-provider timezone-provider
           :floating-timezone-id floating-timezone-id)))
    (case (temporal-value-kind normalized)
      (:zoned
        (unless timezone-provider
          (model-error :missing-series-timezone-provider normalized
                       "zoned instance duration requires a timezone provider"))
        (timezone-resolution-candidate-utc-seconds
         (select-timezone-resolution
          (resolve-zoned-local-time timezone-provider normalized)
          :fold (or (temporal-value-fold normalized) 0)
          :gap-policy (or (temporal-value-gap-policy normalized) :reject))))
      (:floating
       (if floating-timezone-id
           (progn
             (unless timezone-provider
               (model-error
                :missing-series-timezone-provider normalized
                "anchored floating instance arithmetic requires a timezone provider"))
             (timezone-resolution-candidate-utc-seconds
              (select-timezone-resolution
               (resolve-zoned-local-time
                timezone-provider
                (make-temporal-value
                 :kind :zoned
                 :local-value (temporal-value-local-value normalized)
                 :timezone-id floating-timezone-id
                 :precision (temporal-value-precision normalized)))
               :fold 0 :gap-policy :rfc5545)))
           (ical-recurrence-temporal-key normalized)))
      (:date
       (if floating-timezone-id
           (progn
             (unless timezone-provider
               (model-error
                :missing-series-timezone-provider normalized
                "anchored DATE instance arithmetic requires a timezone provider"))
             (timezone-resolution-candidate-utc-seconds
              (select-timezone-resolution
               (resolve-zoned-local-time
                timezone-provider
                (make-temporal-value
                 :kind :zoned
                 :local-value
                 (concatenate 'string
                              (temporal-value-local-value normalized)
                              "T00:00:00")
                 :timezone-id floating-timezone-id
                 :precision :second))
               :fold 0 :gap-policy :rfc5545)))
           (ical-recurrence-temporal-key normalized)))
      (otherwise
       (ical-recurrence-temporal-key normalized)))))

(defun ical-series-explicit-effective-duration
    (item timezone-provider floating-timezone-id)
  (cond
    ((ical-calendar-item-duration item)
     (ical-series-nominal-effective-duration
      (ical-calendar-item-duration item)))
    ((ical-series-item-finish item)
     (let ((effective-start
             (or (ical-calendar-item-start item)
                 (ical-calendar-item-recurrence-id item)))
           (finish (ical-series-item-finish item)))
       (unless (and effective-start
                    (ical-recurrence-compatible-temporal-p
                     effective-start finish))
         (model-error :incompatible-recurrence-instance-finish item
                      "instance finish must match its effective start kind and TZID"))
       (if (eq :date (temporal-value-kind effective-start))
           (let ((seconds
                   (- (ical-recurrence-temporal-key finish)
                      (ical-recurrence-temporal-key effective-start))))
             (when (minusp seconds)
               (model-error :negative-recurrence-instance-duration item
                            "instance finish must not precede its effective start"))
             (%make-ical-effective-duration
              :nominal seconds (truncate seconds 86400) 0))
           (let ((seconds
                   (- (ical-series-resolved-seconds
                       finish timezone-provider floating-timezone-id)
                      (ical-series-resolved-seconds
                       effective-start timezone-provider
                       floating-timezone-id))))
             (when (minusp seconds)
               (model-error :negative-recurrence-instance-duration item
                            "instance finish must not precede its effective start"))
             (%make-ical-effective-duration :exact seconds 0 0)))))
    (t nil)))

(defun ical-series-normalized-period-values
    (period timezone-provider floating-timezone-id)
  (values
   (ical-recurrence-normalize-explicit-leap-second
    (ical-period-value-start period)
    :timezone-provider timezone-provider
    :floating-timezone-id floating-timezone-id)
   (let ((finish (ical-period-value-end period)))
     (and finish
          (ical-recurrence-normalize-explicit-leap-second
           finish :timezone-provider timezone-provider
           :floating-timezone-id floating-timezone-id)))
   (ical-period-value-duration period)))

(defun ical-series-period-effective-duration
    (start finish duration timezone-provider)
  (if duration
      (ical-series-nominal-effective-duration duration)
      (let* ((seconds
               (- (ical-series-resolved-seconds finish timezone-provider)
                  (ical-series-resolved-seconds start timezone-provider))))
        (unless (plusp seconds)
          (model-error :non-positive-rdate-period-duration
                       (cons start finish)
                       "RDATE PERIOD end must resolve after its start"))
        (%make-ical-effective-duration :exact seconds 0 0))))

(defun ical-series-effective-duration-equal-p (left right)
  (and (eq (ical-effective-duration-kind left)
           (ical-effective-duration-kind right))
       (= (ical-effective-duration-seconds left)
          (ical-effective-duration-seconds right))
       (= (ical-effective-duration-nominal-days left)
          (ical-effective-duration-nominal-days right))
       (= (ical-effective-duration-nominal-subday-seconds left)
          (ical-effective-duration-nominal-subday-seconds right))))

(defun ical-series-period-duration-index
    (master timezone-provider floating-timezone-id)
  (let ((index (make-hash-table :test #'eql))
        (master-start (ical-calendar-item-start master)))
    (dolist (value (ical-calendar-item-recurrence-dates master))
      (when (ical-period-value-p value)
        (multiple-value-bind (start finish parsed-duration)
            (ical-series-normalized-period-values
             value timezone-provider floating-timezone-id)
          (let* ((key
                   (progn
                     (ical-recurrence-require-compatible
                      master-start start "RDATE PERIOD start")
                     (ical-recurrence-temporal-key start)))
                 (duration
                   (ical-series-period-effective-duration
                    start finish parsed-duration timezone-provider)))
            (multiple-value-bind (current present-p) (gethash key index)
              (when (and present-p
                         (not (ical-series-effective-duration-equal-p
                               current duration)))
                (model-error :conflicting-rdate-period-durations value
                             "RDATE PERIOD values for one start must have the same duration"))
              (setf (gethash key index) duration))))))
    index))

(defun ical-series-master-effective-duration
    (master timezone-provider floating-timezone-id)
  (or (ical-series-explicit-effective-duration
       master timezone-provider floating-timezone-id)
      (cond
        ((eq :event (ical-calendar-item-kind master))
         (if (eq :date
                 (temporal-value-kind (ical-calendar-item-start master)))
             (%make-ical-effective-duration :nominal 86400 1 0)
             (%make-ical-effective-duration :exact 0 0 0)))
        (t nil))))

(defun ical-series-item-effective-duration
    (item inherited-duration timezone-provider floating-timezone-id)
  (or (ical-series-explicit-effective-duration
       item timezone-provider floating-timezone-id)
      inherited-duration))

(defun ical-series-normalized-recurrence-id
    (item timezone-provider floating-timezone-id)
  (let ((recurrence-id (ical-calendar-item-recurrence-id item)))
    (and recurrence-id
         (ical-recurrence-normalize-explicit-leap-second
          recurrence-id :timezone-provider timezone-provider
          :floating-timezone-id floating-timezone-id))))

(defun ical-series-range-delta
    (override timezone-provider floating-timezone-id)
  (when (ical-series-cancelled-p override)
    (return-from ical-series-range-delta nil))
  (let* ((raw-actual (ical-calendar-item-start override))
         (actual
           (and raw-actual
                (ical-recurrence-normalize-explicit-leap-second
                 raw-actual :timezone-provider timezone-provider
                 :floating-timezone-id floating-timezone-id)))
        (identity
          (ical-series-normalized-recurrence-id
           override timezone-provider floating-timezone-id)))
    (unless actual
      (model-error :missing-ranged-override-start override
                   "non-cancelled THISANDFUTURE override requires DTSTART"))
    (unless (ical-recurrence-compatible-temporal-p identity actual)
      (model-error :incompatible-ranged-override-start override
                   "THISANDFUTURE DTSTART must match RECURRENCE-ID kind and TZID"))
    (- (ical-series-resolved-seconds
        actual timezone-provider floating-timezone-id)
       (ical-series-resolved-seconds
        identity timezone-provider floating-timezone-id))))

(defun ical-series-utc-temporal-from-seconds (seconds)
  (make-temporal-value
   :kind :utc
   :local-value (concatenate 'string (ical-local-string-from-seconds seconds) "Z")
   :precision :second))

(defun ical-series-zoned-shift (start seconds timezone-provider)
  (unless timezone-provider
    (model-error :missing-series-timezone-provider start
                 "zoned instance arithmetic requires a timezone provider"))
  (project-utc-time-to-zoned-local-time
   timezone-provider
   (ical-series-utc-temporal-from-seconds
    (+ (ical-series-resolved-seconds start timezone-provider) seconds))
   (temporal-value-timezone-id start)))

(defun ical-series-civil-shift (start seconds source overflow-code)
  (let ((civil
          (ical-recurrence-civil-from-seconds
           (+ (ical-recurrence-temporal-key start) seconds))))
    (unless (<= 0 (ical-recurrence-civil-year civil) 9999)
      (model-error overflow-code source
                   "instance arithmetic exceeds the supported year range"))
    (ical-recurrence-civil-temporal civil start)))

(defun ical-series-exact-shift
    (start seconds timezone-provider source overflow-code)
  (if (eq :zoned (temporal-value-kind start))
      (ical-series-zoned-shift start seconds timezone-provider)
      (ical-series-civil-shift start seconds source overflow-code)))

(defun ical-series-display-window-keys
    (master display-window-start display-window-end timezone-provider
     floating-timezone-id)
  (when (or display-window-start display-window-end)
    (unless (and display-window-start display-window-end)
      (model-error :incomplete-series-display-window
                   (cons display-window-start display-window-end)
                   "display window requires both start and end"))
    (let* ((master-start (ical-calendar-item-start master))
           (normalized-start
             (ical-recurrence-normalize-explicit-leap-second
              display-window-start :timezone-provider timezone-provider
              :floating-timezone-id floating-timezone-id))
           (normalized-end
             (ical-recurrence-normalize-explicit-leap-second
              display-window-end :timezone-provider timezone-provider
              :floating-timezone-id floating-timezone-id)))
      (ical-recurrence-require-compatible
       master-start normalized-start "display window start")
      (ical-recurrence-require-compatible
       master-start normalized-end "display window end")
      (let ((start-key
              (ical-series-resolved-seconds
               normalized-start timezone-provider floating-timezone-id))
            (end-key
              (ical-series-resolved-seconds
               normalized-end timezone-provider floating-timezone-id)))
        (unless (< start-key end-key)
          (model-error :invalid-series-display-window
                       (cons display-window-start display-window-end)
                       "display window must be non-empty and increasing"))
        (values start-key end-key)))))

(defun ical-series-filter-display-window
    (instances start-key end-key timezone-provider)
  (if (null start-key)
      instances
      (sort
       (remove-if-not
        (lambda (instance)
          (let ((actual-start
                  (ical-recurrence-instance-actual-start instance)))
            (when actual-start
              (let ((key
                      (ical-series-resolved-seconds
                       actual-start timezone-provider)))
                (and (<= start-key key) (< key end-key))))))
        instances)
       (lambda (left right)
         (let ((left-start
                 (ical-series-resolved-seconds
                  (ical-recurrence-instance-actual-start left)
                  timezone-provider))
               (right-start
                 (ical-series-resolved-seconds
                  (ical-recurrence-instance-actual-start right)
                  timezone-provider)))
           (if (= left-start right-start)
               (< (ical-recurrence-temporal-key
                   (ical-recurrence-instance-recurrence-id left))
                  (ical-recurrence-temporal-key
                   (ical-recurrence-instance-recurrence-id right)))
               (< left-start right-start)))))))

(defun ical-series-instance-finish
    (start duration source timezone-provider)
  (when (and start duration)
    (if (and (eq :zoned (temporal-value-kind start))
             (eq :nominal (ical-effective-duration-kind duration)))
        (let* ((after-days
                 (ical-series-civil-shift
                  start
                  (* (ical-effective-duration-nominal-days duration) 86400)
                  source :recurrence-instance-finish-overflow))
               (subday
                 (ical-effective-duration-nominal-subday-seconds duration)))
          (if (zerop subday)
              (progn
                (ical-series-resolved-seconds after-days timezone-provider)
                after-days)
              (ical-series-zoned-shift
               after-days subday timezone-provider)))
        (ical-series-exact-shift
         start (ical-effective-duration-seconds duration)
         timezone-provider source :recurrence-instance-finish-overflow))))

(defun ical-series-validate-override (master override)
  (unless (and (ical-calendar-item-p override)
               (ical-calendar-item-valid-p override))
    (model-error :invalid-recurrence-override override
                 "detached recurrence override must be a valid projected item"))
  (unless (ical-calendar-item-recurrence-id override)
    (model-error :missing-recurrence-override-id override
                 "detached recurrence override requires RECURRENCE-ID"))
  (unless (and (string= (ical-calendar-item-uid master)
                        (ical-calendar-item-uid override))
               (eq (ical-calendar-item-kind master)
                   (ical-calendar-item-kind override)))
    (model-error :mismatched-recurrence-series override
                 "override UID and component kind must match the master"))
  (unless (ical-recurrence-compatible-temporal-p
           (ical-calendar-item-start master)
           (ical-calendar-item-recurrence-id override))
    (model-error :incompatible-recurrence-override-id override
                 "RECURRENCE-ID must have the master's DTSTART kind and TZID"))
  (when (or (ical-calendar-item-recurrence-rule override)
            (ical-calendar-item-recurrence-dates override)
            (ical-calendar-item-recurrence-exception-dates override))
    (model-error :recursive-recurrence-override override
                 "a detached instance cannot define another recurrence set"))
  override)

(defun ical-series-range-derived-instance
    (master-duration range original timezone-provider floating-timezone-id)
  (if (ical-series-cancelled-p range)
      (%make-ical-recurrence-instance
       original nil nil nil :cancelled range)
      (let* ((delta
               (ical-series-range-delta
                range timezone-provider floating-timezone-id))
             (shifted
               (ical-series-exact-shift
                original delta timezone-provider range
                :recurrence-range-overflow))
             (duration
               (ical-series-item-effective-duration
                range master-duration timezone-provider
                floating-timezone-id)))
        (%make-ical-recurrence-instance
         original shifted
         (ical-series-instance-finish
          shifted duration range timezone-provider)
         duration :range-overridden range))))

(defun ical-series-override-instance
    (override master-duration timezone-provider floating-timezone-id)
  (let ((recurrence-id
          (ical-series-normalized-recurrence-id
           override timezone-provider floating-timezone-id)))
    (if (ical-series-cancelled-p override)
        (%make-ical-recurrence-instance
         recurrence-id nil nil nil :cancelled override)
        (let* ((raw-start (ical-calendar-item-start override))
               (start
                 (if raw-start
                     (ical-recurrence-normalize-explicit-leap-second
                      raw-start :timezone-provider timezone-provider
                      :floating-timezone-id floating-timezone-id)
                     recurrence-id))
               (duration
                 (ical-series-item-effective-duration
                  override master-duration timezone-provider
                  floating-timezone-id)))
          (%make-ical-recurrence-instance
           recurrence-id start
           (ical-series-instance-finish
            start duration override timezone-provider)
           duration :overridden override)))))

(defun ical-series-revision-identity
    (item timezone-provider floating-timezone-id)
  (let ((recurrence-id
          (ical-series-normalized-recurrence-id
           item timezone-provider floating-timezone-id)))
    (list
     (ical-calendar-item-uid item)
     (ical-calendar-item-kind item)
     (if recurrence-id
         (list (temporal-value-kind recurrence-id)
               (temporal-value-timezone-id recurrence-id)
               (ical-recurrence-temporal-key recurrence-id))
         :master))))

(defun ical-series-revision-sequence (item)
  (or (ical-calendar-item-sequence item) 0))

(defun ical-series-revision-dtstamp-key (item)
  (let ((dtstamp (ical-calendar-item-dtstamp item)))
    (unless (and (temporal-value-p dtstamp)
                 (eq :utc (temporal-value-kind dtstamp)))
      (model-error :invalid-calendar-item-revision-dtstamp item
                   "revision selection requires a valid UTC DTSTAMP"))
    (ical-recurrence-temporal-key dtstamp)))

(defun ical-series-preferred-revision (current candidate)
  (let ((current-sequence (ical-series-revision-sequence current))
        (candidate-sequence (ical-series-revision-sequence candidate)))
    (cond
      ((> candidate-sequence current-sequence) candidate)
      ((< candidate-sequence current-sequence) current)
      (t
       (let ((current-stamp (ical-series-revision-dtstamp-key current))
             (candidate-stamp (ical-series-revision-dtstamp-key candidate)))
         (cond
           ((> candidate-stamp current-stamp) candidate)
           ((< candidate-stamp current-stamp) current)
           (t
            (model-error :ambiguous-calendar-item-revision
                         (list current candidate)
                         "matching UID RECURRENCE-ID SEQUENCE and DTSTAMP do not identify one authoritative revision"))))))))

(defun select-ical-calendar-item-revisions
    (items &key timezone-provider floating-timezone-id)
  "Select one authoritative item per UID and optional RECURRENCE-ID.

Higher SEQUENCE wins; latest DTSTAMP breaks an equal-SEQUENCE tie.  An exact
rank tie is refused because iTIP supplies no further ordering key.  Proven
leap-second RECURRENCE-ID values normalize before identity grouping; floating
values require both TIMEZONE-PROVIDER and FLOATING-TIMEZONE-ID."
  (let ((table (make-hash-table :test #'equal))
        (order nil))
    (dolist (item
             (copy-proper-list items :invalid-calendar-item-revisions
                               "calendar item revisions"))
      (unless (and (ical-calendar-item-p item)
                   (ical-calendar-item-valid-p item))
        (model-error :invalid-calendar-item-revision item
                     "revision selection requires valid projected items"))
      (let ((key
              (ical-series-revision-identity
               item timezone-provider floating-timezone-id)))
        (multiple-value-bind (current present-p) (gethash key table)
          (if present-p
              (setf (gethash key table)
                    (ical-series-preferred-revision current item))
              (progn
                (setf (gethash key table) item)
                (push key order))))))
    (mapcar (lambda (key) (gethash key table)) (nreverse order))))

(defun ical-rscale-family-key (item)
  (list (ical-calendar-item-uid item) (ical-calendar-item-kind item)))

(defun classify-ical-rscale-component-families
    (items &key timezone-provider floating-timezone-id)
  "Separate complete unsupported RSCALE families from selected calendar items.

Every returned rejection contains its selected master and all UID-and-kind
matched detached overrides.  Unrelated families remain accepted in source
order.  No recurrence is executed by this classifier."
  (let ((selected
          (select-ical-calendar-item-revisions
           items :timezone-provider timezone-provider
           :floating-timezone-id floating-timezone-id))
        (families (make-hash-table :test #'equal))
        (order nil)
        (rejected-keys (make-hash-table :test #'equal))
        (rejections nil))
    (dolist (item selected)
      (let ((key (ical-rscale-family-key item)))
        (unless (gethash key families)
          (push key order))
        (push item (gethash key families))))
    (dolist (key (nreverse order))
      (let* ((family (nreverse (gethash key families)))
             (master
               (find-if-not #'ical-calendar-item-recurrence-id family))
             (rule (and master
                        (ical-calendar-item-recurrence-rule master)))
             (scale (and rule
                         (ical-recur-value-recurrence-scale rule))))
        (when scale
          (setf (gethash key rejected-keys) t)
          (push (%make-ical-rscale-family-rejection
                 (ical-calendar-item-uid master)
                 (ical-calendar-item-kind master)
                 (copy-seq scale) family)
                rejections))))
    (values
     (remove-if (lambda (item)
                  (gethash (ical-rscale-family-key item) rejected-keys))
                selected)
     (nreverse rejections))))

(defun expand-ical-recurrence-series
    (master overrides &key window-start window-end
             display-window-start display-window-end
             (limits (make-ical-recurrence-limits)) timezone-provider
             floating-timezone-id)
  "Assemble detached overrides over one recurrence master.

WINDOW-START and WINDOW-END bound discovery by original RECURRENCE-ID.  When
both display bounds are supplied, the result is filtered and sorted by actual
start, so moved instances inside the identity horizon can enter or leave the
half-open display window.  Cancelled instances have no actual start and are
therefore omitted from a display-filtered result.  THISANDFUTURE start deltas,
effective durations, and cancellations propagate by recurrence identity;
later explicit components affect only their own identity.  Explicit floating
leap-second PERIOD endpoints EXDATE values and RECURRENCE-ID values require
both TIMEZONE-PROVIDER and FLOATING-TIMEZONE-ID; zoned values use
TIMEZONE-PROVIDER."
  (unless (and (ical-calendar-item-p master)
               (ical-calendar-item-valid-p master))
    (model-error :invalid-recurrence-master master
                 "recurrence master must be a valid projected item"))
  (multiple-value-bind (accepted rejections)
      (classify-ical-rscale-component-families
       (cons master overrides)
       :timezone-provider timezone-provider
       :floating-timezone-id floating-timezone-id)
    (declare (ignore accepted))
    (when rejections
      (model-error :unsupported-rscale-component-family
                   (first rejections)
                   "preserve-only RFC 7529 support rejects the complete UID-linked component family")))
  (when (ical-calendar-item-recurrence-id master)
    (model-error :detached-item-used-as-master master
                 "recurrence master cannot contain RECURRENCE-ID"))
  (unless (ical-calendar-item-start master)
    (model-error :missing-recurrence-start master
                 "recurrence master requires DTSTART"))
  (let* ((override-list
           (select-ical-calendar-item-revisions
            overrides :timezone-provider timezone-provider
            :floating-timezone-id floating-timezone-id))
         (override-index (make-hash-table :test #'eql))
         (ranged-overrides nil)
         (master-duration
           (ical-series-master-effective-duration
            master timezone-provider floating-timezone-id))
         (period-duration-index
           (ical-series-period-duration-index
            master timezone-provider floating-timezone-id))
         (window-start-key
           (ical-recurrence-temporal-key
            (ical-recurrence-normalize-explicit-leap-second
             window-start :timezone-provider timezone-provider
             :floating-timezone-id floating-timezone-id)))
         (window-end-key
           (ical-recurrence-temporal-key
            (ical-recurrence-normalize-explicit-leap-second
             window-end :timezone-provider timezone-provider
             :floating-timezone-id floating-timezone-id))))
    (multiple-value-bind (display-start-key display-end-key)
        (ical-series-display-window-keys
         master display-window-start display-window-end timezone-provider
         floating-timezone-id)
      (dolist (override override-list)
        (ical-series-validate-override master override)
        (let* ((recurrence-id
                 (ical-series-normalized-recurrence-id
                  override timezone-provider floating-timezone-id))
               (key (ical-recurrence-temporal-key recurrence-id)))
          (when (gethash key override-index)
            (model-error :duplicate-recurrence-override key
                         "series has multiple components for one RECURRENCE-ID"))
          (setf (gethash key override-index) override)
          (when (eq :this-and-future
                    (ical-calendar-item-recurrence-range override))
            ;; Validate the delta and duration contract before expansion.
            (ical-series-range-delta
             override timezone-provider floating-timezone-id)
            (ical-series-item-effective-duration
             override master-duration timezone-provider floating-timezone-id)
            (push (cons key override) ranged-overrides))))
      (setf ranged-overrides (sort ranged-overrides #'< :key #'car))
      ;; Expand inclusions without EXDATE first.  An exact detached component
      ;; is a separate component and remains visible even if the master also
      ;; lists its original identity in EXDATE; otherwise EXDATE removes the
      ;; generated master occurrence.
      (let* ((base
               (expand-ical-recurrence-set
                (ical-calendar-item-start master)
                :rule (ical-calendar-item-recurrence-rule master)
                :recurrence-dates (ical-calendar-item-recurrence-dates master)
                :window-start window-start :window-end window-end
                :limits limits :timezone-provider timezone-provider
                :floating-timezone-id floating-timezone-id))
             (base-instances (ical-recurrence-expansion-instances base))
             (base-index (make-hash-table :test #'eql))
             (excluded
               (mapcar
                (lambda (exception)
                  (let ((normalized
                          (ical-recurrence-normalize-explicit-leap-second
                           exception :timezone-provider timezone-provider
                           :floating-timezone-id floating-timezone-id)))
                    (ical-recurrence-require-compatible
                     (ical-calendar-item-start master) normalized "EXDATE")
                    (ical-recurrence-temporal-key normalized)))
                (ical-calendar-item-recurrence-exception-dates master)))
             (instances nil)
             (pending-ranges ranged-overrides)
             (active-range nil))
        (dolist (original base-instances)
          (let* ((key (ical-recurrence-temporal-key original))
                 (override (gethash key override-index))
                 (original-duration
                   (or (gethash key period-duration-index)
                       master-duration)))
            (loop :while (and pending-ranges
                              (<= (caar pending-ranges) key))
                  :do (setf active-range (cdar pending-ranges)
                            pending-ranges (cdr pending-ranges)))
            (setf (gethash key base-index) t)
            (cond
              (override
               (push (ical-series-override-instance
                      override original-duration timezone-provider
                      floating-timezone-id)
                     instances))
              ((member key excluded :test #'=))
              (active-range
               (push (ical-series-range-derived-instance
                      original-duration active-range original timezone-provider
                      floating-timezone-id)
                     instances))
              (t
               (push (%make-ical-recurrence-instance
                      original original
                      (ical-series-instance-finish
                       original original-duration master timezone-provider)
                      original-duration :generated master)
                     instances)))))
        (maphash
         (lambda (key override)
           (when (and (<= window-start-key key) (< key window-end-key)
                      (not (gethash key base-index)))
             (model-error
              :orphan-recurrence-override override
              "RECURRENCE-ID does not identify a master occurrence in the requested identity window")))
         override-index)
        (%make-ical-recurrence-series-expansion
         (ical-calendar-item-uid master)
         (ical-calendar-item-kind master)
         master
         (ical-series-filter-display-window
          (nreverse instances) display-start-key display-end-key
          timezone-provider))))))
