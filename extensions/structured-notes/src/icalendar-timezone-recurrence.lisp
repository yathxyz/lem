(in-package #:lem-structured-notes)

(defmethod expand-recurring-timezone-observance-onsets
    ((observance ical-timezone-observance) local-limit
     max-periods max-candidates max-instances)
  "Expand one recurring observance through the shared bounded engine."
  (let* ((start (ical-timezone-observance-start observance))
         (start-key (ical-recurrence-temporal-key start)))
    (when (< local-limit start-key)
      (return-from expand-recurring-timezone-observance-onsets
        (values nil nil 0 0)))
    (let* ((exclusive-limit (1+ local-limit))
           (end-civil
             (ical-recurrence-civil-from-seconds exclusive-limit)))
      (when (> (ical-recurrence-civil-year end-civil) 9999)
        (model-error :timezone-recurrence-range-overflow local-limit
                     "timezone recurrence window exceeds year 9999"))
      (let* ((offset-from
               (ical-timezone-observance-offset-from observance))
             (expansion
               (expand-ical-recurrence-set
                start
                :rule (ical-timezone-observance-recurrence-rule observance)
                :recurrence-dates
                (ical-timezone-observance-recurrence-dates observance)
                :window-start start
                :window-end
                (ical-recurrence-civil-temporal end-civil start)
                :limits
                (make-ical-recurrence-limits
                 :max-periods max-periods
                 :max-candidates max-candidates
                 :max-instances max-instances)
                :candidate-utc-function
                (lambda (candidate)
                  (- (ical-recurrence-temporal-key candidate)
                     offset-from)))))
        (values
         (ical-recurrence-expansion-instances expansion) nil
         (ical-recurrence-expansion-periods-examined expansion)
         (ical-recurrence-expansion-candidates-examined expansion))))))
