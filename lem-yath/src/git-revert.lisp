;;;; Magit-compatible Git revert dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-revert-timeout* 120)
(defparameter *legit-revert-output-limit* (* 4 1024 1024))
(defparameter *legit-revert-message-limit* (* 1024 1024))
(defparameter *legit-revert-commit-limit* 64)

(defvar *legit-revert-history* nil)
(defvar *legit-revert-gpg-history* nil)
(defvar *legit-revert-operation-key* 'lem-yath-legit-revert-operation)
(defvar *legit-revert-gpg-key* 'lem-yath-legit-revert-gpg)

(defstruct (legit-revert-options
             (:constructor make-legit-revert-options
                 (&key mainline (edit-mode :edit) strategy gpg-sign
                       signoff-p)))
  mainline
  edit-mode
  strategy
  gpg-sign
  signoff-p)

(defun legit-revert-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Revert is available only in a Git repository.")))

(defun legit-revert-run-program (arguments &key editor)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-revert-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :environment
     (when editor
       (legit-rebase-child-environment
        "GIT_EDITOR" editor "LC_ALL" "C"))
     :output-limit *legit-revert-output-limit*)))

(defun legit-revert-checked-output (arguments)
  (multiple-value-bind (output error-output status)
      (legit-revert-run-program arguments)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    output))

(defun legit-revert-todo-p ()
  "Return true when Git's sequencer todo begins with a revert action."
  (let* ((relative
           (str:trim
            (legit-revert-checked-output
             '("rev-parse" "--git-path" "sequencer/todo"))))
         (pathname (merge-pathnames relative (uiop:getcwd))))
    (when (uiop:file-exists-p pathname)
      (with-open-file (stream pathname :direction :input
                                      :external-format :utf-8)
        (alexandria:when-let ((line (read-line stream nil nil)))
          (alexandria:starts-with-subseq "revert " line))))))

(defun legit-revert-in-progress-p ()
  "Return true for a stopped single or multi-commit revert."
  (or (legit-git-metadata-path-exists-p "REVERT_HEAD")
      (legit-revert-todo-p)))

(defun legit-revert-unmerged-p ()
  (str:non-blank-string-p
   (legit-revert-checked-output '("ls-files" "--unmerged"))))

(defun legit-revert-index-changes-p ()
  (multiple-value-bind (output error-output status)
      (legit-revert-run-program '("diff" "--cached" "--quiet"))
    (declare (ignore output))
    (cond
      ((eql status 0) nil)
      ((eql status 1) t)
      (t (editor-error "~a"
                       (legit-command-error-text "" error-output))))))

(defun legit-revert-read-bounded-file (git-path)
  "Read a bounded UTF-8 file named by GIT-PATH below Git's metadata dir."
  (let* ((relative
           (str:trim
            (legit-revert-checked-output
             (list "rev-parse" "--git-path" git-path))))
         (pathname (merge-pathnames relative (uiop:getcwd))))
    (unless (uiop:file-exists-p pathname)
      (editor-error "Git did not prepare a revert message."))
    (with-open-file (stream pathname :direction :input :external-format :utf-8)
      (let ((chunk (make-string 8192))
            (count 0)
            (output (make-string-output-stream)))
        (loop :for length := (read-sequence chunk stream)
              :until (zerop length)
              :do (incf count length)
                  (when (> count *legit-revert-message-limit*)
                    (editor-error "Revert message exceeds 1 MiB."))
                  (write-sequence chunk output :end length))
        (get-output-stream-string output)))))

(defun legit-revert-message-buffer-p (&optional (buffer (current-buffer)))
  (eq (buffer-value buffer *legit-revert-operation-key*) :revert))

(defun legit-revert-show-message-buffer (gpg-sign)
  "Open Legit's commit mode with Git's prepared revert message."
  (when (get-buffer "*legit-revert*")
    (editor-error "A revert message buffer is already open."))
  (let ((message (legit-revert-read-bounded-file "COMMIT_EDITMSG"))
        (buffer (make-buffer "*legit-revert*")))
    (setf (buffer-directory buffer) (uiop:getcwd)
          (buffer-read-only-p buffer) nil
          (buffer-value buffer *legit-revert-operation-key*) :revert
          (buffer-value buffer *legit-revert-gpg-key*) gpg-sign)
    (erase-buffer buffer)
    (insert-string
     (buffer-point buffer)
     (format nil "~a~a"
             (string-right-trim '(#\Newline #\Return) message)
             (format nil lem/legit::*commit-buffer-message*)))
    (change-buffer-mode buffer 'lem/legit::legit-commit-mode)
    (buffer-start (buffer-point buffer))
    (next-window)
    (switch-to-buffer buffer)))

(defun legit-revert-message-continue ()
  "Commit the prepared revert using the edited native buffer message."
  (let* ((buffer (current-buffer))
         (message
           (lem/legit::clean-commit-message (buffer-text buffer)))
         (gpg-sign (buffer-value buffer *legit-revert-gpg-key*)))
    (when (str:blankp message)
      (message "No commit message; revert was not committed.")
      (return-from legit-revert-message-continue nil))
    (lem/legit::with-current-project (vcs)
      (legit-revert-require-git vcs)
      (multiple-value-bind (output error-output status)
          (legit-revert-run-program
           (append (list "commit" "-m" message)
                   (when gpg-sign
                     (list (if (str:blankp gpg-sign)
                               "--gpg-sign"
                               (format nil "--gpg-sign=~a" gpg-sign)))))
           :editor "true")
        (if (and (integerp status) (zerop status))
            (progn
              (buffer-unmark buffer)
              (kill-buffer buffer)
              (when (lem/legit::legit-status-active-p)
                (setf (current-window) lem/legit::*peek-window*))
              (lem/legit::show-legit-status)
              (message "Committed revert."))
            (lem/legit::pop-up-message
             (legit-command-error-text output error-output)))))))

(defun legit-revert-message-abort ()
  "Discard the editor buffer while retaining Git's prepared index state."
  (when (or (not lem/legit::*prompt-to-abort-commit*)
            (prompt-for-y-or-n-p "Abort revert message? "))
    (let ((buffer (current-buffer)))
      (buffer-unmark buffer)
      (kill-buffer buffer)
      (when (lem/legit::legit-status-active-p)
        (setf (current-window) lem/legit::*peek-window*)))))

(defun legit-revert-run (arguments success-message &key edit-stop-p gpg-sign)
  "Run Git revert ARGUMENTS and preserve edit and conflict stops."
  (multiple-value-bind (output error-output status)
      (legit-revert-run-program
       (cons "revert" arguments)
       :editor (if edit-stop-p "false" "true"))
    (lem/legit::show-legit-status)
    (cond
      ((and (integerp status) (zerop status))
       (message "~a" success-message)
       t)
      ((legit-revert-unmerged-p)
       (message
        "Revert stopped; resolve conflicts, then continue, abort, or skip from V.")
       nil)
      ((and edit-stop-p
            (search "problem with the editor" error-output
                    :test #'char-equal)
            (legit-revert-index-changes-p))
       (legit-revert-show-message-buffer gpg-sign)
       nil)
      ((legit-revert-in-progress-p)
       (message "Revert stopped; continue, abort, or skip from V.")
       nil)
      (t
       (lem/legit::pop-up-message
        (legit-command-error-text output error-output))
       nil))))

(defun legit-revert-read-commits (prompt)
  "Read verified commits, preferring a valid Magit-style commit region."
  (alexandria:when-let
      ((selected
         (legit-log-selected-commits *legit-revert-commit-limit*)))
    ;; Revert intentionally retains newest-to-oldest display order, matching
    ;; Magit's direct use of the selected section values.
    (return-from legit-revert-read-commits
      (mapcar #'legit-reset-normalize-revision selected)))
  (let* ((default (text-property-at (current-point) :commit-hash))
         (candidates (legit-cherry-pick-candidates))
         (labels (mapcar #'car candidates))
         (input
           (prompt-for-string
            prompt
            :initial-value (or default "")
            :history-symbol '*legit-revert-history*
            :completion-function
            (lambda (query) (completion-strings query labels)))))
    (when input
      (let ((exact (cdr (assoc input candidates :test #'string=))))
        (if exact
            (list exact)
            (let ((parts (remove-if #'str:blankp
                                    (mapcar #'str:trim
                                            (str:split "," input)))))
              (when (null parts)
                (editor-error "At least one commit is required."))
              (when (> (length parts) *legit-revert-commit-limit*)
                (editor-error "A revert is limited to 64 commits."))
              (mapcar #'legit-reset-normalize-revision parts)))))))

(defun legit-revert-merge-commit-p (commit)
  (> (length
      (remove-if
       #'str:blankp
       (str:split " "
                  (str:trim
                   (legit-revert-checked-output
                    (list "rev-list" "--parents" "-n" "1" commit))))))
     2))

(defun legit-revert-effective-mainline (commits configured)
  "Validate merge/non-merge COMMIT selection and return its mainline."
  (let ((merge-count (count-if #'legit-revert-merge-commit-p commits)))
    (cond
      ((zerop merge-count) nil)
      ((/= merge-count (length commits))
       (editor-error "Cannot revert merge and non-merge commits together."))
      (configured configured)
      (t
       (let ((input (prompt-for-string "Replay merges relative to parent: ")))
         (unless (and input
                      (ignore-errors (plusp (parse-integer input
                                                          :junk-allowed nil))))
           (editor-error "A positive mainline parent number is required."))
         (parse-integer input))))))

(defun legit-revert-option-arguments (options commits &key no-commit-p)
  (let ((mainline
          (legit-revert-effective-mainline
           commits (legit-revert-options-mainline options))))
    (append
     (when no-commit-p '("--no-commit"))
     (case (legit-revert-options-edit-mode options)
       (:edit '("--edit"))
       (:no-edit '("--no-edit")))
     (when mainline (list (format nil "--mainline=~d" mainline)))
     (alexandria:when-let ((strategy (legit-revert-options-strategy options)))
       (list (format nil "--strategy=~a" strategy)))
     (alexandria:when-let ((key (legit-revert-options-gpg-sign options)))
       (list (if (str:blankp key)
                 "--gpg-sign"
                 (format nil "--gpg-sign=~a" key))))
     (when (legit-revert-options-signoff-p options) '("--signoff")))))

(defun legit-revert-start (options no-commit-p)
  (alexandria:when-let
      ((commits
         (legit-revert-read-commits
          (if no-commit-p "Revert changes from: " "Revert commit(s): "))))
    (let* ((edit-stop-p
             (and (not no-commit-p)
                  (eq (legit-revert-options-edit-mode options) :edit)))
           (arguments
             (append (legit-revert-option-arguments
                      options commits :no-commit-p no-commit-p)
                     commits)))
      (legit-revert-run
       arguments
       (if no-commit-p
           "Applied reverted changes without committing."
           "Reverted commit(s).")
       :edit-stop-p edit-stop-p
       :gpg-sign (legit-revert-options-gpg-sign options)))))

(defun legit-revert-continue ()
  (unless (legit-revert-in-progress-p)
    (editor-error "No revert is in progress."))
  (when (legit-revert-unmerged-p)
    (editor-error "Cannot continue while conflicts remain unresolved."))
  (legit-revert-run '("--continue") "Revert continued."))

(defun legit-revert-abort ()
  (unless (legit-revert-in-progress-p)
    (editor-error "No revert is in progress."))
  (when (prompt-for-y-or-n-p "Really abort revert? ")
    (legit-revert-run '("--abort") "Revert aborted.")))

(defun legit-revert-skip ()
  (unless (legit-revert-in-progress-p)
    (editor-error "No revert is in progress."))
  (multiple-value-bind (output error-output status)
      (legit-revert-run-program '("reset" "--hard"))
    (if (and (integerp status) (zerop status))
        (legit-revert-run '("--continue") "Skipped reverted commit.")
        (lem/legit::pop-up-message
         (legit-command-error-text output error-output)))))

(defun legit-revert-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-revert-popup-keymap (options active-p)
  (let ((keymap (make-keymap :description "Revert")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (if active-p
        (dolist (entry '(("_" "continue revert")
                         ("s" "skip commit")
                         ("a" "abort revert")
                         ("q" "cancel")))
          (legit-revert-add-popup-entry keymap (first entry) (second entry)))
        (dolist
            (entry
              `(("- m" ,(format nil "mainline parent: ~a"
                                  (or (legit-revert-options-mainline options)
                                      "auto")))
                ("- e" ,(format nil "[~a] edit commit message"
                                  (if (eq (legit-revert-options-edit-mode options)
                                          :edit) "x" " ")))
                ("- E" ,(format nil "[~a] do not edit message"
                                  (if (eq (legit-revert-options-edit-mode options)
                                          :no-edit) "x" " ")))
                ("= s" ,(format nil "strategy: ~a"
                                  (or (legit-revert-options-strategy options)
                                      "default")))
                ("- S" ,(format nil "GPG sign: ~a"
                                  (let ((key
                                          (legit-revert-options-gpg-sign options)))
                                    (cond ((null key) "off")
                                          ((str:blankp key) "default key")
                                          (t key)))))
                ("+ s" ,(format nil "[~a] add Signed-off-by"
                                  (if (legit-revert-options-signoff-p options)
                                      "x" " ")))
                ("_" "revert commit(s)")
                ("v" "revert changes without commit")
                ("q" "cancel")))
          (legit-revert-add-popup-entry keymap (first entry) (second entry))))
    keymap))

(defun legit-revert-read-popup-key ()
  (let* ((first (read-key))
         (name (lem-core::keyseq-to-string (list first))))
    (if (member name '("-" "+" "=") :test #'string=)
        (format nil "~a ~a" name
                (lem-core::keyseq-to-string (list (read-key))))
        name)))

(defun dispatch-legit-revert ()
  "Display and execute one configured Magit revert action."
  (let ((options (make-legit-revert-options)))
    (unwind-protect
         (loop
           :for active-p := (legit-revert-in-progress-p)
           :for keymap := (legit-revert-popup-keymap options active-p)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-revert-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (message "Revert cancelled.")
                   (return nil))
                  ((and active-p (string= name "_"))
                   (legit-revert-continue)
                   (return t))
                  ((and active-p (string= name "s"))
                   (legit-revert-skip)
                   (return t))
                  ((and active-p (string= name "a"))
                   (legit-revert-abort)
                   (return t))
                  (active-p
                   (message "No in-progress revert action is bound to ~a" name)
                   (return nil))
                  ((string= name "- m")
                   (let ((input (prompt-for-string "Mainline parent: ")))
                     (if (or (null input) (str:blankp input))
                         (setf (legit-revert-options-mainline options) nil)
                         (let ((number
                                 (ignore-errors
                                   (parse-integer input :junk-allowed nil))))
                           (unless (and number (plusp number))
                             (editor-error
                              "A positive mainline parent number is required."))
                           (setf (legit-revert-options-mainline options)
                                 number)))))
                  ((string= name "- e")
                   (setf (legit-revert-options-edit-mode options) :edit))
                  ((string= name "- E")
                   (setf (legit-revert-options-edit-mode options) :no-edit))
                  ((string= name "= s")
                   (setf (legit-revert-options-strategy options)
                         (legit-merge-read-choice
                          "Revert strategy: "
                          '("resolve" "recursive" "ort" "octopus" "ours"
                            "subtree")
                          '*legit-merge-strategy-history*)))
                  ((string= name "- S")
                   (setf (legit-revert-options-gpg-sign options)
                         (if (legit-revert-options-gpg-sign options)
                             nil
                             (or (prompt-for-string
                                  "GPG signing key (blank uses default): "
                                  :history-symbol '*legit-revert-gpg-history*)
                                 ""))))
                  ((string= name "+ s")
                   (setf (legit-revert-options-signoff-p options)
                         (not (legit-revert-options-signoff-p options))))
                  ((string= name "_")
                   (legit-revert-start options nil)
                   (return t))
                  ((string= name "v")
                   (legit-revert-start options t)
                   (return t))
                  (t
                   (message "No revert action is bound to ~a" name)
                   (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-revert () ()
  "Open the configured Magit-compatible Git revert transient."
  (lem/legit::with-current-project (vcs)
    (legit-revert-require-git vcs)
    (dispatch-legit-revert)))

(define-command lem-yath-legit-revert-no-commit () ()
  "Apply a prompted commit in reverse without committing it."
  (lem/legit::with-current-project (vcs)
    (legit-revert-require-git vcs)
    (legit-revert-start (make-legit-revert-options) t)))

(define-key lem/legit::*peek-legit-keymap* "_" 'lem-yath-legit-revert)
(define-key lem/legit::*legit-diff-mode-keymap* "_" 'lem-yath-legit-revert)
(define-key lem/legit::*peek-legit-keymap* "-"
  'lem-yath-legit-revert-no-commit)
(define-key lem/legit::*legit-diff-mode-keymap* "-"
  'lem-yath-legit-revert-no-commit)
