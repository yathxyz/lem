;;;; Completion: Vertico + Prescient + Marginalia prompt behavior.
;;;;
;;;; The live Emacs configuration uses Prescient inside Vertico minibuffers:
;;;; literal, regexp, or initialism matching for every space-separated
;;;; component, followed by persistent recency/frequency sorting.  Orderless
;;;; remains the global completion style outside Vertico and is handled by the
;;;; in-buffer completion work separately.  File prompts deliberately retain
;;;; Lem's path-aware completion and receive ranking only.

(in-package :lem-yath)

(defun completion-label (item)
  (handler-case (lem/completion-mode:completion-item-label item)
    (error () (princ-to-string item))))

(defparameter *completion-history-limit* 100)
(defparameter *completion-frequency-decay* 0.997d0)
(defparameter *completion-frequency-threshold* 0.05d0)

(defvar *completion-history* (make-hash-table :test 'equal))
(defvar *completion-frequency* (make-hash-table :test 'equal))
(defvar *completion-ranking-loaded-p* nil)
(defvar *completion-ranking-dirty-p* nil)
(defvar *completion-current-category* nil)

(defun completion-ranking-pathname ()
  "Persistent Prescient-compatible usage data for prompt candidates."
  (or (alexandria:when-let ((override
                             (uiop:getenv "LEM_YATH_COMPLETION_STATE_FILE")))
        (unless (zerop (length override))
          (pathname override)))
      (merge-pathnames
       "lem-yath/completion-ranking.sexp"
       (uiop:ensure-directory-pathname
        (or (uiop:getenv "XDG_STATE_HOME")
            (merge-pathnames ".local/state/" (user-homedir-pathname)))))))

(defun completion-load-ranking ()
  (unless *completion-ranking-loaded-p*
    (setf *completion-ranking-loaded-p* t)
    (alexandria:when-let ((path (uiop:probe-file*
                                (completion-ranking-pathname))))
      (handler-case
          (with-open-file (stream path :direction :input)
            (let ((*read-eval* nil)
                  (state (read stream nil nil)))
              (when (and (listp state) (eql 1 (getf state :version)))
                (dolist (entry (getf state :history))
                  (when (and (listp entry)
                             (= 2 (length entry))
                             (stringp (first entry))
                             (integerp (second entry)))
                    (setf (gethash (first entry) *completion-history*)
                          (second entry))))
                (dolist (entry (getf state :frequency))
                  (when (and (listp entry)
                             (= 2 (length entry))
                             (stringp (first entry))
                             (numberp (second entry)))
                    (setf (gethash (first entry) *completion-frequency*)
                          (coerce (second entry) 'double-float)))))))
        (error ()
          (clrhash *completion-history*)
          (clrhash *completion-frequency*))))))

(defun completion-hash-entries (table)
  (sort (loop :for key :being :each :hash-key :of table
                :using (hash-value value)
              :collect (list key value))
        #'string-lessp :key #'first))

(defun completion-save-ranking ()
  (when *completion-ranking-dirty-p*
    (handler-case
        (let ((path (completion-ranking-pathname)))
          (ensure-directories-exist path)
          (with-open-file (stream path
                                  :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
            (let ((*print-readably* t))
              (print (list :version 1
                           :history (completion-hash-entries
                                     *completion-history*)
                           :frequency (completion-hash-entries
                                       *completion-frequency*))
                     stream)))
          (setf *completion-ranking-dirty-p* nil))
      (error (condition)
        ;; Completion ranking must never prevent a clean editor shutdown.
        (message "Could not save completion ranking: ~a" condition)))))

(defun completion-record-candidate (candidate)
  "Remember CANDIDATE using Prescient's recency and decayed frequency model."
  (completion-load-ranking)
  (unless (or (null candidate) (zerop (length candidate)))
    (let ((old-position (gethash candidate *completion-history*
                                 *completion-history-limit*)))
      (maphash
       (lambda (other position)
         (cond
           ((< position old-position)
            (setf (gethash other *completion-history*) (1+ position)))
           ((>= position (1- *completion-history-limit*))
            (remhash other *completion-history*))))
       *completion-history*)
      (setf (gethash candidate *completion-history*) 0))
    (incf (gethash candidate *completion-frequency* 0d0))
    (maphash
     (lambda (other frequency)
       (let ((decayed (* frequency *completion-frequency-decay*)))
         (if (< decayed *completion-frequency-threshold*)
             (remhash other *completion-frequency*)
             (setf (gethash other *completion-frequency*) decayed))))
     *completion-frequency*)
    (setf *completion-ranking-dirty-p* t)))

(defun completion-candidate-before-p (left right key)
  (let* ((left-label (funcall key left))
         (right-label (funcall key right))
         (left-position (gethash left-label *completion-history*
                                 *completion-history-limit*))
         (right-position (gethash right-label *completion-history*
                                  *completion-history-limit*))
         (left-frequency (gethash left-label *completion-frequency* 0d0))
         (right-frequency (gethash right-label *completion-frequency* 0d0)))
    (or (< left-position right-position)
        (and (= left-position right-position)
             (or (> left-frequency right-frequency)
                 (and (= left-frequency right-frequency)
                      (< (length left-label) (length right-label))))))))

(defun completion-sort-candidates (candidates &key (key #'identity))
  (completion-load-ranking)
  (stable-sort (copy-list candidates)
               (lambda (left right)
                 (completion-candidate-before-p left right key))))

(defun prescient-split-query (query)
  "Split QUERY like Prescient: one space separates; doubled spaces are literal."
  (let* ((query (or query ""))
         (length (length query)))
    (cond
      ((every (lambda (character) (char= character #\Space)) query)
       (if (<= length 1)
           nil
           (list (make-string (1- length) :initial-element #\Space))))
      (t
       (let* ((start (if (and (plusp length)
                              (char= (char query 0) #\Space))
                         1 0))
              (end (if (and (< start length)
                            (char= (char query (1- length)) #\Space))
                       (1- length) length))
              (components '())
              (current (make-string-output-stream))
              (index start))
         (labels ((finish-component ()
                    (let ((component (get-output-stream-string current)))
                      (unless (zerop (length component))
                        (push component components)))
                    (setf current (make-string-output-stream))))
           (loop :while (< index end)
                 :for character := (char query index)
                 :do (if (char/= character #\Space)
                         (progn
                           (write-char character current)
                           (incf index))
                         (let ((run-start index))
                           (loop :while (and (< index end)
                                             (char= (char query index) #\Space))
                                 :do (incf index))
                           (let ((count (- index run-start)))
                             (if (= count 1)
                                 (finish-component)
                                 (loop :repeat (1- count)
                                       :do (write-char #\Space current)))))))
           (finish-component)
           (nreverse components)))))))

(defun prescient-case-sensitive-p (query)
  (some #'upper-case-p query))

(defun prescient-literal-match-p (component label case-sensitive-p)
  (search component label :test (if case-sensitive-p #'char= #'char-equal)))

(defun prescient-regexp-match-p (component label case-sensitive-p)
  (handler-case
      (not (null (ppcre:scan
                  (ppcre:create-scanner
                   component :case-insensitive-mode (not case-sensitive-p))
                  label)))
    (error () nil)))

(defun prescient-initials (label)
  (coerce
   (loop :for index :from 0 :below (length label)
         :for character := (char label index)
         :when (and (alphanumericp character)
                    (or (zerop index)
                        (not (alphanumericp (char label (1- index))))))
           :collect character)
   'string))

(defun prescient-initialism-match-p (component label case-sensitive-p)
  (search component (prescient-initials label)
          :test (if case-sensitive-p #'char= #'char-equal)))

(defun prescient-component-match-p (component label case-sensitive-p)
  (or (prescient-literal-match-p component label case-sensitive-p)
      (prescient-regexp-match-p component label case-sensitive-p)
      (prescient-initialism-match-p component label case-sensitive-p)))

(defun prescient-filter (input candidates
                         &key (key #'identity) (category :generic))
  "Filter and rank CANDIDATES like the active Vertico-Prescient setup.

Every query component may match literally, as a regexp, or as an initialism;
all components must match.  Uppercase input makes matching case-sensitive."
  (setf *completion-current-category* category)
  (let* ((components (prescient-split-query input))
         (case-sensitive-p (prescient-case-sensitive-p (or input "")))
         (filtered
           (if (null components)
               candidates
               (remove-if-not
                (lambda (candidate)
                  (let ((label (funcall key candidate)))
                    (every (lambda (component)
                             (prescient-component-match-p
                              component label case-sensitive-p))
                           components)))
                candidates))))
    (completion-sort-candidates filtered :key key)))

(defvar *default-command-completion* *prompt-command-completion-function*)
(defvar *default-buffer-completion* *prompt-buffer-completion-function*)
(defvar *default-file-completion* *prompt-file-completion-function*)

(setf *prompt-command-completion-function*
      (lambda (input &rest args)
        (prescient-filter input
                          (apply *default-command-completion* "" args)
                          :key #'completion-label
                          :category :command)))

(setf *prompt-buffer-completion-function*
      (lambda (input &rest args)
        (prescient-filter input
                          (apply *default-buffer-completion* "" args)
                          :key #'completion-label
                          :category :buffer)))

(setf *prompt-file-completion-function*
      (lambda (input directory &rest args)
        (setf *completion-current-category* :file)
        (completion-sort-candidates
         (apply *default-file-completion* input directory args)
         :key #'completion-label)))

(defun completion-file-history-label (input)
  (let* ((trailing-slash-p
           (and (plusp (length input))
                (char= (char input (1- (length input))) #\/)))
         (components (remove-if
                      (lambda (component) (zerop (length component)))
                      (uiop:split-string input :separator "/")))
         (last (car (last components))))
    (when last
      (if trailing-slash-p
          (concatenate 'string last "/")
          last))))

(defun completion-record-current-prompt ()
  (alexandria:when-let ((prompt
                         (lem/prompt-window:current-prompt-window)))
    (let* ((input (lem/prompt-window::get-input-string))
           (test (lem/prompt-window::prompt-window-existing-test-function
                  prompt)))
      (when (and (plusp (length input))
                 (or (null test) (funcall test input)))
        (completion-record-candidate
         (if (eq *completion-current-category* :file)
             (completion-file-history-label input)
             input))))))

(define-command lem-yath-prompt-execute () ()
  "Execute the current prompt and remember valid completion choices."
  (completion-record-current-prompt)
  (lem/prompt-window::prompt-execute))

(define-key lem/prompt-window::*prompt-mode-keymap*
  "Return" 'lem-yath-prompt-execute)

(defun completion-prompt-active-p ()
  (alexandria:when-let ((prompt
                         (lem/prompt-window:current-prompt-window)))
    (eq (current-buffer) (window-buffer prompt))))

(defun completion-prompt-context ()
  "Return the current, fully presented prompt completion context."
  (alexandria:when-let* ((prompt
                          (lem/prompt-window:current-prompt-window))
                         (context
                          lem/completion-mode::*completion-context*)
                         (popup
                          (lem/completion-mode::context-popup-menu context)))
    (when (and (eq (current-buffer) (window-buffer prompt))
               (eq (lem/completion-mode::context-buffer context)
                   (current-buffer))
               (= (lem/completion-mode::context-presented-generation context)
                  (lem/completion-mode::context-generation context)))
      context)))

(defun completion-focused-item ()
  (alexandria:when-let* ((context (completion-prompt-context))
                         (popup
                          (lem/completion-mode::context-popup-menu context)))
    (lem/popup-menu:get-focus-item popup)))

(define-command lem-yath-completion-return () ()
  "Accept the focused prompt candidate and submit it with one Return."
  (if (completion-prompt-active-p)
      (alexandria:when-let* ((prompt
                              (lem/prompt-window:current-prompt-window))
                             (context (completion-prompt-context))
                             (popup
                              (lem/completion-mode::context-popup-menu
                               context)))
        (lem:popup-menu-select popup)
        ;; Acceptance normally closes CONTEXT.  Do not submit stale input if a
        ;; callback refused the selection or deliberately opened a replacement.
        (when (and (eq prompt
                       (lem/prompt-window:current-prompt-window))
                   (null lem/completion-mode::*completion-context*))
          (lem-yath-prompt-execute)))
      (lem/completion-mode::completion-select)))

(define-command lem-yath-completion-tab () ()
  "Insert the focused prompt candidate without closing the prompt."
  (if (completion-prompt-active-p)
      (alexandria:when-let ((item (completion-focused-item)))
        (lem/completion-mode::completion-insert (current-point) item)
        (lem/completion-mode:completion-refresh))
      (lem/completion-mode::completion-narrowing-down-or-next-line)))

(defun completion-prompt-history (command)
  "Run prompt history COMMAND and reopen automatic completion."
  (lem/completion-mode:completion-end)
  (funcall command)
  (lem/prompt-window::open-prompt-completion))

(define-command lem-yath-completion-previous-history () ()
  "Use M-p for prompt history and retain candidate movement elsewhere."
  (if (completion-prompt-active-p)
      (completion-prompt-history
       #'lem/prompt-window::prompt-previous-history)
      (lem/completion-mode::completion-previous-line)))

(define-command lem-yath-completion-next-history () ()
  "Use M-n for prompt history and retain candidate movement elsewhere."
  (if (completion-prompt-active-p)
      (completion-prompt-history
       #'lem/prompt-window::prompt-next-history)
      (lem/completion-mode::completion-next-line)))

(define-key lem/completion-mode::*completion-mode-keymap*
  "Return" 'lem-yath-completion-return)
(define-key lem/completion-mode::*completion-mode-keymap*
  "Tab" 'lem-yath-completion-tab)
(define-key lem/completion-mode::*completion-mode-keymap*
  "M-p" 'lem-yath-completion-previous-history)
(define-key lem/completion-mode::*completion-mode-keymap*
  "M-n" 'lem-yath-completion-next-history)
(define-key lem/prompt-window::*prompt-mode-keymap*
  "M-p" 'lem-yath-completion-previous-history)
(define-key lem/prompt-window::*prompt-mode-keymap*
  "M-n" 'lem-yath-completion-next-history)

(defun completion-reset-current-category ()
  (setf *completion-current-category* nil))

(add-hook *prompt-activate-hook* 'completion-reset-current-category)
(add-hook *exit-editor-hook* 'completion-save-ranking)

;; vertico-like: show the candidate list immediately, not only on TAB.
(setf *automatic-tab-completion* t)

;; Lem binds Space in the completion popup to insert-space-and-cancel,
;; which kills multi-token Prescient input ("roam fi" closes the popup at
;; the space). In a prompt, Space must insert and re-filter instead; in
;; ordinary buffers the stock cancel behavior is right (a space ends the
;; symbol being completed).
(define-command lem-yath-completion-space () ()
  "Insert a space; in a prompt, keep filtering the completion popup."
  (insert-character (current-point) #\Space)
  (let ((prompt (lem/prompt-window:current-prompt-window)))
    (cond
      ((and prompt (eq (current-buffer) (window-buffer prompt)))
       (lem/completion-mode:completion-refresh))
      ((lem/completion-mode:completion-local-filtering-p)
       (lem/completion-mode:completion-refresh))
      (t
       (lem/completion-mode:completion-end)))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "Space" 'lem-yath-completion-space)
