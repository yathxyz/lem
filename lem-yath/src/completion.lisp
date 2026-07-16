;;;; Completion: Vertico + Prescient + Marginalia prompt behavior.
;;;;
;;;; The live Emacs configuration uses Prescient inside Vertico minibuffers:
;;;; directional character-folded literal, regexp, or initialism matching for
;;;; every space-separated component, followed by persistent recency/frequency
;;;; sorting.  Orderless
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

(defun completion-character-test (case-sensitive-p)
  (if case-sensitive-p #'char= #'char-equal))

(defun completion-literal-matcher (component case-sensitive-p)
  (let ((test (completion-character-test case-sensitive-p)))
    (lambda (candidate)
      (not (null (search component candidate :test test))))))

(defun completion-character-fold-string (text)
  "Return TEXT compatibility-decomposed without Unicode combining marks."
  (handler-case
      (sb-unicode:normalize-string
       text :nfkd
       (lambda (character)
         (not (member (sb-unicode:general-category character)
                      '(:mn :mc :me)))))
    (error () text)))

(defun completion-canonical-string (text)
  "Return TEXT in canonical decomposed form."
  (handler-case (sb-unicode:normalize-string text :nfd)
    (error () text)))

(defparameter *completion-character-fold-punctuation*
  '((#\" . "\"«»“”„‟❝❞❠⹂〝〞〟＂🙶🙷🙸")
    (#\' . "'‘’‚‛‹›❛❜❟❮❯＇")
    (#\` . "``‘‛‹❛❮｀")))

(defun completion-combining-mark-p (character)
  (member (sb-unicode:general-category character) '(:mn :mc :me)))

(defun completion-canonical-clusters (text)
  "Return canonical base-plus-combining-mark clusters for TEXT."
  (let ((clusters '())
        (current nil))
    (labels ((finish-cluster ()
               (when current
                 (push (coerce (nreverse current) 'string) clusters)
                 (setf current nil))))
      (loop :for character :across (completion-canonical-string text)
            :do (if (and current
                         (completion-combining-mark-p character))
                    (push character current)
                    (progn
                      (finish-cluster)
                      (push character current))))
      (finish-cluster)
      (nreverse clusters))))

(defstruct (completion-fold-form
             (:constructor make-completion-fold-form
                 (text unit-map canonicals ranges boundaries)))
  text
  unit-map
  canonicals
  ranges
  boundaries)

(defun completion-build-fold-form (text)
  "Build a compatibility-folded string retaining source-cluster identity."
  (let* ((clusters (completion-canonical-clusters text))
         (folded-units
           (mapcar (lambda (cluster)
                     (let ((folded
                             (completion-character-fold-string cluster)))
                       ;; A standalone combining mark must remain matchable.
                       (if (zerop (length folded)) cluster folded)))
                   clusters))
         (folded-length (reduce #'+ folded-units
                                :key #'length :initial-value 0))
         (folded (make-string folded-length))
         (unit-map (make-array folded-length :element-type 'fixnum))
         (canonicals (coerce clusters 'vector))
         (ranges (make-array (length clusters)))
         (boundaries
           (make-array (1+ folded-length)
                       :element-type 'bit :initial-element 0))
         (offset 0))
    (setf (sbit boundaries 0) 1)
    (loop :for unit :in folded-units
          :for unit-index :from 0
          :for end := (+ offset (length unit))
          :do (replace folded unit :start1 offset)
              (loop :for index :from offset :below end
                    :do (setf (aref unit-map index) unit-index))
              (setf (aref ranges unit-index) (cons offset end)
                    (sbit boundaries end) 1
                    offset end))
    (make-completion-fold-form
     folded unit-map canonicals ranges boundaries)))

(defun completion-fold-character-match-p
    (query-character candidate-character case-sensitive-p)
  (or (funcall (completion-character-test case-sensitive-p)
               query-character candidate-character)
      (alexandria:when-let
          ((equivalents
             (cdr (assoc query-character
                         *completion-character-fold-punctuation*))))
        (find candidate-character equivalents :test #'char=))))

(defun completion-fold-string-equal-p
    (left right case-sensitive-p)
  (and (= (length left) (length right))
       (loop :for left-character :across left
             :for right-character :across right
             :always (funcall (completion-character-test case-sensitive-p)
                              left-character right-character))))

(defun completion-fold-protected-unit-p (canonical)
  "Whether CANONICAL came from an explicitly non-ASCII query cluster."
  (or (/= 1 (length canonical))
      (> (char-code (char canonical 0)) 127)))

(defun completion-fold-protected-units-match-p
    (query candidate candidate-start case-sensitive-p)
  (loop
    :with query-ranges := (completion-fold-form-ranges query)
    :with query-canonicals := (completion-fold-form-canonicals query)
    :with candidate-map := (completion-fold-form-unit-map candidate)
    :with candidate-canonicals :=
      (completion-fold-form-canonicals candidate)
    :for query-unit-index :from 0 :below (length query-canonicals)
    :for canonical := (aref query-canonicals query-unit-index)
    :when (completion-fold-protected-unit-p canonical)
      :unless
        (let* ((query-range (aref query-ranges query-unit-index))
               (candidate-range-start
                 (+ candidate-start (car query-range)))
               (candidate-range-end
                 (+ candidate-start (cdr query-range)))
               (candidate-unit-index
                 (aref candidate-map candidate-range-start)))
          (and (loop :for index :from candidate-range-start
                     :below candidate-range-end
                     :always (= candidate-unit-index
                                (aref candidate-map index)))
               (completion-fold-string-equal-p
                canonical
                (aref candidate-canonicals candidate-unit-index)
                case-sensitive-p)))
        :do (return nil)
    :finally (return t)))

(defun completion-fold-form-match-p
    (query candidate case-sensitive-p)
  "Search CANDIDATE for QUERY without splitting compatibility characters."
  (let* ((query-text (completion-fold-form-text query))
         (candidate-text (completion-fold-form-text candidate))
         (query-length (length query-text))
         (candidate-length (length candidate-text))
         (boundaries (completion-fold-form-boundaries candidate)))
    (loop :for start :from 0 :to (- candidate-length query-length)
          :for end := (+ start query-length)
          :when (and (= 1 (sbit boundaries start))
                     (= 1 (sbit boundaries end))
                     (loop :for query-index :from 0 :below query-length
                           :always
                             (completion-fold-character-match-p
                              (char query-text query-index)
                              (char candidate-text (+ start query-index))
                              case-sensitive-p))
                     (completion-fold-protected-units-match-p
                      query candidate start case-sensitive-p))
            :do (return t)
          :finally (return nil))))

(defun completion-character-fold-matcher (component case-sensitive-p)
  "Match COMPONENT literally using pinned directional character folding.

An ASCII component can match diacritic, compatibility, and configured quote
variants.  A non-ASCII component is not silently simplified."
  (let ((literal (completion-literal-matcher component case-sensitive-p))
        (query (completion-build-fold-form component))
        (cache (make-hash-table :test 'equal)))
    (lambda (candidate)
      (or (funcall literal candidate)
          (multiple-value-bind (form present-p) (gethash candidate cache)
            (unless present-p
              (setf form (completion-build-fold-form candidate)
                    (gethash candidate cache) form))
            (completion-fold-form-match-p
             query form case-sensitive-p))))))

(defun prescient-regexp-scanner (component case-sensitive-p)
  "Compile COMPONENT once for a candidate batch, or return NIL if invalid."
  (handler-case
      (ppcre:create-scanner
       component :case-insensitive-mode (not case-sensitive-p))
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

(defun prescient-component-matcher (component case-sensitive-p)
  "Compile Prescient's literal, regexp, and initialism methods for COMPONENT."
  (let ((literal
          (completion-character-fold-matcher component case-sensitive-p))
        (regexp (prescient-regexp-scanner component case-sensitive-p)))
    (lambda (label)
      (or (funcall literal label)
          (and regexp (ppcre:scan regexp label))
          (prescient-initialism-match-p
           component label case-sensitive-p)))))

(defun prescient-filter (input candidates
                         &key (key #'identity) (category :generic)
                           (rank-p t))
  "Filter and rank CANDIDATES like the active Vertico-Prescient setup.

Every query component may match as a character-folded literal, regexp, or
initialism; all components must match.  Character folding is directional and
uppercase input makes matching case-sensitive.  When RANK-P is false, preserve
the provider's source-defined order."
  (setf *completion-current-category* category)
  (let* ((components (prescient-split-query input))
         (case-sensitive-p (prescient-case-sensitive-p (or input "")))
         (matchers
           (mapcar (lambda (component)
                     (prescient-component-matcher
                      component case-sensitive-p))
                   components))
         (filtered
           (if (null matchers)
               candidates
               (remove-if-not
                (lambda (candidate)
                  (let ((label (funcall key candidate)))
                    (every (lambda (matcher)
                             (funcall matcher label))
                           matchers)))
                candidates))))
    (if rank-p
        (completion-sort-candidates filtered :key key)
        filtered)))

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
  (cond
    ((completion-prompt-active-p)
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
         (lem-yath-prompt-execute))))
    ((and (fboundp 'auto-completion-session-owned-p)
          (funcall 'auto-completion-session-owned-p))
     (funcall 'auto-completion-return))
    (t
     (lem/completion-mode::completion-select))))

(define-command lem-yath-completion-tab () ()
  "Insert the focused prompt candidate without closing the prompt."
  (cond
    ((completion-prompt-active-p)
     (alexandria:when-let ((item (completion-focused-item)))
       (lem/completion-mode::completion-insert (current-point) item)
       (lem/completion-mode:completion-refresh)))
    ((and (fboundp 'auto-completion-session-owned-p)
          (funcall 'auto-completion-session-owned-p))
     (funcall 'auto-completion-tab))
    (t
     (lem/completion-mode::completion-narrowing-down-or-next-line))))

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

;;; Vertico-style zero-result recovery ---------------------------------------

(defparameter *prompt-completion-edit-commands*
  '(lem/completion-mode::completion-self-insert
    lem/completion-mode::completion-delete-previous-char
    lem/completion-mode::completion-backward-delete-word
    lem-yath-completion-space)
  "Completion commands that can end a prompt context after editing its input.")

(defun prompt-completion-edit-command-p (command)
  "Whether COMMAND may have edited the current prompt input.

Ordinary prompt edits carry Lem's EDITABLE-ADVICE marker.  Completion-mode's
fallback editing commands do not, so name those explicitly."
  (and command
       (or (typep command 'lem:editable-advice)
           (member (command-name command)
                   *prompt-completion-edit-commands*))))

(defun reopen-empty-prompt-completion-after-command ()
  "Reopen automatic prompt completion after a zero-result edit.

Lem ends a synchronous completion context when its provider returns no items.
Keep that ordinary lifecycle for non-prompt completion, but let the next prompt
edit query the provider again like Vertico.  This covers both deleting back
into a valid query and regexp input that becomes valid after another character."
  (when (and (completion-prompt-active-p)
             (null lem/completion-mode::*completion-context*)
             (prompt-completion-edit-command-p (this-command)))
    (lem/prompt-window::open-prompt-completion)))

(remove-hook *post-command-hook*
             'reopen-empty-prompt-completion-after-command)
(add-hook *post-command-hook*
          'reopen-empty-prompt-completion-after-command)
