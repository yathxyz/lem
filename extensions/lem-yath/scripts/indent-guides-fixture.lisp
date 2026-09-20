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

(defun indent-guides-test-line-indentation ()
  ;; Keep the original point-walking implementation as a differential oracle.
  (flet ((reference (point)
           (with-point ((scan point))
             (line-start scan)
             (let ((column 0)
                   (width (variable-value 'tab-width :default scan)))
               (loop :for character := (character-at scan)
                     :do (case character
                           (#\Space (incf column) (character-offset scan 1))
                           (#\Tab
                            (incf column (- width (mod column width)))
                            (character-offset scan 1))
                           (otherwise
                            (return (values column
                                            (or (null character)
                                                (eql character #\Newline)))))))))))
    (let ((buffer (make-buffer "indentation-scan-test" :temporary t))
          (cases 0))
      (unwind-protect
           (progn
             (dolist (prefix (list "" "  " (string #\Tab)
                                   (format nil " ~c" #\Tab)
                                   (format nil "~c " #\Tab)
                                   (format nil "~c~c " #\Tab #\Tab)
                                   (make-string 37 :initial-element #\Space)))
               (dolist (suffix (list "" "x" "λ" (string #\Page)
                                     (string #\Return) (string (code-char 160))))
                 (dolist (terminated '(nil t))
                   (let ((text (concatenate 'string (format nil "before~%")
                                            prefix suffix
                                            (if terminated
                                                (format nil "~%after") ""))))
                     (erase-buffer buffer)
                     (insert-string (buffer-point buffer) text)
                     (let ((tick (buffer-modified-tick buffer)))
                       (dolist (width '(1 2 4 8 16))
                         (setf (variable-value 'tab-width :buffer buffer) width)
                         (with-point ((point (buffer-start-point buffer)))
                           (move-to-line point 2)
                           ;; Every column includes BOL, the indentation boundary
                           ;; and EOL; buffer-local width changes between scans.
                           (dotimes (column (1+ (+ (length prefix) (length suffix))))
                             (let ((position (position-at-point point)))
                               (assert (equal (multiple-value-list (reference point))
                                              (multiple-value-list
                                               (point-line-indentation point))))
                               (assert (= position (position-at-point point)))
                               (incf cases))
                             (when (< column (+ (length prefix) (length suffix)))
                               (character-offset point 1)))))
                       (assert (= tick (buffer-modified-tick buffer)))
                       (assert (string= text (buffer-text buffer))))))))
             (indent-guides-test-log
              "LINE-INDENTATION cases=~d correct=yes unchanged=yes" cases))
        (delete-buffer buffer)))))

(defun indent-guides-test-string-limits (buffer)
  (let ((original (symbol-function 'in-string-p))
        (queries 0)
        (unchanged t)
        (text (buffer-text buffer))
        (tick (buffer-modified-tick buffer)))
    (unwind-protect
         (with-point ((point (buffer-start-point buffer)))
           (sb-ext:without-package-locks
             (setf (symbol-function 'in-string-p)
                   (lambda (point)
                     (incf queries)
                     (funcall original point))))
           ;; Exercise code, blank context and a multiline string with the
           ;; actual buffer syntax, including the exact fast-path boundary.
           (dolist (line '(2 5 10))
             (move-to-line point line)
             (dolist (spacing '(1 2 3 4 8 16))
               (loop :for indentation :from 0 :to (1+ spacing)
                     :do (unless (= indentation
                                    (string-limited-indentation
                                     point indentation spacing))
                           (setf unchanged nil)))))
           (indent-guides-test-log
            "SMALL-LIMITS unchanged=~a queries=~d"
            (if unchanged "yes" "no") queries)
           ;; The original fixture opens its string at column four. Deeper
           ;; indentation must still stop at that opening context.
           (let ((correct t))
             (move-to-line point 10)
             (dolist (case '((1 20 5) (2 20 5) (4 6 5) (4 20 5)
                             (8 20 9) (16 20 17)))
               (destructuring-bind (spacing indentation expected) case
                 (unless (= expected
                            (string-limited-indentation point indentation spacing))
                   (setf correct nil))))
             (move-to-line point 2)
             (unless (= 20 (string-limited-indentation point 20 4))
               (setf correct nil))
             (indent-guides-test-log
              "DEEP-LIMITS correct=~a unchanged=~a"
              (if correct "yes" "no")
              (if (and (= tick (buffer-modified-tick buffer))
                       (string= text (buffer-text buffer))) "yes" "no"))))
      (sb-ext:without-package-locks
        (setf (symbol-function 'in-string-p) original)))))

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
  (indent-guides-test-line-indentation)
  (indent-guides-test-string-limits buffer)
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
