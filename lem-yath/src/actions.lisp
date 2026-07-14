;;;; Context-sensitive, Embark-style actions for the object at point.
;;;;
;;;; Targets are classified once, in strict priority order, and share a snapshot
;;;; of their originating window, buffer, and point.  The transient is generated
;;;; from typed action registrations; the invoking chord cycles targets, and a
;;;; one-key action dispatches the selected target.  All copied points and
;;;; transient state are released through unwind-protect.

(in-package :lem-yath)

;;; --- origin and typed targets ---------------------------------------------

(defclass action-origin ()
  ((window
    :initarg :window
    :reader action-origin-window)
   (buffer
    :initarg :buffer
    :reader action-origin-buffer)
   (point
    :initarg :point
    :reader action-origin-point)
   (tick
    :initarg :tick
    :reader action-origin-tick)
   (cleaned-p
    :initform nil
    :accessor action-origin-cleaned-p)))

(defclass action-target ()
  ((origin
    :initarg :origin
    :reader action-target-origin)
   (cleaned-p
    :initform nil
    :accessor action-target-cleaned-p)))

(defclass region-action-target (action-target)
  ((text
    :initarg :text
    :reader region-action-target-text)))

(defclass file-action-target (action-target)
  ((pathname
    :initarg :pathname
    :reader file-action-target-pathname)))

(defclass url-action-target (action-target)
  ((url
    :initarg :url
    :reader url-action-target-url)))

(defclass identifier-action-target (action-target)
  ((text
    :initarg :text
    :reader identifier-action-target-text)
   (point
    :initarg :point
    :reader identifier-action-target-point)))

(defclass location-action-target (action-target)
  ((point
    :initarg :point
    :reader location-action-target-point)
   (line
    :initarg :line
    :reader location-action-target-line)))

(defclass buffer-action-target (action-target)
  ((buffer
    :initarg :buffer
    :reader buffer-action-target-buffer)))

(defclass completion-action-target (action-target)
  ((context
    :initarg :context
    :reader completion-action-target-context)
   (item
    :initarg :item
    :reader completion-action-target-item)
   (generation
    :initarg :generation
    :reader completion-action-target-generation)
   (text
    :initarg :text
    :reader completion-action-target-text)))

(declaim (ftype function action-summary-text))

(defgeneric action-target-summary (target))

(defmethod action-target-summary ((target region-action-target))
  (format nil "Region: ~a" (action-summary-text
                            (region-action-target-text target))))

(defmethod action-target-summary ((target file-action-target))
  (format nil "File: ~a"
          (uiop:native-namestring (file-action-target-pathname target))))

(defmethod action-target-summary ((target url-action-target))
  (format nil "URL: ~a" (action-summary-text
                         (url-action-target-url target))))

(defmethod action-target-summary ((target identifier-action-target))
  (format nil "Identifier: ~a" (identifier-action-target-text target)))

(defmethod action-target-summary ((target location-action-target))
  (let ((point (location-action-target-point target)))
    (format nil "Location: ~a:~d"
            (or (alexandria:when-let
                    ((filename (buffer-filename (point-buffer point))))
                  (uiop:native-namestring filename))
                (buffer-name (point-buffer point)))
            (line-number-at-point point))))

(defmethod action-target-summary ((target buffer-action-target))
  (format nil "Buffer: ~a"
          (buffer-name (buffer-action-target-buffer target))))

(defmethod action-target-summary ((target completion-action-target))
  (format nil "Completion: ~a"
          (action-summary-text (completion-action-target-text target))))

(defgeneric action-target-identity (target)
  (:method ((target action-target))
    (list (class-name (class-of target)) target)))

