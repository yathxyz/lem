(in-package #:lem-structured-notes)

(defparameter *ical-editable-item-property-names*
  '("UID" "DTSTAMP" "CREATED" "LAST-MODIFIED"
    "SUMMARY" "DESCRIPTION" "STATUS" "LOCATION" "URL"
    "TRANSP" "CATEGORIES" "DTSTART" "DTEND" "DUE" "DURATION"
    "COMPLETED" "PERCENT-COMPLETE" "PRIORITY" "SEQUENCE"
    "RECURRENCE-ID" "RRULE" "RDATE" "EXDATE"))

(defstruct (ical-property-change
            (:constructor %make-ical-property-change
                (name operation property metadata-policy)))
  (name "" :type string :read-only t)
  (operation :set :type keyword :read-only t)
  (property nil :type (or null ical-property-output) :read-only t)
  (metadata-policy :preserve :type keyword :read-only t))

(defun make-ical-property-change
    (&key name (operation :set) (value nil value-supplied-p)
          value-type group (parameters nil) (metadata-policy :preserve))
  "Describe a semantic set or delete of one projected item property.

PRESERVE keeps the first existing occurrence's group and all parameters except
VALUE, TZID, and ENCODING.  REPLACE uses GROUP and PARAMETERS explicitly."
  (unless (and (stringp name) (ical-token-p name))
    (model-error :invalid-icalendar-change-property-name name
                 "property change name must be an iCalendar token"))
  (let ((normalized-name (string-upcase name)))
    (unless (member normalized-name *ical-editable-item-property-names*
                    :test #'string=)
      (model-error :unsupported-icalendar-semantic-property-change name
                   "property is outside the projected VEVENT/VTODO edit profile"))
    (unless (member operation '(:set :delete))
      (model-error :invalid-icalendar-property-change-operation operation
                   "property change operation must be SET or DELETE"))
    (unless (member metadata-policy '(:preserve :replace))
      (model-error :invalid-icalendar-change-metadata-policy metadata-policy
                   "change metadata policy must be PRESERVE or REPLACE"))
    (when (and (eq metadata-policy :preserve)
               (or group parameters))
      (model-error :ambiguous-icalendar-change-metadata
                   (list group parameters)
                   "explicit group or parameters require REPLACE metadata policy"))
    (ecase operation
      (:set
       (unless value-supplied-p
         (model-error :missing-icalendar-property-change-value name
                      "SET property change requires a semantic value"))
       (%make-ical-property-change
        normalized-name operation
        (make-ical-property-output
         :name normalized-name :value value :value-type value-type
         :group group :parameters parameters)
        metadata-policy))
      (:delete
       (when (or value-supplied-p value-type group parameters)
         (model-error :unexpected-icalendar-property-delete-value name
                      "DELETE property change cannot carry output data"))
       (%make-ical-property-change
        normalized-name operation nil metadata-policy)))))

(defstruct (ical-semantic-edit-plan
            (:constructor %make-ical-semantic-edit-plan
                (source-id base-source component-path changes source-edits
                 proposed-source)))
  (source-id "" :type string :read-only t)
  (base-source "" :type string :read-only t)
  (component-path nil :type list :read-only t)
  (changes nil :type list :read-only t)
  (source-edits nil :type list :read-only t)
  (proposed-source "" :type string :read-only t))

(defun ical-component-path (document target)
  (labels ((walk (component path)
             (if (eq component target)
                 path
                 (loop :for child :in (ical-component-children component)
                       :for index :from 0
                       :for found := (walk child (append path (list index)))
                       :when found :return found))))
    (loop :for root :in (ical-document-components document)
          :for index :from 0
          :for found := (walk root (list index))
          :when found :return found)))

(defun ical-component-at-path (document path)
  (unless (and (proper-list-p path) path
               (every (lambda (index)
                        (and (integerp index) (not (minusp index))))
                      path))
    (model-error :invalid-icalendar-component-path path
                 "component path must contain non-negative indexes"))
  (let ((component (nth (first path) (ical-document-components document))))
    (dolist (index (rest path))
      (setf component
            (and component
                 (nth index (ical-component-children component)))))
    (unless component
      (model-error :stale-icalendar-component-path path
                   "component path does not exist in the current document"))
    component))

(defun ical-parent-calendar-for-path (document path)
  (let ((calendar (nth (first path) (ical-document-components document))))
    (unless (and calendar
                 (string= "VCALENDAR"
                          (ical-component-normalized-name calendar)))
      (model-error :invalid-icalendar-edit-calendar path
                   "edited item must belong to a VCALENDAR root"))
    calendar))

(defun ical-property-non-control-output-parameters (line)
  (loop :for parameter :in (ical-content-line-parameters line)
        :for name := (ical-parameter-normalized-name parameter)
        :unless (member name *ical-decoding-control-parameter-names*
                        :test #'string=)
          :collect
          (cons name
                (mapcar #'ical-parameter-value-decoded-text
                        (ical-parameter-values parameter)))))

(defun ical-change-output-metadata (change existing-line)
  (if (and existing-line
           (eq :preserve (ical-property-change-metadata-policy change)))
      (values (ical-content-line-group existing-line)
              (ical-property-non-control-output-parameters existing-line))
      (let ((property (ical-property-change-property change)))
        (values (ical-property-output-group property)
                (ical-property-output-parameters property)))))

(defun ical-change-value-type (change existing-line)
  (or (ical-property-output-value-type
       (ical-property-change-property change))
      (and existing-line
           (ical-property-value-value-type
            (decode-ical-content-line-value existing-line)))))

(defun ical-generate-changed-property-line (change existing-line)
  (let ((property (ical-property-change-property change)))
    (multiple-value-bind (group parameters)
        (ical-change-output-metadata change existing-line)
      (generate-ical-property-line
       (ical-property-change-name change)
       (ical-property-output-value property)
       :value-type (ical-change-value-type change existing-line)
       :group group :parameters parameters))))

(defun ical-component-properties-named (component name)
  (remove-if-not
   (lambda (line)
     (string= name (ical-content-line-normalized-name line)))
   (ical-component-properties component)))

(defun ical-plan-combined-property-insertion
    (document component generated-lines)
  (let* ((anchor (ical-component-default-insertion-line component))
         (span (ical-content-line-span anchor))
         (character-position (source-span-character-start span))
         (byte-position (source-span-byte-start span)))
    (%make-ical-source-edit
     :insert (ical-document-source-id document)
     character-position character-position byte-position byte-position ""
     (apply #'concatenate 'string generated-lines))))

(defun verify-ical-semantic-edit-result (source source-id component-path)
  (let* ((document (parse-icalendar-cst source :source-id source-id))
         (calendar (ical-parent-calendar-for-path document component-path))
         (envelope (project-ical-calendar-envelope calendar))
         (component (ical-component-at-path document component-path)))
    (when (ical-document-diagnostics document)
      (model-error :invalid-icalendar-semantic-edit-syntax
                   (ical-document-diagnostics document)
                   "semantic edit produced structural diagnostics"))
    (unless (ical-calendar-envelope-valid-p envelope)
      (model-error :invalid-icalendar-semantic-edit-envelope
                   (ical-calendar-envelope-diagnostics envelope)
                   "semantic edit invalidated the VCALENDAR envelope"))
    (let ((item
            (project-ical-component
             component :method-present-p
             (not (null (ical-calendar-envelope-method envelope))))))
      (unless (ical-calendar-item-valid-p item)
        (model-error :invalid-icalendar-semantic-edit-item
                     (ical-calendar-item-diagnostics item)
                     "semantic edit invalidated the calendar item")))
    document))

(defun plan-ical-semantic-property-changes
    (document component changes &key (max-output-octets 16777216))
  "Plan verified source-preserving changes to projected item properties."
  (assert-editable-ical-document document)
  (unless (and (proper-list-p changes) changes
               (every #'ical-property-change-p changes))
    (model-error :invalid-icalendar-property-changes changes
                 "property changes must be a non-empty finite list"))
  (let ((component-path (ical-component-path document component)))
    (unless component-path
      (model-error :foreign-icalendar-semantic-edit-component component
                   "edited component must be owned by the document"))
    (unless (member (ical-component-normalized-name component)
                    '("VEVENT" "VTODO") :test #'string=)
      (model-error :unsupported-icalendar-semantic-edit-component component
                   "semantic property editing supports VEVENT and VTODO"))
    (let* ((calendar (ical-parent-calendar-for-path document component-path))
           (envelope (project-ical-calendar-envelope calendar))
           (item
             (project-ical-component
              component :method-present-p
              (not (null (ical-calendar-envelope-method envelope)))))
           (seen (make-hash-table :test #'equal))
           (source-edits nil)
           (insertions nil))
      (unless (and (ical-calendar-envelope-valid-p envelope)
                   (ical-calendar-item-valid-p item))
        (model-error :invalid-icalendar-semantic-edit-base component
                     "semantic editing requires a valid projected base item"))
      (dolist (change changes)
        (let* ((name (ical-property-change-name change))
               (existing (ical-component-properties-named component name)))
          (when (gethash name seen)
            (model-error :duplicate-icalendar-property-change name
                         "one semantic edit plan may change a property once"))
          (setf (gethash name seen) t)
          (when (find-if
                 (lambda (line)
                   (ical-extension-derived-p
                    (decode-ical-content-line-value
                     line :component-name
                     (ical-component-normalized-name component))))
                 existing)
            (model-error :derived-icalendar-property-is-read-only name
                         "RFC 9073 DERIVED=TRUE properties must not be updated or deleted"))
          (ecase (ical-property-change-operation change)
            (:delete
             (dolist (line existing)
               (push (plan-ical-content-line-deletion document line)
                     source-edits)))
            (:set
             (let ((generated
                     (ical-generate-changed-property-line
                      change (first existing))))
               (if existing
                   (progn
                     (push (ical-source-edit-for-span
                            :replace document
                            (ical-content-line-span (first existing))
                            (ical-content-line-raw (first existing)) generated)
                           source-edits)
                     (dolist (line (rest existing))
                       (push (plan-ical-content-line-deletion document line)
                             source-edits)))
                   (push generated insertions)))))))
      (when insertions
        (push (ical-plan-combined-property-insertion
               document component (nreverse insertions))
              source-edits))
      (unless source-edits
        (model-error :empty-icalendar-semantic-edit changes
                     "semantic changes produced no source edits"))
      (let* ((source-edits (nreverse source-edits))
             (proposed
               (apply-ical-source-edits
                document source-edits :max-output-octets max-output-octets)))
        (verify-ical-semantic-edit-result
         proposed (ical-document-source-id document) component-path)
        (%make-ical-semantic-edit-plan
         (ical-document-source-id document)
         (copy-seq (ical-document-source document))
         (copy-list component-path) (copy-list changes)
         (copy-list source-edits) proposed)))))

(defun apply-ical-semantic-edit-plan
    (plan current-document &key (max-output-octets 16777216))
  "Apply PLAN only to its exact source revision and return verified source."
  (unless (and (ical-semantic-edit-plan-p plan)
               (ical-document-p current-document))
    (model-error :invalid-icalendar-semantic-edit-application
                 (list plan current-document)
                 "semantic edit application requires a plan and document"))
  (unless (and (string= (ical-semantic-edit-plan-source-id plan)
                        (ical-document-source-id current-document))
               (string= (ical-semantic-edit-plan-base-source plan)
                        (ical-document-source current-document)))
    (model-error :stale-icalendar-semantic-edit plan
                 "current document differs from the planned source revision"))
  (let ((result
          (apply-ical-source-edits
           current-document (ical-semantic-edit-plan-source-edits plan)
           :max-output-octets max-output-octets)))
    (unless (string= result (ical-semantic-edit-plan-proposed-source plan))
      (model-error :inconsistent-icalendar-semantic-edit-result result
                   "applied source differs from the verified proposal"))
    (verify-ical-semantic-edit-result
     result (ical-semantic-edit-plan-source-id plan)
     (ical-semantic-edit-plan-component-path plan))
    result))
