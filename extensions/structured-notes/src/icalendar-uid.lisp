(in-package #:lem-structured-notes)

(defconstant +icalendar-uid-random-octets+ 16)

(defun icalendar-uid-os-random-data (count)
  #+unix
  (with-open-file
      (stream #p"/dev/urandom" :direction :input
                              :element-type '(unsigned-byte 8))
    (let ((octets
            (make-array count :element-type '(unsigned-byte 8))))
      (unless (= count (read-sequence octets stream))
        (error "OS entropy source returned fewer octets than requested"))
      octets))
  #-unix
  (declare (ignore count))
  #-unix
  (error "No supported OS entropy source is available"))

(defvar *icalendar-uid-random-data-function*
  #'icalendar-uid-os-random-data)

(defun icalendar-uid-random-octets-p (octets)
  (and (typep octets '(vector (unsigned-byte 8)))
       (= (length octets) +icalendar-uid-random-octets+)))

(defun encode-icalendar-uuid-v4 (random)
  (unless (icalendar-uid-random-octets-p random)
    (model-error
     :invalid-icalendar-uid-entropy :invalid-entropy
     "iCalendar UID entropy must contain exactly ~d octets"
     +icalendar-uid-random-octets+))
  (let ((octets (copy-seq random)))
    ;; RFC 9562 UUIDv4 version 4 and variant 10 fields replace six random bits.
    (setf (aref octets 6)
          (logior #x40 (logand #x0f (aref octets 6)))
          (aref octets 8)
          (logior #x80 (logand #x3f (aref octets 8))))
    (string-downcase
     (with-output-to-string (stream)
       (dotimes (index +icalendar-uid-random-octets+)
         (when (member index '(4 6 8 10))
           (write-char #\- stream))
         (format stream "~2,'0x" (aref octets index)))))))

(defun generate-icalendar-uid ()
  "Generate one privacy-preserving RFC 9562 UUIDv4 iCalendar UID.

The value contains no clock, user, host, network, or domain input, as required
by the RFC 7986 security and privacy update to RFC 5545 UID generation."
  (let ((random
          (handler-case
              (funcall *icalendar-uid-random-data-function*
                       +icalendar-uid-random-octets+)
            (error ()
              (model-error
               :icalendar-uid-entropy-failure :unavailable
               "OS cryptographic entropy is unavailable")))))
    (encode-icalendar-uuid-v4 random)))
