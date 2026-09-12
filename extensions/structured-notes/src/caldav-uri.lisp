;;; Pure URI evidence; no dereferencing, XML parsing, account discovery, or transport.
(in-package #:lem-structured-notes)

(defun dav-percent-dot-segment-p (segment)
  (let ((index 0)
        (dots 0))
    (loop :while (< index (length segment))
          :do
             (cond
               ((char= (char segment index) #\.)
                (incf dots)
                (incf index))
               ((and (<= (+ index 3) (length segment))
                     (char= (char segment index) #\%)
                     (char= (char segment (1+ index)) #\2)
                     (member (char segment (+ index 2)) '(#\e #\E)))
                (incf dots)
                (incf index 3))
               (t (return-from dav-percent-dot-segment-p nil))))
    (member dots '(1 2))))

(defun dav-path-has-dot-segment-p (path)
  (some #'dav-percent-dot-segment-p (ical-uri-split path #\/)))

(defun validate-dav-operational-request-uri (href)
  (validate-caldav-resource-href href)
  (multiple-value-bind (uri valid-p message)
      (decode-ical-uri href)
    (declare (ignore message))
    (unless valid-p
      (model-error :invalid-caldav-resource-href href
                   "CalDAV request target cannot be decoded"))
    (when (dav-path-has-dot-segment-p (ical-uri-value-path uri))
      (model-error :dav-request-uri-dot-segment-forbidden href
                   "CalDAV request target must not contain dot segments")))
  href)

(defstruct (dav-resolved-href
            (:constructor %make-dav-resolved-href
                (original absolute-uri reference-kind same-origin-p
                 fetchable-p diagnostics)))
  (original "" :type string :read-only t)
  (absolute-uri "" :type string :read-only t)
  (reference-kind :absolute-path :type keyword :read-only t)
  (same-origin-p nil :type boolean :read-only t)
  (fetchable-p nil :type boolean :read-only t)
  (diagnostics nil :type list :read-only t))

(defun dav-href-diagnostic (code message &key (loss-risk :security))
  (make-diagnostic :severity :fatal :code code :message message
                   :loss-risk loss-risk))

(defun parse-dav-absolute-path-reference (href)
  (unless (and (plusp (length href)) (char= #\/ (char href 0)))
    (model-error :invalid-dav-href href
                 "DAV href must be an absolute URI or absolute path"))
  (when (and (> (length href) 1) (char= #\/ (char href 1)))
    (model-error :dav-href-network-path-forbidden href
                 "DAV href absolute paths must not begin with //"))
  (when (position #\# href)
    (model-error :dav-href-fragment-forbidden href
                 "DAV href must not contain a fragment"))
  (let* ((question (position #\? href))
         (path (subseq href 0 question))
         (query (and question (subseq href (1+ question)))))
    (unless (and (ical-uri-component-valid-p path
                                             #'ical-uri-path-character-p)
                 (or (null query)
                     (ical-uri-component-valid-p
                      query #'ical-uri-query-character-p)))
      (model-error :invalid-dav-href href
                   "DAV absolute-path href contains invalid URI characters"))
    (when (dav-path-has-dot-segment-p path)
      (model-error :dav-href-dot-segment-forbidden href
                   "DAV href must not contain literal or encoded dot segments"))
    (values path query)))

(defun dav-effective-port (uri)
  (let ((port (ical-uri-value-port uri)))
    (if (or (null port) (zerop (length port)))
        (cond
          ((string-equal "https" (ical-uri-value-scheme uri)) 443)
          ((string-equal "http" (ical-uri-value-scheme uri)) 80)
          (t nil))
        (parse-integer port))))

(defun dav-uri-same-origin-p (first second)
  (and (ical-uri-value-authority first)
       (ical-uri-value-authority second)
       (string-equal (ical-uri-value-scheme first)
                     (ical-uri-value-scheme second))
       (string-equal (ical-uri-value-host first)
                     (ical-uri-value-host second))
       (eql (dav-effective-port first) (dav-effective-port second))))

(defun dav-uri-fetchable-p (uri request-uri)
  (and (string-equal "https" (ical-uri-value-scheme uri))
       (ical-uri-value-authority uri)
       (non-empty-string-p (ical-uri-value-host uri))
       (null (ical-uri-value-userinfo uri))
       (null (ical-uri-value-fragment uri))
       (not (dav-path-has-dot-segment-p (ical-uri-value-path uri)))
       (dav-uri-same-origin-p uri request-uri)))

(defun resolve-dav-href (href request-uri)
  "Resolve one RFC 4918 DAV href without dereferencing it.

The original spelling is retained.  Cross-origin and otherwise unsafe
absolute targets remain inspectable but are never marked FETCHABLE-P."
  (validate-dav-operational-request-uri request-uri)
  (unless (and (stringp href) (plusp (length href)))
    (model-error :invalid-dav-href href
                 "DAV href must be a non-empty string"))
  (multiple-value-bind (request decoded-request-p request-message)
      (decode-ical-uri request-uri)
    (declare (ignore request-message))
    (unless decoded-request-p
      (model-error :invalid-caldav-resource-href request-uri
                   "request URI cannot be decoded"))
    (if (char= #\/ (char href 0))
        (multiple-value-bind (path query)
            (parse-dav-absolute-path-reference href)
          (let ((absolute
                  (concatenate
                   'string (ical-uri-value-scheme request) "://"
                   (ical-uri-value-authority request) path
                   (if query (concatenate 'string "?" query) ""))))
            (%make-dav-resolved-href
             (copy-seq href) absolute :absolute-path t t nil)))
        (multiple-value-bind (decoded valid-p message)
            (decode-ical-uri href)
          (unless valid-p
            (model-error :invalid-dav-href href "invalid absolute DAV URI: ~a"
                         message))
          (when (ical-uri-value-fragment decoded)
            (model-error :dav-href-fragment-forbidden href
                         "DAV href must not contain a fragment"))
          (when (dav-path-has-dot-segment-p (ical-uri-value-path decoded))
            (model-error :dav-href-dot-segment-forbidden href
                         "DAV href must not contain literal or encoded dot segments"))
          (let* ((same-origin-p (dav-uri-same-origin-p decoded request))
                 (fetchable-p (dav-uri-fetchable-p decoded request))
                 (diagnostics nil))
            (unless same-origin-p
              (push (dav-href-diagnostic
                     :dav-href-cross-origin
                     "DAV href does not share the request URI origin")
                    diagnostics))
            (unless (and (string-equal "https"
                                       (ical-uri-value-scheme decoded))
                         (ical-uri-value-authority decoded)
                         (non-empty-string-p (ical-uri-value-host decoded))
                         (null (ical-uri-value-userinfo decoded)))
              (push (dav-href-diagnostic
                     :unsafe-dav-href-target
                     "DAV href is not a safe HTTPS authority target")
                    diagnostics))
            (%make-dav-resolved-href
             (copy-seq href) (copy-seq href) :absolute-uri same-origin-p
             fetchable-p (nreverse diagnostics)))))))

(defun dav-uri-resource-key (uri)
  (list (string-downcase (ical-uri-value-scheme uri))
        (and (ical-uri-value-host uri)
             (string-downcase (ical-uri-value-host uri)))
        (dav-effective-port uri)
        (if (zerop (length (ical-uri-value-path uri)))
            "/"
            (ical-uri-value-path uri))
        (ical-uri-value-query uri)))

(defun dav-resolved-href-resource-key (resolved)
  (multiple-value-bind (uri valid-p message)
      (decode-ical-uri (dav-resolved-href-absolute-uri resolved))
    (unless valid-p
      (model-error :invalid-resolved-dav-href resolved
                   "resolved DAV href is invalid: ~a" message))
    (dav-uri-resource-key uri)))

(defun caldav-discovery-error (code value control &rest arguments)
  (model-error code value (apply #'format nil control arguments)))

(defun caldav-discovery-ascii-dns-label-p (label)
  (and
   (<= 1 (length label) 63)
   (not (char= #\- (char label 0)))
   (not (char= #\- (char label (1- (length label)))))
   (every
    (lambda (character)
      (or (and (char<= #\a character) (char<= character #\z))
          (and (char<= #\A character) (char<= character #\Z))
          (and (char<= #\0 character) (char<= character #\9))
          (char= character #\-)))
    label)))

(defun caldav-discovery-normalize-domain (domain)
  (unless (and (stringp domain) (plusp (length domain)))
    (caldav-discovery-error
     :invalid-caldav-discovery-domain domain
     "discovery domain must be a non-empty ASCII DNS name"))
  (let* ((without-root
           (if (char= #\. (char domain (1- (length domain))))
               (subseq domain 0 (1- (length domain)))
               domain))
         (labels (ical-uri-split without-root #\.)))
    (unless (and (<= 1 (length without-root) 253)
                 (every #'caldav-discovery-ascii-dns-label-p labels))
      (caldav-discovery-error
       :invalid-caldav-discovery-domain domain
       "discovery domain must contain bounded LDH DNS labels"))
    (string-downcase without-root)))

(defparameter +caldav-discovery-max-location-characters+ 8192)

(defstruct (caldav-https-origin
            (:constructor %make-caldav-https-origin (host port)))
  (host "" :type string :read-only t)
  (port 443 :type (integer 1 65535) :read-only t))

(defun caldav-discovery-decode-https-target (href)
  (validate-dav-operational-request-uri href)
  (multiple-value-bind (uri valid-p message)
      (decode-ical-uri href)
    (unless valid-p
      (model-error :invalid-caldav-discovery-redirect-target href
                   "redirect target cannot be decoded: ~a" message))
    (unless (eq :reg-name (ical-uri-value-host-kind uri))
      (model-error :unsupported-caldav-redirect-host-identity href
                   "redirect targets require a DNS host until IP-ID is modeled"))
    (let ((port (dav-effective-port uri)))
      (unless (and (integerp port) (<= 1 port 65535))
        (model-error :invalid-caldav-discovery-redirect-port href
                     "redirect target port must be between 1 and 65535"))
      (values
       uri
       (%make-caldav-https-origin
        (caldav-discovery-normalize-domain (ical-uri-value-host uri))
        port)))))

(defun caldav-discovery-uri-prefix (uri)
  (format nil "~a://~a" (ical-uri-value-scheme uri)
          (ical-uri-value-authority uri)))

(defun caldav-discovery-reference-absolute-p (reference)
  (let ((colon (position #\: reference))
        (slash (position #\/ reference))
        (question (position #\? reference)))
    (and colon
         (or (null slash) (< colon slash))
         (or (null question) (< colon question)))))

(defun caldav-discovery-normalize-redirect-path (path)
  "Remove literal RFC 3986 dot segments and reject encoded aliases."
  (unless (and (stringp path)
               (or (zerop (length path))
                   (char= #\/ (char path 0)))
               (ical-uri-component-valid-p path
                                            #'ical-uri-path-character-p))
    (model-error :invalid-caldav-discovery-location-path path
                 "resolved redirect path must be an absolute URI path"))
  (when (zerop (length path))
    (return-from caldav-discovery-normalize-redirect-path ""))
  (let* ((parts (ical-uri-split (subseq path 1) #\/))
         (last-part (car (last parts)))
         (directory-result-p
           (or (string= last-part ".") (string= last-part "..")))
         (stack nil))
    (dolist (part parts)
      (cond
        ((string= part "."))
        ((string= part "..")
         (when stack (pop stack)))
        ((dav-percent-dot-segment-p part)
         (model-error :encoded-caldav-redirect-dot-segment path
                      "encoded redirect dot segments are refused"))
        (t (push part stack))))
    (let ((normalized
            (format nil "/~{~a~^/~}" (nreverse stack))))
      (if (and directory-result-p
               (not (char= #\/ (char normalized
                                      (1- (length normalized))))))
          (concatenate 'string normalized "/")
          normalized))))

(defun caldav-discovery-merge-relative-path (base-path reference-path)
  (let ((base (if (zerop (length base-path)) "/" base-path)))
    (concatenate
     'string
     (subseq base 0 (or (position #\/ base :from-end t) 0))
     "/" reference-path)))

(defun caldav-discovery-build-target (uri path query)
  (let ((target
          (concatenate
           'string (caldav-discovery-uri-prefix uri) path
           (if query (concatenate 'string "?" query) ""))))
    (when (> (length target) +caldav-discovery-max-location-characters+)
      (model-error :caldav-discovery-location-limit-exceeded (length target)
                   "resolved redirect target exceeds the character limit"))
    target))

(defun resolve-caldav-discovery-location (location source-href)
  "Resolve a bounded RFC 9110 Location URI-reference against SOURCE-HREF.

Fragments, userinfo, non-HTTPS targets, IP literals, and percent-encoded dot
segments fail closed.  Literal dot segments are normalized per RFC 3986."
  (unless (and (stringp location) (plusp (length location))
               (<= (length location)
                   +caldav-discovery-max-location-characters+))
    (model-error :invalid-caldav-discovery-location location
                 "Location must be one bounded non-empty URI-reference"))
  (when (position #\# location)
    (model-error :caldav-discovery-location-fragment-forbidden location
                 "redirect Location fragments are refused"))
  (multiple-value-bind (source source-origin)
      (caldav-discovery-decode-https-target source-href)
    (declare (ignore source-origin))
    (let* ((question (position #\? location))
           (reference-path (subseq location 0 question))
           (reference-query
             (and question (subseq location (1+ question))))
           target)
      (cond
        ((caldav-discovery-reference-absolute-p location)
         (multiple-value-bind (absolute valid-p message)
             (decode-ical-uri location)
           (unless valid-p
             (model-error :invalid-caldav-discovery-location location
                          "absolute Location is invalid: ~a" message))
           (when (ical-uri-value-fragment absolute)
             (model-error :caldav-discovery-location-fragment-forbidden
                          location "redirect fragments are refused"))
           (setf target
                 (caldav-discovery-build-target
                  absolute
                  (caldav-discovery-normalize-redirect-path
                   (ical-uri-value-path absolute))
                  (ical-uri-value-query absolute)))))
        ((and (>= (length location) 2)
              (string= "//" location :end2 2))
         (setf target
               (resolve-caldav-discovery-location
                (concatenate 'string
                             (ical-uri-value-scheme source) ":" location)
                source-href)))
        ((and (plusp (length reference-path))
              (char= #\/ (char reference-path 0)))
         (unless (or (null reference-query)
                     (ical-uri-component-valid-p
                      reference-query #'ical-uri-query-character-p))
           (model-error :invalid-caldav-discovery-location-query location
                        "Location query contains invalid URI characters"))
         (setf target
               (caldav-discovery-build-target
                source
                (caldav-discovery-normalize-redirect-path reference-path)
                reference-query)))
        (t
         (unless (and (ical-uri-component-valid-p
                       reference-path #'ical-uri-path-character-p)
                      (or (null reference-query)
                          (ical-uri-component-valid-p
                           reference-query #'ical-uri-query-character-p)))
           (model-error :invalid-caldav-discovery-location location
                        "relative Location contains invalid URI characters"))
         (let ((path
                 (if (zerop (length reference-path))
                     (ical-uri-value-path source)
                     (caldav-discovery-merge-relative-path
                      (ical-uri-value-path source) reference-path)))
               (query
                 (if question
                     reference-query
                     (and (zerop (length reference-path))
                          (ical-uri-value-query source)))))
           (setf target
                 (caldav-discovery-build-target
                  source (caldav-discovery-normalize-redirect-path path)
                  query)))))
      (caldav-discovery-decode-https-target target)
      target)))
