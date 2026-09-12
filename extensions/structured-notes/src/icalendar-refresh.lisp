(in-package #:lem-structured-notes)

(defconstant +ical-refresh-default-minimum-seconds+ 86400)

(defstruct (ical-refresh-consent
            (:copier nil)
            (:constructor %make-ical-refresh-consent
                (source approved-at expires-at minimum-seconds)))
  (source "" :type string :read-only t)
  (approved-at 0 :type (integer 0) :read-only t)
  (expires-at 0 :type (integer 0) :read-only t)
  (minimum-seconds +ical-refresh-default-minimum-seconds+
                   :type (integer 1) :read-only t))

(defstruct (ical-refresh-plan
            (:constructor %make-ical-refresh-plan
                (kind source requested-seconds effective-seconds next-at
                 warning-p retrieval-safe-p consent)))
  (kind :not-configured
        :type (member :not-configured :consent-required :unsafe-source :ready)
        :read-only t)
  (source nil :type (or null ical-uri-value) :read-only t)
  (requested-seconds nil :type (or null (integer 1)) :read-only t)
  (effective-seconds nil :type (or null (integer 1)) :read-only t)
  (next-at nil :type (or null (integer 0)) :read-only t)
  (warning-p nil :type boolean :read-only t)
  (retrieval-safe-p nil :type boolean :read-only t)
  (consent nil :type (or null ical-refresh-consent) :read-only t))

(defun make-ical-refresh-consent
    (source approved-at expires-at
     &key (minimum-seconds +ical-refresh-default-minimum-seconds+))
  "Create inert, exact-SOURCE user consent; this never schedules or fetches."
  (unless (and (ical-uri-value-p source)
               (integerp approved-at) (<= 0 approved-at)
               (integerp expires-at) (< approved-at expires-at)
               (integerp minimum-seconds)
               (>= minimum-seconds
                   +ical-refresh-default-minimum-seconds+))
    (model-error :invalid-icalendar-refresh-consent
                 (list source approved-at expires-at minimum-seconds)
                 "refresh consent requires an exact URI, increasing times, and a minimum of one day"))
  (%make-ical-refresh-consent
   (copy-seq (ical-uri-value-original-lexeme source))
   approved-at expires-at minimum-seconds))

(defun ical-refresh-duration-seconds (duration)
  (unless (and (ical-duration-value-p duration)
               (ical-duration-positive-p duration))
    (model-error :invalid-icalendar-refresh-duration duration
                 "refresh duration must be positive"))
  (+ (* (ical-duration-value-weeks duration) 7 86400)
     (* (ical-duration-value-days duration) 86400)
     (* (ical-duration-value-hours duration) 3600)
     (* (ical-duration-value-minutes duration) 60)
     (ical-duration-value-seconds duration)))

(defun ical-refresh-consent-current-p (consent source now)
  (and (ical-refresh-consent-p consent)
       (string= (ical-refresh-consent-source consent)
                (ical-uri-value-original-lexeme source))
       (<= (ical-refresh-consent-approved-at consent) now)
       (< now (ical-refresh-consent-expires-at consent))))

(defun plan-ical-calendar-refresh (calendar now &key consent)
  "Plan RFC 7986 refresh timing as inert evidence without network or timer I/O."
  (unless (and (ical-calendar-envelope-p calendar)
               (ical-calendar-envelope-valid-p calendar))
    (model-error :invalid-icalendar-refresh-calendar calendar
                 "refresh planning requires a valid VCALENDAR projection"))
  (unless (and (integerp now) (<= 0 now))
    (model-error :invalid-icalendar-refresh-time now
                 "refresh planning time must be a non-negative integer"))
  (let ((source (ical-calendar-envelope-source calendar))
        (duration (ical-calendar-envelope-refresh-interval calendar)))
    (unless source
      (return-from plan-ical-calendar-refresh
        (%make-ical-refresh-plan
         :not-configured nil nil nil nil nil nil nil)))
    (let* ((requested (and duration (ical-refresh-duration-seconds duration)))
           (warning-p
             (and requested
                  (< requested +ical-refresh-default-minimum-seconds+)))
           (retrieval-safe-p
             (ical-managed-attachment-uri-retrieval-safe-p source)))
      (unless retrieval-safe-p
        (return-from plan-ical-calendar-refresh
          (%make-ical-refresh-plan
           :unsafe-source source requested nil nil warning-p nil nil)))
      (unless (ical-refresh-consent-current-p consent source now)
        (return-from plan-ical-calendar-refresh
          (%make-ical-refresh-plan
           :consent-required source requested nil nil warning-p t nil)))
      (let* ((effective
               (max (or requested +ical-refresh-default-minimum-seconds+)
                    +ical-refresh-default-minimum-seconds+
                    (ical-refresh-consent-minimum-seconds consent)))
             (next-at (+ now effective)))
        (unless (ical-refresh-consent-current-p consent source next-at)
          (return-from plan-ical-calendar-refresh
            (%make-ical-refresh-plan
             :consent-required source requested nil nil warning-p t nil)))
        (%make-ical-refresh-plan
         :ready source requested effective next-at warning-p t
         consent)))))
