(in-package #:lem-structured-notes)

(defparameter +org-cst-max-source-characters+ (* 1024 1024))
(defparameter +org-cst-max-lines+ 100000)

(defstruct (org-cst-element
            (:constructor %make-org-cst-element
                (kind character-start character-end byte-start byte-end raw
                 name closed-p)))
  (kind :opaque :type keyword :read-only t)
  (character-start 0 :type (integer 0) :read-only t)
  (character-end 0 :type (integer 0) :read-only t)
  (byte-start 0 :type (integer 0) :read-only t)
  (byte-end 0 :type (integer 0) :read-only t)
  (raw "" :type string :read-only t)
  (name nil :type (or null string) :read-only t)
  (closed-p t :type boolean :read-only t))

(defstruct (org-cst-document
            (:constructor %make-org-cst-document
                (source-id newline elements diagnostics)))
  (source-id "" :type string :read-only t)
  (newline :lf :type keyword :read-only t)
  (elements nil :type list :read-only t)
  (diagnostics nil :type list :read-only t))

(defun org-trimmed-line (line)
  (string-trim '(#\Space #\Tab) line))

(defun org-prefix-p (prefix string)
  (and (<= (length prefix) (length string))
       (string-equal prefix string :end2 (length prefix))))

(defun org-heading-text-p (text)
  (let ((stars (position-if-not (lambda (character) (char= character #\*))
                                text)))
    (and stars (plusp stars) (< stars (length text))
         (member (char text stars) '(#\Space #\Tab)))))

(defun org-planning-text-p (text)
  (let ((trimmed (string-left-trim '(#\Space #\Tab) text)))
    (or (org-prefix-p "SCHEDULED:" trimmed)
        (org-prefix-p "DEADLINE:" trimmed)
        (org-prefix-p "CLOSED:" trimmed))))

(defun org-block-marker-text (text)
  (let ((trimmed (string-downcase
                  (string-left-trim '(#\Space #\Tab) text))))
    (labels ((marker (prefix direction)
               (when (org-prefix-p prefix trimmed)
                 (let* ((start (length prefix))
                        (end (or (position-if
                                  (lambda (character)
                                    (member character '(#\Space #\Tab)))
                                  trimmed :start start)
                                 (length trimmed))))
                   (when (< start end)
                     (values direction (subseq trimmed start end)))))))
      (multiple-value-bind (direction name) (marker "#+begin_" :begin)
        (if direction
            (values direction name)
            (marker "#+end_" :end))))))

(defun org-drawer-name (text)
  (let* ((trimmed (org-trimmed-line text))
         (length (length trimmed)))
    (when (and (> length 2)
               (char= (char trimmed 0) #\:)
               (char= (char trimmed (1- length)) #\:)
               (not (find-if (lambda (character)
                               (member character '(#\Space #\Tab #\:)))
                             trimmed :start 1 :end (1- length))))
      (subseq trimmed 1 (1- length)))))

(defun org-table-text-p (text)
  (let ((trimmed (string-left-trim '(#\Space #\Tab) text)))
    (and (plusp (length trimmed)) (char= (char trimmed 0) #\|))))

(defun org-table-formula-text-p (text)
  (org-prefix-p "#+TBLFM:"
                (string-left-trim '(#\Space #\Tab) text)))

(defun org-list-text-p (text)
  (let* ((trimmed (string-left-trim '(#\Space #\Tab) text))
         (length (length trimmed)))
    (or (and (>= length 2)
             (member (char trimmed 0) '(#\- #\+ #\*))
             (member (char trimmed 1) '(#\Space #\Tab)))
        (let ((digits (position-if-not #'digit-char-p trimmed)))
          (and digits (plusp digits) (< (1+ digits) length)
               (member (char trimmed digits) '(#\. #\)))
               (member (char trimmed (1+ digits)) '(#\Space #\Tab)))))))

(defun org-comment-text-p (text)
  (let ((trimmed (string-left-trim '(#\Space #\Tab) text)))
    (and (plusp (length trimmed))
         (char= (char trimmed 0) #\#)
         (or (= (length trimmed) 1)
             (member (char trimmed 1) '(#\Space #\Tab))))))

(defun org-keyword-text-p (text)
  (org-prefix-p "#+" (string-left-trim '(#\Space #\Tab) text)))

(defun org-boundary-text-p (text)
  (or (zerop (length (org-trimmed-line text)))
      (org-heading-text-p text)
      (org-planning-text-p text)
      (org-block-marker-text text)
      (org-drawer-name text)
      (org-table-text-p text)
      (org-list-text-p text)
      (org-comment-text-p text)
      (org-keyword-text-p text)))

(defun org-cst-element-from-lines
    (source byte-prefixes lines start-index end-index kind
     &key name (closed-p t))
  (let* ((start (source-line-character-start (nth start-index lines)))
         (end (source-line-character-end (nth end-index lines))))
    (%make-org-cst-element
     kind start end (aref byte-prefixes start) (aref byte-prefixes end)
     (subseq source start end) name closed-p)))

(defun org-range-diagnostic
    (source-id byte-prefixes severity code message start end &key loss-risk)
  (make-diagnostic
   :severity severity
   :code code
   :message message
   :span (make-source-span :source-id source-id
                           :character-start start :character-end end
                           :byte-start (aref byte-prefixes start)
                           :byte-end (aref byte-prefixes end))
   :loss-risk (or loss-risk :none)))

(defun find-org-block-end (lines start-index block-name)
  (loop :for index :from (1+ start-index) :below (length lines)
        :for text := (source-line-text (nth index lines))
        :do (multiple-value-bind (direction name) (org-block-marker-text text)
              (when (and (eq direction :end) (string= name block-name))
                (return (values index t))))
        :finally (return (values (1- (length lines)) nil))))

(defun find-org-drawer-end (lines start-index)
  (loop :for index :from (1+ start-index) :below (length lines)
        :for name := (org-drawer-name (source-line-text (nth index lines)))
        :when (and name (string-equal name "END"))
          :return (values index t)
        :finally (return (values (1- (length lines)) nil))))

(defun collect-org-line-run (lines start-index predicate)
  (loop :with end := start-index
        :for index :from (1+ start-index) :below (length lines)
        :while (funcall predicate (source-line-text (nth index lines)))
        :do (setf end index)
        :finally (return end)))

(defun collect-org-table-run (lines start-index)
  (loop :with end := start-index
        :for index :from (1+ start-index) :below (length lines)
        :for text := (source-line-text (nth index lines))
        :while (or (org-table-text-p text) (org-table-formula-text-p text))
        :do (setf end index)
        :finally (return end)))

(defun collect-org-list-run (lines start-index)
  (loop :with end := start-index
        :for index :from (1+ start-index) :below (length lines)
        :for text := (source-line-text (nth index lines))
        :while (or (org-list-text-p text)
                   (not (org-boundary-text-p text)))
        :do (setf end index)
        :finally (return end)))

(defun collect-org-paragraph-run (lines start-index)
  (loop :with end := start-index
        :for index :from (1+ start-index) :below (length lines)
        :for text := (source-line-text (nth index lines))
        :while (not (org-boundary-text-p text))
        :do (setf end index)
        :finally (return end)))

(defun parse-org-cst (source &key source-id)
  "Parse SOURCE into an exact, non-executing Org block CST."
  (unless (stringp source)
    (model-error :invalid-org-source source "Org CST source must be a string"))
  (when (> (length source) +org-cst-max-source-characters+)
    (model-error :org-cst-source-limit-exceeded (length source)
                 "Org CST source exceeds the configured character limit"))
  (require-non-empty-string source-id :invalid-source-id "source ID")
  (let ((lines (scan-source-lines source))
        (byte-prefixes (source-byte-prefixes source))
        (elements nil)
        (diagnostics nil)
        (index 0))
    (when (> (length lines) +org-cst-max-lines+)
      (model-error :org-cst-line-limit-exceeded (length lines)
                   "Org CST source exceeds the configured line limit"))
    (labels ((emit (kind start end &key name (closed-p t))
               (push (org-cst-element-from-lines
                      source byte-prefixes lines start end kind
                      :name name :closed-p closed-p)
                     elements)))
      (loop :while (< index (length lines))
            :for text := (source-line-text (nth index lines))
            :do
               (multiple-value-bind (block-direction block-name)
                   (org-block-marker-text text)
                 (cond
                   ((eq block-direction :begin)
                    (multiple-value-bind (end closed-p)
                        (find-org-block-end lines index block-name)
                      (emit (if (string= block-name "src")
                                :source-block
                                :block)
                            index end :name block-name :closed-p closed-p)
                      (unless closed-p
                        (let ((element (first elements)))
                          (push
                           (org-range-diagnostic
                            source-id byte-prefixes :error
                            :unclosed-org-block
                            (format nil "Unclosed Org block ~a" block-name)
                            (org-cst-element-character-start element)
                            (org-cst-element-character-end element)
                            :loss-risk :none)
                           diagnostics)))
                      (setf index (1+ end))))
                   ((org-heading-text-p text)
                    (emit :heading index index)
                    (incf index))
                   ((org-planning-text-p text)
                    (emit :planning index index)
                    (incf index))
                   ((org-drawer-name text)
                    (let ((drawer-name (org-drawer-name text)))
                      (if (string-equal drawer-name "END")
                          (progn (emit :opaque index index :name drawer-name)
                                 (incf index))
                          (multiple-value-bind (end closed-p)
                              (find-org-drawer-end lines index)
                            (emit (if (string-equal drawer-name "PROPERTIES")
                                      :property-drawer
                                      :drawer)
                                  index end :name drawer-name
                                  :closed-p closed-p)
                            (unless closed-p
                              (let ((element (first elements)))
                                (push
                                 (org-range-diagnostic
                                  source-id byte-prefixes :error
                                  :unclosed-org-drawer
                                  (format nil "Unclosed Org drawer ~a"
                                          drawer-name)
                                  (org-cst-element-character-start element)
                                  (org-cst-element-character-end element)
                                  :loss-risk :none)
                                 diagnostics)))
                            (setf index (1+ end))))))
                   ((zerop (length (org-trimmed-line text)))
                    (let ((end (collect-org-line-run
                                lines index
                                (lambda (line)
                                  (zerop (length (org-trimmed-line line)))))))
                      (emit :blank index end)
                      (setf index (1+ end))))
                   ((org-table-text-p text)
                    (let ((end (collect-org-table-run lines index)))
                      (emit :table index end)
                      (setf index (1+ end))))
                   ((org-list-text-p text)
                    (let ((end (collect-org-list-run lines index)))
                      (emit :list index end)
                      (setf index (1+ end))))
                   ((org-comment-text-p text)
                    (let ((end (collect-org-line-run lines index
                                                     #'org-comment-text-p)))
                      (emit :comment index end)
                      (setf index (1+ end))))
                   ((org-keyword-text-p text)
                    (emit :keyword index index)
                    (incf index))
                   (t
                    (let ((end (collect-org-paragraph-run lines index)))
                      (emit :paragraph index end)
                      (setf index (1+ end))))))))
    (%make-org-cst-document source-id (source-newline-style source)
                            (nreverse elements) (nreverse diagnostics))))

(defun serialize-org-cst (document)
  "Serialize DOCUMENT solely from its exact element raws."
  (unless (org-cst-document-p document)
    (model-error :invalid-org-cst document
                 "value must be an Org CST document"))
  (with-output-to-string (stream)
    (dolist (element (org-cst-document-elements document))
      (write-string (org-cst-element-raw element) stream))))

(defun org-cst-content-kind (kind)
  (case kind
    (:source-block :source-block)
    ((:block) :block)
    ((:drawer) :drawer)
    ((:table) :table)
    ((:list) :list)
    ((:comment) :comment)
    ((:keyword) :keyword)
    ((:blank) :blank)
    ((:paragraph) :paragraph)
    (otherwise :opaque)))

(defun org-cst-content-nodes-in-range
    (document character-start character-end
     &key (exclude-kinds '(:heading :planning :property-drawer)))
  "Project exact Org elements wholly inside a half-open character range."
  (unless (and (integerp character-start) (integerp character-end)
               (<= 0 character-start character-end))
    (model-error :invalid-content-range
                 (cons character-start character-end)
                 "content range must be non-negative and half-open"))
  (loop :for element :in (org-cst-document-elements document)
        :when (and (<= character-start
                        (org-cst-element-character-start element))
                   (<= (org-cst-element-character-end element)
                       character-end)
                   (not (member (org-cst-element-kind element)
                                exclude-kinds)))
          :collect
          (let* ((source-kind
                   (org-cst-content-kind (org-cst-element-kind element)))
                 (raw (org-cst-element-raw element))
                 (code-block
                   (and (eq source-kind :source-block)
                        (org-cst-element-closed-p element)
                        (multiple-value-bind (data valid-p)
                            (parse-org-source-block-data
                             raw
                             :source-id
                             (org-cst-document-source-id document)
                             :character-base
                             (org-cst-element-character-start element)
                             :byte-base (org-cst-element-byte-start element))
                          (and valid-p data))))
                 (quote-inlines
                   (and (eq source-kind :block)
                        (org-cst-element-closed-p element)
                        (string= (or (org-cst-element-name element) "")
                                 "quote")
                        (multiple-value-bind (inlines valid-p)
                            (parse-org-quote-inlines
                             raw
                             :source-id
                             (org-cst-document-source-id document)
                             :character-base
                             (org-cst-element-character-start element)
                             :byte-base (org-cst-element-byte-start element))
                          (and valid-p inlines))))
                 (drawer-values
                   (and (eq source-kind :drawer)
                        (org-cst-element-closed-p element)
                        (multiple-value-list
                         (parse-org-drawer-inlines
                          raw
                          :source-id (org-cst-document-source-id document)
                          :character-base
                          (org-cst-element-character-start element)
                          :byte-base (org-cst-element-byte-start element)))))
                 (drawer-inlines
                   (and drawer-values (third drawer-values)
                        (second drawer-values)))
                 (kind (if quote-inlines :quote source-kind)))
            (make-content-node
             :kind kind
             :source-format :org
             :raw raw
             :text (and (eq kind :comment)
                        (native-org-comment-text raw))
             :inlines
             (or quote-inlines drawer-inlines
                 (and (eq kind :paragraph)
                      (multiple-value-bind (inlines valid-p)
                          (parse-org-paragraph-inlines
                           raw
                           :source-id (org-cst-document-source-id document)
                           :character-base
                           (org-cst-element-character-start element)
                           :byte-base (org-cst-element-byte-start element))
                        (and valid-p inlines))))
             :items
             (and (eq kind :list)
                  (multiple-value-bind (items valid-p)
                      (parse-org-list-items
                       raw
                       :source-id (org-cst-document-source-id document)
                       :character-base
                       (org-cst-element-character-start element)
                       :byte-base (org-cst-element-byte-start element))
                    (and valid-p items)))
             :table
             (and (eq kind :table)
                  (multiple-value-bind (table valid-p)
                      (parse-org-table-data
                       raw
                       :source-id (org-cst-document-source-id document)
                       :character-base
                       (org-cst-element-character-start element)
                       :byte-base (org-cst-element-byte-start element))
                    (and valid-p table)))
             :code-block code-block
             :name (and (null code-block) (null quote-inlines)
                        (or (and drawer-inlines (first drawer-values))
                            (org-cst-element-name element)))
             :span
             (make-source-span
              :source-id (org-cst-document-source-id document)
              :character-start (org-cst-element-character-start element)
              :character-end (org-cst-element-character-end element)
              :byte-start (org-cst-element-byte-start element)
              :byte-end (org-cst-element-byte-end element))))))
