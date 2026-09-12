(in-package #:lem-structured-notes)

(defstruct (ical-availability-period
            (:constructor %make-ical-availability-period (type start end)))
  (type "BUSY-UNAVAILABLE" :type string :read-only t)
  (start nil :type temporal-value :read-only t)
  (end nil :type temporal-value :read-only t))

(defstruct (ical-availability-expansion
            (:constructor %make-ical-availability-expansion
                (window-start window-end periods components-examined
                 boundaries-examined)))
  (window-start nil :type temporal-value :read-only t)
  (window-end nil :type temporal-value :read-only t)
  (periods nil :type list :read-only t)
  (components-examined 0 :type (integer 0) :read-only t)
  (boundaries-examined 0 :type (integer 0) :read-only t))

(defstruct (ical-expanded-availability
            (:constructor %make-ical-expanded-availability
                (availability start-seconds end-seconds free-periods)))
  (availability nil :type ical-availability :read-only t)
  (start-seconds 0 :type integer :read-only t)
  (end-seconds 0 :type integer :read-only t)
  (free-periods nil :type list :read-only t))

(defun ical-available-calendar-item (available)
  (unless (and (ical-available-p available)
               (ical-available-valid-p available))
    (model-error :invalid-ical-available-expansion-input available
                 "availability expansion requires a valid AVAILABLE projection"))
  (%make-ical-calendar-item
   :event (ical-available-component available)
   (ical-available-uid available)
   (ical-available-dtstamp available)
   (ical-available-summary available)
   (ical-available-description available)
   nil
   (ical-available-location available)
   nil nil
   (ical-available-categories available)
   nil
   nil
   nil
   (ical-available-start available)
   (ical-available-end available)
   nil
   (ical-available-duration available)
   nil nil nil nil
   (ical-available-recurrence-id available)
   (ical-available-recurrence-range available)
   (ical-available-recurrence-rule available)
   (ical-available-recurrence-dates available)
   (ical-available-recurrence-exception-dates available)
   nil
   (ical-available-properties available)
   nil t
   (and (ical-available-description available)
        (list (ical-available-description available)))
   nil
   (project-ical-rfc-extensions (ical-available-component available))))

(defun ical-availability-require-utc-window (start end)
  (unless (and (temporal-value-p start) (temporal-value-p end)
               (eq :utc (temporal-value-kind start))
               (eq :utc (temporal-value-kind end)))
    (model-error :invalid-icalendar-availability-window (cons start end)
                 "availability calculation requires UTC DATE-TIME bounds"))
  (let ((start-seconds
          (ical-utc-temporal-seconds
           (ical-recurrence-normalize-explicit-leap-second start)))
        (end-seconds
          (ical-utc-temporal-seconds
           (ical-recurrence-normalize-explicit-leap-second end))))
    (unless (< start-seconds end-seconds)
      (model-error :invalid-icalendar-availability-window (cons start end)
                   "availability window must be non-empty and increasing"))
    (values start-seconds end-seconds)))

(defun ical-availability-resolved-seconds (temporal timezone-provider)
  (when temporal
    (ical-series-resolved-seconds temporal timezone-provider)))

(defun ical-availability-finish
    (start end duration source timezone-provider)
  (cond
    (end end)
    (duration
     (let ((normalized-start
             (ical-recurrence-normalize-explicit-leap-second
              start :timezone-provider timezone-provider)))
       (ical-series-instance-finish
        normalized-start (ical-series-nominal-effective-duration duration)
        source timezone-provider)))
    (t nil)))

(defun ical-availability-component-bounds
    (availability window-start window-end timezone-provider)
  (let* ((start (ical-availability-start availability))
         (finish
           (ical-availability-finish
            start (ical-availability-end availability)
            (ical-availability-duration availability)
            availability timezone-provider))
         (start-seconds
           (if start
               (ical-availability-resolved-seconds start timezone-provider)
               window-start))
         (end-seconds
           (if finish
               (ical-availability-resolved-seconds finish timezone-provider)
               window-end)))
    (values (max window-start start-seconds)
            (min window-end end-seconds))))

(defun ical-availability-overlaps-window-p
    (availability window-start window-end &key timezone-provider)
  "Evaluate the RFC 7953 VAVAILABILITY time-range overlap table."
  (unless (and (ical-availability-p availability)
               (ical-availability-valid-p availability))
    (model-error :invalid-icalendar-availability-expansion-input availability
                 "overlap evaluation requires a valid availability projection"))
  (multiple-value-bind (window-start-seconds window-end-seconds)
      (ical-availability-require-utc-window window-start window-end)
    (multiple-value-bind (start end)
        (ical-availability-component-bounds
         availability window-start-seconds window-end-seconds
         timezone-provider)
      (< start end))))

(defun ical-availability-rdate-start (value)
  (if (ical-period-value-p value)
      (ical-period-value-start value)
      value))

(defun ical-availability-series-start (master timezone-provider)
  (let* ((start
           (ical-recurrence-normalize-explicit-leap-second
            (ical-calendar-item-start master)
            :timezone-provider timezone-provider))
         (values
           (cons start
                 (mapcar
                  (lambda (value)
                    (ical-recurrence-normalize-explicit-leap-second
                     (ical-availability-rdate-start value)
                     :timezone-provider timezone-provider))
                  (ical-calendar-item-recurrence-dates master)))))
    (reduce
     (lambda (left right)
       (ical-recurrence-require-compatible
        start right "AVAILABLE recurrence inclusion")
       (if (< (ical-recurrence-temporal-key right)
              (ical-recurrence-temporal-key left))
           right left))
     values)))

(defun ical-availability-series-window-end
    (master utc-window-end timezone-provider)
  (case (temporal-value-kind (ical-calendar-item-start master))
    (:utc utc-window-end)
    (:zoned
     (unless timezone-provider
       (model-error :missing-availability-timezone-provider master
                    "zoned AVAILABLE expansion requires a timezone provider"))
     (project-utc-time-to-zoned-local-time
      timezone-provider utc-window-end
      (temporal-value-timezone-id
       (ical-calendar-item-start master))))
    (otherwise
     (model-error :invalid-icalendar-available-start master
                  "AVAILABLE recurrence requires UTC or TZID DATE-TIME"))))

(defun ical-availability-group-items (available)
  (let ((table (make-hash-table :test #'equal))
        (order nil))
    (dolist (projection available)
      (let* ((item (ical-available-calendar-item projection))
             (uid (ical-calendar-item-uid item)))
        (unless (gethash uid table)
          (push uid order))
        (push item (gethash uid table))))
    (values table (nreverse order))))

(defun ical-availability-expand-series
    (items utc-window-end timezone-provider recurrence-limits)
  (let* ((selected
           (select-ical-calendar-item-revisions
            items :timezone-provider timezone-provider))
         (masters
           (remove-if #'ical-calendar-item-recurrence-id selected))
         (overrides
           (remove-if-not #'ical-calendar-item-recurrence-id selected)))
    (unless (= 1 (length masters))
      (model-error :invalid-icalendar-available-series
                   (mapcar #'ical-calendar-item-uid selected)
                   "each AVAILABLE UID requires exactly one recurrence master"))
    (let* ((master (first masters))
           (series-start
             (ical-availability-series-start master timezone-provider))
           (series-end
             (ical-availability-series-window-end
              master utc-window-end timezone-provider)))
      (when (>= (ical-recurrence-temporal-key series-start)
                (ical-recurrence-temporal-key series-end))
        (return-from ical-availability-expand-series nil))
      (ical-recurrence-series-expansion-instances
       (expand-ical-recurrence-series
        master overrides
        :window-start series-start :window-end series-end
        :limits recurrence-limits :timezone-provider timezone-provider)))))

(defun ical-availability-free-periods
    (availability component-start component-end utc-window-end
     timezone-provider recurrence-limits max-free-periods)
  (multiple-value-bind (table order)
      (ical-availability-group-items
       (ical-availability-available availability))
    (let ((periods nil))
      (dolist (uid order)
        (dolist (instance
                 (ical-availability-expand-series
                  (gethash uid table) utc-window-end timezone-provider
                  recurrence-limits))
          (let ((start (ical-recurrence-instance-actual-start instance))
                (finish (ical-recurrence-instance-actual-finish instance)))
            (when (and start finish)
              (let ((start-seconds
                      (ical-availability-resolved-seconds
                       start timezone-provider))
                    (end-seconds
                      (ical-availability-resolved-seconds
                       finish timezone-provider)))
                (when (< start-seconds end-seconds)
                  (let ((clipped-start
                          (max component-start start-seconds))
                        (clipped-end
                          (min component-end end-seconds)))
                    (when (< clipped-start clipped-end)
                      (when (>= (length periods) max-free-periods)
                        (model-error
                         :icalendar-availability-free-period-limit-exceeded
                         max-free-periods
                         "expanded AVAILABLE periods exceed their configured limit"))
                      (push (cons clipped-start clipped-end) periods)))))))))
      (nreverse periods))))

(defun ical-expand-availability-component
    (availability window-start-seconds window-end-seconds utc-window-end
     timezone-provider recurrence-limits max-free-periods)
  (multiple-value-bind (start end)
      (ical-availability-component-bounds
       availability window-start-seconds window-end-seconds timezone-provider)
    (when (< start end)
      (%make-ical-expanded-availability
       availability start end
       (ical-availability-free-periods
        availability start end utc-window-end timezone-provider
        recurrence-limits max-free-periods)))))

(defun ical-expanded-availability-active-p (expanded start end)
  (and (< (ical-expanded-availability-start-seconds expanded) end)
       (> (ical-expanded-availability-end-seconds expanded) start)))

(defun ical-expanded-availability-free-p (expanded start end)
  (find-if
   (lambda (period)
     (and (<= (car period) start) (>= (cdr period) end)))
   (ical-expanded-availability-free-periods expanded)))

(defun ical-availability-effective-busy-type (expanded start end)
  (unless (ical-expanded-availability-free-p expanded start end)
    (ical-availability-busy-type
     (ical-expanded-availability-availability expanded))))

(defun ical-availability-resolve-busy-type (types)
  (let ((unique (remove-duplicates types :test #'string-equal)))
    (cond
      ((null unique) nil)
      ((null (rest unique)) (first unique))
      ((every
        (lambda (type)
          (member type '("BUSY" "BUSY-UNAVAILABLE" "BUSY-TENTATIVE")
                  :test #'string-equal))
        unique)
       (first
        (sort unique #'>
              :key #'ical-availability-busy-type-rank)))
      (t
       (model-error :undefined-icalendar-availability-busy-precedence unique
                    "distinct extension BUSYTYPE values have no RFC 7953 precedence")))))

(defun ical-availability-segment-type (expanded start end)
  (let* ((active
           (remove-if-not
            (lambda (item)
              (ical-expanded-availability-active-p item start end))
            expanded)))
    (when active
      (let* ((highest
               (reduce
                #'max active
                :key
                (lambda (item)
                  (ical-availability-priority-rank
                   (ical-availability-priority
                    (ical-expanded-availability-availability item))))))
             (controlling
               (remove-if-not
                (lambda (item)
                  (= highest
                     (ical-availability-priority-rank
                      (ical-availability-priority
                       (ical-expanded-availability-availability item)))))
                active)))
        (ical-availability-resolve-busy-type
         (remove nil
                 (mapcar
                  (lambda (item)
                    (ical-availability-effective-busy-type item start end))
                  controlling)))))))

(defun ical-availability-boundaries
    (expanded window-start window-end max-boundaries)
  (let ((boundaries (list window-start window-end)))
    (dolist (item expanded)
      (push (ical-expanded-availability-start-seconds item) boundaries)
      (push (ical-expanded-availability-end-seconds item) boundaries)
      (dolist (period (ical-expanded-availability-free-periods item))
        (push (car period) boundaries)
        (push (cdr period) boundaries)))
    (setf boundaries (sort (remove-duplicates boundaries :test #'=) #'<))
    (when (> (length boundaries) max-boundaries)
      (model-error :icalendar-availability-boundary-limit-exceeded
                   (length boundaries)
                   "availability calculation exceeds its boundary limit"))
    boundaries))

(defun ical-availability-append-period (periods type start end)
  (let ((previous (first periods)))
    (if (and previous
             (string-equal type (ical-availability-period-type previous))
             (= start
                (ical-utc-temporal-seconds
                 (ical-availability-period-end previous))))
        (cons
         (%make-ical-availability-period
          (ical-availability-period-type previous)
          (ical-availability-period-start previous)
          (ical-series-utc-temporal-from-seconds end))
         (rest periods))
        (cons
         (%make-ical-availability-period
          (copy-seq type)
          (ical-series-utc-temporal-from-seconds start)
          (ical-series-utc-temporal-from-seconds end))
         periods))))

(defun calculate-ical-availability
    (availabilities &key window-start window-end timezone-provider
                         (recurrence-limits (make-ical-recurrence-limits))
                         (max-components 1024)
                         (max-free-periods 10000)
                         (max-boundaries 20002))
  "Calculate RFC 7953 availability-only busy periods in one UTC window.

VEVENT and VFREEBUSY overlay is intentionally a separate operation.  The
result contains only coalesced busy periods; gaps are free."
  (unless (and (integerp max-components) (plusp max-components)
               (integerp max-free-periods) (plusp max-free-periods)
               (integerp max-boundaries) (> max-boundaries 1))
    (model-error :invalid-icalendar-availability-expansion-limits
                 (list max-components max-free-periods max-boundaries)
                 "availability expansion limits must be positive"))
  (let ((items
          (copy-proper-list
           availabilities :invalid-icalendar-availabilities
           "availabilities")))
    (when (> (length items) max-components)
      (model-error :icalendar-availability-component-limit-exceeded
                   (length items)
                   "availability calculation exceeds its component limit"))
    (dolist (availability items)
      (unless (and (ical-availability-p availability)
                   (ical-availability-valid-p availability))
        (model-error :invalid-icalendar-availability-expansion-input
                     availability
                     "availability calculation requires valid projections")))
    (multiple-value-bind (window-start-seconds window-end-seconds)
        (ical-availability-require-utc-window window-start window-end)
      (let ((expanded nil))
        (dolist (availability items)
          (let ((item
                  (ical-expand-availability-component
                   availability window-start-seconds window-end-seconds
                   window-end timezone-provider recurrence-limits
                   max-free-periods)))
            (when item (push item expanded))))
        (setf expanded (nreverse expanded))
        (let ((boundaries
                (ical-availability-boundaries
                 expanded window-start-seconds window-end-seconds
                 max-boundaries))
              (periods nil))
          (loop :for tail :on boundaries
                :while (rest tail)
                :for start := (first tail)
                :for end := (second tail)
                :for type := (ical-availability-segment-type
                              expanded start end)
                :when type
                  :do (setf periods
                            (ical-availability-append-period
                             periods type start end)))
          (%make-ical-availability-expansion
           window-start window-end (nreverse periods)
           (length expanded) (length boundaries)))))))
