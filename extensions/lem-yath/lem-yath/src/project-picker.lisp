;;;; Consult-style project buffer, recent-file, and root picker.

(in-package :lem-yath)

(defparameter *project-picker-preview-byte-limit* (* 1024 1024))
(defparameter *project-picker-annotation-item-limit* 100)

(defstruct project-picker-candidate
  kind
  group
  label
  value)

(defstruct project-picker-session
  root
  origin-window
  origin-buffer
  origin-point
  origin-view-point
  origin-horizontal-scroll-start
  candidates
  group-order
  narrow-kind
  selected
  preview-candidate
  preview-buffer
  active-p)

(defvar *project-picker-session* nil)

(defun project-picker-live-buffer-p (buffer)
  (and buffer (not (deleted-buffer-p buffer))))

(defun project-picker-live-window-p (window)
  (and window (not (deleted-window-p window))))

(defun project-picker-visible-buffer-p (buffer)
  (not (null (get-buffer-windows buffer))))

(defun project-picker-expanded-name (pathname)
  "Return PATHNAME as an absolute lexical name without resolving symlinks."
  (handler-case
      (expand-file-name pathname)
    (error () nil)))

(defun project-picker-expanded-directory-name (directory)
  "Return DIRECTORY as an absolute lexical name ending in a separator."
  (alexandria:when-let ((name (project-picker-expanded-name directory)))
    (uiop:native-namestring
     (uiop:ensure-directory-pathname (pathname name)))))

(defun project-picker-buffer-in-root-p (buffer root)
  (alexandria:when-let*
      ((directory (buffer-directory buffer))
       (directory-name (project-picker-expanded-directory-name directory))
       (root-name (project-picker-expanded-directory-name root)))
    (alexandria:starts-with-subseq root-name directory-name)))

