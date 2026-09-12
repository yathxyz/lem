(in-package #:lem-structured-notes)

(defstruct (ical-property-profile
            (:constructor make-ical-property-profile
                (name default-type allowed-types list-p
                 allowed-control-parameters)))
  (name "" :type string :read-only t)
  (default-type :text :type keyword :read-only t)
  (allowed-types nil :type list :read-only t)
  (list-p nil :type boolean :read-only t)
  (allowed-control-parameters nil :type list :read-only t))

(defstruct (ical-property-value
            (:constructor %make-ical-property-value
                (line value-type values language media-type
                 typed-p valid-p diagnostics)))
  (line nil :type ical-content-line :read-only t)
  (value-type :unknown :type keyword :read-only t)
  (values nil :type list :read-only t)
  (language nil :type (or null string) :read-only t)
  (media-type nil :type (or null string) :read-only t)
  (typed-p nil :type boolean :read-only t)
  (valid-p nil :type boolean :read-only t)
  (diagnostics nil :type list :read-only t))

(defstruct (ical-property-presentation
            (:constructor %make-ical-property-presentation
                (ordinal property value language)))
  (ordinal 0 :type (integer 1 *) :read-only t)
  (property nil :type ical-property-value :read-only t)
  (value nil :type ical-value :read-only t)
  (language nil :type (or null string) :read-only t))

(defstruct (ical-property-presentation-set
            (:constructor %make-ical-property-presentation-set
                (component values diagnostics valid-p)))
  (component nil :type ical-component :read-only t)
  (values nil :type list :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-managed-attachment
            (:constructor %make-ical-managed-attachment
                (kind property uri managed-id media-type filename size
                 retrieval-safe-p diagnostics valid-p)))
  (kind :invalid :type (member :managed :unmanaged :invalid) :read-only t)
  (property nil :type ical-property-value :read-only t)
  (uri nil :type (or null ical-uri-value) :read-only t)
  (managed-id nil :type (or null string) :read-only t)
  (media-type nil :type (or null string) :read-only t)
  ;; This is untrusted display metadata and is never a local pathname.
  (filename nil :type (or null string) :read-only t)
  (size nil :type (or null integer) :read-only t)
  (retrieval-safe-p nil :type boolean :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-image
            (:constructor %make-ical-image
                (property kind uri binary media-type displays raw-displays
                 display-resolution alternate-uri retrieval-safe-p diagnostics
                 valid-p)))
  (property nil :type ical-property-value :read-only t)
  (kind :invalid :type (member :uri :binary :invalid) :read-only t)
  (uri nil :type (or null ical-uri-value) :read-only t)
  (binary nil :type (or null vector) :read-only t)
  (media-type nil :type (or null string) :read-only t)
  (displays nil :type list :read-only t)
  (raw-displays nil :type list :read-only t)
  (display-resolution :invalid-property :type keyword :read-only t)
  (alternate-uri nil :type (or null ical-uri-value) :read-only t)
  (retrieval-safe-p nil :type boolean :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defstruct (ical-conference
            (:constructor %make-ical-conference
                (property uri features feature-resolution label language
                 moderator-p retrieval-safe-p diagnostics valid-p)))
  (property nil :type ical-property-value :read-only t)
  (uri nil :type (or null ical-uri-value) :read-only t)
  (features nil :type list :read-only t)
  (feature-resolution :invalid-property :type keyword :read-only t)
  (label nil :type (or null string) :read-only t)
  (language nil :type (or null string) :read-only t)
  (moderator-p nil :type boolean :read-only t)
  (retrieval-safe-p nil :type boolean :read-only t)
  (diagnostics nil :type list :read-only t)
  (valid-p nil :type boolean :read-only t))

(defparameter *ical-value-type-names*
  '(("BINARY" . :binary)
    ("BOOLEAN" . :boolean)
    ("CAL-ADDRESS" . :cal-address)
    ("DATE" . :date)
    ("DATE-TIME" . :date-time)
    ("DURATION" . :duration)
    ("FLOAT" . :float)
    ("INTEGER" . :integer)
    ("PERIOD" . :period)
    ("RECUR" . :recur)
    ("TEXT" . :text)
    ("TIME" . :time)
    ("UID" . :uid)
    ("URI" . :uri)
    ("UTC-OFFSET" . :utc-offset)
    ("XML-REFERENCE" . :xml-reference)))

(defun ical-profile
    (name default-type &key allowed-types list-p allowed-control-parameters)
  (make-ical-property-profile
   name default-type (or allowed-types (list default-type)) list-p
   allowed-control-parameters))

(defparameter *ical-core-property-profiles*
  (mapcar
   (lambda (specification)
     (apply #'ical-profile specification))
   '(("ACTION" :text)
     ("ACKNOWLEDGED" :date-time)
     ("ATTACH" :uri :allowed-types (:uri :binary)
                    :allowed-control-parameters ("VALUE" "ENCODING"))
     ("ATTENDEE" :cal-address)
     ("BUSYTYPE" :text)
     ("CALSCALE" :text)
     ("CATEGORIES" :text :list-p t)
     ("CALENDAR-ADDRESS" :cal-address)
     ("CLASS" :text)
     ("COLOR" :text)
     ("COMMENT" :text)
     ("COMPLETED" :date-time)
     ("CONFERENCE" :uri :allowed-control-parameters ("VALUE"))
     ("CONCEPT" :uri)
     ("CONTACT" :text)
     ("CREATED" :date-time)
     ("DESCRIPTION" :text)
     ("DTEND" :date-time :allowed-types (:date-time :date)
                         :allowed-control-parameters ("VALUE" "TZID"))
     ("DTSTAMP" :date-time)
     ("DTSTART" :date-time :allowed-types (:date-time :date)
                           :allowed-control-parameters ("VALUE" "TZID"))
     ("DUE" :date-time :allowed-types (:date-time :date)
                       :allowed-control-parameters ("VALUE" "TZID"))
     ("DURATION" :duration)
     ("EXDATE" :date-time :allowed-types (:date-time :date) :list-p t
                          :allowed-control-parameters ("VALUE" "TZID"))
     ("FREEBUSY" :period :list-p t)
     ("IMAGE" :uri :allowed-types (:uri :binary)
                    :allowed-control-parameters ("VALUE" "ENCODING"))
     ("LAST-MODIFIED" :date-time)
     ("LINK" :uri :allowed-types (:uri :uid :xml-reference)
                   :allowed-control-parameters ("VALUE"))
     ("LOCATION" :text)
     ("LOCATION-TYPE" :text :list-p t)
     ("METHOD" :text)
     ("NAME" :text)
     ("ORGANIZER" :cal-address)
     ("PERCENT-COMPLETE" :integer)
     ("PRIORITY" :integer)
     ("PROXIMITY" :text)
     ("PRODID" :text)
     ("RDATE" :date-time :allowed-types (:date-time :date :period) :list-p t
                         :allowed-control-parameters ("VALUE" "TZID"))
     ("RECURRENCE-ID" :date-time :allowed-types (:date-time :date)
                                 :allowed-control-parameters ("VALUE" "TZID"))
     ("RELATED-TO" :uid :allowed-types (:uid :uri :text)
                   :allowed-control-parameters ("VALUE"))
     ("REFID" :text)
     ("REPEAT" :integer)
     ("REQUEST-STATUS" :request-status)
     ("REFRESH-INTERVAL" :duration
                         :allowed-control-parameters ("VALUE"))
     ("RESOURCES" :text :list-p t)
     ("RESOURCE-TYPE" :text)
     ("RRULE" :recur)
     ("SEQUENCE" :integer)
     ("SOURCE" :uri :allowed-control-parameters ("VALUE"))
     ("STATUS" :text)
     ("STYLED-DESCRIPTION" :text :allowed-types (:text :uri)
                            :allowed-control-parameters ("VALUE"))
     ("STRUCTURED-DATA" :text :allowed-types (:text :binary :uri)
                        :allowed-control-parameters ("VALUE" "ENCODING"))
     ("SUMMARY" :text)
     ("TRANSP" :text)
     ("TRIGGER" :duration :allowed-types (:duration :date-time)
                          :allowed-control-parameters ("VALUE"))
     ("TZID" :text)
     ("TZNAME" :text)
     ("TZOFFSETFROM" :utc-offset)
     ("TZOFFSETTO" :utc-offset)
     ("TZURL" :uri)
     ("UID" :text)
     ("URL" :uri)
     ("PARTICIPANT-TYPE" :text)
     ("VERSION" :text))))

(defparameter *ical-language-property-names*
  '("ATTENDEE" "CATEGORIES" "COMMENT" "CONFERENCE" "CONTACT" "DESCRIPTION"
    "LINK" "LOCATION" "NAME" "ORGANIZER" "REQUEST-STATUS" "RESOURCES" "SUMMARY"
    "STYLED-DESCRIPTION" "TZNAME"))

(defparameter *ical-explicit-value-property-names*
  '("CONFERENCE" "IMAGE" "LINK" "REFRESH-INTERVAL" "SOURCE"
    "STYLED-DESCRIPTION" "STRUCTURED-DATA"))

