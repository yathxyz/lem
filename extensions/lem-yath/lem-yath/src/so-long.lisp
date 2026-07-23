;;;; GNU So Long's configured automatic guard for pathological file lines.
;;;;
;;;; The Emacs configuration enables global-so-long-mode with uncustomized
;;;; defaults.  Detect before Lem enters the selected language mode so an
;;;; excessive line cannot first activate its parser, LSP client, linter, or
;;;; other programming-buffer machinery.  The rest of the find-file hooks still
;;;; run normally against the deliberately basic read-only mode.

(in-package :lem-yath)

(defconstant +so-long-threshold+ 10000)

(defvar *global-so-long-mode-enabled* t)

(defparameter *so-long-document-mode-classes*
  '(("LEM-MARKDOWN-MODE" . "MARKDOWN-MODE")
    ("LEM-ASCIIDOC-MODE" . "ASCIIDOC-MODE")
    ("LEM-YATH" . "TYPST-MODE")
    ("LEM-YATH" . "ORG-MODE")
    ("LEM-PATCH-MODE" . "PATCH-MODE")
    ("LEM-REVIEW-MODE" . "REVIEW-MODE"))
  "Lem modes corresponding to Emacs text-mode or special-mode buffers.")

(defparameter *so-long-plain-text-extensions*
  '("txt" "text" "md" "markdown" "org" "rst" "adoc" "asciidoc")
  "Document extensions which Lem may otherwise leave in Fundamental mode.")

(defstruct so-long-state
  original-mode
  read-only-p
  line-wrap-p
  highlight-line-p)

