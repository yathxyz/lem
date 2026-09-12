(in-package #:lem-structured-notes)

(defconstant +caldav-resource-name-random-octets+ 16)

(defun caldav-resource-name-os-random-data (count)
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

(defvar *caldav-resource-name-random-data-function*
  #'caldav-resource-name-os-random-data)

(defun caldav-resource-name-octets-p (octets)
  (and (typep octets '(vector (unsigned-byte 8)))
       (= (length octets) +caldav-resource-name-random-octets+)))

(defun encode-caldav-opaque-resource-name (octets)
  (unless (caldav-resource-name-octets-p octets)
    (model-error
     :invalid-caldav-resource-name-entropy :invalid-entropy
     "CalDAV resource-name entropy must contain exactly ~d octets"
     +caldav-resource-name-random-octets+))
  (let ((name (make-string (* 2 +caldav-resource-name-random-octets+))))
    (dotimes (index +caldav-resource-name-random-octets+ name)
      (let ((octet (aref octets index)))
        (setf (char name (* 2 index))
              (char-downcase (digit-char (ldb (byte 4 4) octet) 16))
              (char name (1+ (* 2 index)))
              (char-downcase (digit-char (ldb (byte 4 0) octet) 16)))))))

(defun generate-caldav-opaque-resource-name ()
  "Generate one metadata-free path segment from 128 bits of OS entropy."
  (let ((octets
          (handler-case
              (funcall *caldav-resource-name-random-data-function*
                       +caldav-resource-name-random-octets+)
            (error ()
              (model-error
               :caldav-resource-name-entropy-failure :unavailable
               "OS cryptographic entropy is unavailable")))))
    (encode-caldav-opaque-resource-name octets)))
