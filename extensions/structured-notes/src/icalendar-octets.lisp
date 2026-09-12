(in-package #:lem-structured-notes)

(defstruct (ical-octet-input
            (:constructor %make-ical-octet-input
                (octets decoded-source document diagnostics utf8-valid-p)))
  (octets #() :type vector :read-only t)
  (decoded-source nil :type (or null string) :read-only t)
  (document nil :type (or null ical-document) :read-only t)
  (diagnostics nil :type list :read-only t)
  (utf8-valid-p nil :type boolean :read-only t))

(defun copy-ical-octets (octets)
  (unless (vectorp octets)
    (model-error :invalid-icalendar-octets octets
                 "iCalendar octet input must be a vector"))
  (let ((copy (make-array (length octets) :element-type '(unsigned-byte 8))))
    (loop :for value :across octets
          :for index :from 0
          :do
             (unless (typep value '(unsigned-byte 8))
               (model-error :invalid-icalendar-octet value
                            "iCalendar byte ~d is not an unsigned octet" index))
             (setf (aref copy index) value))
    copy))

(defun utf8-continuation-p (octet)
  (<= #x80 octet #xBF))

(defun decode-icalendar-utf8 (octets)
  "Strictly decode OCTETS, returning text or an exact malformed byte range."
  (labels ((failure (start end message)
             (return-from decode-icalendar-utf8
               (values nil start end message)))
           (need (index count)
             (when (> (+ index count) (length octets))
               (failure index (length octets)
                        "truncated UTF-8 scalar value")))
           (continuation (index sequence-start)
             (let ((value (aref octets index)))
               (unless (utf8-continuation-p value)
                 (failure index (1+ index)
                          (format nil
                                  "invalid UTF-8 continuation after byte ~d"
                                  sequence-start)))
               value))
           (write-code (code stream start end)
             (let ((character (code-char code)))
               (unless character
                 (failure start end
                          "Unicode scalar is unavailable in this Lisp image"))
               (write-char character stream))))
    (with-output-to-string (stream)
      (loop :with index := 0
            :while (< index (length octets))
            :for first := (aref octets index)
            :do
               (cond
                 ((<= first #x7F)
                  (write-code first stream index (1+ index))
                  (incf index))
                 ((<= #xC2 first #xDF)
                  (need index 2)
                  (let* ((second (continuation (1+ index) index))
                         (code (logior (ash (logand first #x1F) 6)
                                       (logand second #x3F))))
                    (write-code code stream index (+ index 2))
                    (incf index 2)))
                 ((<= #xE0 first #xEF)
                  (need index 3)
                  (let ((second (continuation (1+ index) index))
                        (third (continuation (+ index 2) index)))
                    (when (or (and (= first #xE0) (< second #xA0))
                              (and (= first #xED) (> second #x9F)))
                      (failure index (+ index 3)
                               "overlong or surrogate UTF-8 scalar value"))
                    (let ((code
                            (logior (ash (logand first #x0F) 12)
                                    (ash (logand second #x3F) 6)
                                    (logand third #x3F))))
                      (write-code code stream index (+ index 3))
                      (incf index 3))))
                 ((<= #xF0 first #xF4)
                  (need index 4)
                  (let ((second (continuation (1+ index) index))
                        (third (continuation (+ index 2) index))
                        (fourth (continuation (+ index 3) index)))
                    (when (or (and (= first #xF0) (< second #x90))
                              (and (= first #xF4) (> second #x8F)))
                      (failure index (+ index 4)
                               "UTF-8 scalar value is outside Unicode"))
                    (let ((code
                            (logior (ash (logand first #x07) 18)
                                    (ash (logand second #x3F) 12)
                                    (ash (logand third #x3F) 6)
                                    (logand fourth #x3F))))
                      (write-code code stream index (+ index 4))
                      (incf index 4))))
                 (t
                  (failure index (1+ index)
                           "invalid UTF-8 leading byte")))))))

(defun unfold-icalendar-octets-for-utf8 (octets)
  "Remove RFC 5545 CRLF/WSP folds before UTF-8 decoding.
Return unfolded bytes, an output-byte to physical-byte map, and fold count."
  (let ((unfolded
          (make-array (length octets) :element-type '(unsigned-byte 8)
                      :adjustable t :fill-pointer 0))
        (physical-index
          (make-array (length octets) :element-type 'fixnum
                      :adjustable t :fill-pointer 0))
        (fold-count 0))
    (loop :with index := 0
          :while (< index (length octets))
          :do
             (if (and (< (+ index 2) (length octets))
                      (= #x0D (aref octets index))
                      (= #x0A (aref octets (1+ index)))
                      (member (aref octets (+ index 2)) '(#x20 #x09)))
                 (progn
                   (incf fold-count)
                   (incf index 3))
                 (progn
                   (vector-push-extend (aref octets index) unfolded)
                   (vector-push-extend index physical-index)
                   (incf index))))
    (values (copy-seq unfolded) (copy-seq physical-index) fold-count)))

(defun ical-unfolded-error-physical-range
    (physical-index error-start error-end physical-length)
  "Map one half-open unfolded UTF-8 error range to exact physical bytes."
  (if (zerop (length physical-index))
      (values 0 physical-length)
      (let* ((start-index (min error-start (1- (length physical-index))))
             (end-index
               (min (max error-start (1- error-end))
                    (1- (length physical-index)))))
        (values (aref physical-index start-index)
                (min physical-length
                     (1+ (aref physical-index end-index)))))))

(defun ical-octet-diagnostic (source-id code message byte-start byte-end
                              &key (severity :fatal) (loss-risk :security))
  (make-diagnostic
   :severity severity :code code :message message :loss-risk loss-risk
   :span (make-source-span
          :source-id source-id :character-start 0 :character-end 0
          :byte-start byte-start :byte-end byte-end)))

(defun parse-icalendar-octets
    (octets &key (source-id "calendar.ics") (max-input-octets 16777216))
  "Validate logical UTF-8 before constructing an iCalendar text CST.

RFC 5545 folds are removed at the octet layer when a fold splits a multi-octet
scalar.  Malformed logical input is never replacement-decoded.  The result
always retains an independent copy of the exact physical input octets."
  (require-non-empty-string source-id :invalid-source-id "source ID")
  (unless (and (integerp max-input-octets) (not (minusp max-input-octets)))
    (model-error :invalid-icalendar-octet-limit max-input-octets
                 "maximum input octets must be a non-negative integer"))
  (let ((copy (copy-ical-octets octets)))
    (when (> (length copy) max-input-octets)
      (let ((diagnostic
              (ical-octet-diagnostic
               source-id :icalendar-octet-limit-exceeded
               "iCalendar entity exceeds the configured byte limit"
               0 (length copy))))
        (return-from parse-icalendar-octets
          (%make-ical-octet-input copy nil nil (list diagnostic) nil))))
    (multiple-value-bind (source error-start error-end message)
        (decode-icalendar-utf8 copy)
      (when source
        (let ((document (parse-icalendar-cst source :source-id source-id)))
          (return-from parse-icalendar-octets
            (%make-ical-octet-input
             copy source document (ical-document-diagnostics document) t))))
      (multiple-value-bind (unfolded physical-index fold-count)
          (unfold-icalendar-octets-for-utf8 copy)
        (when (plusp fold-count)
          (multiple-value-bind
                (unfolded-source unfolded-error-start unfolded-error-end
                 unfolded-message)
              (decode-icalendar-utf8 unfolded)
            (when unfolded-source
              (let ((document
                      (parse-icalendar-cst
                       unfolded-source :source-id source-id)))
                (return-from parse-icalendar-octets
                  (%make-ical-octet-input
                   copy unfolded-source document
                   (ical-document-diagnostics document) t))))
            (setf message unfolded-message)
            (multiple-value-setq (error-start error-end)
              (ical-unfolded-error-physical-range
               physical-index unfolded-error-start unfolded-error-end
               (length copy)))))
        (let ((diagnostic
                (ical-octet-diagnostic
                 source-id :invalid-icalendar-utf8 message
                 error-start error-end)))
          (%make-ical-octet-input copy nil nil (list diagnostic) nil))))))

(defun serialize-icalendar-octets (input)
  "Return a fresh copy of the untouched entity bytes retained by INPUT."
  (unless (ical-octet-input-p input)
    (model-error :invalid-icalendar-octet-input input
                 "value must be an iCalendar octet input"))
  (copy-seq (ical-octet-input-octets input)))
