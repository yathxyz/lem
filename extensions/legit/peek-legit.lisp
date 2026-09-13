#|
peek-legit defines the left window of the legit interface.

It writes on the window the VCS components: untracked files, changes, staged changes, latest commits… They are displayed with custom attributes (read-only colors…) and text properties (on this line, the function to call on Enter is this lambda function…).

Cursor mouvements and keybindings send changes to the right window.


Notes:

- if names don't conflict, use a :keyword for text properties, not a 'symbol (:commit-hash vs 'commit-hash). Keywords are easier to manipulate from another source file (no home package).
- the dichotomoy peek-legit / legit originally follows grep-mode.

|#

(in-package :lem/legit)


(define-minor-mode peek-legit-mode
    (:name "Peek"
     :keymap *peek-legit-keymap*)
  (setf (not-switchable-buffer-p (current-buffer)) t))

;; Git commands
;; Some are defined on legit.lisp for this keymap too.
(define-key *peek-legit-keymap* "s" 'peek-legit-stage-file)
(define-key *peek-legit-keymap* "u" 'peek-legit-unstage-file)
(define-key *peek-legit-keymap* "k" 'peek-legit-discard-file)

;; quit
(define-key *peek-legit-keymap* "Return" 'peek-legit-select)

;; navigation
(define-key *peek-legit-keymap* 'next-line 'peek-legit-next)
(define-key *peek-legit-keymap* "n" 'peek-legit-next)
(define-key *peek-legit-keymap* "C-n" 'peek-legit-next)
(define-key *peek-legit-keymap* 'previous-line 'peek-legit-previous)
(define-key *peek-legit-keymap* "p" 'peek-legit-previous)
(define-key *peek-legit-keymap* "C-p" 'peek-legit-previous)
(define-key *peek-legit-keymap* "Tab" 'next-window)


;;;
;;; The two windows pane.
;;;
(define-attribute filename-attribute
  (t :foreground :base0D))

(define-attribute highlight
  (t :background :base0D))

(defvar *collector*)

(defclass collector ()
  ((buffer :initarg :buffer
           :reader collector-buffer)
   (count :initform 0
          :accessor collector-count)))

(defstruct pane-context parent peek source buffers overlays finalizing closed)

(defun current-pane-context (&optional create)
  "The active frame owns its panes through window parameters, never globals."
  (or (loop for window in (cons (current-window)
                               (append (lem-core::frame-floating-windows (current-frame))
                                       (window-list)))
            for context = (window-parameter window 'legit-context)
            when (and context (not (pane-context-closed context))) return context)
      (when create
        (let ((context (make-pane-context :parent (current-window))))
          (setf (window-parameter (current-window) 'legit-context) context)
          context))))

(defun peek-window ()
  (alexandria:when-let ((context (current-pane-context))) (pane-context-peek context)))
(defun source-window ()
  (alexandria:when-let ((context (current-pane-context))) (pane-context-source context)))
(defun parent-window ()
  (alexandria:when-let ((context (current-pane-context))) (pane-context-parent context)))

(defun pane-buffer (kind name &key (temporary t) (enable-undo-p nil))
  (let* ((context (current-pane-context t))
         (entry (assoc kind (pane-context-buffers context)))
         (buffer (cdr entry)))
    (unless (and buffer (not (deleted-buffer-p buffer)))
      (setf buffer (make-buffer (unique-buffer-name name) :temporary temporary
                                :enable-undo-p enable-undo-p :directory (uiop:getcwd)))
      (setf (buffer-value buffer 'legit-buffer-kind) kind)
      (if entry (setf (cdr entry) buffer)
          (push (cons kind buffer) (pane-context-buffers context))))
    buffer))

(defun dispose-pane-buffers (context)
  ;; Exact objects only. A human may have deliberately opened one of these
  ;; buffers in a surviving frame; that live view retains its buffer.
  (dolist (entry (pane-context-buffers context))
    (let ((buffer (cdr entry)))
      (when (and (not (deleted-buffer-p buffer))
                 (or (buffer-temporary-p buffer) (member buffer (buffer-list)))
                 (not (loop for frame in (all-frames)
                            thereis (find buffer (append (window-list frame)
                                                        (lem-core::frame-floating-windows frame))
                                          :key #'window-buffer))))
        (delete-buffer buffer))))
  (setf (pane-context-buffers context) nil))

(defun retire-pane-context (context)
  (unless (pane-context-closed context)
    (setf (pane-context-closed context) t)
    (finalize-highlight-overlays context)
    ;; DELETE-WINDOW and frame teardown still own their backend cleanup.
    ;; Buffer disposal happens later, under the then-active editor context.
    (send-event (lambda () (dispose-pane-buffers context)))))

(defun retire-frame-pane-contexts (frame)
  (dolist (context (remove-duplicates
                    (remove nil (mapcar (lambda (window) (window-parameter window 'legit-context))
                                        (append (window-list frame)
                                                (lem-core::frame-floating-windows frame))))))
    (retire-pane-context context)))

(add-hook *teardown-frame-hook* 'retire-frame-pane-contexts)

(defclass peek-window (floating-window) ())
(defclass source-window (floating-window) ())

(defmethod lem-core::%delete-window :before ((window peek-window))
  (finalize-peek-legit (window-parameter window 'legit-context) :deleting window))
(defmethod lem-core::%delete-window :before ((window source-window))
  (finalize-peek-legit (window-parameter window 'legit-context) :deleting window))

(defmethod compute-window-list ((window peek-window))
  (let ((context (window-parameter window 'legit-context)))
    (list (pane-context-peek context) (pane-context-source context))))
(defmethod compute-window-list ((window source-window))
  (let ((context (window-parameter window 'legit-context)))
    (list (pane-context-source context) (pane-context-peek context))))

(defun finalize-peek-legit (&optional (context (current-pane-context)) &key deleting)
  (when (and context (not (or (pane-context-finalizing context) (pane-context-closed context))))
    (setf (pane-context-finalizing context) t)
    (unwind-protect
         (progn
           (finalize-highlight-overlays context)
           (let ((parent (pane-context-parent context)))
             (when (member (current-window) (list (pane-context-peek context) (pane-context-source context)))
               (setf (current-window) parent))
             (dolist (window (list (pane-context-source context) (pane-context-peek context)))
               ;; The outer DELETE-WINDOW owns DELETING. Recursing into it
               ;; would release its backend view and points twice.
               (when (and window (not (eq window deleting))
                          (not (lem-core::window-deleted-p window)))
                 (delete-window window)))
             (when (eq context (window-parameter parent 'legit-context))
               (setf (window-parameter parent 'legit-context) nil)))
           (retire-pane-context context))
      (setf (pane-context-finalizing context) nil))))

(defun set-move-function (start end move-function)
  (with-point ((end start))
    (character-offset end 1)
    (put-text-property start end :move-marker t))
  (put-text-property start end :move-function move-function))

(defun set-visit-file-function (start end function)
  (with-point ((end start))
    (character-offset end 1)
    (put-text-property start end :file-marker t))
  (put-text-property start end :visit-file-function function))

(defun set-stage-function (start end function)
  (with-point ((end start))
    (character-offset end 1)
    (put-text-property start end :stage-marker t))
  (put-text-property start end :stage-function function))

(defun set-unstage-function (start end function)
  (with-point ((end start))
    (character-offset end 1)
    (put-text-property start end :unstage-marker t))
  (put-text-property start end :unstage-function function))

(defun set-discard-file-function (start end function)
  (with-point ((end start))
    (character-offset end 1)
    (put-text-property start end :discard-file-marker t))
  (put-text-property start end :discard-file-function function))

(defun get-move-function (point)
  (with-point ((point point))
    (line-start point)
    (text-property-at point :move-function)))

(defun get-visit-file-function (point)
  (with-point ((point point))
    (line-start point)
    (text-property-at point :visit-file-function)))

(defun get-stage-function (point)
  (with-point ((point point))
    (line-start point)
    (text-property-at point :stage-function)))

(defun get-unstage-function (point)
  (with-point ((point point))
    (line-start point)
    (text-property-at point :unstage-function)))

(defun get-discard-file-function (point)
  (with-point ((point point))
    (line-start point)
    (text-property-at point :discard-file-function)))

(defun start-move-point (point)
  (buffer-start point)
  (unless (text-property-at point :move-marker)
    (next-move-point point)))

(defun next-move-point (point)
  "Find the next point (line) with a marker.
  This is how we distinguish between simple text, and meaningful text."
  (when (text-property-at point :move-marker)
    (next-single-property-change point :move-marker))
  (next-single-property-change point :move-marker))

(defun previous-move-point (point)
  (when (text-property-at point :move-marker)
    (previous-single-property-change point :move-marker))
  (previous-single-property-change point :move-marker))

(defun next-header-point (point)
  "Find the next point (line) with a header marker."
  (when (text-property-at point :header-marker)
    (next-single-property-change point :header-marker))
  (next-single-property-change point :header-marker))

(defun previous-header-point (point)
  "Find the previous point (line) with a header marker."
  (when (text-property-at point :header-marker)
    (previous-single-property-change point :header-marker))
  (previous-single-property-change point :header-marker))

(defun make-two-side-by-side-windows (buffer)
  (let* ((x-margin 4)
         (y-margin 2)
         (width (- (floor (display-width) 2) 2 x-margin))
         (height (- (display-height) 2 (* 2 y-margin)))
         (peek-window (make-instance 'peek-window
                                     :buffer buffer
                                     :x (+ 1 x-margin)
                                     :y (+ 1 y-margin)
                                     :width width
                                     :height height
                                     :use-border t))
         (source-window (make-instance 'source-window
                                       :buffer (pane-buffer :source "*source*")
                                       :x (+ (window-x peek-window) (window-width peek-window) 2)
                                       :y (+ 1 y-margin)
                                       :width width
                                       :height height
                                       :use-border t)))
    (list peek-window source-window)))

(defun display (collector &key (minor-mode 'peek-legit-mode))
  (let ((context (current-pane-context t)))
    (setf (pane-context-finalizing context) t)
    (unwind-protect
         (progn
           (when (member (current-window) (list (pane-context-peek context) (pane-context-source context)))
             (setf (current-window) (pane-context-parent context)))
           (dolist (window (list (pane-context-peek context) (pane-context-source context)))
             (when (and window (not (lem-core::window-deleted-p window))) (delete-window window))))
      (setf (pane-context-finalizing context) nil))
    (destructuring-bind (peek source)
        (make-two-side-by-side-windows (collector-buffer collector))
      (setf (pane-context-peek context) peek (pane-context-source context) source
            (window-parameter peek 'legit-context) context
            (window-parameter source 'legit-context) context
            (current-window) peek)
      (funcall minor-mode t)
      (start-move-point (buffer-point (collector-buffer collector)))
      (show-matched-line))))

(defun make-peek-legit-buffer (&key (name "*peek-legit*"))
  (let ((buffer (pane-buffer (if (equal name "*peek-legit*") :status :commits-log)
                             name :enable-undo-p t)))
    (let ((*inhibit-read-only* t)) (erase-buffer buffer))
    (setf (variable-value 'line-wrap :buffer buffer) nil)
    buffer))

(defun call-with-collecting-sources (function &key read-only buffer (minor-mode 'peek-legit-mode))
  "Initialize variables to display things on a legit buffer.

  BUFFER: either :status or :commits-log.
  READ-ONLY: boolean.
  MINOR-MODE: the minor mode to activate after we displayed things in the buffer. Defaults to the main peek-legit-mode. The mode is activated with:

    (peek-legit-mode t)
  or
    (funcall minor-mode t)"
  (let* ((*collector* (make-instance 'collector
                                     :buffer
                                     (make-peek-legit-buffer
                                      :name
                                      (case buffer
                                        (:status "*peek-legit*")
                                        (:commits-log "*legit-commits-log*")
                                        (otherwise (error "Unknown buffer name to display legit data: ~a" buffer))))))
         (point (buffer-point (collector-buffer *collector*))))
    (declare (ignorable point))
    (funcall function *collector*)
    (when read-only
      (setf (buffer-read-only-p (collector-buffer *collector*)) t))
      (display *collector* :minor-mode minor-mode)))

(defmacro with-collecting-sources ((collector &key (buffer :status)
                                                (read-only t)
                                                (minor-mode 'peek-legit-mode))
                                   &body body)
  "Top-level macro that prepares a buffer to print stuff on and activates a minor-mode.

  Then see `with-appending-source' and `collector-insert'."
  `(call-with-collecting-sources (lambda (,collector)
                                   (declare (ignorable ,collector))
                                   ,@body)
                                 :buffer ,buffer
                                 :minor-mode ,minor-mode
                                 :read-only ,read-only))

(defun call-with-appending-source (insert-function
                                   move-function
                                   visit-file-function
                                   stage-function
                                   unstage-function
                                   discard-file-function)
  (let ((point (buffer-point (collector-buffer *collector*))))
    (with-point ((start point))
      (funcall insert-function point)
      (unless (start-line-p point)
        (insert-string point (string #\newline) :read-only t))
      (set-move-function start point move-function)
      (set-visit-file-function start point visit-file-function)
      (set-stage-function start point stage-function)
      (set-unstage-function start point unstage-function)
      (set-discard-file-function start point discard-file-function))
    (incf (collector-count *collector*))))

(defmacro with-appending-source ((point &key move-function
                                             visit-file-function
                                             stage-function
                                             unstage-function
                                             discard-file-function) &body body)
  "Macro to use inside `with-collecting-sources' to print stuff.

  Save the lambda functions :move-function etc to their corresponding string properties.

  A keybinding is associated to these functions.
  They will dig up the lambda functions associated with these markers and run them.

  Devel note 2024: the key arguments move-function, visit-file-function etc
  are now badly named. They should represent a function tied to an action:
  - what to do when the point moves on this line (this is currently move-function to show diffs)
  - what to do on Enter (this is currently visit-file-function)
  - what to do on the `s` keybinding (currently stage-function)
  etc

  Not everything represented on legit status represents a file.
  We now use :visit-file-function and :stage-function to have actions on stashes."
  `(call-with-appending-source (lambda (,point) ,@body)
                               ,move-function
                               ,visit-file-function
                               ,stage-function
                               ,unstage-function
                               ,discard-file-function))

(defun collector-insert (s &key (newline t) header)
  (let ((point (buffer-point (collector-buffer *collector*))))
    (with-point ((start point))
      (character-offset start 1)
      (insert-string point s :read-only t)
      (when header
        (put-text-property start point :header-marker t))
      (when newline
        (insert-string point (string #\newline) :read-only t)))))

;;;
(define-attribute match-line-attribute
  (t :background :base02))

(defun get-matched-point ()
  (alexandria:when-let* ((move (get-move-function (buffer-point (window-buffer (peek-window)))))
                         (point (funcall move)))
    point))

(defun get-matched-file ()
  (alexandria:when-let* ((visit-file-function (get-visit-file-function
                                               (buffer-point (window-buffer (peek-window)))))
                         (file (funcall visit-file-function)))
    file))

(defun show-matched-line ()
  (alexandria:when-let (point (get-matched-point))
    (let* ((point (copy-point point :temporary))
           (buffer (point-buffer point)))
      (with-current-window (source-window)
        (switch-to-buffer buffer nil nil)
        (update-highlight-overlay point)
        (move-point (buffer-point buffer) point)
        (window-see (current-window))))))

(defmethod execute :after ((mode peek-legit-mode) command argument)
  "After a command is run in this mode, apply an effect.

  In the case of `peek-legit-mode', it is run after `peek-legit-next',
  in order to show the file content on the right window.

  The method is to subclass for all legit modes."
  (when (eq (current-window) (peek-window))
    (show-matched-line)))

(defun highlight-matched-line (point)
  (let ((overlay (make-line-overlay point 'highlight)))
    (start-timer (make-timer (lambda ()
                               (delete-overlay overlay))
                             :name "highlight-matched-line")
                 300)))


(define-command peek-legit-select () ()
  "Run the action stored in the :visit-file-function marker. Bound to Enter.

  By default, this function works on files:
  - execute the lambda function from the marker,
  - expect its return value is a file name
  - and visit the file, in the context of the current VCS.

  It is possible to run actions not tied to files, for example do
  something when pressing Enter on a line representing a commit stash.
  The lambda function needs to return nil or (values)."
  (alexandria:when-let ((path (get-matched-file)))
    (%legit-quit)
    (with-current-project (vcs)
      (declare (ignore vcs))
      (let ((full-path (merge-pathnames path (uiop:getcwd))))
        (if (or (uiop:file-exists-p full-path)
                (uiop:directory-exists-p full-path))
            (find-file (namestring full-path))
            (editor-error "Path ~a doesn't exist." full-path))))))

(define-command peek-legit-next () ()
  "Find the next line with a :move-marker text property.

  After finding it, our :after method of `execute' is run, to apply an effect, showing the new diff on the right."
  (next-move-point (current-point)))

(define-command peek-legit-next-header () ()
  (next-header-point (current-point)))

(define-command peek-legit-previous-header () ()
  (previous-header-point (current-point)))

(define-command peek-legit-previous () ()
  (previous-move-point (current-point)))

(define-command peek-legit-stage-file () ()
  "Get the lambda function associated with the :stage-function marker, call it, ignore side effects and refresh legit status."
  (alexandria:when-let* ((stage (get-stage-function (buffer-point (window-buffer (peek-window)))))
                         (point (funcall stage)))
    ;; Update the buffer, to see that a staged file goes to the staged section.
    ;; This calls git again and refreshes everything.
    (show-legit-status)
    point))

(define-command peek-legit-unstage-file () ()
  "Get the lambda function associated with the :unstage-function marker, call it, ignore side effects and refresh legit status."
  (alexandria:when-let* ((unstage (get-unstage-function (buffer-point (window-buffer (peek-window)))))
                         (point (funcall unstage)))
    ;; Update the buffer, to see that a staged file goes to the staged section.
    ;; This calls git again and refreshes everything.
    (show-legit-status)
    point))

(define-command peek-legit-discard-file () ()
  "Discard the changes in this file. The file should not be stage."
  (alexandria:when-let* ((fn (get-discard-file-function (buffer-point (window-buffer (peek-window)))))
                         (point (funcall fn)))
    ;; Update the buffer.
    ;; This calls git again and refreshes everything.
    (show-legit-status)
    point))

(defun %legit-quit ()
  "Close the current frame's panes before later commands can replace them."
  (finalize-peek-legit))

(defun set-highlight-overlay (point)
  (let ((overlay (make-line-overlay point (ensure-attribute 'match-line-attribute))))
    (push overlay (pane-context-overlays (current-pane-context)))))

(defun get-highlight-overlay (point)
  (find (point-buffer point) (pane-context-overlays (current-pane-context)) :key #'overlay-buffer))

(defun update-highlight-overlay (point)
  (let ((overlay (get-highlight-overlay point)))
    (cond (overlay
           (move-point (overlay-start overlay) point)
           (move-point (overlay-end overlay) point))
          (t
           (set-highlight-overlay point)))))

(defun finalize-highlight-overlays (&optional (context (current-pane-context)))
  (when context
    (mapc #'delete-overlay (pane-context-overlays context))
    (setf (pane-context-overlays context) nil)))
