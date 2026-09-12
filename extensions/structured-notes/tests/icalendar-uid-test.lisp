(in-package #:lem-structured-notes/tests)

(defun icalendar-uid-test-error-code (thunk)
  (handler-case
      (progn (funcall thunk) nil)
    (semantic-model-error (condition)
      (semantic-model-error-code condition))))

(define-foundation-test icalendar-uids-are-private-random-uuidv4-values
  (let ((requested-count nil)
        (fixture
          (make-array 16 :element-type '(unsigned-byte 8)
                         :initial-contents
                         '(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))))
    (let ((lem-structured-notes::*icalendar-uid-random-data-function*
            (lambda (count)
              (setf requested-count count)
              (copy-seq fixture))))
      (assert-equal
       "00010203-0405-4607-8809-0a0b0c0d0e0f"
       (generate-icalendar-uid)
       :test #'string=))
    (assert-equal 16 requested-count))
  (let ((uid (generate-icalendar-uid)))
    (assert-equal 36 (length uid))
    (assert-equal #\4 (char uid 14))
    (assert-true (find (char uid 19) "89ab" :test #'char=))
    (assert-false (find #\@ uid))
    (loop :for character :across uid
          :for index :from 0
          :do (if (member index '(8 13 18 23))
                  (assert-equal #\- character)
                  (assert-true
                   (or (digit-char-p character)
                       (find character "abcdef" :test #'char=)))))))

(define-foundation-test icalendar-uid-entropy-fails-closed
  (let ((lem-structured-notes::*icalendar-uid-random-data-function*
          (lambda (count)
            (declare (ignore count))
            (make-array 15 :element-type '(unsigned-byte 8)
                           :initial-element 0))))
    (assert-equal
     :invalid-icalendar-uid-entropy
     (icalendar-uid-test-error-code #'generate-icalendar-uid)))
  (let ((lem-structured-notes::*icalendar-uid-random-data-function*
          (lambda (count)
            (declare (ignore count))
            (error "entropy backend secret detail"))))
    (let ((condition
            (assert-signals
             'semantic-model-error
             #'generate-icalendar-uid)))
      (assert-equal :icalendar-uid-entropy-failure
                    (semantic-model-error-code condition))
      (assert-equal :unavailable (semantic-model-error-value condition))
      (assert-false
       (search "secret detail" (semantic-model-error-message condition))))))

(define-foundation-test rfc7986-output-uids-are-bounded-opaque-tokens
  (let* ((maximum (make-string 254 :initial-element #\a))
         (line (generate-ical-property-line "UID" maximum))
         (legacy
           (project-ical-component
            (parse-first-ical-item-component
             "BEGIN:VEVENT" "UID:legacy-user@example.test"
             "DTSTAMP:20260728T120000Z" "DTSTART:20260728T130000Z"
             "END:VEVENT"))))
    (assert-true (search "UID:" line))
    (assert-true (ical-calendar-item-valid-p legacy))
    (assert-equal "legacy-user@example.test"
                  (ical-calendar-item-uid legacy) :test #'string=)
    (dolist (uid (list "" "user@example.test" "not_iana_token"
                       "identifiant-é"
                       (make-string 255 :initial-element #\a)))
      (assert-signals
       'semantic-model-error
       (lambda () (generate-ical-property-line "UID" uid))))))
