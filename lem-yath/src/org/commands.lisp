;;;; Org editing commands and buffer-aware Evil/Vi integration.

(in-package :lem-yath)

;;; --- folding --------------------------------------------------------------

(define-command lem-yath-org-cycle () ()
  "Cycle a heading through folded, direct children, and full subtree.
In a table, align it and advance to the next cell."
  (cond
    ((org-table-line-p (current-point))
     (org-table-next-cell))
    ((org-heading-line-p (current-point))
     (org-cycle-heading (current-point))
     (redraw-display))
    (t
     (message "Org cycle: point is not on a heading or table"))))

(define-command lem-yath-org-shift-tab () ()
  "Move to the previous table cell, or cycle global Org visibility."
  (if (org-table-line-p (current-point))
      (org-table-previous-cell)
      (progn
        (org-cycle-global-visibility)
        (redraw-display))))

;;; --- heading navigation ---------------------------------------------------

(defun org-move-to-heading (heading)
  (when heading
    (move-point (current-point) heading)
    (line-start (current-point))
    t))

(lem-vi-mode:define-motion lem-yath-org-forward-element (&optional (count 1))
    (:universal)
  (:type :exclusive)
  (dotimes (_ (or count 1))
    (unless (org-move-to-heading (org-next-heading-point))
      (return))))

(lem-vi-mode:define-motion lem-yath-org-backward-element (&optional (count 1))
    (:universal)
  (:type :exclusive)
  (dotimes (_ (or count 1))
    (unless (org-move-to-heading (org-previous-heading-point))
      (return))))

(lem-vi-mode:define-motion lem-yath-org-up-element (&optional (count 1))
    (:universal)
  (:type :exclusive)
  (dotimes (_ (or count 1))
    (unless (org-move-to-heading (org-parent-heading-point))
      (return))))

(lem-vi-mode:define-motion lem-yath-org-down-element (&optional (count 1))
    (:universal)
  (:type :exclusive)
  (dotimes (_ (or count 1))
    (unless (org-move-to-heading (org-first-child-heading-point))
      (return))))

(lem-vi-mode:define-motion lem-yath-org-top (&optional (count 1)) (:universal)
  (:type :exclusive)
  (let ((wanted (or count 1)))
    (with-point ((point (current-point)))
      (loop
        (when (= wanted (or (org-heading-level-at point) 0))
          (return (org-move-to-heading point)))
        (unless (line-offset point -1)
          (return))))))

(lem-vi-mode:define-motion lem-yath-org-next-visible-line (&optional (count 1))
    (:universal)
  (:type :line)
  (let ((column (point-charpos (current-point))))
    (when (lem-core::move-to-next-visible-line (current-point) (or count 1))
      (move-to-column (current-point) column))))

(lem-vi-mode:define-motion lem-yath-org-previous-visible-line
    (&optional (count 1)) (:universal)
  (:type :line)
  (let ((column (point-charpos (current-point))))
    (when (lem-core::move-to-previous-visible-line
           (current-point) (or count 1))
      (move-to-column (current-point) column))))

;;; --- TODO workflow --------------------------------------------------------

(defun org-heading-todo-bounds (heading)
  "Return TODO start/end columns and state for HEADING."
  (let ((line (line-string heading)))
    (multiple-value-bind (start end register-starts register-ends)
        (cl-ppcre:scan
         (format nil "^\\*+\\s+(~a)(?:\\s|$)" *org-todo-keyword-pattern*)
         line)
      (declare (ignore start end))
      (when (and register-starts (aref register-starts 0))
        (let ((from (aref register-starts 0))
              (to (aref register-ends 0)))
          (values from to (subseq line from to)))))))

