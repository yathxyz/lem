(in-package #:lem-structured-notes/tests)

(defun caldav-resource-name-test-error-code (thunk)
  (handler-case
      (progn (funcall thunk) nil)
    (semantic-model-error (condition)
      (semantic-model-error-code condition))))

(define-foundation-test caldav-resource-names-are-opaque-and-os-random
  (let ((requested-count nil)
        (fixture (make-array 16 :element-type '(unsigned-byte 8)
                                :initial-contents
                                '(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))))
    (let ((lem-structured-notes::*caldav-resource-name-random-data-function*
            (lambda (count)
              (setf requested-count count)
              (copy-seq fixture))))
      (assert-equal
       "000102030405060708090a0b0c0d0e0f"
       (generate-caldav-opaque-resource-name)
       :test #'string=))
    (assert-equal 16 requested-count)
    (let ((name (generate-caldav-opaque-resource-name)))
      (assert-equal 32 (length name))
      (assert-true
       (every (lambda (character)
                (or (digit-char-p character)
                    (find character "abcdef" :test #'char=)))
              name)
       "generated CalDAV name was not one opaque lowercase-hex segment"))))

(define-foundation-test caldav-resource-name-entropy-fails-closed
  (let ((lem-structured-notes::*caldav-resource-name-random-data-function*
          (lambda (count)
            (declare (ignore count))
            (make-array 15 :element-type '(unsigned-byte 8)
                           :initial-element 0))))
    (assert-equal
     :invalid-caldav-resource-name-entropy
     (caldav-resource-name-test-error-code
      #'generate-caldav-opaque-resource-name)))
  (let ((lem-structured-notes::*caldav-resource-name-random-data-function*
          (lambda (count)
            (declare (ignore count))
            (error "entropy backend detail must remain private"))))
    (let ((condition
            (assert-signals
             'semantic-model-error
             #'generate-caldav-opaque-resource-name)))
      (assert-equal :caldav-resource-name-entropy-failure
                    (semantic-model-error-code condition))
      (assert-equal :unavailable (semantic-model-error-value condition))
      (assert-false
       (search "backend detail" (semantic-model-error-message condition))))))
