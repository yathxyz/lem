;;;; Evil-Org-compatible text objects and Org-local Vi dispatch.

(in-package :lem-yath)

;;; --- Range adaptation -----------------------------------------------------

(defun org-vi-existing-visual-range ()
  "Return the active Visual range, or NIL outside Visual state."
  (when (lem-vi-mode/visual:visual-p)
    (lem-vi-mode/visual:visual-range)))

(defun org-vi-normalized-visual-range (visual-range)
  "Return copied low/high endpoints for a possibly reversed VISUAL-RANGE."
  (when visual-range
    (destructuring-bind (first second) visual-range
      (let ((start (copy-point first :temporary))
            (end (copy-point second :temporary)))
        (when (point< end start)
          (rotatef start end))
        (list start end)))))

(defun org-vi-abort-text-object (visual-range)
  "Abort without changing an existing VISUAL-RANGE."
  (if visual-range
      (destructuring-bind (start end) visual-range
        (error 'lem-vi-mode/core:text-object-abort
               :range (lem-vi-mode/core:make-range start end)))
      (error 'lem-vi-mode/core:text-object-abort)))

(defun org-vi-set-visual-shape (kind)
  "Make the active Visual selection match boundary KIND.
Guard the Vi shape commands because invoking an already-active shape toggles
Visual state off."
  (when (lem-vi-mode/visual:visual-p)
    (ecase kind
      (:character
       (unless (lem-vi-mode/visual:visual-char-p)
         (call-command 'lem-vi-mode/visual:vi-visual-char nil)))
      (:line
       (unless (lem-vi-mode/visual:visual-line-p)
         (call-command 'lem-vi-mode/visual:vi-visual-line nil))))))

(defun org-vi-operator-line-end (start exclusive-end)
  "Return a point on the last line of START..EXCLUSIVE-END.
Lem expands a :LINE motion endpoint to the following line for an operator, so
an already-exclusive endpoint would otherwise make the operator consume one
line too many."
  (let ((end (copy-point exclusive-end :temporary)))
    (when (point< start end)
      (character-offset end -1))
    end))

(defun org-vi-text-object-range (class inner-p expected-kind count)
  "Adapt an Org boundary to Lem's operator and Visual range conventions."
  (let* ((visual-range (org-vi-existing-visual-range))
         (normalized-range (org-vi-normalized-visual-range visual-range))
         (selection-start (first normalized-range))
         (selection-end (second normalized-range)))
    (multiple-value-bind (start exclusive-end kind)
        (org-text-object-boundary
         class inner-p
         :origin (current-point)
         :count (or count 1)
         :selection-start selection-start
         :selection-end selection-end)
      (unless (and start exclusive-end
                   (eq kind expected-kind)
                   (point< start exclusive-end))
        (org-vi-abort-text-object visual-range))
      ;; Do this only after a complete boundary has been validated: an
      ;; unsupported text object must leave both text and Visual shape alone.
      (org-vi-set-visual-shape kind)
      (let ((end (if (and (eq kind :line)
                          (not (lem-vi-mode/visual:visual-p)))
                     (org-vi-operator-line-end start exclusive-end)
                     exclusive-end)))
        (lem-vi-mode/core:make-range
         start end (if (eq kind :line) :line :exclusive))))))

;;; --- Evil-Org text-object commands ---------------------------------------

(lem-vi-mode:define-text-object-command lem-yath-org-a-object (count) ("p") ()
  "Select the surrounding Org object, including its delimiters."
  (org-vi-text-object-range :object nil :character count))

(lem-vi-mode:define-text-object-command lem-yath-org-inner-object (count) ("p") ()
  "Select the contents of the surrounding Org object."
  (org-vi-text-object-range :object t :character count))

(lem-vi-mode:define-text-object-command lem-yath-org-a-element (count) ("p") ()
  "Select the surrounding Org element."
  (org-vi-text-object-range :element nil :character count))

(lem-vi-mode:define-text-object-command lem-yath-org-inner-element (count) ("p") ()
  "Select the contents of the surrounding Org element."
  (org-vi-text-object-range :element t :character count))

(lem-vi-mode:define-text-object-command
    lem-yath-org-a-greater-element (count) ("p") ()
  "Select the surrounding Org greater element as whole lines."
  (org-vi-text-object-range :greater-element nil :line count))

(lem-vi-mode:define-text-object-command
    lem-yath-org-inner-greater-element (count) ("p") ()
  "Select the contents of the surrounding Org greater element."
  (org-vi-text-object-range :greater-element t :character count))

(lem-vi-mode:define-text-object-command lem-yath-org-a-subtree (count) ("p") ()
  "Select an Org heading and its subtree as whole lines."
  (org-vi-text-object-range :subtree nil :line count))

(lem-vi-mode:define-text-object-command lem-yath-org-inner-subtree (count) ("p") ()
  "Select an Org subtree body while retaining its heading."
  (org-vi-text-object-range :subtree t :line count))

;;; --- Org-local Vi text-object maps ---------------------------------------

(defvar *org-vi-operator-keymap*
  (make-keymap :description '*org-vi-operator-keymap*))
(defvar *org-vi-outer-text-objects-keymap*
  (make-keymap :description '*org-vi-outer-text-objects-keymap*))
(defvar *org-vi-inner-text-objects-keymap*
  (make-keymap :description '*org-vi-inner-text-objects-keymap*))

(defun configure-org-vi-text-object-maps ()
  "Install Org text objects without replacing stock Vi text objects."
  ;; Child lookup keeps aw/iw and the other global text objects available.
  ;; KEYMAP-ADD-CHILD and DEFINE-KEY are identity/overwrite idempotent, so a
  ;; configuration reload neither duplicates maps nor loses fallbacks.
  (keymap-add-child *org-vi-outer-text-objects-keymap*
                    lem-vi-mode:*outer-text-objects-keymap*)
  (keymap-add-child *org-vi-inner-text-objects-keymap*
                    lem-vi-mode:*inner-text-objects-keymap*)

  (define-key *org-vi-outer-text-objects-keymap* "e"
    'lem-yath-org-a-object)
  (define-key *org-vi-inner-text-objects-keymap* "e"
    'lem-yath-org-inner-object)
  (define-key *org-vi-outer-text-objects-keymap* "E"
    'lem-yath-org-a-element)
  (define-key *org-vi-inner-text-objects-keymap* "E"
    'lem-yath-org-inner-element)
  (define-key *org-vi-outer-text-objects-keymap* "r"
    'lem-yath-org-a-greater-element)
  (define-key *org-vi-inner-text-objects-keymap* "r"
    'lem-yath-org-inner-greater-element)
  (define-key *org-vi-outer-text-objects-keymap* "R"
    'lem-yath-org-a-subtree)
  (define-key *org-vi-inner-text-objects-keymap* "R"
    'lem-yath-org-inner-subtree)

  ;; Normal a/i must remain append/insert.  These prefixes exist only in the
  ;; Org operator and Visual maps.
  (define-key *org-vi-operator-keymap* "a"
    *org-vi-outer-text-objects-keymap*)
  (define-key *org-vi-operator-keymap* "i"
    *org-vi-inner-text-objects-keymap*)
  ;; Operator-pending receives only genuine motions from the Org normal map.
  ;; Point-mutating normal commands such as o/O, Tab, and Meta structure edits
  ;; must never be executed by Lem's motion reader.
  ;; A repeated range operator must resolve to itself so >> and << can use
  ;; Lem's native doubled-operator line selection.
  (define-key *org-vi-operator-keymap* "<" 'lem-yath-org-shift-left)
  (define-key *org-vi-operator-keymap* ">" 'lem-yath-org-shift-right)
  (define-key *org-vi-operator-keymap* "j" 'lem-yath-org-next-visible-line)
  (define-key *org-vi-operator-keymap* "k" 'lem-yath-org-previous-visible-line)
  (define-key *org-vi-operator-keymap* "g h" 'lem-yath-org-up-element)
  (define-key *org-vi-operator-keymap* "g l" 'lem-yath-org-down-element)
  (define-key *org-vi-operator-keymap* "g k" 'lem-yath-org-backward-element)
  (define-key *org-vi-operator-keymap* "g j" 'lem-yath-org-forward-element)
  (define-key *org-vi-operator-keymap* "g H" 'lem-yath-org-top)
  (define-key *org-vi-visual-keymap* "a"
    *org-vi-outer-text-objects-keymap*)
  (define-key *org-vi-visual-keymap* "i"
    *org-vi-inner-text-objects-keymap*))

(configure-org-vi-text-object-maps)

;; Keep only Org motions in operator-pending state while leaving unbound keys
;; to the stock state maps.  This preserves ordinary operators, surround, and
;; operator-pending Snipe without exposing Org's normal-state mutators.
(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode org-mode))
  (declare (ignore mode))
  (let ((state (lem-vi-mode/core:current-state)))
    (cond
      ((typep state 'lem-vi-mode/states:operator)
       (list *org-vi-operator-keymap*))
      ((typep state 'lem-vi-mode/visual:visual)
       (list *org-vi-visual-keymap*))
      ((typep state 'lem-vi-mode/states:insert)
       (list *org-vi-insert-keymap*))
      (t (list *org-vi-normal-keymap*)))))
