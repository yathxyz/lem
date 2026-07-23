(in-package :lem-core)

(define-editor-variable wrap-line-character #\\)
(define-editor-variable wrap-line-attribute nil)
(define-editor-variable display-line-transform-function nil
  "Optional function called with BUFFER, the source POINT, a freshly
constructed LOGICAL-LINE, and the rendering WINDOW before conversion to
drawing objects.  WINDOW is NIL for callers which construct a logical line
outside redisplay.  The function may replace display strings and attributes
but must not modify the buffer or change the number of cells corresponding to
existing text.")

(defvar *inactive-window-background-color* nil)

(defun inactive-window-background-color ()
  *inactive-window-background-color*)

(defun (setf inactive-window-background-color) (color)
  (setf *inactive-window-background-color* color))

(defgeneric redraw-buffer (implementation buffer window force))

(defgeneric compute-left-display-area-content (mode buffer point)
  (:method (mode buffer point) nil))

(defgeneric compute-window-content-width (mode buffer window)
  (:documentation
   "Return the preferred maximum content width in columns for WINDOW, or NIL.")
  (:method (mode buffer window)
    (declare (ignore mode buffer window))
    nil))

(defgeneric compute-wrap-left-area-content (mode left-side-width left-side-characters)
  (:method (mode left-side-width left-side-characters)
    nil))

(defvar *in-redraw-display* nil
  "T if the screen is currently being redrawn by `redraw-display`.
Used to prevent recursive `redraw-display` calls.")

(defgeneric window-redraw (window force)
  (:method (window force)
    (redraw-buffer (implementation) (window-buffer window) window force)
    (when (window-attached-window window)
      (window-redraw (window-attached-window window) force))))

(defun redraw-current-window (window force)
  (assert (eq window (current-window)))
  (window-see window)
  (run-show-buffer-hooks window)
  (window-redraw window force))

(defun redraw-display (&key force)
  (when (no-force-needed-p (implementation))
    (setf force nil))
  (when *in-redraw-display*
    (log:warn "redraw-display is called recursively")
    (return-from redraw-display))
  (prog1
      (let ((*in-redraw-display* t)
            (redraw-after-modifying-floating-window
              (and (not (no-force-needed-p (implementation)))
                   (redraw-after-modifying-floating-window (implementation)))))
        (labels ((redraw-window-list (force)
                   (dolist (window (window-list))
                     (unless (eq window (current-window))
                       (window-redraw window force)))
                   (redraw-current-window (current-window) force))
                 (redraw-header-windows (force)
                   (let ((force (or force (not (null (frame-floating-windows (current-frame)))))))
                     (dolist (window (frame-header-windows (current-frame)))
                       (window-redraw window force))))
                 (redraw-floating-windows ()
                   (dolist (window (frame-floating-windows (current-frame)))
                     (window-redraw window redraw-after-modifying-floating-window)))
                 (redraw-all-windows ()
                   (redraw-header-windows force)
                   (redraw-window-list
                    (if redraw-after-modifying-floating-window
                        (or (frame-require-redisplay-windows (current-frame))
                            ;; floating-windowが変更されたら、その下のウィンドウは再描画する必要がある
                            (frame-modified-floating-windows (current-frame))
                            force)
                        force))
                   (redraw-floating-windows)
                   (lem-if:update-display (implementation))))
          (without-interrupts
            (lem-if:will-update-display (implementation))
            (update-floating-prompt-window (current-frame))
            (when (frame-modified-header-windows (current-frame))
              (adjust-all-window-size))
            (redraw-all-windows)
            (notify-frame-redraw-finished (current-frame)))))
    (note-redisplay-done)))
