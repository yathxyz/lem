;;;; Cell-stable terminal projection of the active org-modern defaults.
;;;; Display strings change, but buffer text, cursor geometry, and saves do not.

(in-package :lem-yath)

(define-attribute org-modern-label-attribute
  (t :reverse t :bold t))
(define-attribute org-modern-symbol-attribute
  (t :bold t))

(defparameter *org-modern-folded-stars* #("▶" "▷" "⯈" "▹" "▹"))
(defparameter *org-modern-expanded-stars* #("▿" "▽" "⯆" "▿" "▿"))

(defun org-modern-redraw ()
  (redraw-display :force t))

(define-minor-mode org-modern-mode
    (:name "OrgModern"
     :hide-from-modeline t
     :enable-hook 'org-modern-redraw
     :disable-hook 'org-modern-redraw))

(defun org-modern-enable ()
  (org-modern-mode t))

(remove-hook *org-mode-hook* 'org-modern-enable)
(add-hook *org-mode-hook* 'org-modern-enable)

(defun org-modern-block-context-cache (buffer)
  "Return BUFFER's modified-tick-indexed Org block-line context table."
  (let* ((tick (buffer-modified-tick buffer))
         (cache (buffer-value buffer 'lem-yath-org-modern-block-cache)))
    (if (and (consp cache) (= tick (car cache)))
        (cdr cache)
        (let ((contexts (make-hash-table :test 'eql))
              (open-type nil))
          (with-point ((point (buffer-start-point buffer)))
            (loop
              (let ((marker (org-block-marker (line-string point)))
                    (position (position-at-point point)))
                (cond
                  ((and open-type marker
                        (eq (car marker) :end)
                        (string= open-type (cdr marker)))
                   (setf (gethash position contexts)
                         (cons :end (cdr marker))
                         open-type nil))
                  (open-type
                   (setf (gethash position contexts) '(:inside)))
                  ((and marker (eq (car marker) :begin))
                   (setf (gethash position contexts)
                         (cons :begin (cdr marker))
                         open-type (cdr marker)))
                  ((and marker (eq (car marker) :end))
                   (setf (gethash position contexts)
                         (cons :end (cdr marker))))))
              (unless (line-offset point 1)
                (return))))
          (setf (buffer-value buffer 'lem-yath-org-modern-block-cache)
                (cons tick contexts))
          contexts))))

(defun org-modern-line-block-context (buffer point)
  (with-point ((line point))
    (line-start line)
    (gethash (position-at-point line)
             (org-modern-block-context-cache buffer))))

(defun org-modern-first-nonspace-index (string)
  (position-if (lambda (character) (not (char= character #\Space))) string))

(defun org-modern-last-nonspace-index (string)
  (position-if (lambda (character) (not (char= character #\Space)))
               string :from-end t))

(defun org-modern-replace-range (string start end character)
  (loop :for index :from start :below end
        :when (< index (length string))
          :do (setf (aref string index) character)))

(defun org-modern-overlay-label (attributes start end)
  (lem-core::overlay-attributes attributes start end
                                'org-modern-label-attribute))

(defun org-modern-overlay-symbol (attributes index)
  (lem-core::overlay-attributes attributes index (1+ index)
                                'org-modern-symbol-attribute))

(defun org-modern-whitespace-character-p (character)
  (member character '(#\Space #\Tab #\Newline #\Return)))

(defun org-modern-tag-character-p (character)
  (or (alphanumericp character)
      (member character '(#\_ #\@ #\# #\%))))

(defun org-modern-trailing-tag-range (source)
  "Return the start and end of a valid trailing :TAG: group in SOURCE."
  (let ((last (org-modern-last-nonspace-index source)))
    (when (and last (char= (char source last) #\:))
      (let* ((end (1+ last))
             (separator
               (position-if #'org-modern-whitespace-character-p source
                            :from-end t :end end))
             (start (and separator (1+ separator))))
        (when (and start (< (1+ start) end)
                   (char= (char source start) #\:)
                   (loop :with tag-length = 0
                         :for index :from (1+ start) :below end
                         :for character = (char source index)
                         :always
                         (cond
                           ((char= character #\:)
                            (prog1 (plusp tag-length)
                              (setf tag-length 0)))
                           ((org-modern-tag-character-p character)
                            (incf tag-length)
                            t)
                           (t nil))))
          (values start end))))))

(defun org-modern-transform-trailing-tags (source string attributes)
  (multiple-value-bind (start end) (org-modern-trailing-tag-range source)
    (when start
      (loop :for index :from start :below end
            :when (char= (char source index) #\:)
              :do (setf (aref string index) #\Space))
      (setf attributes (org-modern-overlay-label attributes start end))))
  attributes)

(defun org-modern-heading-folded-p (point)
  (with-point ((next point))
    (line-start next)
    (and (line-offset next 1)
         (org-line-hidden-p next))))

(defun org-modern-transform-heading (point source string attributes)
  (let ((level (org-heading-level-from-line source)))
    (when level
      (org-modern-replace-range string 0 (1- level) #\Space)
      (let* ((stars (if (org-modern-heading-folded-p point)
                        *org-modern-folded-stars*
                        *org-modern-expanded-stars*))
             (glyph (aref stars (min (1- level) (1- (length stars)))))
             (index (1- level)))
        (setf (aref string index) (char glyph 0)
              attributes (org-modern-overlay-symbol attributes index)))
      (multiple-value-bind (start end register-starts register-ends)
          (cl-ppcre:scan
           (format nil "^\\*+\\s+(~a)(?:\\s|$)" *org-todo-keyword-pattern*)
           source)
        (declare (ignore start end))
        (when (and register-starts (aref register-starts 0))
          (setf attributes
                (org-modern-overlay-label
                 attributes (aref register-starts 0)
                 (aref register-ends 0)))))
      (cl-ppcre:do-matches (start end "\\[#[A-Z0-9]\\]" source)
        (setf (aref string start) #\Space
              (aref string (1+ start)) #\Space
              (aref string (1- end)) #\Space
              attributes (org-modern-overlay-label attributes start end)))
      (setf attributes
            (org-modern-transform-trailing-tags source string attributes)))
    (values string attributes)))

(defun org-modern-list-bullet (character)
  (case character
    (#\+ #\◦)
    (#\- #\–)
    (#\* #\∙)))

(defun org-modern-transform-list (source string attributes)
  (let* ((index (org-modern-first-nonspace-index source))
         (bullet (and index (< (1+ index) (length source))
                      (char source index))))
    (when (and bullet
               (org-modern-list-bullet bullet)
               (char= (char source (1+ index)) #\Space)
               (or (not (char= bullet #\*)) (plusp index)))
      (setf (aref string index) (org-modern-list-bullet bullet)
            attributes (org-modern-overlay-symbol attributes index))
      (let ((checkbox (search "[" source :start2 (+ index 2))))
        (when (and checkbox (< (+ checkbox 2) (length source))
                   (char= (char source (+ checkbox 2)) #\])
                   (member (char source (1+ checkbox))
                           '(#\Space #\X #\x #\-)))
          (let ((glyph (case (char source (1+ checkbox))
                         ((#\X #\x) #\☑)
                         (#\- #\⊟)
                         (otherwise #\□))))
            (setf (aref string checkbox) #\Space
                  (aref string (1+ checkbox)) glyph
                  (aref string (+ checkbox 2)) #\Space
                  attributes
                  (org-modern-overlay-symbol attributes (1+ checkbox)))))))
    (values string attributes)))

(defun org-modern-table-line-p (string)
  (let ((start (org-modern-first-nonspace-index string))
        (end (org-modern-last-nonspace-index string)))
    (and start end
         (char= (char string start) #\|)
         (char= (char string end) #\|))))

(defun org-modern-table-rule-p (string)
  (every (lambda (character)
           (member character '(#\Space #\| #\+ #\-)))
         string))

(defun org-modern-transform-table (source string attributes)
  (when (org-modern-table-line-p source)
    (let ((rule-p (org-modern-table-rule-p source)))
      (loop :for character :across source
            :for index :from 0
            :do (cond
                  ((char= character #\|)
                   (setf (aref string index) #\│))
                  ((and rule-p (char= character #\-))
                   (setf (aref string index) #\─))
                  ((and rule-p (char= character #\+))
                   (setf (aref string index) #\┼))))
      (setf attributes
            (lem-core::overlay-attributes
             attributes 0 (length string) 'document-table-attribute))))
  (values string attributes))

(defun org-modern-transform-keyword (source string context attributes)
  (let ((start (org-modern-first-nonspace-index source)))
    (when (and start (< (1+ start) (length source))
               (char= (char source start) #\#)
               (char= (char source (1+ start)) #\+))
      (if (member (car context) '(:begin :end))
          (let ((underscore (position #\_ source :start start)))
            (when underscore
              (org-modern-replace-range string start (1+ underscore) #\Space)
              (setf (aref string start) #\▏
                    attributes
                    (org-modern-overlay-symbol attributes start))))
          (setf (aref string start) #\Space
                (aref string (1+ start)) #\Space))
      (when (cl-ppcre:scan "(?i)^\\s*#\\+filetags:" source)
        (setf attributes
              (org-modern-transform-trailing-tags source string attributes))))
    (values string attributes)))

(defun org-modern-transform-horizontal-rule (source string attributes)
  (let ((start (org-modern-first-nonspace-index source))
        (end (org-modern-last-nonspace-index source)))
    (when (and start end (<= 4 (- end start))
               (loop :for index :from start :to end
                     :always (char= (char source index) #\-)))
      (org-modern-replace-range string start (1+ end) #\─)
      (setf attributes
            (lem-core::overlay-attributes attributes start (1+ end)
                                          'document-metadata-attribute))))
  (values string attributes))

(defun org-modern-target-content-p (source start end)
  (and (< start end)
       (not (org-modern-whitespace-character-p (char source start)))
       (not (org-modern-whitespace-character-p (char source (1- end))))
       (loop :for index :from start :below end
             :never (member (char source index) '(#\< #\> #\Newline #\Return)))))

(defun org-modern-transform-target (source string attributes open close glyph)
  (loop :with offset = 0
        :for start = (search open source :start2 offset)
        :while start
        :for content-start = (+ start (length open))
        :for close-start = (search close source :start2 content-start)
        :do
           (if (and close-start
                    (org-modern-target-content-p source content-start close-start))
               (let ((end (+ close-start (length close))))
                 (setf (aref string start) glyph)
                 (org-modern-replace-range string (1+ start) content-start #\Space)
                 (org-modern-replace-range string close-start end #\Space)
                 (setf attributes
                       (org-modern-overlay-symbol attributes start)
                       offset end))
               (setf offset (1+ start))))
  attributes)

(defun org-modern-transform-inline (source string attributes)
  (cl-ppcre:do-matches
      (start end
       "(?:<|\\[)[0-9]{4}-[0-9]{2}-[0-9]{2}[^]>]*(?:>|\\])" source)
    (setf (aref string start) #\Space
          (aref string (1- end)) #\Space))
  (setf attributes
        (org-modern-transform-target source string attributes
                                     "<<<" ">>>" #\⛯))
  ;; Radio targets have already consumed every triple delimiter.  Rejecting
  ;; adjacent angle brackets keeps this pass from treating them as <<targets>>.
  (loop :with offset = 0
        :for start = (search "<<" source :start2 offset)
        :while start
        :for close-start = (search ">>" source :start2 (+ start 2))
        :for radio-p = (or (and (plusp start)
                                (char= (char source (1- start)) #\<))
                           (and (< (+ start 2) (length source))
                                (char= (char source (+ start 2)) #\<)))
        :do
           (if (and close-start
                    (not radio-p)
                    (or (= (+ close-start 2) (length source))
                        (not (char= (char source (+ close-start 2)) #\>)))
                    (org-modern-target-content-p source (+ start 2) close-start))
               (let ((end (+ close-start 2)))
                 (setf (aref string start) #\↪
                       (aref string (1+ start)) #\Space)
                 (org-modern-replace-range string close-start end #\Space)
                 (setf attributes
                       (org-modern-overlay-symbol attributes start)
                       offset end))
               (setf offset (1+ start))))
  (values string attributes))

(defun transform-org-modern-display-line (buffer point logical-line &optional window)
  (declare (ignore window))
  (when (and (mode-active-p buffer 'org-mode)
             (mode-active-p buffer 'org-modern-mode))
    (let* ((source (lem-core::logical-line-string logical-line))
           (string (make-array (length source)
                               :element-type t
                               :initial-contents source))
           (attributes (lem-core::logical-line-attributes logical-line))
           (context (org-modern-line-block-context buffer point)))
      (unless (eq (car context) :inside)
        (multiple-value-setq (string attributes)
          (org-modern-transform-heading point source string attributes))
        (multiple-value-setq (string attributes)
          (org-modern-transform-horizontal-rule source string attributes))
        (multiple-value-setq (string attributes)
          (org-modern-transform-list source string attributes))
        (multiple-value-setq (string attributes)
          (org-modern-transform-table source string attributes))
        (multiple-value-setq (string attributes)
          (org-modern-transform-keyword source string context attributes))
        (multiple-value-setq (string attributes)
          (org-modern-transform-inline source string attributes)))
      (setf (lem-core::logical-line-string logical-line) (coerce string 'string)
            (lem-core::logical-line-attributes logical-line) attributes))))
