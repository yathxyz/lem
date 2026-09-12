(in-package #:lem-structured-notes/tests)

(define-foundation-test http-preference-applied-parser-preserves-exact-values
  (let ((preferences
          (parse-http-applied-preference-field
           "return=representation, example=\"Case\\\"Sensitive\"")))
    (assert-equal 2 (length preferences))
    (assert-equal "return" (http-applied-preference-token (first preferences)))
    (assert-equal "representation"
                  (http-applied-preference-value (first preferences)))
    (assert-equal "example" (http-applied-preference-token (second preferences)))
    (assert-equal "Case\"Sensitive"
                  (http-applied-preference-value (second preferences)))))

(define-foundation-test http-prefer-request-parser-preserves-generic-parameters
  (let* ((preferences
           (parse-http-prefer-field
            "RETURN=minimal; Foo=\"Case\\\"Sensitive\"; flag; empty=\"\"; ;, wait=10"))
         (return (first preferences))
         (parameters (http-request-preference-parameters return)))
    (assert-equal 2 (length preferences))
    (assert-equal "return" (http-request-preference-token return))
    (assert-equal "minimal" (http-request-preference-value return))
    (assert-equal '("foo" "flag" "empty")
                  (mapcar #'http-preference-parameter-name parameters))
    (assert-equal '("Case\"Sensitive" nil nil)
                  (mapcar #'http-preference-parameter-value parameters))
    (assert-equal "Foo=\"Case\\\"Sensitive\""
                  (http-preference-parameter-raw (first parameters)))
    (assert-equal
     "RETURN=minimal; Foo=\"Case\\\"Sensitive\"; flag; empty=\"\"; ;"
     (http-request-preference-raw return))
    (assert-equal "wait"
                  (http-request-preference-token (second preferences)))
    (assert-equal "10"
                  (http-request-preference-value (second preferences)))))

(define-foundation-test http-prefer-first-occurrence-and-applied-grammar-are-exact
  (let ((headers
          '(("Prefer" "return=minimal; trace=One, respond-async")
            ("Prefer" "return=representation, depth-noroot; mode=Exact")
            ("Prefer" "depth-noroot=unsupported"))))
    (assert-equal :minimal
                  (caldav-return-preference-from-request-headers headers))
    (assert-true (caldav-depth-noroot-from-request-headers headers))
    (assert-equal
     :invalid-http-preference-syntax
     (signaled-model-code
      (lambda ()
        (parse-http-applied-preference-field
         "return=minimal; response-parameters=forbidden"))))))

(define-foundation-test caldav-return-preference-distinguishes-application
  (dolist (entry
           (list
            (list nil nil :not-requested nil)
            (list '( ("Prefer" "return=minimal")) nil :ignored nil)
            (list '( ("Prefer" "return=minimal"))
                  '( ("Preference-Applied" "return=minimal"))
                  :applied :minimal)
            (list '( ("Prefer" "return=representation"))
                  '( ("Preference-Applied" "return=minimal"))
                  :mismatched :minimal)
            (list '( ("Prefer" "return=minimal"))
                  '( ("Preference-Applied"
                      "return=minimal, return=representation"))
                  :ambiguous nil)))
    (let ((evidence
            (classify-caldav-return-preference (first entry) (second entry))))
      (assert-equal (third entry)
                    (caldav-return-preference-evidence-kind evidence))
      (assert-equal (fourth entry)
                    (caldav-return-preference-evidence-applied evidence)))))

(define-foundation-test typed-prefer-request-recovers-return-and-depth-noroot
  (let ((headers
          '(("Prefer" "return=minimal, depth-noroot"))))
    (assert-equal :minimal
                  (caldav-return-preference-from-request-headers headers))
    (assert-true (caldav-depth-noroot-from-request-headers headers))
    (assert-false
     (caldav-depth-noroot-from-request-headers
      '(("Prefer" "return=minimal"))))
    (assert-false
     (caldav-depth-noroot-from-request-headers
      '(("Prefer" "return=minimal, depth-noroot=1"))))))

(define-foundation-test malformed-or-unsupported-preference-fields-fail-closed
  (dolist (thunk
           (list
            (lambda () (parse-http-applied-preference-field ""))
            (lambda () (parse-http-applied-preference-field "return="))
            (lambda () (parse-http-applied-preference-field "return=minimal,"))
            (lambda () (parse-http-applied-preference-field "return=\"open"))
            (lambda ()
              (parse-http-applied-preference-field
               "return=minimal" :max-characters 1))
            (lambda ()
              (classify-caldav-return-preference
               '(("Prefer" "return=minimal; broken=\"open")) nil))))
    (assert-signals 'semantic-model-error thunk)))
