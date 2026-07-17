;;;; Git/VCS: Magit -> Legit, Majutsu -> a focused jj porcelain, and
;;;; prog-mode-local git-gutter behavior.

(in-package :lem-yath)

(defvar *lem-yath-jj-root-key* 'lem-yath-jj-root)
(defvar *lem-yath-jj-view-kind-key* 'lem-yath-jj-view-kind)
(defvar *lem-yath-jj-revision-key* 'lem-yath-jj-revision)
(defvar *lem-yath-git-gutter-synced-mode-key*
  'lem-yath-git-gutter-synced-mode)

;; Pinned Lem's Vi dispatcher places state maps ahead of ordinary major-mode
;; maps.  Legit's status and log panes are minor modes and already win, but its
;; diff, commit, and rebase buffers are major modes.  Register their native
;; maps explicitly so the Magit-like porcelain keys are not mistaken for Vi
;; motions and operators.
(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem/legit::legit-diff-mode))
  (list lem/legit::*legit-diff-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem/legit::legit-commit-mode))
  (list lem/legit::*legit-commit-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem/legit::legit-rebase-mode))
  (list lem/legit::*legit-rebase-mode-keymap*))

(defun legit-git-hunk-patch ()
  "Return a complete Git patch for the Legit hunk at point."
  (save-excursion
    (with-point ((start (copy-point (current-point)))
                 (end (copy-point (current-point)))
                 (header (copy-point (current-point))))
      (setf start (lem/legit::%hunk-start-point start))
      (unless start
        (editor-error "No hunk at point"))
      (move-point header start)
      (unless (search-backward-regexp header "^diff --git ")
        (editor-error "The current hunk has no Git patch header"))
      (move-point end start)
      (setf end (lem/legit::%hunk-end-point end))
      (format nil "~a~a~%"
              (points-to-string header start)
              (points-to-string start end)))))

(defun legit-git-diff-p ()
  (with-point ((point (current-point)))
    (not (null (search-backward-regexp point "^diff --git ")))))

