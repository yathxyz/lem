(defpackage :lem/completion-mode
  (:use :cl :lem)
  (:export :make-completion-spec
           :make-completion-item
           :completion-item
           :completion-item-label
           :completion-item-filter-text
           :completion-item-insert-text
           :completion-item-final-insert-action
           :completion-item-detail
           :completion-item-group
           :completion-item-accept-action
           :completion-context-input-valid-p
           :completion-context-options-function
           :completion-context-observer-function
           :completion-snippet-preparation-function
           :completion-local-filtering-p
           :completion-start-local-filtering
           :run-completion
           :completion-end
           :completion-mode
           :completion-clear-focus
           :completion-refresh
           :completion-repaint)
  #+sbcl
  (:lock t))
(in-package :lem/completion-mode)

(defparameter *limit-number-of-items* 100)

(defvar *completion-context* nil)
(defvar *completion-reverse* nil)

(define-editor-variable completion-context-options-function nil
  "Function returning completion context options for the current buffer.

The function receives the completion spec and returns a property list.  The
supported keys are :FILTER-FUNCTION, :TEST-FUNCTION, :SEPARATOR, :NARROWING,
and :OBSERVER-FUNCTION.  A filter function receives the current completion
input and the provider's raw items, and must return the original items it wants
displayed.  A test function receives the complete provider input and raw items,
and reports whether that input is already a valid completion.
When :NARROWING is false, displaying synchronous candidates neither inserts
their common prefix nor accepts a singleton automatically.")

(define-editor-variable completion-snippet-preparation-function nil
  "Function used by completion providers to prepare a snippet session.

The function receives snippet text, its display label, and the target buffer.
It returns an installer which receives the accepted completion range's start
and end points, or NIL when preparation fails.  Preparing must not mutate the
buffer; the installer returns true only when it installs the rendered snippet
without exposing snippet syntax as ordinary buffer text.")

(define-editor-variable completion-context-observer-function nil
  "Function notified about completion context presentation and teardown.

The function receives CONTEXT, an event keyword, and an optional completion
item.  :PRESENT follows each rendered generation; :FOCUS follows its item action
only while that presentation remains current.  :END is sent before the old popup
and tracked range are destroyed.  Options may override via :OBSERVER-FUNCTION.")

(defclass completion-context ()
  ((spec
    :initarg :spec
    :reader context-spec
    :type completion-spec)
   (buffer
    :initarg :buffer
    :initform (current-buffer)
    :reader context-buffer)
   (generation
    :initform 0
    :accessor context-generation)
   (presented-generation
    :initform 0
    :accessor context-presented-generation)
   (automatic
    :initarg :automatic
    :initform nil
    :reader context-automatic-p)
   (narrowing
    :initarg :narrowing
    :initform t
    :reader context-narrowing-p)
   (style
    :initarg :style
    :initform nil
    :reader context-style)
   (filter-function
    :initarg :filter-function
    :initform nil
    :reader context-filter-function)
   (test-function
    :initarg :test-function
    :initform nil
    :reader context-test-function)
   (separator
    :initarg :separator
    :initform nil
    :reader context-separator)
   (observer-function
    :initarg :observer-function
    :initform nil
    :reader context-observer-function)
   (focus-message-window
    :initform nil
    :accessor context-focus-message-window)
   (focus-message-frame
    :initform nil
    :accessor context-focus-message-frame)
   (focus-serial
    :initform 0
    :accessor context-focus-serial)
   (local-filtering
    :initform nil
    :accessor context-local-filtering-p)
   (request-pending
    :initform nil
    :accessor context-request-pending-p)
   (raw-items
    :initform nil
    :accessor context-raw-items)
   (range-start
    :initform nil
    :accessor context-range-start)
   (range-end
    :initform nil
    :accessor context-range-end)
   (range-offsets
    :initform (make-hash-table :test #'eq)
    :reader context-range-offsets)
   (max-display-items
    :initarg :max-display-items
    :initform nil
    :reader context-max-display-items)
   (cycle
    :initarg :cycle
    :initform t
    :reader context-cycle-p)
   (spinner
    :initform nil
    :accessor context-spinner)
   (last-items
    :initform '()
    :accessor context-last-items)
   (popup-menu
    :initform nil
    :accessor context-popup-menu)))

(defclass completion-spec ()
  ((function
    :initarg :function
    :reader spec-function)
   (async
    :initarg :async
    :initform nil
    :reader spec-async-p)
   (filter-function
    :initarg :filter-function
    :initform nil
    :reader spec-filter-function)
   (test-function
    :initarg :test-function
    :initform nil
    :reader spec-test-function)))

(defun make-completion-spec (function &key async filter-function test-function)
  (make-instance 'completion-spec
                 :function function
                 :async async
                 :filter-function filter-function
                 :test-function test-function))

(defun ensure-completion-spec (completion-spec)
  (typecase completion-spec
    (completion-spec
     completion-spec)
    (otherwise
     (make-completion-spec (alexandria:ensure-function completion-spec)))))

(defun call-sync-function (completion-spec point)
  (assert (not (spec-async-p completion-spec)))
  (funcall (spec-function completion-spec) point))

(defun call-async-function (completion-spec point then)
  (assert (spec-async-p completion-spec))
  (funcall (spec-function completion-spec) point then))

(defclass completion-item ()
  ((label
    :initarg :label
    :initform ""
    :reader completion-item-label
    :type string)
   (filter-text
    :initarg :filter-text
    :initform nil
    :reader %completion-item-filter-text
    :type (or null string))
   (insert-text
    :initarg :insert-text
    :initform nil
    :reader %completion-item-insert-text
    :type (or null string))
   (chunks
    :initarg :chunks
    :initform nil
    :reader completion-item-chunks
    :type list)
   (detail
    :initarg :detail
    :initform ""
    :accessor completion-item-detail
    :type string)
   (group
    :initarg :group
    :initform nil
    :reader completion-item-group
    :type (or null string))
   (start
    :initarg :start
    :initform nil
    :reader completion-item-start
    :type (or null point))
   (end
    :initarg :end
    :initform nil
    :reader completion-item-end
    :type (or null point))
   (focus-action
    :initarg :focus-action
    :initform nil
    :reader completion-item-focus-action
    :type (or null function))
   (final-insert-action
    :initarg :final-insert-action
    :initform nil
    :reader completion-item-final-insert-action
    :type (or null function))
   (accept-action
    :initarg :accept-action
    :initform nil
    :reader completion-item-accept-action
    :type (or null function))))

(defun completion-item-filter-text (item)
  "Return ITEM's filtering text, falling back to its display label."
  (or (%completion-item-filter-text item)
      (completion-item-label item)))

(defun completion-item-insert-text (item)
  "Return ITEM's insertion text, falling back to its display label."
  (or (%completion-item-insert-text item)
      (completion-item-label item)))

(defmethod print-object ((obj completion-item) stream)
  (print-unreadable-object (obj stream :type t)
    (format stream "label: ~a" (completion-item-label obj))))

(defun make-completion-item (&rest initargs
                             &key label filter-text insert-text chunks detail group
                               start end focus-action final-insert-action
                               accept-action)
  (declare (ignore label filter-text insert-text chunks detail group
                   start end focus-action final-insert-action accept-action))
  (apply #'make-instance 'completion-item initargs))

(defvar *completion-mode-keymap* (make-keymap :description '*completion-mode-keymap*
                                              :undef-hook 'completion-self-insert))
(define-minor-mode completion-mode
    (:name "completion"
     :keymap *completion-mode-keymap*))

(define-key *completion-mode-keymap* 'next-line 'completion-next-line)
(define-key *completion-mode-keymap* "M-n"    'completion-next-line)
(define-key *completion-mode-keymap* "Tab"    'completion-narrowing-down-or-next-line)
(define-key *completion-mode-keymap* "Shift-Tab"    'completion-previous-line)
(define-key *completion-mode-keymap* 'previous-line 'completion-previous-line)
(define-key *completion-mode-keymap* "M-p"    'completion-previous-line)
(define-key *completion-mode-keymap* 'move-to-end-of-buffer 'completion-end-of-buffer)
(define-key *completion-mode-keymap* 'move-to-beginning-of-buffer 'completion-beginning-of-buffer)
(define-key *completion-mode-keymap* "Return"    'completion-select)
(define-key *completion-mode-keymap* "Space"    'completion-insert-space-and-cancel)
(define-key *completion-mode-keymap* 'delete-previous-char 'completion-delete-previous-char)
(define-key *completion-mode-keymap* 'backward-delete-word 'completion-backward-delete-word)
(define-key *completion-mode-keymap* "Up" 'completion-previous-line)
(define-key *completion-mode-keymap* "Down" 'completion-next-line)

(define-attribute detail-attribute
  (t :foreground :base03))

(define-attribute chunk-attribute
  (t :foreground :base0D))

(defclass print-spec ()
  ((label-width
    :initarg :label-width
    :reader label-width)))

(defparameter *completion-label-width-minimum* 20)
(defparameter *completion-label-width-step* 10)

(defun compute-label-width (items)
  "Return Marginalia's left-alignment column for ITEMS.
The leading popup cell is part of the candidate width.  Measure terminal
cells rather than Lisp characters so wide labels cannot shift annotations."
  (let ((width
          (loop :for item :in items
                :maximize
                (1+ (lem/common/character:string-width
                     (completion-item-label item))))))
    (max *completion-label-width-minimum*
         (* (ceiling width *completion-label-width-step*)
            *completion-label-width-step*))))

(defun make-print-spec (items)
  (make-instance 'print-spec
                 :label-width
                 (compute-label-width items)))

(defmethod lem/popup-menu:item-group
    ((print-spec print-spec) (item completion-item))
  (completion-item-group item))

(defmethod lem/popup-menu:apply-print-spec ((print-spec print-spec) point item)
  (with-point ((start point))
    (insert-string point " ")
    (insert-string point (completion-item-label item))
    (loop :for (offset-start . offset-end) :in (completion-item-chunks item)
          :do (with-point ((start point) (end point))
                (character-offset (line-start start) (1+ offset-start))
                (character-offset (line-start end) (1+ offset-end))
                (put-text-property start end :attribute 'chunk-attribute)))
    (move-to-column point (label-width print-spec) t)
    (line-end point)
    (insert-string point "  ")
    (unless (alexandria:emptyp (completion-item-detail item))
      (insert-string point (completion-item-detail item)
                     :attribute 'detail-attribute)
      (insert-string point " "))
    (put-text-property start
                       point
                       :click-callback (lambda (window dest-point)
                                         (declare (ignore window dest-point))
                                         (completion-select)))
    (let ((context *completion-context*)
          (generation
            (context-presented-generation *completion-context*)))
      (put-text-property start
                         point
                         :hover-callback
                         (lambda (window dest-point)
                           (when (eq context *completion-context*)
                             (let ((popup (context-popup-menu context)))
                               (when (and
                                      popup
                                      (eq window
                                          (lem/popup-menu::popup-menu-window
                                           popup))
                                      (context-presentation-current-p
                                       context generation popup))
                                 (clear-context-focus-message context)
                                 (when (and
                                        (eq window
                                            (lem/popup-menu::popup-menu-window
                                             popup))
                                        (context-presentation-current-p
                                         context generation popup))
                                   (lem/popup-menu::move-focus
                                    popup
                                    (lambda (point)
                                      (move-point point dest-point)))
                                   (when (and
                                          (eq window
                                              (lem/popup-menu::popup-menu-window
                                               popup))
                                          (context-presentation-current-p
                                           context generation popup))
                                     (call-focus-action)))))))))))

(defun stop-context-spinner (context)
  (alexandria:when-let ((spinner (context-spinner context)))
    (lem/loading-spinner:stop-loading-spinner spinner)
    (setf (context-spinner context) nil)))

(defun close-context-popup (context)
  (alexandria:when-let ((popup (context-popup-menu context)))
    (popup-menu-quit popup)
    (setf (context-popup-menu context) nil)))

(defun delete-context-range (context)
  (dolist (point (list (context-range-start context)
                       (context-range-end context)))
    (when point
      (ignore-errors (delete-point point))))
  (setf (context-range-start context) nil
        (context-range-end context) nil)
  (clrhash (context-range-offsets context)))

(defun clear-context-focus-message (context)
  "Delete only the message window returned by CONTEXT's last focus action."
  (let ((window (context-focus-message-window context))
        (frame (context-focus-message-frame context)))
    (setf (context-focus-message-window context) nil
          (context-focus-message-frame context) nil)
    (when (and window frame
               (eq window (frame-message-window frame)))
      (unless (deleted-window-p window)
        (delete-window window))
      (setf (frame-message-window frame) nil))))

(defun completion-clear-focus ()
  "Deactivate the current completion row and its owned documentation."
  (alexandria:when-let* ((context *completion-context*)
                         (popup (context-popup-menu context)))
    (clear-context-focus-message context)
    (lem/popup-menu:popup-menu-clear-focus popup)))

(defun context-presentation-current-p (context generation popup)
  (and (eq context *completion-context*)
       (= generation (context-generation context))
       (= generation (context-presented-generation context))
       (eq popup (context-popup-menu context))))

(defun notify-context-presentation (context item)
  (alexandria:when-let ((observer (context-observer-function context)))
    (funcall observer context :present item)))

(defun notify-context-focus (context item)
  (alexandria:when-let ((observer (context-observer-function context)))
    (funcall observer context :focus item)))

(defun completion-end ()
  (when *completion-context*
    (let* ((context *completion-context*)
           (buffer (context-buffer context)))
      (incf (context-generation context))
      (setf (context-request-pending-p context) nil)
      (setf *completion-context* nil)
      (stop-context-spinner context)
      (when (or (buffer-temporary-p buffer)
                (member buffer (buffer-list)))
        (with-current-buffer buffer
          (completion-mode nil)))
      (unwind-protect
           (progn
             (handler-case (clear-context-focus-message context)
               (error (condition)
                 (message "Could not clear completion documentation: ~A"
                          condition)))
             (alexandria:when-let ((observer
                                    (context-observer-function context)))
               (funcall observer context :end nil)))
        (close-context-popup context)
        (delete-context-range context)))))

(defun call-focus-action ()
  (alexandria:when-let ((context *completion-context*))
    (let ((generation (context-generation context))
          (frame (current-frame)))
      (alexandria:when-let* ((popup (context-popup-menu context))
                             (item
                               (and
                                (context-presentation-current-p
                                 context generation popup)
                                (lem/popup-menu:get-focus-item popup))))
        (let ((serial (incf (context-focus-serial context))))
          (alexandria:when-let ((fn (completion-item-focus-action item)))
            (let ((result (funcall fn context)))
              (when (and result (eq result (frame-message-window frame)))
                (if (and (= serial (context-focus-serial context))
                         (context-presentation-current-p
                          context generation popup))
                    (setf (context-focus-message-window context) result
                          (context-focus-message-frame context) frame)
                    (progn
                      (unless (deleted-window-p result)
                        (delete-window result))
                      (when (eq result (frame-message-window frame))
                        (setf (frame-message-window frame) nil)))))))
          (when (and (= serial (context-focus-serial context))
                     (context-presentation-current-p
                      context generation popup)
                     (eq item (lem/popup-menu:get-focus-item popup)))
            (notify-context-focus context item)))))))

(defun notify-context-presentation-and-focus (context)
  "Notify presentation, then focus only if its exact row is still current."
  (when (eq context *completion-context*)
    (let* ((generation (context-generation context))
           (popup (context-popup-menu context))
           (serial (context-focus-serial context))
           (item (and popup (lem/popup-menu:get-focus-item popup))))
      (notify-context-presentation context item)
      (when (and popup
                 (= serial (context-focus-serial context))
                 (context-presentation-current-p context generation popup)
                 (eq item (lem/popup-menu:get-focus-item popup)))
        (call-focus-action)))))

(define-command completion-self-insert () ()
  (let ((c (insertion-key-p (last-read-key-sequence))))
    (cond (c (insert-character (current-point) c)
             (completion-refresh))
          (t (unread-key-sequence (last-read-key-sequence))
             (completion-end)))))

(defun completion-refresh ()
  "This will refresh the contents of the completion window using any changes made in the interim"
  (alexandria:when-let ((context *completion-context*))
    (if (context-local-filtering-p context)
        (if (completion-context-separator-present-p context)
            (completion-refilter context)
            (progn
              (setf (context-local-filtering-p context) nil)
              (continue-completion context)))
        (continue-completion context))))

(defun completion-repaint ()
  "Recompute an active completion presentation without moving its focus row.

Unlike `completion-refresh', this is for display-only changes such as a
terminal resize.  It deliberately reruns the provider so width-dependent
annotations can be rendered again while the prompt input remains unchanged."
  (alexandria:when-let ((context *completion-context*))
    (if (context-local-filtering-p context)
        (completion-refilter context :keep-focus t)
        (continue-completion context :keep-focus t))))

(define-command completion-delete-previous-char (n) (:universal)
  (delete-previous-char n)
  (completion-refresh))

(define-command completion-backward-delete-word (n) (:universal)
  (backward-delete-word n)
  (completion-refresh))

(defun popup-focus-at-last-item-p (popup)
  (with-point ((focus (lem/popup-menu::focus-point popup))
               (end (buffer-end-point
                     (lem/popup-menu::popup-menu-buffer popup))))
    (same-line-p focus end)))

(defun popup-focus-at-first-item-p (popup)
  (with-point ((focus (lem/popup-menu::focus-point popup))
               (first (buffer-start-point
                       (lem/popup-menu::popup-menu-buffer popup))))
    (lem/popup-menu::seek-selectable-point first 1)
    (same-line-p focus first)))

(define-command completion-next-line () ()
  "Move selection to next line in completion window"
  (alexandria:when-let ((popup (context-popup-menu *completion-context*)))
    (when (or (not (lem/popup-menu:popup-menu-focus-active-p popup))
              (context-cycle-p *completion-context*)
              (not (popup-focus-at-last-item-p popup)))
      (clear-context-focus-message *completion-context*)
      (popup-menu-down popup)
      (call-focus-action))))

(define-command completion-previous-line () ()
  "Move selection to previous line in completion window"
  (alexandria:when-let ((popup (context-popup-menu *completion-context*)))
    (when (or (context-cycle-p *completion-context*)
              (not (popup-focus-at-first-item-p popup)))
      (clear-context-focus-message *completion-context*)
      (popup-menu-up popup)
      (call-focus-action))))

(define-command completion-end-of-buffer () ()
  (alexandria:when-let ((popup (context-popup-menu *completion-context*)))
    (clear-context-focus-message *completion-context*)
    (popup-menu-last popup)
    (call-focus-action)))

(define-command completion-beginning-of-buffer () ()
  (alexandria:when-let ((popup (context-popup-menu *completion-context*)))
    (clear-context-focus-message *completion-context*)
    (popup-menu-first popup)
    (call-focus-action)))

(define-command completion-select () ()
  (alexandria:if-let ((popup (context-popup-menu *completion-context*)))
    (popup-menu-select popup)
    (progn
      (unread-key-sequence (last-read-key-sequence))
      (completion-end))))

(define-command completion-insert-space-and-cancel () ()
  (insert-character (current-point) #\space)
  (completion-end))

(defun completion-item-provider-range (point item)
  (let ((start (or (completion-item-start item)
                   (with-point ((start point))
                     (skip-chars-backward start #'syntax-symbol-char-p)
                     start)))
        (end (or (completion-item-end item)
                 point)))
    (values start end)))

(defun completion-item-range (point item)
  (let ((context *completion-context*))
    (if (and context
             (context-range-start context)
             (context-range-end context))
        (destructuring-bind (start-offset . end-offset)
            (gethash item (context-range-offsets context) '(0 . 0))
          (let ((start (copy-point (context-range-start context) :temporary))
                (end (copy-point (context-range-end context) :temporary)))
            (character-offset start start-offset)
            (character-offset end end-offset)
            (values start (if (point> point end) point end))))
        (completion-item-provider-range point item))))

(defun completion-insert (point item &optional begin)
  (when item
    (multiple-value-bind (start end) (completion-item-range point item)
      (delete-between-points start end)
      (insert-string point (subseq (completion-item-insert-text item) 0 begin)))))

(defun completion-accept (point item)
  "Insert ITEM finally, then run its post-accept action exactly once."
  (cond
    ((null item)
     nil)
    ((and *completion-context*
          (or (not (eq (context-buffer *completion-context*)
                       (point-buffer point)))
              (deleted-buffer-p (context-buffer *completion-context*))))
     (completion-end)
     nil)
    (t
     (let ((final-action (completion-item-final-insert-action item))
           (accept-action (completion-item-accept-action item)))
       (if final-action
           (multiple-value-bind (range-start range-end)
               (completion-item-range point item)
             (with-point ((start range-start :right-inserting)
                          (end range-end :left-inserting))
               (completion-end)
               (when (funcall final-action point start end)
                 (when accept-action
                   (funcall accept-action)))))
           (progn
             (completion-insert point item)
             (completion-end)
             (when accept-action
               (funcall accept-action))))))))

(defun partial-match (strings)
  (when strings
    (let ((n nil))
      (loop :for rest :on strings
            :do (loop :for rest2 :on (cdr rest)
                      :for mismatch := (mismatch (first rest) (first rest2))
                      :do (and mismatch
                               (setf n
                                     (if n
                                         (min n mismatch)
                                         mismatch)))))
      n)))

(defun narrowing-down (context last-items)
  (when last-items
    (cond
      ((and (alexandria:length= last-items 1)
            (completion-item-final-insert-action (first last-items)))
       (completion-accept (current-point) (first last-items))
       t)
      ((some #'completion-item-final-insert-action last-items)
       nil)
      (t
       (let ((n (partial-match
                 (mapcar #'completion-item-insert-text last-items))))
         (multiple-value-bind (start end)
             (completion-item-range (current-point) (first last-items))
           (cond ((and n (plusp n) (< (count-characters start end) n))
                  (completion-insert (current-point)
                                     (first last-items)
                                     n)
                  (completion-refresh)
                  t)
                 ((alexandria:length= last-items 1)
                  (completion-insert (current-point)
                                     (first last-items))
                  (completion-refresh)
                  t)
                 (t
                  nil))))))))

(define-command completion-narrowing-down-or-next-line () ()
  (or (narrowing-down *completion-context* (context-last-items *completion-context*))
      (if *completion-reverse*
          (completion-previous-line)
          (completion-next-line))))

(defun limitation-items (items)
  (let ((result (if (and *limit-number-of-items*
                         (< *limit-number-of-items* (length items)))
                    (subseq items 0 *limit-number-of-items*)
                    items)))
    (if *completion-reverse*
        (reverse result)
        result)))

(defun compute-completion-items (context then)
  (let ((generation (incf (context-generation context))))
    (setf (context-last-items context) nil)
    (if (context-local-filtering-p context)
        (funcall then (context-raw-items context) generation nil)
        (let ((spec (context-spec context)))
          (setf (context-request-pending-p context) t)
          (flet ((return-items (items)
                   (funcall then items generation t)))
            (if (spec-async-p spec)
                (call-async-function spec (current-point) #'return-items)
                (return-items (call-sync-function spec (current-point)))))))))

(defun update-context-range (context items)
  (when items
    (multiple-value-bind (start end)
        (completion-item-provider-range (current-point) (first items))
      (delete-context-range context)
      (setf (context-range-start context)
            (copy-point start :right-inserting)
            (context-range-end context)
            (copy-point end :left-inserting))
      (let ((base-start-position (position-at-point start))
            (base-end-position (position-at-point end)))
        (dolist (item items)
          (multiple-value-bind (item-start item-end)
              (completion-item-provider-range (current-point) item)
            (when (and (eq (point-buffer item-start) (point-buffer start))
                       (eq (point-buffer item-end) (point-buffer end)))
              (setf (gethash item (context-range-offsets context))
                    (cons (- (position-at-point item-start)
                             base-start-position)
                          (- (position-at-point item-end)
                             base-end-position))))))))))

(defun completion-context-input (context)
  (alexandria:when-let ((start (context-range-start context)))
    (when (and (eq (point-buffer start) (current-buffer))
               (point<= start (current-point)))
      (points-to-string start (current-point)))))

(defun completion-context-input-valid-p (context &optional input)
  "Ask CONTEXT's provider whether INPUT is already a valid completion.

The provider sees its unfiltered items.  Missing predicates and predicate errors
fail closed so presentation code never mistakes a display-string heuristic for
provider truth."
  (alexandria:when-let ((test-function (context-test-function context)))
    (handler-case
        (not (null (funcall test-function
                            (or input (completion-context-input context) "")
                            (context-raw-items context))))
      (error () nil))))

(defun completion-context-separator-present-p (context)
  (alexandria:when-let* ((separator (context-separator context))
                         (input (completion-context-input context)))
    (find separator input :test #'char=)))

(defun filter-context-items (context items)
  (alexandria:if-let ((filter (context-filter-function context)))
    (funcall filter (or (completion-context-input context) "") items)
    items))

(defun prepare-context-items (context raw-items)
  (limitation-items (filter-context-items context raw-items)))

(defun completion-local-filtering-p ()
  (and *completion-context*
       (context-local-filtering-p *completion-context*)))

(defun completion-start-local-filtering (&optional (separator #\Space))
  "Freeze the current provider batch and filter it locally after SEPARATOR."
  (let ((context *completion-context*))
    (when (and context
               (context-filter-function context)
               (eql separator (context-separator context))
               (context-raw-items context)
               (context-range-start context))
      (incf (context-generation context))
      (setf (context-request-pending-p context) nil
            (context-local-filtering-p context) t)
      (stop-context-spinner context)
      t)))

(defun start-completion (context items generation)
  "Open popup menu for completions in the context provided"
  (when items
    (setf (context-presented-generation context) generation)
    (setf (context-popup-menu context)
          (apply
           #'display-popup-menu
           items
           :action-callback (lambda (item)
                              (cond
                                ((not (eq context *completion-context*))
                                 nil)
                                ((or
                                  (not (eq (context-buffer context)
                                           (current-buffer)))
                                  (deleted-buffer-p (context-buffer context)))
                                 (completion-end))
                                ((/= (context-presented-generation context)
                                     (context-generation context))
                                 nil)
                                (t
                                 (completion-accept (current-point) item))))
           :print-spec (make-print-spec items)
           (append (alexandria:when-let ((style (context-style context)))
                     `(:style ,style))
                   (alexandria:when-let ((max-display-items
                                          (context-max-display-items context)))
                     `(:max-display-items ,max-display-items)))))
    (completion-mode t)
    (unless (or (not (context-narrowing-p context))
                (spec-async-p (context-spec context))
                (context-automatic-p context)
                (context-local-filtering-p context))
      (narrowing-down context items))
    (when (and (eq context *completion-context*)
               *completion-reverse*)
      (popup-menu-last (context-popup-menu context)))
    (when (eq context *completion-context*)
      (notify-context-presentation-and-focus context))))

(defun present-context-items (context items generation &key keep-focus)
  (setf (context-last-items context) items)
  (cond
    ((null items)
     (if (context-local-filtering-p context)
         (progn
           (setf (context-presented-generation context) generation)
           (clear-context-focus-message context)
           (close-context-popup context)
           (completion-mode t)
           (notify-context-presentation context nil))
         (completion-end)))
    ((context-popup-menu context)
     (setf (context-presented-generation context) generation)
     (clear-context-focus-message context)
     (apply
      #'popup-menu-update
      (context-popup-menu context)
      items
      :print-spec (make-print-spec items)
      :keep-focus keep-focus
      (alexandria:when-let
          ((max-display-items (context-max-display-items context)))
        `(:max-display-items ,max-display-items)))
     (notify-context-presentation-and-focus context))
    (t
     (start-completion context items generation))))

(defun completion-refilter (context &key keep-focus)
  (let ((generation (incf (context-generation context))))
    (setf (context-request-pending-p context) nil)
    (stop-context-spinner context)
    (present-context-items
     context
     (prepare-context-items context (context-raw-items context))
     generation
     :keep-focus keep-focus)))

(defun continue-completion (context &key keep-focus)
  (let ((origin-buffer (current-buffer))
        (origin-tick (buffer-modified-tick (current-buffer)))
        (origin-position (position-at-point (current-point))))
    (compute-completion-items
     context
     (lambda (raw-items generation provider-result-p)
       (when (and (eq context *completion-context*)
                  (= generation (context-generation context)))
         (if (and (eq origin-buffer (current-buffer))
                  (or (not (spec-async-p (context-spec context)))
                      (and
                       (= origin-tick (buffer-modified-tick origin-buffer))
                       (= origin-position
                          (position-at-point (current-point))))))
             (progn
               (setf (context-request-pending-p context) nil)
               (when provider-result-p
                 (setf (context-raw-items context) raw-items)
                 (update-context-range context raw-items))
               (present-context-items
                context
                (prepare-context-items context raw-items)
                generation
                :keep-focus keep-focus))
             (completion-end))))))
  (when *completion-reverse*
    (ignore-errors (completion-end-of-buffer))))

(defun run-completion
    (completion-spec
     &key style then automatic max-display-items (cycle t)
       (narrowing nil narrowing-supplied-p)
       (filter-function nil filter-function-supplied-p)
       (test-function nil test-function-supplied-p)
       (separator nil separator-supplied-p)
       (observer-function nil observer-function-supplied-p))
  "Start a new completion using the completion-spec,
creates a new completion-context and sets *completion-context*"
  (when *completion-context*
    (completion-end)
    (alexandria:when-let ((replacement *completion-context*))
      (return-from run-completion replacement)))
  (let* ((spec (ensure-completion-spec completion-spec))
         (origin-buffer (current-buffer))
         (options-function
           (variable-value 'completion-context-options-function
                           :default origin-buffer))
         (options
           (when options-function
             (funcall (alexandria:ensure-function options-function) spec)))
         (filter-function
           (cond
             (filter-function-supplied-p filter-function)
             ((getf options :filter-function))
             (t (spec-filter-function spec))))
         (test-function
           (cond
             (test-function-supplied-p test-function)
             ((getf options :test-function))
             (t (spec-test-function spec))))
         (separator
           (if separator-supplied-p
               separator
               (getf options :separator)))
         (observer-function
           (cond
             (observer-function-supplied-p observer-function)
             ((getf options :observer-function))
             (t
              (variable-value 'completion-context-observer-function
                              :default origin-buffer))))
         (narrowing-option (getf options :narrowing :unspecified))
         (narrowing
           (cond
             (narrowing-supplied-p narrowing)
             ((eq narrowing-option :unspecified) t)
             (t narrowing-option)))
         (context (make-instance 'completion-context
                                 :spec spec
                                 :buffer origin-buffer
                                 :automatic automatic
                                 :narrowing narrowing
                                 :style style
                                 :filter-function filter-function
                                 :test-function test-function
                                 :separator separator
                                 :observer-function observer-function
                                 :max-display-items max-display-items
                                 :cycle cycle))
         (origin-tick (buffer-modified-tick origin-buffer)))
    (setf *completion-context* context)
    (handler-case
        (with-point ((before-point (current-point)))
          (if (spec-async-p (context-spec context))
              (progn
                (setf (context-spinner context)
                      (lem/loading-spinner:start-loading-spinner
                       :line :point before-point))
            (compute-completion-items
             context
             (lambda (raw-items generation provider-result-p)
               (declare (ignore provider-result-p))
               (stop-context-spinner context)
               (when (and (eq context *completion-context*)
                          (= generation (context-generation context)))
                 (if (and (eq origin-buffer (current-buffer))
                          (= origin-tick (buffer-modified-tick origin-buffer))
                          (point= before-point (current-point)))
                     (progn
                       (setf (context-request-pending-p context) nil
                             (context-raw-items context) raw-items)
                       (update-context-range context raw-items)
                       (let ((items (prepare-context-items context raw-items)))
                         (setf (context-last-items context) items)
                         (if items
                           (progn
                             (start-completion context items generation)
                             (when then
                               (funcall then)))
                             (completion-end))))
                     (completion-end))))))
              (compute-completion-items
               context
               (lambda (raw-items generation provider-result-p)
                 (declare (ignore provider-result-p))
                 (when (and (eq context *completion-context*)
                            (= generation (context-generation context)))
                   (setf (context-request-pending-p context) nil
                         (context-raw-items context) raw-items)
                   (update-context-range context raw-items)
                   (let ((items (prepare-context-items context raw-items)))
                     (setf (context-last-items context) items)
                     (cond
                       ((null items)
                        (completion-end))
                       ((and (context-narrowing-p context)
                             (alexandria:length= items 1)
                             (not automatic))
                        (completion-accept (current-point) (first items)))
                       (t
                        (start-completion context items generation)
                        (when then
                          (funcall then))))))))))
      (error (condition)
        (when (eq context *completion-context*)
          (completion-end))
        (error condition)))
    context))
