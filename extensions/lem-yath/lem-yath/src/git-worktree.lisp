;;;; Evil-Collection-compatible Magit worktree dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-worktree-timeout* 120)
(defparameter *legit-worktree-output-limit* (* 4 1024 1024))
(defparameter *legit-worktree-candidate-limit* 5000)
(defparameter *legit-worktree-value-limit* 4096)

(defvar *legit-worktree-path-history* nil)

(defstruct legit-worktree
  path
  head
  branch
  bare-p
  detached-p
  locked-p
  prunable-p)

(defun legit-worktree-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Worktree commands are available only in a Git repository.")))

(defun legit-worktree-run-program (arguments &optional directory)
  "Run bounded Git ARGUMENTS in DIRECTORY or Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-worktree-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (or directory (uiop:getcwd))
     :output-limit *legit-worktree-output-limit*)))

(defun legit-worktree-checked-output (arguments &optional directory)
  (multiple-value-bind (output error-output status)
      (legit-worktree-run-program arguments directory)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    output))

(defun legit-worktree-split-nul (text)
  "Split TEXT at NUL bytes while retaining empty record separators."
  (let ((separator (code-char 0))
        (start 0)
        (fields '()))
    (loop :for end := (position separator text :start start)
          :do (push (subseq text start end) fields)
          :if end
            :do (setf start (1+ end))
          :else
            :do (return (nreverse fields)))))

(defun legit-worktree-parse-record (fields)
  (let ((worktree (make-legit-worktree)))
    (dolist (field fields)
      (let ((space (position #\Space field)))
        (flet ((value () (and space (subseq field (1+ space)))))
          (cond
            ((alexandria:starts-with-subseq "worktree " field)
             (setf (legit-worktree-path worktree) (value)))
            ((alexandria:starts-with-subseq "HEAD " field)
             (setf (legit-worktree-head worktree) (value)))
            ((alexandria:starts-with-subseq "branch refs/heads/" field)
             (setf (legit-worktree-branch worktree)
                   (subseq (value) (length "refs/heads/"))))
            ((string= field "bare")
             (setf (legit-worktree-bare-p worktree) t))
            ((string= field "detached")
             (setf (legit-worktree-detached-p worktree) t))
            ((or (string= field "locked")
                 (alexandria:starts-with-subseq "locked " field))
             (setf (legit-worktree-locked-p worktree) t))
            ((or (string= field "prunable")
                 (alexandria:starts-with-subseq "prunable " field))
             (setf (legit-worktree-prunable-p worktree) t))))))
    (unless (legit-worktree-path worktree)
      (editor-error "Git returned a worktree record without a path."))
    worktree))

(defun legit-worktree-list ()
  "Return bounded worktree records from Git's NUL-delimited porcelain."
  (let ((records '())
        (fields '()))
    (dolist (field
             (legit-worktree-split-nul
              (legit-worktree-checked-output
               '("worktree" "list" "--porcelain" "-z"))))
      (if (string= field "")
          (when fields
            (push (legit-worktree-parse-record (nreverse fields)) records)
            (setf fields nil))
          (push field fields)))
    (when fields
      (push (legit-worktree-parse-record (nreverse fields)) records))
    (setf records (nreverse records))
    (when (> (length records) *legit-worktree-candidate-limit*)
      (editor-error "Git returned more than ~d worktrees."
                    *legit-worktree-candidate-limit*))
    records))

(defun legit-worktree-normalize-path (path)
  "Return PATH as a bounded absolute native path."
  ;; Lem's directory completion keeps "./" when its prompt is cleared.  A
  ;; subsequently pasted absolute path therefore arrives as ".//..."; retain
  ;; the user's rooted-path intent instead of nesting it below the repository.
  (when (alexandria:starts-with-subseq ".//" path)
    (setf path (subseq path 1)))
  (unless (and (str:non-blank-string-p path)
               (<= (length path) *legit-worktree-value-limit*)
               (not (find (code-char 0) path)))
    (editor-error "A worktree path must contain between 1 and 4096 characters."))
  (uiop:native-namestring
   (merge-pathnames path (uiop:ensure-directory-pathname (uiop:getcwd)))))

(defun legit-worktree-comparison-path (path)
  (string-right-trim
   '(#\/)
   (uiop:native-namestring
    (or (ignore-errors (truename path))
        (merge-pathnames path
                         (uiop:ensure-directory-pathname (uiop:getcwd)))))))

(defun legit-worktree-path= (left right)
  (string= (legit-worktree-comparison-path left)
           (legit-worktree-comparison-path right)))

(defun legit-worktree-primary (worktrees)
  (or (first worktrees)
      (editor-error "Git did not report a primary worktree.")))

(defun legit-worktree-default-directory (branch)
  "Return Magit's sibling-style default directory for BRANCH."
  (let* ((root (uiop:ensure-directory-pathname (uiop:getcwd)))
         (parent (uiop:pathname-parent-directory-pathname root))
         (name (car (last (pathname-directory root))))
         (underscore (position #\_ name))
         (prefix (if underscore (subseq name 0 underscore) name))
         (suffix (and branch
                      (substitute #\- #\/ branch))))
    (merge-pathnames (format nil "~a_~a/" prefix (or suffix "")) parent)))

(defun legit-worktree-read-directory (prompt branch)
  (alexandria:when-let
      ((path
         (prompt-for-directory
          prompt
          :directory
          (uiop:native-namestring
           (legit-worktree-default-directory branch)))))
    (legit-worktree-normalize-path path)))

(defun legit-worktree-revision-token (revision)
  "Return a safe branch/ref token or a resolved commit hash for REVISION."
  (if (member revision
              (append (legit-branch-local-branches)
                      (legit-branch-remote-branches))
              :test #'string=)
      revision
      (legit-reset-normalize-revision revision)))

(defun legit-worktree-read-revision ()
  (alexandria:when-let
      ((revision
         (legit-branch-read-revision
          "In new worktree; checkout: "
          (legit-branch-default-start))))
    (legit-worktree-revision-token revision)))

(defun legit-worktree-visit-directory (directory)
  "Replace an active Legit view with status for DIRECTORY."
  (if (lem/legit::legit-status-active-p)
      (let ((directory (copy-seq directory)))
        ;; Legit's quit deletes its peek/source windows on the next idle turn.
        ;; Reopening synchronously would replace its global window references
        ;; before that deletion callback runs and can corrupt the editor state.
        (lem/legit::legit-quit)
        (start-timer
         (make-timer
          (lambda ()
            (send-event
             (lambda () (lem-yath-legit-status-at directory)))))
         100))
      (lem-yath-legit-status-at directory)))

(defun legit-worktree-add-checkout ()
  (alexandria:when-let ((revision (legit-worktree-read-revision)))
    (alexandria:when-let
        ((directory
           (legit-worktree-read-directory
            (format nil "Checkout ~a in new worktree: " revision)
            (and (member revision (legit-branch-local-branches)
                         :test #'string=)
                 revision))))
      (legit-worktree-checked-output
       (list "worktree" "add" directory revision))
      (legit-worktree-visit-directory directory)
      (message "Checked out ~a in ~a." revision directory)
      t)))

(defun legit-worktree-add-branch ()
  (alexandria:when-let
      ((arguments
         (legit-branch-read-create-arguments
          "Create branch and worktree")))
    (destructuring-bind (branch start) arguments
      (alexandria:when-let
          ((directory
             (legit-worktree-read-directory
              (format nil "Checkout ~a in new worktree: " branch) branch)))
        (legit-worktree-checked-output
         (list "worktree" "add" "-b" branch directory
               (legit-reset-normalize-revision start)))
        (legit-worktree-visit-directory directory)
        (message "Created ~a in ~a." branch directory)
        t))))

(defun legit-worktree-read (prompt &key include-primary-p initial-value)
  (let* ((worktrees (legit-worktree-list))
         (eligible (if include-primary-p worktrees (rest worktrees)))
         (paths (mapcar #'legit-worktree-path eligible)))
    (unless paths
      (editor-error "There is no eligible linked worktree."))
    (alexandria:when-let
        ((path
           (prompt-for-string
            prompt
            :initial-value (or initial-value
                               (and (= (length paths) 1) (first paths))
                               "")
            :history-symbol '*legit-worktree-path-history*
            :completion-function
            (lambda (query) (completion-strings query paths))
            :test-function
            (lambda (input) (member input paths :test #'string=)))))
      (find path eligible :key #'legit-worktree-path :test #'string=))))

(defun legit-worktree-visit ()
  (alexandria:when-let
      ((worktree
         (legit-worktree-read "Show status for worktree: "
                              :include-primary-p t)))
    (when (legit-worktree-prunable-p worktree)
      (editor-error "The selected worktree no longer exists; prune it first."))
    (legit-worktree-visit-directory (legit-worktree-path worktree))))

(defun legit-worktree-move ()
  (alexandria:when-let
      ((worktree (legit-worktree-read "Move worktree: ")))
    (when (legit-worktree-prunable-p worktree)
      (editor-error "A missing worktree cannot be moved."))
    (alexandria:when-let
        ((directory
           (legit-worktree-read-directory "Move worktree to: "
                                          (legit-worktree-branch worktree))))
      (let* ((old (legit-worktree-path worktree))
             (current-p (legit-worktree-path= old (uiop:getcwd)))
             (container-p (uiop:directory-exists-p directory))
             (old-name
               (car (last
                     (pathname-directory
                      (uiop:ensure-directory-pathname old)))))
             (destination
               (if container-p
                   (uiop:native-namestring
                    (merge-pathnames
                     (make-pathname :directory `(:relative ,old-name))
                     (uiop:ensure-directory-pathname directory)))
                   directory)))
        (legit-worktree-checked-output
         (list "worktree" "move" old directory))
        (if current-p
            (legit-worktree-visit-directory destination)
            (lem/legit::show-legit-status))
        (message "Moved worktree to ~a." destination)
        t))))

(defun legit-worktree-dirty-p (worktree)
  (and (probe-file (legit-worktree-path worktree))
       (str:non-blank-string-p
        (legit-worktree-checked-output
         '("status" "--porcelain" "--untracked-files=all")
         (legit-worktree-path worktree)))))

(defun legit-worktree-delete ()
  (let* ((worktrees (legit-worktree-list))
         (primary (legit-worktree-primary worktrees)))
    (alexandria:when-let
        ((worktree (legit-worktree-read "Delete worktree: ")))
      (let* ((path (legit-worktree-path worktree))
             (current-p (legit-worktree-path= path (uiop:getcwd)))
             (exists-p (probe-file path))
             (dirty-p (and exists-p (legit-worktree-dirty-p worktree))))
        (unless exists-p
          (legit-worktree-checked-output '("worktree" "prune"))
          (lem/legit::show-legit-status)
          (message "Pruned missing worktree ~a." path)
          (return-from legit-worktree-delete t))
        (when (legit-worktree-locked-p worktree)
          (editor-error "Unlock the selected worktree before deleting it."))
        (unless (prompt-for-y-or-n-p
                 (format nil "Delete worktree ~a~:[?~; despite uncommitted changes?~] "
                         path dirty-p))
          (message "Worktree deletion cancelled.")
          (return-from legit-worktree-delete nil))
        (legit-worktree-checked-output
         (append (list "worktree" "remove")
                 (when dirty-p '("--force"))
                 (list path)))
        (if current-p
            (legit-worktree-visit-directory
             (legit-worktree-path primary))
            (lem/legit::show-legit-status))
        (message "Deleted worktree ~a." path)
        t))))

(defun legit-worktree-popup-keymap ()
  (let ((keymap (make-keymap :description "Worktree")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist (entry '(("b" "checkout in new worktree")
                     ("c" "create branch and worktree")
                     ("m" "move worktree")
                     ("k" "delete worktree")
                     ("g" "visit worktree")
                     ("q" "cancel")))
      (legit-branch-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun dispatch-legit-worktree ()
  "Display and execute the configured Evil Collection Magit worktree dispatch."
  (unwind-protect
       (progn
         (let ((lem/transient:*transient-popup-delay* 0))
           (keymap-activate (legit-worktree-popup-keymap)))
         (redraw-display)
         (let ((name (lem-core::keyseq-to-string (list (read-key)))))
           (lem/transient::hide-transient)
           (cond
             ((or (string= name "q") (string= name "Escape"))
              (message "Worktree dispatch cancelled.")
              nil)
             ((string= name "b") (legit-worktree-add-checkout))
             ((string= name "c") (legit-worktree-add-branch))
             ((string= name "m") (legit-worktree-move))
             ((string= name "k") (legit-worktree-delete))
             ((string= name "g") (legit-worktree-visit))
             (t (message "No worktree action is bound to ~a" name) nil))))
    (lem/transient::hide-transient)))

(define-command lem-yath-legit-worktree () ()
  "Open the configured Evil Collection Magit worktree dispatch."
  (lem/legit::with-current-project (vcs)
    (legit-worktree-require-git vcs)
    (dispatch-legit-worktree)))

(define-key lem/legit::*peek-legit-keymap* "Z" 'lem-yath-legit-worktree)
(define-key lem/legit::*legit-diff-mode-keymap* "Z" 'lem-yath-legit-worktree)