(defparameter *ical-format-type-property-names*
  '("ATTACH" "IMAGE" "LINK" "STYLED-DESCRIPTION" "STRUCTURED-DATA"))

(defparameter *ical-attendee-forbidden-context-parameter-names*
  '("CN" "CUTYPE" "DELEGATED-FROM" "DELEGATED-TO" "DIR" "LANGUAGE"
    "MEMBER" "PARTSTAT" "ROLE" "RSVP" "SENT-BY"))

(defun ical-attendee-restricted-context-p (property-name component-name)
  (and (string= property-name "ATTENDEE")
       (stringp component-name)
       (member component-name '("VFREEBUSY" "VALARM")
               :test #'string-equal)))

(defparameter *ical-request-status-component-names*
  '("VEVENT" "VTODO" "VJOURNAL" "VFREEBUSY"))

(defun ical-request-status-component-name-p (component-name)
  (and (stringp component-name)
       (member component-name *ical-request-status-component-names*
               :test #'string-equal)))

(defun ical-conference-component-name-p (component-name)
  (and (stringp component-name)
       (member component-name '("VEVENT" "VTODO") :test #'string-equal)))

(defparameter *ical-registered-metadata-parameter-policies*
  '(("ALTREP" :properties
       ("COMMENT" "CONTACT" "DESCRIPTION" "IMAGE" "LOCATION" "NAME" "RESOURCES"
        "SUMMARY")
       :kind :quoted-uri)
    ("CN" :properties ("ATTENDEE" "ORGANIZER") :kind :text)
    ("CUTYPE" :properties ("ATTENDEE") :kind :token)
    ("DELEGATED-FROM" :properties ("ATTENDEE") :kind :quoted-uri-list)
    ("DELEGATED-TO" :properties ("ATTENDEE") :kind :quoted-uri-list)
    ("DIR" :properties ("ATTENDEE" "ORGANIZER") :kind :quoted-uri)
    ("DISPLAY" :properties ("IMAGE") :kind :token-list)
    ("EMAIL" :properties ("ATTENDEE" "ORGANIZER") :kind :text)
    ("FBTYPE" :properties ("FREEBUSY") :kind :token)
    ("FEATURE" :properties ("CONFERENCE") :kind :token-list)
    ("LABEL" :properties ("CONFERENCE" "LINK") :kind :text)
    ("DERIVED" :properties :any :kind :boolean-token)
    ("GAP" :properties ("RELATED-TO") :kind :duration)
    ("LINKREL" :properties ("LINK") :kind :link-relation)
    ("MEMBER" :properties ("ATTENDEE") :kind :quoted-uri-list)
    ("PARTSTAT" :properties ("ATTENDEE") :kind :token)
    ("RANGE" :properties ("RECURRENCE-ID") :kind :this-and-future)
    ("RELATED" :properties ("TRIGGER") :kind :start-or-end)
    ("RELTYPE" :properties ("RELATED-TO") :kind :token)
    ("ORDER" :properties
       ("PARTICIPANT-TYPE" "RESOURCE-TYPE" "LOCATION-TYPE"
        "STYLED-DESCRIPTION" "STRUCTURED-DATA")
       :kind :positive-integer)
    ("ROLE" :properties ("ATTENDEE") :kind :token)
    ("RSVP" :properties ("ATTENDEE") :kind :boolean-token)
    ("SCHEMA" :properties ("STRUCTURED-DATA") :kind :quoted-uri)
    ("SENT-BY" :properties ("ATTENDEE" "ORGANIZER")
       :kind :quoted-mailto)))

(defparameter *ical-effective-token-parameter-policies*
  '(("CUTYPE" :registered
       ("INDIVIDUAL" "GROUP" "RESOURCE" "ROOM" "UNKNOWN")
       :default "INDIVIDUAL" :fallback "UNKNOWN")
    ("FBTYPE" :registered
       ("FREE" "BUSY" "BUSY-UNAVAILABLE" "BUSY-TENTATIVE")
       :default "BUSY" :fallback "BUSY")
    ("PARTSTAT" :registered
       ("NEEDS-ACTION" "ACCEPTED" "DECLINED" "TENTATIVE" "DELEGATED"
        "COMPLETED" "IN-PROCESS")
       :default "NEEDS-ACTION" :fallback "NEEDS-ACTION")
    ("RELTYPE" :registered
       ("PARENT" "CHILD" "SIBLING" "SNOOZE" "FINISHTOSTART"
        "FINISHTOFINISH" "STARTTOFINISH" "STARTTOSTART" "FIRST" "NEXT"
        "DEPENDS-ON" "REFID" "CONCEPT")
       :default "PARENT" :fallback "PARENT")
    ("ROLE" :registered
       ("CHAIR" "REQ-PARTICIPANT" "OPT-PARTICIPANT" "NON-PARTICIPANT")
       :default "REQ-PARTICIPANT" :fallback "REQ-PARTICIPANT")
    ("RSVP" :registered ("TRUE" "FALSE") :default "FALSE")))

(defparameter *ical-partstat-values-by-component*
  '(("VEVENT" "NEEDS-ACTION" "ACCEPTED" "DECLINED" "TENTATIVE"
              "DELEGATED")
    ("VTODO" "NEEDS-ACTION" "ACCEPTED" "DECLINED" "TENTATIVE"
             "DELEGATED" "COMPLETED" "IN-PROCESS")
    ("VJOURNAL" "NEEDS-ACTION" "ACCEPTED" "DECLINED")))

(defparameter *ical-grandfathered-language-tags*
  '("art-lojban" "cel-gaulish" "en-gb-oed" "i-ami" "i-bnn"
    "i-default" "i-enochian" "i-hak" "i-klingon" "i-lux" "i-mingo"
    "i-navajo" "i-pwn" "i-tao" "i-tay" "i-tsu" "no-bok" "no-nyn"
    "sgn-be-fr" "sgn-be-nl" "sgn-ch-de" "zh-guoyu" "zh-hakka"
    "zh-min" "zh-min-nan" "zh-xiang"))

