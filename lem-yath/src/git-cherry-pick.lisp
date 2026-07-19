;;;; Magit-compatible core cherry-pick dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-cherry-pick-candidate-limit* 200)
(defvar *legit-cherry-pick-history* nil)
(defvar *legit-cherry-pick-keymap*
  (make-keymap :description "Apply"))

(defun legit-git-metadata-path-exists-p (relative-path)
  "Return true when RELATIVE-PATH exists below Git's effective metadata dir."
  (multiple-value-bind (output error-output status)
      (lem/porcelain/git::run-git
       (list "rev-parse" "--git-path" relative-path))
    (declare (ignore error-output))
    (and (zerop status)
         (uiop:file-exists-p
          (merge-pathnames (str:trim output) (uiop:getcwd))))))

(defun legit-cherry-pick-in-progress-p ()
  "Return true for a stopped single or multi-commit cherry-pick."
  (or (legit-git-metadata-path-exists-p "CHERRY_PICK_HEAD")
      (legit-git-metadata-path-exists-p "sequencer/todo")))

(defun legit-cherry-pick-candidates ()
  "Return bounded display/hash pairs for commits reachable from every ref."
  (multiple-value-bind (output error-output status)
      (lem/porcelain/git::run-git
       (list "log" "--all" "--pretty=format:%H%x00%s"
             "-n" (princ-to-string *legit-cherry-pick-candidate-limit*)))
    (unless (zerop status)
      (editor-error "~a" (legit-command-error-text output error-output)))
    (loop :for line :in (str:lines output)
          :for separator := (position #\Null line)
          :when (and separator (plusp separator))
            :collect
            (let ((hash (subseq line 0 separator))
                  (subject (subseq line (1+ separator))))
              (cons (format nil "~a  ~a"
                            (subseq hash 0 (min 12 (length hash)))
                            subject)
                    hash)))))

(defun legit-read-cherry-pick-commit (prompt)
  "Read one commit or revision, defaulting to the commit at point."
  (let* ((default (text-property-at (current-point) :commit-hash))
         (candidates (legit-cherry-pick-candidates))
         (labels (mapcar #'car candidates))
         (input
           (prompt-for-string
            prompt
            :initial-value (or default "")
            :history-symbol '*legit-cherry-pick-history*
            :completion-function
            (lambda (query) (completion-strings query labels)))))
    (when input
      (or (cdr (assoc input candidates :test #'string=))
          (let ((revision (str:trim input)))
            (when (str:blankp revision)
              (editor-error "A commit or revision is required."))
            (when (find-if (lambda (character)
                             (member character '(#\Space #\Tab #\Newline
                                                 #\Return)))
                           revision)
              (editor-error "A Git revision cannot contain whitespace."))
            revision)))))

(defun run-legit-cherry-pick (arguments success-message)
  "Run Git cherry-pick ARGUMENTS without recursively opening an editor."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable."))))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (cons (uiop:native-namestring git) arguments)
         :directory (uiop:getcwd)
         :environment (legit-rebase-child-environment "GIT_EDITOR" "true"))
      (lem/legit::show-legit-status)
      (cond
        ((zerop status)
         (message "~a" success-message)
         t)
        ((legit-cherry-pick-in-progress-p)
         ;; Conflicts are a normal sequencer stop.  Keep the refreshed status
         ;; operable instead of covering it with Legit's blocking error popup.
         (message "Cherry-pick stopped; resolve conflicts, then continue, abort, or skip.")
         nil)
        (t
         (lem/legit::pop-up-message
          (legit-command-error-text output error-output))
         nil)))))

(define-command lem-yath-legit-cherry-pick-or-continue () ()
  "Run Magit's A A action: pick a commit, or continue a stopped pick."
  (lem/legit::with-current-project (vcs)
    (unless (typep vcs 'lem/porcelain/git::vcs-git)
      (editor-error "Cherry-pick is available only in a Git repository."))
    (if (legit-cherry-pick-in-progress-p)
        (run-legit-cherry-pick
         '("cherry-pick" "--continue") "Cherry-pick continued.")
        (alexandria:when-let
            ((commit (legit-read-cherry-pick-commit "Cherry-pick: ")))
          (run-legit-cherry-pick
           (list "cherry-pick" "--ff" commit) "Cherry-picked commit.")))))

(define-command lem-yath-legit-cherry-apply-or-abort () ()
  "Run Magit's A a action: apply without commit, or abort a stopped pick."
  (lem/legit::with-current-project (vcs)
    (unless (typep vcs 'lem/porcelain/git::vcs-git)
      (editor-error "Cherry-pick is available only in a Git repository."))
    (if (legit-cherry-pick-in-progress-p)
        (when (prompt-for-y-or-n-p "Abort cherry-pick? ")
          (run-legit-cherry-pick
           '("cherry-pick" "--abort") "Cherry-pick aborted."))
        (alexandria:when-let
            ((commit
               (legit-read-cherry-pick-commit
                "Apply changes from commit: ")))
          (run-legit-cherry-pick
           (list "cherry-pick" "--no-commit" commit)
           "Applied commit without committing.")))))

(define-command lem-yath-legit-cherry-skip () ()
  "Run Magit's in-progress A s action."
  (lem/legit::with-current-project (vcs)
    (unless (typep vcs 'lem/porcelain/git::vcs-git)
      (editor-error "Cherry-pick is available only in a Git repository."))
    (unless (legit-cherry-pick-in-progress-p)
      (editor-error "No cherry-pick is in progress."))
    (run-legit-cherry-pick
     '("cherry-pick" "--skip") "Skipped cherry-pick commit.")))

(define-key *legit-cherry-pick-keymap*
  "A" 'lem-yath-legit-cherry-pick-or-continue)
(define-key *legit-cherry-pick-keymap*
  "a" 'lem-yath-legit-cherry-apply-or-abort)
(define-key *legit-cherry-pick-keymap*
  "s" 'lem-yath-legit-cherry-skip)
(define-key lem/legit::*peek-legit-keymap*
  "A" *legit-cherry-pick-keymap*)
(define-key lem/legit::*legit-diff-mode-keymap*
  "A" *legit-cherry-pick-keymap*)
