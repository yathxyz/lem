;;;; Terminal indentation guides matching the active Emacs indent-bars setup.
;;;; The renderer substitutes display-only glyphs; buffer text, undo history,
;;;; cursor positions, and save output remain unchanged.

(in-package :lem-yath)

(define-attribute lem-yath-indent-guide-1-attribute)
(define-attribute lem-yath-indent-guide-2-attribute)
(define-attribute lem-yath-indent-guide-3-attribute)
(define-attribute lem-yath-indent-guide-4-attribute)
(define-attribute lem-yath-indent-guide-5-attribute)
(define-attribute lem-yath-indent-guide-6-attribute)

(defparameter *indent-guide-attributes*
  #(lem-yath-indent-guide-1-attribute
    lem-yath-indent-guide-2-attribute
    lem-yath-indent-guide-3-attribute
    lem-yath-indent-guide-4-attribute
    lem-yath-indent-guide-5-attribute
    lem-yath-indent-guide-6-attribute))

(define-editor-variable lem-yath-indent-guides t
  "Whether programming buffers render indentation guide characters.")

(defun indent-guide-spacing (buffer)
  (let ((spacing
          (or (ignore-errors
                (variable-value 'lem/language-mode:indent-size
                                :default buffer))
              (variable-value 'tab-width :default buffer)
              4)))
    (if (and (integerp spacing) (plusp spacing)) spacing 4)))

(defun point-line-indentation (point)
  "Return visual indentation and whether POINT's line is blank."
  (with-point ((scan point))
    (line-start scan)
    (let ((column 0)
          (tab-width (variable-value 'tab-width :default scan)))
      (loop :for character := (character-at scan)
            :do (cond
                  ((eql character #\Space)
                   (incf column)
                   (character-offset scan 1))
                  ((eql character #\Tab)
                   (incf column (- tab-width (mod column tab-width)))
                   (character-offset scan 1))
                  (t
                   (return (values column
                                   (or (null character)
                                       (eql character #\Newline))))))))))

(defun indent-guide-context-cache (buffer)
  (let* ((tick (buffer-modified-tick buffer))
         (cache (buffer-value buffer 'lem-yath-indent-guide-context-cache)))
    (if (and (consp cache) (= tick (car cache)))
        (cdr cache)
        (let ((values (make-hash-table :test 'eql)))
          (setf (buffer-value buffer 'lem-yath-indent-guide-context-cache)
                (cons tick values))
          values))))

(defun nearby-nonblank-indentation (point direction)
  (with-point ((scan point))
    (loop :with blank-positions := nil
          :while (line-offset scan direction)
          :do (multiple-value-bind (indentation blank-p)
                  (point-line-indentation scan)
                (if blank-p
                    (push (position-at-point scan) blank-positions)
                    (return (values indentation blank-positions))))
          :finally (return (values 0 blank-positions)))))

(defun blank-line-context-indentation (point)
  "Match indent-bars' contextual blank-line behavior."
  (let* ((buffer (point-buffer point))
         (cache (indent-guide-context-cache buffer))
         (position (position-at-point point)))
    (multiple-value-bind (cached found-p) (gethash position cache)
      (if found-p
          cached
          (multiple-value-bind (prior prior-blanks)
              (nearby-nonblank-indentation point -1)
            (multiple-value-bind (next next-blanks)
                (nearby-nonblank-indentation point 1)
              (let ((context (max prior next)))
                (dolist (blank-position
                         (list* position (nconc prior-blanks next-blanks)))
                  (setf (gethash blank-position cache) context))
                context)))))))

(defun visible-indent-guide-depth (indentation spacing)
  (floor (max 0 (1- indentation)) spacing))

(defun string-limited-indentation (point indentation spacing)
  "Avoid descending through a multiline string beyond its opening context."
  (with-point ((scan point))
    (line-start scan)
    (if (not (in-string-p scan))
        indentation
        (with-point ((opener scan))
          (if (not (maybe-beginning-of-string opener))
              indentation
              (multiple-value-bind (opener-indentation blank-p)
                  (point-line-indentation opener)
                (declare (ignore blank-p))
                (min indentation
                     (1+ (* spacing
                            (1+ (visible-indent-guide-depth
                                 opener-indentation spacing)))))))))))

(defun cursor-attribute-at-index-p (attributes index)
  (loop :for (start end attribute) :in attributes
        :thereis (and (<= start index)
                      (< index end)
                      (lem-core::cursor-attribute-p attribute))))

(defun guide-attribute (depth)
  (aref *indent-guide-attributes*
        (mod (1- depth) (length *indent-guide-attributes*))))

(defun add-indent-guide-attribute (attributes index depth)
  (if (cursor-attribute-at-index-p attributes index)
      attributes
      (lem-core::overlay-attributes attributes
                                    index
                                    (1+ index)
                                    (guide-attribute depth))))

(defun extend-blank-logical-line (logical-line width)
  "Add display-only cells through WIDTH while keeping an EOL cursor anchored."
  (let* ((string (lem-core::logical-line-string logical-line))
         (length (length string))
         (cursor
           (lem-core::logical-line-end-of-line-cursor-attribute logical-line)))
    (when (< length width)
      (setf (lem-core::logical-line-string logical-line)
            (concatenate 'string string
                         (make-string (- width length)
                                      :initial-element #\Space)))
      (when cursor
        (setf (lem-core::logical-line-attributes logical-line)
              (lem-core::overlay-attributes
               (lem-core::logical-line-attributes logical-line)
               length
               (1+ length)
               cursor)
              (lem-core::logical-line-end-of-line-cursor-attribute logical-line)
              nil)))))

(defun transform-indent-guide-line (buffer point logical-line &optional window)
  (declare (ignore window))
  (when (and (programming-buffer-p buffer)
             (variable-value 'lem-yath-indent-guides :default buffer))
    (multiple-value-bind (indentation blank-p)
        (point-line-indentation point)
      (let* ((spacing (indent-guide-spacing buffer))
             (context-indentation
               (if blank-p
                   (blank-line-context-indentation point)
                   indentation))
             (indentation
               (string-limited-indentation point
                                           context-indentation
                                           spacing)))
        (when blank-p
          (extend-blank-logical-line logical-line indentation))
        (let ((string (copy-seq (lem-core::logical-line-string logical-line)))
              (attributes
                (lem-core::logical-line-attributes logical-line)))
          (loop :for index :from spacing :below indentation :by spacing
                :for depth :from 1
                :when (< index (length string))
                  :do (setf (char string index) #\│
                            attributes
                            (add-indent-guide-attribute attributes index depth)))
          (setf (lem-core::logical-line-string logical-line) string
                (lem-core::logical-line-attributes logical-line) attributes))))))

(defun transform-lem-yath-display-line (buffer point logical-line window)
  "Apply every lem-yath display-only line transformation in load order."
  (transform-org-modern-display-line buffer point logical-line window)
  (transform-indent-guide-line buffer point logical-line window)
  (transform-dirvish-display-line buffer point logical-line window))

(setf (variable-value 'lem-core::display-line-transform-function :global)
      'transform-lem-yath-display-line)

(define-command lem-yath-toggle-indent-guides () ()
  "Toggle display-only indentation guides in the current buffer."
  (let* ((buffer (current-buffer))
         (enabled
           (variable-value 'lem-yath-indent-guides :default buffer)))
    (setf (variable-value 'lem-yath-indent-guides :buffer buffer)
          (not enabled))
    (redraw-display :force t)
    (message "Indent guides ~:[disabled~;enabled~]"
             (not enabled))))