(defun ical-ascii-alpha-p (character)
  (or (and (char<= #\A character) (char<= character #\Z))
      (and (char<= #\a character) (char<= character #\z))))

(defun ical-ascii-digit-p (character)
  (and (char<= #\0 character) (char<= character #\9)))

(defun ical-ascii-alphanumeric-p (character)
  (or (ical-ascii-alpha-p character) (ical-ascii-digit-p character)))

(defun ical-language-subtags (tag)
  (let ((subtags nil)
        (start 0))
    (loop :for index :from 0 :below (length tag)
          :when (char= #\- (char tag index))
            :do (push (subseq tag start index) subtags)
                (setf start (1+ index)))
    (push (subseq tag start) subtags)
    (nreverse subtags)))

(defun ical-language-subtag-p
    (subtag minimum maximum &key alpha-only digit-only)
  (and (<= minimum (length subtag) maximum)
       (every (cond (alpha-only #'ical-ascii-alpha-p)
                    (digit-only #'ical-ascii-digit-p)
                    (t #'ical-ascii-alphanumeric-p))
              subtag)))

(defun ical-language-variant-subtag-p (subtag)
  (or (ical-language-subtag-p subtag 5 8)
      (and (= 4 (length subtag))
           (ical-ascii-digit-p (char subtag 0))
           (every #'ical-ascii-alphanumeric-p subtag))))

(defun ical-well-formed-language-tag-p (tag)
  "Return true for a well-formed RFC 5646 Language-Tag.

This validates the complete ABNF plus the no-duplicate variant and extension
singleton rules.  It does not claim that registry-dependent subtags are
currently assigned."
  (and (stringp tag)
       (plusp (length tag))
       (or (member (string-downcase tag) *ical-grandfathered-language-tags*
                   :test #'string=)
           (let* ((subtags (ical-language-subtags tag))
                  (count (length subtags)))
             (and (every (lambda (subtag)
                           (ical-language-subtag-p subtag 1 8))
                         subtags)
                  (labels ((subtag (index) (and (< index count)
                                                (nth index subtags)))
                           (private-use-tail-p (index)
                             (and (< index count)
                                  (string-equal "x" (subtag index))
                                  (< (1+ index) count)
                                  (loop :for tail :in (nthcdr (1+ index) subtags)
                                        :always
                                        (ical-language-subtag-p tail 1 8)))))
                    (if (string-equal "x" (first subtags))
                        (private-use-tail-p 0)
                        (let ((index 0)
                              (variants (make-hash-table :test #'equal))
                              (singletons (make-hash-table :test #'equal)))
                          (cond
                            ((ical-language-subtag-p
                              (subtag index) 2 3 :alpha-only t)
                             (incf index)
                             (loop :repeat 3
                                   :while (and (< index count)
                                               (ical-language-subtag-p
                                                (subtag index) 3 3
                                                :alpha-only t))
                                   :do (incf index)))
                            ((ical-language-subtag-p
                              (subtag index) 4 4 :alpha-only t)
                             (incf index))
                            ((ical-language-subtag-p
                              (subtag index) 5 8 :alpha-only t)
                             (incf index))
                            (t (return-from ical-well-formed-language-tag-p nil)))
                          (when (and (< index count)
                                     (ical-language-subtag-p
                                      (subtag index) 4 4 :alpha-only t))
                            (incf index))
                          (when (and (< index count)
                                     (or (ical-language-subtag-p
                                          (subtag index) 2 2 :alpha-only t)
                                         (ical-language-subtag-p
                                          (subtag index) 3 3 :digit-only t)))
                            (incf index))
                          (loop :while (and (< index count)
                                            (ical-language-variant-subtag-p
                                             (subtag index)))
                                :for key := (string-downcase (subtag index))
                                :do
                                   (when (gethash key variants)
                                     (return-from ical-well-formed-language-tag-p nil))
                                   (setf (gethash key variants) t)
                                   (incf index))
                          (loop :while (and (< index count)
                                            (= 1 (length (subtag index)))
                                            (not (string-equal "x"
                                                               (subtag index))))
                                :for key := (string-downcase (subtag index))
                                :do
                                   (when (gethash key singletons)
                                     (return-from ical-well-formed-language-tag-p nil))
                                   (setf (gethash key singletons) t)
                                   (incf index)
                                   (let ((start index))
                                     (loop :while
                                             (and (< index count)
                                                  (ical-language-subtag-p
                                                   (subtag index) 2 8))
                                           :do (incf index))
                                     (when (= start index)
                                       (return-from
                                           ical-well-formed-language-tag-p nil))))
                          (or (= index count)
                              (and (private-use-tail-p index) t))))))))))

(defun find-ical-property-profile (name)
  (find name *ical-core-property-profiles*
        :key #'ical-property-profile-name :test #'string=))

(defparameter *ical-decoding-control-parameter-names*
  '("VALUE" "TZID" "ENCODING"))

(defun ical-value-type-name (type)
  (car (rassoc type *ical-value-type-names*)))

(defun ical-media-type-name-first-character-p (character)
  (or (and (char<= #\A character) (char<= character #\Z))
      (and (char<= #\a character) (char<= character #\z))
      (and (char<= #\0 character) (char<= character #\9))))

(defun ical-media-type-name-character-p (character)
  (or (ical-media-type-name-first-character-p character)
      (find character "!#$&-^_.+" :test #'char=)))

(defun ical-valid-media-type-name-p (name)
  (and (<= 1 (length name) 127)
       (ical-media-type-name-first-character-p (char name 0))
       (every #'ical-media-type-name-character-p name)))

(defun ical-valid-media-type-text-p (text)
  (and (stringp text)
       (let ((slash (position #\/ text)))
         (and slash
              (null (position #\/ text :start (1+ slash)))
              (ical-valid-media-type-name-p (subseq text 0 slash))
              (ical-valid-media-type-name-p (subseq text (1+ slash)))))))

(defun ical-image-media-type-p (text)
  (and (ical-valid-media-type-text-p text)
       (string-equal "image" (subseq text 0 (position #\/ text)))))

(defun ical-rfc7986-generated-uid-p (value)
  (and (stringp value)
       (< (ical-string-utf8-octets value) 255)
       (ical-token-p value)))

(defun ical-registered-metadata-parameter-policy (name)
  (assoc name *ical-registered-metadata-parameter-policies* :test #'string=))

(defun ical-effective-token-parameter-policy (name)
  (assoc name *ical-effective-token-parameter-policies* :test #'string=))

(defun ical-partstat-values-for-component (component-name)
  (rest (assoc component-name *ical-partstat-values-by-component*
               :test #'string-equal)))

(defun ical-resolve-effective-token-parameter
    (name raw &key component-name)
  "Resolve an RFC 5545 token parameter without changing its source token.

The secondary value is :DEFAULT, :REGISTERED, :FALLBACK,
:INVALID-CONTEXT, or :INVALID-VALUE."
  (let* ((normalized-name (string-upcase name))
         (policy (ical-effective-token-parameter-policy normalized-name)))
    (unless policy
      (model-error :unsupported-icalendar-effective-parameter name
                   "parameter has no RFC 5545 effective-token policy"))
    (let* ((registered (getf (rest policy) :registered))
           (default (getf (rest policy) :default))
           (fallback (getf (rest policy) :fallback))
           (normalized-raw (and raw (string-upcase raw)))
           (partstat-p (string= normalized-name "PARTSTAT"))
           (context-values
             (and partstat-p component-name
                  (ical-partstat-values-for-component component-name))))
      (cond
        ((and partstat-p component-name (null context-values))
         (values nil :invalid-context))
        ((null normalized-raw)
         (values default :default))
        ((and partstat-p context-values
              (member normalized-raw registered :test #'string=)
              (not (member normalized-raw context-values :test #'string=)))
         (values nil :invalid-context))
        ((member normalized-raw
                 (or context-values registered) :test #'string=)
         (values normalized-raw :registered))
        (fallback
         (values fallback :fallback))
        (t
         (values nil :invalid-value))))))

(defun ical-parameter-kind-allows-many-values-p (kind)
  (member kind '(:quoted-uri-list :token-list :link-relation)))

(defun ical-parameter-kind-requires-quoted-values-p (kind)
  (member kind '(:quoted-uri :quoted-uri-list :quoted-mailto)))

(defun ical-parameter-kind-requires-unquoted-values-p (kind)
  (member kind '(:token :token-list :this-and-future :start-or-end
                 :boolean-token :positive-integer :duration)))

(defun ical-valid-absolute-uri-parameter-p (text &key mailto-only)
  (multiple-value-bind (uri valid-p message) (decode-ical-uri text)
    (declare (ignore message))
    (and valid-p
         (or (not mailto-only)
             (string-equal "mailto" (ical-uri-value-scheme uri))))))

(defun ical-registered-metadata-value-valid-p (kind text)
  (case kind
    ((:quoted-uri :quoted-uri-list)
     (ical-valid-absolute-uri-parameter-p text))
    (:quoted-mailto
     (ical-valid-absolute-uri-parameter-p text :mailto-only t))
    (:text t)
    ((:token :token-list) (ical-token-p text))
    (:this-and-future (string-equal text "THISANDFUTURE"))
    (:start-or-end
     (or (string-equal text "START") (string-equal text "END")))
    (:boolean-token
     (or (string-equal text "TRUE") (string-equal text "FALSE")))
    (:positive-integer
     (and (plusp (length text))
          (every #'ical-ascii-digit-p text)
          (plusp (parse-integer text))))
    (:duration
     (nth-value 1 (decode-ical-duration text)))
    (:link-relation
     (or (ical-token-p text)
         (ical-valid-absolute-uri-parameter-p text)))
    (otherwise nil)))

(defun ical-registered-parameter-allows-property-p (policy property-name)
  (let ((properties (getf (rest policy) :properties)))
    (or (eq properties :any)
        (member property-name properties :test #'string=))))

(defun ical-output-registered-metadata-parameter
    (parameter profile value-type component-name)
  (let* ((name (string-upcase (first parameter)))
         (policy (ical-registered-metadata-parameter-policy name)))
    (when policy
      (let ((kind (getf (rest policy) :kind))
            (values (rest parameter)))
        (unless (and (or (ical-parameter-kind-allows-many-values-p kind)
                         (= 1 (length values)))
                     (every (lambda (value)
                              (ical-registered-metadata-value-valid-p
                               kind value))
                            values))
          (model-error
           :invalid-icalendar-output-registered-parameter parameter
           "registered parameter has invalid cardinality or value syntax"))
        (unless (ical-registered-parameter-allows-property-p
                 policy (ical-property-profile-name profile))
          (model-error
           :disallowed-icalendar-output-registered-parameter parameter
           "property does not permit this registered parameter"))
        (when (and (string= name "RELATED")
                   (not (eq value-type :duration)))
          (model-error
           :invalid-icalendar-output-related-coupling parameter
           "RELATED is valid only on a DURATION-valued TRIGGER"))
        (when (string= name "PARTSTAT")
          (unless component-name
            (model-error
             :missing-icalendar-output-partstat-component parameter
             "PARTSTAT output requires its enclosing component name"))
          (unless (stringp component-name)
            (model-error
             :invalid-icalendar-output-partstat-component component-name
             "PARTSTAT output component name must be a string"))
          (multiple-value-bind (effective resolution)
              (ical-resolve-effective-token-parameter
               "PARTSTAT" (first values) :component-name component-name)
            (declare (ignore effective))
            (when (member resolution '(:invalid-context :invalid-value))
              (model-error
               :invalid-icalendar-output-partstat-component
               (list parameter component-name)
               "PARTSTAT is not valid for its enclosing component"))))))))

(defun ical-output-extension-parameters
    (parameters profile value-type component-name)
  (unless (proper-list-p parameters)
    (model-error :invalid-icalendar-output-parameters parameters
                 "property parameters must be a finite ordered list"))
  (let ((language-count 0)
        (format-type-count 0)
        (registered-counts (make-hash-table :test #'equal)))
    (dolist (parameter parameters)
      ;; Validate the complete low-level shape before inspecting its name.
      (ical-output-parameter parameter)
      (let ((name (string-upcase (first parameter))))
        (when (and (ical-attendee-restricted-context-p
                    (ical-property-profile-name profile) component-name)
                   (member name
                           *ical-attendee-forbidden-context-parameter-names*
                           :test #'string=))
          (model-error
           :disallowed-icalendar-output-attendee-context-parameter parameter
           "VFREEBUSY and VALARM ATTENDEE properties forbid participant parameters"))
        (when (member name *ical-decoding-control-parameter-names*
                      :test #'string=)
          (model-error
           :reserved-icalendar-output-control-parameter parameter
           "VALUE, TZID, and ENCODING are selected by the typed writer"))
        (when (ical-registered-metadata-parameter-policy name)
          (when (> (incf (gethash name registered-counts 0)) 1)
            (model-error
             :duplicate-icalendar-output-registered-parameter parameter
             "registered parameters must not occur more than once"))
          (ical-output-registered-metadata-parameter
           parameter profile value-type component-name))
        (when (string= name "LANGUAGE")
          (incf language-count)
          (unless (and (= language-count 1)
                       (= 2 (length parameter))
                       (ical-well-formed-language-tag-p (second parameter)))
            (model-error
             :invalid-icalendar-output-language parameter
             "LANGUAGE must occur once with one well-formed RFC 5646 tag"))
          (unless (member (ical-property-profile-name profile)
                          *ical-language-property-names* :test #'string=)
            (model-error
             :disallowed-icalendar-output-language parameter
             "property does not permit the LANGUAGE parameter")))
        (when (string= name "FMTTYPE")
          (incf format-type-count)
          (unless (and (= format-type-count 1)
                       (= 2 (length parameter))
                       (ical-valid-media-type-text-p (second parameter)))
            (model-error
             :invalid-icalendar-output-format-type parameter
             "FMTTYPE must occur once with one type/subtype media type"))
          (unless (member (ical-property-profile-name profile)
                          *ical-format-type-property-names* :test #'string=)
            (model-error
             :disallowed-icalendar-output-format-type parameter
             "property does not permit the FMTTYPE parameter"))
          (when (and (string= "IMAGE" (ical-property-profile-name profile))
                     (= 2 (length parameter))
                     (not (ical-image-media-type-p (second parameter))))
            (model-error
             :invalid-icalendar-output-image-format-type parameter
             "IMAGE FMTTYPE must use the image top-level media type")))))
    (copy-tree parameters)))

(defun generate-ical-property-line
    (name value &key value-type group (parameters nil) component-name
                     (max-unfolded-octets 1048576)
                     (max-binary-octets 8388608))
  "Generate one registered property from typed semantic VALUE.

For declared list properties VALUE must be a non-empty proper list.  This
function owns the registered VALUE, TZID, and ENCODING control parameters;
PARAMETERS is reserved for ordered extension or non-decoding metadata.
COMPONENT-NAME is mandatory for REQUEST-STATUS and when PARAMETERS contains
PARTSTAT."
  (unless (stringp name)
    (model-error :invalid-icalendar-output-name name
                 "typed property name must be a string"))
  (let* ((normalized-name (string-upcase name))
         (profile (find-ical-property-profile normalized-name)))
    (unless profile
      (model-error :unsupported-icalendar-output-property name
                   "typed property generation requires a registered profile"))
    (when (and (string= normalized-name "REQUEST-STATUS")
               (not (ical-request-status-component-name-p component-name)))
      (model-error :invalid-icalendar-output-request-status-component
                   component-name
                   "REQUEST-STATUS output requires VEVENT VTODO VJOURNAL or VFREEBUSY context"))
    (when (and (string= normalized-name "CONFERENCE")
               (not (ical-conference-component-name-p component-name)))
      (model-error :invalid-icalendar-output-conference-component
                   component-name
                   "CONFERENCE output requires VEVENT or VTODO context"))
    (let ((type (or value-type
                    (ical-property-profile-default-type profile))))
      (unless (member type (ical-property-profile-allowed-types profile))
        (model-error :disallowed-icalendar-output-value-type type
                     "property does not permit the requested value type"))
      (let* ((values
               (if (ical-property-profile-list-p profile)
                   (progn
                     (unless (and (proper-list-p value) value)
                       (model-error :invalid-icalendar-output-property-list value
                                    "list property requires one or more values"))
                     value)
                   (list value)))
             (raw-values nil)
             (timezone-id nil)
             (timezone-seen-p nil))
        (dolist (semantic values)
          (when (and (string= normalized-name "UID")
                     (not (ical-rfc7986-generated-uid-p semantic)))
            (model-error
             :invalid-rfc7986-output-uid semantic
             "generated UID must be an iana-token shorter than 255 octets"))
          (multiple-value-bind (raw semantic-timezone-id)
              (encode-ical-value
               semantic type :max-binary-octets max-binary-octets)
            (if timezone-seen-p
                (unless (equal timezone-id semantic-timezone-id)
                  (model-error :incompatible-icalendar-output-timezones value
                               "all values on one property line require one TZID"))
                (setf timezone-id semantic-timezone-id
                      timezone-seen-p t))
            (push raw raw-values)))
        (let ((control-parameters nil))
          (when (or (member normalized-name
                            *ical-explicit-value-property-names*
                            :test #'string=)
                    (not (eq type
                             (ical-property-profile-default-type profile)))
                    (eq type :binary))
            (push (list "VALUE" (ical-value-type-name type))
                  control-parameters))
          (when timezone-id
            (push (list "TZID" timezone-id) control-parameters))
          (when (eq type :binary)
            (push '("ENCODING" "BASE64") control-parameters))
          (setf control-parameters (nreverse control-parameters))
          (dolist (parameter control-parameters)
            (unless (member (first parameter)
                            (ical-property-profile-allowed-control-parameters
                             profile)
                            :test #'string=)
              (model-error :disallowed-icalendar-output-control-parameter
                           parameter
                           "property does not permit a required control parameter")))
          (let ((extension-parameters
                  (ical-output-extension-parameters
                   parameters profile type component-name)))
            ;; Inline ATTACH content is exceptional and FMTTYPE is recommended.
            ;; When the caller has no more specific knowledge, emit the RFC 5545
            ;; fallback instead of generating media-type-ambiguous content.
            (when (and (eq type :binary)
                       (string= normalized-name "ATTACH")
                       (not (find "FMTTYPE" extension-parameters
                                  :key (lambda (parameter)
                                         (string-upcase (first parameter)))
                                  :test #'string=)))
              (setf extension-parameters
                    (append extension-parameters
                            '(("FMTTYPE" "application/octet-stream")))))
            (generate-ical-content-line
             normalized-name
             (ical-recur-join (nreverse raw-values) #\,)
             :group group
             :parameters (append control-parameters extension-parameters)
             :max-unfolded-octets max-unfolded-octets)))))))

(defun ical-property-diagnostic (line code message)
  (make-diagnostic :severity :error :code code :message message
                   :span (ical-content-line-span line) :loss-risk :none))

(defun ical-parameters-named (line name)
  (remove-if-not
   (lambda (parameter)
     (string= name (ical-parameter-normalized-name parameter)))
   (ical-content-line-parameters line)))

(defun ical-single-parameter-text (line name)
  (let ((parameters (ical-parameters-named line name)))
    (cond
      ((null parameters) (values nil t nil nil))
      ((or (rest parameters)
           (/= 1 (length (ical-parameter-values (first parameters)))))
       (values nil nil
               (ical-property-diagnostic
                line :invalid-icalendar-property-parameter-cardinality
                (format nil "~a must occur once with one value" name))
               nil))
      (t
       (let ((value (first (ical-parameter-values (first parameters)))))
         (values (ical-parameter-value-decoded-text value)
                 t nil (ical-parameter-value-quoted-p value)))))))

(defun ical-registered-metadata-parameter-diagnostics
    (line profile &key component-name)
  (let ((diagnostics nil)
        (property-name (ical-content-line-normalized-name line)))
    (dolist (policy *ical-registered-metadata-parameter-policies*)
      (let* ((name (first policy))
             (kind (getf (rest policy) :kind))
             (parameters (ical-parameters-named line name)))
        (when parameters
          (let ((values (mapcan (lambda (parameter)
                                  (copy-list
                                   (ical-parameter-values parameter)))
                                parameters)))
            (when (or (rest parameters)
                      (and (not (ical-parameter-kind-allows-many-values-p kind))
                           (/= 1 (length values))))
              (push (ical-property-diagnostic
                     line :invalid-icalendar-registered-parameter-cardinality
                     (format nil
                             "~a must occur at most once~:[ with one value~;~]"
                             name
                             (ical-parameter-kind-allows-many-values-p kind)))
                    diagnostics))
            (dolist (value values)
              (let ((text (ical-parameter-value-decoded-text value))
                    (quoted-p (ical-parameter-value-quoted-p value)))
                (when (and (ical-parameter-kind-requires-quoted-values-p kind)
                           (not quoted-p))
                  (push (ical-property-diagnostic
                         line :unquoted-icalendar-registered-parameter
                         (format nil "~a values must use quoted-string syntax"
                                 name))
                        diagnostics))
                (when (and (ical-parameter-kind-requires-unquoted-values-p kind)
                           quoted-p)
                  (push (ical-property-diagnostic
                         line :quoted-icalendar-registered-parameter
                         (format nil "~a values must use unquoted token syntax"
                                 name))
                        diagnostics))
                (unless (ical-registered-metadata-value-valid-p kind text)
                  (push (ical-property-diagnostic
                         line :invalid-icalendar-registered-parameter-value
                         (format nil "~a has invalid registered value syntax"
                                 name))
                        diagnostics))))
            (when (and profile
                       (not (ical-registered-parameter-allows-property-p
                             policy property-name)))
              (push (ical-property-diagnostic
                     line :disallowed-icalendar-registered-parameter
                     (format nil "~a does not permit the ~a parameter"
                             property-name name))
                    diagnostics))))))
    (when (ical-attendee-restricted-context-p property-name component-name)
      (dolist (name *ical-attendee-forbidden-context-parameter-names*)
        (when (ical-parameters-named line name)
          (push
           (ical-property-diagnostic
            line :disallowed-icalendar-attendee-context-parameter
            (format nil
                    "~a ATTENDEE properties must not carry the ~a parameter"
                    component-name name))
           diagnostics))))
    (when (and component-name
               (ical-parameters-named line "PARTSTAT"))
      (multiple-value-bind (text cardinality-valid-p)
          (ical-single-parameter-text line "PARTSTAT")
        (when cardinality-valid-p
          (multiple-value-bind (effective resolution)
              (ical-resolve-effective-token-parameter
               "PARTSTAT" text :component-name component-name)
            (declare (ignore effective))
            (when (eq resolution :invalid-context)
              (push
               (ical-property-diagnostic
                line :invalid-icalendar-partstat-component
                (format nil "PARTSTAT value ~a is not valid in ~a"
                        text component-name))
               diagnostics))))))
    (nreverse diagnostics)))

(defun ical-managed-attachment-uri-retrieval-safe-p (uri)
  (and (ical-uri-value-p uri)
       (string-equal "https" (ical-uri-value-scheme uri))
       (ical-uri-value-authority uri)
       (non-empty-string-p (ical-uri-value-host uri))
       (null (ical-uri-value-userinfo uri))
       (null (ical-uri-value-fragment uri))))

(defun project-ical-image (property)
  "Project one RFC 7986 IMAGE as inert data without dereferencing either URI."
  (unless (and (ical-property-value-p property)
               (string= "IMAGE"
                        (ical-content-line-normalized-name
                         (ical-property-value-line property))))
    (model-error :invalid-icalendar-image-property property
                 "IMAGE projection requires one decoded IMAGE property"))
  (let* ((line (ical-property-value-line property))
         (diagnostics (copy-list (ical-property-value-diagnostics property)))
         (value
           (and (ical-property-value-valid-p property)
                (first (ical-property-value-values property))))
         (decoded (and value (ical-value-decoded value)))
         (kind
           (case (ical-property-value-value-type property)
             (:uri :uri)
             (:binary :binary)
             (otherwise :invalid)))
         (alternate-uri nil))
    (multiple-value-bind (alternate-text cardinality-valid-p diagnostic)
        (ical-single-parameter-text line "ALTREP")
      (unless cardinality-valid-p
        (push diagnostic diagnostics))
      (when alternate-text
        (multiple-value-bind (uri valid-p message)
            (decode-ical-uri alternate-text)
          (if valid-p
              (setf alternate-uri uri)
              (push (ical-property-diagnostic
                     line :invalid-icalendar-image-alternate-uri message)
                    diagnostics)))))
    (multiple-value-bind (displays raw-displays display-resolution)
        (ical-property-effective-image-displays property)
      (%make-ical-image
       property kind
       (and (eq kind :uri) decoded)
       (and (eq kind :binary) decoded)
       (ical-property-effective-media-type property)
       displays raw-displays display-resolution alternate-uri
       (and (eq kind :uri)
            (ical-managed-attachment-uri-retrieval-safe-p decoded))
       diagnostics (null diagnostics)))))

(defun project-ical-conference (property)
  "Project one RFC 7986 CONFERENCE as inert URI data without accessing it."
  (unless (and (ical-property-value-p property)
               (string= "CONFERENCE"
                        (ical-content-line-normalized-name
                         (ical-property-value-line property))))
    (model-error :invalid-icalendar-conference-property property
                 "conference projection requires one CONFERENCE property"))
  (let* ((diagnostics (copy-list (ical-property-value-diagnostics property)))
         (value
           (and (ical-property-value-valid-p property)
                (first (ical-property-value-values property))))
         (uri (and value (ical-value-decoded value))))
    (multiple-value-bind (features feature-resolution)
        (ical-property-effective-conference-features property)
      (multiple-value-bind (label label-valid-p)
          (ical-property-conference-label property)
        (declare (ignore label-valid-p))
        (%make-ical-conference
         property uri features feature-resolution label
         (ical-property-value-language property)
         (not (null (member "MODERATOR" features :test #'string=)))
         (and uri (ical-managed-attachment-uri-retrieval-safe-p uri))
         diagnostics (null diagnostics))))))

(defun project-ical-managed-attachment (property)
  "Project one ATTACH property without treating FILENAME as a pathname."
  (unless (and (ical-property-value-p property)
               (string= "ATTACH"
                        (ical-content-line-normalized-name
                         (ical-property-value-line property))))
    (model-error :invalid-icalendar-managed-attachment-property property
                 "managed attachment projection requires an ATTACH property"))
  (let* ((line (ical-property-value-line property))
         (diagnostics (copy-list (ical-property-value-diagnostics property)))
         (managed-id nil)
         (media-type (ical-property-value-media-type property))
         (filename nil)
         (size-text nil))
    (labels ((read-parameter (name)
               (multiple-value-bind (value valid-p diagnostic)
                   (ical-single-parameter-text line name)
                 (unless valid-p
                   (push diagnostic diagnostics))
                 value)))
      (setf managed-id (read-parameter "MANAGED-ID")
            filename (read-parameter "FILENAME")
            size-text (read-parameter "SIZE")))
    (let* ((value
             (and (ical-property-value-valid-p property)
                  (first (ical-property-value-values property))))
           (decoded (and value (ical-value-decoded value)))
           (uri (and (eq :uri (ical-property-value-value-type property))
                     (ical-uri-value-p decoded)
                     decoded))
           (managed-p
             (not (null (ical-parameters-named line "MANAGED-ID"))))
           (size nil))
      (when managed-p
        (unless (and managed-id (plusp (length managed-id))
                     (<= (length managed-id) 4096))
          (push (ical-property-diagnostic
                 line :invalid-icalendar-managed-id
                 "MANAGED-ID must be one non-empty bounded parameter value")
                diagnostics))
        (unless (and uri
                     (member (string-downcase (ical-uri-value-scheme uri))
                             '("http" "https") :test #'string=)
                     (ical-uri-value-authority uri))
          (push (ical-property-diagnostic
                 line :invalid-icalendar-managed-attachment-uri
                 "managed ATTACH requires an absolute HTTP(S) URI")
                diagnostics)))
      (when (and filename (not managed-p))
        (push (ical-property-diagnostic
               line :filename-on-unmanaged-icalendar-attachment
               "FILENAME is only defined for managed ATTACH properties")
              diagnostics))
      (when (and filename
                 (or (zerop (length filename)) (> (length filename) 4096)))
        (push (ical-property-diagnostic
               line :invalid-icalendar-attachment-filename
               "FILENAME must be non-empty and bounded")
              diagnostics))
      (when size-text
        (if (and (plusp (length size-text))
                 (every (lambda (character)
                          (and (char<= #\0 character)
                               (char<= character #\9)))
                        size-text)
                 (<= (length size-text) 19))
            (let ((parsed (parse-integer size-text)))
              (if (and (plusp parsed) (<= parsed (1- (ash 1 63))))
                  (setf size parsed)
                  (push (ical-property-diagnostic
                         line :invalid-icalendar-attachment-size
                         "SIZE must be a positive signed-63-bit decimal integer")
                        diagnostics)))
            (push (ical-property-diagnostic
                   line :invalid-icalendar-attachment-size
                   "SIZE must be a positive signed-63-bit decimal integer")
                  diagnostics)))
      (setf diagnostics (nreverse diagnostics))
      (%make-ical-managed-attachment
       (cond (diagnostics :invalid) (managed-p :managed) (t :unmanaged))
       property uri (and managed-p managed-id) media-type filename size
       (and managed-p (ical-managed-attachment-uri-retrieval-safe-p uri))
       diagnostics (null diagnostics)))))

(defun ical-control-parameter-applicability-diagnostics (line profile)
  (when profile
    (let ((allowed
            (ical-property-profile-allowed-control-parameters profile)))
      (loop :for parameter :in (ical-content-line-parameters line)
            :for name := (ical-parameter-normalized-name parameter)
            :when (and (member name *ical-decoding-control-parameter-names*
                               :test #'string=)
                       (not (member name allowed :test #'string=)))
              :collect
              (ical-property-diagnostic
               line :disallowed-icalendar-property-parameter
               (format nil "~a does not permit the ~a parameter"
                       (ical-property-profile-name profile) name))))))

(defun ical-split-property-list (raw text-p)
  (let ((parts nil)
        (start 0)
        (escaped-p nil))
    (loop :for index :from 0 :below (length raw)
          :for character := (char raw index)
          :do
             (cond
               ((and text-p escaped-p) (setf escaped-p nil))
               ((and text-p (char= character #\\)) (setf escaped-p t))
               ((char= character #\,)
                (push (subseq raw start index) parts)
                (setf start (1+ index)))))
    (push (subseq raw start) parts)
    (nreverse parts)))

(defun ical-untyped-property-value
    (line &optional diagnostics language media-type)
  (%make-ical-property-value
   line :unknown
   (list (%make-ical-value :unknown (ical-content-line-value line)
                           (ical-content-line-value line) t nil))
   language media-type nil (null diagnostics) diagnostics))

(defun decode-ical-content-line-value
    (line &key (max-value-characters 16384)
               (max-binary-octets 8388608)
               component-name)
  "Apply the selected core property profile to one retained content line."
  (unless (ical-content-line-p line)
    (model-error :invalid-icalendar-content-line-object line
                 "value must be an iCalendar content line"))
  (unless (ical-content-line-valid-p line)
    (return-from decode-ical-content-line-value
      (ical-untyped-property-value
       line (list (ical-property-diagnostic
                   line :untyped-invalid-icalendar-content-line
                   "invalid content line cannot be semantically decoded")))))
  (let* ((name (ical-content-line-normalized-name line))
         (profile (find-ical-property-profile name))
         (language-result
           (multiple-value-list (ical-single-parameter-text line "LANGUAGE")))
         (language (first language-result))
         (format-type-result
           (multiple-value-list (ical-single-parameter-text line "FMTTYPE")))
         (media-type (first format-type-result))
         (diagnostics
           (nconc
            (ical-control-parameter-applicability-diagnostics line profile)
            (ical-registered-metadata-parameter-diagnostics
             line profile :component-name component-name))))
    (when (and (string= name "REQUEST-STATUS")
               (not (ical-request-status-component-name-p component-name)))
      (push (ical-property-diagnostic
             line :invalid-icalendar-request-status-component
             "REQUEST-STATUS requires VEVENT VTODO VJOURNAL or VFREEBUSY context")
            diagnostics))
    (when (and (string= name "CONFERENCE")
               (not (ical-conference-component-name-p component-name)))
      (push (ical-property-diagnostic
             line :invalid-icalendar-conference-component
             "CONFERENCE requires VEVENT or VTODO context")
            diagnostics))
    (unless (second language-result)
      (push (third language-result) diagnostics))
    (when (fourth language-result)
      (push (ical-property-diagnostic
             line :quoted-icalendar-language-tag
             "LANGUAGE must use the unquoted Language-Tag syntax")
            diagnostics))
    (when (and language (not (ical-well-formed-language-tag-p language)))
      (push (ical-property-diagnostic
             line :invalid-icalendar-language-tag
             "LANGUAGE must be a well-formed RFC 5646 Language-Tag")
            diagnostics))
    (when (and language profile
               (not (member name *ical-language-property-names*
                            :test #'string=)))
      (push (ical-property-diagnostic
             line :disallowed-icalendar-property-language
             (format nil "~a does not permit the LANGUAGE parameter" name))
            diagnostics))
    (unless (second format-type-result)
      (push (third format-type-result) diagnostics))
    (when (fourth format-type-result)
      (push (ical-property-diagnostic
             line :quoted-icalendar-format-type
             "FMTTYPE must use the unquoted type/subtype syntax")
            diagnostics))
    (when (and media-type (not (ical-valid-media-type-text-p media-type)))
      (push (ical-property-diagnostic
             line :invalid-icalendar-format-type
             "FMTTYPE must contain one type/subtype media type")
            diagnostics))
    (when (and media-type profile
               (not (member name *ical-format-type-property-names*
                            :test #'string=)))
      (push (ical-property-diagnostic
             line :disallowed-icalendar-property-format-type
             (format nil "~a does not permit the FMTTYPE parameter" name))
            diagnostics))
    (when (and media-type (string= name "IMAGE")
               (not (ical-image-media-type-p media-type)))
      (push (ical-property-diagnostic
             line :invalid-icalendar-image-format-type
             "IMAGE FMTTYPE must use the image top-level media type")
            diagnostics))
    (multiple-value-bind
        (value-name value-cardinality-valid-p value-diagnostic value-quoted-p)
        (ical-single-parameter-text line "VALUE")
      (unless value-cardinality-valid-p
        (push value-diagnostic diagnostics))
      (when (and value-cardinality-valid-p
                 (null value-name)
                 (member name *ical-explicit-value-property-names*
                         :test #'string=))
        (push (ical-property-diagnostic
               line :missing-icalendar-explicit-value-type
               (format nil "~a requires an explicit VALUE parameter" name))
              diagnostics))
      (when value-quoted-p
        (push (ical-property-diagnostic
               line :quoted-icalendar-value-type
               "VALUE must use an unquoted registered or extension token")
              diagnostics))
      (multiple-value-bind
          (timezone-id timezone-valid-p timezone-diagnostic timezone-quoted-p)
          (ical-single-parameter-text line "TZID")
        (unless timezone-valid-p
          (push timezone-diagnostic diagnostics))
        (when timezone-quoted-p
          (push (ical-property-diagnostic
                 line :quoted-icalendar-timezone-id
                 "TZID must use the unquoted paramtext syntax")
                diagnostics))
        (multiple-value-bind
            (encoding encoding-valid-p encoding-diagnostic encoding-quoted-p)
            (ical-single-parameter-text line "ENCODING")
          (unless encoding-valid-p
            (push encoding-diagnostic diagnostics))
          (when encoding-quoted-p
            (push (ical-property-diagnostic
                   line :quoted-icalendar-encoding
                   "ENCODING must use an unquoted registered token")
                  diagnostics))
          (when (and encoding
                     (not (or (string-equal encoding "8BIT")
                              (string-equal encoding "BASE64"))))
            (push (ical-property-diagnostic
                   line :invalid-icalendar-encoding
                   "ENCODING must be either 8BIT or BASE64")
                  diagnostics))
          (when diagnostics
            (return-from decode-ical-content-line-value
              (ical-untyped-property-value
               line (nreverse diagnostics) language media-type)))
          (let* ((explicit-type
                   (and value-name
                        (cdr (assoc (string-upcase value-name)
                                    *ical-value-type-names* :test #'string=))))
                 (type (or explicit-type
                           (and (null value-name) profile
                                (ical-property-profile-default-type profile)))))
            (when (and encoding
                       (string-equal encoding "BASE64")
                       (not (eq type :binary)))
              (push (ical-property-diagnostic
                     line :invalid-icalendar-encoding-value-coupling
                     "ENCODING=BASE64 requires a BINARY value")
                    diagnostics))
            (when diagnostics
              (return-from decode-ical-content-line-value
                (ical-untyped-property-value
                 line (nreverse diagnostics) language media-type)))
            (when (and value-name (null explicit-type))
              (return-from decode-ical-content-line-value
                (ical-untyped-property-value
                 line nil language media-type)))
            (unless type
              (return-from decode-ical-content-line-value
                (ical-untyped-property-value
                 line nil language media-type)))
            (when (and profile
                       (not (member
                             type
                             (ical-property-profile-allowed-types profile))))
              (return-from decode-ical-content-line-value
                (ical-untyped-property-value
                 line (list (ical-property-diagnostic
                             line :disallowed-icalendar-property-value-type
                             (format nil "~a does not permit VALUE=~a"
                                     name value-name)))
                 language media-type)))
            (when (and encoding
                       (string= name "ATTACH")
                       (not (eq type :binary)))
              (push (ical-property-diagnostic
                     line :invalid-icalendar-attachment-encoding
                     "URI-valued ATTACH must not carry inline ENCODING")
                    diagnostics))
            (when (and timezone-id
                       (not (member type '(:date-time :time :period))))
              (push (ical-property-diagnostic
                     line :invalid-icalendar-timezone-value-coupling
                     "TZID is only valid with DATE-TIME, TIME, or PERIOD values")
                    diagnostics))
            (when (and (ical-parameters-named line "RELATED")
                       (not (eq type :duration)))
              (push (ical-property-diagnostic
                     line :invalid-icalendar-related-value-coupling
                     "RELATED is valid only on a DURATION-valued TRIGGER")
                    diagnostics))
            (when (eq type :binary)
              (unless (and encoding (string-equal encoding "BASE64"))
                (push (ical-property-diagnostic
                       line :missing-icalendar-binary-encoding
                       "BINARY values require exactly one ENCODING=BASE64")
                      diagnostics)))
            (when diagnostics
              (return-from decode-ical-content-line-value
                (ical-untyped-property-value
                 line (nreverse diagnostics) language media-type)))
            (let* ((list-p
                     (and profile (ical-property-profile-list-p profile)))
                   (raw-values
                     (if list-p
                         (ical-split-property-list
                          (ical-content-line-value line) (eq type :text))
                         (list (ical-content-line-value line))))
                   (values
                     (mapcar
                      (lambda (raw)
                        (decode-ical-value
                         raw type :timezone-id timezone-id
                         :max-value-characters max-value-characters
                         :max-binary-octets max-binary-octets))
                      raw-values))
                   (value-diagnostics
                     (mapcan (lambda (value)
                               (copy-list (ical-value-diagnostics value)))
                             values))
                   (valid-p (and (every #'ical-value-valid-p values)
                                 (null value-diagnostics))))
              (%make-ical-property-value
               line type values language media-type
               t valid-p value-diagnostics))))))))

(defun ical-property-effective-token-parameter
    (property parameter-name property-name &key component-name)
  (unless (ical-property-value-p property)
    (model-error :invalid-icalendar-effective-parameter-property property
                 "effective parameter lookup requires an iCalendar property"))
  (let ((line (ical-property-value-line property)))
    (unless (string= property-name
                     (ical-content-line-normalized-name line))
      (model-error :wrong-icalendar-effective-parameter-property property
                   (format nil "effective ~a requires a ~a property"
                           parameter-name property-name)))
    (unless (ical-property-value-valid-p property)
      (return-from ical-property-effective-token-parameter
        (values nil nil :invalid-property)))
    (multiple-value-bind (raw cardinality-valid-p)
        (ical-single-parameter-text line parameter-name)
      (unless cardinality-valid-p
        (return-from ical-property-effective-token-parameter
          (values nil raw :invalid-property)))
      (multiple-value-bind (effective resolution)
          (ical-resolve-effective-token-parameter
           parameter-name raw :component-name component-name)
        (values effective raw resolution)))))

(defun ical-property-effective-calendar-user-type (property)
  "Return effective ATTENDEE CUTYPE, raw token, and resolution provenance."
  (ical-property-effective-token-parameter
   property "CUTYPE" "ATTENDEE"))

(defun ical-property-effective-free-busy-type (property)
  "Return effective FREEBUSY FBTYPE, raw token, and resolution provenance."
  (ical-property-effective-token-parameter
   property "FBTYPE" "FREEBUSY"))

(defun ical-property-effective-participation-status
    (property component-name)
  "Return effective ATTENDEE PARTSTAT for COMPONENT-NAME and provenance."
  (ical-property-effective-token-parameter
   property "PARTSTAT" "ATTENDEE" :component-name component-name))

(defun ical-property-effective-relationship-type (property)
  "Return effective RELATED-TO RELTYPE, raw token, and resolution provenance."
  (ical-property-effective-token-parameter
   property "RELTYPE" "RELATED-TO"))

(defun ical-property-effective-role (property)
  "Return effective ATTENDEE ROLE, raw token, and resolution provenance."
  (ical-property-effective-token-parameter property "ROLE" "ATTENDEE"))

(defun ical-property-effective-rsvp-p (property)
  "Return effective ATTENDEE RSVP Boolean, raw token, and provenance."
  (multiple-value-bind (effective raw resolution)
      (ical-property-effective-token-parameter
       property "RSVP" "ATTENDEE")
    (values (and effective (string= effective "TRUE")) raw resolution)))

(defun ical-property-effective-media-type (property)
  "Return an explicit FMTTYPE or the RFC 5545 fallback for inline binary."
  (unless (ical-property-value-p property)
    (model-error :invalid-icalendar-property-media-type property
                 "effective media type requires an iCalendar property value"))
  (and (ical-property-value-valid-p property)
       (or (ical-property-value-media-type property)
           (and (eq :binary (ical-property-value-value-type property))
                (not (string= "IMAGE"
                              (ical-content-line-normalized-name
                               (ical-property-value-line property))))
                "application/octet-stream"))))

(defun ical-property-effective-image-displays (property)
  "Return displayable IMAGE modes, raw normalized modes, and provenance.

The provenance is :DEFAULT, :REGISTERED, :UNSUPPORTED, or :INVALID-PROPERTY.
An unsupported registered or extension token deliberately yields no effective
display mode, as required by RFC 7986."
  (unless (and (ical-property-value-p property)
               (string= "IMAGE"
                        (ical-content-line-normalized-name
                         (ical-property-value-line property))))
    (model-error :invalid-icalendar-image-property property
                 "effective IMAGE display modes require an IMAGE property"))
  (unless (ical-property-value-valid-p property)
    (return-from ical-property-effective-image-displays
      (values nil nil :invalid-property)))
  (let ((parameters
          (ical-parameters-named (ical-property-value-line property) "DISPLAY")))
    (if (null parameters)
        (values '("BADGE") nil :default)
        (let ((raw
                (mapcar (lambda (value)
                          (string-upcase
                           (ical-parameter-value-decoded-text value)))
                        (ical-parameter-values (first parameters)))))
          (if (every (lambda (value)
                       (member value '("BADGE" "GRAPHIC" "FULLSIZE" "THUMBNAIL")
                               :test #'string=))
                     raw)
              (values raw raw :registered)
              (values nil raw :unsupported))))))

(defun ical-property-effective-conference-features (property)
  "Return normalized CONFERENCE FEATURE values and registration provenance."
  (unless (and (ical-property-value-p property)
               (string= "CONFERENCE"
                        (ical-content-line-normalized-name
                         (ical-property-value-line property))))
    (model-error :invalid-icalendar-conference-property property
                 "effective features require a CONFERENCE property"))
  (unless (ical-property-value-valid-p property)
    (return-from ical-property-effective-conference-features
      (values nil :invalid-property)))
  (let ((parameters
          (ical-parameters-named
           (ical-property-value-line property) "FEATURE")))
    (if (null parameters)
        (values nil :absent)
        (let ((features
                (mapcar (lambda (value)
                          (string-upcase
                           (ical-parameter-value-decoded-text value)))
                        (ical-parameter-values (first parameters)))))
          (values
           features
           (if (every
                (lambda (feature)
                  (member feature
                          '("AUDIO" "CHAT" "FEED" "MODERATOR" "PHONE"
                            "SCREEN" "VIDEO")
                          :test #'string=))
                features)
               :registered
               :extended))))))

(defun ical-property-conference-label (property)
  "Return decoded CONFERENCE LABEL text and its property validity."
  (unless (and (ical-property-value-p property)
               (string= "CONFERENCE"
                        (ical-content-line-normalized-name
                         (ical-property-value-line property))))
    (model-error :invalid-icalendar-conference-property property
                 "conference label requires a CONFERENCE property"))
  (if (ical-property-value-valid-p property)
      (multiple-value-bind (text valid-p)
          (ical-single-parameter-text
           (ical-property-value-line property) "LABEL")
        (values text valid-p))
      (values nil nil)))

(defun ical-property-calendar-user-email (property)
  "Return decoded RFC 7986 EMAIL metadata from ATTENDEE or ORGANIZER."
  (unless (and (ical-property-value-p property)
               (member (ical-content-line-normalized-name
                        (ical-property-value-line property))
                       '("ATTENDEE" "ORGANIZER") :test #'string=))
    (model-error :invalid-icalendar-calendar-user-property property
                 "EMAIL metadata requires ATTENDEE or ORGANIZER"))
  (if (ical-property-value-valid-p property)
      (multiple-value-bind (text valid-p)
          (ical-single-parameter-text
           (ical-property-value-line property) "EMAIL")
        (values text valid-p))
      (values nil nil)))

(defun project-ical-property-presentations (component)
  "Expose every valid property value in source order without language collapse."
  (unless (ical-component-p component)
    (model-error :invalid-icalendar-presentation-component component
                 "presentation projection requires an iCalendar component"))
  (let ((values nil)
        (diagnostics nil)
        (ordinal 0))
    (dolist (line (ical-component-properties component))
      (let ((property (decode-ical-content-line-value line)))
        (setf diagnostics
              (nconc diagnostics
                     (copy-list (ical-property-value-diagnostics property))))
        (when (ical-property-value-valid-p property)
          (dolist (value (ical-property-value-values property))
            (when (ical-value-valid-p value)
              (push (%make-ical-property-presentation
                     (incf ordinal) property value
                     (ical-property-value-language property))
                    values))))))
    (%make-ical-property-presentation-set
     component (nreverse values) diagnostics (null diagnostics))))
