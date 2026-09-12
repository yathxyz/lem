;;; Exact pure URI cases extracted from the pinned umbrella test suites.
(in-package #:lem-structured-notes/tests)

(define-foundation-test dav-hrefs-resolve-with-origin-and-path-evidence
  (let ((relative
          (resolve-dav-href
           "/home/a%20b.ics?revision=1"
           "https://calendar.example.test/home/"))
        (default-port
          (resolve-dav-href
           "https://CALENDAR.example.test:443/home/a.ics"
           "https://calendar.example.test/home/"))
        (cross-origin
          (resolve-dav-href
           "https://other.example.test/home/a.ics"
           "https://calendar.example.test/home/")))
    (assert-equal "https://calendar.example.test/home/a%20b.ics?revision=1"
                  (dav-resolved-href-absolute-uri relative) :test #'string=)
    (assert-equal :absolute-path
                  (dav-resolved-href-reference-kind relative))
    (assert-true (dav-resolved-href-fetchable-p relative))
    (assert-true (dav-resolved-href-same-origin-p default-port))
    (assert-true (dav-resolved-href-fetchable-p default-port))
    (assert-false (dav-resolved-href-fetchable-p cross-origin))
    (assert-equal '(:dav-href-cross-origin)
                  (mapcar #'diagnostic-code
                          (dav-resolved-href-diagnostics cross-origin)))))

(define-foundation-test dav-hrefs-reject-fragments-dot-segments-and-relative-paths
  (dolist (case '(("child.ics" :invalid-dav-href)
                  ("//other.example.test/home" :dav-href-network-path-forbidden)
                  ("/home/../private" :dav-href-dot-segment-forbidden)
                  ("/home/%2e%2E/private" :dav-href-dot-segment-forbidden)
                  ("/home/a.ics#part" :dav-href-fragment-forbidden)))
    (assert-equal
     (second case)
     (signaled-model-code
      (lambda ()
        (resolve-dav-href (first case)
                          "https://calendar.example.test/home/"))))))

(define-foundation-test caldav-location-resolves-relative-references-safely
  (assert-equal
   "https://calendar.example.test/root/context?user=one"
   (resolve-caldav-discovery-location
    "../context?user=one"
    "https://calendar.example.test/root/bootstrap/start")
   :test #'string=)
  (assert-equal
   "https://other.example.test/new"
   (resolve-caldav-discovery-location
    "//other.example.test/new"
    "https://calendar.example.test/root")
   :test #'string=)
  (assert-equal
   :unsafe-caldav-resource-href
   (signaled-model-code
    (lambda ()
      (resolve-caldav-discovery-location
       "http://calendar.example.test/plaintext"
       "https://calendar.example.test/root"))))
  (assert-equal
   :encoded-caldav-redirect-dot-segment
   (signaled-model-code
    (lambda ()
      (resolve-caldav-discovery-location
       "/root/%2e%2e/private"
       "https://calendar.example.test/root")))))
