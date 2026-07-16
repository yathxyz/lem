;;;; Editable Org capture sessions for the configured i/t/p/r templates.
;;;; notes.lisp owns pathname and pure placement policy; this module owns the
;;;; transient template selector, context rendering, finalize, and abort UI.

(in-package :lem-yath)

(eval-when (:load-toplevel :execute)
  (when (fboundp 'org-capture-cleanup-for-reload)
    (org-capture-cleanup-for-reload)))

(defparameter *org-capture-buffer-name* "*Org Capture*")
(defparameter *org-capture-buffer-character-limit* (* 1024 1024))
(defparameter *org-capture-time-function* #'get-universal-time)
(defparameter *org-capture-id-function* #'uuid-v4)

(defvar *org-capture-mode-keymap* (make-keymap))
(defvar *org-capture-template-mode-keymap* (make-keymap))
(defvar *org-capture-session* nil)
(defvar *org-capture-request* nil)

(defstruct org-capture-request
  origin-buffer
  origin-window
  origin-point
  origin-state
  initial-text
  annotation)

(defstruct org-capture-session
  request
  template
  capture-buffer
  closing-p)

(define-minor-mode lem-yath-org-capture-mode
    (:name "Org-Capture"
     :description "Finalize or abort an active Org capture"
     :keymap *org-capture-mode-keymap*))

(define-minor-mode lem-yath-org-capture-template-mode
    (:name "Org-Capture-Template"
     :description "Select an Org capture template"
     :keymap *org-capture-template-mode-keymap*
     :hide-from-modeline t))

(defun org-capture-live-buffer-p (buffer)
  (and (bufferp buffer) (not (deleted-buffer-p buffer))))

(defun org-capture-request-origin-live-p (request)
  (let ((buffer (org-capture-request-origin-buffer request))
        (point (org-capture-request-origin-point request)))
    (and (org-capture-live-buffer-p buffer)
         point
         (ignore-errors (eq (point-buffer point) buffer)))))

(defun org-capture-active-region-text (buffer)
  (multiple-value-bind (start end) (action-region-bounds buffer)
    (if start (points-to-string start end) "")))

(defun org-capture-link-escape (text)
  (with-output-to-string (output)
    (loop :for character :across text
          :do (progn
                (when (member character '(#\\ #\]))
                  (write-char #\\ output))
                (write-char character output)))))

(defun org-capture-origin-annotation (buffer point)
  "Return the useful local-file subset of Org capture's %a annotation."
  (alexandria:when-let ((filename (ignore-errors (buffer-filename buffer))))
    (let* ((path (uiop:native-namestring (pathname filename)))
           (line (line-number-at-point point))
           (label (format nil "~a:~d" (file-namestring path) line)))
      (format nil "[[file:~a::~d][~a]]"
              (org-capture-link-escape path) line
              (org-capture-link-escape label)))))

(defun org-capture-restore-origin (request)
  (unless (org-capture-request-origin-live-p request)
    (editor-error "The Org capture origin no longer exists."))
  (let ((window (org-capture-request-origin-window request))
        (buffer (org-capture-request-origin-buffer request)))
    (when (and window (not (deleted-window-p window)))
      (setf (current-window) window))
    (unless (eq (current-buffer) buffer)
      (switch-to-buffer buffer nil nil))
    (move-point (current-point) (org-capture-request-origin-point request))
    (alexandria:when-let ((state (org-capture-request-origin-state request)))
      (setf (lem-vi-mode/core:current-state) state))))

(defun org-capture-release-request-point (request)
  (alexandria:when-let ((point (org-capture-request-origin-point request)))
    (ignore-errors (delete-point point))
    (setf (org-capture-request-origin-point request) nil)))

(defun org-capture-disable-template-mode (request)
  (let ((buffer (org-capture-request-origin-buffer request)))
    (when (org-capture-live-buffer-p buffer)
      (with-current-buffer buffer
        (remove-hook (variable-value 'kill-buffer-hook :buffer buffer)
                     'org-capture-origin-kill-buffer-hook)
        (when (mode-active-p buffer 'lem-yath-org-capture-template-mode)
          (lem-yath-org-capture-template-mode nil))))))

(defun org-capture-disable-session (session)
  (let* ((request (org-capture-session-request session))
         (origin (org-capture-request-origin-buffer request))
         (capture (org-capture-session-capture-buffer session)))
    (when (org-capture-live-buffer-p origin)
      (with-current-buffer origin
        (remove-hook (variable-value 'kill-buffer-hook :buffer origin)
                     'org-capture-origin-kill-buffer-hook)))
    (when (org-capture-live-buffer-p capture)
      (with-current-buffer capture
        (remove-hook (variable-value 'kill-buffer-hook :buffer capture)
                     'org-capture-buffer-kill-hook)
        (setf (buffer-value capture 'lem-yath-org-capture-session) nil)
        (when (mode-active-p capture 'lem-yath-org-capture-mode)
          (lem-yath-org-capture-mode nil))))))

(defun org-capture-clear-request (request)
  (org-capture-disable-template-mode request)
  (org-capture-release-request-point request)
  (when (eq *org-capture-request* request)
    (setf *org-capture-request* nil)))

(defun org-capture-clear-session (session)
  (unless (org-capture-session-closing-p session)
    (setf (org-capture-session-closing-p session) t)
    (org-capture-disable-session session)
    (org-capture-release-request-point (org-capture-session-request session))
    (when (eq *org-capture-session* session)
      (setf *org-capture-session* nil))))

(defun org-capture-buffer-kill-hook (&optional (buffer (current-buffer)))
  (alexandria:when-let
      ((session (buffer-value buffer 'lem-yath-org-capture-session)))
    (unless (org-capture-session-closing-p session)
      (setf (org-capture-session-closing-p session) t)
      (let ((request (org-capture-session-request session)))
        (when (org-capture-request-origin-live-p request)
          (ignore-errors (org-capture-restore-origin request)))
        (org-capture-disable-session session)
        (org-capture-release-request-point request)
        (when (eq *org-capture-session* session)
          (setf *org-capture-session* nil))))))

(defun org-capture-origin-kill-buffer-hook (&optional (buffer (current-buffer)))
  (cond
    ((and *org-capture-request*
          (eq buffer (org-capture-request-origin-buffer
                      *org-capture-request*)))
     (let ((request *org-capture-request*))
       (org-capture-clear-request request)))
    ((and *org-capture-session*
          (eq buffer
              (org-capture-request-origin-buffer
               (org-capture-session-request *org-capture-session*))))
     (let* ((session *org-capture-session*)
            (capture (org-capture-session-capture-buffer session)))
       (org-capture-clear-session session)
       (when (org-capture-live-buffer-p capture)
         (with-global-variable-value (kill-buffer-hook nil)
           (delete-buffer capture)))))))

(defun org-capture-template-message ()
  (message "Org capture: [i] Inbox  [t] TODO  [p] Public TODO  [r] Reading  [C-g] cancel"))

(defun org-capture-render-entry (template request)
  "Return TEMPLATE's editable capture text and the %? character offset."
  (destructuring-bind (key label root file prefix placement) template
    (declare (ignore key label root file))
    (let* ((publicp (eq placement :file))
           (stars (if publicp "*" "**"))
           (heading-prefix (format nil "~a ~@[~a~]" stars prefix))
           (timestamp
             (inactive-org-timestamp (funcall *org-capture-time-function*)))
           (id (and publicp (funcall *org-capture-id-function*)))
           (initial (or (org-capture-request-initial-text request) ""))
           (annotation (or (org-capture-request-annotation request) ""))
           (text
             (with-output-to-string (stream)
               (format stream "~a~%:PROPERTIES:~%" heading-prefix)
               (when id (format stream ":ID: ~a~%" id))
               (format stream ":CREATED: ~a~%:END:~%~a~%~a~%"
                       timestamp initial annotation))))
      (values text (length heading-prefix)))))

(defun org-capture-buffer-text (buffer)
  (let ((characters (- (position-at-point (buffer-end-point buffer))
                       (position-at-point (buffer-start-point buffer)))))
    (when (> characters *org-capture-buffer-character-limit*)
      (editor-error "The Org capture exceeds the ~d-character safety limit."
                    *org-capture-buffer-character-limit*))
    (let ((text (points-to-string (buffer-start-point buffer)
                                  (buffer-end-point buffer))))
      (when (> (length (babel:string-to-octets text :encoding :utf-8))
               *org-capture-buffer-character-limit*)
        (editor-error "The UTF-8 Org capture exceeds the safety limit."))
      text)))

(defun org-capture-insertion (contents template fragment)
  "Return the character position and exact insertion for FRAGMENT."
  (destructuring-bind (key label root file prefix placement) template
    (declare (ignore key label root file prefix))
    (ecase placement
      (:file
       (values (length contents)
               (concatenate 'string
                            (blank-line-separator contents) fragment)))
      (:inbox
       (multiple-value-bind (position foundp)
           (inbox-subtree-insertion-position contents)
         (if foundp
             (let ((before (subseq contents 0 position))
                   (after (subseq contents position)))
               (values position
                       (concatenate 'string
                                    (blank-line-separator before)
                                    fragment
                                    (if (zerop (length after))
                                        ""
                                        (string #\Newline)))))
             (values (length contents)
                     (concatenate 'string
                                  (blank-line-separator contents)
                                  (format nil "* Inbox~%~%")
                                  fragment))))))))

(defun org-capture-insert-and-save (session)
  "Insert the edited capture into the live target buffer and save it."
  (let* ((template (org-capture-session-template session))
         (path (capture-target-path template))
         (fragment
           (org-capture-buffer-text
            (org-capture-session-capture-buffer session))))
    (ensure-directories-exist path)
    (let ((buffer (find-file-buffer path)))
      (with-current-buffer buffer
        (when (buffer-read-only-p buffer)
          (editor-error "The Org capture target is read-only: ~a" path))
        (let ((contents (buffer-text buffer))
              (original-modified-p (buffer-modified-p buffer)))
          (multiple-value-bind (position insertion-text)
              (org-capture-insertion contents template fragment)
            (with-point ((insertion (buffer-start-point buffer)))
              (character-offset insertion position)
              (with-point ((start insertion :left-inserting)
                           (end insertion :right-inserting))
                (insert-string insertion insertion-text)
                (handler-case
                    (save-buffer buffer)
                  (error (condition)
                    (delete-between-points start end)
                    (unless original-modified-p (buffer-mark-saved buffer))
                    (error condition))))))))
      path)))

(defun org-capture-open-session (request template)
  (let ((buffer nil)
        (session nil)
        (owned-buffer-p nil)
        (opened-p nil))
    (unwind-protect
         (progn
           (when (find *org-capture-buffer-name* (buffer-list)
                       :key #'buffer-name :test #'string=)
             (editor-error "The private Org capture buffer name is already in use."))
           (setf buffer (make-buffer *org-capture-buffer-name*))
           (setf owned-buffer-p t)
           (with-buffer-read-only buffer nil
             (erase-buffer buffer)
             (change-buffer-mode buffer 'org-mode)
             (multiple-value-bind (text cursor)
                 (org-capture-render-entry template request)
               (insert-string (buffer-start-point buffer) text)
               (buffer-start (buffer-point buffer))
               (character-offset (buffer-point buffer) cursor)))
           (setf session
                 (make-org-capture-session
                  :request request :template template :capture-buffer buffer)
                 *org-capture-session* session
                 (buffer-value buffer 'lem-yath-org-capture-session) session)
           (add-hook (variable-value 'kill-buffer-hook :buffer buffer)
                     'org-capture-buffer-kill-hook)
           (add-hook
            (variable-value
             'kill-buffer-hook
             :buffer (org-capture-request-origin-buffer request))
            'org-capture-origin-kill-buffer-hook)
           (switch-to-buffer buffer nil nil)
           (lem-yath-org-capture-mode t)
           (setf (buffer-minor-modes buffer)
                 (cons 'lem-yath-org-capture-mode
                       (remove 'lem-yath-org-capture-mode
                               (buffer-minor-modes buffer))))
           (setf (lem-vi-mode/core:buffer-state buffer)
                 'lem-vi-mode/states:insert
                 opened-p t)
           (message "Org capture: C-c C-c finalizes; C-c C-k aborts."))
      (unless opened-p
        (when (org-capture-request-origin-live-p request)
          (ignore-errors (org-capture-restore-origin request)))
        (when session (org-capture-clear-session session))
        (when (and owned-buffer-p buffer
                   (org-capture-live-buffer-p buffer))
          (with-global-variable-value (kill-buffer-hook nil)
            (delete-buffer buffer)))
        (unless session (org-capture-release-request-point request))))))

(defun org-capture-select-template (key)
  (let ((request *org-capture-request*)
        (template (capture-template-for-key key)))
    (unless (and request template)
      (editor-error "There is no matching pending Org capture template."))
    (unless (and (org-capture-request-origin-live-p request)
                 (eq (current-buffer)
                     (org-capture-request-origin-buffer request)))
      (editor-error "The pending Org capture is no longer at its origin."))
    (org-capture-disable-template-mode request)
    (setf *org-capture-request* nil)
    (org-capture-open-session request template)))

(define-command lem-yath-org-capture-template-inbox () ()
  (org-capture-select-template "i"))
(define-command lem-yath-org-capture-template-todo () ()
  (org-capture-select-template "t"))
(define-command lem-yath-org-capture-template-public () ()
  (org-capture-select-template "p"))
(define-command lem-yath-org-capture-template-reading () ()
  (org-capture-select-template "r"))

(define-command lem-yath-org-capture-template-abort () ()
  "Abort a pending Org capture before a target template is selected."
  (let ((request *org-capture-request*))
    (unless request
      (editor-error "There is no pending Org capture template."))
    (when (org-capture-request-origin-live-p request)
      (org-capture-restore-origin request))
    (org-capture-clear-request request)
    (message "Org capture cancelled.")))

(define-command lem-yath-org-capture-save-guard () ()
  (editor-error "Use C-c C-c to finalize or C-c C-k to abort this capture."))

(define-command lem-yath-org-capture-finalize () ()
  "Write the edited capture fragment and restore the exact origin."
  (let ((session *org-capture-session*))
    (unless (and session
                 (eq (current-buffer)
                     (org-capture-session-capture-buffer session)))
      (editor-error "There is no active Org capture in this buffer."))
    (let ((request (org-capture-session-request session))
          (capture (org-capture-session-capture-buffer session))
          (path nil))
      (unless (org-capture-request-origin-live-p request)
        (editor-error "The Org capture origin no longer exists."))
      (setf path (org-capture-insert-and-save session))
      (org-capture-restore-origin request)
      (org-capture-clear-session session)
      (when (org-capture-live-buffer-p capture)
        (with-global-variable-value (kill-buffer-hook nil)
          (delete-buffer capture)))
      (message "Captured to ~a" (file-namestring path)))))

(define-command lem-yath-org-capture-abort () ()
  "Discard the active capture buffer and restore the exact origin."
  (let ((session *org-capture-session*))
    (unless (and session
                 (eq (current-buffer)
                     (org-capture-session-capture-buffer session)))
      (editor-error "There is no active Org capture in this buffer."))
    (let ((request (org-capture-session-request session))
          (capture (org-capture-session-capture-buffer session)))
      (when (org-capture-request-origin-live-p request)
        (org-capture-restore-origin request))
      (org-capture-clear-session session)
      (when (org-capture-live-buffer-p capture)
        (with-global-variable-value (kill-buffer-hook nil)
          (delete-buffer capture)))
      (message "Org capture aborted."))))

(defun org-capture-focus-existing ()
  (or
   (alexandria:when-let ((session *org-capture-session*))
     (let ((buffer (org-capture-session-capture-buffer session)))
       (if (org-capture-live-buffer-p buffer)
           (progn
             (switch-to-buffer buffer nil nil)
             (message "Finish with C-c C-c or abort with C-c C-k.")
             t)
           (progn (org-capture-clear-session session) nil))))
   (alexandria:when-let ((request *org-capture-request*))
     (if (org-capture-request-origin-live-p request)
         (progn
           (org-capture-restore-origin request)
           (org-capture-template-message)
           t)
         (progn (org-capture-clear-request request) nil)))))

(define-command lem-yath-capture () ()
  "Start the configured one-key i/t/p/r Org capture workflow."
  (when (org-capture-focus-existing)
    (return-from lem-yath-capture nil))
  (let* ((buffer (current-buffer))
         (point (current-point))
         (initial (org-capture-active-region-text buffer))
         (annotation (org-capture-origin-annotation buffer point))
         (request
           (make-org-capture-request
            :origin-buffer buffer
            :origin-window (current-window)
            :origin-point (copy-point point :right-inserting)
            :origin-state (lem-vi-mode/core:current-state)
            :initial-text initial
            :annotation annotation)))
    (setf *org-capture-request* request)
    (add-hook (variable-value 'kill-buffer-hook :buffer buffer)
              'org-capture-origin-kill-buffer-hook)
    (lem-yath-org-capture-template-mode t)
    (setf (buffer-minor-modes buffer)
          (cons 'lem-yath-org-capture-template-mode
                (remove 'lem-yath-org-capture-template-mode
                        (buffer-minor-modes buffer))))
    (org-capture-template-message)))

(defun org-capture-cleanup-for-reload ()
  (alexandria:when-let ((session *org-capture-session*))
    (let* ((request (org-capture-session-request session))
           (capture (org-capture-session-capture-buffer session)))
      (when (org-capture-request-origin-live-p request)
        (ignore-errors (org-capture-restore-origin request)))
      (org-capture-clear-session session)
      (when (org-capture-live-buffer-p capture)
        (with-global-variable-value (kill-buffer-hook nil)
          (delete-buffer capture)))))
  (alexandria:when-let ((request *org-capture-request*))
    (when (org-capture-request-origin-live-p request)
      (ignore-errors (org-capture-restore-origin request)))
    (org-capture-clear-request request)))

(define-key *org-capture-mode-keymap* "C-c C-c"
  'lem-yath-org-capture-finalize)
(define-key *org-capture-mode-keymap* "C-c C-k"
  'lem-yath-org-capture-abort)
(define-key *org-capture-mode-keymap* "C-x C-s"
  'lem-yath-org-capture-save-guard)

(define-key *org-capture-template-mode-keymap* "i"
  'lem-yath-org-capture-template-inbox)
(define-key *org-capture-template-mode-keymap* "t"
  'lem-yath-org-capture-template-todo)
(define-key *org-capture-template-mode-keymap* "p"
  'lem-yath-org-capture-template-public)
(define-key *org-capture-template-mode-keymap* "r"
  'lem-yath-org-capture-template-reading)
(define-key *org-capture-template-mode-keymap* "C-g"
  'lem-yath-org-capture-template-abort)
(define-key *org-capture-template-mode-keymap* "Escape"
  'lem-yath-org-capture-template-abort)
