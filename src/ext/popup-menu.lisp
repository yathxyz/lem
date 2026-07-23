(defpackage :lem/popup-menu
  (:use :cl :lem)
  (:export :write-header
           :get-focus-item
           :apply-print-spec
           :item-group
           :popup-menu-focus-active-p
           :popup-menu-clear-focus
           :popup-menu-activate-focus)
  #+sbcl
  (:lock t))
(in-package :lem/popup-menu)

(defclass popup-menu ()
  ((buffer
    :initarg :buffer
    :accessor popup-menu-buffer)
   (window
    :initarg :window
    :accessor popup-menu-window)
   (focus-overlay
    :initarg :focus-overlay
    :accessor popup-menu-focus-overlay)
   (action-callback
    :initarg :action-callback
    :accessor popup-menu-action-callback)
   (focus-attribute
    :initarg :focus-attribute
    :accessor popup-menu-focus-attribute)
   (focus-active
    :initform t
    :accessor popup-menu-focus-active-p)))

(define-attribute popup-menu-attribute
  (t :foreground "white" :background "RoyalBlue"))
(define-attribute non-focus-popup-menu-attribute)

(define-attribute popup-menu-group-attribute
  (t :foreground :base0D :bold t))

(defun focus-point (popup-menu)
  (buffer-point (popup-menu-buffer popup-menu)))

(defun make-focus-overlay (point focus-attribute)
  (make-line-overlay point focus-attribute))

(defun selectable-point-p (point)
  "Return true when POINT is on a row backed by a popup item."
  (not (null (text-property-at (line-start point) :item))))

(defun update-focus-overlay (popup-menu point)
  "Refresh the focus highlight so it tracks POINT in POPUP-MENU.
Deletes any previous overlay, clears stray overlays, and creates a new
focus overlay unless POINT is on the header line."
  (alexandria:when-let ((focus-overlay (popup-menu-focus-overlay popup-menu)))
    (delete-overlay focus-overlay))
  (clear-overlays (popup-menu-buffer popup-menu))
  (setf (popup-menu-focus-overlay popup-menu) nil)
  (when (and (popup-menu-focus-active-p popup-menu)
             (selectable-point-p point))
    (setf (popup-menu-focus-overlay popup-menu)
          (make-focus-overlay point (popup-menu-focus-attribute popup-menu)))))

