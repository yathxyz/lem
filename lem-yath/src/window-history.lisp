;;;; Frame-local window-layout history modelled after Emacs Winner mode.
;;;; Ordinary editor windows and their buffers are recorded; prompt, floating,
;;;; attached, header, and side windows remain owned by their subsystems.

(in-package :lem-yath)

(defparameter *window-layout-history-limit* 200)

(defparameter *window-layout-boring-buffers* '("*Completions*"))

(defclass window-layout-leaf ()
  ((buffer :initarg :buffer :reader window-layout-leaf-buffer)
   (view-point :initarg :view-point :reader window-layout-leaf-view-point)))

(defclass window-layout-branch ()
  ((split-type :initarg :split-type :reader window-layout-branch-split-type)
   (ratio :initarg :ratio :reader window-layout-branch-ratio)
   (left :initarg :left :reader window-layout-branch-left)
   (right :initarg :right :reader window-layout-branch-right)))

(defclass window-layout-configuration ()
  ((tree :initarg :tree :reader window-layout-configuration-tree)
   (signature :initarg :signature :reader window-layout-configuration-signature)
   (selected-index :initarg :selected-index
                   :accessor window-layout-configuration-selected-index)))

(defclass window-layout-frame-history ()
  ((current :initform nil :accessor window-layout-history-current)
   (undo :initform nil :accessor window-layout-history-undo)
   (redo :initform nil :accessor window-layout-history-redo)
   (last-command :initform nil :accessor window-layout-history-last-command)))

(defvar *window-layout-histories* (make-hash-table :test #'eq))

(defvar *restoring-window-layout-p* nil)

(defun window-layout-tree-bounds (tree)
  (if (lem-core::window-tree-leaf-p tree)
      (values (window-x tree)
              (window-y tree)
              (+ (window-x tree) (window-width tree))
              (+ (window-y tree) (window-height tree)))
      (multiple-value-bind (left-x left-y left-right left-bottom)
          (window-layout-tree-bounds (lem-core::window-node-left tree))
        (multiple-value-bind (right-x right-y right-right right-bottom)
            (window-layout-tree-bounds (lem-core::window-node-right tree))
          (values (min left-x right-x)
                  (min left-y right-y)
                  (max left-right right-right)
                  (max left-bottom right-bottom))))))

(defun capture-window-layout-node (tree)
  (if (lem-core::window-tree-leaf-p tree)
      (make-instance 'window-layout-leaf
                     :buffer (window-buffer tree)
                     :view-point (copy-point (window-view-point tree)
                                             :right-inserting))
      (let* ((split-type (lem-core::window-node-split-type tree))
             (left-tree (lem-core::window-node-left tree))
             (right-tree (lem-core::window-node-right tree)))
        (multiple-value-bind (left-x left-y left-right left-bottom)
            (window-layout-tree-bounds left-tree)
          (multiple-value-bind (right-x right-y right-right right-bottom)
              (window-layout-tree-bounds right-tree)
            (let ((left-span (if (eq split-type :hsplit)
                                 (- left-right left-x)
                                 (- left-bottom left-y)))
                  (right-span (if (eq split-type :hsplit)
                                  (- right-right right-x)
                                  (- right-bottom right-y))))
              (make-instance 'window-layout-branch
                             :split-type split-type
                             :ratio (/ left-span (+ left-span right-span))
                             :left (capture-window-layout-node left-tree)
                             :right (capture-window-layout-node right-tree))))))))

(defun window-layout-tree-signature (tree)
  (if (lem-core::window-tree-leaf-p tree)
      (list :leaf
            (window-buffer tree)
            (window-x tree)
            (window-y tree)
            (window-width tree)
            (window-height tree))
      (list (lem-core::window-node-split-type tree)
            (window-layout-tree-signature
             (lem-core::window-node-left tree))
            (window-layout-tree-signature
             (lem-core::window-node-right tree)))))

(defun window-layout-signature-matches-tree-p (signature tree)
  (if (lem-core::window-tree-leaf-p tree)
      (and (eq (first signature) :leaf)
           (eq (second signature) (window-buffer tree))
           (= (third signature) (window-x tree))
           (= (fourth signature) (window-y tree))
           (= (fifth signature) (window-width tree))
           (= (sixth signature) (window-height tree)))
      (and (eq (first signature)
               (lem-core::window-node-split-type tree))
           (window-layout-signature-matches-tree-p
            (second signature) (lem-core::window-node-left tree))
           (window-layout-signature-matches-tree-p
            (third signature) (lem-core::window-node-right tree)))))

(defun refresh-window-layout-view-points (node tree)
  (typecase node
    (window-layout-leaf
     (move-point (window-layout-leaf-view-point node)
                 (window-view-point tree)))
    (window-layout-branch
     (refresh-window-layout-view-points
      (window-layout-branch-left node)
      (lem-core::window-node-left tree))
     (refresh-window-layout-view-points
      (window-layout-branch-right node)
      (lem-core::window-node-right tree)))))

(defun capture-window-layout (&optional (frame (current-frame)))
  (let* ((windows (window-list frame))
         (selected (lem-core::frame-current-window frame))
         (selected-index (position selected windows :test #'eq)))
    (when (and windows selected-index)
      (let ((tree (lem-core::frame-window-tree frame)))
        (make-instance 'window-layout-configuration
                       :tree (capture-window-layout-node tree)
                       :signature (window-layout-tree-signature tree)
                       :selected-index selected-index)))))

(defun dispose-window-layout-node (node)
  (typecase node
    (window-layout-leaf
     (ignore-errors (delete-point (window-layout-leaf-view-point node))))
    (window-layout-branch
     (dispose-window-layout-node (window-layout-branch-left node))
     (dispose-window-layout-node (window-layout-branch-right node)))))

(defun dispose-window-layout (configuration)
  (when configuration
    (dispose-window-layout-node
     (window-layout-configuration-tree configuration))))

(defun dispose-window-layout-list (configurations)
  (mapc #'dispose-window-layout configurations))

(defun window-layout-node-valid-p (node)
  (typecase node
    (window-layout-leaf
     (let ((buffer (window-layout-leaf-buffer node)))
       (and (not (deleted-buffer-p buffer))
            (not (member (buffer-name buffer)
                         *window-layout-boring-buffers*
                         :test #'string=)))))
    (window-layout-branch
     (and (window-layout-node-valid-p (window-layout-branch-left node))
          (window-layout-node-valid-p (window-layout-branch-right node))))
    (t nil)))

(defun window-layout-minimum-size (node)
  (typecase node
    (window-layout-leaf (values 3 2))
    (window-layout-branch
     (multiple-value-bind (left-width left-height)
         (window-layout-minimum-size (window-layout-branch-left node))
       (multiple-value-bind (right-width right-height)
           (window-layout-minimum-size (window-layout-branch-right node))
         (if (eq (window-layout-branch-split-type node) :hsplit)
             (values (+ left-width
                        (lem-core::frame-window-left-margin (current-frame))
                        right-width)
                     (max left-height right-height))
             (values (max left-width right-width)
                     (+ left-height
                        (lem-core::frame-window-bottom-margin (current-frame))
                        right-height))))))))

(defun clamp-window-layout-span (wanted minimum maximum)
  (max minimum (min wanted maximum)))

(defun build-window-layout-tree (configuration)
  (let ((created nil))
    (labels ((build (node x y width height)
               (multiple-value-bind (minimum-width minimum-height)
                   (window-layout-minimum-size node)
                 (when (or (< width minimum-width) (< height minimum-height))
                   (error "Window layout does not fit the current frame")))
               (typecase node
                 (window-layout-leaf
                  (let* ((buffer (window-layout-leaf-buffer node))
                         (window (lem-core::make-window
                                  buffer x y width height t)))
                    (push window created)
                    (move-point (window-view-point window)
                                (window-layout-leaf-view-point node))
                    (move-point (lem-core::%window-point window)
                                (buffer-point buffer))
                    window))
                 (window-layout-branch
                  (let* ((split-type (window-layout-branch-split-type node))
                         (left-node (window-layout-branch-left node))
                         (right-node (window-layout-branch-right node))
                         (margin (if (eq split-type :hsplit)
                                     (lem-core::frame-window-left-margin
                                      (current-frame))
                                     (lem-core::frame-window-bottom-margin
                                      (current-frame))))
                         (extent (if (eq split-type :hsplit) width height))
                         (available (- extent margin)))
                    (multiple-value-bind (left-min-width left-min-height)
                        (window-layout-minimum-size left-node)
                      (multiple-value-bind (right-min-width right-min-height)
                          (window-layout-minimum-size right-node)
                        (let* ((left-min (if (eq split-type :hsplit)
                                             left-min-width left-min-height))
                               (right-min (if (eq split-type :hsplit)
                                              right-min-width right-min-height))
                               (left-span
                                 (clamp-window-layout-span
                                  (round (* available
                                            (window-layout-branch-ratio node)))
                                  left-min
                                  (- available right-min)))
                               (right-span (- available left-span)))
                          (if (eq split-type :hsplit)
                              (lem-core::make-window-node
                               split-type
                               (build left-node x y left-span height)
                               (build right-node
                                      (+ x left-span margin)
                                      y right-span height))
                              (lem-core::make-window-node
                               split-type
                               (build left-node x y width left-span)
                               (build right-node
                                      x (+ y left-span margin)
                                      width right-span)))))))))))
      (handler-case
          (let* ((frame (current-frame))
                 (tree (build
                        (window-layout-configuration-tree configuration)
                        (lem-core::topleft-window-x frame)
                        (lem-core::topleft-window-y frame)
                        (lem-core::max-window-width frame)
                        (lem-core::max-window-height frame))))
            (values tree (nreverse created)))
        (error (condition)
          (dolist (window created)
            (ignore-errors (lem-core::%free-window window)))
          (error condition))))))

(defun release-replaced-layout-window (window)
  (unless (lem-core::window-deleted-p window)
    (let ((attached (lem-core::window-attached-window window)))
      (when attached
        (ignore-errors (delete-window attached))))
    (run-hooks (lem-core::window-delete-hook window))
    (lem-core::%free-window window)
    (setf (lem-core::window-deleted-p window) t)))

(defun restore-window-layout (configuration)
  (unless (window-layout-node-valid-p
           (window-layout-configuration-tree configuration))
    (return-from restore-window-layout nil))
  (multiple-value-bind (new-tree new-windows)
      (build-window-layout-tree configuration)
    (let* ((frame (current-frame))
           (old-windows (window-list frame))
           (selected-index
             (min (window-layout-configuration-selected-index configuration)
                  (1- (length new-windows))))
           (selected-window (nth selected-index new-windows)))
      (let ((*restoring-window-layout-p* t))
        (setf (lem-core::frame-window-tree frame) new-tree)
        (setf (current-window) selected-window)
        (setf lem-core::*last-focused-window* nil)
        (dolist (window old-windows)
          (release-replaced-layout-window window))
        (dolist (window new-windows)
          (let ((attached-buffer
                  (lem-core::buffer-attached-buffer (window-buffer window))))
            (when attached-buffer
              (lem-core::make-attached-window window :buffer attached-buffer))))
        (lem-core::notify-frame-redisplay-required frame))
      t)))

(defun trim-window-layout-history (configurations)
  (cond
    ((not (plusp *window-layout-history-limit*))
     (dispose-window-layout-list configurations)
     nil)
    ((> (length configurations) *window-layout-history-limit*)
     (let* ((last-retained
              (nthcdr (1- *window-layout-history-limit*) configurations))
            (discarded (cdr last-retained)))
       (setf (cdr last-retained) nil)
       (dispose-window-layout-list discarded)
       configurations))
    (t configurations)))

(defun push-window-layout-history (configuration configurations)
  (trim-window-layout-history (cons configuration configurations)))

(defun clear-window-layout-redo (history)
  (dispose-window-layout-list (window-layout-history-redo history))
  (setf (window-layout-history-redo history) nil))

(defun ensure-window-layout-history (&optional (frame (current-frame)))
  (or (gethash frame *window-layout-histories*)
      (let ((history (make-instance 'window-layout-frame-history)))
        (setf (window-layout-history-current history)
              (capture-window-layout frame))
        (setf (gethash frame *window-layout-histories*) history)
        history)))

(defun dispose-window-layout-history (history)
  (dispose-window-layout (window-layout-history-current history))
  (dispose-window-layout-list (window-layout-history-undo history))
  (dispose-window-layout-list (window-layout-history-redo history)))

(defun cull-window-layout-histories ()
  (let ((live-frames (lem-core::all-frames))
        (dead-frames nil))
    (maphash (lambda (frame history)
               (unless (member frame live-frames :test #'eq)
                 (dispose-window-layout-history history)
                 (push frame dead-frames)))
             *window-layout-histories*)
    (dolist (frame dead-frames)
      (remhash frame *window-layout-histories*))))

(defun record-current-window-layout ()
  (unless *restoring-window-layout-p*
    (cull-window-layout-histories)
    (let* ((frame (current-frame))
           (history (ensure-window-layout-history frame))
           (tree (lem-core::frame-window-tree frame))
           (windows (window-list frame))
           (selected-index
             (position (lem-core::frame-current-window frame)
                       windows :test #'eq))
           (command (and (this-command) (command-name (this-command))))
           (current (window-layout-history-current history)))
      (when selected-index
        (cond
          ((and current
                (window-layout-signature-matches-tree-p
                 (window-layout-configuration-signature current) tree))
           (refresh-window-layout-view-points
            (window-layout-configuration-tree current) tree)
           (setf (window-layout-configuration-selected-index current)
                 selected-index))
          (t
           (let ((configuration (capture-window-layout frame)))
             (cond
               ((null current) nil)
               ((equal command
                       (window-layout-history-last-command history))
                (dispose-window-layout current))
               (t
                (setf (window-layout-history-undo history)
                      (push-window-layout-history
                       current (window-layout-history-undo history)))
                (clear-window-layout-redo history)))
             (setf (window-layout-history-current history)
                   configuration)))))
      (setf (window-layout-history-last-command history) command))))

(defun pop-valid-window-layout (configurations)
  (loop :while configurations
        :for configuration := (pop configurations)
        :if (window-layout-node-valid-p
             (window-layout-configuration-tree configuration))
          :do (return (values configuration configurations))
        :else
          :do (dispose-window-layout configuration)
        :finally (return (values nil nil))))

(defun move-window-layout-history (direction)
  (let* ((history (ensure-window-layout-history))
         (source (ecase direction
                   (:undo (window-layout-history-undo history))
                   (:redo (window-layout-history-redo history)))))
    (flet ((set-source (value)
             (ecase direction
               (:undo (setf (window-layout-history-undo history) value))
               (:redo (setf (window-layout-history-redo history) value)))))
      (multiple-value-bind (target remainder)
          (pop-valid-window-layout source)
        (unless target
          (set-source remainder)
          (editor-error "No further window layout ~a information"
                        (string-downcase direction)))
        (let ((live (capture-window-layout)))
          (unless live
            (set-source (cons target remainder))
            (editor-error "The current window layout cannot be recorded"))
          (handler-case
              (unless (restore-window-layout target)
                (error "The saved buffers are no longer available"))
            (error (condition)
              (dispose-window-layout live)
              (set-source (cons target remainder))
              (editor-error "Cannot restore the saved window layout: ~a"
                            condition)))
          (set-source remainder)
          (ecase direction
            (:undo
             (setf (window-layout-history-redo history)
                   (push-window-layout-history
                    live (window-layout-history-redo history))))
            (:redo
             (setf (window-layout-history-undo history)
                   (push-window-layout-history
                    live (window-layout-history-undo history)))))
          (dispose-window-layout (window-layout-history-current history))
          (dispose-window-layout target)
          (setf (window-layout-history-current history)
                (capture-window-layout)))))))

(define-command lem-yath-window-layout-undo () ()
  "Restore the preceding ordinary-window configuration in this frame."
  (move-window-layout-history :undo)
  (message "Winner undo"))

(define-command lem-yath-window-layout-redo () ()
  "Restore the next ordinary-window configuration in this frame."
  (move-window-layout-history :redo)
  (message "Winner redo"))

(define-key *global-keymap* "C-c Left" 'lem-yath-window-layout-undo)
(define-key *global-keymap* "C-c Right" 'lem-yath-window-layout-redo)

(remove-hook *post-command-hook* 'record-current-window-layout)
(add-hook *post-command-hook* 'record-current-window-layout)
(ensure-window-layout-history)
