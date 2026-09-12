(in-package #:lem-structured-notes/tests)

(defun project-refresh-calendar (&rest properties)
  (apply #'project-ical-calendar-envelope-from-lines
         (append '("PRODID:-//Refresh Test//EN" "VERSION:2.0")
                 properties
                 '("BEGIN:VEVENT" "END:VEVENT"))))

(define-foundation-test rfc7986-refresh-plans-require-exact-current-consent
  (let* ((now 1000000)
         (source-text "https://calendar.example.test/source.ics")
         (calendar
           (project-refresh-calendar
            (format nil "SOURCE;VALUE=URI:~a" source-text)))
         (source (ical-calendar-envelope-source calendar))
         (absent (project-refresh-calendar))
         (matching
           (make-ical-refresh-consent source (- now 60) (+ now 100000)))
         (different
           (make-ical-refresh-consent
            (ical-calendar-envelope-source
             (project-refresh-calendar
              "SOURCE;VALUE=URI:https://calendar.example.test/other.ics"))
            (- now 60) (+ now 3600)))
         (expired
           (make-ical-refresh-consent source (- now 120) now))
         (expires-before-retrieval
           (make-ical-refresh-consent source (- now 60) (+ now 3600)))
         (future
           (make-ical-refresh-consent source (+ now 1) (+ now 3600))))
    (assert-equal :not-configured
                  (ical-refresh-plan-kind
                   (plan-ical-calendar-refresh absent now)))
    (dolist (consent
             (list nil different expired expires-before-retrieval future))
      (let ((plan
              (plan-ical-calendar-refresh calendar now :consent consent)))
        (assert-equal :consent-required (ical-refresh-plan-kind plan))
        (assert-true (ical-refresh-plan-retrieval-safe-p plan))
        (assert-false (ical-refresh-plan-effective-seconds plan))
        (assert-false (ical-refresh-plan-next-at plan))))
    (let ((plan
            (plan-ical-calendar-refresh calendar now :consent matching)))
      (assert-equal :ready (ical-refresh-plan-kind plan))
      (assert-equal +ical-refresh-default-minimum-seconds+
                    (ical-refresh-plan-effective-seconds plan))
      (assert-equal (+ now +ical-refresh-default-minimum-seconds+)
                    (ical-refresh-plan-next-at plan))
      (assert-equal matching (ical-refresh-plan-consent plan)))))

(define-foundation-test rfc7986-refresh-plans-throttle-and-warn
  (let* ((now 2000000)
         (short
           (project-refresh-calendar
            "REFRESH-INTERVAL;VALUE=DURATION:PT1S"
            "SOURCE;VALUE=URI:https://calendar.example.test/short.ics"))
         (long
           (project-refresh-calendar
            "REFRESH-INTERVAL;VALUE=DURATION:P2D"
            "SOURCE;VALUE=URI:https://calendar.example.test/long.ics"))
         (short-consent
           (make-ical-refresh-consent
            (ical-calendar-envelope-source short) (- now 1) (+ now 1000000)
            :minimum-seconds 172800))
         (long-consent
           (make-ical-refresh-consent
            (ical-calendar-envelope-source long) (- now 1) (+ now 1000000)))
         (short-plan
           (plan-ical-calendar-refresh short now :consent short-consent))
         (long-plan
           (plan-ical-calendar-refresh long now :consent long-consent)))
    (assert-equal 1 (ical-refresh-plan-requested-seconds short-plan))
    (assert-equal 172800 (ical-refresh-plan-effective-seconds short-plan))
    (assert-equal (+ now 172800) (ical-refresh-plan-next-at short-plan))
    (assert-true (ical-refresh-plan-warning-p short-plan))
    (assert-equal 172800 (ical-refresh-plan-requested-seconds long-plan))
    (assert-equal 172800 (ical-refresh-plan-effective-seconds long-plan))
    (assert-false (ical-refresh-plan-warning-p long-plan))))

(define-foundation-test rfc7986-refresh-plans-never-authorize-unsafe-source
  (let ((now 3000000))
    (dolist (source-text
             '("http://calendar.example.test/source.ics"
               "https://user@calendar.example.test/source.ics"
               "https://calendar.example.test/source.ics#fragment"
               "tel:+1-555-0100"))
      (let* ((calendar
               (project-refresh-calendar
                (format nil "SOURCE;VALUE=URI:~a" source-text)))
             (source (ical-calendar-envelope-source calendar))
             (consent
               (make-ical-refresh-consent source (- now 1) (+ now 1000)))
             (plan
               (plan-ical-calendar-refresh calendar now :consent consent)))
        (assert-equal :unsafe-source (ical-refresh-plan-kind plan))
        (assert-false (ical-refresh-plan-retrieval-safe-p plan))
        (assert-false (ical-refresh-plan-effective-seconds plan))
        (assert-false (ical-refresh-plan-next-at plan))))
    (let ((source
            (ical-calendar-envelope-source
             (project-refresh-calendar
              "SOURCE;VALUE=URI:https://calendar.example.test/source.ics"))))
      (assert-signals
       'semantic-model-error
       (lambda ()
         (make-ical-refresh-consent source now (+ now 1000)
                                    :minimum-seconds 86399)))
      (assert-signals
       'semantic-model-error
       (lambda () (make-ical-refresh-consent source now now))))
    (assert-signals
     'semantic-model-error
     (lambda () (plan-ical-calendar-refresh (project-refresh-calendar) -1)))))