(defun so-long-buffer-active-p (&optional (buffer (current-buffer)))
  (not (null (buffer-value buffer 'lem-yath-so-long-state))))

(defun so-long-effective-file-mode (buffer)
  "Return the final configured mode candidate for BUFFER without enabling it."
  (or (and (fboundp 'configured-language-path-mode)
           (funcall (symbol-function 'configured-language-path-mode) buffer))
      (lem-core::detect-file-mode buffer)
      'lem/buffer/fundamental-mode:fundamental-mode))

(defun so-long-plain-text-file-p (buffer)
  (alexandria:when-let* ((filename (buffer-filename buffer))
                         (type (pathname-type (pathname filename))))
    (member (string-downcase type)
            *so-long-plain-text-extensions*
            :test #'string=)))

(defun so-long-document-mode-p (mode-object)
  (some (lambda (class-name)
          (mode-object-typep mode-object class-name))
        *so-long-document-mode-classes*))

(defun so-long-target-mode-p (buffer mode)
  "Whether MODE represents one of GNU So Long's default target families."
  (cond
    ((eq mode 'lem/buffer/fundamental-mode:fundamental-mode)
     ;; Emacs targets Fundamental mode, but ordinary .txt-style files enter
     ;; text-mode there and therefore are not part of the default policy.
     (not (so-long-plain-text-file-p buffer)))
    (t
     (alexandria:when-let
         ((mode-object (ignore-errors (ensure-mode-object mode))))
       (and (typep mode-object 'lem/language-mode:language-mode)
            (not (so-long-document-mode-p mode-object)))))))

(defun so-long-buffer-excessive-p (buffer)
  "Whether BUFFER contains a line over 10,000 UTF-8 bytes, without copying it."
  (with-point ((start (buffer-start-point buffer)))
    (loop :for line := (point-line start)
            :then (lem/buffer/line:line-next line)
          :while line
          :thereis
          (> (babel:string-size-in-octets
              (lem/buffer/line:line-string line) :encoding :utf-8)
             +so-long-threshold+))))

(define-major-mode lem-yath-so-long-mode ()
    (:name "So Long"
     :keymap *lem-yath-so-long-mode-keymap*)
  ;; GNU So Long's defaults make the buffer read-only and turn truncation off
  ;; so vertical motion does not scan to the distant end of a clipped line.
  (setf (buffer-read-only-p (current-buffer)) t
        (variable-value 'line-wrap :buffer (current-buffer)) t
        (variable-value 'highlight-line :buffer (current-buffer)) nil))

(defun so-long-activate-buffer (buffer original-mode)
  (unless (so-long-buffer-active-p buffer)
    (setf (buffer-value buffer 'lem-yath-so-long-state)
          (make-so-long-state
           :original-mode original-mode
           :read-only-p (buffer-read-only-p buffer)
           :line-wrap-p (variable-value 'line-wrap :default buffer)
           :highlight-line-p
           (variable-value 'highlight-line :default buffer)))
    (change-buffer-mode buffer 'lem-yath-so-long-mode)
    (message
     "Very long line detected; using So Long mode. C-c C-c restores ~a"
     (mode-name original-mode)))
  buffer)

(defun so-long-process-file (buffer)
  "So Long-aware replacement for Lem's core file-mode selection hook."
  (cond
    ((so-long-buffer-active-p buffer) nil)
    (*global-so-long-mode-enabled*
     (let ((mode (so-long-effective-file-mode buffer)))
       (if (and (so-long-target-mode-p buffer mode)
                (so-long-buffer-excessive-p buffer))
           (so-long-activate-buffer buffer mode)
           (lem-core::process-file buffer))))
    (t
     (lem-core::process-file buffer))))

(defun so-long-before-save-process-file (buffer)
  "Keep an active So Long buffer basic; otherwise retain core save behavior."
  (unless (or (so-long-buffer-active-p buffer)
              (variable-value 'find-file-literally :default buffer))
    (lem-core::process-file buffer)))

(define-command so-long-revert () ()
  "Restore the major mode and presentation replaced by automatic So Long."
  (let* ((buffer (current-buffer))
         (state (buffer-value buffer 'lem-yath-so-long-state)))
    (unless state
      (editor-error "So Long mitigation is not active in this buffer"))
    (let ((mode (so-long-state-original-mode state)))
      (setf (buffer-read-only-p buffer) nil)
      (handler-case
          (progn
            (change-buffer-mode buffer mode)
            (setf (buffer-read-only-p buffer)
                  (so-long-state-read-only-p state)
                  (variable-value 'line-wrap :buffer buffer)
                  (so-long-state-line-wrap-p state)
                  (variable-value 'highlight-line :buffer buffer)
                  (so-long-state-highlight-line-p state)
                  (buffer-value buffer 'lem-yath-so-long-state) nil)
            (message "Restored ~a after So Long mitigation" (mode-name mode)))
        (error (condition)
          ;; A failing language hook must not leave the pathological buffer in
          ;; an uncertain, writable half-mode.  Return to the known-safe mode.
          (change-buffer-mode buffer 'lem-yath-so-long-mode)
          (setf (buffer-value buffer 'lem-yath-so-long-state) state)
          (editor-error "Could not restore ~a: ~a" (mode-name mode) condition))))))

(define-command global-so-long-mode () ()
  "Toggle automatic So Long mitigation for subsequently visited files."
  (setf *global-so-long-mode-enabled*
        (not *global-so-long-mode-enabled*))
  (message "Global So Long mode ~:[disabled~;enabled~]"
           *global-so-long-mode-enabled*))

(define-key *lem-yath-so-long-mode-keymap* "C-c C-c" 'so-long-revert)

(defun install-so-long-file-policy ()
  "Replace core mode selection idempotently at its original hook boundaries."
  (remove-hook *find-file-hook* 'lem-core::process-file)
  (remove-hook *find-file-hook* 'so-long-process-file)
  (add-hook *find-file-hook* 'so-long-process-file 5000)
  (remove-hook (variable-value 'before-save-hook :global t)
               'lem-core::process-file)
  (remove-hook (variable-value 'before-save-hook :global t)
               'so-long-before-save-process-file)
  (add-hook (variable-value 'before-save-hook :global t)
            'so-long-before-save-process-file))

(install-so-long-file-policy)
