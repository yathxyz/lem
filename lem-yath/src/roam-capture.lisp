;;;; Org-roam/md-roam capture sessions for typed missing node titles.
;;;; Existing-node discovery remains in roam.lisp; this module owns the
;;;; configured five-template creation workflow and its finalize/abort state.

(in-package :lem-yath)

(eval-when (:load-toplevel :execute)
  (when (fboundp 'roam-capture-cleanup-for-reload)
    (roam-capture-cleanup-for-reload)))

(defparameter *roam-capture-slug-limit* 160)
(defparameter *roam-capture-time-function* #'get-universal-time)
(defparameter *roam-capture-id-function* #'uuid-v4)

(defvar *roam-capture-mode-keymap* (make-keymap))
(defvar *roam-capture-template-mode-keymap* (make-keymap))
(defvar *roam-capture-session* nil)
(defvar *roam-capture-request* nil)

(defstruct roam-capture-template
  key
  name
  kind
  directory
  filename-prefix
  filetag
  first-heading
  body-tail)

(defstruct roam-capture-session
  template
  title
  id
  pathname
  capture-buffer
  origin-buffer
  origin-window
  origin-point
  insert-p
  saved-p
  finalizing-p
  closing-p)

(defstruct roam-capture-request
  title
  origin-buffer
  origin-window
  origin-point
  insert-p)

(defparameter *roam-capture-templates*
  (list
   (make-roam-capture-template
    :key "n" :name "note" :kind :org :directory ""
    :filename-prefix "" :filetag nil :first-heading nil :body-tail "")
   (make-roam-capture-template
    :key "c" :name "concept" :kind :org :directory ""
    :filename-prefix "" :filetag "concept" :first-heading "Claim"
    :body-tail (format nil "~%~%* Context~%~%* Links~%"))
   (make-roam-capture-template
    :key "p" :name "project" :kind :org :directory ""
    :filename-prefix "project-" :filetag "project" :first-heading "Outcome"
    :body-tail (format nil "~%~%* Notes~%~%* Links~%"))
   (make-roam-capture-template
    :key "s" :name "source" :kind :org :directory "references/"
    :filename-prefix "" :filetag "source" :first-heading "Summary"
    :body-tail (format nil "~%~%* Notes~%~%* Links~%"))
   (make-roam-capture-template
    :key "m" :name "markdown note" :kind :markdown :directory ""
    :filename-prefix "" :filetag nil :first-heading nil :body-tail "")))

(define-minor-mode lem-yath-roam-capture-mode
    (:name "Roam-Capture"
     :description "Finalize or abort an active Org-roam capture"
     :keymap *roam-capture-mode-keymap*))

(define-minor-mode lem-yath-roam-capture-template-mode
    (:name "Roam-Template"
     :description "Select an Org-roam capture template"
     :keymap *roam-capture-template-mode-keymap*
     :hide-from-modeline t))

(defun roam-capture-live-buffer-p (buffer)
  (and (bufferp buffer) (not (deleted-buffer-p buffer))))

(defun roam-capture-safe-title (input)
  "Return a bounded single-line title derived from INPUT or signal an error."
  (unless (stringp input)
    (editor-error "A roam capture title must be text."))
  (let ((title (string-trim '(#\Space #\Tab) input)))
    (when (zerop (length title))
      (editor-error "A roam capture title cannot be blank."))
    (when (> (length title) *roam-metadata-value-limit*)
      (editor-error "The roam capture title exceeds ~d characters."
                    *roam-metadata-value-limit*))
    (when (some (lambda (character)
                  (let ((code (char-code character)))
                    (or (< code 32) (= code 127))))
                title)
      (editor-error "A roam capture title cannot contain control characters."))
    title))

(defparameter *roam-capture-slug-combining-marks*
  '(#x300 #x301 #x302 #x303 #x304 #x306 #x307 #x308 #x309 #x30a
    #x30b #x30c #x31b #x323 #x324 #x325 #x327 #x32d #x32e #x330 #x331))

(defun roam-capture-unicode-normalize (text form)
  "Use SBCL's Unicode normalizer when present, otherwise preserve TEXT."
  (let ((function (find-symbol "NORMALIZE-STRING" :sb-unicode)))
    (if (and function (fboundp function))
        (handler-case (funcall function text form)
          (error () text))
        text)))

(defun roam-capture-slug (title)
  "Slugify TITLE like the configured Org-roam version, with a path bound."
  (let ((output (make-string-output-stream))
        (separator-p nil)
        (wrote-p nil))
    (loop :for character :across (roam-capture-unicode-normalize title :nfd)
          :for code := (char-code character)
          :unless (member code *roam-capture-slug-combining-marks*)
            :do (if (alphanumericp character)
                    (progn
                      (when (and separator-p wrote-p)
                        (write-char #\_ output))
                      (write-char (char-downcase character) output)
                      (setf separator-p nil
                            wrote-p t))
                    (setf separator-p t)))
    (let* ((slug (roam-capture-unicode-normalize
                  (get-output-stream-string output) :nfc))
           (bounded (if (> (length slug) *roam-capture-slug-limit*)
                        (subseq slug 0 *roam-capture-slug-limit*)
                        slug)))
      (string-right-trim "_" bounded))))

(defun roam-capture-timestamp (time)
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time time)
    (format nil "~4,'0d~2,'0d~2,'0d~2,'0d~2,'0d~2,'0d"
            year month day hour minute second)))

(defun roam-capture-iso-timestamp (time)
  (multiple-value-bind (second minute hour day month year day-of-week
                        daylight-p timezone)
      (decode-universal-time time)
    (declare (ignore day-of-week daylight-p))
    (let* ((offset-minutes (round (* -60 timezone)))
           (absolute (abs offset-minutes)))
      (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d~c~2,'0d~2,'0d"
              year month day hour minute second
              (if (minusp offset-minutes) #\- #\+)
              (floor absolute 60) (mod absolute 60)))))

(defun roam-capture-template-extension (template)
  (if (eq (roam-capture-template-kind template) :markdown) "md" "org"))

(defun roam-capture-relative-path (template title time)
  (let ((filename
          (format nil "~a-~a~a.~a"
                  (roam-capture-timestamp time)
                  (roam-capture-template-filename-prefix template)
                  (roam-capture-slug title)
                  (roam-capture-template-extension template))))
    (concatenate 'string (roam-capture-template-directory template) filename)))

(defun roam-capture-render (template title id time)
  "Return configured TEMPLATE text and the zero-based %? cursor offset."
  (if (eq (roam-capture-template-kind template) :markdown)
      (let ((text
              (format nil
                      "---~%id: ~a~%title: ~a~%created: \"~a\"~%tags: []~%---~%~%"
                      id title (roam-capture-iso-timestamp time))))
        (values text (length text)))
      (let* ((tag (roam-capture-template-filetag template))
             (header
               (format nil ":PROPERTIES:~%:ID: ~a~%:END:~%#+title: ~a~%#+created: ~a~a~%~%"
                       id title (inactive-org-timestamp time)
                       (if tag (format nil "~%#+filetags: :~a:" tag) "")))
             (heading (roam-capture-template-first-heading template))
             (before-point (if heading (format nil "* ~a~%" heading) ""))
             (text (concatenate 'string header before-point
                                (roam-capture-template-body-tail template))))
        (values text (+ (length header) (length before-point))))))

(defun roam-capture-template-by-key (input)
  (find input *roam-capture-templates*
        :test #'string= :key #'roam-capture-template-key))

(defun roam-capture-buffer-kind (&optional (buffer (current-buffer)))
  (let* ((file (ignore-errors (buffer-filename buffer)))
         (type (and file (pathname-type (pathname file)))))
    (cond ((and type (string-equal "org" type)) :org)
          ((and type (string-equal "md" type)) :markdown))))

(defun roam-insert-node-link (node)
  "Resolve NODE and insert the configured link form at the current point."
  (let ((origin-kind (roam-capture-buffer-kind)))
    (unless origin-kind
      (editor-error "Roam links can only be inserted in Org or Markdown files."))
    (when (buffer-read-only-p (current-buffer))
      (editor-error "Cannot insert a roam link into a read-only buffer."))
    (let* ((current (roam-resolve-node node))
           (title (roam-node-title current)))
      (if (eq origin-kind :org)
          (progn
            (when (> (count (roam-node-id current) (note-nodes)
                            :test #'string= :key #'roam-node-id)
                     1)
              (editor-error "The selected roam node ID is globally ambiguous."))
            (insert-string
             (current-point)
             (format nil "[[id:~a][~a]]"
                     (roam-node-id current)
                     (roam-escape-link-text title '(#\\ #\])))))
          (insert-string
           (current-point)
           (format nil "[[~a]]"
                   (roam-escape-link-text title '(#\\ #\]))))))))

(defun roam-capture-unique-id ()
  (let ((existing (note-nodes)))
    (loop :repeat 100
          :for id := (funcall *roam-capture-id-function*)
          :when (and (roam-valid-node-id-p id)
                     (not (find id existing :test #'string=
                                            :key #'roam-node-id)))
            :return id
          :finally (editor-error "Could not generate a unique roam node ID."))))

(defun roam-capture-safe-pathname (template title time)
  (let* ((root (roam-directory))
         (relative (roam-capture-relative-path template title time))
         (pathname (merge-pathnames relative root)))
    (when (> (length relative) *roam-pathname-character-limit*)
      (editor-error "The roam capture pathname exceeds its safety limit."))
    (ensure-directories-exist pathname)
    (let ((canonical-root (ignore-errors (truename root)))
          (canonical-parent
            (ignore-errors (truename (uiop:pathname-directory-pathname pathname)))))
      (unless (and canonical-root canonical-parent
                   (roam-path-in-root-p canonical-parent canonical-root))
        (editor-error "The roam capture target is not safely inside the roam root.")))
    (when (or (uiop:probe-file* pathname)
              (find-if
               (lambda (buffer)
                 (let ((file (ignore-errors (buffer-filename buffer))))
                   (and file
                        (string= (uiop:native-namestring pathname)
                                 (uiop:native-namestring (pathname file))))))
               (buffer-list)))
      (editor-error "The roam capture target already exists: ~a" relative))
    pathname))

(defun roam-capture-origin-live-p (session)
  (let ((buffer (roam-capture-session-origin-buffer session))
        (point (roam-capture-session-origin-point session)))
    (and (roam-capture-live-buffer-p buffer)
         point
         (ignore-errors (eq (point-buffer point) buffer)))))

(defun roam-capture-restore-origin (session)
  (unless (roam-capture-origin-live-p session)
    (editor-error "The roam capture origin no longer exists."))
  (let ((window (roam-capture-session-origin-window session))
        (buffer (roam-capture-session-origin-buffer session)))
    (when (and window (not (deleted-window-p window)))
      (setf (current-window) window))
    (unless (eq (current-buffer) buffer)
      (switch-to-buffer buffer nil nil))
    (move-point (current-point) (roam-capture-session-origin-point session))))

(defun roam-capture-release-origin (session)
  (alexandria:when-let ((point (roam-capture-session-origin-point session)))
    (ignore-errors (delete-point point))
    (setf (roam-capture-session-origin-point session) nil)))

(defun roam-capture-disable-buffer (session)
  (let ((buffer (roam-capture-session-capture-buffer session)))
    (when (roam-capture-live-buffer-p buffer)
      (with-current-buffer buffer
        (remove-hook (variable-value 'before-save-hook :buffer buffer)
                     'roam-capture-before-save-hook)
        (remove-hook (variable-value 'kill-buffer-hook :buffer buffer)
                     'roam-capture-kill-buffer-hook)
        (setf (buffer-value buffer 'lem-yath-roam-capture-session) nil)
        (when (mode-active-p buffer 'lem-yath-roam-capture-mode)
          (lem-yath-roam-capture-mode nil))))))

(defun roam-capture-clear-session (session)
  (unless (roam-capture-session-closing-p session)
    (setf (roam-capture-session-closing-p session) t)
    (roam-capture-disable-buffer session)
    (roam-capture-release-origin session)
    (when (eq *roam-capture-session* session)
      (setf *roam-capture-session* nil))))

(defun roam-capture-before-save-hook (buffer)
  (alexandria:when-let
      ((session (buffer-value buffer 'lem-yath-roam-capture-session)))
    (unless (roam-capture-session-finalizing-p session)
      (editor-error "Use C-c C-c to finalize or C-c C-k to abort this capture."))))

(defun roam-capture-kill-buffer-hook (&optional (buffer (current-buffer)))
  (alexandria:when-let
      ((session (buffer-value buffer 'lem-yath-roam-capture-session)))
    (unless (roam-capture-session-closing-p session)
      (setf (roam-capture-session-closing-p session) t)
      (when (and (not (eq buffer (roam-capture-session-origin-buffer session)))
                 (roam-capture-origin-live-p session))
        (ignore-errors (roam-capture-restore-origin session)))
      (roam-capture-release-origin session)
      (when (eq *roam-capture-session* session)
        (setf *roam-capture-session* nil)))))

(defun roam-capture-buffer-text (buffer)
  (let ((characters (- (position-at-point (buffer-end-point buffer))
                       (position-at-point (buffer-start-point buffer)))))
    (when (> characters *roam-file-byte-limit*)
      (editor-error "The capture exceeds the roam file safety limit."))
    (points-to-string (buffer-start-point buffer) (buffer-end-point buffer))))

(defun roam-capture-save-buffer (session)
  (let ((buffer (roam-capture-session-capture-buffer session))
        (pathname (roam-capture-session-pathname session)))
    (unless (and (roam-capture-live-buffer-p buffer)
                 (eq (buffer-value buffer 'lem-yath-roam-capture-session)
                     session))
      (editor-error "The active roam capture buffer no longer exists."))
    (unless (roam-capture-session-saved-p session)
      (when (uiop:probe-file* pathname)
        (editor-error "The roam capture target appeared on disk; refusing to overwrite it.")))
    (let* ((text (roam-capture-buffer-text buffer))
           (octets (babel:string-to-octets text :encoding :utf-8)))
      (when (> (length octets) *roam-file-byte-limit*)
        (editor-error "The UTF-8 capture exceeds the roam file safety limit.")))
    (setf (roam-capture-session-finalizing-p session) t)
    (unwind-protect
         (with-current-buffer buffer
           (save-buffer buffer)
           (unless (uiop:probe-file* pathname)
             (editor-error "The roam capture target was not saved."))
           (setf (roam-capture-session-saved-p session) t))
      (setf (roam-capture-session-finalizing-p session) nil))))

(defun roam-capture-created-node (session)
  (let ((root (ignore-errors (truename (roam-directory)))))
    (unless (and root
                 (roam-path-in-root-p (roam-capture-session-pathname session)
                                      root))
      (editor-error "The saved roam capture escaped the roam root."))
    (multiple-value-bind (nodes bytes status)
        (roam-nodes-from-pathname (roam-capture-session-pathname session) root)
      (declare (ignore bytes))
      (unless (eq status :ok)
        (editor-error "The saved roam capture is not a safe indexable note."))
      (let ((matches
              (remove-if-not
               (lambda (node)
                 (string= (roam-node-id node)
                          (roam-capture-session-id session)))
               nodes)))
        (cond ((null matches)
               (editor-error "The saved roam capture no longer contains its node ID."))
              ((cdr matches)
               (editor-error "The saved roam capture contains an ambiguous node ID."))
              (t (first matches)))))))

(defun roam-capture-validate-insert-origin (session)
  (unless (roam-capture-origin-live-p session)
    (editor-error "The roam insertion origin no longer exists."))
  (let ((buffer (roam-capture-session-origin-buffer session)))
    (unless (roam-capture-buffer-kind buffer)
      (editor-error "Roam links can only be inserted in Org or Markdown files."))
    (when (buffer-read-only-p buffer)
      (editor-error "Cannot insert a roam link into a read-only buffer."))))

(define-command lem-yath-roam-capture-finalize () ()
  "Save the active capture and complete find or deferred link insertion."
  (let ((session *roam-capture-session*))
    (unless (and session
                 (eq (current-buffer)
                     (roam-capture-session-capture-buffer session)))
      (editor-error "There is no active roam capture in this buffer."))
    (when (roam-capture-session-insert-p session)
      (roam-capture-validate-insert-origin session))
    (roam-capture-save-buffer session)
    (let ((node (roam-capture-created-node session)))
      (when (roam-capture-session-insert-p session)
        (handler-case
            (progn
              (roam-capture-restore-origin session)
              (roam-insert-node-link node))
          (error (condition)
            (when (roam-capture-live-buffer-p
                   (roam-capture-session-capture-buffer session))
              (switch-to-buffer
               (roam-capture-session-capture-buffer session) nil nil))
            (error condition))))
      (let ((relative (enough-namestring
                       (roam-capture-session-pathname session)
                       (roam-directory))))
        (roam-capture-clear-session session)
        (message "Captured roam node: ~a" relative)))))

(define-command lem-yath-roam-capture-abort () ()
  "Abort the active capture and restore its exact origin."
  (let ((session *roam-capture-session*))
    (unless (and session
                 (eq (current-buffer)
                     (roam-capture-session-capture-buffer session)))
      (editor-error "There is no active roam capture in this buffer."))
    (let ((buffer (roam-capture-session-capture-buffer session))
          (saved-p (roam-capture-session-saved-p session)))
      (when (roam-capture-origin-live-p session)
        (roam-capture-restore-origin session))
      (roam-capture-clear-session session)
      (when (and (not saved-p) (roam-capture-live-buffer-p buffer))
        (with-global-variable-value (kill-buffer-hook nil)
          (delete-buffer buffer)))
      (message (if saved-p
                   "Roam capture aborted; the already-saved note was kept."
                   "Roam capture aborted.")))))

(defun roam-capture-request-origin-live-p (request)
  (let ((buffer (roam-capture-request-origin-buffer request))
        (point (roam-capture-request-origin-point request)))
    (and (roam-capture-live-buffer-p buffer)
         point
         (ignore-errors (eq (point-buffer point) buffer)))))

(defun roam-capture-restore-request-origin (request)
  (unless (roam-capture-request-origin-live-p request)
    (editor-error "The roam capture request origin no longer exists."))
  (let ((window (roam-capture-request-origin-window request))
        (buffer (roam-capture-request-origin-buffer request)))
    (when (and window (not (deleted-window-p window)))
      (setf (current-window) window))
    (unless (eq (current-buffer) buffer)
      (switch-to-buffer buffer nil nil))
    (move-point (current-point) (roam-capture-request-origin-point request))))

(defun roam-capture-disable-request-buffer (request)
  (let ((buffer (roam-capture-request-origin-buffer request)))
    (when (roam-capture-live-buffer-p buffer)
      (with-current-buffer buffer
        (remove-hook (variable-value 'kill-buffer-hook :buffer buffer)
                     'roam-capture-request-kill-buffer-hook)
        (when (mode-active-p buffer 'lem-yath-roam-capture-template-mode)
          (lem-yath-roam-capture-template-mode nil))))))

(defun roam-capture-release-request (request)
  (roam-capture-disable-request-buffer request)
  (alexandria:when-let ((point (roam-capture-request-origin-point request)))
    (ignore-errors (delete-point point))
    (setf (roam-capture-request-origin-point request) nil))
  (when (eq *roam-capture-request* request)
    (setf *roam-capture-request* nil)))

(defun roam-capture-request-kill-buffer-hook (&optional (buffer (current-buffer)))
  (let ((request *roam-capture-request*))
    (when (and request
               (eq buffer (roam-capture-request-origin-buffer request)))
      (roam-capture-release-request request))))

(defun roam-capture-template-message ()
  (message
   "Roam template: n note | c concept | p project | s source | m markdown note | C-g abort"))

(define-command lem-yath-roam-capture-template-abort () ()
  "Abort a pending template selection without changing the origin."
  (let ((request *roam-capture-request*))
    (unless request
      (editor-error "There is no pending roam capture template."))
    (when (roam-capture-request-origin-live-p request)
      (roam-capture-restore-request-origin request))
    (roam-capture-release-request request)
    (message "Roam capture cancelled.")))

(defun roam-capture-start-request (request template)
  (let* ((title (roam-capture-request-title request))
         (origin-buffer (roam-capture-request-origin-buffer request))
         (origin-window (roam-capture-request-origin-window request))
         (origin-point (roam-capture-request-origin-point request))
         (insert-p (roam-capture-request-insert-p request))
         (time (funcall *roam-capture-time-function*))
         (id (roam-capture-unique-id))
         (pathname (roam-capture-safe-pathname template title time))
         (buffer nil)
         (session nil)
         (opened-p nil))
    (unwind-protect
         (progn
           (find-file pathname)
           (setf buffer (current-buffer))
           (unless (zerop (- (position-at-point (buffer-end-point buffer))
                             (position-at-point (buffer-start-point buffer))))
             (editor-error "The new roam capture buffer is not empty."))
           (multiple-value-bind (text cursor)
               (roam-capture-render template title id time)
             (insert-string (current-point) text)
             (buffer-start (current-point))
             (character-offset (current-point) cursor))
           (setf session
                 (make-roam-capture-session
                  :template template :title title :id id :pathname pathname
                  :capture-buffer buffer :origin-buffer origin-buffer
                  :origin-window origin-window :origin-point origin-point
                  :insert-p insert-p))
           (setf *roam-capture-session* session
                 (buffer-value buffer 'lem-yath-roam-capture-session) session)
           (add-hook (variable-value 'before-save-hook :buffer buffer)
                     'roam-capture-before-save-hook)
           (add-hook (variable-value 'kill-buffer-hook :buffer buffer)
                     'roam-capture-kill-buffer-hook)
           (lem-yath-roam-capture-mode t)
           (setf (buffer-minor-modes buffer)
                 (cons 'lem-yath-roam-capture-mode
                       (remove 'lem-yath-roam-capture-mode
                               (buffer-minor-modes buffer))))
           (setf (lem-vi-mode/core:buffer-state)
                 'lem-vi-mode/states:insert)
           (setf (roam-capture-request-origin-point request) nil
                 opened-p t)
           (message "Roam capture: C-c C-c finalizes; C-c C-k aborts."))
      (unless opened-p
        (when session (roam-capture-clear-session session))
        (unless session (ignore-errors (delete-point origin-point)))
        (when (and buffer (roam-capture-live-buffer-p buffer))
          (with-global-variable-value (kill-buffer-hook nil)
            (delete-buffer buffer)))
        (when (roam-capture-live-buffer-p origin-buffer)
          (ignore-errors
            (setf (current-window) origin-window)
            (switch-to-buffer origin-buffer nil nil)))))))

(defun roam-capture-select-template (key)
  (let ((request *roam-capture-request*)
        (template (roam-capture-template-by-key key)))
    (unless (and request template)
      (editor-error "There is no matching pending roam capture template."))
    (unless (and (roam-capture-request-origin-live-p request)
                 (eq (current-buffer)
                     (roam-capture-request-origin-buffer request)))
      (editor-error "The pending roam capture is no longer at its origin."))
    (roam-capture-disable-request-buffer request)
    (setf *roam-capture-request* nil)
    (handler-case
        (roam-capture-start-request request template)
      (error (condition)
        (roam-capture-release-request request)
        (error condition)))))

(define-command lem-yath-roam-capture-template-note () ()
  (roam-capture-select-template "n"))
(define-command lem-yath-roam-capture-template-concept () ()
  (roam-capture-select-template "c"))
(define-command lem-yath-roam-capture-template-project () ()
  (roam-capture-select-template "p"))
(define-command lem-yath-roam-capture-template-source () ()
  (roam-capture-select-template "s"))
(define-command lem-yath-roam-capture-template-markdown () ()
  (roam-capture-select-template "m"))

(defun roam-capture-focus-existing ()
  (or
   (alexandria:when-let ((session *roam-capture-session*))
     (let ((buffer (roam-capture-session-capture-buffer session)))
       (if (roam-capture-live-buffer-p buffer)
           (progn
             (switch-to-buffer buffer nil nil)
             (message
              "Finish this roam capture with C-c C-c or abort with C-c C-k.")
             t)
           (progn
             (roam-capture-clear-session session)
             nil))))
   (alexandria:when-let ((request *roam-capture-request*))
     (if (roam-capture-request-origin-live-p request)
         (progn
           (roam-capture-restore-request-origin request)
           (roam-capture-template-message)
           t)
         (progn
           (roam-capture-release-request request)
           nil)))))

(defun roam-capture-begin-request (input &key insert-p)
  (when (roam-capture-focus-existing)
    (return-from roam-capture-begin-request nil))
  (let* ((title (roam-capture-safe-title input))
         (origin-buffer (current-buffer))
         (origin-window (current-window)))
    (when insert-p
      (unless (roam-capture-buffer-kind origin-buffer)
        (editor-error "Roam links can only be inserted in Org or Markdown files."))
      (when (buffer-read-only-p origin-buffer)
        (editor-error "Cannot insert a roam link into a read-only buffer.")))
    (let ((request
            (make-roam-capture-request
             :title title :origin-buffer origin-buffer
             :origin-window origin-window
             :origin-point (copy-point (current-point) :right-inserting)
             :insert-p insert-p)))
      (setf *roam-capture-request* request)
      (add-hook (variable-value 'kill-buffer-hook :buffer origin-buffer)
                'roam-capture-request-kill-buffer-hook)
      (lem-yath-roam-capture-template-mode t)
      (setf (buffer-minor-modes origin-buffer)
            (cons 'lem-yath-roam-capture-template-mode
                  (remove 'lem-yath-roam-capture-template-mode
                          (buffer-minor-modes origin-buffer))))
      (roam-capture-template-message))))

(defun roam-capture-cleanup-for-reload ()
  (alexandria:when-let ((session *roam-capture-session*))
    (let ((buffer (roam-capture-session-capture-buffer session)))
      (when (roam-capture-origin-live-p session)
        (ignore-errors (roam-capture-restore-origin session)))
      (roam-capture-clear-session session)
      (when (and (not (roam-capture-session-saved-p session))
                 (roam-capture-live-buffer-p buffer))
        (with-global-variable-value (kill-buffer-hook nil)
          (delete-buffer buffer)))))
  (alexandria:when-let ((request *roam-capture-request*))
    (when (roam-capture-request-origin-live-p request)
      (ignore-errors (roam-capture-restore-request-origin request)))
    (roam-capture-release-request request)))

(define-command lem-yath-roam-find () ()
  "Find an existing node or capture a typed missing title."
  (multiple-value-bind (node nodes new-title)
      (prompt-for-note "Roam node: ")
    (declare (ignore nodes))
    (cond (node (roam-visit-node node))
          (new-title (roam-capture-begin-request new-title)))))

(define-command lem-yath-roam-insert () ()
  "Insert an existing node link or capture and insert a typed missing title."
  (multiple-value-bind (node nodes new-title)
      (prompt-for-note "Insert link to: ")
    (declare (ignore nodes))
    (cond (node (roam-insert-node-link node))
          (new-title (roam-capture-begin-request new-title :insert-p t)))))

(define-key *roam-capture-mode-keymap* "C-c C-c"
  'lem-yath-roam-capture-finalize)
(define-key *roam-capture-mode-keymap* "C-c C-k"
  'lem-yath-roam-capture-abort)

(define-key *roam-capture-template-mode-keymap* "n"
  'lem-yath-roam-capture-template-note)
(define-key *roam-capture-template-mode-keymap* "c"
  'lem-yath-roam-capture-template-concept)
(define-key *roam-capture-template-mode-keymap* "p"
  'lem-yath-roam-capture-template-project)
(define-key *roam-capture-template-mode-keymap* "s"
  'lem-yath-roam-capture-template-source)
(define-key *roam-capture-template-mode-keymap* "m"
  'lem-yath-roam-capture-template-markdown)
(define-key *roam-capture-template-mode-keymap* "C-g"
  'lem-yath-roam-capture-template-abort)
(define-key *roam-capture-template-mode-keymap* "Escape"
  'lem-yath-roam-capture-template-abort)
