(in-package :lem-yath)

(defvar *indent-guides-test-report*
  (uiop:getenv "LEM_YATH_INDENT_GUIDES_REPORT"))
(defvar *indent-guides-test-code*
  (uiop:getenv "LEM_YATH_INDENT_GUIDES_CODE"))
(defvar *indent-guides-test-prose*
  (uiop:getenv "LEM_YATH_INDENT_GUIDES_PROSE"))
(defvar *indent-guides-test-source*
  (or (uiop:getenv "LEM_YATH_INDENT_GUIDES_SOURCE")
      (merge-pathnames "src/indent-guides.lisp"
                       (asdf:system-source-directory "lem-yath"))))
(defvar *indent-guides-test-original-text* nil)

(defun indent-guides-test-log (control &rest arguments)
  (with-open-file (stream *indent-guides-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun indent-guides-test-line (buffer line-number)
  (with-point ((point (buffer-start-point buffer)))
    (when (> line-number 1)
      (line-offset point (1- line-number)))
    (let* ((active-modes
             (lem-core::get-active-modes-class-instance buffer))
           (lem-core::*active-modes* active-modes)
           (line (lem-core::create-logical-line point nil active-modes)))
      (lem-core::logical-line-string line))))

(defun indent-guides-test-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across string
          :do (case character
                (#\Space (write-char #\. stream))
                (#\Tab (write-string "<TAB>" stream))
                (#\│ (write-char #\│ stream))
                (otherwise (write-char character stream))))))

(defun indent-guides-test-record-line (label buffer line-number)
  (indent-guides-test-log
   "LINE label=~a number=~d text=~a"
   label
   line-number
   (indent-guides-test-encode
    (indent-guides-test-line buffer line-number))))

(defun indent-guides-test-open (filename)
  (find-file filename)
  (current-buffer))

(defun indent-guides-test-record-code ()
  (let ((buffer (indent-guides-test-open *indent-guides-test-code*)))
    (setf (variable-value 'lem/language-mode:indent-size :buffer buffer) 4)
    (indent-guides-test-record-line "level-one" buffer 2)
    (indent-guides-test-record-line "level-two" buffer 3)
    (indent-guides-test-record-line "level-three" buffer 4)
    (indent-guides-test-record-line "blank-context" buffer 5)
    (indent-guides-test-record-line "tab-expanded" buffer 7)
    (indent-guides-test-record-line "string-limited" buffer 10)
    (indent-guides-test-log
     "CODE programming=~a enabled=~a modified=~a bytes-same=~a transformer=~a"
     (if (programming-buffer-p buffer) "yes" "no")
     (if (variable-value 'lem-yath-indent-guides :default buffer) "yes" "no")
     (if (buffer-modified-p buffer) "yes" "no")
     (if (string= *indent-guides-test-original-text* (buffer-text buffer))
         "yes" "no")
     (if (eq (variable-value
              'lem-core::display-line-transform-function :global)
             'transform-lem-yath-display-line)
         "yes" "no"))))

(define-command lem-yath-test-indent-guides-code-screen () ()
  (let ((buffer (indent-guides-test-open *indent-guides-test-code*)))
    (setf (variable-value 'lem/language-mode:indent-size :buffer buffer) 4)
    (move-point (current-point) (buffer-start-point buffer))
    (line-offset (current-point) 3)
    (redraw-display :force t)
    (indent-guides-test-log
     "SCREEN code line=~d column=~d modified=~a"
     (line-number-at-point (current-point))
     (point-charpos (current-point))
     (if (buffer-modified-p buffer) "yes" "no"))))

(define-command lem-yath-test-indent-guides-prose () ()
  (let ((buffer (indent-guides-test-open *indent-guides-test-prose*)))
    (indent-guides-test-record-line "prose" buffer 3)
    (redraw-display :force t)
    (indent-guides-test-log
     "PROSE programming=~a enabled=~a modified=~a"
     (if (programming-buffer-p buffer) "yes" "no")
     (if (variable-value 'lem-yath-indent-guides :default buffer) "yes" "no")
     (if (buffer-modified-p buffer) "yes" "no"))))

(define-command lem-yath-test-indent-guides-toggle () ()
  (let ((buffer (indent-guides-test-open *indent-guides-test-code*)))
    (setf (variable-value 'lem/language-mode:indent-size :buffer buffer) 4)
    (lem-yath-toggle-indent-guides)
    (indent-guides-test-record-line "disabled" buffer 4)
    (lem-yath-toggle-indent-guides)
    (indent-guides-test-record-line "reenabled" buffer 4)
    (indent-guides-test-log
     "TOGGLE enabled=~a modified=~a bytes-same=~a"
     (if (variable-value 'lem-yath-indent-guides :default buffer) "yes" "no")
     (if (buffer-modified-p buffer) "yes" "no")
     (if (string= *indent-guides-test-original-text* (buffer-text buffer))
         "yes" "no"))))

(define-command lem-yath-test-indent-guides-reload () ()
  (load *indent-guides-test-source*)
  (load *indent-guides-test-source*)
  (let ((buffer (indent-guides-test-open *indent-guides-test-code*)))
    (setf (variable-value 'lem/language-mode:indent-size :buffer buffer) 4)
    (indent-guides-test-record-line "reloaded" buffer 4)
    (indent-guides-test-log
     "RELOAD transformer=~a enabled=~a"
     (if (eq (variable-value
              'lem-core::display-line-transform-function :global)
             'transform-lem-yath-display-line)
         "yes" "no")
     (if (variable-value 'lem-yath-indent-guides :default buffer)
         "yes" "no"))))

(define-command lem-yath-test-indent-guides-blank-cursor () ()
  (let ((buffer (indent-guides-test-open *indent-guides-test-code*)))
    (setf (variable-value 'lem/language-mode:indent-size :buffer buffer) 4)
    (move-point (current-point) (buffer-start-point buffer))
    (line-offset (current-point) 4)
    (let* ((active-modes
             (lem-core::get-active-modes-class-instance buffer))
           (lem-core::*active-modes* active-modes)
           (line
             (lem-core::create-logical-line
              (current-point)
              (lem-core::get-window-overlays (current-window))
              active-modes))
           (cursor-index
             (loop :for (start end attribute)
                     :in (lem-core::logical-line-attributes line)
                   :when (and (< start end)
                              (lem-core::cursor-attribute-p attribute))
                     :return start)))
      (indent-guides-test-log
       "BLANK-CURSOR line=~d column=~d text=~a cursor=~a eol=~a modified=~a"
       (line-number-at-point (current-point))
       (point-charpos (current-point))
       (indent-guides-test-encode (lem-core::logical-line-string line))
       (or cursor-index "none")
       (if (lem-core::logical-line-end-of-line-cursor-attribute line)
           "yes" "no")
       (if (buffer-modified-p buffer) "yes" "no")))
    (redraw-display :force t)))

(let ((buffer (indent-guides-test-open *indent-guides-test-code*)))
  (setf *indent-guides-test-original-text* (buffer-text buffer)
        (variable-value 'lem/language-mode:indent-size :buffer buffer) 4)
  (indent-guides-test-record-code)
  (move-point (current-point) (buffer-start-point buffer))
  (line-offset (current-point) 3)
  (redraw-display :force t)
  (indent-guides-test-log "READY"))

(define-key *global-keymap* "F2" 'lem-yath-test-indent-guides-code-screen)
(define-key *global-keymap* "F3" 'lem-yath-test-indent-guides-prose)
(define-key *global-keymap* "F4" 'lem-yath-test-indent-guides-toggle)
(define-key *global-keymap* "F5" 'lem-yath-test-indent-guides-reload)
(define-key *global-keymap* "F6" 'lem-yath-test-indent-guides-blank-cursor)