(defmethod action-target-identity ((target region-action-target))
  (list 'region (region-action-target-text target)))

(defmethod action-target-identity ((target file-action-target))
  (list 'file
        (uiop:native-namestring (file-action-target-pathname target))))

(defmethod action-target-identity ((target url-action-target))
  (list 'url (url-action-target-url target)))

(defmethod action-target-identity ((target identifier-action-target))
  (list 'identifier (identifier-action-target-text target)))

(defmethod action-target-identity ((target location-action-target))
  (let ((point (location-action-target-point target)))
    (list 'location (point-buffer point) (position-at-point point))))

(defmethod action-target-identity ((target buffer-action-target))
  (list 'buffer (buffer-action-target-buffer target)))

(defmethod action-target-identity ((target completion-action-target))
  (list 'completion (completion-action-target-context target)
                    (completion-action-target-item target)))

(defun action-summary-text (text &optional (limit 64))
  (let* ((one-line
           (substitute #\Space #\Return
                       (substitute #\Space #\Newline (or text ""))))
         (length (length one-line)))
    (if (<= length limit)
        one-line
        (concatenate 'string (subseq one-line 0 (- limit 1)) "…"))))

(defun snapshot-action-origin ()
  "Snapshot the editor location whose target is about to be classified."
  (let ((point (current-point)))
    (make-instance 'action-origin
                   :window (current-window)
                   :buffer (current-buffer)
                   :point (copy-point point :right-inserting)
                   :tick (buffer-modified-tick (current-buffer)))))

(defun action-buffer-live-p (buffer)
  (and (bufferp buffer)
       (not (deleted-buffer-p buffer))))

(defun action-origin-live-p (origin)
  (and (not (action-origin-cleaned-p origin))
       (not (deleted-window-p (action-origin-window origin)))
       (action-buffer-live-p (action-origin-buffer origin))
       (ignore-errors
         (eq (point-buffer (action-origin-point origin))
             (action-origin-buffer origin)))))

(defun action-origin-current-p (origin &key unchanged)
  (and (action-origin-live-p origin)
       (eq (action-origin-window origin) (current-window))
       (eq (action-origin-buffer origin) (current-buffer))
       (= (position-at-point (current-point))
          (position-at-point (action-origin-point origin)))
       (or (not unchanged)
           (= (action-origin-tick origin)
              (buffer-modified-tick (action-origin-buffer origin))))))

(defun restore-action-origin (origin)
  "Restore ORIGIN when its window and buffer still exist."
  (unless (action-origin-live-p origin)
    (editor-error "The action target's originating buffer no longer exists"))
  (let ((window (action-origin-window origin))
        (buffer (action-origin-buffer origin)))
    (setf (current-window) window)
    (unless (eq buffer (current-buffer))
      (switch-to-buffer buffer nil nil))
    (move-point (current-point) (action-origin-point origin)))
  t)

(defun cleanup-action-origin (origin)
  (unless (action-origin-cleaned-p origin)
    (setf (action-origin-cleaned-p origin) t)
    (ignore-errors (delete-point (action-origin-point origin))))
  nil)

(defgeneric cleanup-action-target-payload (target)
  (:method ((target action-target)) nil))

(defmethod cleanup-action-target-payload ((target identifier-action-target))
  (ignore-errors (delete-point (identifier-action-target-point target))))

(defmethod cleanup-action-target-payload ((target location-action-target))
  (ignore-errors (delete-point (location-action-target-point target))))

(defun cleanup-action-target-payload-only (target)
  (when (and target (not (action-target-cleaned-p target)))
    (setf (action-target-cleaned-p target) t)
    (cleanup-action-target-payload target))
  nil)

(defun cleanup-action-target (target)
  "Release TARGET's copied points.  Safe to call more than once."
  (when target
    (cleanup-action-target-payload-only target)
    (cleanup-action-origin (action-target-origin target)))
  nil)

;;; --- reload-safe typed registries -----------------------------------------

(defclass action-target-provider ()
  ((id
    :initarg :id
    :reader action-target-provider-id)
   (target-type
    :initarg :target-type
    :reader action-target-provider-target-type)
   (function
    :initarg :function
    :reader action-target-provider-function)
   (priority
    :initarg :priority
    :reader action-target-provider-priority)
   (contexts
    :initarg :contexts
    :reader action-target-provider-contexts)))

(defclass action-definition ()
  ((id
    :initarg :id
    :reader action-definition-id)
   (target-type
    :initarg :target-type
    :reader action-definition-target-type)
   (key
    :initarg :key
    :reader action-definition-key)
   (label
    :initarg :label
    :reader action-definition-label)
   (function
    :initarg :function
    :reader action-definition-function)
   (availability-function
    :initarg :availability-function
    :reader action-definition-availability-function)
   (default-p
    :initarg :default-p
    :reader action-definition-default-p)))

(defvar *action-target-provider-registry* (make-hash-table :test #'eq))
(defvar *action-definition-registry* (make-hash-table :test #'eq))
(defvar *registered-builtin-action-target-provider-ids* nil)
(defvar *registered-builtin-action-definition-ids* nil)

(defun action-target-type-p (type)
  (and (symbolp type)
       (find-class type nil)
       (nth-value 0 (subtypep type 'action-target))))

(defun canonical-action-key (key)
  (let ((keys (etypecase key
                (string (lem-core::parse-keyspec key))
                (list key))))
    (unless (= 1 (length keys))
      (error "Action key must contain exactly one key: ~s" key))
    (lem-core::keyseq-to-string keys)))

(defun register-action-target-provider
    (id target-type function &key (priority 0) (contexts '(:ordinary)))
  "Register or replace one typed target provider under ID.

FUNCTION receives an ACTION-ORIGIN and returns either a TARGET-TYPE instance
or NIL.  Lower PRIORITY values run first.  Re-registering ID replaces the old
definition, which makes configuration reloads idempotent."
  (check-type id symbol)
  (check-type priority real)
  (unless (action-target-type-p target-type)
    (error "Not an action target type: ~s" target-type))
  (unless (and (listp contexts)
               (every (lambda (context)
                        (member context '(:ordinary :completion)))
                      contexts))
    (error "Invalid action target contexts: ~s" contexts))
  (setf (gethash id *action-target-provider-registry*)
        (make-instance 'action-target-provider
                       :id id
                       :target-type target-type
                       :function (alexandria:ensure-function function)
                       :priority priority
                       :contexts (remove-duplicates contexts)))
  id)

(defun register-action
    (id target-type key label function
     &key default-p (availability-function (constantly t)))
  "Register or replace one typed action under ID.

KEY must be one terminal-safe key.  Duplicate keys are allowed across disjoint
target types, but a resolved menu containing duplicates is rejected before it
is displayed."
  (check-type id symbol)
  (unless (action-target-type-p target-type)
    (error "Not an action target type: ~s" target-type))
  (check-type label string)
  (let ((key (canonical-action-key key)))
    (when (string= key "q")
      (error "q is reserved for cancelling an action menu"))
    (setf (gethash id *action-definition-registry*)
          (make-instance 'action-definition
                         :id id
                         :target-type target-type
                         :key key
                         :label label
                         :function (alexandria:ensure-function function)
                         :availability-function
                         (alexandria:ensure-function availability-function)
                         :default-p (not (null default-p)))))
  id)

(defun action-target-providers ()
  "Return the registered target providers in deterministic priority order."
  (sort (loop :for provider :being :each :hash-value
                :of *action-target-provider-registry*
              :collect provider)
        (lambda (left right)
          (or (< (action-target-provider-priority left)
                 (action-target-provider-priority right))
              (and (= (action-target-provider-priority left)
                      (action-target-provider-priority right))
                   (string< (symbol-name (action-target-provider-id left))
                            (symbol-name (action-target-provider-id right))))))))

(defun action-definitions ()
  "Return a snapshot of every registered action definition."
  (sort (loop :for action :being :each :hash-value
                :of *action-definition-registry*
              :collect action)
        #'string<
        :key (lambda (action)
               (symbol-name (action-definition-id action)))))

(defun clear-builtin-action-registrations ()
  "Remove only built-ins from a previous load; preserve third-party entries."
  (dolist (id *registered-builtin-action-target-provider-ids*)
    (remhash id *action-target-provider-registry*))
  (dolist (id *registered-builtin-action-definition-ids*)
    (remhash id *action-definition-registry*))
  (setf *registered-builtin-action-target-provider-ids* nil
        *registered-builtin-action-definition-ids* nil))

(defun register-builtin-action-target-provider
    (id target-type function &rest options)
  (apply #'register-action-target-provider id target-type function options)
  (pushnew id *registered-builtin-action-target-provider-ids*)
  id)

(defun register-builtin-action (id target-type key label function &rest options)
  (apply #'register-action id target-type key label function options)
  (pushnew id *registered-builtin-action-definition-ids*)
  id)

;;; --- target classification ------------------------------------------------

(defun action-region-bounds (buffer)
  (cond
    ((and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
          (lem-vi-mode/visual:visual-p buffer)
          (not (lem-vi-mode/visual:visual-block-p buffer)))
     (destructuring-bind (first second)
         (lem-vi-mode/visual:visual-range buffer)
       (let ((start (point-min first second))
             (end (point-max first second)))
         (unless (point= start end)
           (values start end)))))
    ((and (not (typep (current-global-mode) 'lem-vi-mode:vi-mode))
          (let* ((point (buffer-point buffer))
                 (mark (cursor-mark point)))
            (and (mark-active-p mark)
                 (mark-point mark)
                 (not (point= point (mark-point mark))))))
     (values (cursor-region-beginning (buffer-point buffer))
             (cursor-region-end (buffer-point buffer))))))

(defun region-action-target-provider (origin)
  (multiple-value-bind (start end)
      (action-region-bounds (action-origin-buffer origin))
    (when start
      (make-instance 'region-action-target
                     :origin origin
                     :text (points-to-string start end)))))

(defun find-name-action-target-provider (origin)
  (with-point ((point (action-origin-point origin)))
    (line-start point)
    (alexandria:when-let*
        ((path (text-property-at point :find-name-path))
         (existing (uiop:probe-file* path)))
      (make-instance 'file-action-target
                     :origin origin
                     :pathname existing))))

(defun peek-action-target-provider (origin)
  (alexandria:when-let
      ((move-function
         (lem/peek-source:get-move-function (action-origin-point origin))))
    (alexandria:when-let ((point (funcall move-function)))
      (when (pointp point)
        (make-instance 'location-action-target
                       :origin origin
                       :point (copy-point point :right-inserting)
                       :line (line-string point))))))

(defparameter *action-token-left-trim-characters*
  '(#\" #\' #\` #\( #\[ #\{ #\<))

(defparameter *action-token-right-trim-characters*
  '(#\" #\' #\` #\) #\] #\} #\> #\, #\; #\.))

(defun action-token-delimiter-p (character)
  (or (null character)
      (find character '(#\Space #\Tab #\Newline #\Return) :test #'char=)))

(defun action-token-at-point (point)
  (with-point ((start point)
               (end point))
    (when (and (action-token-delimiter-p (character-at start))
               (not (start-buffer-p start))
               (not (action-token-delimiter-p (character-at start -1))))
      (character-offset start -1)
      (move-point end start))
    (unless (action-token-delimiter-p (character-at start))
      (skip-chars-backward start (complement #'action-token-delimiter-p))
      (skip-chars-forward end (complement #'action-token-delimiter-p))
      (string-left-trim
       *action-token-left-trim-characters*
       (string-right-trim *action-token-right-trim-characters*
                          (points-to-string start end))))))

(defun http-url-p (string)
  (and (stringp string)
       (or (alexandria:starts-with-subseq "http://" string
                                         :test #'char-equal)
           (alexandria:starts-with-subseq "https://" string
                                         :test #'char-equal))
       (> (length string)
          (if (char-equal (char string 4) #\s) 8 7))))

(defun action-token-pathname (token buffer)
  (let ((token (if (and (<= 5 (length token))
                        (string-equal "file:" token :end2 5))
                   (subseq token 5)
                   token)))
    (when (plusp (length token))
      (ignore-errors
        (uiop:probe-file*
         (expand-file-name token (buffer-directory buffer)))))))

(defun token-action-target-provider (origin)
  (alexandria:when-let ((token (action-token-at-point
                                (action-origin-point origin))))
    (cond
      ((http-url-p token)
       (make-instance 'url-action-target
                      :origin origin
                      :url token))
      ((alexandria:when-let
           ((path (action-token-pathname token (action-origin-buffer origin))))
         (make-instance 'file-action-target
                        :origin origin
                        :pathname path))))))

(defun syntax-identifier-character-p (character)
  (and character (syntax-symbol-char-p character)))

(defun identifier-at-point (point)
  (with-point ((start point)
               (end point))
    (when (and (not (syntax-identifier-character-p (character-at start)))
               (not (start-buffer-p start))
               (syntax-identifier-character-p (character-at start -1)))
      (character-offset start -1)
      (move-point end start))
    (when (syntax-identifier-character-p (character-at start))
      (skip-chars-backward start #'syntax-identifier-character-p)
      (skip-chars-forward end #'syntax-identifier-character-p)
      (let ((text (points-to-string start end)))
        (unless (zerop (length text)) text)))))

(defun identifier-action-target-provider (origin)
  (let ((point (copy-point (action-origin-point origin) :right-inserting)))
    (unwind-protect
         (progn
           ;; Keep handlers inside the identifier when point is immediately
           ;; after it (for example, on trailing whitespace or at EOF).
           (when (and (not (syntax-identifier-character-p
                            (character-at point)))
                      (not (start-buffer-p point))
                      (syntax-identifier-character-p
                       (character-at point -1)))
             (character-offset point -1))
           (alexandria:when-let ((text (identifier-at-point point)))
             (prog1
                 (make-instance 'identifier-action-target
                                :origin origin
                                :text text
                                :point point)
               (setf point nil))))
      (when point
        (ignore-errors (delete-point point))))))

(defun buffer-action-target-provider (origin)
  (make-instance 'buffer-action-target
                 :origin origin
                 :buffer (action-origin-buffer origin)))

(defun completion-action-target-current-p (target)
  (let ((context (completion-action-target-context target))
        (item (completion-action-target-item target)))
    (and (not (action-target-cleaned-p target))
         (eq context lem/completion-mode::*completion-context*)
         (eq (action-origin-buffer (action-target-origin target))
             (lem/completion-mode::context-buffer context))
         (= (completion-action-target-generation target)
            (lem/completion-mode::context-generation context))
         (= (completion-action-target-generation target)
            (lem/completion-mode::context-presented-generation context))
         (alexandria:when-let
             ((popup (lem/completion-mode::context-popup-menu context)))
           (eq item (lem/popup-menu:get-focus-item popup))))))

(defun completion-action-target-provider (origin)
  (alexandria:when-let*
      ((context lem/completion-mode::*completion-context*)
       (popup (lem/completion-mode::context-popup-menu context))
       (item (lem/popup-menu:get-focus-item popup)))
    (let ((generation (lem/completion-mode::context-generation context)))
      (when (and (typep item 'lem/completion-mode:completion-item)
                 (eq (action-origin-buffer origin)
                     (lem/completion-mode::context-buffer context))
                 (= generation
                    (lem/completion-mode::context-presented-generation context)))
        (make-instance 'completion-action-target
                       :origin origin
                       :context context
                       :item item
                       :generation generation
                       :text
                       (lem/completion-mode:completion-item-insert-text item))))))

(defun call-action-target-provider (provider origin)
  (unwind-protect
       (handler-case
           (let ((target (funcall (action-target-provider-function provider)
                                  origin)))
             (cond
               ((null target) nil)
               ((typep target (action-target-provider-target-type provider))
                (if (eq origin (action-target-origin target))
                    target
                    (progn
                      (message "Action target provider ~a returned a target with the wrong origin"
                               (action-target-provider-id provider))
                      nil)))
               (t
                (message "Action target provider ~a returned ~s, not ~a"
                         (action-target-provider-id provider)
                         target
                         (action-target-provider-target-type provider))
                nil)))
         (editor-abort (condition) (error condition))
         (error (condition)
           (message "Action target provider ~a failed: ~a"
                    (action-target-provider-id provider) condition)
           nil))
    (when (action-origin-live-p origin)
      (ignore-errors (restore-action-origin origin)))))

(defun detect-action-target (&key (origin (snapshot-action-origin))
                                  (context :ordinary))
  "Return the first target for CONTEXT, transferring ownership of ORIGIN.

On failure ORIGIN is cleaned before NIL is returned."
  (let ((origin-transferred-p nil))
    (unwind-protect
         (let ((target
                 (loop :for provider :in (action-target-providers)
                       :when (member context
                                     (action-target-provider-contexts provider))
                         :do (alexandria:when-let
                                 ((candidate
                                    (call-action-target-provider provider origin)))
                               (return candidate)))))
           (when target
             (setf origin-transferred-p t))
           target)
      (unless origin-transferred-p
        (cleanup-action-origin origin)))))

(defun unique-action-targets (targets)
  "Keep the first target for each typed identity and release duplicate payloads."
  (let ((seen (make-hash-table :test #'equal))
        (result nil))
    (dolist (target targets (nreverse result))
      (let ((identity (action-target-identity target)))
        (if (gethash identity seen)
            (cleanup-action-target-payload-only target)
            (progn
              (setf (gethash identity seen) t)
              (push target result)))))))

(defun detect-action-targets (&key (origin (snapshot-action-origin))
                                   (context :ordinary))
  "Return every unique target for CONTEXT in provider priority order.

The returned targets share and jointly own ORIGIN.  If classification aborts,
all copied payload points and ORIGIN are released before the condition escapes."
  (let ((targets nil)
        (origin-transferred-p nil))
    (unwind-protect
         (progn
           (dolist (provider (action-target-providers))
             (when (member context
                           (action-target-provider-contexts provider))
               (alexandria:when-let
                   ((target (call-action-target-provider provider origin)))
                 (push target targets))))
           (setf targets (unique-action-targets (nreverse targets)))
           (when targets
             (setf origin-transferred-p t))
           targets)
      (unless origin-transferred-p
        (dolist (target targets)
          (cleanup-action-target-payload-only target))
        (cleanup-action-origin origin)))))

(defun detect-completion-action-target ()
  (detect-action-target :context :completion))

;;; --- action resolution and one-key transient ------------------------------

(defun action-definition-available-p (action target)
  (and (typep target (action-definition-target-type action))
       (handler-case
           (not (null
                 (funcall (action-definition-availability-function action)
                          target)))
         (editor-abort (condition) (error condition))
         (error (condition)
           (message "Action availability check ~a failed: ~a"
                    (action-definition-id action) condition)
           nil))))

(defun validate-action-keys (actions)
  (let ((seen (make-hash-table :test #'equal))
        (default nil))
    (dolist (action actions)
      (let* ((key (action-definition-key action))
             (previous (gethash key seen)))
        (when previous
          (editor-error "Duplicate action key ~a: ~a and ~a"
                        key
                        (action-definition-id previous)
                        (action-definition-id action)))
        (setf (gethash key seen) action))
      (when (action-definition-default-p action)
        (when default
          (editor-error "Multiple default actions: ~a and ~a"
                        (action-definition-id default)
                        (action-definition-id action)))
        (setf default action)))
    actions))

(defun actions-for-target (target)
  "Resolve and validate the currently available actions for TARGET."
  (let ((actions
          (remove-if-not (lambda (action)
                           (action-definition-available-p action target))
                         (action-definitions))))
    (validate-action-keys actions)
    (stable-sort
     actions
     (lambda (left right)
       (cond
         ((and (action-definition-default-p left)
               (not (action-definition-default-p right)))
          t)
         ((action-definition-default-p right) nil)
         (t (string< (action-definition-key left)
                     (action-definition-key right))))))))

(defparameter *action-target-cycle-key* "Space e a")

(defun build-action-keymap
    (target &optional (actions (actions-for-target target))
                      target-number target-count)
  "Build a fresh transient keymap for TARGET's resolved action set."
  (let ((keymap
          (make-keymap
           :description
           (if (and target-number target-count (> target-count 1))
               (format nil "[~d/~d] ~a" target-number target-count
                       (action-target-summary target))
               (action-target-summary target)))))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist (action actions)
      (define-key keymap (action-definition-key action) 'nop-command)
      (setf (lem-core::prefix-description
             (lem-core::keymap-find
              keymap
              (lem-core::parse-keyspec (action-definition-key action))))
            (action-definition-label action)))
    (define-key keymap "q" 'nop-command)
    (setf (lem-core::prefix-description
           (lem-core::keymap-find keymap (lem-core::parse-keyspec "q")))
          "cancel")
    (when (and target-count (> target-count 1))
      (define-key keymap *action-target-cycle-key* 'nop-command)
      (setf (lem-core::prefix-description
             (lem-core::keymap-find
              keymap (lem-core::parse-keyspec *action-target-cycle-key*)))
            "next target"))
    keymap))

(defun invoke-action-by-key
    (target key &optional (actions (actions-for-target target)))
  "Invoke TARGET's action bound to KEY without reading editor input.

Returns :INVOKED, :FAILED, :CANCELLED, or NIL for an unbound key.  TARGET
ownership remains with the caller, allowing this function to serve as a
non-interactive test and extension hook."
  (let ((key (canonical-action-key key)))
    (cond
      ((string= key "q") :cancelled)
      (t
       (alexandria:when-let
           ((action (find key actions
                          :key #'action-definition-key
                          :test #'string=)))
         (handler-case
             (progn
               (restore-action-origin (action-target-origin target))
               (funcall (action-definition-function action) target)
               :invoked)
           (editor-abort (condition) (error condition))
           (error (condition)
             (when (action-origin-live-p (action-target-origin target))
               (ignore-errors
                 (restore-action-origin (action-target-origin target))))
             (message "Action ~a failed: ~a"
                      (action-definition-label action) condition)
             :failed)))))))

(defun dispatch-action-targets (targets)
  "Display and dispatch TARGETS, cycling with the invoking leader chord."
  (let ((targets (copy-list targets)))
    (unless targets
      (return-from dispatch-action-targets nil))
    (let ((index 0)
          (count (length targets)))
      (unwind-protect
           (loop
             (let* ((target (nth index targets))
                    (actions (actions-for-target target))
                    (keymap (build-action-keymap
                             target actions (1+ index) count)))
               (let ((lem/transient:*transient-popup-delay* 0))
                 (keymap-activate keymap))
               (redraw-display)
               (let* ((key-sequence (read-key-sequence))
                      (key-name
                        (lem-core::keyseq-to-string key-sequence)))
                 (lem/transient::hide-transient)
                 (cond
                   ((and (> count 1)
                         (string= key-name *action-target-cycle-key*))
                    (setf index (mod (1+ index) count)))
                   (t
                    (let ((result
                            (and (= 1 (length key-sequence))
                                 (invoke-action-by-key
                                  target key-sequence actions))))
                      (unless result
                        (message "No action is bound to ~a" key-name))
                      (return result)))))))
        (lem/transient::hide-transient)
        (mapc #'cleanup-action-target targets)))))

(defun dispatch-action-target (target)
  "Display TARGET's dynamic transient, read one action, and dispatch it."
  (dispatch-action-targets (list target)))

(define-command lem-yath-act () ()
  "Act on a region, object, identifier, or buffer target at point."
  (alexandria:when-let ((targets (detect-action-targets)))
    (dispatch-action-targets targets)))

(define-command lem-yath-act-completion () ()
  "Act on the currently focused, still-valid completion item."
  (alexandria:if-let ((target (detect-completion-action-target)))
    (dispatch-action-target target)
    (message "There is no focused completion item to act on")))

;;; --- built-in actions ------------------------------------------------------

(defun action-copy (text description)
  (copy-to-clipboard-with-killring text)
  (message "Copied ~a" description))

(defun open-with-xdg (target)
  "Open TARGET with xdg-open using an argv vector, never a shell."
  (alexandria:if-let ((xdg-open (executable-find "xdg-open")))
    (progn
      (uiop:launch-program
       (list (uiop:native-namestring xdg-open) target)
       :input nil
       :output nil
       :error-output nil)
      (message "Opened externally: ~a" target))
    (editor-error "xdg-open is not available")))

(defun action-copy-region (target)
  (action-copy (region-action-target-text target) "region"))

(defun action-open-url (target)
  (let ((url (url-action-target-url target)))
    (unless (http-url-p url)
      (editor-error "The URL target is no longer valid"))
    (open-with-xdg url)))

(defun action-copy-url (target)
  (action-copy (url-action-target-url target) "URL"))

(defun live-file-action-pathname (target)
  (or (uiop:probe-file* (file-action-target-pathname target))
      (editor-error "The file target no longer exists: ~a"
                    (file-action-target-pathname target))))

(defun action-visit-file (target)
  (find-file (live-file-action-pathname target)))

(defun action-copy-file-path (target)
  (action-copy
   (uiop:native-namestring (file-action-target-pathname target))
   "path"))

(defun action-open-file-externally (target)
  (open-with-xdg
   (uiop:native-namestring (live-file-action-pathname target))))

(declaim (ftype function identifier-action-target-current-p))

(defun identifier-action-handler (target variable description)
  (unless (identifier-action-target-current-p target)
    (editor-error "The identifier target changed while choosing an action"))
  (let* ((point (identifier-action-target-point target))
         (function (variable-value variable :buffer point)))
    (unless function
      (editor-error "No ~a provider is active" description))
    (funcall (alexandria:ensure-function function) point)))

(defun identifier-action-target-current-p (target)
  (let* ((origin (action-target-origin target))
         (buffer (action-origin-buffer origin))
         (point (identifier-action-target-point target)))
    (and (action-origin-live-p origin)
         (= (action-origin-tick origin) (buffer-modified-tick buffer))
         (ignore-errors (eq (point-buffer point) buffer))
         (with-current-buffer buffer
           (equal (identifier-action-target-text target)
                  (identifier-at-point point))))))

(defun identifier-definition-available-p (target)
  (and (identifier-action-target-current-p target)
       (not (null (variable-value
                   'lem/language-mode:find-definitions-function
                   :buffer (identifier-action-target-point target))))))

(defun identifier-reference-available-p (target)
  (and (identifier-action-target-current-p target)
       (not (null (variable-value
                   'lem/language-mode:find-references-function
                   :buffer (identifier-action-target-point target))))))

(defun action-find-identifier-definitions (target)
  (identifier-action-handler
   target 'lem/language-mode:find-definitions-function "definition"))

(defun action-find-identifier-references (target)
  (identifier-action-handler
   target 'lem/language-mode:find-references-function "reference"))

(defun action-copy-identifier (target)
  (unless (identifier-action-target-current-p target)
    (editor-error "The identifier target changed while choosing an action"))
  (action-copy (identifier-action-target-text target) "identifier"))

(defun identifier-current-lsp-action-p (target)
  (let* ((origin (action-target-origin target))
         (buffer (action-origin-buffer origin))
         (workspace (and (action-origin-current-p origin :unchanged t)
                         (ignore-errors
                           (lem-lsp-mode::buffer-workspace buffer)))))
    (and (identifier-action-target-current-p target)
         workspace
         (eq :ready (ignore-errors
                      (lem-lsp-mode::workspace-state workspace)))
         (ignore-errors (lem-lsp-mode::provide-code-action-p workspace)))))

(defun action-lsp-code-actions (target)
  (unless (identifier-current-lsp-action-p target)
    (editor-error "The identifier is no longer current in a ready LSP workspace"))
  (with-buffer-point ((action-origin-buffer (action-target-origin target))
                      (identifier-action-target-point target))
    (lem-lsp-mode::lsp-code-action)))

(defun action-location-live-p (target)
  (and (action-buffer-live-p
        (point-buffer (location-action-target-point target)))
       (not (action-target-cleaned-p target))))

(defun action-visit-location (target)
  (unless (action-location-live-p target)
    (editor-error "The location target no longer exists"))
  (let* ((point (location-action-target-point target))
         (buffer (point-buffer point))
         (origin-buffer
           (action-origin-buffer (action-target-origin target))))
    (when (mode-active-p origin-buffer 'lem/peek-source::peek-source-mode)
      (lem/peek-source::peek-source-quit))
    (switch-to-buffer buffer)
    (move-point (current-point) point)
    (lem/peek-source:highlight-matched-line (current-point))))

(defun action-copy-location-line (target)
  (action-copy (location-action-target-line target) "line"))

(defun action-buffer-live-target-p (target)
  (action-buffer-live-p (buffer-action-target-buffer target)))

(defun action-buffer-file-p (target)
  (and (action-buffer-live-target-p target)
       (buffer-filename (buffer-action-target-buffer target))))

(defun action-buffer-revertable-p (target)
  (and (action-buffer-live-target-p target)
       (or (buffer-filename (buffer-action-target-buffer target))
           (lem-core/commands/file:revert-buffer-function
            (buffer-action-target-buffer target)))))

(defun action-save-buffer (target)
  (let ((buffer (buffer-action-target-buffer target)))
    (unless (action-buffer-live-p buffer)
      (editor-error "The buffer target no longer exists"))
    (alexandria:if-let ((filename (save-buffer buffer)))
      (message "Wrote ~a" filename)
      (message "Buffer is already saved"))))

(defun action-revert-buffer (target)
  (let ((buffer (buffer-action-target-buffer target)))
    (unless (action-buffer-live-p buffer)
      (editor-error "The buffer target no longer exists"))
    (unless (eq buffer (current-buffer))
      (switch-to-buffer buffer))
    (lem-core/commands/file:revert-buffer nil)))

(defun action-kill-buffer (target)
  (let ((buffer (buffer-action-target-buffer target)))
    (unless (action-buffer-live-p buffer)
      (editor-error "The buffer target no longer exists"))
    (kill-buffer buffer)))

(defun action-kill-buffer-available-p (target)
  (and (action-buffer-live-target-p target)
       (cdr (buffer-list))))

(defun action-copy-buffer (target)
  (let ((buffer (buffer-action-target-buffer target)))
    (unless (action-buffer-live-p buffer)
      (editor-error "The buffer target no longer exists"))
    (action-copy (buffer-name buffer) "buffer name")))

(defun action-accept-completion (target)
  (unless (completion-action-target-current-p target)
    (editor-error "The focused completion item changed while choosing an action"))
  (lem/completion-mode::completion-accept
   (current-point)
   (completion-action-target-item target)))

(defun action-copy-completion (target)
  (unless (completion-action-target-current-p target)
    (editor-error "The focused completion item changed while choosing an action"))
  (action-copy (completion-action-target-text target) "completion"))

(defun action-native-context-menu-available-p (target)
  (and (not (typep target 'completion-action-target))
       (action-origin-live-p (action-target-origin target))
       (lem-core::buffer-context-menu
        (action-origin-buffer (action-target-origin target)))))

(defun action-native-context-menu (target)
  (let* ((origin (action-target-origin target))
         (buffer (action-origin-buffer origin))
         (context-menu (lem-core::buffer-context-menu buffer)))
    (unless context-menu
      (editor-error "This mode has no native context menu"))
    (lem-core::update-point-on-context-menu-open (current-point))
    (lem-if:display-context-menu
     (implementation) context-menu '(:gravity :cursor))))

(clear-builtin-action-registrations)

;; Target priority is an explicit part of the user-facing contract.
(register-builtin-action-target-provider
 'region 'region-action-target #'region-action-target-provider :priority 10)
(register-builtin-action-target-provider
 'find-name 'file-action-target #'find-name-action-target-provider :priority 20)
(register-builtin-action-target-provider
 'peek-location 'location-action-target #'peek-action-target-provider :priority 30)
(register-builtin-action-target-provider
 'url-or-file-token 'action-target #'token-action-target-provider :priority 40)
(register-builtin-action-target-provider
 'identifier 'identifier-action-target #'identifier-action-target-provider
 :priority 50)
(register-builtin-action-target-provider
 'buffer 'buffer-action-target #'buffer-action-target-provider :priority 60)
(register-builtin-action-target-provider
 'completion 'completion-action-target #'completion-action-target-provider
 :priority 0 :contexts '(:completion))

(register-builtin-action
 'region-copy 'region-action-target "w" "copy region" #'action-copy-region)

(register-builtin-action
 'url-open 'url-action-target "Return" "open URL" #'action-open-url
 :default-p t)
(register-builtin-action
 'url-copy 'url-action-target "w" "copy URL" #'action-copy-url)

(register-builtin-action
 'file-visit 'file-action-target "Return" "visit file" #'action-visit-file
 :default-p t)
(register-builtin-action
 'file-copy 'file-action-target "w" "copy path" #'action-copy-file-path)
(register-builtin-action
 'file-external 'file-action-target "x" "open externally"
 #'action-open-file-externally)

(register-builtin-action
 'identifier-definitions 'identifier-action-target "d" "find definitions"
 #'action-find-identifier-definitions
 :availability-function #'identifier-definition-available-p)
(register-builtin-action
 'identifier-references 'identifier-action-target "r" "find references"
 #'action-find-identifier-references
 :availability-function #'identifier-reference-available-p)
(register-builtin-action
 'identifier-copy 'identifier-action-target "w" "copy identifier"
 #'action-copy-identifier
 :availability-function #'identifier-action-target-current-p)
(register-builtin-action
 'identifier-code-actions 'identifier-action-target "a" "LSP code actions"
 #'action-lsp-code-actions
 :availability-function #'identifier-current-lsp-action-p)

(register-builtin-action
 'location-visit 'location-action-target "Return" "visit location"
 #'action-visit-location :default-p t
 :availability-function #'action-location-live-p)
(register-builtin-action
 'location-copy 'location-action-target "w" "copy line"
 #'action-copy-location-line)

(register-builtin-action
 'buffer-save 'buffer-action-target "s" "save buffer" #'action-save-buffer
 :availability-function #'action-buffer-file-p)
(register-builtin-action
 'buffer-revert 'buffer-action-target "r" "revert buffer" #'action-revert-buffer
 :availability-function #'action-buffer-revertable-p)
(register-builtin-action
 'buffer-kill 'buffer-action-target "k" "kill buffer" #'action-kill-buffer
 :availability-function #'action-kill-buffer-available-p)
(register-builtin-action
 'buffer-copy 'buffer-action-target "w" "copy buffer" #'action-copy-buffer
 :availability-function #'action-buffer-live-target-p)

(register-builtin-action
 'completion-accept 'completion-action-target "Return" "accept completion"
 #'action-accept-completion :default-p t
 :availability-function #'completion-action-target-current-p)
(register-builtin-action
 'completion-copy 'completion-action-target "w" "copy completion"
 #'action-copy-completion
 :availability-function #'completion-action-target-current-p)

(register-builtin-action
 'native-context-menu 'action-target "m" "mode context menu"
 #'action-native-context-menu
 :availability-function #'action-native-context-menu-available-p)

;; Completion is the only place this module owns a keymap directly.  The
;; ordinary SPC binding lives in the shared normal/visual leader declaration.
(define-key lem/completion-mode::*completion-mode-keymap*
  "C-c a" 'lem-yath-act-completion)
