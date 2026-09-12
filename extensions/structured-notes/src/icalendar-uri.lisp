(in-package #:lem-structured-notes)

(defstruct (ical-uri-value
            (:constructor %make-ical-uri-value
                (original-lexeme scheme authority userinfo host host-kind port
                 path query fragment)))
  (original-lexeme "" :type string :read-only t)
  (scheme "" :type string :read-only t)
  (authority nil :type (or null string) :read-only t)
  (userinfo nil :type (or null string) :read-only t)
  (host nil :type (or null string) :read-only t)
  (host-kind nil :type (or null keyword) :read-only t)
  (port nil :type (or null string) :read-only t)
  (path "" :type string :read-only t)
  (query nil :type (or null string) :read-only t)
  (fragment nil :type (or null string) :read-only t))

(defun ical-ascii-digit-p (character)
  (let ((code (char-code character)))
    (<= (char-code #\0) code (char-code #\9))))

(defun ical-digit-string-p (text)
  (and (plusp (length text)) (every #'ical-ascii-digit-p text)))

(defun ical-unsigned-integer (text)
  (when (ical-digit-string-p text)
    (loop :with result := 0
          :for character :across text
          :do (setf result
                    (+ (* result 10)
                       (- (char-code character) (char-code #\0))))
          :finally (return result))))

(defun ical-ascii-alpha-p (character)
  (let ((code (char-code character)))
    (or (<= (char-code #\A) code (char-code #\Z))
        (<= (char-code #\a) code (char-code #\z)))))

(defun ical-ascii-hex-digit-p (character)
  (or (ical-ascii-digit-p character)
      (let ((code (char-code character)))
        (or (<= (char-code #\A) code (char-code #\F))
            (<= (char-code #\a) code (char-code #\f))))))

(defun ical-uri-unreserved-p (character)
  (or (ical-ascii-alpha-p character)
      (ical-ascii-digit-p character)
      (find character "-._~" :test #'char=)))

(defun ical-uri-sub-delimiter-p (character)
  (find character "!$&'()*+,;=" :test #'char=))

(defun ical-uri-component-valid-p (text literal-character-p)
  (loop :with length := (length text)
        :for index :from 0 :below length
        :for character := (char text index)
        :always
        (cond
          ((char= character #\%)
           (and (< (+ index 2) length)
                (ical-ascii-hex-digit-p (char text (1+ index)))
                (ical-ascii-hex-digit-p (char text (+ index 2)))
                (progn (incf index 2) t)))
          ((funcall literal-character-p character) t)
          (t nil))))

(defun ical-uri-pchar-p (character)
  (or (ical-uri-unreserved-p character)
      (ical-uri-sub-delimiter-p character)
      (find character ":@" :test #'char=)))

(defun ical-uri-path-character-p (character)
  (or (ical-uri-pchar-p character) (char= character #\/)))

(defun ical-uri-query-character-p (character)
  (or (ical-uri-path-character-p character) (char= character #\?)))

(defun ical-uri-userinfo-character-p (character)
  (or (ical-uri-unreserved-p character)
      (ical-uri-sub-delimiter-p character)
      (char= character #\:)))

(defun ical-uri-reg-name-character-p (character)
  (or (ical-uri-unreserved-p character)
      (ical-uri-sub-delimiter-p character)))

(defun ical-uri-scheme-valid-p (scheme)
  (and (plusp (length scheme))
       (ical-ascii-alpha-p (char scheme 0))
       (loop :for index :from 1 :below (length scheme)
             :for character := (char scheme index)
             :always (or (ical-ascii-alpha-p character)
                         (ical-ascii-digit-p character)
                         (find character "+-." :test #'char=)))))

(defun ical-uri-decimal-octet-valid-p (text)
  (and (<= 1 (length text) 3)
       (every #'ical-ascii-digit-p text)
       (or (= (length text) 1)
           (not (char= (char text 0) #\0)))
       (<= (ical-unsigned-integer text) 255)))

(defun ical-uri-split (text delimiter)
  (loop :with start := 0
        :for position := (position delimiter text :start start)
        :collect (subseq text start position)
        :while position
        :do (setf start (1+ position))))

(defun ical-uri-ipv4-valid-p (text)
  (let ((parts (ical-uri-split text #\.)))
    (and (= (length parts) 4)
         (every #'ical-uri-decimal-octet-valid-p parts))))

(defun ical-uri-hextet-valid-p (text)
  (and (<= 1 (length text) 4)
       (every #'ical-ascii-hex-digit-p text)))

(defun ical-uri-ipv6-side-units (text ipv4-tail-allowed-p)
  (if (zerop (length text))
      (values 0 t)
      (let ((parts (ical-uri-split text #\:)))
        (when (some (lambda (part) (zerop (length part))) parts)
          (return-from ical-uri-ipv6-side-units (values 0 nil)))
        (let* ((last (car (last parts)))
               (ipv4-p (find #\. last :test #'char=)))
          (when (and ipv4-p
                     (or (not ipv4-tail-allowed-p)
                         (not (ical-uri-ipv4-valid-p last))))
            (return-from ical-uri-ipv6-side-units (values 0 nil)))
          (unless (every #'ical-uri-hextet-valid-p
                         (if ipv4-p (butlast parts) parts))
            (return-from ical-uri-ipv6-side-units (values 0 nil)))
          (values (+ (length parts) (if ipv4-p 1 0)) t)))))

(defun ical-uri-ipv6-valid-p (text)
  (let ((compression (search "::" text)))
    (if compression
        (let ((left (subseq text 0 compression))
              (right (subseq text (+ compression 2))))
          (when (search "::" right)
            (return-from ical-uri-ipv6-valid-p nil))
          (multiple-value-bind (left-units left-valid-p)
              (ical-uri-ipv6-side-units left nil)
            (multiple-value-bind (right-units right-valid-p)
                (ical-uri-ipv6-side-units right t)
              (and left-valid-p right-valid-p
                   (< (+ left-units right-units) 8)))))
        (multiple-value-bind (units valid-p)
            (ical-uri-ipv6-side-units text t)
          (and valid-p (= units 8))))))

(defun ical-uri-ipv-future-valid-p (text)
  (and (>= (length text) 4)
       (member (char text 0) '(#\v #\V))
       (let ((dot (position #\. text :start 1)))
         (and dot
              (> dot 1)
              (< dot (1- (length text)))
              (every #'ical-ascii-hex-digit-p (subseq text 1 dot))
              (every (lambda (character)
                       (or (ical-uri-unreserved-p character)
                           (ical-uri-sub-delimiter-p character)
                           (char= character #\:)))
                     (subseq text (1+ dot)))))))

(defun ical-uri-ip-literal-kind (text)
  (cond
    ((ical-uri-ipv6-valid-p text) :ipv6)
    ((ical-uri-ipv-future-valid-p text) :ipv-future)))

(defun ical-uri-parse-host-port (text)
  (if (and (plusp (length text)) (char= (char text 0) #\[))
      (let ((close (position #\] text :start 1)))
        (unless close
          (return-from ical-uri-parse-host-port
            (values nil nil nil nil "IP literal has no closing bracket")))
        (let* ((literal (subseq text 1 close))
               (kind (ical-uri-ip-literal-kind literal))
               (suffix (subseq text (1+ close))))
          (unless kind
            (return-from ical-uri-parse-host-port
              (values nil nil nil nil "invalid IPv6 or IPvFuture literal")))
          (unless (or (zerop (length suffix))
                      (and (char= (char suffix 0) #\:)
                           (every #'ical-ascii-digit-p (subseq suffix 1))))
            (return-from ical-uri-parse-host-port
              (values nil nil nil nil "invalid text after IP literal")))
          (values literal kind
                  (and (plusp (length suffix)) (subseq suffix 1)) t nil)))
      (let ((colon (position #\: text)))
        (when (and colon (position #\: text :start (1+ colon)))
          (return-from ical-uri-parse-host-port
            (values nil nil nil nil "unbracketed host contains multiple colons")))
        (let ((host (subseq text 0 colon))
              (port (and colon (subseq text (1+ colon)))))
          (unless (ical-uri-component-valid-p
                   host #'ical-uri-reg-name-character-p)
            (return-from ical-uri-parse-host-port
              (values nil nil nil nil "host is not a valid reg-name")))
          (unless (or (null port) (every #'ical-ascii-digit-p port))
            (return-from ical-uri-parse-host-port
              (values nil nil nil nil "port contains a non-digit")))
          (values host
                  (if (ical-uri-ipv4-valid-p host) :ipv4 :reg-name)
                  port t nil)))))

(defun ical-uri-parse-authority (authority)
  (let ((at (position #\@ authority)))
    (when (and at (position #\@ authority :start (1+ at)))
      (return-from ical-uri-parse-authority
        (values nil nil nil nil nil "authority contains more than one @")))
    (let ((userinfo (and at (subseq authority 0 at)))
          (host-port (if at (subseq authority (1+ at)) authority)))
      (when (and userinfo
                 (not (ical-uri-component-valid-p
                       userinfo #'ical-uri-userinfo-character-p)))
        (return-from ical-uri-parse-authority
          (values nil nil nil nil nil "userinfo is invalid")))
      (multiple-value-bind (host host-kind port valid-p message)
          (ical-uri-parse-host-port host-port)
        (values userinfo host host-kind port valid-p message)))))

(defun decode-ical-uri (raw)
  "Validate an RFC 3986 absolute URI without resolving or dereferencing it."
  (let ((colon (position #\: raw)))
    (unless colon
      (return-from decode-ical-uri
        (values nil nil "absolute URI has no scheme")))
    (let ((scheme (subseq raw 0 colon)))
      (unless (ical-uri-scheme-valid-p scheme)
        (return-from decode-ical-uri
          (values nil nil "URI scheme is invalid")))
      (let* ((hier-start (1+ colon))
             (fragment-marker (position #\# raw :start hier-start))
             (before-fragment-end (or fragment-marker (length raw)))
             (query-marker (position #\? raw :start hier-start
                                     :end before-fragment-end))
             (hier-end (or query-marker before-fragment-end))
             (hier (subseq raw hier-start hier-end))
             (query (and query-marker
                         (subseq raw (1+ query-marker) before-fragment-end)))
             (fragment (and fragment-marker
                            (subseq raw (1+ fragment-marker))))
             authority userinfo host host-kind port path)
        (unless (and (or (null query)
                         (ical-uri-component-valid-p
                          query #'ical-uri-query-character-p))
                     (or (null fragment)
                         (ical-uri-component-valid-p
                          fragment #'ical-uri-query-character-p)))
          (return-from decode-ical-uri
            (values nil nil "query or fragment is invalid")))
        (if (and (>= (length hier) 2)
                 (string= "//" hier :end2 2))
            (let* ((authority-end (or (position #\/ hier :start 2)
                                      (length hier))))
              (setf authority (subseq hier 2 authority-end)
                    path (subseq hier authority-end))
              (multiple-value-bind
                    (parsed-userinfo parsed-host parsed-host-kind parsed-port
                     valid-p message)
                  (ical-uri-parse-authority authority)
                (unless valid-p
                  (return-from decode-ical-uri (values nil nil message)))
                (setf userinfo parsed-userinfo
                      host parsed-host
                      host-kind parsed-host-kind
                      port parsed-port)))
            (setf path hier))
        (unless (ical-uri-component-valid-p path #'ical-uri-path-character-p)
          (return-from decode-ical-uri
            (values nil nil "path is invalid")))
        (values
         (%make-ical-uri-value
          raw (string-downcase scheme) authority userinfo host host-kind port
          path query fragment)
         t nil)))))
