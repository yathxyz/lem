;;;; UI branch regression only: real panes, simulated successful Git mutations.
;;;; Loaded into a private configured daemon by git-pane-callers-test.py.
(in-package :lem-yath)

(defmacro with-pane-caller-functions (bindings &body body)
  (let ((saved (gensym "SAVED")))
    `(let ((,saved (list ,@(mapcar (lambda (binding)
                                    `(cons ',(first binding)
                                           (symbol-function ',(first binding))))
                                  bindings))))
       (unwind-protect
            (progn
              ,@(mapcar (lambda (binding)
                          `(setf (symbol-function ',(first binding)) ,(second binding)))
                        bindings)
              ,@body)
         (dolist (entry ,saved) (setf (symbol-function (car entry)) (cdr entry)))))))

(defun pane-caller-check (value description)
  (unless value (error "Git pane regression: ~a" description)))

(defun pane-caller-open-message (kind)
  (ecase kind
    (:amend (show-legit-amend-buffer "Fixture commit" (uiop:getcwd)))
    (:revert
     (with-pane-caller-functions
         ((legit-revert-read-bounded-file (lambda (&rest args) (declare (ignore args)) "Fixture commit")))
       (legit-revert-show-message-buffer nil)))
    (:cherry
     (with-pane-caller-functions
         ((legit-cherry-read-bounded-file (lambda (&rest args) (declare (ignore args)) "Fixture commit")))
       (legit-cherry-show-message-buffer nil (uiop:getcwd)))))
  (current-buffer))

(defun pane-caller-function (kind action)
  (ecase action
    (:continue (ecase kind
                 (:amend #'legit-amend-continue)
                 (:revert #'legit-revert-message-continue)
                 (:cherry #'legit-cherry-message-continue)))
    (:abort (ecase kind
              (:amend #'legit-amend-abort)
              (:revert #'legit-revert-message-abort)
              (:cherry #'legit-cherry-message-abort)))))

(defun pane-caller-check-unchanged-context (context peek source)
  (pane-caller-check (eq context (lem/legit::current-pane-context)) "replacement context survives")
  (pane-caller-check (eq peek (lem/legit::peek-window)) "replacement status pane survives")
  (pane-caller-check (eq source (lem/legit::source-window)) "replacement source pane survives"))

(defun pane-caller-message-case (kind action state)
  (lem/legit::with-current-project (vcs)
    (declare (ignore vcs))
    (let ((origin-buffer (current-buffer)) message-buffer)
      (unwind-protect
           (progn
             (lem/legit::show-legit-status)
             (let* ((context (lem/legit::current-pane-context))
                    (commits 0)
                    (old-run-git (symbol-function 'lem/porcelain/git::run-git))
                    replacement peek source)
               (setf message-buffer (pane-caller-open-message kind))
               (let ((text (buffer-text message-buffer))
                     (owner (buffer-value message-buffer 'legit-message-context)))
                 (pane-caller-check
                  (eq :refused (handler-case (pane-caller-open-message kind)
                                 (error () :refused)))
                  "an existing message buffer is refused before reuse")
                 (pane-caller-check (and (string= text (buffer-text message-buffer))
                                         (eq owner (buffer-value message-buffer 'legit-message-context)))
                                    "name collision preserves pending text and context"))
               (unless (eq state :live)
                 (lem/legit::finalize-peek-legit context)
                 (when (eq state :replacement)
                   (lem/legit::show-legit-status)
                   (setf replacement (lem/legit::current-pane-context)
                         peek (lem/legit::peek-window) source (lem/legit::source-window))
                   (setf (current-window) source))
                 (switch-to-buffer message-buffer))
               (flet ((commit-success (arguments &rest rest)
                        (if (equal (first arguments) "commit")
                            (progn (incf commits) (values "fixture commit" "" 0))
                            (apply old-run-git arguments rest))))
                 (with-pane-caller-functions
                     ((lem/porcelain/git::run-git #'commit-success)
                      (legit-revert-run-program #'commit-success)
                      (legit-cherry-run-program #'commit-success))
                   (let ((lem/legit::*prompt-to-abort-commit* nil)
                         (*legit-cherry-pending-move* nil))
                     (funcall (pane-caller-function kind action)))))
               (pane-caller-check (= commits (if (eq action :continue) 1 0)) "exact requested commit branch")
               (pane-caller-check (deleted-buffer-p message-buffer) "message buffer closes")
               (ecase state
                 (:live
                  (pane-caller-check (eq context (lem/legit::current-pane-context)) "origin context survives")
                  (pane-caller-check (eq (current-window) (lem/legit::peek-window)) "focus returns to origin status"))
                 (:closed (pane-caller-check (null (lem/legit::current-pane-context)) "closed panes stay closed"))
                 (:replacement
                  (pane-caller-check-unchanged-context replacement peek source)
                  (pane-caller-check (eq source (current-window)) "replacement source keeps focus")))
               t))
        (when (lem/legit::current-pane-context) (lem/legit::finalize-peek-legit))
        (when (and message-buffer (not (deleted-buffer-p message-buffer)))
          (buffer-unmark message-buffer)
          (delete-buffer message-buffer))
        (switch-to-buffer origin-buffer)))))

(defun pane-caller-remote-case (role state)
  (lem/legit::with-current-project (vcs)
    (declare (ignore vcs))
    (unwind-protect
         (progn
           (lem/legit::show-legit-status)
           (let* ((context (lem/legit::current-pane-context))
                  (window (ecase role (:peek (lem/legit::peek-window)) (:source (lem/legit::source-window))))
                  (*legit-remote-dispatch-window* window)
                  replacement peek source selected)
             (setf (current-window) window)
             (unless (eq state :live)
               (lem/legit::finalize-peek-legit context)
               (when (eq state :replacement)
                 (lem/legit::show-legit-status)
                 (setf replacement (lem/legit::current-pane-context)
                       peek (lem/legit::peek-window) source (lem/legit::source-window)
                       selected (current-window))))
             (legit-remote-refresh)
             (ecase state
               (:live
                (pane-caller-check (eq context (lem/legit::current-pane-context)) "remote owns refreshed context")
                (pane-caller-check (eq (current-window)
                                      (ecase role (:peek (lem/legit::peek-window)) (:source (lem/legit::source-window))))
                                   "remote retains pane role after window replacement"))
               (:closed (pane-caller-check (null (lem/legit::current-pane-context)) "remote never reopens closed context"))
               (:replacement
                (pane-caller-check-unchanged-context replacement peek source)
                (pane-caller-check (eq selected (current-window)) "remote leaves replacement focus")))
             t))
      (when (lem/legit::current-pane-context) (lem/legit::finalize-peek-legit)))))

(defun pane-caller-merge-case (state)
  (lem/legit::with-current-project (vcs)
    (declare (ignore vcs))
    (unwind-protect
         (progn
           (lem/legit::show-legit-status)
           (let ((context (lem/legit::current-pane-context)) replacement peek source selected)
             (with-pane-caller-functions
                 ((legit-merge-read-head
                   (lambda (&rest args)
                     (declare (ignore args))
                     (unless (eq state :live)
                       (lem/legit::finalize-peek-legit context)
                       (when (eq state :replacement)
                         (lem/legit::show-legit-status)
                         (setf replacement (lem/legit::current-pane-context)
                               peek (lem/legit::peek-window) source (lem/legit::source-window)
                               selected (current-window))))
                     "HEAD")))
               (legit-merge-preview))
             (ecase state
               (:live (pane-caller-check (eq (current-window) (lem/legit::source-window)) "merge focuses origin preview"))
               (:closed (pane-caller-check (null (lem/legit::current-pane-context)) "merge leaves closed context closed"))
               (:replacement
                (pane-caller-check-unchanged-context replacement peek source)
                (pane-caller-check (eq selected (current-window)) "merge leaves replacement focus")))
             t))
      (when (lem/legit::current-pane-context) (lem/legit::finalize-peek-legit)))))
