;;;; Directory-local Consult outline parity for the Emacs configuration tree.
;;;;
;;;; The source `.dir-locals.el' binds C-c i only in Emacs Lisp buffers and
;;;; sets `outline-regexp' to ";;;".  This module reads that declaration as
;;;; data with *READ-EVAL* disabled; it never evaluates directory-local Lisp.

(in-package :lem-yath)

(defparameter *project-outline-dir-locals-byte-limit* (* 64 1024))

(defstruct project-outline-candidate
  label line point)

(defstruct project-outline-session
  source-buffer
  source-window
  origin-point
  origin-view-point
  origin-horizontal-scroll-start
  origin-state
  candidates
  line-number-width
  selected
  selected-input
  preview-candidate
  preview-input
  active-p)

(defvar *project-outline-session* nil)
(defvar *project-outline-keymap*
  (make-keymap :description '*project-outline-keymap*))
(defparameter *project-outline-prompt-keymap*
  (let ((keymap (make-keymap :description "Project outline prompt")))
    (define-key keymap "C-g" 'lem/prompt-window::prompt-quit)
    (define-key keymap "Escape" 'lem/prompt-window::prompt-quit)
    keymap))

;;; --- safe directory-local activation ------------------------------------

(defun project-outline-symbol-name-p (value name)
  (and (symbolp value) (string-equal (symbol-name value) name)))

(defun project-outline-function-quote-reader (stream character)
  "Read only the #' form needed by the audited directory-local declaration."
  (declare (ignore character))
  (unless (eql (read-char stream nil nil t) #\')
    (error "Unsupported directory-local reader dispatch"))
  (list 'function (read stream t nil t)))

(defun project-outline-read-dir-locals (pathname)
  "Read one bounded directory-local form without permitting reader evaluation."
  (handler-case
      (with-open-file (stream pathname
                              :direction :input
                              :element-type '(unsigned-byte 8))
        (let* ((limit *project-outline-dir-locals-byte-limit*)
               (octets (make-array (1+ limit)
                                   :element-type '(unsigned-byte 8)))
               (length 0))
          (loop
            (let ((next (read-sequence octets stream :start length)))
              (when (= next length) (return))
              (setf length next)
              (when (> length limit)
                (return-from project-outline-read-dir-locals nil))))
          (let ((contents
                  (babel:octets-to-string octets
                                          :end length
                                          :encoding :utf-8
                                          :errorp t)))
          (let ((*read-eval* nil)
                (*readtable* (copy-readtable nil))
                (*package* (find-package :lem-yath))
                (eof (gensym "EOF")))
            ;; Reject #., circular labels, arrays, structures, pathnames, and
            ;; every other dispatch form rather than merely declining to use
            ;; the resulting object.
            (set-macro-character
             #\# #'project-outline-function-quote-reader nil *readtable*)
            (with-input-from-string (input contents :end length)
              (let ((form (read input nil eof)))
                (and (not (eq form eof))
                     (eq (read input nil eof) eof)
                     form)))))))
    (error () nil)))

(defun project-outline-local-binding-p (option)
  "Whether OPTION is the exact safe C-c i -> consult-outline declaration."
  (and (consp option)
       (project-outline-symbol-name-p (car option) "EVAL")
       (let ((form (cdr option)))
         (and (listp form)
              (= (length form) 3)
              (project-outline-symbol-name-p
               (first form) "LOCAL-SET-KEY")
              (let ((key-form (second form)))
                (and (listp key-form)
                     (= (length key-form) 2)
                     (project-outline-symbol-name-p (first key-form) "KBD")
                     (string= (second key-form) "C-c i")))
              (let ((command-form (third form)))
                (and (listp command-form)
                     (= (length command-form) 2)
                     (project-outline-symbol-name-p
                      (first command-form) "FUNCTION")
                     (project-outline-symbol-name-p
                      (second command-form) "CONSULT-OUTLINE")))))))

(defun project-outline-declared-regexp (form)
  "Return the configured outline regexp when FORM declares this exact binding."
  (handler-case
      (let ((mode-entry
              (find-if
               (lambda (entry)
                 (and (consp entry)
                      (project-outline-symbol-name-p
                       (car entry) "EMACS-LISP-MODE")))
               form)))
        (when mode-entry
          (let* ((options (cdr mode-entry))
                 (regexp-option
                   (find-if
                    (lambda (option)
                      (and (consp option)
                           (project-outline-symbol-name-p
                            (car option) "OUTLINE-REGEXP")))
                    options))
                 (regexp (and regexp-option (cdr regexp-option))))
            (when (and (stringp regexp)
                       (string= regexp ";;;")
                       (some #'project-outline-local-binding-p options))
              regexp))))
    (error () nil)))

(defun project-outline-directory-config (buffer)
  "Return regexp and root declared for BUFFER, without evaluating local forms."
  (alexandria:when-let* ((filename (buffer-filename buffer))
                         (directory
                           (uiop:pathname-directory-pathname filename))
                         (root (find-up directory ".dir-locals.el"))
                         (file (merge-pathnames ".dir-locals.el" root))
                         (form (project-outline-read-dir-locals file))
                         (regexp (project-outline-declared-regexp form)))
    (values regexp root)))

(define-minor-mode lem-yath-project-outline-mode
    (:name "ProjectOutline"
     :description "Directory-local Consult-style outline navigation."
     :hide-from-modeline t))

;; A minor-mode map precedes every Vi state map in pinned Lem, which would
;; shadow the intentional Insert/Visual C-c i LLM binding.  Expose this local
;; binding only in the two states where the Emacs directory-local map applies.
(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-elisp-mode:elisp-mode))
  (declare (ignore mode))
  (let ((state (lem-vi-mode/core:current-state)))
    (when (and (mode-active-p
                (current-buffer) 'lem-yath-project-outline-mode)
               (or (typep state 'lem-vi-mode/states:normal)
                   (typep state 'lem-yath-emacs-state)))
      (list *project-outline-keymap*))))

(defun configure-project-outline-mode ()
  "Enable the outline binding only where the audited .dir-locals declares it."
  (multiple-value-bind (regexp root)
      (project-outline-directory-config (current-buffer))
    (setf (buffer-value (current-buffer) 'lem-yath-project-outline-regexp)
          regexp
          (buffer-value (current-buffer) 'lem-yath-project-outline-root)
          root)
    (lem-yath-project-outline-mode (not (null regexp)))))

(defun ensure-project-outline-mode (&optional buffer)
  "Apply the safe local declaration once BUFFER has its final mode and path."
  (save-excursion
    (when buffer (setf (current-buffer) buffer))
    (let* ((buffer (current-buffer))
           (filename (buffer-filename buffer)))
      (when (and filename
                 (mode-active-p buffer 'lem-elisp-mode:elisp-mode)
                 (not (equal filename
                             (buffer-value
                              buffer 'lem-yath-project-outline-checked-file))))
        (configure-project-outline-mode)
        (setf (buffer-value buffer 'lem-yath-project-outline-checked-file)
              filename)))))

;;; --- candidates and point placement -------------------------------------

(defun project-outline-candidates (buffer regexp)
  "Return BUFFER headings matching the configured literal REGEXP in source order."
  (let ((candidates '()))
    (with-current-buffer buffer
      (with-point ((point (buffer-start-point buffer)))
        (loop
          (let ((line (line-string point)))
            ;; The only accepted declaration is the literal ";;;" regexp.
            (when (alexandria:starts-with-subseq regexp line)
              (push (make-project-outline-candidate
                     :label line
                     :line (line-number-at-point point)
                     :point (copy-point point))
                    candidates)))
          (unless (line-offset point 1) (return)))))
    (nreverse candidates)))

(defun project-outline-delete-candidates (candidates)
  (dolist (candidate candidates)
    (ignore-errors (delete-point (project-outline-candidate-point candidate)))))

(defun project-outline-initialism-offset
    (component label case-sensitive-p)
  (let ((initials '())
        (positions '()))
    (loop :for index :from 0 :below (length label)
          :for character := (char label index)
          :when (and (alphanumericp character)
                     (or (zerop index)
                         (not (alphanumericp (char label (1- index))))))
            :do (push character initials)
                (push index positions))
    (let* ((initials (coerce (nreverse initials) 'string))
           (positions (nreverse positions))
           (match (search component initials
                          :test (if case-sensitive-p #'char= #'char-equal))))
      (and match (nth match positions)))))

(defun project-outline-component-offset
    (component label case-sensitive-p)
  "Return the first Prescient-style match offset for COMPONENT in LABEL."
  (or (search component label
              :test (if case-sensitive-p #'char= #'char-equal))
      (handler-case
          (nth-value
           0 (ppcre:scan
              (ppcre:create-scanner
               component :case-insensitive-mode (not case-sensitive-p))
              label))
        (error () nil))
      (project-outline-initialism-offset
       component label case-sensitive-p)))

(defun project-outline-match-offset (input label)
  "Return Consult-like placement at the earliest highlighted input match."
  (let* ((components (prescient-split-query (or input "")))
         (case-sensitive-p (prescient-case-sensitive-p (or input "")))
         (offsets
           (remove nil
                   (mapcar
                    (lambda (component)
                      (project-outline-component-offset
                       component label case-sensitive-p))
                    components))))
    (if offsets (reduce #'min offsets) 0)))

;;; --- preview and completion ---------------------------------------------

(defun project-outline-session-restorable-p (session)
  (let ((buffer (project-outline-session-source-buffer session))
        (window (project-outline-session-source-window session)))
    (and (project-picker-live-buffer-p buffer)
         (project-picker-live-window-p window)
         (eq (window-buffer window) buffer)
         (alive-point-p (project-outline-session-origin-point session))
         (alive-point-p (project-outline-session-origin-view-point session)))))

(defun project-outline-restore-origin (session)
  (when (project-outline-session-restorable-p session)
    (let ((window (project-outline-session-source-window session))
          (buffer (project-outline-session-source-buffer session)))
      (with-current-window window
        (move-point (buffer-point buffer)
                    (project-outline-session-origin-point session))
        (move-point (window-view-point window)
                    (project-outline-session-origin-view-point session))
        (setf (window-parameter window 'lem-core::horizontal-scroll-start)
              (project-outline-session-origin-horizontal-scroll-start
               session))))))

(defun project-outline-restore-source-state (session)
  "Restore the Vi state that owned the source window before the prompt."
  (let ((window (project-outline-session-source-window session))
        (state (project-outline-session-origin-state session)))
    ;; A completion prompt that previews another window can leave pinned Lem
    ;; in its temporary VI-MODELINE state after prompt teardown.
    (when (and state
               (project-picker-live-window-p window)
               (eq (current-window) window))
      (setf (lem-vi-mode/core:current-state) state))))

(defun project-outline-delete-origin-points (session)
  (dolist (point (list (project-outline-session-origin-point session)
                       (project-outline-session-origin-view-point session)))
    (when point (ignore-errors (delete-point point))))
  (setf (project-outline-session-origin-point session) nil
        (project-outline-session-origin-view-point session) nil))

(defun project-outline-current-input ()
  (or (ignore-errors (lem/prompt-window::get-input-string)) ""))

(defun project-outline-move-to-candidate (session candidate input)
  (let ((window (project-outline-session-source-window session))
        (buffer (project-outline-session-source-buffer session))
        (point (project-outline-candidate-point candidate)))
    (when (and (project-outline-session-restorable-p session)
               (alive-point-p point)
               (eq (point-buffer point) buffer))
      (with-current-window window
        (move-point (buffer-point buffer) point)
        (line-start (buffer-point buffer))
        (character-offset
         (buffer-point buffer)
         (min (project-outline-match-offset
               input (project-outline-candidate-label candidate))
              (length (line-string (buffer-point buffer)))))
        (window-recenter window)))))

(defun project-outline-clear-preview (session)
  (when (project-outline-session-preview-candidate session)
    (project-outline-restore-origin session)
    (setf (project-outline-session-preview-candidate session) nil
          (project-outline-session-preview-input session) nil)))

(defun project-outline-preview (session candidate)
  (let ((input (project-outline-current-input)))
    (when (and (project-outline-session-active-p session)
               (or (not (eq candidate
                            (project-outline-session-preview-candidate
                             session)))
                   (not (string= input
                                 (or (project-outline-session-preview-input
                                      session)
                                     "")))))
      (project-outline-clear-preview session)
      (project-outline-move-to-candidate session candidate input)
      (setf (project-outline-session-preview-candidate session) candidate
            (project-outline-session-preview-input session) input))))

(defun project-outline-completion-item (session candidate input)
  (with-point ((start (lem/prompt-window::current-prompt-start-point))
               (end (lem/prompt-window::current-prompt-start-point)))
    (let ((candidate candidate))
      (lem/completion-mode:make-completion-item
       :label
       (format nil "~vd ~a"
               (project-outline-session-line-number-width session)
               (project-outline-candidate-line candidate)
               (project-outline-candidate-label candidate))
       :filter-text (project-outline-candidate-label candidate)
       :insert-text (project-outline-candidate-label candidate)
       :start start
       :end (line-end end)
       :focus-action
       (lambda (context)
         (declare (ignore context))
         (project-outline-preview session candidate))
       :accept-action
       (lambda ()
         (setf (project-outline-session-selected session) candidate
               (project-outline-session-selected-input session)
               input))))))

(defun project-outline-completion-items (session input)
  (mapcar
   (lambda (candidate)
     (project-outline-completion-item session candidate input))
   (prescient-filter
    input
    (project-outline-session-candidates session)
    :key #'project-outline-candidate-label
    :category :project-outline
    :rank-p nil)))

(defun project-outline-completion-observer (session event item)
  (case event
    (:present
     (unless item (project-outline-clear-preview session)))
    (:end
     (project-outline-clear-preview session))))

(defun project-outline-install-completion-options (session)
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
        (declare (ignore context))
        (project-outline-completion-observer session event item))))))

(defun project-outline-read-candidate (session)
  (let ((*project-outline-session* session)
        (*prompt-after-activate-hook*
          (cons (cons (lambda ()
                        (project-outline-install-completion-options session))
                      0)
                *prompt-after-activate-hook*)))
    (prompt-for-string
     "Go to heading: "
     :completion-function
     (lambda (input)
       (project-outline-completion-items session input))
     :test-function
     (lambda (input)
       (alexandria:when-let
           ((selected (project-outline-session-selected session)))
         (string= input (project-outline-candidate-label selected))))
     :history-symbol 'lem-yath-project-outline
     :special-keymap *project-outline-prompt-keymap*))
  (project-outline-session-selected session))

(defun project-outline-final-jump (session candidate)
  (project-outline-restore-origin session)
  (when (project-outline-session-restorable-p session)
    (with-current-window (project-outline-session-source-window session)
      (lem-vi-mode/jumplist:with-jumplist
        (project-outline-move-to-candidate
         session candidate
         (or (project-outline-session-selected-input session) "")))
      (jump-feedback-after-jump))))

(defun project-outline-make-session ()
  (let* ((buffer (current-buffer))
         (regexp (buffer-value buffer 'lem-yath-project-outline-regexp))
         (candidates (and regexp
                          (project-outline-candidates buffer regexp)))
         (window (current-window)))
    (unless regexp
      (editor-error "No directory-local outline configuration"))
    (unless candidates
      (editor-error "No headings"))
    (make-project-outline-session
     :source-buffer buffer
     :source-window window
     :origin-point (copy-point (buffer-point buffer))
     :origin-view-point (copy-point (window-view-point window))
     :origin-horizontal-scroll-start
     (window-parameter window 'lem-core::horizontal-scroll-start)
     :origin-state (lem-vi-mode/core:current-state)
     :candidates candidates
     :line-number-width
     (length (princ-to-string
              (line-number-at-point (buffer-end-point buffer))))
     :active-p t)))

(define-command lem-yath-consult-outline () ()
  "Select and preview a configured directory-local outline heading."
  (let ((session (project-outline-make-session)))
    (unwind-protect
         (let ((selected (project-outline-read-candidate session)))
           (when selected
             (project-outline-final-jump session selected)))
      (unwind-protect
           (unwind-protect
                (ignore-errors (project-outline-clear-preview session))
             (ignore-errors (project-outline-restore-source-state session))
             (setf (project-outline-session-active-p session) nil))
        (project-outline-delete-candidates
         (project-outline-session-candidates session))
        (project-outline-delete-origin-points session)))))

(define-key *project-outline-keymap*
  "C-c i" 'lem-yath-consult-outline)

(add-hook lem-elisp-mode:*elisp-mode-hook* 'configure-project-outline-mode)
(remove-hook *find-file-hook* 'ensure-project-outline-mode)
(remove-hook *switch-to-buffer-hook* 'ensure-project-outline-mode)
(remove-hook *pre-command-hook* 'ensure-project-outline-mode)
(add-hook *find-file-hook* 'ensure-project-outline-mode)
(add-hook *switch-to-buffer-hook* 'ensure-project-outline-mode)
(add-hook *pre-command-hook* 'ensure-project-outline-mode)
