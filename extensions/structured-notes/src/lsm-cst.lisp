(in-package #:lem-structured-notes)

(defstruct (source-line
            (:constructor make-source-line
                (character-start content-end character-end text)))
  (character-start 0 :type (integer 0) :read-only t)
  (content-end 0 :type (integer 0) :read-only t)
  (character-end 0 :type (integer 0) :read-only t)
  (text "" :type string :read-only t))

(defun scan-source-lines (source)
  "Split SOURCE while retaining half-open content and line-ending bounds."
  (let ((length (length source))
        (start 0)
        (lines nil))
    (loop :while (< start length)
          :do (let ((newline
                      (position-if (lambda (character)
                                     (or (char= character #\Newline)
                                         (char= character #\Return)))
                                   source :start start)))
                (if newline
                    (let ((end
                            (if (and (char= (char source newline) #\Return)
                                     (< (1+ newline) length)
                                     (char= (char source (1+ newline))
                                            #\Newline))
                                (+ newline 2)
                                (1+ newline))))
                      (push (make-source-line
                             start newline end (subseq source start newline))
                            lines)
                      (setf start end))
                    (progn
                      (push (make-source-line
                             start length length (subseq source start length))
                            lines)
                      (setf start length)))))
    (nreverse lines)))

(defun source-newline-style (source)
  (let ((position
          (position-if (lambda (character)
                         (or (char= character #\Newline)
                             (char= character #\Return)))
                       source)))
    (cond
      ((null position) :lf)
      ((and (char= (char source position) #\Return)
            (< (1+ position) (length source))
            (char= (char source (1+ position)) #\Newline))
       :crlf)
      ((char= (char source position) #\Return) :cr)
      (t :lf))))

(defun utf8-character-octets (character)
  (let ((code (char-code character)))
    (cond
      ((<= code #x7f) 1)
      ((<= code #x7ff) 2)
      ((<= code #xffff) 3)
      (t 4))))

(defun source-byte-prefixes (source)
  (let ((prefixes (make-array (1+ (length source)) :element-type 'integer))
        (count 0))
    (setf (aref prefixes 0) 0)
    (loop :for character :across source
          :for index :from 1
          :do (incf count (utf8-character-octets character))
              (setf (aref prefixes index) count))
    prefixes))

(defstruct (cst-node
            (:constructor %make-cst-node
                (kind character-start character-end byte-start byte-end raw
                 name fields)))
  (kind :raw :type keyword :read-only t)
  (character-start 0 :type (integer 0) :read-only t)
  (character-end 0 :type (integer 0) :read-only t)
  (byte-start 0 :type (integer 0) :read-only t)
  (byte-end 0 :type (integer 0) :read-only t)
  (raw "" :type string :read-only t)
  (name nil :type (or null string) :read-only t)
  (fields nil :type list :read-only t))

(defun make-cst-node-from-source
    (source byte-prefixes kind start end &key name (fields nil))
  (unless (and (integerp start) (integerp end)
               (<= 0 start end (length source)))
    (model-error :invalid-cst-span (cons start end)
                 "CST character span is outside the source"))
  (%make-cst-node kind start end
                  (aref byte-prefixes start)
                  (aref byte-prefixes end)
                  (subseq source start end)
                  name
                  (copy-proper-list fields :invalid-cst-fields
                                    "CST fields")))

(defstruct (lsm-syntax-document
            (:constructor %make-lsm-syntax-document
                (source newline nodes profile document-id diagnostics)))
  (source "" :type string :read-only t)
  (newline :lf :type keyword :read-only t)
  (nodes nil :type list :read-only t)
  (profile "" :type string :read-only t)
  (document-id "" :type string :read-only t)
  (diagnostics nil :type list :read-only t))

(defun make-lsm-syntax-document
    (&key source newline nodes profile document-id diagnostics)
  (unless (stringp source)
    (model-error :invalid-lsm-source source "LSM source must be a string"))
  (require-membership newline '(:lf :crlf :cr)
                      :invalid-newline "LSM newline style")
  (require-non-empty-string profile :invalid-profile "LSM profile")
  (require-non-empty-string document-id :invalid-document-id "LSM document ID")
  (let ((nodes (copy-proper-list nodes :invalid-cst-nodes "CST nodes"))
        (diagnostics
          (copy-proper-list diagnostics :invalid-diagnostics
                            "LSM diagnostics"))
        (cursor 0))
    (unless (every #'cst-node-p nodes)
      (model-error :invalid-cst-node nodes
                   "every LSM syntax node must be a CST node"))
    (dolist (node nodes)
      (unless (= cursor (cst-node-character-start node))
        (model-error :cst-coverage-gap node
                     "CST nodes must cover the source contiguously"))
      (unless (string= (cst-node-raw node)
                       (subseq source cursor (cst-node-character-end node)))
        (model-error :cst-raw-mismatch node
                     "CST raw text differs from its source span"))
      (setf cursor (cst-node-character-end node)))
    (unless (= cursor (length source))
      (model-error :cst-incomplete-coverage cursor
                   "CST nodes must cover the entire source"))
    (unless (every #'diagnostic-p diagnostics)
      (model-error :invalid-diagnostic diagnostics
                   "every LSM diagnostic must be a diagnostic"))
    (%make-lsm-syntax-document source newline nodes profile document-id
                               diagnostics)))

(defun serialize-lsm-syntax (syntax-document)
  "Serialize the untouched CST. This must be byte-identical to its input."
  (unless (lsm-syntax-document-p syntax-document)
    (model-error :invalid-lsm-syntax syntax-document
                 "value is not an LSM syntax document"))
  (with-output-to-string (stream)
    (dolist (node (lsm-syntax-document-nodes syntax-document))
      (write-string (cst-node-raw node) stream))))
