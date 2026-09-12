(defpackage #:lem-structured-notes/tests
  (:use #:cl #:lem-structured-notes)
  (:export #:run-tests))

(in-package #:lem-structured-notes/tests)

(defvar *tests* nil)
(setf *tests* nil)

(defmacro define-foundation-test (name &body body)
  `(push (cons ',name (lambda () ,@body)) *tests*))

(defun fail-test (control &rest arguments)
  (error (apply #'format nil control arguments)))

(defun assert-true (value &optional (message "expected a true value"))
  (unless value
    (fail-test "~a" message))
  value)

(defun assert-false (value &optional (message "expected a false value"))
  (when value
    (fail-test "~a" message))
  t)

(defun assert-equal (expected actual &key (test #'equal) message)
  (unless (funcall test expected actual)
    (fail-test "~aExpected ~s, received ~s"
               (if message (format nil "~a: " message) "")
               expected actual))
  actual)

(defun assert-signals (condition-type thunk)
  (handler-case
      (progn
        (funcall thunk)
        (fail-test "Expected condition ~s, but none was signaled"
                   condition-type))
    (condition (condition)
      (unless (typep condition condition-type)
        (error condition))
      condition)))

(defun run-tests ()
  (let ((passed 0)
        (failures nil))
    (dolist (entry (reverse *tests*))
      (handler-case
          (progn
            (funcall (cdr entry))
            (incf passed)
            (format t "PASS ~a~%" (car entry)))
        (condition (condition)
          (push (cons (car entry) condition) failures)
          (format *error-output* "FAIL ~a: ~a~%" (car entry) condition))))
    (format t "~d foundation tests passed; ~d failed.~%"
            passed (length failures))
    (when failures
      (error "lem-structured-notes foundation tests failed: ~{~a~^, ~}"
             (mapcar #'car (reverse failures))))
    t))