(defun popup-menu-clear-focus (popup-menu)
  "Make POPUP-MENU's prompt row authoritative, not merely unhighlighted."
  (setf (slot-value popup-menu 'focus-active) nil)
  (update-focus-overlay popup-menu (focus-point popup-menu))
  nil)

(defun popup-menu-activate-focus (popup-menu)
  "Activate POPUP-MENU's current physical row."
  (setf (slot-value popup-menu 'focus-active) t)
  (update-focus-overlay popup-menu (focus-point popup-menu))
  t)

(defgeneric write-header (print-spec point)
  (:method (print-spec point)))

(defgeneric item-group (print-spec item)
  (:documentation "Return ITEM's optional non-selectable group heading.")
  (:method (print-spec item)
    (declare (ignore print-spec item))
    nil))

(defgeneric apply-print-spec (print-spec point item)
  (:documentation "Applies the function `print-spec` to an `item` at `point`.  Typically this
will get the string representation of `item` and insert it at `point` (the default method implemented below)")
  (:method ((print-spec function) point item)
    (let ((string (funcall print-spec item)))
      (insert-string point string))))

(defun insert-items (point items print-spec)
  "Insert ITEMS and return the number of candidate and group rows."
  (let ((previous-group (gensym "NO-GROUP"))
        (first-row-p t)
        (row-count 0))
    (labels ((begin-row ()
               (unless first-row-p
                 (insert-character point #\newline))
               (setf first-row-p nil)
               (incf row-count)))
      (dolist (item items)
        (let ((group (item-group print-spec item)))
          (unless (equal group previous-group)
            (setf previous-group group)
            (when group
              (begin-row)
              (insert-string point group
                             :attribute 'popup-menu-group-attribute))))
        (begin-row)
        (with-point ((start point :right-inserting))
          (apply-print-spec print-spec point item)
          (line-end point)
          (put-text-property start point :item item))))
    (buffer-start point)
    row-count))

(defun seek-selectable-point (point direction)
  "Move POINT in DIRECTION until it reaches a selectable row."
  (loop
    (when (selectable-point-p point)
      (return t))
    (unless (line-offset point direction)
      (return nil))))

(defun get-focus-item (popup-menu)
  (alexandria:when-let (p (and (popup-menu-focus-active-p popup-menu)
                               (focus-point popup-menu)))
    (text-property-at (line-start p) :item)))

(defun make-menu-buffer ()
  (make-buffer "*popup menu*" :enable-undo-p nil :temporary t))

(defun buffer-start-line (buffer)
  (buffer-value buffer 'start-line))

(defun (setf buffer-start-line) (line buffer)
  (setf (buffer-value buffer 'start-line) line))

(defun setup-menu-buffer (buffer items print-spec focus-attribute &optional last-line)
  (clear-overlays buffer)
  (erase-buffer buffer)
  (setf (variable-value 'line-wrap :buffer buffer) nil)
  (let ((point (buffer-point buffer)))
    (write-header print-spec point)
    (let* ((header-exists (< 0 (length (buffer-text buffer))))
           (start-line (if header-exists
                           (1+ (line-number-at-point point))
                           1)))
      (when (and header-exists
                 (< 0 (length items)))
        (insert-character point #\newline))
      (setf (buffer-start-line buffer) start-line)
      (let ((row-count (insert-items point items print-spec)))
        (buffer-start point)
        (when header-exists
          (move-to-line point start-line))
        (when last-line (move-to-line point last-line))
        (seek-selectable-point point 1)
        (let ((focus-overlay (make-focus-overlay point focus-attribute))
              (width (lem/popup-window::compute-buffer-width buffer)))
          (values width
                  focus-overlay
                  (+ (1- start-line) row-count)))))))

(defparameter *style* '(:use-border t :offset-y 0))

(defmethod lem-if:display-popup-menu (implementation items
                                      &key action-callback
                                           print-spec
                                           (style *style*)
                                           (max-display-items 20))
  (let ((style (lem/popup-window::ensure-style style))
        (focus-attribute (ensure-attribute 'popup-menu-attribute))
        (non-focus-attribute (ensure-attribute 'non-focus-popup-menu-attribute))
        (buffer (make-menu-buffer)))
    (multiple-value-bind (menu-width focus-overlay height)
        (setup-menu-buffer buffer
                           items
                           print-spec
                           focus-attribute)
      (let ((window (lem/popup-window::make-popup-window
                     :source-window (current-window)
                     :buffer buffer
                     :width menu-width
                     :height (min max-display-items height)
                     :style (lem/popup-window::merge-style
                             style
                             :background-color (or (lem/popup-window::style-background-color style)
                                                   (attribute-background
                                                    non-focus-attribute))
                             :cursor-invisible t))))
        (make-instance 'popup-menu
                       :buffer buffer
                       :window window
                       :focus-overlay focus-overlay
                       :action-callback action-callback
                       :focus-attribute focus-attribute)))))

(defmethod lem-if:popup-menu-update (implementation popup-menu items &key print-spec (max-display-items 20) keep-focus)
  (when popup-menu
    (unless keep-focus
      (setf (slot-value popup-menu 'focus-active) t))
    (let ((last-line (line-number-at-point (buffer-point (popup-menu-buffer popup-menu)))))
      (multiple-value-bind (menu-width focus-overlay height)
          (setup-menu-buffer (popup-menu-buffer popup-menu)
                             items
                             print-spec
                             (popup-menu-focus-attribute popup-menu)
                             (if keep-focus last-line))
        (setf (popup-menu-focus-overlay popup-menu) focus-overlay)
        (let ((source-window (current-window)))
          (when (eq source-window
                    (frame-prompt-window (current-frame)))
            ;; prompt-window内でcompletion-windowを出している場合,
            ;; completion-windowの位置を決める前にprompt-windowの調整を先にしておかないとずれるため,
            ;; ここで更新する
            (lem-core::update-floating-prompt-window (current-frame)))
          (lem/popup-window::update-popup-window :source-window source-window
                                                 :width menu-width
                                                 :height (min max-display-items height)
                                                 :destination-window (popup-menu-window popup-menu)))))
    (when (header-point-p (focus-point popup-menu))
      (move-to-line (focus-point popup-menu)
                    (buffer-start-line (popup-menu-buffer popup-menu))))
    (update-focus-overlay popup-menu (focus-point popup-menu))))

(defmethod lem-if:popup-menu-quit (implementation popup-menu)
  (delete-window (popup-menu-window popup-menu))
  (delete-buffer (popup-menu-buffer popup-menu)))

(defun header-point-p (point)
  (not (selectable-point-p point)))

(defun move-focus (popup-menu function &optional direction)
  (alexandria:when-let (point (focus-point popup-menu))
    (setf (slot-value popup-menu 'focus-active) t)
    (funcall function point)
    (when (and direction (not (seek-selectable-point point direction)))
      (if (plusp direction)
          (buffer-start point)
          (buffer-end point))
      (seek-selectable-point point (- direction)))
    (line-start point)
    (window-see (popup-menu-window popup-menu))
    (update-focus-overlay popup-menu point)))

(defmethod lem-if:popup-menu-down (implementation popup-menu)
  (if (popup-menu-focus-active-p popup-menu)
      (move-focus
       popup-menu
       (lambda (point)
         (unless (line-offset point 1)
           (buffer-start point)))
       1)
      (popup-menu-activate-focus popup-menu)))

(defmethod lem-if:popup-menu-up (implementation popup-menu)
  (if (popup-menu-focus-active-p popup-menu)
      (move-focus
       popup-menu
       (lambda (point)
         (unless (line-offset point -1)
           (buffer-end point)))
       -1)
      (popup-menu-activate-focus popup-menu)))

(defmethod lem-if:popup-menu-first (implementation popup-menu)
  (setf (slot-value popup-menu 'focus-active) t)
  (move-focus
   popup-menu
   (lambda (point)
     (buffer-start point))
   1))

(defmethod lem-if:popup-menu-last (implementation popup-menu)
  (setf (slot-value popup-menu 'focus-active) t)
  (move-focus
   popup-menu
   (lambda (point)
     (buffer-end point))
   -1))

(defmethod lem-if:popup-menu-select (implementation popup-menu)
  (alexandria:when-let ((f (popup-menu-action-callback popup-menu))
                        (item (get-focus-item popup-menu)))
    (funcall f item)))