(defun org-set-heading-todo-state (heading state)
  "Set HEADING to STATE, where NIL removes its TODO keyword."
  (multiple-value-bind (todo-start todo-end old-state)
      (org-heading-todo-bounds heading)
    (with-point ((point heading))
      (line-start point)
      (cond
        (old-state
         (character-offset point todo-start)
         (let ((length (- todo-end todo-start)))
           (when (and (null state)
                      (eql (character-at point length) #\Space))
             (incf length))
           (delete-character point length)
           (when state
             (insert-string point state))))
        (state
         (character-offset point (1+ (org-heading-level-at heading)))
         (insert-string point (concatenate 'string state " ")))))
    state))

(defun org-next-todo-state (state)
  (if state
      (let ((tail (member state *org-todo-keywords* :test #'string=)))
        (second tail))
      (first *org-todo-keywords*)))

(define-command lem-yath-org-todo () ()
  "Cycle the configured TODO sequence and immediately save a file buffer."
  (alexandria:if-let ((heading (org-current-heading-point)))
    (multiple-value-bind (start end state) (org-heading-todo-bounds heading)
      (declare (ignore start end))
      (let ((next (org-next-todo-state state)))
        (org-clear-folds (current-buffer))
        (org-set-heading-todo-state heading next)
        ;; The Emacs configuration advises org-todo to persist immediately.
        (when (buffer-filename (current-buffer))
          (save-buffer (current-buffer)))
        (message "TODO state: ~a" (or next "none"))))
    (message "No Org heading at point")))

;;; --- checkboxes and lists -------------------------------------------------

(defun org-list-prefix (point)
  "Return the reusable list prefix on POINT's line, or NIL."
  (when (org-inside-block-p point)
    (return-from org-list-prefix nil))
  (let ((line (line-string point)))
    (multiple-value-bind (start end register-starts register-ends)
        (cl-ppcre:scan
         "^(\\s*)((?:[-+]\\s+|[0-9]+[.)]\\s+|\\*\\s+))(?:((?:\\[[ Xx-]\\]))\\s*)?"
         line)
      (declare (ignore start))
      (when end
        (let* ((indent (subseq line (aref register-starts 0)
                               (aref register-ends 0)))
               (bullet (subseq line (aref register-starts 1)
                               (aref register-ends 1)))
               (checkbox-start (and (>= (length register-starts) 3)
                                    (aref register-starts 2))))
          (unless (and (zerop (length indent))
                       (eql (char bullet 0) #\*))
            (concatenate 'string indent bullet
                         (if checkbox-start "[ ] " ""))))))))

(defun org-enter-insert-state ()
  (setf (lem-vi-mode/core:buffer-state)
        'lem-vi-mode/states:insert))

(defun org-open-list-or-table (above-p)
  (let ((prefix (org-list-prefix (current-point))))
    (cond
      (prefix
       (org-clear-folds (current-buffer))
       (if above-p
           (progn
             (line-start (current-point))
             (insert-string (current-point)
                            (concatenate 'string prefix (string #\Newline)))
             ;; INSERT-STRING leaves point at the original line.  Move back
             ;; into the newly inserted item so insert state edits that item.
             (line-offset (current-point) -1)
             (line-end (current-point)))
           (progn
             (line-end (current-point))
             (insert-string (current-point)
                            (concatenate 'string (string #\Newline) prefix))))
       (org-enter-insert-state)
       t)
      ((org-table-line-p (current-point))
       (when (org-table-insert-row above-p)
         (org-enter-insert-state))
       t)
      (t nil))))

(define-command lem-yath-org-open-below () ()
  (unless (org-open-list-or-table nil)
    (call-command 'lem-vi-mode/commands:vi-open-below nil)))

(define-command lem-yath-org-open-above () ()
  (unless (org-open-list-or-table t)
    (call-command 'lem-vi-mode/commands:vi-open-above nil)))

(define-command lem-yath-org-toggle-checkbox () ()
  "Toggle the first checkbox on the current Org line."
  (let ((line (line-string (current-point))))
    (multiple-value-bind (start end) (cl-ppcre:scan "\\[[ Xx-]\\]" line)
      (if (null start)
          (message "No checkbox on this line")
          (with-point ((point (current-point)))
            (line-start point)
            (character-offset point start)
            (let ((checked (member (char line (1+ start)) '(#\X #\x))))
              (delete-character point (- end start))
              (insert-string point (if checked "[ ]" "[X]"))))))))

;;; --- heading and subtree transforms --------------------------------------

(defun org-insert-heading-after-subtree (&key todo)
  (let* ((heading (org-current-heading-point))
         (level (or (and heading (org-heading-level-at heading)) 1))
         (target (if heading
                     (org-subtree-end-point heading)
                     (copy-point (current-point) :temporary)))
         (prefix (format nil "~v@{*~} ~:[~;TODO ~]" level todo))
         (before-next-heading-p
           (and heading (not (end-buffer-p target)))))
    (org-clear-folds (current-buffer))
    (move-point (current-point) target)
    (cond
      (before-next-heading-p
       ;; SUBTREE-END is the next sibling's line start.  Insert a complete
       ;; line before it, then return point to the end of the new prefix.
       (insert-string (current-point)
                      (concatenate 'string prefix (string #\Newline)))
       (line-offset (current-point) -1)
       (line-end (current-point)))
      (t
       (unless (start-line-p (current-point))
         (insert-character (current-point) #\Newline))
       (insert-string (current-point) prefix)))
    (org-enter-insert-state)))

(define-command lem-yath-org-insert-heading () ()
  (org-insert-heading-after-subtree))

(define-command lem-yath-org-insert-todo-heading () ()
  (org-insert-heading-after-subtree :todo t))

(define-command lem-yath-org-meta-return () ()
  (unless (org-open-list-or-table nil)
    (org-insert-heading-after-subtree)))

(define-command lem-yath-org-insert-line () ()
  "Enter Insert like Evil-Org's I with the configured Org defaults.

The active Emacs configuration leaves `org-special-ctrl-a/e' disabled.
Evil-Org consequently inserts at literal column zero on headings and list
items, but retains Evil's indentation-aware I everywhere else.  Reusing the
bounded native Org predicates also keeps list and heading lookalikes inside
source blocks on the ordinary Evil path."
  (if (or (org-heading-line-p (current-point))
          (org-list-item-line-p (current-point)))
      (progn
        (line-start (current-point))
        (org-enter-insert-state))
      (call-command 'lem-yath-insert-line nil)))

(defun org-list-item-line-p (point)
  (not (null (org-list-prefix point))))

(defun org-list-item-columns (&optional (point (current-point)))
  "Return indentation, list-content, and text columns for POINT's item."
  (when (org-inside-block-p point)
    (return-from org-list-item-columns nil))
  (multiple-value-bind (start end register-starts register-ends)
      (cl-ppcre:scan
       "^(\\s*)([-+*]|[0-9]+[.)])(\\s+)(?:\\[[ Xx-]\\]\\s+)?"
       (line-string point))
    (declare (ignore start register-starts))
    (when (and end
               (not (and (zerop (aref register-ends 0))
                         (eql (char (line-string point)
                                    (aref register-ends 0))
                              #\*))))
      (values (aref register-ends 0) (aref register-ends 2) end))))

(defun org-line-indentation (&optional (point (current-point)))
  (or (nth-value 1 (cl-ppcre:scan "^\\s*" (line-string point))) 0))

(defun org-list-item-tree-end (item)
  "Return the exclusive end of the list-item tree starting at ITEM."
  (multiple-value-bind (indent content-column) (org-list-item-columns item)
    (declare (ignore content-column))
    (unless indent
      (return-from org-list-item-tree-end nil))
    (with-point ((point item))
      (line-start point)
      (let ((pending-blank nil))
        (loop :while (line-offset point 1)
              :for line := (line-string point)
              :do (cond
                    ((zerop (length line))
                     (unless pending-blank
                       (setf pending-blank (copy-point point :temporary))))
                    ((or (org-heading-line-p point)
                         (and (org-list-item-line-p point)
                              (<= (nth-value 0 (org-list-item-columns point))
                                  indent))
                         (and (not (org-list-item-line-p point))
                              (<= (org-line-indentation point) indent)))
                     (return (or pending-blank
                                 (copy-point point :temporary))))
                    (t (setf pending-blank nil)))
              :finally
                 (return
                   (or pending-blank
                       (copy-point (buffer-end-point (point-buffer point))
                                   :temporary))))))))

(defun org-list-previous-item (item predicate)
  "Return the nearest earlier list item satisfying PREDICATE."
  (let ((base-indent (nth-value 0 (org-list-item-columns item))))
    (with-point ((point item))
      (line-start point)
      (loop :while (line-offset point -1)
            :for line := (line-string point)
            :when (or (org-heading-line-p point)
                      (zerop (length line)))
              :do (return nil)
            :when (org-list-item-line-p point)
              :do (multiple-value-bind (indent content-column)
                      (org-list-item-columns point)
                    (when (funcall predicate indent content-column point)
                      (return (copy-point point :temporary))))
            :when (and (not (org-list-item-line-p point))
                       (plusp (length line))
                       (<= (org-line-indentation point) base-indent))
              :do (return nil)))))

(defun org-list-ordered-item-p (&optional (point (current-point)))
  (and (org-list-item-line-p point)
       (not (null (cl-ppcre:scan "^\\s*[0-9]+[.)]\\s+"
                                  (line-string point))))))

(defun org-list-star-item-p (&optional (point (current-point)))
  (multiple-value-bind (indent content-column) (org-list-item-columns point)
    (declare (ignore content-column))
    (and indent (eql (char (line-string point) indent) #\*))))

(defun org-list-line-structural-tab-p (point)
  (let ((structural-end
          (if (org-list-item-line-p point)
              (nth-value 2 (org-list-item-columns point))
              (org-line-indentation point))))
    (and structural-end
         (position #\Tab (line-string point) :end structural-end))))

(defun org-list-context-tab-p (item)
  "Whether ITEM's contiguous list context uses tabs in structural columns."
  (or (org-list-line-structural-tab-p item)
      (with-point ((point item))
        (loop :while (line-offset point -1)
              :for line := (line-string point)
              :until (or (zerop (length line)) (org-heading-line-p point))
              :when (org-list-line-structural-tab-p point)
                :return t))
      (with-point ((point item))
        (loop :while (line-offset point 1)
              :for line := (line-string point)
              :until (or (zerop (length line)) (org-heading-line-p point))
              :when (org-list-line-structural-tab-p point)
                :return t))))

(defun org-list-item-has-child-p (item)
  (let ((indent (nth-value 0 (org-list-item-columns item)))
        (end (org-list-item-tree-end item)))
    (with-point ((point item))
      (loop :while (and (line-offset point 1) (point< point end))
            :when (and (org-list-item-line-p point)
                       (> (nth-value 0 (org-list-item-columns point)) indent))
              :return t))))

(defun org-list-item-has-direct-body-p (item)
  "Whether ITEM has non-list continuation content requiring Org reflow."
  (let ((end (org-list-item-tree-end item)))
    (with-point ((point item))
      (loop :while (and (line-offset point 1) (point< point end))
            :for line := (line-string point)
            :when (and (plusp (length line))
                       (not (org-list-item-line-p point)))
              :return t))))

(defun org-list-next-sibling (item)
  (multiple-value-bind (indent content-column) (org-list-item-columns item)
    (declare (ignore content-column))
    (alexandria:when-let ((end (org-list-item-tree-end item)))
      (unless (end-buffer-p end)
        (multiple-value-bind (candidate-indent candidate-content)
            (org-list-item-columns end)
          (declare (ignore candidate-content))
          (and (eql candidate-indent indent)
               (copy-point end :temporary)))))))

(defun org-list-previous-sibling (item)
  (multiple-value-bind (indent content-column) (org-list-item-columns item)
    (declare (ignore content-column))
    (org-list-previous-item
     item
     (lambda (candidate-indent candidate-content candidate)
       (declare (ignore candidate-content candidate))
       (cond ((< candidate-indent indent) (return-from org-list-previous-sibling nil))
             ((= candidate-indent indent) t))))))

(defun org-shift-line-indentation (point delta)
  (with-point ((line point))
    (line-start line)
    (cond
      ((plusp delta)
       (insert-string line (make-string delta :initial-element #\Space)))
      ((minusp delta)
       (let ((available (org-line-indentation line)))
         (delete-character line (min available (- delta))))))))

(defun org-shift-region-indentation (start end delta)
  (with-point ((point start))
    (line-start point)
    (loop :while (point< point end)
          :unless (zerop (length (line-string point)))
            :do (org-shift-line-indentation point delta)
          :unless (line-offset point 1)
            :do (return))))

(defun org-list-indent-target (item direction)
  (multiple-value-bind (indent content-column) (org-list-item-columns item)
    (declare (ignore content-column))
    (ecase direction
      (1
       (alexandria:when-let
           ((previous
              (org-list-previous-item
               item
               (lambda (candidate-indent candidate-content candidate)
                 (declare (ignore candidate-content candidate))
                 (cond ((< candidate-indent indent) nil)
                       ((= candidate-indent indent) t))))))
         (nth-value 1 (org-list-item-columns previous))))
      (-1
       (if (zerop indent)
           nil
           (or (alexandria:when-let
                   ((parent
                      (org-list-previous-item
                       item
                       (lambda (candidate-indent candidate-content candidate)
                         (declare (ignore candidate-content candidate))
                         (< candidate-indent indent)))))
                 (nth-value 0 (org-list-item-columns parent)))
               0))))))

(defun org-adjust-list-indent (direction &key tree)
  "Indent or outdent the current list item, optionally including its tree."
  (with-point ((item (current-point)))
    (line-start item)
    (multiple-value-bind (indent content-column) (org-list-item-columns item)
      (declare (ignore content-column))
      (unless indent
        (message "Point is not on an Org list item")
        (return-from org-adjust-list-indent nil))
      (when (org-list-ordered-item-p item)
        (message "Ordered-list structural edits need counter repair")
        (return-from org-adjust-list-indent nil))
      (when (org-list-context-tab-p item)
        (message "Tab-indented list structure is unchanged until column repair is available")
        (return-from org-adjust-list-indent nil))
      (when (and (not tree) (org-list-item-has-direct-body-p item))
        (message "Cannot safely indent a list item with continuation text")
        (return-from org-adjust-list-indent nil))
      (when (and (minusp direction) (not tree)
                 (org-list-item-has-child-p item))
        (message "Cannot outdent a list item without its children")
        (return-from org-adjust-list-indent nil))
      (alexandria:if-let ((target (org-list-indent-target item direction)))
        (let ((column (point-column (current-point)))
              (convert-star-p (and (zerop target)
                                   (org-list-star-item-p item)))
              (end (if tree
                       (org-list-item-tree-end item)
                       (with-point ((end item))
                         (if (line-offset end 1)
                             (copy-point end :temporary)
                             (copy-point (buffer-end-point (point-buffer end))
                                         :temporary)))))
              (delta (- target indent)))
          (org-clear-folds (current-buffer))
          (org-shift-region-indentation item end delta)
          (when convert-star-p
            (with-point ((bullet item))
              (line-start bullet)
              (delete-character bullet 1)
              (insert-character bullet #\-)))
          (move-to-column (current-point) (max 0 (+ column delta)))
          t)
        (message "Cannot ~:[outdent~;indent~] this list item"
                 (plusp direction))))))

(defun org-adjust-heading-level (delta)
  "Adjust only the heading on the current line by DELTA."
  (let ((level (org-heading-level-at (current-point))))
    (cond
      ((null level) nil)
      ((and (minusp delta) (= level 1))
       (message "A level-1 heading cannot be promoted")
       nil)
      (t
       (org-clear-folds (current-buffer))
       (with-point ((point (current-point)))
         (line-start point)
         (if (plusp delta)
             (insert-character point #\*)
             (delete-character point 1)))
       t))))

(defun org-adjust-subtree-level (delta)
  (alexandria:if-let ((heading (org-current-heading-point)))
    (let ((level (org-heading-level-at heading)))
      (when (and (minusp delta) (= level 1))
        (message "A level-1 heading cannot be promoted")
        (return-from org-adjust-subtree-level nil))
      (let ((end (org-subtree-end-point heading)))
        (org-clear-folds (current-buffer))
        (with-point ((point heading))
          (loop :while (point< point end)
                :when (org-heading-line-p point)
                  :do (line-start point)
                      (if (plusp delta)
                          (insert-character point #\*)
                          (delete-character point 1))
                :unless (line-offset point 1)
                  :do (return))))
      t)
    (message "No Org heading at point")))

(defun org-word-motion (direction)
  (call-command (if (minusp direction)
                    'lem-core/commands/word:previous-word
                    'lem-core/commands/word:forward-word)
                1))

(define-command lem-yath-org-metaleft () ()
  "Move a table column left, or promote the current heading/list item."
  (cond
    ((org-table-line-p (current-point)) (org-table-move-column -1))
    ((org-heading-line-p (current-point)) (org-adjust-heading-level -1))
    ((org-list-item-line-p (current-point)) (org-adjust-list-indent -1))
    (t (org-word-motion -1))))

(define-command lem-yath-org-metaright () ()
  "Move a table column right, or demote the current heading/list item."
  (cond
    ((org-table-line-p (current-point)) (org-table-move-column 1))
    ((org-heading-line-p (current-point)) (org-adjust-heading-level 1))
    ((org-list-item-line-p (current-point)) (org-adjust-list-indent 1))
    (t (org-word-motion 1))))

(defun org-swap-adjacent-linewise-text (first second)
  "Return SECOND followed by FIRST without joining an unterminated EOF line.
The second value is the length of SECOND in its new leading position."
  (if (and (plusp (length first))
           (eql (char first (1- (length first))) #\Newline)
           (or (zerop (length second))
               (not (eql (char second (1- (length second))) #\Newline))))
      (values (concatenate 'string second (string #\Newline)
                           (subseq first 0 (1- (length first))))
              (1+ (length second)))
      (values (concatenate 'string second first) (length second))))

(defun org-swap-subtree (direction)
  (alexandria:if-let ((heading (org-current-heading-point)))
    (let ((sibling (org-same-level-sibling heading direction)))
      (unless sibling
        (message "No same-level sibling in that direction")
        (return-from org-swap-subtree nil))
      (org-clear-folds (current-buffer))
      (let ((offset (- (position-at-point (current-point))
                       (position-at-point heading))))
        (if (plusp direction)
            (let* ((heading-end (org-subtree-end-point heading))
                   (sibling-end (org-subtree-end-point sibling))
                   (first (points-to-string heading heading-end))
                   (second (points-to-string sibling sibling-end)))
              (delete-between-points heading sibling-end)
              (multiple-value-bind (replacement second-length)
                  (org-swap-adjacent-linewise-text first second)
                (insert-string heading replacement)
                (move-point (current-point) heading)
                (character-offset (current-point) (+ second-length offset))))
            (let* ((sibling-end (org-subtree-end-point sibling))
                   (first (points-to-string sibling sibling-end))
                   (second (points-to-string heading (org-subtree-end-point heading))))
              (delete-between-points sibling (org-subtree-end-point heading))
              (multiple-value-bind (replacement second-length)
                  (org-swap-adjacent-linewise-text first second)
                (declare (ignore second-length))
                (insert-string sibling replacement)
                (move-point (current-point) sibling)
                (character-offset (current-point) offset)))))
      t)
    (message "No Org heading at point")))

(defun org-swap-list-item (direction)
  "Swap the current list-item tree with a same-level sibling."
  (with-point ((item (current-point)))
    (line-start item)
    (unless (org-list-item-line-p item)
      (message "Point is not on an Org list item")
      (return-from org-swap-list-item nil))
    (let ((sibling (if (minusp direction)
                       (org-list-previous-sibling item)
                       (org-list-next-sibling item))))
      (unless sibling
        (message "No same-level list item in that direction")
        (return-from org-swap-list-item nil))
      (when (or (org-list-ordered-item-p item)
                (org-list-ordered-item-p sibling))
        (message "Ordered-list movement needs counter repair")
        (return-from org-swap-list-item nil))
      (when (or (org-list-context-tab-p item)
                (org-list-context-tab-p sibling))
        (message "Tab-indented list movement is unchanged until column repair is available")
        (return-from org-swap-list-item nil))
      (org-clear-folds (current-buffer))
      (let ((offset (point-column (current-point))))
        (if (plusp direction)
            (let* ((item-end (org-list-item-tree-end item))
                   (sibling-end (org-list-item-tree-end sibling))
                   (first (points-to-string item item-end))
                   (second (points-to-string sibling sibling-end)))
              (delete-between-points item sibling-end)
              (multiple-value-bind (replacement second-length)
                  (org-swap-adjacent-linewise-text first second)
                (insert-string item replacement)
                (move-point (current-point) item)
                (character-offset (current-point) second-length)))
            (let* ((sibling-end (org-list-item-tree-end sibling))
                   (item-end (org-list-item-tree-end item))
                   (first (points-to-string sibling sibling-end))
                   (second (points-to-string item item-end)))
              (delete-between-points sibling item-end)
              (multiple-value-bind (replacement second-length)
                  (org-swap-adjacent-linewise-text first second)
                (declare (ignore second-length))
                (insert-string sibling replacement)
                (move-point (current-point) sibling))))
        (move-to-column (current-point) offset))
      t)))

(defun org-current-line-segment (point)
  (with-point ((start point)
               (end point))
    (line-start start)
    (line-start end)
    (if (line-offset end 1)
        (values (copy-point start :temporary)
                (copy-point end :temporary))
        (values (copy-point start :temporary)
                (copy-point (buffer-end-point (point-buffer end)) :temporary)))))

(defun org-drag-current-line (direction)
  "Swap the current literal line with its neighbor in DIRECTION."
  (let ((column (point-column (current-point))))
    (with-point ((neighbor (current-point)))
      (line-start neighbor)
      (unless (line-offset neighbor direction)
        (message "Cannot move line further")
        (return-from org-drag-current-line nil))
      (multiple-value-bind (current-start current-end)
          (org-current-line-segment (current-point))
        (multiple-value-bind (neighbor-start neighbor-end)
            (org-current-line-segment neighbor)
          (let* ((start (point-min current-start neighbor-start))
                 (end (point-max current-end neighbor-end))
                 (current-text (line-string current-start))
                 (neighbor-text (line-string neighbor-start))
                 (trailing-newline-p
                   (and (plusp (position-at-point end))
                        (eql (character-at end -1) #\Newline)))
                 (replacement
                   (format nil "~a~%~a~:[~;~%~]"
                           (if (minusp direction) current-text neighbor-text)
                           (if (minusp direction) neighbor-text current-text)
                           trailing-newline-p)))
            (org-clear-folds (current-buffer))
            (delete-between-points start end)
            (insert-string start replacement)
            (move-point (current-point) start)
            (when (plusp direction)
              (line-offset (current-point) 1))
            (move-to-column (current-point) column)
            t))))))

(define-command lem-yath-org-metaup () ()
  "Move the current table row, heading subtree, or list-item tree up."
  (cond
    ((org-table-line-p (current-point)) (org-table-move-row -1))
    ((org-heading-line-p (current-point)) (org-swap-subtree -1))
    ((org-list-item-line-p (current-point)) (org-swap-list-item -1))
    (t (message "No supported movable Org element at point"))))

(define-command lem-yath-org-metadown () ()
  "Move the current table row, heading subtree, or list-item tree down."
  (cond
    ((org-table-line-p (current-point)) (org-table-move-row 1))
    ((org-heading-line-p (current-point)) (org-swap-subtree 1))
    ((org-list-item-line-p (current-point)) (org-swap-list-item 1))
    (t (message "No supported movable Org element at point"))))

(define-command lem-yath-org-shiftmetaleft () ()
  "Delete a table column, promote a subtree, or outdent a list tree."
  (cond
    ((org-table-line-p (current-point)) (org-table-delete-column))
    ((org-heading-line-p (current-point)) (org-adjust-subtree-level -1))
    ((org-list-item-line-p (current-point))
     (org-adjust-list-indent -1 :tree t))
    (t (message "This command requires a table, heading, or list item"))))

(define-command lem-yath-org-shiftmetaright () ()
  "Insert a table column, demote a subtree, or indent a list tree."
  (cond
    ((org-table-line-p (current-point)) (org-table-insert-column))
    ((org-heading-line-p (current-point)) (org-adjust-subtree-level 1))
    ((org-list-item-line-p (current-point))
     (org-adjust-list-indent 1 :tree t))
    (t (message "This command requires a table, heading, or list item"))))

(define-command lem-yath-org-shiftmetaup () ()
  "Delete the current table row, or drag the literal line upward."
  (cond
    ((org-table-line-p (current-point)) (org-table-delete-row))
    ((cl-ppcre:scan "(?i)^\\s*CLOCK:" (line-string (current-point)))
     (message "CLOCK timestamp adjustment is not implemented; line unchanged"))
    (t (org-drag-current-line -1))))

(define-command lem-yath-org-shiftmetadown () ()
  "Insert a table row above point, or drag the literal line downward."
  (cond
    ((org-table-line-p (current-point)) (org-table-insert-row t))
    ((cl-ppcre:scan "(?i)^\\s*CLOCK:" (line-string (current-point)))
     (message "CLOCK timestamp adjustment is not implemented; line unchanged"))
    (t (org-drag-current-line 1))))

;;; --- links ---------------------------------------------------------------

(defun org-link-at-point (&optional (point (current-point)))
  "Return the bracket-link target covering POINT, or NIL."
  (let ((line (line-string point))
        (column (point-charpos point)))
    (cl-ppcre:do-scans (start end register-starts register-ends
                        "\\[\\[([^]\\n]+)\\](?:\\[[^]\\n]*\\])?\\]" line)
      (when (<= start column end)
        (return-from org-link-at-point
          (subseq line (aref register-starts 0) (aref register-ends 0)))))))

(defun org-split-link-search (target)
  (let ((separator (search "::" target)))
    (if separator
        (values (subseq target 0 separator) (subseq target (+ separator 2)))
        (values target nil))))

(defun org-relative-link-path (path)
  (let ((pathname (pathname path)))
    (if (uiop:absolute-pathname-p pathname)
        pathname
        (merge-pathnames
         pathname
         (or (and (buffer-filename (current-buffer))
                  (uiop:pathname-directory-pathname
                   (buffer-filename (current-buffer))))
             (buffer-directory (current-buffer)))))))

(defun org-visit-search-suffix (suffix)
  (when (and suffix (plusp (length suffix)))
    (let ((point (current-point)))
      (buffer-start point)
      (cond
        ((alexandria:starts-with-subseq "*" suffix)
         (search-forward-regexp
          point
          (format nil "(?m)^\\*+\\s+~a\\s*$"
                  (cl-ppcre:quote-meta-chars
                   (string-trim '(#\Space #\*) suffix)))))
        ((alexandria:starts-with-subseq "#" suffix)
         (search-forward-regexp
          point
          (format nil "(?mi)^:CUSTOM_ID:\\s*~a\\s*$"
                  (cl-ppcre:quote-meta-chars (subseq suffix 1)))))
        (t
         (search-forward-regexp point (cl-ppcre:quote-meta-chars suffix)))))))

(defun org-id-file (id)
  (let* ((root (workdir))
         (output (ignore-errors
                   (uiop:run-program
                    (list "rg" "--files-with-matches" "--glob" "*.org"
                          "--fixed-strings" (format nil ":ID: ~a" id)
                          (namestring root))
                    :output :string :ignore-error-status t)))
         (line (first (uiop:split-string (or output "")
                                         :separator (string #\Newline)))))
    (and line (plusp (length line)) (pathname line))))

(defun org-open-id-link (id)
  (alexandria:if-let ((file (org-id-file id)))
    (progn
      (find-file file)
      (let ((point (current-point)))
        (buffer-start point)
        (when (search-forward-regexp
               point
               (format nil "(?mi)^:ID:\\s*~a\\s*$"
                       (cl-ppcre:quote-meta-chars id)))
          (alexandria:when-let ((heading (org-current-heading-point point)))
            (move-point point heading)))))
    (message "No Org heading with ID ~a under ~a" id (workdir))))

(define-command lem-yath-org-open-at-point () ()
  "Open the Org bracket link at point."
  (alexandria:if-let ((target (org-link-at-point)))
    (cond
      ((or (alexandria:starts-with-subseq "http://" target)
           (alexandria:starts-with-subseq "https://" target)
           (alexandria:starts-with-subseq "mailto:" target))
       (open-with-xdg target))
      ((alexandria:starts-with-subseq "id:" target)
       (org-open-id-link (subseq target 3)))
      (t
       (multiple-value-bind (path suffix)
           (org-split-link-search
            (if (alexandria:starts-with-subseq "file:" target)
                (subseq target 5)
                target))
         (find-file (org-relative-link-path path))
         (org-visit-search-suffix suffix))))
    (message "No Org link at point")))

(define-command lem-yath-org-insert-link () ()
  "Insert an Org bracket link after prompting for target and description."
  (let ((target (prompt-for-string "Link target: ")))
    (when (plusp (length target))
      (let ((description (prompt-for-string "Description (optional): ")))
        (insert-string
         (current-point)
         (if (plusp (length description))
             (format nil "[[~a][~a]]" target description)
             (format nil "[[~a]]" target)))))))

;;; --- tables ---------------------------------------------------------------

(defun org-table-line-p (&optional (point (current-point)))
  (and (not (org-inside-block-p point))
       (not (null (cl-ppcre:scan "^\\s*\\|" (line-string point))))))

(defun org-table-separator-line-p (line)
  ;; Org recognizes a horizontal rule only when the opening pipe is followed
  ;; immediately by a dash.  Rows such as `| - |` and `|   |` contain data.
  (not (null (cl-ppcre:scan "^[ \\t]*\\|-" line))))

(defun org-table-cells (line)
  (let ((cells (cl-ppcre:split "\\|" (string-trim '(#\Space #\Tab) line))))
    (when (and cells (string= (first cells) ""))
      (setf cells (rest cells)))
    (when (and cells (string= (car (last cells)) ""))
      (setf cells (butlast cells)))
    (mapcar (lambda (cell) (string-trim '(#\Space #\Tab) cell)) cells)))

(defun org-table-bounds (&optional (origin (current-point)))
  (when (org-table-line-p origin)
    (with-point ((start origin)
                 (end origin))
      (line-start start)
      (line-start end)
      (loop :while (with-point ((previous start))
                     (and (line-offset previous -1)
                          (org-table-line-p previous)
                          (progn (move-point start previous) t))))
      (loop :while (with-point ((next end))
                     (and (line-offset next 1)
                          (org-table-line-p next)
                          (progn (move-point end next) t))))
      (line-end end)
      (values (copy-point start :temporary)
              (copy-point end :temporary)))))

(defun org-table-row-lines (start end)
  (let ((lines '()))
    (with-point ((point start))
      (loop
        (push (line-string point) lines)
        (when (same-line-p point end)
          (return))
        (unless (line-offset point 1)
          (return))))
    (nreverse lines)))

(defun org-table-formula-after-p (&optional (origin (current-point)))
  "Whether the table at ORIGIN is followed by an associated #+TBLFM."
  (multiple-value-bind (start end) (org-table-bounds origin)
    (declare (ignore start))
    (and end
         (with-point ((point end))
           (loop :while (line-offset point 1)
                 :for line := (line-string point)
                 :unless (cl-ppcre:scan "^\\s*$" line)
                   :do (return
                         (not (null
                               (cl-ppcre:scan "(?i)^\\s*#\\+TBLFM:"
                                              line))))
                 :finally (return nil))))))

(defun org-table-structural-editable-p ()
  (if (org-table-formula-after-p)
      (progn
        (message "Table structure is unchanged because #+TBLFM repair is unavailable")
        nil)
      t))

(defun org-table-column-widths (lines)
  (let ((widths '()))
    (dolist (line lines)
      (unless (org-table-separator-line-p line)
        (loop :for cell :in (org-table-cells line)
              :for index :from 0
              :do (let ((width (length cell)))
                    (if (< index (length widths))
                        (setf (nth index widths)
                              (max width (nth index widths)))
                        (setf widths
                              (append widths
                                      (make-list (- index (length widths))
                                                 :initial-element 0)
                                      (list width))))))))
    (if widths
        (mapcar (lambda (width) (max 1 width)) widths)
        ;; A table may temporarily contain only a horizontal rule.  Recover
        ;; its column count and approximate widths instead of reducing it to
        ;; an unusable `||'.
        (alexandria:when-let
            ((separator (find-if #'org-table-separator-line-p lines)))
          (let* ((start (position #\| separator))
                 (end (position #\| separator :from-end t))
                 (body (and start end (< start end)
                            (subseq separator (1+ start) end))))
            (when body
              (mapcar (lambda (segment)
                        (max 1 (- (length
                                   (string-trim '(#\Space #\Tab) segment))
                                  2)))
                      (cl-ppcre:split "\\+" body))))))))

(defun org-table-line-indentation (line)
  (let ((pipe (position #\| line)))
    (if pipe (subseq line 0 pipe) "")))

(defun org-format-table-row (line widths)
  (let ((indentation (org-table-line-indentation line)))
    (concatenate
     'string indentation
     (if (org-table-separator-line-p line)
         (format nil "|~{~a~^+~}|"
                 (mapcar
                  (lambda (width)
                    (make-string (+ width 2) :initial-element #\-))
                  widths))
         (let ((cells (org-table-cells line)))
           (with-output-to-string (out)
             (write-char #\| out)
             (loop :for width :in widths
                   :for index :from 0
                   :for cell := (or (nth index cells) "")
                   :do (format out " ~vA |" width cell))))))))

(defun org-table-cell-index (&optional (point (current-point)))
  (let* ((line (line-string point))
         (end (min (point-charpos point) (length line))))
    (if (org-table-separator-line-p line)
        (count-if (lambda (character)
                    (member character '(#\| #\+)))
                  line :end end)
        (count #\| line :end end))))

(defun org-table-move-to-cell (point index)
  (line-start point)
  (let ((line (line-string point))
        (seen 0))
    (loop :for column :from 0 :below (length line)
          :when (if (org-table-separator-line-p line)
                    (member (char line column) '(#\| #\+))
                    (eql (char line column) #\|))
            :do (incf seen)
                (when (= seen index)
                  (move-to-column point (min (length line) (+ column 2)))
                  (return t)))))

(defun org-table-align ()
  "Align the contiguous Org table at point and preserve the current cell."
  (multiple-value-bind (start end) (org-table-bounds)
    (unless start
      (return-from org-table-align nil))
    (let* ((row (- (line-number-at-point (current-point))
                   (line-number-at-point start)))
           (cell (max 1 (org-table-cell-index)))
           (lines (org-table-row-lines start end))
           (widths (org-table-column-widths lines))
           (formatted (format nil "~{~a~^~%~}"
                              (mapcar (lambda (line)
                                        (org-format-table-row line widths))
                                      lines))))
      (delete-between-points start end)
      (insert-string start formatted)
      (move-point (current-point) start)
      (line-offset (current-point) row)
      (org-table-move-to-cell (current-point) cell)
      t)))

(defun org-table-last-cell-p (point)
  (let* ((line (line-string point))
         (column (point-charpos point))
         (next (position #\| line :start (min (length line) (1+ column)))))
    (or (null next)
        (null (position #\| line :start (1+ next))))))

(defun org-table-next-cell ()
  (org-table-align)
  (let ((index (max 1 (org-table-cell-index))))
    (if (org-table-last-cell-p (current-point))
        (with-point ((next (current-point)))
          (if (and (line-offset next 1) (org-table-line-p next)
                   (not (org-table-separator-line-p (line-string next))))
              (progn
                (move-point (current-point) next)
                (org-table-move-to-cell (current-point) 1))
              (org-table-insert-row nil)))
        (org-table-move-to-cell (current-point) (1+ index)))))

(defun org-table-previous-cell ()
  (org-table-align)
  (let ((index (max 1 (org-table-cell-index)))
        (separator-p (org-table-separator-line-p
                      (line-string (current-point)))))
    (if (and (not separator-p) (> index 1))
        (org-table-move-to-cell (current-point) (1- index))
        (with-point ((previous (current-point)))
          (loop :while (line-offset previous -1)
                :when (and (org-table-line-p previous)
                           (not (org-table-separator-line-p
                                 (line-string previous))))
                  :do (move-point (current-point) previous)
                      (org-table-move-to-cell
                       (current-point)
                       (length (org-table-cells (line-string previous))))
                      (return))))))

(defun org-table-insert-row (above-p)
  (unless (org-table-structural-editable-p)
    (return-from org-table-insert-row nil))
  (multiple-value-bind (start end) (org-table-bounds)
    (let* ((lines (org-table-row-lines start end))
           (columns (max 1 (or (org-table-data-column-count lines)
                               (length (org-table-column-widths lines)))))
           (indentation (org-table-line-indentation
                         (line-string (current-point))))
           (row (org-table-raw-data-line
                 indentation (make-list columns :initial-element ""))))
      (if above-p
          (progn
            (line-start (current-point))
            (insert-string (current-point)
                           (concatenate 'string row (string #\Newline)))
            (line-offset (current-point) -1))
          (progn
            (line-end (current-point))
            (insert-string
             (current-point) (concatenate 'string (string #\Newline) row))))
      (org-table-move-to-cell (current-point) 1)
      t)))

(defun org-table-row-indentation (line)
  (subseq line 0 (or (position #\| line) 0)))

(defun org-table-data-column-count (lines)
  (loop :for line :in lines
        :unless (org-table-separator-line-p line)
          :return (length (org-table-cells line))))

(defun org-table-raw-data-line (indentation cells)
  (format nil "~a| ~{~a~^ | ~} |" indentation cells))

(defun org-table-raw-separator-line (indentation columns)
  (format nil "~a|~{~a~^+~}|"
          indentation (make-list columns :initial-element "---")))

(defun org-table-rewrite-lines (lines row cell)
  "Replace the table at point with LINES, then restore ROW and CELL."
  (multiple-value-bind (start end) (org-table-bounds)
    (unless start
      (return-from org-table-rewrite-lines nil))
    (delete-between-points start end)
    (insert-string start (format nil "~{~a~^~%~}" lines))
    (move-point (current-point) start)
    (line-offset (current-point) row)
    (org-table-move-to-cell (current-point) cell)
    (org-table-align)
    t))

(defun org-table-transform-columns (transform target-cell)
  (unless (org-table-structural-editable-p)
    (return-from org-table-transform-columns nil))
  (multiple-value-bind (raw-start raw-end) (org-table-bounds)
    (unless (org-table-data-column-count
             (org-table-row-lines raw-start raw-end))
      (message "A table column operation needs at least one data row")
      (return-from org-table-transform-columns nil)))
  (org-table-align)
  (multiple-value-bind (start end) (org-table-bounds)
    (let* ((row (- (line-number-at-point (current-point))
                   (line-number-at-point start)))
           (lines (org-table-row-lines start end))
           (columns (org-table-data-column-count lines))
           (cell (min (or columns 1) (max 1 (org-table-cell-index)))))
      (unless (plusp (or columns 0))
        (message "A table column operation needs at least one data row")
        (return-from org-table-transform-columns nil))
      (let* ((new-columns (length (funcall transform
                                           (make-list columns
                                                      :initial-element ""))))
             (rewritten
               (mapcar
                (lambda (line)
                  (let ((indentation (org-table-row-indentation line)))
                    (if (org-table-separator-line-p line)
                        (org-table-raw-separator-line indentation new-columns)
                        (org-table-raw-data-line
                         indentation (funcall transform (org-table-cells line))))))
                lines)))
        (org-table-rewrite-lines rewritten row
                                 (funcall target-cell cell columns))))))

(defun org-swap-list-elements (list left right)
  (let ((copy (copy-list list)))
    (rotatef (nth left copy) (nth right copy))
    copy))

(defun org-table-move-column (direction)
  "Move the current table column one place in DIRECTION."
  (unless (org-table-structural-editable-p)
    (return-from org-table-move-column nil))
  (multiple-value-bind (raw-start raw-end) (org-table-bounds)
    (unless (org-table-data-column-count
             (org-table-row-lines raw-start raw-end))
      (message "A table column operation needs at least one data row")
      (return-from org-table-move-column nil)))
  (org-table-align)
  (multiple-value-bind (start end) (org-table-bounds)
    (let* ((lines (org-table-row-lines start end))
           (columns (org-table-data-column-count lines))
           (cell (min (or columns 1) (max 1 (org-table-cell-index))))
           (target (+ cell direction)))
      (cond
        ((or (null columns) (< target 1) (> target columns))
         (message "Cannot move table column further")
         nil)
        (t
         (org-table-transform-columns
          (lambda (cells)
            (org-swap-list-elements cells (1- cell) (1- target)))
          (lambda (old-cell old-columns)
            (declare (ignore old-cell old-columns))
            target)))))))

(defun org-table-insert-column ()
  "Insert an empty table column immediately before the current column."
  (unless (org-table-structural-editable-p)
    (return-from org-table-insert-column nil))
  (multiple-value-bind (raw-start raw-end) (org-table-bounds)
    (unless (org-table-data-column-count
             (org-table-row-lines raw-start raw-end))
      (message "A table column operation needs at least one data row")
      (return-from org-table-insert-column nil)))
  (org-table-align)
  (multiple-value-bind (start end) (org-table-bounds)
    (let* ((columns (org-table-data-column-count
                     (org-table-row-lines start end)))
           (cell (min (or columns 1) (max 1 (org-table-cell-index))))
           (index (1- cell)))
      (org-table-transform-columns
       (lambda (cells)
         (append (subseq cells 0 index) (list "") (subseq cells index)))
       (lambda (old-cell old-columns)
         (declare (ignore old-cell old-columns))
         cell)))))

(defun org-table-delete-column ()
  "Delete the current table column without touching its enclosing subtree."
  (unless (org-table-structural-editable-p)
    (return-from org-table-delete-column nil))
  (multiple-value-bind (raw-start raw-end) (org-table-bounds)
    (let ((columns (org-table-data-column-count
                    (org-table-row-lines raw-start raw-end))))
      (cond
        ((null columns)
         (message "A table column operation needs at least one data row")
         (return-from org-table-delete-column nil))
        ((= columns 1)
         (message "Cannot delete the only table column safely")
         (return-from org-table-delete-column nil)))))
  (org-table-align)
  (multiple-value-bind (start end) (org-table-bounds)
    (let* ((columns (org-table-data-column-count
                     (org-table-row-lines start end)))
           (cell (min (or columns 1) (max 1 (org-table-cell-index))))
           (index (1- cell)))
      (org-table-transform-columns
       (lambda (cells)
         (append (subseq cells 0 index) (subseq cells (1+ index))))
       (lambda (old-cell old-columns)
         (declare (ignore old-cell))
         (max 1 (min cell (max 1 (1- old-columns)))))))))

(defun org-table-move-row (direction)
  "Move the current literal table row one line in DIRECTION."
  (unless (org-table-structural-editable-p)
    (return-from org-table-move-row nil))
  (org-table-align)
  (multiple-value-bind (start end) (org-table-bounds)
    (let* ((row (- (line-number-at-point (current-point))
                   (line-number-at-point start)))
           (cell (max 1 (org-table-cell-index)))
           (lines (org-table-row-lines start end))
           (target (+ row direction)))
      (if (or (< target 0) (>= target (length lines)))
          (progn (message "Cannot move table row further") nil)
          (org-table-rewrite-lines
           (org-swap-list-elements lines row target) target cell)))))

(defun org-table-delete-row ()
  "Delete the current table row or horizontal separator."
  (unless (org-table-structural-editable-p)
    (return-from org-table-delete-row nil))
  (org-table-align)
  (multiple-value-bind (start end) (org-table-bounds)
    (let* ((row (- (line-number-at-point (current-point))
                   (line-number-at-point start)))
           (cell (max 1 (org-table-cell-index)))
           (lines (org-table-row-lines start end))
           (remaining (append (subseq lines 0 row)
                              (subseq lines (1+ row)))))
      (if remaining
          (org-table-rewrite-lines remaining
                                   (min row (1- (length remaining))) cell)
          (progn
            (when (eql (character-at end) #\Newline)
              (character-offset end 1))
            (delete-between-points start end)
            (move-point (current-point) start)
            t)))))

(define-command lem-yath-org-context-action () ()
  "Align a table; execution of source blocks remains a later safe tranche."
  (if (org-table-line-p (current-point))
      (org-table-align)
      (message "No supported Org context action at point")))

;;; --- Evil-Org destructive editing ---------------------------------------

(defvar *org-tags-column* -77
  "Configured terminal headline-tag column.

A negative value right-aligns the tag suffix so it ends at the absolute value,
matching the active Emacs terminal profile.")

(defun org-tag-suffix-character-p (character)
  "Whether CHARACTER may occur in an Org headline tag suffix."
  (or (alphanumericp character)
      (member character '(#\_ #\@ #\# #\% #\:))))

(defun org-heading-tag-bounds (&optional (point (current-point)))
  "Return tag start, end, and preceding-blank start columns on POINT's line."
  (when (org-heading-line-p point)
    (let* ((line (line-string point))
           (end (length line)))
      (loop :while (and (plusp end)
                        (member (char line (1- end)) '(#\Space #\Tab)))
            :do (decf end))
      (when (and (> end 2) (char= (char line (1- end)) #\:))
        (let ((start end))
          (loop :while (and (plusp start)
                            (org-tag-suffix-character-p
                             (char line (1- start))))
                :do (decf start))
          (when (and (plusp start)
                     (char= (char line start) #\:)
                     (member (char line (1- start)) '(#\Space #\Tab))
                     (loop :for index :from (1+ start) :below (1- end)
                           :thereis (not (char= (char line index) #\:))))
            (let ((blank start))
              (loop :while (and (plusp blank)
                                (member (char line (1- blank))
                                        '(#\Space #\Tab)))
                    :do (decf blank))
              (values start end blank))))))))

(defun org-align-current-heading-tags ()
  "Match `org-fix-tags-on-the-fly' for the configured terminal profile."
  (multiple-value-bind (tag-start tag-end blank-start)
      (org-heading-tag-bounds)
    (when (and tag-start (< (point-charpos (current-point)) tag-start))
      (let* ((tag-width (- tag-end tag-start))
             (configured *org-tags-column*)
             (target (cond ((minusp configured)
                            (- (abs configured) tag-width))
                           ((plusp configured) configured)
                           (t (1+ blank-start))))
             (new-start (max target (1+ blank-start)))
             (origin-column (point-charpos (current-point)))
             (in-blank-p (and (> origin-column blank-start)
                              (<= origin-column tag-start))))
        (unless (= new-start tag-start)
          (with-point ((start (current-point))
                       (end (current-point)))
            (line-start start)
            (line-start end)
            (character-offset start blank-start)
            (character-offset end tag-start)
            (delete-between-points start end)
            (insert-character start #\Space (- new-start blank-start)))
          (when in-blank-p
            (move-to-column (current-point) origin-column)))))))

(defun org-ordered-item-number-info (point)
  "Return indentation, number bounds/value, and counter cookie for POINT."
  (multiple-value-bind (start end register-starts register-ends)
      (cl-ppcre:scan
       "^(\\s*)([0-9]+)([.)])(\\s+)(?:\\[@([0-9]+)\\]\\s+)?"
       (line-string point))
    (declare (ignore start end))
    (when (and register-starts (aref register-starts 1))
      (let ((cookie-start (and (> (length register-starts) 4)
                               (aref register-starts 4))))
        (values (aref register-ends 0)
                (aref register-starts 1)
                (aref register-ends 1)
                (parse-integer
                 (subseq (line-string point)
                         (aref register-starts 1)
                         (aref register-ends 1)))
                (and cookie-start
                     (parse-integer
                      (subseq (line-string point)
                              cookie-start
                              (aref register-ends 4)))))))))

(defun org-list-repair-segment-lines (anchor)
  "Return the nonblank, non-heading segment surrounding list ANCHOR."
  (with-point ((start anchor))
    (line-start start)
    (loop
      (with-point ((previous start))
        (unless (line-offset previous -1)
          (return))
        (when (or (zerop (length (line-string previous)))
                  (org-heading-line-p previous))
          (return))
        (move-point start previous)))
    (loop :with lines := nil
          :with point := (copy-point start :temporary)
          :for line := (line-string point)
          :until (or (zerop (length line))
                     (org-heading-line-p point))
          :do (push (copy-point point :temporary) lines)
          :unless (line-offset point 1)
            :do (return (nreverse lines))
          :finally (return (nreverse lines)))))

(defun org-ordered-list-repair-plan (anchor)
  "Return repair lines and safety for the ordered list around ANCHOR."
  (let ((lines (org-list-repair-segment-lines anchor))
        (types (make-hash-table :test #'eql))
        (ordered-p nil)
        (safe-p t))
    (dolist (line lines)
      (multiple-value-bind (indent content-column)
          (org-list-item-columns line)
        (declare (ignore content-column))
        (unless (and indent
                     (not (org-list-line-structural-tab-p line)))
          (setf safe-p nil)
          (return))
        (let* ((type (if (org-list-ordered-item-p line)
                         :ordered :unordered))
               (prior (gethash indent types)))
          (when (and prior (not (eq prior type)))
            (setf safe-p nil)
            (return))
          (setf (gethash indent types) type)
          (when (eq type :ordered)
            (setf ordered-p t)))))
    (values lines safe-p ordered-p)))

(defun org-delete-crosses-current-line-p (start end)
  "Whether START..END extends outside point's current logical line."
  (with-point ((line-start (current-point))
               (line-end (current-point)))
    (line-start line-start)
    (line-end line-end)
    (or (point< start line-start) (point< line-end end))))

(defun org-delete-ordered-anchor (start end)
  "Return a candidate ordered-list repair anchor for START..END."
  (when (org-delete-crosses-current-line-p start end)
    (or (and (org-list-ordered-item-p (current-point))
             (copy-point (current-point) :temporary))
        (and (org-list-ordered-item-p start)
             (copy-point start :temporary))
        (and (org-list-ordered-item-p end)
             (copy-point end :temporary)))))

(defun org-preflight-ordered-delete (start end)
  "Return whether deletion needs repair; abort unsafe repair before mutation."
  (alexandria:if-let ((anchor (org-delete-ordered-anchor start end)))
    (multiple-value-bind (lines safe-p ordered-p)
        (org-ordered-list-repair-plan anchor)
      (declare (ignore lines))
      (unless (and safe-p ordered-p)
        (message "Ordered-list deletion needs unsupported structural repair")
        (error 'lem-vi-mode/core:operator-abort))
      t)
    nil))

(defun org-repair-ordered-list-at-point ()
  "Renumber the safe ordered-list segment containing point."
  (unless (org-list-ordered-item-p (current-point))
    (return-from org-repair-ordered-list-at-point nil))
  (multiple-value-bind (lines safe-p ordered-p)
      (org-ordered-list-repair-plan (current-point))
    (unless (and safe-p ordered-p)
      (return-from org-repair-ordered-list-at-point nil))
    (let ((next-by-indent (make-hash-table :test #'eql))
          (changes nil))
      (dolist (line lines)
        (multiple-value-bind (indent number-start number-end old cookie)
            (org-ordered-item-number-info line)
          (multiple-value-bind (item-indent content-column)
              (org-list-item-columns line)
            (declare (ignore content-column))
            (let ((deeper nil))
              (maphash (lambda (key value)
                         (declare (ignore value))
                         (when (> key item-indent) (push key deeper)))
                       next-by-indent)
              (dolist (key deeper) (remhash key next-by-indent)))
            (if indent
                (let ((new (or cookie
                               (1+ (gethash indent next-by-indent 0)))))
                  (setf (gethash indent next-by-indent) new)
                  (unless (= old new)
                    (push (list (copy-point line :temporary)
                                number-start number-end new)
                          changes)))
                (remhash item-indent next-by-indent)))))
      (dolist (change changes)
        (destructuring-bind (line start-column end-column number) change
          (with-point ((start line) (end line))
            (line-start start)
            (line-start end)
            (character-offset start start-column)
            (character-offset end end-column)
            (delete-between-points start end)
            (insert-string start (princ-to-string number)))))
      t)))

(defun org-delete-range (start end type &key repair-p)
  "Delete START..END through Vi and apply configured Org repairs."
  (let ((ordered-p (and repair-p
                        (org-preflight-ordered-delete start end))))
    (if repair-p
        (let ((lem-core::*this-command*
                (get-command 'lem-vi-mode/commands:vi-delete)))
          (lem-vi-mode/commands:vi-delete start end type))
        (lem-vi-mode/commands:vi-delete start end type))
    (when ordered-p
      (org-repair-ordered-list-at-point))
    (org-align-current-heading-tags)))

(defun org-table-single-delete-padding-p (start end)
  "Whether one-character START..END deletion gets Org table padding."
  (and (same-line-p start end)
       (= 1 (- (position-at-point end) (position-at-point start)))
       (org-table-line-p start)
       (not (eql (character-at start) #\|))
       (find-if (lambda (character)
                  (not (member character '(#\Space #\Tab))))
                (line-string start)
                :end (point-charpos start))
       (position #\| (line-string start)
                 :start (1+ (point-charpos start)))))

(defun org-pad-table-after-single-delete ()
  "Insert replacement padding before the next table separator."
  (let* ((line (line-string (current-point)))
         (separator (position #\| line :start (point-charpos (current-point)))))
    (when separator
      (with-point ((point (current-point)))
        (line-start point)
        (character-offset point separator)
        (insert-character point #\Space)))))

(defun org-delete-character-range (start end type)
  "Delete one normal-state character range with Org table/tag behavior."
  (let ((pad-p (org-table-single-delete-padding-p start end)))
    (org-delete-range start end type)
    (when pad-p
      (org-pad-table-after-single-delete))))

(lem-vi-mode:define-operator lem-yath-org-delete (start end type) ("<R>")
  (:move-point nil)
  (org-delete-range start end type :repair-p t))

(lem-vi-mode:define-operator lem-yath-org-delete-lines (start end type) ("<R>")
  (:motion lem-yath-line-motion :move-point nil)
  (org-delete-range start end type :repair-p t))

(lem-vi-mode:define-operator lem-yath-org-delete-to-zero
    (start end type) ("<R>")
  (:motion lem-yath-zero-motion :move-point nil)
  (org-delete-range start end type :repair-p t))

(lem-vi-mode:define-operator lem-yath-org-delete-next-char
    (start end type) ("<R>")
  (:motion lem-vi-mode/commands:vi-forward-char :move-point nil)
  (org-delete-character-range start end type))

(lem-vi-mode:define-operator lem-yath-org-delete-previous-char
    (start end type) ("<R>")
  (:motion lem-vi-mode/commands:vi-backward-char :move-point nil)
  (org-delete-character-range start end type))

(define-command lem-yath-org-delete-or-surround (argument) (:universal-nil)
  "Dispatch Evil-Org d without losing surround or counted motions."
  (multiple-value-bind (key combined-argument counted-p)
      (lem-yath-read-operator-key argument)
    (case (key-to-char key)
      (#\s
       (if counted-p
           (call-vi-operator 'lem-yath-org-delete combined-argument key)
           (lem-yath-surround-delete)))
      (#\d
       (call-command 'lem-yath-org-delete-lines combined-argument))
      (#\0
       (call-command 'lem-yath-org-delete-to-zero combined-argument))
      (otherwise
       (call-vi-operator 'lem-yath-org-delete combined-argument key)))))

;;; --- Vi state maps --------------------------------------------------------

(defvar *org-vi-normal-keymap* (make-keymap :description '*org-vi-normal-keymap*))
(defvar *org-vi-visual-keymap* (make-keymap :description '*org-vi-visual-keymap*))
(defvar *org-vi-insert-keymap* (make-keymap :description '*org-vi-insert-keymap*))

(defun configure-org-vi-common-map (keymap)
  (define-key keymap "j" 'lem-yath-org-next-visible-line)
  (define-key keymap "k" 'lem-yath-org-previous-visible-line)
  (define-key keymap "Tab" 'lem-yath-org-cycle)
  (define-key keymap "g Tab" 'lem-yath-org-cycle)
  (define-key keymap "Shift-Tab" 'lem-yath-org-shift-tab)
  (define-key keymap "g h" 'lem-yath-org-up-element)
  (define-key keymap "g l" 'lem-yath-org-down-element)
  (define-key keymap "g k" 'lem-yath-org-backward-element)
  (define-key keymap "g j" 'lem-yath-org-forward-element)
  (define-key keymap "g H" 'lem-yath-org-top)
  (define-key keymap "M-h" 'lem-yath-org-metaleft)
  (define-key keymap "M-l" 'lem-yath-org-metaright)
  (define-key keymap "M-k" 'lem-yath-org-metaup)
  (define-key keymap "M-j" 'lem-yath-org-metadown)
  (define-key keymap "M-H" 'lem-yath-org-shiftmetaleft)
  (define-key keymap "M-L" 'lem-yath-org-shiftmetaright)
  (define-key keymap "M-K" 'lem-yath-org-shiftmetaup)
  (define-key keymap "M-J" 'lem-yath-org-shiftmetadown)
  ;; Evil-Org's < and > are range operators, not aliases for org-metaleft
  ;; and org-metaright.  Fail closed until the native range operators below
  ;; are available instead of silently changing an enclosing subtree.
  (undefine-key keymap "<")
  (undefine-key keymap ">"))

(configure-org-vi-common-map *org-vi-normal-keymap*)
(configure-org-vi-common-map *org-vi-visual-keymap*)

(define-command lem-yath-org-visual-structural-unsupported () ()
  (message "Region-aware Evil-Org Meta editing is not implemented; selection unchanged"))

;; Point-only structural commands would silently ignore most of a Vi
;; selection.  Keep the selection byte-identical until the region semantics
;; can be implemented as true operators.
(dolist (key '("M-h" "M-l" "M-k" "M-j" "M-H" "M-L" "M-K" "M-J"))
  (define-key *org-vi-visual-keymap* key
    'lem-yath-org-visual-structural-unsupported))

(define-key *org-vi-normal-keymap* "o" 'lem-yath-org-open-below)
(define-key *org-vi-normal-keymap* "O" 'lem-yath-org-open-above)
(define-key *org-vi-normal-keymap* "0" 'lem-yath-zero)
(define-key *org-vi-normal-keymap* "$" 'lem-yath-end-of-line)
(define-key *org-vi-normal-keymap* "I" 'lem-yath-org-insert-line)
(define-key *org-vi-normal-keymap* "A" 'lem-yath-append-line)
(define-key *org-vi-normal-keymap* "d" 'lem-yath-org-delete-or-surround)
(define-key *org-vi-normal-keymap* "x" 'lem-yath-org-delete-next-char)
(define-key *org-vi-normal-keymap* "X" 'lem-yath-org-delete-previous-char)
(define-key *org-vi-normal-keymap* "C-Return" 'lem-yath-org-insert-heading)
(define-key *org-vi-normal-keymap* "C-Shift-Return"
  'lem-yath-org-insert-todo-heading)

(define-key *org-vi-insert-keymap* "Tab" 'lem-yath-org-cycle)
(define-key *org-vi-insert-keymap* "Shift-Tab" 'lem-yath-org-shift-tab)
(define-key *org-vi-insert-keymap* "C-t" 'lem-yath-org-metaright)
(define-key *org-vi-insert-keymap* "C-d" 'lem-yath-org-metaleft)

;;; Stock Org chords that do not conflict with the active Evil state maps.
(define-key *org-mode-keymap* "Tab" 'lem-yath-org-cycle)
(define-key *org-mode-keymap* "Shift-Tab" 'lem-yath-org-shift-tab)
(define-key *org-mode-keymap* "C-c C-t" 'lem-yath-org-todo)
(define-key *org-mode-keymap* "C-c C-x C-b" 'lem-yath-org-toggle-checkbox)
(define-key *org-mode-keymap* "C-c C-l" 'lem-yath-org-insert-link)
(define-key *org-mode-keymap* "C-c C-o" 'lem-yath-org-open-at-point)
(define-key *org-mode-keymap* "C-c C-c" 'lem-yath-org-context-action)
(define-key *org-mode-keymap* "M-Return" 'lem-yath-org-meta-return)
(define-key *org-mode-keymap* "C-Return" 'lem-yath-org-insert-heading)
(define-key *org-mode-keymap* "C-Shift-Return" 'lem-yath-org-insert-todo-heading)
