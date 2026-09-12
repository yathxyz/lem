(in-package #:lem-structured-notes/tests)

(defun ascii-octets (text)
  (let ((octets (make-array (length text) :element-type '(unsigned-byte 8))))
    (loop :for character :across text
          :for index :from 0
          :do (setf (aref octets index) (char-code character)))
    octets))

(define-foundation-test valid-utf8-icalendar-octets-are-source-preserved
  (let* ((crlf (format nil "~c~c" #\Return #\Newline))
         (prefix
           (ascii-octets
            (format nil "BEGIN:VCALENDAR~aX-NAME:Caf" crlf)))
         (suffix
           (ascii-octets (format nil "~aEND:VCALENDAR~a" crlf crlf)))
         (octets
           (concatenate '(vector (unsigned-byte 8))
                        prefix #(#xC3 #xA9) suffix))
         (input (parse-icalendar-octets octets :source-id "utf8.ics"))
         (calendar
           (first (ical-document-components
                   (ical-octet-input-document input))))
         (name (find-ical-property calendar "X-NAME")))
    (setf (aref octets 0) 0)
    (assert-true (ical-octet-input-utf8-valid-p input))
    (assert-equal "Café" (ical-content-line-value name) :test #'string=)
    (assert-equal (char-code #\B)
                  (aref (serialize-icalendar-octets input) 0))
    (assert-equal (ical-octet-input-octets input)
                  (serialize-icalendar-octets input) :test #'equalp)))

(define-foundation-test utf8-scalar-split-by-fold-is-unfolded-before-decoding
  (let* ((crlf (format nil "~c~c" #\Return #\Newline))
         (prefix
           (ascii-octets
            (format nil "BEGIN:VCALENDAR~aX-NAME:Caf" crlf)))
         (fold (ascii-octets (format nil "~a " crlf)))
         (suffix
           (ascii-octets (format nil "~aEND:VCALENDAR~a" crlf crlf)))
         (octets
           (concatenate '(vector (unsigned-byte 8))
                        prefix #(#xC3) fold #(#xA9) suffix))
         (input (parse-icalendar-octets octets :source-id "folded-utf8.ics"))
         (document (ical-octet-input-document input))
         (calendar (first (ical-document-components document)))
         (name (find-ical-property calendar "X-NAME")))
    (assert-true (ical-octet-input-utf8-valid-p input))
    (assert-equal "Café" (ical-content-line-value name) :test #'string=)
    (assert-false
     (search (format nil "~a " crlf) (ical-content-line-raw name)))
    (assert-equal octets (serialize-icalendar-octets input) :test #'equalp)
    (assert-equal
     (format nil "BEGIN:VCALENDAR~aX-NAME:Café~aEND:VCALENDAR~a"
             crlf crlf crlf)
     (ical-octet-input-decoded-source input) :test #'string=)))

(define-foundation-test utf8-folding-accepts-every-internal-scalar-boundary
  (let ((crlf (format nil "~c~c" #\Return #\Newline)))
    (dolist (case (list (cons #x20AC #(#xE2 #x82 #xAC))
                        (cons #x1F600 #(#xF0 #x9F #x98 #x80))))
      (loop :for split :from 1 :below (length (cdr case))
            :for whitespace := (if (oddp split) #\Tab #\Space)
            :for fold :=
              (ascii-octets (format nil "~a~c" crlf whitespace))
            :for octets :=
              (concatenate
               '(vector (unsigned-byte 8))
               (ascii-octets
                (format nil "BEGIN:VCALENDAR~aX-NAME:" crlf))
               (subseq (cdr case) 0 split)
               fold
               (subseq (cdr case) split)
               (ascii-octets
                (format nil "~aEND:VCALENDAR~a" crlf crlf)))
            :for input :=
              (parse-icalendar-octets
               octets :source-id "every-fold-boundary.ics")
            :for calendar :=
              (first
               (ical-document-components
                (ical-octet-input-document input)))
            :for property := (find-ical-property calendar "X-NAME")
            :do
               (assert-true (ical-octet-input-utf8-valid-p input))
               (assert-equal
                (string (code-char (car case)))
                (ical-content-line-value property) :test #'string=)
               (assert-equal
                octets (serialize-icalendar-octets input) :test #'equalp)))))

(define-foundation-test malformed-utf8-across-fold-remains-inert
  (let* ((crlf (ascii-octets (format nil "~c~c " #\Return #\Newline)))
         (octets
           (concatenate '(vector (unsigned-byte 8))
                        #(#xC3) crlf #(#x28)))
         (input (parse-icalendar-octets octets :source-id "bad-fold.ics"))
         (diagnostic (first (ical-octet-input-diagnostics input)))
         (span (diagnostic-span diagnostic)))
    (assert-false (ical-octet-input-utf8-valid-p input))
    (assert-false (ical-octet-input-decoded-source input))
    (assert-false (ical-octet-input-document input))
    (assert-equal :invalid-icalendar-utf8 (diagnostic-code diagnostic))
    (assert-equal 4 (source-span-byte-start span))
    (assert-equal 5 (source-span-byte-end span))
    (assert-equal octets (serialize-icalendar-octets input) :test #'equalp)))

(define-foundation-test malformed-utf8-remains-inert-exact-octets
  (dolist (octets
           (list #(#xC0 #xAF)
                 #(#xE2 #x82)
                 #(#xED #xA0 #x80)
                 #(#xF4 #x90 #x80 #x80)
                 #(#xC3 #x28)))
    (let* ((input (parse-icalendar-octets octets :source-id "invalid.ics"))
           (diagnostic (first (ical-octet-input-diagnostics input))))
      (assert-false (ical-octet-input-utf8-valid-p input))
      (assert-false (ical-octet-input-decoded-source input))
      (assert-false (ical-octet-input-document input))
      (assert-equal :invalid-icalendar-utf8
                    (diagnostic-code diagnostic))
      (assert-equal octets (serialize-icalendar-octets input)
                    :test #'equalp))))

(define-foundation-test icalendar-octet-ingress-enforces-entity-limit
  (let* ((octets #(65 66 67))
         (input
           (parse-icalendar-octets octets :source-id "large.ics"
                                   :max-input-octets 2)))
    (assert-false (ical-octet-input-utf8-valid-p input))
    (assert-equal :icalendar-octet-limit-exceeded
                  (diagnostic-code
                   (first (ical-octet-input-diagnostics input))))
    (assert-equal octets (serialize-icalendar-octets input) :test #'equalp)))