(defun apply-legit-git-hunk (reverse)
  "Apply the current Legit hunk to Git's index, reversing when REVERSE."
  (let ((patch (legit-git-hunk-patch)))
    (uiop:with-temporary-file
        (:pathname patch-path :stream patch-stream
         :direction :output :element-type 'character)
      (write-string patch patch-stream)
      (finish-output patch-stream)
      (close patch-stream)
      (lem/legit::with-current-project (vcs)
        (declare (ignore vcs))
        (multiple-value-bind (output error-output status)
            (run-project-program
             (append
              (list (uiop:native-namestring
                     (or (executable-find "git")
                         (editor-error "Git is unavailable")))
                    "apply" "--ignore-space-change" "-C0"
                    "--index" "--cached")
              (when reverse (list "--reverse"))
              (list (uiop:native-namestring patch-path)))
             :directory (uiop:getcwd))
          (if (zerop status)
              (progn
                (lem/legit::show-legit-status)
                (message (if reverse "Unstaged hunk" "Staged hunk")))
              (lem/legit::pop-up-message
               (if (plusp (length error-output))
                   error-output
                   output))))))))

(define-command lem-yath-legit-stage-hunk () ()
  (if (legit-git-diff-p)
      (apply-legit-git-hunk nil)
      (lem/legit::legit-stage-hunk)))

(define-command lem-yath-legit-unstage-hunk () ()
  (if (legit-git-diff-p)
      (apply-legit-git-hunk t)
      (lem/legit::legit-unstage-hunk)))

(define-command lem-yath-legit-commit-continue () ()
  ;; This is a transient message buffer, not a file that needs saving.  Pinned
  ;; Legit otherwise commits successfully and then prompts before killing it.
  (unless (str:blankp
           (lem/legit::clean-commit-message
            (buffer-text (current-buffer))))
    (buffer-unmark (current-buffer)))
  (lem/legit::commit-continue))

(define-key lem/legit::*legit-diff-mode-keymap*
  "s" 'lem-yath-legit-stage-hunk)
(define-key lem/legit::*legit-diff-mode-keymap*
  "u" 'lem-yath-legit-unstage-hunk)
(define-key lem/legit::*legit-commit-mode-keymap*
  "C-c C-c" 'lem-yath-legit-commit-continue)
(define-key lem/legit::*legit-commit-mode-keymap*
  "C-Return" 'lem-yath-legit-commit-continue)

;; Defined later in the serial system, in ui.lisp.  Git state can be prepared
;; before the UI module loads, but rendering only happens after startup.
(declaim (ftype function join-left-display-content))
(declaim (ftype function run-project-program))
(declaim (special *project-process-timeout*))

(defparameter *legit-todo-result-limit* 200)
(defparameter *legit-todo-output-limit* (* 1024 1024))
(defparameter *legit-todo-timeout* 5)

(defstruct legit-todo
  path
  line
  text)

(defun parse-legit-todos (output)
  "Parse Git grep's NUL-delimited path, line, and text records."
  (let ((start 0)
        (length (length output))
        (results '()))
    (loop :while (and (< start length)
                      (< (length results) *legit-todo-result-limit*))
          :for path-end := (position #\Null output :start start)
          :for line-end := (and path-end
                                (position #\Null output
                                          :start (1+ path-end)))
          :for text-end := (and line-end
                                (or (position #\Newline output
                                              :start (1+ line-end))
                                    length))
          :while (and path-end line-end text-end)
          :for path := (subseq output start path-end)
          :for line := (parse-integer output
                                      :start (1+ path-end)
                                      :end line-end
                                      :junk-allowed t)
          :for text := (subseq output (1+ line-end) text-end)
          :when (and line (plusp line) (plusp (length path)))
            :do (push (make-legit-todo :path path :line line :text text)
                      results)
          :do (setf start (min length (1+ text-end))))
    (nreverse results)))

(defun collect-legit-todos (root)
  "Return bounded TODO/FIXME matches from tracked Git files below ROOT."
  (let ((git (or (executable-find "git")
                 (error "Git is unavailable"))))
    (let ((*project-process-timeout* *legit-todo-timeout*))
      (multiple-value-bind (output error-output status)
          (run-project-program
           (list (uiop:native-namestring git)
                 "grep" "-n" "-I" "-z" "-E" "(TODO|FIXME)" "--")
           :directory root
           :output-limit *legit-todo-output-limit*)
        (cond
          ((eql status 0) (parse-legit-todos output))
          ((eql status 1) '())
          (t
           (error "git grep failed (~a): ~a"
                  status
                  (completion-bounded-annotation error-output))))))))

(defun make-legit-todo-move-function (root todo)
  (let ((pathname (merge-pathnames (legit-todo-path todo) root))
        (line (legit-todo-line todo)))
    (lambda ()
      (let* ((buffer (find-file-buffer pathname))
             (point (buffer-point buffer)))
        (move-to-line point line)
        (line-start point)
        point))))

(defun insert-legit-todo-section (vcs collector)
  "Append a navigable tracked-file TODO/FIXME section to Legit status."
  (declare (ignore collector))
  (unless (string-equal "git" (lem/porcelain::vcs-name vcs))
    (return-from insert-legit-todo-section))
  (let ((root (uiop:ensure-directory-pathname (truename (uiop:getcwd)))))
    (handler-case
        (let ((todos (collect-legit-todos root)))
          (lem/legit::collector-insert "")
          (lem/legit::collector-insert
           (format nil "TODO/FIXME (~d):" (length todos)) :header t)
          (if todos
              (dolist (todo todos)
                (lem/legit::with-appending-source
                    (point
                     :move-function
                     (make-legit-todo-move-function root todo)
                     :visit-file-function
                     (let ((path (legit-todo-path todo)))
                       (lambda () path)))
                  (insert-string
                   point
                   (format nil "~a:~d: ~a"
                           (legit-todo-path todo)
                           (legit-todo-line todo)
                           (completion-bounded-annotation
                            (legit-todo-text todo)))
                   :attribute 'lem/legit::filename-attribute
                   :read-only t)))
              (lem/legit::collector-insert "<none>")))
      (error (condition)
        (lem/legit::collector-insert "")
        (lem/legit::collector-insert "TODO/FIXME (unavailable):" :header t)
        (lem/legit::collector-insert
         (completion-bounded-annotation (princ-to-string condition)))))))

(remove-hook lem/legit::*status-section-functions*
             'insert-legit-todo-section)
(add-hook lem/legit::*status-section-functions*
          'insert-legit-todo-section)

(defun vcs-directory (&optional (buffer (current-buffer)))
  "Return BUFFER's file directory, local directory, or Lem process directory."
  (or (and (buffer-filename buffer)
           (uiop:pathname-directory-pathname (buffer-filename buffer)))
      (ignore-errors (buffer-directory buffer))
      (uiop:getcwd)))

(defun jj-root (&optional directory)
  "Return the enclosing Jujutsu workspace root for DIRECTORY."
  (find-up (or directory (vcs-directory)) ".jj"))

(defun git-root (&optional directory)
  "Return the enclosing Git repository root for DIRECTORY."
  (find-up (or directory (vcs-directory)) ".git"))

(defun call-with-vcs-buffer-directory (directory function)
  "Call FUNCTION while the current buffer directory is temporarily DIRECTORY."
  (let* ((buffer (current-buffer))
         (old-directory
           (lem/buffer/internal::buffer-%directory buffer))
         (directory (uiop:ensure-directory-pathname directory)))
    (unwind-protect
         (progn
           (setf (buffer-directory buffer) directory)
           (funcall function))
      (unless (deleted-buffer-p buffer)
        (setf (lem/buffer/internal::buffer-%directory buffer)
              old-directory)))))

(defun run-jj (root arguments)
  "Run jj with direct ARGUMENTS at ROOT and return stdout, or signal an editor error."
  (let ((executable (executable-find "jj")))
    (unless executable
      (editor-error "The jj executable is unavailable"))
    (handler-case
        (multiple-value-bind (stdout stderr code)
            (uiop:run-program
             (append (list (namestring executable) "--color=never" "--no-pager")
                     arguments)
             :directory root
             :output :string
             :error-output :string
             :ignore-error-status t)
          (if (eql code 0)
              stdout
              (editor-error "jj ~a failed (~d): ~a"
                            (first arguments) code
                            (string-trim '(#\Space #\Tab #\Newline #\Return)
                                         stderr))))
      (editor-error (condition)
        (error condition))
      (error (condition)
        (editor-error "Could not run jj: ~a" condition)))))

(defparameter *jj-log-limit* 30)

(defparameter *jj-log-template*
  (concatenate
   'string
   "change_id.shortest(12) ++ \"\\0\" ++ "
   "commit_id.shortest(12) ++ \"\\0\" ++ "
   "if(current_working_copy, \"@\", \" \") ++ \"\\0\" ++ "
   "description.first_line() ++ \"\\0\""))

(defstruct jj-log-entry
  change-id
  commit-id
  marker
  description)

(defun jj-split-null-fields (text)
  "Split TEXT at NUL characters without interpreting its contents."
  (let ((start 0)
        (length (length text))
        (fields '()))
    (loop :while (< start length)
          :for end := (or (position #\Null text :start start) length)
          :do (push (subseq text start end) fields)
          :do (setf start (if (< end length) (1+ end) length)))
    (nreverse fields)))

(defun parse-jj-log-entries (output)
  "Parse the NUL-delimited log OUTPUT produced by `*jj-log-template*'."
  (let ((fields (jj-split-null-fields output)))
    (loop :while (>= (length fields) 4)
          :collect (make-jj-log-entry
                    :change-id (pop fields)
                    :commit-id (pop fields)
                    :marker (pop fields)
                    :description (pop fields)))))

(defun jj-log-entries (root)
  (parse-jj-log-entries
   (run-jj root
           (list "log" "--no-graph" "-n" (princ-to-string *jj-log-limit*)
                 "--template" *jj-log-template*))))

(defun jj-row-revision (&optional (point (current-point)))
  "Return the Jujutsu change ID attached to POINT's rendered row."
  (with-point ((line point))
    (line-start line)
    (text-property-at line *lem-yath-jj-revision-key*)))

(defun jj-insert-history (buffer entries)
  (let ((point (buffer-end-point buffer)))
    (insert-string point
                   (format nil "History (~d revisions)~%" *jj-log-limit*))
    (dolist (entry entries)
      (with-point ((start point))
        (insert-string
         point
         (format nil "~a ~12a ~12a  ~a~%"
                 (jj-log-entry-marker entry)
                 (jj-log-entry-change-id entry)
                 (jj-log-entry-commit-id entry)
                 (if (str:blankp (jj-log-entry-description entry))
                     "(no description)"
                     (jj-log-entry-description entry))))
        (put-text-property start point *lem-yath-jj-revision-key*
                           (jj-log-entry-change-id entry))))))

(defun jj-restore-revision-point (buffer revision)
  (when revision
    (with-point ((point (buffer-start-point buffer)))
      (loop
        (when (string= revision (or (jj-row-revision point) ""))
          (move-point (buffer-point buffer) point)
          (return t))
        (unless (line-offset point 1)
          (return nil))))))

(defun jj-buffer-name (root)
  "Return a repository-specific buffer name for Jujutsu workspace ROOT."
  (format nil "*lem-yath-jj: ~a*"
          (namestring (or (ignore-errors (truename root)) root))))

(define-minor-mode lem-yath-jj-view-mode
    (:name "Jujutsu"
     :keymap *lem-yath-jj-view-keymap*)
  "Majutsu-like navigation and mutation keys for Jujutsu buffers.")

(defun render-jj-buffer (buffer root)
  "Refresh BUFFER with row-aware Jujutsu data from ROOT."
  (let ((revision
          (save-excursion
            (setf (current-buffer) buffer)
            (jj-row-revision)))
        (status (run-jj root '("status")))
        (entries (jj-log-entries root)))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string
       (buffer-start-point buffer)
       (format nil "Jujutsu: ~a~%~%Status~%~a~%"
               (namestring root) status))
      (jj-insert-history buffer entries))
    (buffer-unmark buffer)
    (setf (buffer-directory buffer) root
          (buffer-value buffer *lem-yath-jj-root-key*) root
          (buffer-value buffer *lem-yath-jj-view-kind-key*) :log
          (buffer-read-only-p buffer) t)
    (unless (jj-restore-revision-point buffer revision)
      (buffer-start (buffer-point buffer)))
    buffer))

(defun render-jj-show-buffer (buffer root revision)
  "Render a read-only `jj show' view for REVISION."
  (let ((text (run-jj root (list "show" revision))))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-start-point buffer) text)
      (buffer-start (buffer-point buffer)))
    (buffer-unmark buffer)
    (setf (buffer-directory buffer) root
          (buffer-value buffer *lem-yath-jj-root-key*) root
          (buffer-value buffer *lem-yath-jj-view-kind-key*) :show
          (buffer-value buffer *lem-yath-jj-revision-key*) revision
          (buffer-read-only-p buffer) t)
    buffer))

(defun lem-yath-jj-log-at (directory)
  "Show Jujutsu status/log for the workspace enclosing DIRECTORY."
  (let ((root (jj-root directory)))
    (unless root
      (message "Not inside a Jujutsu workspace")
      (return-from lem-yath-jj-log-at))
    (let ((buffer (make-buffer (jj-buffer-name root) :directory root)))
      (change-buffer-mode
       buffer 'lem/buffer/fundamental-mode:fundamental-mode)
      (save-excursion
        (setf (current-buffer) buffer)
        (enable-minor-mode 'lem-yath-jj-view-mode))
      (render-jj-buffer buffer root)
      (switch-to-buffer buffer))))

(define-command lem-yath-jj-log () ()
  "Show the Jujutsu status and row-aware bounded history porcelain."
  (lem-yath-jj-log-at (vcs-directory)))

(define-command lem-yath-jj-refresh () ()
  "Refresh the current Jujutsu log or change view."
  (alexandria:if-let ((root (buffer-value (current-buffer)
                                          *lem-yath-jj-root-key*)))
    (progn
      (if (eq :show (buffer-value (current-buffer)
                                  *lem-yath-jj-view-kind-key*))
          (render-jj-show-buffer
           (current-buffer) root
           (buffer-value (current-buffer) *lem-yath-jj-revision-key*))
          (render-jj-buffer (current-buffer) root))
      (message "Jujutsu view refreshed"))
    (message "This is not a Jujutsu view")))

(defun jj-current-root ()
  (or (buffer-value (current-buffer) *lem-yath-jj-root-key*)
      (editor-error "This is not a Jujutsu view")))

(defun jj-selected-revision ()
  "Return the revision at point, defaulting to the working copy."
  (or (jj-row-revision) "@"))

(defun jj-refresh-after-mutation (root arguments success-message)
  "Run a mutating jj command and refresh the current porcelain."
  (run-jj root arguments)
  (render-jj-buffer (current-buffer) root)
  (message success-message))

(defun jj-description (root revision)
  (string-right-trim
   '(#\Newline #\Return)
   (run-jj root
           (list "log" "--no-graph" "-r" revision
                 "--template" "description"))))

(defun jj-single-parent-revision (root revision)
  "Return REVISION's sole parent, refusing roots and merge revisions."
  (let ((parents
          (jj-split-null-fields
           (run-jj root
                   (list "log" "--no-graph"
                         "-r" (format nil "(~a)-" revision)
                         "--template"
                         "change_id.shortest(12) ++ \"\\0\"")))))
    (cond
      ((null parents)
       (editor-error "The selected Jujutsu revision has no parent to squash into"))
      ((rest parents)
       (editor-error "Cannot squash a Jujutsu merge with this focused workflow"))
      (t (first parents)))))

(defun jj-combined-description (destination source)
  "Combine DESTINATION and SOURCE descriptions without losing either body."
  (cond
    ((str:blankp destination) source)
    ((str:blankp source) destination)
    (t (format nil "~a~%~%~a" destination source))))

(defun jj-squash-description (root revision parent policy)
  "Return the squash message selected by POLICY for REVISION and PARENT."
  (let ((source (jj-description root revision))
        (destination (jj-description root parent)))
    (ecase policy
      (:combine (jj-combined-description destination source))
      (:destination destination)
      (:source source))))

(defun jj-squash-keymap ()
  "Build the focused Majutsu-style squash popup."
  (let ((keymap (make-keymap :description "JJ Squash")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          '(("c" "squash; combine descriptions")
            ("d" "squash; destination description")
            ("r" "squash; source description")
            ("k" "squash; combine and keep emptied source")
            ("s" "squash; combine descriptions")
            ("Return" "squash; combine descriptions")
            ("q" "cancel")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun jj-execute-squash (root revision parent policy keep-emptied)
  "Squash REVISION into PARENT and keep point on the destination row."
  (let ((arguments
          (list "squash" "--revision" revision
                "--message"
                (jj-squash-description root revision parent policy))))
    (when keep-emptied
      (setf arguments (append arguments '("--keep-emptied"))))
    (run-jj root arguments)
    (let ((buffer (current-buffer)))
      (render-jj-buffer buffer root)
      (jj-restore-revision-point buffer parent))
    (message "Jujutsu change squashed")))

(defun dispatch-jj-squash (root revision parent)
  "Read and execute a focused whole-revision squash action."
  (unwind-protect
       (progn
         (let ((lem/transient:*transient-popup-delay* 0))
           (keymap-activate (jj-squash-keymap)))
         (redraw-display)
         (let* ((key (read-key))
                (name (lem-core::keyseq-to-string (list key))))
           (lem/transient::hide-transient)
           (cond
             ((or (string= name "s") (string= name "Return")
                  (string= name "c"))
              (jj-execute-squash root revision parent :combine nil))
             ((string= name "d")
              (jj-execute-squash root revision parent :destination nil))
             ((string= name "r")
              (jj-execute-squash root revision parent :source nil))
             ((string= name "k")
              (jj-execute-squash root revision parent :combine t))
             ((or (string= name "q") (string= name "Escape"))
              (message "Jujutsu squash cancelled"))
             (t (message "No squash action is bound to ~a" name)))))
    (lem/transient::hide-transient)))

(define-command lem-yath-jj-squash () ()
  "Squash the selected change into its sole parent, like Majutsu `s'."
  (let* ((root (jj-current-root))
         (revision (jj-selected-revision))
         (parent (jj-single-parent-revision root revision)))
    (dispatch-jj-squash root revision parent)))

(defun jj-prompt-for-rebase-destination (root)
  "Read a history change ID or arbitrary jj revset for a rebase destination."
  (let* ((entries (jj-log-entries root))
         (choices
           (mapcar (lambda (entry)
                     (cons (jj-log-entry-change-id entry) entry))
                   entries)))
    (prompt-for-string
     "Rebase destination revision or revset: "
     :completion-function
     (lambda (input)
       (completion-annotated-prompt-choices
        (prescient-filter input choices :key #'car :category :jj-revision)
        (lambda (entry)
          (format nil "~12a  ~a"
                  (jj-log-entry-commit-id entry)
                  (if (str:blankp (jj-log-entry-description entry))
                      "(no description)"
                      (jj-log-entry-description entry))))))
     :test-function (lambda (input) (not (str:blankp input)))
     :history-symbol 'lem-yath-jj-rebase-destination)))

(defun jj-rebase-keymap ()
  "Build the focused Majutsu-style rebase popup."
  (let ((keymap (make-keymap :description "JJ Rebase")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist (entry
              '(("Return" "branch onto destination")
                ("b" "branch onto destination")
                ("s" "selected revision and descendants onto destination")
                ("r" "selected revision only onto destination")
                ("a" "selected revision after destination")
                ("B" "selected revision before destination")
                ("q" "cancel")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun jj-rebase-arguments (revision destination action)
  "Return direct jj rebase arguments for row REVISION and popup ACTION."
  (ecase action
    (:branch
     (list "rebase" "--branch" revision "--destination" destination))
    (:source
     (list "rebase" "--source" revision "--destination" destination))
    (:revision
     (list "rebase" "--revisions" revision "--destination" destination))
    (:after
     (list "rebase" "--revisions" revision "--insert-after" destination))
    (:before
     (list "rebase" "--revisions" revision "--insert-before" destination))))

(defun jj-execute-rebase (root revision action)
  "Prompt for a destination and rebase row REVISION according to ACTION."
  (let ((destination (jj-prompt-for-rebase-destination root)))
    (if (prompt-for-y-or-n-p
         (format nil "Rebase Jujutsu revision ~a using ~a onto ~a?"
                 revision (string-downcase (symbol-name action)) destination))
        (progn
          (run-jj root (jj-rebase-arguments revision destination action))
          (let ((buffer (current-buffer)))
            (render-jj-buffer buffer root)
            (jj-restore-revision-point buffer revision))
          (message "Jujutsu rebase completed"))
        (message "Jujutsu rebase cancelled"))))

(defun dispatch-jj-rebase (root revision)
  "Read one focused Majutsu-style rebase action for REVISION."
  (unwind-protect
       (progn
         (let ((lem/transient:*transient-popup-delay* 0))
           (keymap-activate (jj-rebase-keymap)))
         (redraw-display)
         (let* ((key (read-key))
                (name (lem-core::keyseq-to-string (list key))))
           (lem/transient::hide-transient)
           (cond
             ((or (string= name "Return") (string= name "b"))
              (jj-execute-rebase root revision :branch))
             ((string= name "s")
              (jj-execute-rebase root revision :source))
             ((string= name "r")
              (jj-execute-rebase root revision :revision))
             ((string= name "a")
              (jj-execute-rebase root revision :after))
             ((string= name "B")
              (jj-execute-rebase root revision :before))
             ((or (string= name "q") (string= name "Escape"))
              (message "Jujutsu rebase cancelled"))
             (t (message "No rebase action is bound to ~a" name)))))
    (lem/transient::hide-transient)))

(define-command lem-yath-jj-rebase () ()
  "Rebase the selected change through a focused Majutsu-style popup."
  (dispatch-jj-rebase (jj-current-root) (jj-selected-revision)))

(define-command lem-yath-jj-describe () ()
  "Set the selected change's description, like Majutsu `c'."
  (let* ((root (jj-current-root))
         (revision (jj-selected-revision))
         (existing (jj-description root revision))
         (description
           (progn
             (when (or (find #\Newline existing) (find #\Return existing))
               (editor-error
                "This change has a multiline description; use jj describe to preserve it"))
             (prompt-for-string
              "Description: "
              :initial-value existing
              :history-symbol 'lem-yath-jj-description))))
    (jj-refresh-after-mutation
     root (list "describe" revision "--message" description)
     "Jujutsu description updated")))

(define-command lem-yath-jj-new () ()
  "Create a new change after the selected revision, like Majutsu `o'."
  (let* ((root (jj-current-root))
         (revision (jj-selected-revision))
         (description
           (prompt-for-string
            "New change description (optional): "
            :history-symbol 'lem-yath-jj-description))
         (arguments (list "new" revision)))
    (unless (str:blankp description)
      (setf arguments (append arguments (list "--message" description))))
    (jj-refresh-after-mutation root arguments "Jujutsu change created")))

(define-command lem-yath-jj-edit () ()
  "Edit the selected change in the working copy, like Majutsu `e'."
  (let ((root (jj-current-root))
        (revision (jj-selected-revision)))
    (jj-refresh-after-mutation
     root (list "edit" revision) "Jujutsu working copy changed")))

(define-command lem-yath-jj-undo () ()
  "Undo the last Jujutsu operation, like Majutsu `u'."
  (let ((root (jj-current-root)))
    (jj-refresh-after-mutation root '("undo") "Jujutsu operation undone")))

(define-command lem-yath-jj-redo () ()
  "Redo the last undone Jujutsu operation, like Majutsu `C-r'."
  (let ((root (jj-current-root)))
    (jj-refresh-after-mutation root '("redo") "Jujutsu operation redone")))

(define-command lem-yath-jj-abandon () ()
  "Confirm and abandon the selected change, like Majutsu `x'."
  (let ((root (jj-current-root))
        (revision (jj-selected-revision)))
    (if (prompt-for-y-or-n-p
         (format nil "Abandon Jujutsu revision ~a?" revision))
        (jj-refresh-after-mutation
         root (list "abandon" revision) "Jujutsu change abandoned")
        (message "Jujutsu abandon cancelled"))))

(defun jj-show-buffer-name (root revision)
  (format nil "*lem-yath-jj-show: ~a:~a*"
          (namestring (or (ignore-errors (truename root)) root)) revision))

(define-command lem-yath-jj-show () ()
  "Show the selected revision's patch in a read-only buffer."
  (let* ((root (jj-current-root))
         (revision (jj-selected-revision))
         (buffer
           (make-buffer (jj-show-buffer-name root revision) :directory root)))
    (change-buffer-mode buffer 'lem/buffer/fundamental-mode:fundamental-mode)
    (save-excursion
      (setf (current-buffer) buffer)
      (enable-minor-mode 'lem-yath-jj-view-mode))
    (render-jj-show-buffer buffer root revision)
    (switch-to-buffer buffer)))

(defun jj-move-to-revision-row (direction)
  (unless (eq :log (buffer-value (current-buffer)
                                 *lem-yath-jj-view-kind-key*))
    (editor-error "Revision navigation requires a Jujutsu log view"))
  (with-point ((point (current-point)))
    (loop
      (unless (line-offset point direction)
        (editor-error "No more Jujutsu revisions"))
      (when (jj-row-revision point)
        (move-point (current-point) point)
        (return)))))

(define-command lem-yath-jj-next-revision () ()
  "Move to the next rendered Jujutsu revision."
  (jj-move-to-revision-row 1))

(define-command lem-yath-jj-previous-revision () ()
  "Move to the previous rendered Jujutsu revision."
  (jj-move-to-revision-row -1))

(define-command lem-yath-jj-help () ()
  "Show the focused Majutsu-compatible Jujutsu command surface."
  (message
   "Jujutsu: c describe (one line), o new, s squash, r rebase, e edit, u undo, C-r redo, x abandon, d/RET show, C-j/C-k rows, g r refresh, q quit"))

(define-command lem-yath-jj-quit () ()
  "Quit the current Jujutsu status/log window."
  (if (buffer-value (current-buffer) *lem-yath-jj-root-key*)
      (quit-active-window)
      (message "This is not a Jujutsu status buffer")))

(defun jj-normal-g-keymap ()
  "Return vi normal state's existing `g' suffix keymap, if available."
  (alexandria:when-let
      ((prefix
         (lem-core::keymap-find lem-vi-mode:*normal-keymap*
                                (lem-core::parse-keyspec "g"))))
    (let ((suffix (lem-core::prefix-suffix prefix)))
      (when (typep suffix 'lem-core::keymap)
        suffix))))

;; Majutsu's Evil collection binds refresh at g r and leaves the rest of the
;; ordinary normal-state g prefix available.  Rebuild this subtree on reload.
(undefine-key *lem-yath-jj-view-keymap* "g")
(undefine-key *lem-yath-jj-view-keymap* "q")
(defparameter *lem-yath-jj-g-keymap*
  (make-keymap :description '*lem-yath-jj-g-keymap*
               :base (jj-normal-g-keymap)))
(define-key *lem-yath-jj-g-keymap* "r" 'lem-yath-jj-refresh)
(define-key *lem-yath-jj-g-keymap* "j" 'lem-yath-jj-next-revision)
(define-key *lem-yath-jj-g-keymap* "k" 'lem-yath-jj-previous-revision)
(define-key *lem-yath-jj-view-keymap* "g" *lem-yath-jj-g-keymap*)
(define-key *lem-yath-jj-view-keymap* "q" 'lem-yath-jj-quit)
(define-key *lem-yath-jj-view-keymap* "c" 'lem-yath-jj-describe)
(define-key *lem-yath-jj-view-keymap* "o" 'lem-yath-jj-new)
(define-key *lem-yath-jj-view-keymap* "s" 'lem-yath-jj-squash)
(define-key *lem-yath-jj-view-keymap* "r" 'lem-yath-jj-rebase)
(define-key *lem-yath-jj-view-keymap* "e" 'lem-yath-jj-edit)
(define-key *lem-yath-jj-view-keymap* "u" 'lem-yath-jj-undo)
(define-key *lem-yath-jj-view-keymap* "C-r" 'lem-yath-jj-redo)
(define-key *lem-yath-jj-view-keymap* "x" 'lem-yath-jj-abandon)
(define-key *lem-yath-jj-view-keymap* "d" 'lem-yath-jj-show)
(define-key *lem-yath-jj-view-keymap* "Return" 'lem-yath-jj-show)
(define-key *lem-yath-jj-view-keymap* "C-j" 'lem-yath-jj-next-revision)
(define-key *lem-yath-jj-view-keymap* "C-k" 'lem-yath-jj-previous-revision)
(define-key *lem-yath-jj-view-keymap* "]" 'lem-yath-jj-next-revision)
(define-key *lem-yath-jj-view-keymap* "[" 'lem-yath-jj-previous-revision)
(define-key *lem-yath-jj-view-keymap* "?" 'lem-yath-jj-help)

(defun lem-yath-legit-status-at (directory)
  "Open Legit at the Git root enclosing DIRECTORY."
  (let* ((directory (uiop:ensure-directory-pathname directory))
         (root (or (git-root directory) directory)))
    (call-with-vcs-buffer-directory
     root
     (lambda () (uiop:symbol-call :lem/legit :legit-status)))))

(define-command lem-yath-legit-status () ()
  "Open Legit at the enclosing Git root, like the configured Magit command."
  (lem-yath-legit-status-at (vcs-directory)))

(defun lem-yath-vcs-status-at (directory)
  "Dispatch to Jujutsu or Git for the repository enclosing DIRECTORY."
  (cond
    ((jj-root directory) (lem-yath-jj-log-at directory))
    ((git-root directory) (lem-yath-legit-status-at directory))
    (t (lem-yath-legit-status-at directory))))

(define-command lem-yath-vcs-status () ()
  "Smart VCS dispatch: jj repo -> jj log view, otherwise legit (git)."
  (lem-yath-vcs-status-at (vcs-directory)))

;;; Git gutter ---------------------------------------------------------------

(defun lem-yath-git-gutter-enable-buffer ()
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer *lem-yath-git-gutter-synced-mode-key*)
          (buffer-major-mode buffer))
    (when (buffer-filename buffer)
      (lem-git-gutter::update-git-gutter-for-buffer buffer))))

(defun lem-yath-git-gutter-clear-buffer (buffer)
  (lem-git-gutter::cancel-buffer-git-gutter-timer buffer)
  (setf (lem-git-gutter::buffer-git-gutter-changes buffer) nil)
  (lem-git-gutter::clear-git-gutter-overlays buffer))

(defun lem-yath-git-gutter-disable-buffer ()
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer *lem-yath-git-gutter-synced-mode-key*) nil)
    (lem-yath-git-gutter-clear-buffer buffer)))

(define-minor-mode lem-yath-git-gutter-mode
    (:name "GitGutter"
     :enable-hook 'lem-yath-git-gutter-enable-buffer
     :disable-hook 'lem-yath-git-gutter-disable-buffer)
  "Show Git changes only in buffers equivalent to Emacs `prog-mode'.")

(defun lem-yath-git-gutter-mode-active-p (buffer)
  (member 'lem-yath-git-gutter-mode (buffer-minor-modes buffer)))

(defun lem-yath-git-gutter-sync-buffer (buffer)
  "Enable or disable the buffer-local gutter according to BUFFER's major mode."
  (unless (deleted-buffer-p buffer)
    (let* ((wanted (programming-buffer-p buffer))
           (active (lem-yath-git-gutter-mode-active-p buffer))
           (mode (buffer-major-mode buffer))
           (synced-mode
             (buffer-value buffer *lem-yath-git-gutter-synced-mode-key*)))
      (cond
        ((and wanted (not active))
         (save-excursion
           (setf (current-buffer) buffer)
           (lem-yath-git-gutter-mode t)))
        ((and wanted (not (eq mode synced-mode)))
         (save-excursion
           (setf (current-buffer) buffer)
           (setf (buffer-value buffer
                               *lem-yath-git-gutter-synced-mode-key*)
                 mode)
           (when (buffer-filename buffer)
             (lem-git-gutter::update-git-gutter-for-buffer buffer))))
        ((and (not wanted) active)
         (save-excursion
           (setf (current-buffer) buffer)
           (lem-yath-git-gutter-mode nil)))))))

(defun lem-yath-git-gutter-find-file (buffer)
  (lem-yath-git-gutter-sync-buffer buffer))

(defun lem-yath-git-gutter-post-command ()
  (lem-yath-git-gutter-sync-buffer (current-buffer)))

(defun lem-yath-git-gutter-after-save (&optional (buffer (current-buffer)))
  (when (lem-yath-git-gutter-mode-active-p buffer)
    (lem-git-gutter::cancel-buffer-git-gutter-timer buffer)
    (lem-git-gutter::update-git-gutter-for-buffer buffer)))

(defun lem-yath-git-gutter-after-change (start end old-length)
  (declare (ignore end old-length))
  (let ((buffer (point-buffer start)))
    (when (and (buffer-filename buffer)
               (lem-yath-git-gutter-mode-active-p buffer))
      (alexandria:when-let
          ((existing (lem-git-gutter::buffer-git-gutter-timer buffer)))
        (stop-timer existing))
      (let (timer)
        (setf timer
              (start-timer
               (make-idle-timer
                (lambda ()
                  (when (and (not (deleted-buffer-p buffer))
                             (eq timer
                                 (lem-git-gutter::buffer-git-gutter-timer
                                  buffer)))
                    (setf (lem-git-gutter::buffer-git-gutter-timer buffer)
                          nil)
                    (when (and (buffer-filename buffer)
                               (programming-buffer-p buffer)
                               (lem-yath-git-gutter-mode-active-p buffer))
                      (lem-git-gutter::update-git-gutter-for-buffer buffer))))
                :name "lem-yath-git-gutter-update")
               lem-git-gutter:*git-gutter-update-delay*
               :repeat nil)
              (lem-git-gutter::buffer-git-gutter-timer buffer) timer)))))

(defun lem-yath-git-gutter-kill-buffer (&optional (buffer (current-buffer)))
  (when (or (lem-yath-git-gutter-mode-active-p buffer)
            (lem-git-gutter::buffer-git-gutter-timer buffer)
            (lem-git-gutter::buffer-git-gutter-changes buffer))
    (lem-yath-git-gutter-clear-buffer buffer)))

(defmethod lem-core:compute-left-display-area-content
    ((mode lem-yath-git-gutter-mode) buffer point)
  (declare (ignore mode))
  (let* ((other-content (call-next-method))
         (changes (lem-git-gutter::buffer-git-gutter-changes buffer))
         (line-number (line-number-at-point point))
         (change-type (and changes (gethash line-number changes))))
    (if change-type
        (join-left-display-content
         (lem-git-gutter::make-gutter-content change-type)
         other-content)
        other-content)))

(defun enable-lem-yath-git-gutter ()
  "Install the buffer-local prog-mode gutter lifecycle idempotently."
  (when (member 'lem-git-gutter::git-gutter-mode
                (lem-core::active-global-minor-modes))
    (uiop:symbol-call :lem-git-gutter :git-gutter-mode nil))
  (pushnew ".git" lem-core/commands/project:*root-files* :test #'string=)
  (remove-hook *find-file-hook* 'lem-yath-git-gutter-find-file)
  (remove-hook *post-command-hook* 'lem-yath-git-gutter-post-command)
  (remove-hook (variable-value 'kill-buffer-hook :global t)
               'lem-yath-git-gutter-kill-buffer)
  (remove-hook (variable-value 'after-save-hook :global t)
               'lem-yath-git-gutter-after-save)
  (remove-hook (variable-value 'after-change-functions :global t)
               'lem-yath-git-gutter-after-change)
  (add-hook *find-file-hook* 'lem-yath-git-gutter-find-file)
  (add-hook *post-command-hook* 'lem-yath-git-gutter-post-command)
  (add-hook (variable-value 'kill-buffer-hook :global t)
            'lem-yath-git-gutter-kill-buffer)
  (add-hook (variable-value 'after-save-hook :global t)
            'lem-yath-git-gutter-after-save)
  (add-hook (variable-value 'after-change-functions :global t)
            'lem-yath-git-gutter-after-change)
  (dolist (buffer (buffer-list))
    (lem-yath-git-gutter-sync-buffer buffer)))

(initialize-editor-feature 'enable-lem-yath-git-gutter)