(defun project-picker-project-buffers (root)
  "Return project buffers in Consult's visibility/MRU order."
  (let* ((current (current-buffer))
         (buffers
           (loop :for buffer :in (buffer-list)
                 :when (and (project-picker-live-buffer-p buffer)
                            (not (not-switchable-buffer-p buffer))
                            (project-picker-buffer-in-root-p buffer root))
                   :collect buffer))
         (others (remove current buffers :test #'eq)))
    (append
     (remove-if #'project-picker-visible-buffer-p others)
     (remove-if-not #'project-picker-visible-buffer-p others)
     (when (member current buffers :test #'eq)
       (list current)))))

(defun project-picker-file-equal-p (left right)
  (let ((left (and left (project-picker-expanded-name left)))
        (right (and right (project-picker-expanded-name right))))
    (and left right (string= left right))))

(defun project-picker-open-file-buffer (pathname)
  (find-if
   (lambda (buffer)
     (and (project-picker-live-buffer-p buffer)
          (buffer-filename buffer)
          (project-picker-file-equal-p pathname (buffer-filename buffer))))
   (buffer-list)))

(defun project-picker-file-in-root-p (pathname root)
  "Whether PATHNAME is project-local, retaining harmless stale history rows."
  (alexandria:when-let*
      ((name (project-picker-expanded-name pathname))
       (root-name (project-picker-expanded-directory-name root)))
    (alexandria:starts-with-subseq root-name name)))

(defun project-picker-recent-files (root)
  "Return recent project files, newest first, excluding files already open."
  (remove-duplicates
   (loop :for entry :in (lem-core/commands/file:recent-files)
         :for name := (project-picker-expanded-name entry)
         :when (and name
                    (project-picker-file-in-root-p name root)
                    (null (project-picker-open-file-buffer name)))
           :collect name)
   :test #'string=
   :from-end t))

(defun project-picker-known-roots (current-root)
  "Return CURRENT-ROOT first, then other known roots alphabetically."
  (cons current-root
        (sort
         (remove-if
          (lambda (root) (uiop:pathname-equal root current-root))
          (saved-project-roots))
         #'string-lessp
         :key #'uiop:native-namestring)))

(defun project-picker-root-label (root)
  (let* ((root-name (uiop:native-namestring root))
         (home-name
           (uiop:native-namestring
            (uiop:ensure-directory-pathname (user-homedir-pathname))))
         (abbreviated
           (if (alexandria:starts-with-subseq home-name root-name)
               (concatenate 'string "~/" (subseq root-name (length home-name)))
               root-name)))
    (project-display-string abbreviated)))

(defun project-picker-buffer-candidate (buffer)
  (make-project-picker-candidate
   :kind :buffer
   :group "Project Buffer"
   :label (project-display-string (buffer-name buffer))
   :value buffer))

(defun project-picker-file-candidate (pathname root)
  (make-project-picker-candidate
   :kind :file
   :group "Project File"
   :label (project-display-string (enough-namestring pathname root))
   :value pathname))

(defun project-picker-root-candidate (root)
  (make-project-picker-candidate
   :kind :root
   :group "Project Root"
   :label (project-picker-root-label root)
   :value root))

(defun project-picker-candidates (root)
  (append
   (mapcar #'project-picker-buffer-candidate
           (project-picker-project-buffers root))
   (mapcar (lambda (pathname)
             (project-picker-file-candidate pathname root))
           (project-picker-recent-files root))
   (mapcar #'project-picker-root-candidate
           (project-picker-known-roots root))))

(defun project-picker-kinds-in-order (candidates)
  (let ((seen '())
        (result '()))
    (dolist (candidate candidates (nreverse result))
      (let ((kind (project-picker-candidate-kind candidate)))
        (unless (member kind seen)
          (push kind seen)
          (push kind result))))))

(defun project-picker-candidate-live-p (candidate)
  (case (project-picker-candidate-kind candidate)
    (:buffer
     (project-picker-live-buffer-p
      (project-picker-candidate-value candidate)))
    (:root
     (uiop:directory-exists-p
      (project-picker-candidate-value candidate)))
    (otherwise t)))

(defun project-picker-ordered-candidates (session)
  (let ((candidates
          (remove-if-not #'project-picker-candidate-live-p
                         (project-picker-session-candidates session))))
    (loop :for kind :in
            (if (project-picker-session-narrow-kind session)
                (list (project-picker-session-narrow-kind session))
                (project-picker-session-group-order session))
          :append
          (remove-if-not
           (lambda (candidate)
             (eq kind (project-picker-candidate-kind candidate)))
           candidates))))

(defun project-picker-filtered-candidates (session input)
  (prescient-filter
   input
   (project-picker-ordered-candidates session)
   :key #'project-picker-candidate-label
   :category :project-picker
   :rank-p nil))

(defun project-picker-candidate-detail (session candidate)
  (case (project-picker-candidate-kind candidate)
    (:buffer
     (let* ((buffer (project-picker-candidate-value candidate))
            (filename (and (project-picker-live-buffer-p buffer)
                           (buffer-filename buffer))))
       (if (project-picker-live-buffer-p buffer)
           (completion-buffer-detail
            buffer
            (and filename
                 (project-display-string
                  (enough-namestring
                   filename (project-picker-session-root session)))))
           "")))
    ((:file :root)
     (completion-file-detail
      (project-picker-candidate-value candidate)))
    (otherwise "")))

(defun project-picker-fallback-buffer (session)
  (or (and (project-picker-live-buffer-p
            (project-picker-session-origin-buffer session))
           (project-picker-session-origin-buffer session))
      (find-if
       (lambda (buffer)
         (and (project-picker-live-buffer-p buffer)
              (not (not-switchable-buffer-p buffer))))
       (buffer-list))))

(defun project-picker-restore-origin (session)
  "Restore the caller window's exact buffer, point, view, and horizontal scroll."
  (let ((window (project-picker-session-origin-window session))
        (buffer (project-picker-fallback-buffer session)))
    (when (and (project-picker-live-window-p window) buffer)
      (with-current-window window
        (unless (eq (current-buffer) buffer)
          (lem-core::%switch-to-buffer buffer nil nil))
        (when (eq buffer (project-picker-session-origin-buffer session))
          (move-point
           (buffer-point buffer)
           (project-picker-session-origin-point session))
          (move-point
           (window-view-point window)
           (project-picker-session-origin-view-point session))
          (setf (window-parameter window 'lem-core::horizontal-scroll-start)
                (project-picker-session-origin-horizontal-scroll-start
                 session)))))))

(defun project-picker-delete-origin-points (session)
  (dolist (point (list (project-picker-session-origin-point session)
                       (project-picker-session-origin-view-point session)))
    (when point
      (ignore-errors (delete-point point))))
  (setf (project-picker-session-origin-point session) nil
        (project-picker-session-origin-view-point session) nil))

(defun project-picker-delete-preview-buffer (session)
  (let ((buffer (project-picker-session-preview-buffer session)))
    (when (project-picker-live-buffer-p buffer)
      (ignore-errors
        (with-global-variable-value (kill-buffer-hook nil)
          (delete-buffer buffer))))
    (unless (project-picker-live-buffer-p buffer)
      (setf (project-picker-session-preview-buffer session) nil))))

(defun project-picker-clear-preview (session)
  (unwind-protect
       (project-picker-restore-origin session)
    (project-picker-delete-preview-buffer session)
    (setf (project-picker-session-preview-candidate session) nil)))

(defun project-picker-normalize-preview-newlines (string)
  (with-output-to-string (stream)
    (loop :with length := (length string)
          :for index :from 0 :below length
          :for character := (char string index)
          :do
             (if (char= character #\Return)
                 (progn
                   (write-char #\Newline stream)
                   (when (and (< (1+ index) length)
                              (char= (char string (1+ index)) #\Newline))
                     (incf index)))
                 (write-char character stream)))))

(defun project-picker-read-preview-text (pathname)
  "Read at most the preview limit from one nonblocking regular-file descriptor."
  (let ((descriptor nil)
        (stream nil))
    (unwind-protect
         (handler-case
             (progn
               (setf descriptor
                     (sb-posix:open
                      (uiop:native-namestring pathname)
                      (logior sb-posix:o-rdonly sb-posix:o-nonblock)))
               (let ((stat (sb-posix:fstat descriptor)))
                 (unless (and (= (logand (sb-posix:stat-mode stat)
                                         sb-posix:s-ifmt)
                                  sb-posix:s-ifreg)
                              (<= (sb-posix:stat-size stat)
                                  *project-picker-preview-byte-limit*))
                   (return-from project-picker-read-preview-text nil)))
               (setf stream
                     (sb-sys:make-fd-stream
                      descriptor
                      :input t
                      :element-type '(unsigned-byte 8)
                      :buffering :full
                      :name (uiop:native-namestring pathname))
                     descriptor nil)
               (let* ((capacity (1+ *project-picker-preview-byte-limit*))
                      (octets (make-array capacity
                                          :element-type '(unsigned-byte 8)))
                      (count 0))
                 (loop
                   (let ((next (read-sequence octets stream :start count)))
                     (when (= next count)
                       (return))
                     (setf count next)
                     (when (= count capacity)
                       (return-from project-picker-read-preview-text nil))))
                 (when (find 0 octets :end count)
                   (return-from project-picker-read-preview-text nil))
                 (project-picker-normalize-preview-newlines
                  (babel:octets-to-string octets
                                          :end count
                                          :encoding :utf-8))))
           (error () nil))
      (when stream
        (ignore-errors (close stream :abort t)))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor))))))

(defun project-picker-read-preview-buffer (session pathname)
  "Read PATHNAME without assigning a filename or activating a major mode.

  Generic Lem mode activation can run arbitrary hooks and mutate shared parser
state, so unopened-file previews intentionally remain isolated raw text."
  (let ((buffer nil)
        (text (project-picker-read-preview-text pathname)))
    (unless text
      (return-from project-picker-read-preview-buffer nil))
    (handler-case
        (progn
          (setf
           buffer
           (make-buffer
            (format nil " Preview:~a" (file-namestring pathname))
            :temporary t
            :enable-undo-p nil
            :directory
            (uiop:ensure-directory-pathname
             (directory-namestring pathname)))
           (project-picker-session-preview-buffer session) buffer)
          (let ((*inhibit-modification-hooks* t))
            (insert-string (buffer-start-point buffer) text))
          (setf (buffer-encoding buffer)
                (lem/buffer/encodings:encoding :utf-8 :lf))
          (buffer-mark-saved buffer)
          (setf (buffer-read-only-p buffer) t)
          buffer)
      (error ()
        (project-picker-delete-preview-buffer session)
        nil))))

(defun project-picker-show-buffer (session buffer)
  (let ((window (project-picker-session-origin-window session)))
    (when (and (project-picker-live-window-p window)
               (project-picker-live-buffer-p buffer))
      (with-current-window window
        (lem-core::%switch-to-buffer buffer nil t)
        (setf (window-parameter window 'lem-core::horizontal-scroll-start)
              0)))))

(defun project-picker-preview-file (session pathname)
  (alexandria:if-let ((buffer (project-picker-open-file-buffer pathname)))
    (project-picker-show-buffer session buffer)
    (alexandria:when-let
        ((buffer (project-picker-read-preview-buffer session pathname)))
      (project-picker-show-buffer session buffer))))

(defun project-picker-preview (session candidate)
  "Preview CANDIDATE without changing buffer history or running file hooks."
  (when (and (project-picker-session-active-p session)
             (not (eq candidate
                      (project-picker-session-preview-candidate session))))
    (handler-case
        (progn
          (project-picker-clear-preview session)
          (case (project-picker-candidate-kind candidate)
            (:buffer
             (project-picker-show-buffer
              session (project-picker-candidate-value candidate)))
            (:file
             (project-picker-preview-file
              session (project-picker-candidate-value candidate)))
            (:root nil))
          (setf (project-picker-session-preview-candidate session) candidate))
      (error ()
        (ignore-errors (project-picker-clear-preview session))))))

(defun project-picker-make-completion-item (session candidate detail-p)
  (with-point ((start (lem/prompt-window::current-prompt-start-point))
               (end (lem/prompt-window::current-prompt-start-point)))
    (let ((candidate candidate))
      (lem/completion-mode:make-completion-item
       :label (project-picker-candidate-label candidate)
       :filter-text (project-picker-candidate-label candidate)
       :insert-text (project-picker-candidate-label candidate)
       :detail (if detail-p
                   (project-picker-candidate-detail session candidate)
                   "")
       :group (project-picker-candidate-group candidate)
       :start start
       :end (line-end end)
       :focus-action
       (lambda (context)
         (declare (ignore context))
         (project-picker-preview session candidate))
       :accept-action
       (lambda ()
         (setf (project-picker-session-selected session) candidate))))))

(defun project-picker-completion-items (session input)
  (loop :for candidate :in (project-picker-filtered-candidates session input)
        :for index :from 0
        :collect
        (project-picker-make-completion-item
         session candidate
         (< index *project-picker-annotation-item-limit*))))

(defun project-picker-completion-observer (session context event item)
  (declare (ignore context))
  (case event
    (:present
     (unless item
       (ignore-errors (project-picker-clear-preview session))))
    (:end
     (ignore-errors (project-picker-clear-preview session)))))

(defun project-picker-install-completion-options (session)
  (setf
   (variable-value
    'lem/completion-mode:completion-context-options-function
    :buffer (current-buffer))
   (lambda (spec)
     (declare (ignore spec))
     (list
      :narrowing nil
      :observer-function
      (lambda (context event item)
        (project-picker-completion-observer
         session context event item))))))

(defun project-picker-narrow-kind (input)
  (and (= (length input) 1)
       (case (char-downcase (char input 0))
         (#\b :buffer)
         (#\f :file)
         (#\r :root))))

(defun project-picker-kind-label (kind)
  (ecase kind
    (:buffer "Project Buffer")
    (:file "Project File")
    (:root "Project Root")))

(defun project-picker-prompt-prefix (session)
  (if (project-picker-session-narrow-kind session)
      (format nil "Switch to: [~a] "
              (project-picker-kind-label
               (project-picker-session-narrow-kind session)))
      "Switch to: "))

(defun project-picker-refresh-completion ()
  (if lem/completion-mode::*completion-context*
      (lem/completion-mode:completion-refresh)
      (lem/prompt-window::open-prompt-completion)))

(defun project-picker-reset-prompt-prefix (session)
  (lem/completion-mode:completion-end)
  (let* ((prompt (lem/prompt-window:current-prompt-window))
         (buffer (window-buffer prompt)))
    (setf (slot-value buffer 'lem/prompt-window::prompt-string)
          (project-picker-prompt-prefix session))
    (lem/prompt-window::initialize-prompt-buffer buffer)
    (lem/prompt-window::initialize-prompt prompt)
    (lem/prompt-window::update-prompt-window prompt)
    (lem/prompt-window::open-prompt-completion)))

(define-command project-picker-space () ()
  "Narrow on b/f/r plus Space; otherwise insert an ordinary query space."
  (let* ((session *project-picker-session*)
         (kind (and session
                    (project-picker-narrow-kind
                     (lem/prompt-window::get-input-string)))))
    (if (and session kind)
        (progn
          (setf (project-picker-session-narrow-kind session) kind)
          (project-picker-reset-prompt-prefix session))
        (progn
          (insert-character (current-point) #\Space)
          (project-picker-refresh-completion)))))

(define-command project-picker-delete-previous-char () ()
  "Widen an empty narrowed picker; otherwise run ordinary prompt Backspace."
  (let ((session *project-picker-session*))
    (if (and session
             (project-picker-session-narrow-kind session)
             (zerop (length (lem/prompt-window::get-input-string))))
        (progn
          (setf (project-picker-session-narrow-kind session) nil)
          (project-picker-reset-prompt-prefix session))
        (progn
          (delete-previous-char 1)
          (project-picker-refresh-completion)))))

(defun project-picker-present-group-kinds (session input)
  (project-picker-kinds-in-order
   (project-picker-filtered-candidates session input)))

(defun project-picker-rotate-group-order (session target)
  (let* ((order (project-picker-session-group-order session))
         (position (position target order)))
    (when position
      (setf (project-picker-session-group-order session)
            (append (subseq order position) (subseq order 0 position))))))

(defun project-picker-cycle-group (direction)
  (let ((session *project-picker-session*))
    (when (and session
               (null (project-picker-session-narrow-kind session)))
      (let ((groups
              (project-picker-present-group-kinds
               session (lem/prompt-window::get-input-string))))
        (when (cdr groups)
          (project-picker-rotate-group-order
           session
           (if (plusp direction) (second groups) (car (last groups))))
          (project-picker-refresh-completion))))))

(define-command project-picker-next-group () ()
  "Rotate the next visible source group to the front."
  (project-picker-cycle-group 1))

(define-command project-picker-previous-group () ()
  "Rotate the previous visible source group to the front."
  (project-picker-cycle-group -1))

(defparameter *project-picker-keymap*
  (let ((keymap (make-keymap :description "Project picker")))
    (define-key keymap "Space" 'project-picker-space)
    (define-key keymap 'delete-previous-char
      'project-picker-delete-previous-char)
    (define-key keymap "Backspace" 'project-picker-delete-previous-char)
    (define-key keymap "C-h" 'project-picker-delete-previous-char)
    (define-key keymap "M-}" 'project-picker-next-group)
    (define-key keymap "M-{" 'project-picker-previous-group)
    keymap))

(defun project-picker-read-candidate (session)
  (let ((*project-picker-session* session)
        (*prompt-after-activate-hook*
          (cons (cons (lambda ()
                        (project-picker-install-completion-options session))
                      0)
                *prompt-after-activate-hook*)))
    (prompt-for-string
     "Switch to: "
     :completion-function
     (lambda (input)
       (project-picker-completion-items session input))
     :test-function
     (lambda (input)
       (alexandria:when-let
           ((selected (project-picker-session-selected session)))
         (string= input (project-picker-candidate-label selected))))
     :edit-callback
     (lambda (input)
       (declare (ignore input))
       (project-picker-refresh-completion))
     :history-symbol 'lem-yath-project-picker
     :special-keymap *project-picker-keymap*))
  (project-picker-session-selected session))

(defun project-picker-perform-action (candidate)
  (case (project-picker-candidate-kind candidate)
    (:buffer
     (let ((buffer (project-picker-candidate-value candidate)))
       (unless (project-picker-live-buffer-p buffer)
         (editor-error "Selected buffer no longer exists"))
       (switch-to-buffer buffer)))
    (:file
     (find-file (project-picker-candidate-value candidate)))
    (:root
     (let ((root (project-picker-candidate-value candidate)))
       (unless (uiop:directory-exists-p root)
         (editor-error "Project root no longer exists: ~a" root))
       (call-in-project-buffer-directory
        root
        (lambda ()
          (lem-core/commands/file:find-file 1)))))))

(defun project-picker-make-session (root)
  (let* ((candidates (project-picker-candidates root))
         (group-order (project-picker-kinds-in-order candidates))
         (window (current-window))
         (buffer (current-buffer)))
    (make-project-picker-session
     :root root
     :origin-window window
     :origin-buffer buffer
     :origin-point (copy-point (buffer-point buffer))
     :origin-view-point (copy-point (window-view-point window))
     :origin-horizontal-scroll-start
     (window-parameter window 'lem-core::horizontal-scroll-start)
     :candidates candidates
     :group-order group-order
     :active-p t)))

(define-command lem-yath-project-buffers () ()
  "Switch among current-project buffers, recent files, and known roots."
  (let* ((root (current-project-directory))
         (session (project-picker-make-session root))
         (selected nil))
    (unwind-protect
         (setf selected (project-picker-read-candidate session))
      (unwind-protect
           (progn
             (ignore-errors (project-picker-clear-preview session))
             (setf (project-picker-session-active-p session) nil))
        (project-picker-delete-origin-points session)))
    (when selected
      (project-picker-perform-action selected)
      (jump-feedback-after-jump))))

(define-key *global-keymap* "C-x p b" 'lem-yath-project-buffers)
