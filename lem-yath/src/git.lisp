;;;; Git/VCS: Magit -> Legit, Majutsu -> a focused jj porcelain, and
;;;; prog-mode-local git-gutter behavior.

(in-package :lem-yath)

(defvar *lem-yath-jj-root-key* 'lem-yath-jj-root)
(defvar *lem-yath-jj-view-kind-key* 'lem-yath-jj-view-kind)
(defvar *lem-yath-jj-revision-key* 'lem-yath-jj-revision)
(defvar *lem-yath-jj-split-hunks-key* 'lem-yath-jj-split-hunks)
(defvar *lem-yath-jj-split-hunk-key* 'lem-yath-jj-split-hunk)
(defvar *lem-yath-jj-split-line-key* 'lem-yath-jj-split-line)
(defvar *lem-yath-jj-split-origin-key* 'lem-yath-jj-split-origin)
(defvar *lem-yath-jj-split-placement-key* 'lem-yath-jj-split-placement)
(defvar *lem-yath-jj-split-destination-key* 'lem-yath-jj-split-destination)
(defvar *lem-yath-jj-split-parallel-key* 'lem-yath-jj-split-parallel)
(defvar *lem-yath-jj-squash-state-key* 'lem-yath-jj-squash-state)
(defvar *lem-yath-jj-squash-origin-key* 'lem-yath-jj-squash-origin)
(defvar *lem-yath-jj-squash-mode-keymap*
  (make-keymap :description '*lem-yath-jj-squash-mode-keymap*))
(defvar *lem-yath-jj-restore-state-key* 'lem-yath-jj-restore-state)
(defvar *lem-yath-jj-restore-origin-key* 'lem-yath-jj-restore-origin)
(defvar *lem-yath-jj-message-action-key* 'lem-yath-jj-message-action)
(defvar *lem-yath-jj-message-origin-key* 'lem-yath-jj-message-origin)
(defvar *lem-yath-jj-message-mode-keymap*
  (make-keymap :description '*lem-yath-jj-message-mode-keymap*))
(defvar *lem-yath-jj-restore-mode-keymap*
  (make-keymap :description '*lem-yath-jj-restore-mode-keymap*))
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

(defun git-diff-lines-with-endings (text)
  "Return TEXT as lines while retaining every existing newline."
  (let ((start 0)
        (length (length text))
        (lines '()))
    (loop :while (< start length)
          :for newline := (position #\Newline text :start start)
          :do (if newline
                  (progn
                    (push (subseq text start (1+ newline)) lines)
                    (setf start (1+ newline)))
                  (progn
                    (push (subseq text start length) lines)
                    (setf start length))))
    (nreverse lines)))

(defun git-diff-parse-hunk-header (line)
  "Parse a unified Git hunk header into old/new starts, lengths, and suffix."
  (cl-ppcre:register-groups-bind
      (old-start old-length new-start new-length suffix)
      ("^@@ -(\\d+)(?:,(\\d+))? \\+(\\d+)(?:,(\\d+))? @@(.*?)(?:\\n)?$"
       line)
    (when old-start
      (list (parse-integer old-start)
            (parse-integer (or old-length "1"))
            (parse-integer new-start)
            (parse-integer (or new-length "1"))
            (or suffix "")))))

(defun git-diff-format-range (start length)
  (if (= length 1)
      (princ-to-string start)
      (format nil "~d,~d" start length)))

(defun legit-git-partial-hunk-patch (lines selected-indices)
  "Build a valid patch for the changed lines selected from hunk LINES."
  (let* ((parsed (git-diff-parse-hunk-header (first lines)))
         (old-length 0)
         (new-length 0)
         (has-change nil)
         (previous-included-p nil)
         (body '()))
    (unless parsed
      (editor-error "Unsupported Git hunk header"))
    (loop :for line :in (rest lines)
          :for index :from 1
          :for type :=
            (and (plusp (length line))
                 (case (char line 0)
                   (#\Space :context)
                   (#\+ :added)
                   (#\- :removed)
                   (#\\ :meta)))
          :for selected-p := (member index selected-indices)
          :for included-line := nil
          :do
             (case type
               (:context
                (incf old-length)
                (incf new-length)
                (setf included-line line
                      previous-included-p t))
               (:added
                (if selected-p
                    (progn
                      (incf new-length)
                      (setf has-change t
                            included-line line
                            previous-included-p t))
                    (setf previous-included-p nil)))
               (:removed
                (incf old-length)
                (incf new-length)
                (if selected-p
                    (progn
                      (decf new-length)
                      (setf has-change t
                            included-line line))
                    (setf included-line
                          (concatenate 'string " " (subseq line 1))))
                (setf previous-included-p t))
               (:meta
                (when previous-included-p
                  (setf included-line line))))
             (when included-line
               (push included-line body)))
    (when has-change
      (destructuring-bind (old-start ignored-old new-start ignored-new suffix)
          parsed
        (declare (ignore ignored-old ignored-new))
        (concatenate
         'string
         (format nil "@@ -~a +~a @@~a~%"
                 (git-diff-format-range old-start old-length)
                 (git-diff-format-range new-start new-length)
                 suffix)
         (apply #'concatenate 'string (nreverse body)))))))

(defun legit-git-region-bounds ()
  "Return the first and last selected diff lines."
  (let* ((buffer (current-buffer))
         (visual-p
           (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
                (lem-vi-mode/visual:visual-p buffer))))
    (when (and visual-p (lem-vi-mode/visual:visual-block-p buffer))
      (editor-error "Blockwise regions cannot select a Git patch"))
    (unless (or visual-p (buffer-mark-p buffer))
      (editor-error "No active region in the Git diff"))
    (let* ((bounds
             (if visual-p
                 (lem-vi-mode/visual:visual-range buffer)
                 (list (copy-point (region-beginning buffer))
                       (copy-point (region-end buffer)))))
           (start (point-min (first bounds) (second bounds)))
           (end (point-max (first bounds) (second bounds))))
      (when (point= start end)
        (editor-error "The active Git diff region is empty"))
      (with-point ((first-line start)
                   (last-line end))
        (line-start first-line)
        ;; Both Lem regions and Vi Visual ranges use an exclusive upper bound.
        (character-offset last-line -1)
        (line-start last-line)
        (values first-line last-line)))))

(defun legit-git-region-patch ()
  "Return a complete Git patch for selected changed lines across local hunks."
  (multiple-value-bind (region-start region-end)
      (legit-git-region-bounds)
    (with-point ((header region-start)
                 (file-end region-start))
      (unless (search-backward-regexp header "^diff --git ")
        (editor-error "The selected region has no Git patch header"))
      (move-point file-end header)
      (line-offset file-end 1)
      (unless (search-forward-regexp file-end "^diff --git ")
        (move-point file-end (buffer-end-point (current-buffer))))
      (when (point>= region-end file-end)
        (editor-error "A Git diff region must stay within one file"))
      (let* ((header-line (line-number-at-point header))
             (first-line (line-number-at-point region-start))
             (last-line (line-number-at-point region-end))
             (lines
               (git-diff-lines-with-endings
                (points-to-string header file-end)))
             (file-header '())
             (hunk-lines nil)
             (hunk-start nil)
             (patches '()))
        (labels
            ((flush-hunk ()
               (when hunk-lines
                 (let* ((ordered (nreverse hunk-lines))
                        (selected
                          (loop :for line :in (rest ordered)
                                :for relative :from 1
                                :for absolute :=
                                  (+ header-line hunk-start relative)
                                :when
                                  (and (<= first-line absolute last-line)
                                       (plusp (length line))
                                       (member (char line 0) '(#\+ #\-)))
                                  :collect relative))
                        (patch
                          (and selected
                               (legit-git-partial-hunk-patch
                                ordered selected))))
                   (when patch (push patch patches)))
                 (setf hunk-lines nil
                       hunk-start nil)))
             (append-line (line index)
               (if (str:starts-with-p "@@ " line)
                   (progn
                     (flush-hunk)
                     (setf hunk-lines (list line)
                           hunk-start index))
                   (if hunk-lines
                       (push line hunk-lines)
                       (push line file-header)))))
          (loop :for line :in lines
                :for index :from 0
                :do (append-line line index))
          (flush-hunk))
        (unless patches
          (editor-error "The region contains no changed Git lines"))
        (concatenate
         'string
         (apply #'concatenate 'string (nreverse file-header))
         (apply #'concatenate 'string (nreverse patches)))))))

(defun legit-git-diff-p ()
  (with-point ((point (current-point)))
    (not (null (search-backward-regexp point "^diff --git ")))))

(defun apply-legit-git-patch (patch reverse &key region-p)
  "Apply PATCH to Git's index, reversing when REVERSE."
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
              (when region-p
                (if (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
                         (lem-vi-mode/visual:visual-p (current-buffer)))
                    (lem-vi-mode/visual:vi-visual-end)
                    (buffer-mark-cancel (current-buffer))))
              (lem/legit::show-legit-status)
              (message
               (cond
                 ((and region-p reverse) "Unstaged selected lines")
                 (region-p "Staged selected lines")
                 (reverse "Unstaged hunk")
                 (t "Staged hunk")))
              t)
            (lem/legit::pop-up-message
             (if (plusp (length error-output))
                 error-output
                 output)))))))

(defun apply-legit-git-hunk (reverse)
  "Apply the current Legit hunk to Git's index, reversing when REVERSE."
  (apply-legit-git-patch (legit-git-hunk-patch) reverse))

(defun apply-legit-git-region (reverse)
  "Apply selected changed lines to Git's index, reversing when REVERSE."
  (apply-legit-git-patch
   (legit-git-region-patch) reverse :region-p t))

(define-command lem-yath-legit-stage-hunk () ()
  (if (legit-git-diff-p)
      (if (or (buffer-mark-p (current-buffer))
              (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
                   (lem-vi-mode/visual:visual-p (current-buffer))))
          (apply-legit-git-region nil)
          (apply-legit-git-hunk nil))
      (lem/legit::legit-stage-hunk)))

(define-command lem-yath-legit-unstage-hunk () ()
  (if (legit-git-diff-p)
      (if (or (buffer-mark-p (current-buffer))
              (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
                   (lem-vi-mode/visual:visual-p (current-buffer))))
          (apply-legit-git-region t)
          (apply-legit-git-hunk t))
      (lem/legit::legit-unstage-hunk)))

(declaim (ftype function
                legit-amend-buffer-p
                legit-amend-continue
                legit-amend-abort
                legit-cherry-message-buffer-p
                legit-cherry-message-continue
                legit-cherry-message-abort
                legit-revert-message-buffer-p
                legit-revert-message-continue
                legit-revert-message-abort))

(define-command lem-yath-legit-commit-continue () ()
  (cond
    ((server-buffer-requests)
     ;; Git invokes the packaged blocking client for reword.  COMMIT_EDITMSG
     ;; still selects Legit's commit major mode, so its ordinary command would
     ;; incorrectly start a second `git commit'.  Save the file and release
     ;; the waiting Git process instead.
     (lem-yath-server-save-done))
    ((legit-amend-buffer-p)
     (legit-amend-continue))
    ((and (fboundp 'legit-cherry-message-buffer-p)
          (legit-cherry-message-buffer-p))
     (legit-cherry-message-continue))
    ((and (fboundp 'legit-revert-message-buffer-p)
          (legit-revert-message-buffer-p))
     (legit-revert-message-continue))
    (t
     ;; This is a transient message buffer, not a file that needs saving.
     ;; Pinned Legit otherwise commits successfully and then prompts before
     ;; killing it.
     (unless (str:blankp
              (lem/legit::clean-commit-message
               (buffer-text (current-buffer))))
       (buffer-unmark (current-buffer)))
     (lem/legit::commit-continue))))

(define-command lem-yath-legit-commit-abort () ()
  (cond
    ((server-buffer-requests)
     (lem-yath-server-abort))
    ((legit-amend-buffer-p)
     (legit-amend-abort))
    ((and (fboundp 'legit-cherry-message-buffer-p)
          (legit-cherry-message-buffer-p))
     (legit-cherry-message-abort))
    ((and (fboundp 'legit-revert-message-buffer-p)
          (legit-revert-message-buffer-p))
     (legit-revert-message-abort))
    (t
     (lem/legit::commit-abort))))

(define-key lem/legit::*legit-diff-mode-keymap*
  "s" 'lem-yath-legit-stage-hunk)
(define-key lem/legit::*legit-diff-mode-keymap*
  "u" 'lem-yath-legit-unstage-hunk)
(define-key lem/legit::*legit-commit-mode-keymap*
  "C-c C-c" 'lem-yath-legit-commit-continue)
(define-key lem/legit::*legit-commit-mode-keymap*
  "C-Return" 'lem-yath-legit-commit-continue)
(define-key lem/legit::*legit-commit-mode-keymap*
  "C-c C-k" 'lem-yath-legit-commit-abort)
(define-key lem/legit::*legit-commit-mode-keymap*
  "M-q" 'lem-yath-legit-commit-abort)

;; Defined later in the serial system, in ui.lisp.  Git state can be prepared
;; before the UI module loads, but rendering only happens after startup.
(declaim (ftype function join-left-display-content))
(declaim (ftype function run-project-program))
(declaim (special *project-process-timeout*))

(defparameter *legit-todo-result-limit* 200)
(defparameter *legit-todo-output-limit* (* 1024 1024))
(defparameter *legit-todo-timeout* 5)
(defparameter *legit-todo-keywords*
  '("HOLD" "TODO" "NEXT" "THEM" "PROG" "OKAY" "DONT" "FAIL"
    "MAYBE" "KLUDGE" "HACK" "TEMP" "WIP" "FIXME" "DEBUG" "XXXX*"))

(defstruct legit-todo
  path
  line
  keyword
  text)

(defun detect-legit-todo-keyword (text)
  (loop :for keyword :in *legit-todo-keywords*
        :for quoted := (cl-ppcre:quote-meta-chars keyword)
        :when (or (cl-ppcre:scan
                   (format nil "^\\*+[\\t ]+~a[\\t ]+" quoted) text)
                  (cl-ppcre:scan
                   (format nil
                           "(?:^|[\\t ]+)~a(?:\\([^)]+\\)|\\[[^]]+\\])?:"
                           quoted)
                   text))
          :return keyword))

(defun legit-todo-keyword-index (todo)
  (position (legit-todo-keyword todo) *legit-todo-keywords*
            :test #'string=))

(defun sort-legit-todos (todos)
  (stable-sort todos
               (lambda (left right)
                 (let ((left-keyword (legit-todo-keyword-index left))
                       (right-keyword (legit-todo-keyword-index right)))
                   (or (< left-keyword right-keyword)
                       (and (= left-keyword right-keyword)
                            (or (string< (legit-todo-path left)
                                         (legit-todo-path right))
                                (and (string= (legit-todo-path left)
                                              (legit-todo-path right))
                                     (< (legit-todo-line left)
                                        (legit-todo-line right))))))))))

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
          :for keyword := (detect-legit-todo-keyword text)
          :when (and line keyword (plusp line) (plusp (length path)))
            :do (push (make-legit-todo :path path :line line
                                       :keyword keyword :text text)
                      results)
          :do (setf start (min length (1+ text-end))))
    (sort-legit-todos (nreverse results))))

(defun legit-todo-grep-regexp ()
  (let ((keywords
          (format nil "~{~a~^|~}"
                  (mapcar (lambda (keyword)
                            (if (string= keyword "XXXX*")
                                "XXXX\\*"
                                keyword))
                          *legit-todo-keywords*))))
    (format nil
            "(^[*]+[[:blank:]]+(~a)[[:blank:]]+)|((^|[[:blank:]]+)(~a)(\\([^)]{1,}\\)|\\[[^]]{1,}\\])?:)"
            keywords keywords)))

(defun collect-legit-todos (root)
  "Return bounded configured Magit-Todos matches from tracked files."
  (let ((git (or (executable-find "git")
                 (error "Git is unavailable"))))
    (let ((*project-process-timeout* *legit-todo-timeout*))
      (multiple-value-bind (output error-output status)
          (run-project-program
           (list (uiop:native-namestring git)
                 "grep" "-n" "-I" "-z" "-E" (legit-todo-grep-regexp) "--")
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
  "Append configured Magit-Todos matches to Legit status."
  (declare (ignore collector))
  (unless (string-equal "git" (lem/porcelain::vcs-name vcs))
    (return-from insert-legit-todo-section))
  (let ((root (uiop:ensure-directory-pathname (truename (uiop:getcwd)))))
    (handler-case
        (let ((todos (collect-legit-todos root)))
          (lem/legit::collector-insert "")
          (lem/legit::collector-insert
           (format nil "Todos (~d):" (length todos)) :header t)
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
        (lem/legit::collector-insert "Todos (unavailable):" :header t)
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
(defparameter *jj-split-diff-limit* (* 8 1024 1024))

(defparameter *jj-log-template*
  (concatenate
   'string
   "change_id.shortest(12) ++ \"\\0\" ++ "
   "commit_id.shortest(12) ++ \"\\0\" ++ "
   "if(current_working_copy, \"@\", \" \") ++ \"\\0\" ++ "
   "description.first_line() ++ \"\\0\" ++ "
   "local_bookmarks ++ \"\\0\""))

(defstruct jj-log-entry
  change-id
  commit-id
  marker
  description
  bookmarks)

(defstruct jj-split-hunk
  id
  file
  header
  body
  selection)

(defstruct jj-restore-state
  revision
  from
  into
  changes-in
  fileset
  restore-descendants
  ignore-immutable)

(defstruct jj-absorb-state
  revision
  from
  into
  fileset
  ignore-immutable)

(defstruct jj-squash-state
  initiating-revision
  revision
  from
  into
  placement
  destination
  fileset
  keep-emptied
  ignore-immutable)

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
    (loop :while (>= (length fields) 5)
          :collect (make-jj-log-entry
                    :change-id (pop fields)
                    :commit-id (pop fields)
                    :marker (pop fields)
                    :description (pop fields)
                    :bookmarks (pop fields)))))

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
         (format nil "~a ~12a ~12a  ~a~a~%"
                 (jj-log-entry-marker entry)
                 (jj-log-entry-change-id entry)
                 (jj-log-entry-commit-id entry)
                 (if (str:blankp (jj-log-entry-bookmarks entry))
                     ""
                     (format nil "[~a] "
                             (jj-log-entry-bookmarks entry)))
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

(defun jj-restore-working-copy-point (buffer)
  "Restore BUFFER point to the rendered working-copy row."
  (with-point ((point (buffer-start-point buffer)))
    (loop
      (when (and (jj-row-revision point)
                 (eql (character-at point) #\@))
        (move-point (buffer-point buffer) point)
        (return t))
      (unless (line-offset point 1)
        (return nil)))))

(defun jj-buffer-name (root)
  "Return a repository-specific buffer name for Jujutsu workspace ROOT."
  (format nil "*lem-yath-jj: ~a*"
          (namestring (or (ignore-errors (truename root)) root))))

(define-minor-mode lem-yath-jj-view-mode
    (:name "Jujutsu"
     :keymap *lem-yath-jj-view-keymap*)
  "Majutsu-like navigation and mutation keys for Jujutsu buffers.")

(define-minor-mode lem-yath-jj-split-mode
    (:name "JJ-Split"
     :keymap *lem-yath-jj-split-mode-keymap*)
  "Partial-patch selection keys for a Jujutsu split buffer.")

(define-minor-mode lem-yath-jj-squash-mode
    (:name "JJ-Squash"
     :keymap *lem-yath-jj-squash-mode-keymap*)
  "Partial-patch selection keys for a Jujutsu squash buffer.")

(define-minor-mode lem-yath-jj-restore-mode
    (:name "JJ-Restore"
     :keymap *lem-yath-jj-restore-mode-keymap*)
  "Partial-patch selection keys for a Jujutsu restore buffer.")

(define-major-mode lem-yath-jj-message-mode nil
    (:name "JJ-Message" :keymap *lem-yath-jj-message-mode-keymap*)
  "Edit a Jujutsu description or commit message.")

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-jj-message-mode))
  (list *lem-yath-jj-message-mode-keymap*))

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

(defun jj-bookmark-buffer-name (root)
  (format nil "*lem-yath-jj-bookmarks: ~a*"
          (namestring (or (ignore-errors (truename root)) root))))

(defun render-jj-bookmark-buffer (buffer root)
  "Render local Jujutsu bookmarks in a focused read-only BUFFER."
  (let ((text (run-jj root '("bookmark" "list" "--quiet"))))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string
       (buffer-start-point buffer)
       (format nil "Jujutsu bookmarks: ~a~%~%~a"
               (namestring root)
               (if (str:blankp text) "(no local bookmarks)\n" text)))
      (buffer-start (buffer-point buffer)))
    (buffer-unmark buffer)
    (setf (buffer-directory buffer) root
          (buffer-value buffer *lem-yath-jj-root-key*) root
          (buffer-value buffer *lem-yath-jj-view-kind-key*) :bookmarks
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
      (case (buffer-value (current-buffer) *lem-yath-jj-view-kind-key*)
        (:show
         (render-jj-show-buffer
          (current-buffer) root
          (buffer-value (current-buffer) *lem-yath-jj-revision-key*)))
        (:bookmarks (render-jj-bookmark-buffer (current-buffer) root))
        (otherwise (render-jj-buffer (current-buffer) root)))
      (message "Jujutsu view refreshed"))
    (message "This is not a Jujutsu view")))

(defun jj-current-root ()
  (or (buffer-value (current-buffer) *lem-yath-jj-root-key*)
      (editor-error "This is not a Jujutsu view")))

(defun jj-selected-revision ()
  "Return the revision at point, defaulting to the working copy."
  (or (jj-row-revision) "@"))

(defun jj-current-log-revision ()
  "Return the revision row selected in the current Jujutsu log."
  (unless (eq :log
              (buffer-value (current-buffer) *lem-yath-jj-view-kind-key*))
    (editor-error "This command requires the Jujutsu history"))
  (or (jj-row-revision)
      (editor-error "No Jujutsu revision is selected")))

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

(defun jj-squash-state-label (value)
  "Return a bounded popup label for squash VALUE."
  (if value (completion-bounded-annotation value) "(unset)"))

(defun jj-squash-placement-label (state)
  "Return a compact placement label for squash STATE."
  (if (jj-squash-state-placement state)
      (format nil "~(~a~) ~a"
              (jj-squash-state-placement state)
              (jj-squash-state-label
               (jj-squash-state-destination state)))
      "(unset)"))

(defun jj-squash-keymap (state)
  "Build the pinned Majutsu-style squash popup for STATE."
  (let* ((keymap (make-keymap :description "JJ Squash"))
         (row (jj-squash-state-initiating-revision state)))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          (list
           (list "r" (format nil "revision selected row: ~a~a" row
                              (if (equal row
                                         (jj-squash-state-revision state))
                                  " [selected]" "")))
           (list "f" (format nil "from selected row: ~a~a" row
                              (if (equal row (jj-squash-state-from state))
                                  " [selected]" "")))
           (list "t" (format nil "into selected row: ~a~a" row
                              (if (equal row (jj-squash-state-into state))
                                  " [selected]" "")))
           (list "o" "destination at selected row")
           (list "a" "insert after selected row")
           (list "b" "insert before selected row")
           (list "c" "clear revision selections")
           (list "-" "options: revsets, paths, keep, immutable")
           (list "i" "select patch in Lem")
           (list "s" "squash")
           (list "Return" "squash")
           (list "q" "cancel")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun jj-squash-option-keymap (state)
  "Build the option suffix popup for squash STATE."
  (let ((keymap (make-keymap :description "JJ Squash options")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          (list
           (list "r" (format nil "revision: ~a"
                              (jj-squash-state-label
                               (jj-squash-state-revision state))))
           (list "f" (format nil "from: ~a"
                              (jj-squash-state-label
                               (jj-squash-state-from state))))
           (list "t" (format nil "into: ~a"
                              (jj-squash-state-label
                               (jj-squash-state-into state))))
           (list "o" (format nil "destination: ~a"
                              (jj-squash-placement-label state)))
           (list "A" "insert-after revset")
           (list "B" "insert-before revset")
           (list "-" (format nil "fileset/path: ~a"
                              (jj-squash-state-label
                               (jj-squash-state-fileset state))))
           (list "k" (format nil "keep emptied: ~:[off~;on~]"
                              (jj-squash-state-keep-emptied state)))
           (list "I" (format nil "ignore immutable: ~:[off~;on~]"
                              (jj-squash-state-ignore-immutable state)))
           (list "q" "back")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun jj-squash-clear-selections (state)
  "Clear mutually exclusive revision selections in squash STATE."
  (setf (jj-squash-state-revision state) nil
        (jj-squash-state-from state) nil
        (jj-squash-state-into state) nil
        (jj-squash-state-placement state) nil
        (jj-squash-state-destination state) nil))

(defun jj-squash-select (state category value &optional toggle-p)
  "Set squash CATEGORY in STATE to VALUE while enforcing jj exclusions.
When TOGGLE-P is true, selecting the identical row again clears CATEGORY."
  (ecase category
    (:revision
     (let ((selected
             (unless (and toggle-p
                          (equal value (jj-squash-state-revision state)))
               value)))
       (jj-squash-clear-selections state)
       (setf (jj-squash-state-revision state) selected)))
    (:from
     (setf (jj-squash-state-revision state) nil
           (jj-squash-state-from state)
           (unless (and toggle-p
                        (equal value (jj-squash-state-from state)))
             value)))
    (:into
     (setf (jj-squash-state-revision state) nil
           (jj-squash-state-placement state) nil
           (jj-squash-state-destination state) nil
           (jj-squash-state-into state)
           (unless (and toggle-p
                        (equal value (jj-squash-state-into state)))
             value)))
    ((:destination :after :before)
     (let ((selected
             (unless (and toggle-p
                          (eq category (jj-squash-state-placement state))
                          (equal value
                                 (jj-squash-state-destination state)))
               value)))
       (setf (jj-squash-state-revision state) nil
             (jj-squash-state-into state) nil
             (jj-squash-state-placement state) (and selected category)
             (jj-squash-state-destination state) selected)))))

(defun jj-squash-prompt-label (category)
  (ecase category
    (:revision "Squash revision or revset: ")
    (:from "Squash from revision or revset: ")
    (:into "Squash into revision or revset: ")
    (:destination "Squash destination revision or revset: ")
    (:after "Squash insert-after revision or revset: ")
    (:before "Squash insert-before revision or revset: ")))

(defun jj-squash-set-revset (state root category)
  "Prompt for and set squash CATEGORY on STATE at ROOT."
  (jj-squash-select
   state category
   (jj-prompt-for-revision
    root (jj-squash-prompt-label category)
    (intern (format nil "LEM-YATH-JJ-SQUASH-~a" category) :lem-yath))))

(defun jj-squash-read-option (state)
  "Read one `-' squash option key for STATE."
  (let ((lem/transient:*transient-popup-delay* 0))
    (keymap-activate (jj-squash-option-keymap state)))
  (redraw-display)
  (prog1
      (lem-core::keyseq-to-string (list (read-key)))
    (lem/transient::hide-transient)))

(defun jj-squash-handle-option (state root)
  "Update squash STATE from one pinned option at ROOT."
  (let ((name (jj-squash-read-option state)))
    (cond
      ((string= name "r") (jj-squash-set-revset state root :revision))
      ((string= name "f") (jj-squash-set-revset state root :from))
      ((string= name "t") (jj-squash-set-revset state root :into))
      ((string= name "o") (jj-squash-set-revset state root :destination))
      ((string= name "A") (jj-squash-set-revset state root :after))
      ((string= name "B") (jj-squash-set-revset state root :before))
      ((string= name "-")
       (let ((fileset
               (prompt-for-string
                "Squash fileset or path (empty clears): "
                :history-symbol 'lem-yath-jj-squash-fileset)))
         (setf (jj-squash-state-fileset state)
               (unless (str:blankp fileset) fileset))))
      ((string= name "k")
       (setf (jj-squash-state-keep-emptied state)
             (not (jj-squash-state-keep-emptied state))))
      ((string= name "I")
       (setf (jj-squash-state-ignore-immutable state)
             (not (jj-squash-state-ignore-immutable state))))
      ((or (string= name "q") (string= name "Escape")) nil)
      (t (message "No squash option is bound to - ~a" name)))))

(defun jj-squash-effective-revision (state)
  "Return STATE's revision-mode source, including the log-row default."
  (or (jj-squash-state-revision state)
      (unless (or (jj-squash-state-from state)
                  (jj-squash-state-into state)
                  (jj-squash-state-placement state))
        (jj-squash-state-initiating-revision state))))

(defun jj-squash-editor-config ()
  "Return config that accepts jj's own prefilled squash description."
  (list "--config"
        (format nil "ui.editor=[~a]"
                (jj-toml-string
                 (namestring (jj-required-executable "true"))))))

(defun jj-squash-arguments (state &optional extra-options)
  "Return direct whole or interactive `jj squash' arguments for STATE."
  (let ((arguments (list "squash"))
        (revision (jj-squash-effective-revision state)))
    (cond
      (revision
       (setf arguments (append arguments (list "--revision" revision))))
      (t
       (when (jj-squash-state-from state)
         (setf arguments
               (append arguments
                       (list "--from" (jj-squash-state-from state)))))
       (when (jj-squash-state-into state)
         (setf arguments
               (append arguments
                       (list "--into" (jj-squash-state-into state)))))
       (when (jj-squash-state-placement state)
         (setf arguments
               (append
                arguments
                (list
                 (ecase (jj-squash-state-placement state)
                   (:destination "--destination")
                   (:after "--insert-after")
                   (:before "--insert-before"))
                 (jj-squash-state-destination state)))))))
    (when (jj-squash-state-keep-emptied state)
      (setf arguments (append arguments '("--keep-emptied"))))
    (when (jj-squash-state-ignore-immutable state)
      (setf arguments (append arguments '("--ignore-immutable"))))
    (setf arguments (append arguments (jj-squash-editor-config)))
    (when extra-options
      (setf arguments (append arguments extra-options)))
    (when (jj-squash-state-fileset state)
      (setf arguments
            (append arguments
                    (list "--" (jj-squash-state-fileset state)))))
    arguments))

(defun jj-execute-squash (root state)
  "Execute whole squash STATE at ROOT and restore its logical history row."
  (let* ((buffer (current-buffer))
         (revision (jj-squash-effective-revision state))
         (parent (and revision (jj-single-parent-revision root revision))))
    (run-jj root (jj-squash-arguments state))
    (render-jj-buffer buffer root)
    (or (jj-restore-revision-point
         buffer (jj-squash-state-initiating-revision state))
        (jj-restore-revision-point buffer parent)
        (jj-restore-working-copy-point buffer))
    (message "Jujutsu change squashed")))

(defun dispatch-jj-squash (root revision)
  "Configure and execute pinned Majutsu squash from history REVISION."
  (let ((state (make-jj-squash-state :initiating-revision revision)))
    (unwind-protect
         (loop
           (let ((lem/transient:*transient-popup-delay* 0))
             (keymap-activate (jj-squash-keymap state)))
           (redraw-display)
           (let* ((key (read-key))
                  (name (lem-core::keyseq-to-string (list key))))
             (lem/transient::hide-transient)
             (cond
               ((string= name "r")
                (jj-squash-select state :revision revision t))
               ((string= name "f")
                (jj-squash-select state :from revision t))
               ((string= name "t")
                (jj-squash-select state :into revision t))
               ((string= name "o")
                (jj-squash-select state :destination revision t))
               ((string= name "a")
                (jj-squash-select state :after revision t))
               ((string= name "b")
                (jj-squash-select state :before revision t))
               ((string= name "c") (jj-squash-clear-selections state))
               ((string= name "-") (jj-squash-handle-option state root))
               ((string= name "i")
                (jj-open-squash-selection root state)
                (return))
               ((or (string= name "s") (string= name "Return"))
                (jj-execute-squash root state)
                (return))
               ((or (string= name "q") (string= name "Escape"))
                (message "Jujutsu squash cancelled")
                (return))
               (t (message "No squash action is bound to ~a" name)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-jj-squash () ()
  "Open pinned Majutsu squash from the selected Jujutsu revision."
  (let ((root (jj-current-root))
        (revision (jj-selected-revision)))
    ;; Preserve the established fail-fast behavior for roots and merges before
    ;; presenting a default that cannot execute.
    (jj-single-parent-revision root revision)
    (dispatch-jj-squash root revision)))

(defun jj-prompt-for-revision (root prompt history-symbol)
  "Read a history change ID or arbitrary jj revset using PROMPT and HISTORY-SYMBOL."
  (let* ((entries (jj-log-entries root))
         (choices
           (mapcar (lambda (entry)
                     (cons (jj-log-entry-change-id entry) entry))
                   entries)))
    (prompt-for-string
     prompt
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
     :history-symbol history-symbol)))

(defun jj-absorb-state-label (value)
  "Return a bounded popup label for absorb VALUE."
  (if value (completion-bounded-annotation value) "(unset)"))

(defun jj-absorb-keymap (state)
  "Build the pinned Majutsu-style absorb popup for STATE."
  (let* ((keymap (make-keymap :description "JJ Absorb"))
         (revision (jj-absorb-state-revision state))
         (from (jj-absorb-state-from state))
         (into (jj-absorb-state-into state)))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          (list
           (list "f" (format nil "from selected row: ~a~a"
                              revision
                              (if (equal from revision) " [selected]" "")))
           (list "t" (format nil "into selected row: ~a~a"
                              revision
                              (if (equal into revision) " [selected]" "")))
           (list "c" "clear selections")
           (list "-" "options: revsets, fileset, immutable")
           (list "a" "absorb")
           (list "Return" "absorb")
           (list "q" "cancel")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun jj-absorb-option-keymap (state)
  "Build the option suffix popup for absorb STATE."
  (let ((keymap (make-keymap :description "JJ Absorb options")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          (list
           (list "f" (format nil "from revset: ~a"
                              (jj-absorb-state-label
                               (jj-absorb-state-from state))))
           (list "t" (format nil "into revset: ~a"
                              (jj-absorb-state-label
                               (jj-absorb-state-into state))))
           (list "-" (format nil "fileset/path: ~a"
                              (jj-absorb-state-label
                               (jj-absorb-state-fileset state))))
           (list "I" (format nil "ignore immutable: ~:[off~;on~]"
                              (jj-absorb-state-ignore-immutable state)))
           (list "q" "back")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun jj-absorb-select-row (state category)
  "Toggle STATE's initiating revision in absorb CATEGORY."
  (let ((revision (jj-absorb-state-revision state)))
    (ecase category
      (:from
       (setf (jj-absorb-state-from state)
             (unless (equal (jj-absorb-state-from state) revision)
               revision)))
      (:into
       (setf (jj-absorb-state-into state)
             (unless (equal (jj-absorb-state-into state) revision)
               revision))))))

(defun jj-absorb-set-revset (state root category)
  "Prompt for and set absorb CATEGORY on STATE at ROOT."
  (let ((revision
          (jj-prompt-for-revision
           root
           (ecase category
             (:from "Absorb from revision or revset: ")
             (:into "Absorb into revision or revset: "))
           (ecase category
             (:from 'lem-yath-jj-absorb-from)
             (:into 'lem-yath-jj-absorb-into)))))
    (ecase category
      (:from (setf (jj-absorb-state-from state) revision))
      (:into (setf (jj-absorb-state-into state) revision)))))

(defun jj-absorb-read-option (state)
  "Read one `-' absorb option key for STATE."
  (let ((lem/transient:*transient-popup-delay* 0))
    (keymap-activate (jj-absorb-option-keymap state)))
  (redraw-display)
  (prog1
      (lem-core::keyseq-to-string (list (read-key)))
    (lem/transient::hide-transient)))

(defun jj-absorb-handle-option (state root)
  "Update absorb STATE from one pinned option at ROOT."
  (let ((name (jj-absorb-read-option state)))
    (cond
      ((string= name "f") (jj-absorb-set-revset state root :from))
      ((string= name "t") (jj-absorb-set-revset state root :into))
      ((string= name "-")
       (let ((fileset
               (prompt-for-string
                "Absorb fileset or path (empty clears): "
                :history-symbol 'lem-yath-jj-absorb-fileset)))
         (setf (jj-absorb-state-fileset state)
               (unless (str:blankp fileset) fileset))))
      ((string= name "I")
       (setf (jj-absorb-state-ignore-immutable state)
             (not (jj-absorb-state-ignore-immutable state))))
      ((or (string= name "q") (string= name "Escape")) nil)
      (t (message "No absorb option is bound to - ~a" name)))))

(defun jj-absorb-arguments (state)
  "Return direct `jj absorb' arguments represented by STATE."
  (let ((arguments (list "absorb")))
    (when (jj-absorb-state-from state)
      (setf arguments
            (append arguments
                    (list "--from" (jj-absorb-state-from state)))))
    (when (jj-absorb-state-into state)
      (setf arguments
            (append arguments
                    (list "--into" (jj-absorb-state-into state)))))
    (unless (or (jj-absorb-state-from state)
                (jj-absorb-state-into state))
      (setf arguments
            (append arguments
                    (list "--from" (jj-absorb-state-revision state)))))
    (when (jj-absorb-state-ignore-immutable state)
      (setf arguments (append arguments '("--ignore-immutable"))))
    (when (jj-absorb-state-fileset state)
      (setf arguments
            (append arguments
                    (list "--" (jj-absorb-state-fileset state)))))
    arguments))

(defun jj-execute-absorb (root state)
  "Execute absorb STATE at ROOT and retain its initiating history context."
  (let ((buffer (current-buffer))
        (revision (jj-absorb-state-revision state)))
    (run-jj root (jj-absorb-arguments state))
    (render-jj-buffer buffer root)
    (unless (jj-restore-revision-point buffer revision)
      (jj-restore-working-copy-point buffer))
    (message "Jujutsu absorb completed")))

(defun dispatch-jj-absorb (root revision)
  "Configure and execute pinned Majutsu absorb from history REVISION."
  (let ((state (make-jj-absorb-state :revision revision)))
    (unwind-protect
         (loop
           (let ((lem/transient:*transient-popup-delay* 0))
             (keymap-activate (jj-absorb-keymap state)))
           (redraw-display)
           (let* ((key (read-key))
                  (name (lem-core::keyseq-to-string (list key))))
             (lem/transient::hide-transient)
             (cond
               ((string= name "f") (jj-absorb-select-row state :from))
               ((string= name "t") (jj-absorb-select-row state :into))
               ((string= name "c")
                (setf (jj-absorb-state-from state) nil
                      (jj-absorb-state-into state) nil))
               ((string= name "-") (jj-absorb-handle-option state root))
               ((or (string= name "a") (string= name "Return"))
                (jj-execute-absorb root state)
                (return))
               ((or (string= name "q") (string= name "Escape"))
                (message "Jujutsu absorb cancelled")
                (return))
               (t (message "No absorb action is bound to ~a" name)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-jj-absorb () ()
  "Open the pinned Majutsu absorb workflow from the selected revision row."
  (dispatch-jj-absorb (jj-current-root) (jj-current-log-revision)))

(defun jj-related-visible-entries (root revision relation)
  "Return visible history entries related to REVISION by RELATION."
  (let* ((revset
           (ecase relation
             (:parent (format nil "parents(~a)" revision))
             (:child (format nil "children(~a)" revision))))
         (related
           (jj-split-null-fields
            (run-jj root
                    (list "log" "--no-graph" "-r" revset
                          "--template"
                          "change_id.shortest(12) ++ \"\\0\"")))))
    (remove-if-not
     (lambda (entry)
       (find (jj-log-entry-change-id entry) related :test #'string=))
     (jj-log-entries root))))

(defun jj-prompt-for-related-entry (prompt entries)
  "Read one exact history entry from ENTRIES using PROMPT."
  (let ((choices
          (mapcar (lambda (entry)
                    (cons (jj-log-entry-change-id entry) entry))
                  entries)))
    (prompt-for-string
     prompt
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
     :test-function
     (lambda (input)
       (not (null (assoc input choices :test #'string=)))))))

(defun jj-goto-related-revision (relation)
  "Move to a visible parent or child row selected by RELATION."
  (let* ((root (jj-current-root))
         (revision (jj-current-log-revision))
         (entries (jj-related-visible-entries root revision relation))
         (label (if (eq relation :parent) "parent" "child")))
    (unless entries
      (editor-error "No ~a revisions are visible in the current history" label))
    (let* ((entry
             (if (null (rest entries))
                 (first entries)
                 (let ((id
                         (jj-prompt-for-related-entry
                          (format nil "Go to ~a: " label) entries)))
                   (find id entries :key #'jj-log-entry-change-id
                                    :test #'string=))))
           (target (jj-log-entry-change-id entry)))
      (unless (jj-restore-revision-point (current-buffer) target)
        (editor-error "The selected ~a is no longer visible" label))
      target)))

(defun jj-revert-keymap (source placement destination)
  "Build a focused Majutsu-style revert popup for the current selections."
  (let ((keymap (make-keymap :description "JJ Revert"))
        (source-label (completion-bounded-annotation source))
        (destination-label (completion-bounded-annotation destination)))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          (list
           (list "r" (format nil "source revisions: ~a" source-label))
           (list "o" (format nil "onto: ~a~a"
                              destination-label
                              (if (eq placement :onto) " [selected]" "")))
           (list "a" (format nil "insert after: ~a~a"
                              destination-label
                              (if (eq placement :after) " [selected]" "")))
           (list "b" (format nil "insert before: ~a~a"
                              destination-label
                              (if (eq placement :before) " [selected]" "")))
           (list "c" "reset to selected row")
           (list "_" "execute revert")
           (list "V" "execute revert")
           (list "Return" "execute revert")
           (list "q" "cancel")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun jj-execute-revert (root source placement destination selected-revision)
  "Revert SOURCE at DESTINATION according to PLACEMENT and retain selection."
  (let ((placement-argument
          (ecase placement
            (:onto "--destination")
            (:after "--insert-after")
            (:before "--insert-before")))
        (buffer (current-buffer)))
    (run-jj root
            (list "revert" "--revisions" source
                  placement-argument destination))
    (render-jj-buffer buffer root)
    (jj-restore-revision-point buffer selected-revision)
    (message "Jujutsu revert completed")))

(defun dispatch-jj-revert (root revision)
  "Configure and execute a Jujutsu revert rooted at REVISION."
  (let ((source revision)
        (placement :after)
        (destination revision))
    (unwind-protect
         (loop
           (let ((lem/transient:*transient-popup-delay* 0))
             (keymap-activate
              (jj-revert-keymap source placement destination)))
           (redraw-display)
           (let* ((key (read-key))
                  (name (lem-core::keyseq-to-string (list key))))
             (lem/transient::hide-transient)
             (cond
               ((string= name "r")
                (setf source
                      (jj-prompt-for-revision
                       root "Revert revisions: " 'lem-yath-jj-revert-source)))
               ((member name '("o" "a" "b") :test #'string=)
                (setf placement
                      (cond
                        ((string= name "o") :onto)
                        ((string= name "a") :after)
                        (t :before))
                      destination
                      (jj-prompt-for-revision
                       root
                       (ecase placement
                         (:onto "Revert onto: ")
                         (:after "Insert revert after: ")
                         (:before "Insert revert before: "))
                       'lem-yath-jj-revert-destination)))
               ((string= name "c")
                (setf source revision
                      placement :after
                      destination revision))
               ((or (string= name "_") (string= name "V")
                    (string= name "Return"))
                (jj-execute-revert
                 root source placement destination revision)
                (return))
               ((or (string= name "q") (string= name "Escape"))
                (message "Jujutsu revert cancelled")
                (return))
               (t (message "No revert action is bound to ~a" name)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-jj-revert () ()
  "Open the Majutsu-style revert workflow for the selected revision."
  (let ((root (jj-current-root))
        (revision (jj-current-log-revision)))
    (dispatch-jj-revert root revision)))

(defun jj-restore-state-label (value)
  "Return a bounded popup label for restore VALUE."
  (if value (completion-bounded-annotation value) "(unset)"))

(defun jj-restore-keymap (state)
  "Build a Majutsu-style restore popup for STATE."
  (let* ((keymap (make-keymap :description "JJ Restore"))
         (revision (jj-restore-state-revision state))
         (from (jj-restore-state-from state))
         (into (jj-restore-state-into state))
         (changes-in (jj-restore-state-changes-in state)))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          (list
           (list "f" (format nil "from selected row: ~a~a"
                              revision
                              (if (equal from revision) " [selected]" "")))
           (list "t" (format nil "into selected row: ~a~a"
                              revision
                              (if (equal into revision) " [selected]" "")))
           (list "c" (format nil "changes in selected row: ~a~a"
                              revision
                              (if (equal changes-in revision)
                                  " [selected]"
                                  "")))
           (list "-" "options: revsets, fileset, descendants, immutable")
           (list "x" "clear revision selections")
           (list "r" "restore")
           (list "q" "cancel")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun jj-restore-option-keymap (state)
  "Build the option suffix popup for restore STATE."
  (let ((keymap (make-keymap :description "JJ Restore options")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          (list
           (list "f" (format nil "from revset: ~a"
                              (jj-restore-state-label
                               (jj-restore-state-from state))))
           (list "t" (format nil "into revset: ~a"
                              (jj-restore-state-label
                               (jj-restore-state-into state))))
           (list "c" (format nil "changes-in revset: ~a"
                              (jj-restore-state-label
                               (jj-restore-state-changes-in state))))
           (list "-" (format nil "fileset/path: ~a"
                              (jj-restore-state-label
                               (jj-restore-state-fileset state))))
           (list "d" (format nil "restore descendants: ~:[off~;on~]"
                              (jj-restore-state-restore-descendants state)))
           (list "i" "interactive partial selection")
           (list "I" (format nil "ignore immutable: ~:[off~;on~]"
                              (jj-restore-state-ignore-immutable state)))
           (list "q" "back")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun jj-restore-select-row (state category)
  "Toggle STATE's selected revision in restore CATEGORY."
  (let ((revision (jj-restore-state-revision state)))
    (ecase category
      (:from
       (setf (jj-restore-state-from state)
             (unless (equal (jj-restore-state-from state) revision) revision)
             (jj-restore-state-changes-in state) nil))
      (:into
       (setf (jj-restore-state-into state)
             (unless (equal (jj-restore-state-into state) revision) revision)
             (jj-restore-state-changes-in state) nil))
      (:changes-in
       (setf (jj-restore-state-changes-in state)
             (unless (equal (jj-restore-state-changes-in state) revision)
               revision)
             (jj-restore-state-from state) nil
             (jj-restore-state-into state) nil)))))

(defun jj-restore-set-revset (state root category)
  "Prompt for and set restore CATEGORY on STATE at ROOT."
  (let ((revision
          (jj-prompt-for-revision
           root
           (ecase category
             (:from "Restore from revision or revset: ")
             (:into "Restore into revision or revset: ")
             (:changes-in "Restore changes in revision or revset: "))
           (ecase category
             (:from 'lem-yath-jj-restore-from)
             (:into 'lem-yath-jj-restore-into)
             (:changes-in 'lem-yath-jj-restore-changes-in)))))
    (ecase category
      (:from
       (setf (jj-restore-state-from state) revision
             (jj-restore-state-changes-in state) nil))
      (:into
       (setf (jj-restore-state-into state) revision
             (jj-restore-state-changes-in state) nil))
      (:changes-in
       (setf (jj-restore-state-changes-in state) revision
             (jj-restore-state-from state) nil
             (jj-restore-state-into state) nil)))))

(defun jj-restore-read-option (state)
  "Read one `-' restore option key for STATE."
  (let ((lem/transient:*transient-popup-delay* 0))
    (keymap-activate (jj-restore-option-keymap state)))
  (redraw-display)
  (prog1
      (lem-core::keyseq-to-string (list (read-key)))
    (lem/transient::hide-transient)))

(defun jj-restore-handle-option (state root)
  "Update restore STATE from one Majutsu-style option at ROOT."
  (let ((name (jj-restore-read-option state)))
    (cond
      ((string= name "f") (jj-restore-set-revset state root :from))
      ((string= name "t") (jj-restore-set-revset state root :into))
      ((string= name "c") (jj-restore-set-revset state root :changes-in))
      ((string= name "-")
       (let ((fileset
               (prompt-for-string
                "Restore fileset or path (empty clears): "
                :history-symbol 'lem-yath-jj-restore-fileset)))
         (setf (jj-restore-state-fileset state)
               (unless (str:blankp fileset) fileset))))
      ((string= name "d")
       (setf (jj-restore-state-restore-descendants state)
             (not (jj-restore-state-restore-descendants state))))
      ((string= name "i") :interactive)
      ((string= name "I")
       (setf (jj-restore-state-ignore-immutable state)
             (not (jj-restore-state-ignore-immutable state))))
      ((or (string= name "q") (string= name "Escape")) nil)
      (t (message "No restore option is bound to - ~a" name)))))

(defun jj-restore-arguments (state &optional extra-options)
  "Return direct `jj restore' arguments represented by STATE."
  (let ((arguments (list "restore")))
    (when (jj-restore-state-from state)
      (setf arguments
            (append arguments
                    (list "--from" (jj-restore-state-from state)))))
    (when (jj-restore-state-into state)
      (setf arguments
            (append arguments
                    (list "--into" (jj-restore-state-into state)))))
    (when (jj-restore-state-changes-in state)
      (setf arguments
            (append arguments
                    (list "--changes-in"
                          (jj-restore-state-changes-in state)))))
    (when (jj-restore-state-restore-descendants state)
      (setf arguments (append arguments '("--restore-descendants"))))
    (when (jj-restore-state-ignore-immutable state)
      (setf arguments (append arguments '("--ignore-immutable"))))
    (when extra-options
      (setf arguments (append arguments extra-options)))
    (when (jj-restore-state-fileset state)
      (setf arguments
            (append arguments
                    (list "--" (jj-restore-state-fileset state)))))
    arguments))

(defun jj-execute-restore (root state)
  "Execute restore STATE at ROOT and retain the selected history row."
  (let ((buffer (current-buffer))
        (revision (jj-restore-state-revision state)))
    (run-jj root (jj-restore-arguments state))
    (render-jj-buffer buffer root)
    (jj-restore-revision-point buffer revision)
    (message "Jujutsu restore completed")))

(defun dispatch-jj-restore (root revision)
  "Configure and execute Majutsu-style restore from history REVISION."
  (let ((state (make-jj-restore-state :revision revision)))
    (unwind-protect
         (loop
           (let ((lem/transient:*transient-popup-delay* 0))
             (keymap-activate (jj-restore-keymap state)))
           (redraw-display)
           (let* ((key (read-key))
                  (name (lem-core::keyseq-to-string (list key))))
             (lem/transient::hide-transient)
             (cond
               ((string= name "f") (jj-restore-select-row state :from))
               ((string= name "t") (jj-restore-select-row state :into))
               ((string= name "c")
                (jj-restore-select-row state :changes-in))
               ((string= name "-")
                (when (eq :interactive
                          (jj-restore-handle-option state root))
                  (jj-open-restore-selection root state)
                  (return)))
               ((string= name "x")
                (setf (jj-restore-state-from state) nil
                      (jj-restore-state-into state) nil
                      (jj-restore-state-changes-in state) nil))
               ((string= name "r")
                (jj-execute-restore root state)
                (return))
               ((or (string= name "q") (string= name "Escape"))
                (message "Jujutsu restore cancelled")
                (return))
               (t (message "No restore action is bound to ~a" name)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-jj-restore () ()
  "Open the Majutsu-style restore workflow from the selected revision row."
  (dispatch-jj-restore (jj-current-root) (jj-current-log-revision)))

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
  (let ((destination
          (jj-prompt-for-revision
           root
           "Rebase destination revision or revset: "
           'lem-yath-jj-rebase-destination)))
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

(defun jj-duplicate-keymap ()
  "Build the focused Majutsu-style duplicate popup."
  (let ((keymap (make-keymap :description "JJ Duplicate")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist (entry
              '(("Return" "duplicate onto the existing parent")
                ("y" "duplicate onto the existing parent")
                ("o" "duplicate onto a destination")
                ("a" "duplicate after a destination")
                ("b" "duplicate before a destination")
                ("q" "cancel")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun jj-duplicate-arguments (revision action &optional destination)
  "Return direct jj duplicate arguments for REVISION, ACTION, and DESTINATION."
  (ecase action
    (:parent (list "duplicate" revision))
    (:onto (list "duplicate" revision "--destination" destination))
    (:after (list "duplicate" revision "--insert-after" destination))
    (:before (list "duplicate" revision "--insert-before" destination))))

(defun jj-duplicate-prompt (action)
  "Return the destination prompt for duplicate ACTION."
  (ecase action
    (:onto "Duplicate destination revision or revset: ")
    (:after "Duplicate insert-after revision or revset: ")
    (:before "Duplicate insert-before revision or revset: ")))

(defun jj-execute-duplicate (root revision action)
  "Duplicate row REVISION according to placement ACTION and retain its row."
  (let ((destination
          (unless (eq action :parent)
            (jj-prompt-for-revision
             root (jj-duplicate-prompt action)
             'lem-yath-jj-duplicate-destination))))
    (run-jj root (jj-duplicate-arguments revision action destination))
    (let ((buffer (current-buffer)))
      (render-jj-buffer buffer root)
      (jj-restore-revision-point buffer revision))
    (message "Jujutsu change duplicated")))

(defun dispatch-jj-duplicate (root revision)
  "Read one focused Majutsu-style duplicate action for REVISION."
  (unwind-protect
       (progn
         (let ((lem/transient:*transient-popup-delay* 0))
           (keymap-activate (jj-duplicate-keymap)))
         (redraw-display)
         (let* ((key (read-key))
                (name (lem-core::keyseq-to-string (list key))))
           (lem/transient::hide-transient)
           (cond
             ((or (string= name "Return") (string= name "y"))
              (jj-execute-duplicate root revision :parent))
             ((string= name "o")
              (jj-execute-duplicate root revision :onto))
             ((string= name "a")
              (jj-execute-duplicate root revision :after))
             ((string= name "b")
              (jj-execute-duplicate root revision :before))
             ((or (string= name "q") (string= name "Escape"))
              (message "Jujutsu duplicate cancelled"))
             (t (message "No duplicate action is bound to ~a" name)))))
    (lem/transient::hide-transient)))

(define-command lem-yath-jj-duplicate () ()
  "Duplicate the selected change through a Majutsu-style placement popup."
  (dispatch-jj-duplicate (jj-current-root) (jj-selected-revision)))

(define-command lem-yath-jj-duplicate-dwim () ()
  "Duplicate the selected change onto its existing parent, like Majutsu `Y'."
  (jj-execute-duplicate
   (jj-current-root) (jj-selected-revision) :parent))

(defun parse-jj-split-hunks (output)
  "Parse Git-format jj diff OUTPUT into ordered textual hunks."
  (let ((file nil)
        (header nil)
        (body nil)
        (hunks '())
        (next-id 1))
    (labels ((flush-hunk ()
               (when body
                 (push (make-jj-split-hunk
                        :id next-id
                        :file file
                        :header (apply #'concatenate 'string
                                       (nreverse (copy-list header)))
                        :body (apply #'concatenate 'string
                                     (nreverse body)))
                       hunks)
                 (incf next-id)
                 (setf body nil))))
      (dolist (line (git-diff-lines-with-endings output))
        (cond
          ((uiop:string-prefix-p "diff --git " line)
           (flush-hunk)
           (setf file
                 (string-right-trim '(#\Newline #\Return) line)
                 header (list line)
                 body nil))
          ((uiop:string-prefix-p "@@ " line)
           (unless file
             (editor-error "Malformed Jujutsu Git diff: hunk before file"))
           (flush-hunk)
           (setf body (list line)))
          (body (push line body))
          (file (push line header))))
      (flush-hunk))
    (nreverse hunks)))

(defun jj-split-hunk-lines (hunk)
  "Return HUNK body entries as (INDEX LINE)."
  (loop :for line :in (git-diff-lines-with-endings (jj-split-hunk-body hunk))
        :for index :from 0
        :collect (list index line)))

(defun jj-split-change-line-p (line)
  "Return whether LINE is an added or removed hunk-body line."
  (and (plusp (length line))
       (member (char line 0) '(#\+ #\-) :test #'char=)))

(defun jj-split-hunk-marker (hunk)
  "Return the display marker for HUNK's selection state."
  (cond
    ((eq :all (jj-split-hunk-selection hunk)) "x")
    ((jj-split-hunk-selection hunk) "*")
    (t " ")))

(defun jj-split-selected-count (hunks)
  (count-if #'jj-split-hunk-selection hunks))

(defun jj-split-placement-label (buffer)
  "Return BUFFER's split placement as a concise label."
  (let ((placement (buffer-value buffer *lem-yath-jj-split-placement-key*))
        (destination
          (buffer-value buffer *lem-yath-jj-split-destination-key*)))
    (case placement
      (:destination (format nil "onto ~a" destination))
      (:after (format nil "after ~a" destination))
      (:before (format nil "before ~a" destination))
      (otherwise "existing parent"))))

(defun jj-split-hunk-at-point (&optional (point (current-point)))
  "Return the split hunk represented at POINT."
  (alexandria:when-let
      ((id (text-property-at point *lem-yath-jj-split-hunk-key*)))
    (find id
          (buffer-value (current-buffer) *lem-yath-jj-split-hunks-key*)
          :key #'jj-split-hunk-id)))

(defun jj-restore-split-hunk-point (buffer id)
  "Restore BUFFER point to split hunk ID."
  (when id
    (with-point ((point (buffer-start-point buffer)))
      (loop
        (when (eql id
                   (text-property-at point *lem-yath-jj-split-hunk-key*))
          (move-point (buffer-point buffer) point)
          (return t))
        (unless (line-offset point 1)
          (return nil))))))

(defun render-jj-split-buffer (buffer)
  "Render BUFFER's partial split selection without changing its model."
  (let* ((hunks (buffer-value buffer *lem-yath-jj-split-hunks-key*))
         (revision (buffer-value buffer *lem-yath-jj-revision-key*))
         (root (buffer-value buffer *lem-yath-jj-root-key*))
         (current-id
           (save-excursion
             (setf (current-buffer) buffer)
             (alexandria:when-let ((hunk (jj-split-hunk-at-point)))
               (jj-split-hunk-id hunk))))
         (previous-file nil))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (let ((point (buffer-end-point buffer)))
        (insert-string
         point
         (format nil
                 "Jujutsu split: ~a~%Revision: ~a~%Selected: ~d/~d hunks  Placement: ~a  Layout: ~a~%~%H/Space hunk, F file, R region, C clear, o/a/b placement, c parent, p parallel, s/RET execute, q cancel~%"
                 (namestring root)
                 revision
                 (jj-split-selected-count hunks)
                 (length hunks)
                 (jj-split-placement-label buffer)
                 (if (buffer-value buffer *lem-yath-jj-split-parallel-key*)
                     "parallel"
                     "linear")))
        (dolist (hunk hunks)
          (unless (equal previous-file (jj-split-hunk-file hunk))
            (setf previous-file (jj-split-hunk-file hunk))
            (insert-string point (format nil "~%~a~%" previous-file)))
          (with-point ((start point))
            (insert-string
             point
             (format nil "[~a] Hunk ~d~%"
                     (jj-split-hunk-marker hunk)
                     (jj-split-hunk-id hunk)))
            (put-text-property start point *lem-yath-jj-split-hunk-key*
                               (jj-split-hunk-id hunk)))
          (dolist (entry (jj-split-hunk-lines hunk))
            (destructuring-bind (index line) entry
              (with-point ((start point))
                (insert-string point line)
                (put-text-property start point *lem-yath-jj-split-hunk-key*
                                   (jj-split-hunk-id hunk))
                (when (jj-split-change-line-p line)
                  (put-text-property
                   start point *lem-yath-jj-split-line-key*
                   (cons (jj-split-hunk-id hunk) index))))))))
      (buffer-unmark buffer))
    (setf (buffer-read-only-p buffer) t)
    (unless (jj-restore-split-hunk-point buffer current-id)
      (jj-restore-split-hunk-point buffer
                                   (jj-split-hunk-id (first hunks))))
    buffer))

(defun jj-split-toggle-hunk-model (hunk)
  "Toggle whole-HUNK selection."
  (setf (jj-split-hunk-selection hunk)
        (unless (jj-split-hunk-selection hunk) :all)))

(define-command lem-yath-jj-split-toggle-hunk () ()
  "Toggle the complete split hunk at point."
  (let ((hunk (or (jj-split-hunk-at-point)
                  (editor-error "No Jujutsu split hunk at point"))))
    (jj-split-toggle-hunk-model hunk)
    (render-jj-split-buffer (current-buffer))
    (message (if (jj-split-hunk-selection hunk)
                 "Selected split hunk"
                 "Deselected split hunk"))))

(define-command lem-yath-jj-split-toggle-file () ()
  "Toggle every split hunk belonging to the file at point."
  (let* ((hunk (or (jj-split-hunk-at-point)
                   (editor-error "No Jujutsu split file at point")))
         (file (jj-split-hunk-file hunk))
         (hunks
           (remove-if-not
            (lambda (candidate)
              (equal file (jj-split-hunk-file candidate)))
            (buffer-value (current-buffer) *lem-yath-jj-split-hunks-key*)))
         (selected-p (every #'jj-split-hunk-selection hunks)))
    (dolist (candidate hunks)
      (setf (jj-split-hunk-selection candidate)
            (unless selected-p :all)))
    (render-jj-split-buffer (current-buffer))
    (message (if selected-p
                 "Deselected split file"
                 "Selected split file"))))

(defun jj-split-region-entries (buffer)
  "Return unique (HUNK-ID . LINE-INDEX) entries selected in BUFFER."
  (unless (buffer-mark-p buffer)
    (editor-error "No active region in the Jujutsu split diff"))
  (let* ((visual-p
           (and (typep (current-global-mode) 'lem-vi-mode:vi-mode)
                (lem-vi-mode/visual:visual-p buffer)))
         (bounds
           (when visual-p
             (lem-vi-mode/visual:visual-range buffer)))
         (start (if bounds
                    (point-min (first bounds) (second bounds))
                    (region-beginning buffer)))
         (end (if bounds
                  (point-max (first bounds) (second bounds))
                  (region-end buffer)))
         (entries '()))
    (when (and (not visual-p) (point= start end))
      (editor-error "The active split region is empty"))
    (with-point ((point start)
                 (last-line end))
      (line-start point)
      (line-start last-line)
      (if visual-p
          (loop
            :for entry := (text-property-at
                           point *lem-yath-jj-split-line-key*)
            :do (when entry (pushnew entry entries :test #'equal))
            :until (point>= point last-line)
            :unless (line-offset point 1)
              :do (return))
          (loop :while (point< point end)
                :for entry := (text-property-at
                               point *lem-yath-jj-split-line-key*)
                :do (when entry (pushnew entry entries :test #'equal))
                :while (line-offset point 1))))
    (unless entries
      (editor-error "The region contains no changed split lines"))
    (let ((id (caar entries)))
      (unless (every (lambda (entry) (eql id (car entry))) entries)
        (editor-error "A split region must stay within one hunk")))
    (nreverse entries)))

(define-command lem-yath-jj-split-toggle-region () ()
  "Use the active region's changed lines as a partial hunk selection."
  (let* ((buffer (current-buffer))
         (entries (jj-split-region-entries buffer))
         (id (caar entries))
         (indices (mapcar #'cdr entries))
         (hunk
           (find id (buffer-value buffer *lem-yath-jj-split-hunks-key*)
                 :key #'jj-split-hunk-id))
         (current (jj-split-hunk-selection hunk)))
    (when (or (search "--- /dev/null" (jj-split-hunk-header hunk))
              (search "+++ /dev/null" (jj-split-hunk-header hunk)))
      (editor-error
       "Select the whole hunk or file when splitting an added or deleted file"))
    (setf (jj-split-hunk-selection hunk)
          (cond
            ((eq current :all) indices)
            ((every (lambda (index) (member index current)) indices)
             (set-difference current indices))
            (t (sort (remove-duplicates (append indices current)) #'<))))
    (when (and (listp (jj-split-hunk-selection hunk))
               (null (jj-split-hunk-selection hunk)))
      (setf (jj-split-hunk-selection hunk) nil))
    (buffer-mark-cancel buffer)
    (render-jj-split-buffer buffer)
    (message "Split region selection updated")))

(define-command lem-yath-jj-split-clear () ()
  "Clear every patch selection in the current split buffer."
  (dolist (hunk (buffer-value (current-buffer)
                              *lem-yath-jj-split-hunks-key*))
    (setf (jj-split-hunk-selection hunk) nil))
  (render-jj-split-buffer (current-buffer))
  (message "Cleared split selections"))

(defun jj-split-move-hunk (direction)
  "Move to the next split hunk in DIRECTION."
  (let ((current-id
          (alexandria:when-let ((hunk (jj-split-hunk-at-point)))
            (jj-split-hunk-id hunk))))
    (with-point ((point (current-point)))
      (loop
        (unless (line-offset point direction)
          (editor-error "No more Jujutsu split hunks"))
        (let ((id (text-property-at point *lem-yath-jj-split-hunk-key*)))
          (when (and id (not (eql id current-id)))
            (move-point (current-point) point)
            (return)))))))

(define-command lem-yath-jj-split-next-hunk () ()
  (jj-split-move-hunk 1))

(define-command lem-yath-jj-split-previous-hunk () ()
  (jj-split-move-hunk -1))

(defun jj-split-partial-hunk-patch (hunk indices)
  "Build HUNK patch containing only changed lines at INDICES."
  (let* ((entries (jj-split-hunk-lines hunk))
         (parsed (git-diff-parse-hunk-header (second (first entries))))
         (old-length 0)
         (new-length 0)
         (has-change nil)
         (previous-included-p nil)
         (body '()))
    (unless parsed
      (editor-error "Unsupported Jujutsu hunk header"))
    (dolist (entry (rest entries))
      (destructuring-bind (index line) entry
        (let* ((type
                 (and (plusp (length line))
                      (case (char line 0)
                        (#\Space :context)
                        (#\+ :added)
                        (#\- :removed)
                        (#\\ :meta))))
               (selected-p (member index indices))
               (included-line nil))
          (case type
            (:context
             (incf old-length)
             (incf new-length)
             (setf included-line line
                   previous-included-p t))
            (:added
             (if selected-p
                 (progn
                   (incf new-length)
                   (setf has-change t
                         included-line line
                         previous-included-p t))
                 (setf previous-included-p nil)))
            (:removed
             (incf old-length)
             (incf new-length)
             (if selected-p
                 (progn
                   (decf new-length)
                   (setf has-change t
                         included-line line))
                 (setf included-line
                       (concatenate 'string " " (subseq line 1))))
             (setf previous-included-p t))
            (:meta
             (when previous-included-p
               (setf included-line line))))
          (when included-line (push included-line body)))))
    (when has-change
      (destructuring-bind (old-start ignored-old new-start ignored-new suffix)
          parsed
        (declare (ignore ignored-old ignored-new))
        (concatenate
         'string
         (format nil "@@ -~a +~a @@~a~%"
                 (git-diff-format-range old-start old-length)
                 (git-diff-format-range new-start new-length)
                 suffix)
         (apply #'concatenate 'string (nreverse body)))))))

(defun jj-split-hunk-patch (hunk)
  "Return HUNK's selected patch fragment, or nil."
  (let ((selection (jj-split-hunk-selection hunk)))
    (cond
      ((eq selection :all) (jj-split-hunk-body hunk))
      ((consp selection) (jj-split-partial-hunk-patch hunk selection))
      (t nil))))

(defun jj-split-selected-patch (hunks)
  "Build one Git-format patch from selected HUNKS."
  (let ((parts '())
        (previous-file nil))
    (dolist (hunk hunks)
      (alexandria:when-let ((patch (jj-split-hunk-patch hunk)))
        (unless (equal previous-file (jj-split-hunk-file hunk))
          (push (jj-split-hunk-header hunk) parts)
          (setf previous-file (jj-split-hunk-file hunk)))
        (push patch parts)))
    (when parts
      (apply #'concatenate 'string (nreverse parts)))))

(defun jj-squash-source-revision (state)
  "Return the source revset whose changes can be selected for squash STATE."
  (or (jj-squash-effective-revision state)
      (jj-squash-state-from state)
      "@"))

(defun jj-squash-diff-arguments (state)
  "Return the bounded Git-diff arguments for interactive squash STATE."
  (let ((arguments
          (list "diff" "--git" "--context" "3" "--revisions"
                (jj-squash-source-revision state))))
    (when (jj-squash-state-fileset state)
      (setf arguments
            (append arguments
                    (list "--" (jj-squash-state-fileset state)))))
    arguments))

(defun jj-squash-selection-summary (state)
  "Return a concise endpoint summary for interactive squash STATE."
  (cond
    ((jj-squash-effective-revision state)
     (format nil "revision ~a into its parent"
             (jj-squash-effective-revision state)))
    ((jj-squash-state-placement state)
     (format nil "from ~a, ~(~a~) ~a"
             (or (jj-squash-state-from state) "@")
             (jj-squash-state-placement state)
             (jj-squash-state-destination state)))
    (t
     (format nil "from ~a into ~a"
             (or (jj-squash-state-from state) "@")
             (or (jj-squash-state-into state) "@")))))

(defun render-jj-squash-buffer (buffer)
  "Render BUFFER's native partial-squash selection without changing its model."
  (let* ((hunks (buffer-value buffer *lem-yath-jj-split-hunks-key*))
         (state (buffer-value buffer *lem-yath-jj-squash-state-key*))
         (root (buffer-value buffer *lem-yath-jj-root-key*))
         (current-id
           (save-excursion
             (setf (current-buffer) buffer)
             (alexandria:when-let ((hunk (jj-split-hunk-at-point)))
               (jj-split-hunk-id hunk))))
         (previous-file nil))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (let ((point (buffer-end-point buffer)))
        (insert-string
         point
         (format nil
                 "Jujutsu squash: ~a~%Range: ~a~%Selected: ~d/~d hunks~%~%H/Space hunk, F file, R region, C clear, C-j/C-k hunks, s/RET execute, q cancel~%"
                 (namestring root)
                 (jj-squash-selection-summary state)
                 (jj-split-selected-count hunks)
                 (length hunks)))
        (dolist (hunk hunks)
          (unless (equal previous-file (jj-split-hunk-file hunk))
            (setf previous-file (jj-split-hunk-file hunk))
            (insert-string point (format nil "~%~a~%" previous-file)))
          (with-point ((start point))
            (insert-string
             point
             (format nil "[~a] Hunk ~d~%"
                     (jj-split-hunk-marker hunk)
                     (jj-split-hunk-id hunk)))
            (put-text-property start point *lem-yath-jj-split-hunk-key*
                               (jj-split-hunk-id hunk)))
          (dolist (entry (jj-split-hunk-lines hunk))
            (destructuring-bind (index line) entry
              (with-point ((start point))
                (insert-string point line)
                (put-text-property start point *lem-yath-jj-split-hunk-key*
                                   (jj-split-hunk-id hunk))
                (when (jj-split-change-line-p line)
                  (put-text-property
                   start point *lem-yath-jj-split-line-key*
                   (cons (jj-split-hunk-id hunk) index))))))))
      (buffer-unmark buffer))
    (setf (buffer-read-only-p buffer) t)
    (unless (jj-restore-split-hunk-point buffer current-id)
      (jj-restore-split-hunk-point
       buffer (jj-split-hunk-id (first hunks))))
    buffer))

(define-command lem-yath-jj-squash-toggle-hunk () ()
  "Toggle the complete squash hunk at point."
  (let ((hunk (or (jj-split-hunk-at-point)
                  (editor-error "No Jujutsu squash hunk at point"))))
    (jj-split-toggle-hunk-model hunk)
    (render-jj-squash-buffer (current-buffer))
    (message (if (jj-split-hunk-selection hunk)
                 "Selected squash hunk"
                 "Deselected squash hunk"))))

(define-command lem-yath-jj-squash-toggle-file () ()
  "Toggle every squash hunk belonging to the file at point."
  (let* ((hunk (or (jj-split-hunk-at-point)
                   (editor-error "No Jujutsu squash file at point")))
         (file (jj-split-hunk-file hunk))
         (hunks
           (remove-if-not
            (lambda (candidate)
              (equal file (jj-split-hunk-file candidate)))
            (buffer-value (current-buffer) *lem-yath-jj-split-hunks-key*)))
         (selected-p (every #'jj-split-hunk-selection hunks)))
    (dolist (candidate hunks)
      (setf (jj-split-hunk-selection candidate)
            (unless selected-p :all)))
    (render-jj-squash-buffer (current-buffer))
    (message (if selected-p
                 "Deselected squash file"
                 "Selected squash file"))))

(define-command lem-yath-jj-squash-toggle-region () ()
  "Use the active region's changed lines as a partial squash selection."
  (let* ((buffer (current-buffer))
         (entries (jj-split-region-entries buffer))
         (id (caar entries))
         (indices (mapcar #'cdr entries))
         (hunk
           (find id (buffer-value buffer *lem-yath-jj-split-hunks-key*)
                 :key #'jj-split-hunk-id))
         (current (jj-split-hunk-selection hunk)))
    (when (or (search "--- /dev/null" (jj-split-hunk-header hunk))
              (search "+++ /dev/null" (jj-split-hunk-header hunk)))
      (editor-error
       "Select the whole hunk or file when squashing an added or deleted file"))
    (setf (jj-split-hunk-selection hunk)
          (cond
            ((eq current :all) indices)
            ((every (lambda (index) (member index current)) indices)
             (set-difference current indices))
            (t (sort (remove-duplicates (append indices current)) #'<))))
    (when (and (listp (jj-split-hunk-selection hunk))
               (null (jj-split-hunk-selection hunk)))
      (setf (jj-split-hunk-selection hunk) nil))
    (buffer-mark-cancel buffer)
    (render-jj-squash-buffer buffer)
    (message "Squash region selection updated")))

(define-command lem-yath-jj-squash-clear () ()
  "Clear every patch selection in the current squash buffer."
  (dolist (hunk (buffer-value (current-buffer)
                              *lem-yath-jj-split-hunks-key*))
    (setf (jj-split-hunk-selection hunk) nil))
  (render-jj-squash-buffer (current-buffer))
  (message "Cleared squash selections"))

(define-command lem-yath-jj-squash-next-hunk () ()
  (jj-split-move-hunk 1))

(define-command lem-yath-jj-squash-previous-hunk () ()
  (jj-split-move-hunk -1))

(define-command lem-yath-jj-squash-selection-execute () ()
  "Execute the selected patch as a Jujutsu squash."
  (let* ((buffer (current-buffer))
         (root (buffer-value buffer *lem-yath-jj-root-key*))
         (state (buffer-value buffer *lem-yath-jj-squash-state-key*))
         (origin (buffer-value buffer *lem-yath-jj-squash-origin-key*))
         (revision (jj-squash-effective-revision state))
         (parent (and revision (jj-single-parent-revision root revision)))
         (patch
           (jj-split-selected-patch
            (buffer-value buffer *lem-yath-jj-split-hunks-key*))))
    (unless patch
      (editor-error "Select at least one Jujutsu squash hunk or changed region"))
    (jj-run-squash-with-patch root state patch)
    (quit-active-window)
    (when (and origin (not (deleted-buffer-p origin)))
      (render-jj-buffer origin root)
      (or (jj-restore-revision-point
           origin (jj-squash-state-initiating-revision state))
          (jj-restore-revision-point origin parent)
          (jj-restore-working-copy-point origin)))
    (message "Jujutsu partial squash completed")))

(define-command lem-yath-jj-squash-selection-cancel () ()
  "Cancel partial squash and return to the exact history row."
  (quit-active-window)
  (message "Jujutsu partial squash cancelled"))

(define-command lem-yath-jj-squash-selection-help () ()
  (message
   "JJ Squash: H/Space hunk, F file, R region, C clear, C-j/C-k hunks, s/RET execute, q cancel"))

(defun jj-squash-selection-buffer-name (root revision)
  (format nil "*lem-yath-jj-squash: ~a:~a*"
          (namestring (or (ignore-errors (truename root)) root)) revision))

(defun jj-open-squash-selection (root state)
  "Open native interactive patch selection for squash STATE at ROOT."
  (let ((diff (run-jj root (jj-squash-diff-arguments state))))
    (when (> (babel:string-size-in-octets diff :encoding :utf-8)
             *jj-split-diff-limit*)
      (editor-error "The Jujutsu squash diff exceeds the ~d-byte safety limit"
                    *jj-split-diff-limit*))
    (when (str:blankp diff)
      (editor-error "There are no Jujutsu changes to squash interactively"))
    (let ((hunks (parse-jj-split-hunks diff)))
      (unless hunks
        (editor-error "The squash source has no selectable textual hunks"))
      (let* ((origin (current-buffer))
             (revision (jj-squash-source-revision state))
             (buffer
               (make-buffer
                (jj-squash-selection-buffer-name root revision)
                :directory (namestring root))))
        (change-buffer-mode buffer 'lem/buffer/fundamental-mode:fundamental-mode)
        (save-excursion
          (setf (current-buffer) buffer)
          (enable-minor-mode 'lem-yath-jj-squash-mode))
        (setf (buffer-value buffer *lem-yath-jj-root-key*) root
              (buffer-value buffer *lem-yath-jj-view-kind-key*)
              :squash-selection
              (buffer-value buffer *lem-yath-jj-squash-state-key*) state
              (buffer-value buffer *lem-yath-jj-squash-origin-key*) origin
              (buffer-value buffer *lem-yath-jj-split-hunks-key*) hunks)
        (render-jj-squash-buffer buffer)
        (switch-to-buffer buffer)))))

(defun jj-restore-diff-arguments (state)
  "Return the Git-diff range represented by restore STATE."
  (let ((arguments (list "diff" "--git" "--context" "3")))
    (cond
      ((jj-restore-state-changes-in state)
       (setf arguments
             (append arguments
                     (list "--revisions"
                           (jj-restore-state-changes-in state)))))
      ((or (jj-restore-state-from state) (jj-restore-state-into state))
       (setf arguments
             (append arguments
                     (list "--from" (or (jj-restore-state-from state) "@")
                           "--to" (or (jj-restore-state-into state) "@")))))
      (t (setf arguments (append arguments '("--revisions" "@")))))
    (when (jj-restore-state-fileset state)
      (setf arguments
            (append arguments
                    (list "--" (jj-restore-state-fileset state)))))
    arguments))

(defun jj-restore-selection-summary (state)
  "Return a compact description of restore STATE."
  (cond
    ((jj-restore-state-changes-in state)
     (format nil "changes in ~a" (jj-restore-state-changes-in state)))
    ((or (jj-restore-state-from state) (jj-restore-state-into state))
     (format nil "from ~a into ~a"
             (or (jj-restore-state-from state) "@")
             (or (jj-restore-state-into state) "@")))
    (t "working copy from parents")))

(defun render-jj-restore-buffer (buffer)
  "Render BUFFER's native partial-restore selection."
  (let* ((hunks (buffer-value buffer *lem-yath-jj-split-hunks-key*))
         (state (buffer-value buffer *lem-yath-jj-restore-state-key*))
         (root (buffer-value buffer *lem-yath-jj-root-key*))
         (current-id
           (save-excursion
             (setf (current-buffer) buffer)
             (alexandria:when-let ((hunk (jj-split-hunk-at-point)))
               (jj-split-hunk-id hunk))))
         (previous-file nil))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (let ((point (buffer-end-point buffer)))
        (insert-string
         point
         (format nil
                 "Jujutsu restore selection: ~a~%Range: ~a~%Selected: ~d/~d hunks~%~%H/Space hunk, F file, R region, C clear, C-j/C-k hunks, r/RET execute, q cancel~%"
                 (namestring root)
                 (jj-restore-selection-summary state)
                 (jj-split-selected-count hunks)
                 (length hunks)))
        (dolist (hunk hunks)
          (unless (equal previous-file (jj-split-hunk-file hunk))
            (setf previous-file (jj-split-hunk-file hunk))
            (insert-string point (format nil "~%~a~%" previous-file)))
          (with-point ((start point))
            (insert-string
             point
             (format nil "[~a] Hunk ~d~%"
                     (jj-split-hunk-marker hunk)
                     (jj-split-hunk-id hunk)))
            (put-text-property start point *lem-yath-jj-split-hunk-key*
                               (jj-split-hunk-id hunk)))
          (dolist (entry (jj-split-hunk-lines hunk))
            (destructuring-bind (index line) entry
              (with-point ((start point))
                (insert-string point line)
                (put-text-property start point *lem-yath-jj-split-hunk-key*
                                   (jj-split-hunk-id hunk))
                (when (jj-split-change-line-p line)
                  (put-text-property
                   start point *lem-yath-jj-split-line-key*
                   (cons (jj-split-hunk-id hunk) index))))))))
      (buffer-unmark buffer))
    (setf (buffer-read-only-p buffer) t)
    (unless (jj-restore-split-hunk-point buffer current-id)
      (jj-restore-split-hunk-point
       buffer (jj-split-hunk-id (first hunks))))
    buffer))

(define-command lem-yath-jj-restore-toggle-hunk () ()
  "Toggle the complete restore hunk at point."
  (let ((hunk (or (jj-split-hunk-at-point)
                  (editor-error "No Jujutsu restore hunk at point"))))
    (jj-split-toggle-hunk-model hunk)
    (render-jj-restore-buffer (current-buffer))
    (message (if (jj-split-hunk-selection hunk)
                 "Selected restore hunk"
                 "Deselected restore hunk"))))

(define-command lem-yath-jj-restore-toggle-file () ()
  "Toggle every restore hunk belonging to the file at point."
  (let* ((hunk (or (jj-split-hunk-at-point)
                   (editor-error "No Jujutsu restore file at point")))
         (file (jj-split-hunk-file hunk))
         (hunks
           (remove-if-not
            (lambda (candidate)
              (equal file (jj-split-hunk-file candidate)))
            (buffer-value (current-buffer)
                          *lem-yath-jj-split-hunks-key*)))
         (selected-p (every #'jj-split-hunk-selection hunks)))
    (dolist (candidate hunks)
      (setf (jj-split-hunk-selection candidate)
            (unless selected-p :all)))
    (render-jj-restore-buffer (current-buffer))
    (message (if selected-p
                 "Deselected restore file"
                 "Selected restore file"))))

(define-command lem-yath-jj-restore-toggle-region () ()
  "Use the active region's changed lines as a partial restore selection."
  (let* ((buffer (current-buffer))
         (entries (jj-split-region-entries buffer))
         (id (caar entries))
         (indices (mapcar #'cdr entries))
         (hunk
           (find id (buffer-value buffer *lem-yath-jj-split-hunks-key*)
                 :key #'jj-split-hunk-id))
         (current (jj-split-hunk-selection hunk)))
    (when (or (search "--- /dev/null" (jj-split-hunk-header hunk))
              (search "+++ /dev/null" (jj-split-hunk-header hunk)))
      (editor-error
       "Select the whole hunk or file when restoring an added or deleted file"))
    (setf (jj-split-hunk-selection hunk)
          (cond
            ((eq current :all) indices)
            ((every (lambda (index) (member index current)) indices)
             (set-difference current indices))
            (t (sort (remove-duplicates (append indices current)) #'<))))
    (when (and (listp (jj-split-hunk-selection hunk))
               (null (jj-split-hunk-selection hunk)))
      (setf (jj-split-hunk-selection hunk) nil))
    (buffer-mark-cancel buffer)
    (render-jj-restore-buffer buffer)
    (message "Restore region selection updated")))

(define-command lem-yath-jj-restore-clear () ()
  "Clear every patch selection in the current restore buffer."
  (dolist (hunk (buffer-value (current-buffer)
                              *lem-yath-jj-split-hunks-key*))
    (setf (jj-split-hunk-selection hunk) nil))
  (render-jj-restore-buffer (current-buffer))
  (message "Cleared restore selections"))

(defun jj-restore-move-hunk (direction)
  "Move to the next restore hunk in DIRECTION."
  (let ((current-id
          (alexandria:when-let ((hunk (jj-split-hunk-at-point)))
            (jj-split-hunk-id hunk))))
    (with-point ((point (current-point)))
      (loop
        (unless (line-offset point direction)
          (editor-error "No more Jujutsu restore hunks"))
        (let ((id (text-property-at point *lem-yath-jj-split-hunk-key*)))
          (when (and id (not (eql id current-id)))
            (move-point (current-point) point)
            (return)))))))

(define-command lem-yath-jj-restore-next-hunk () ()
  (jj-restore-move-hunk 1))

(define-command lem-yath-jj-restore-previous-hunk () ()
  (jj-restore-move-hunk -1))

(defun jj-restore-hunk-complement-patch (hunk)
  "Return HUNK's unselected changes for a partial restore tool."
  (let ((selection (jj-split-hunk-selection hunk)))
    (cond
      ((null selection) (jj-split-hunk-body hunk))
      ((eq selection :all) nil)
      (t
       (let* ((all
                (loop :for (index line) :in (jj-split-hunk-lines hunk)
                      :when (jj-split-change-line-p line)
                        :collect index))
              (remaining (set-difference all selection)))
         (when remaining
           (jj-split-partial-hunk-patch hunk remaining)))))))

(defun jj-restore-complement-patch (hunks)
  "Build the patch that preserves every unselected change in HUNKS."
  (let ((parts '())
        (previous-file nil))
    (dolist (hunk hunks)
      (alexandria:when-let
          ((patch (jj-restore-hunk-complement-patch hunk)))
        (unless (equal previous-file (jj-split-hunk-file hunk))
          (push (jj-split-hunk-header hunk) parts)
          (setf previous-file (jj-split-hunk-file hunk)))
        (push patch parts)))
    (if parts
        (apply #'concatenate 'string (nreverse parts))
        "")))

(defun jj-restore-script-text ()
  "Return the fixed private diff-tool script used by partial restore."
  (format nil
          "set -eu~%left=$1~%right=$2~%patch=$3~%git=$4~%[ -d \"$left\" ]~%[ -d \"$right\" ]~%[ \"${left%/*}\" = \"${right%/*}\" ]~%[ \"${left##*/}\" = left ]~%[ \"${right##*/}\" = right ]~%if [ -s \"$patch\" ]; then~%  cd \"$right\"~%  \"$git\" apply --recount --unidiff-zero -- \"$patch\"~%fi~%"))

(defun jj-restore-tool-config (script patch)
  "Return temporary jj diff-tool configuration for SCRIPT and PATCH."
  (let* ((program (namestring (jj-required-executable "sh")))
         (arguments
           (mapcar #'jj-toml-string
                   (list (uiop:native-namestring script)
                         "$left" "$right"
                         (uiop:native-namestring patch)
                         (namestring (jj-required-executable "git"))))))
    (list
     "--config"
     (format nil "merge-tools.lem-yath-restore.program=~a"
             (jj-toml-string program))
     "--config"
     (format nil "merge-tools.lem-yath-restore.edit-args=[~{~a~^,~}]"
             arguments))))

(defun jj-run-restore-with-patch (root state patch)
  "Run partial restore STATE at ROOT while preserving unselected PATCH."
  (uiop:with-temporary-file
      (:pathname patch-path :stream patch-stream
       :direction :output :element-type 'character)
    (write-string patch patch-stream)
    (finish-output patch-stream)
    (close patch-stream)
    (uiop:with-temporary-file
        (:pathname script-path :stream script-stream
         :direction :output :element-type 'character)
      (write-string (jj-restore-script-text) script-stream)
      (finish-output script-stream)
      (close script-stream)
      (run-jj
       root
       (jj-restore-arguments
        state
        (append '("--interactive" "--tool" "lem-yath-restore")
                (jj-restore-tool-config script-path patch-path)))))))

(define-command lem-yath-jj-restore-selection-execute () ()
  "Restore the selected patch and preserve all unselected changes."
  (let* ((buffer (current-buffer))
         (root (buffer-value buffer *lem-yath-jj-root-key*))
         (state (buffer-value buffer *lem-yath-jj-restore-state-key*))
         (origin (buffer-value buffer *lem-yath-jj-restore-origin-key*))
         (hunks (buffer-value buffer *lem-yath-jj-split-hunks-key*)))
    (unless (some #'jj-split-hunk-selection hunks)
      (editor-error "Select at least one Jujutsu restore hunk or changed region"))
    (jj-run-restore-with-patch
     root state (jj-restore-complement-patch hunks))
    (quit-active-window)
    (when (and origin (not (deleted-buffer-p origin)))
      (render-jj-buffer origin root)
      (jj-restore-revision-point
       origin (jj-restore-state-revision state)))
    (message "Jujutsu partial restore completed")))

(define-command lem-yath-jj-restore-selection-cancel () ()
  "Cancel partial restore and return to the exact history row."
  (quit-active-window)
  (message "Jujutsu partial restore cancelled"))

(define-command lem-yath-jj-restore-selection-help () ()
  (message
   "JJ Restore: H/Space hunk, F file, R region, C clear, C-j/C-k hunks, r/RET execute, q cancel"))

(defun jj-restore-selection-buffer-name (root revision)
  (format nil "*lem-yath-jj-restore: ~a:~a*"
          (namestring (or (ignore-errors (truename root)) root)) revision))

(defun jj-open-restore-selection (root state)
  "Open native interactive patch selection for restore STATE at ROOT."
  (let ((diff (run-jj root (jj-restore-diff-arguments state))))
    (when (> (babel:string-size-in-octets diff :encoding :utf-8)
             *jj-split-diff-limit*)
      (editor-error "The Jujutsu restore diff exceeds the ~d-byte safety limit"
                    *jj-split-diff-limit*))
    (when (str:blankp diff)
      (editor-error "There are no Jujutsu changes to restore interactively"))
    (let ((hunks (parse-jj-split-hunks diff)))
      (unless hunks
        (editor-error "The restore range has no selectable textual hunks"))
      (let* ((origin (current-buffer))
             (revision (jj-restore-state-revision state))
             (buffer
               (make-buffer
                (jj-restore-selection-buffer-name root revision)
                :directory (namestring root))))
        (change-buffer-mode buffer 'lem/buffer/fundamental-mode:fundamental-mode)
        (save-excursion
          (setf (current-buffer) buffer)
          (enable-minor-mode 'lem-yath-jj-restore-mode))
        (setf (buffer-value buffer *lem-yath-jj-root-key*) root
              (buffer-value buffer *lem-yath-jj-view-kind-key*)
              :restore-selection
              (buffer-value buffer *lem-yath-jj-restore-state-key*) state
              (buffer-value buffer *lem-yath-jj-restore-origin-key*) origin
              (buffer-value buffer *lem-yath-jj-split-hunks-key*) hunks)
        (render-jj-restore-buffer buffer)
        (switch-to-buffer buffer)))))

(defun jj-toml-string (value)
  "Quote VALUE as a basic TOML string."
  (with-output-to-string (stream)
    (write-char #\" stream)
    (loop :for character :across value
          :do (case character
                (#\\ (write-string "\\\\" stream))
                (#\" (write-string "\\\"" stream))
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (otherwise (write-char character stream))))
    (write-char #\" stream)))

(defun jj-required-executable (name)
  (or (executable-find name)
      (editor-error "The ~a executable is required for partial Jujutsu editing"
                    name)))

(defun jj-split-tool-config (script patch)
  "Return temporary jj diff-tool configuration for SCRIPT and PATCH."
  (let* ((program (namestring (jj-required-executable "sh")))
         (arguments
           (mapcar #'jj-toml-string
                   (list (uiop:native-namestring script)
                         "$left" "$right"
                         (uiop:native-namestring patch)
                         (namestring (jj-required-executable "rm"))
                         (namestring (jj-required-executable "cp"))
                         (namestring (jj-required-executable "git"))))))
    (list
     "--config"
     (format nil "merge-tools.lem-yath-split.program=~a"
             (jj-toml-string program))
     "--config"
     (format nil "merge-tools.lem-yath-split.edit-args=[~{~a~^,~}]"
             arguments))))

(defun jj-split-script-text ()
  "Return the fixed private diff-tool script used by partial split."
  (format nil
          "set -eu~%left=$1~%right=$2~%patch=$3~%rm=$4~%cp=$5~%git=$6~%[ -d \"$left\" ]~%[ -d \"$right\" ]~%[ \"${left%/*}\" = \"${right%/*}\" ]~%[ \"${left##*/}\" = left ]~%[ \"${right##*/}\" = right ]~%\"$rm\" -rf -- \"$right\"~%\"$cp\" -a -- \"$left\" \"$right\"~%cd \"$right\"~%\"$git\" apply --recount --unidiff-zero -- \"$patch\"~%"))

(defun jj-squash-tool-config (script patch)
  "Return temporary jj diff-tool configuration for squash SCRIPT and PATCH."
  (let* ((program (namestring (jj-required-executable "sh")))
         (arguments
           (mapcar #'jj-toml-string
                   (list (uiop:native-namestring script)
                         "$left" "$right"
                         (uiop:native-namestring patch)
                         (namestring (jj-required-executable "rm"))
                         (namestring (jj-required-executable "cp"))
                         (namestring (jj-required-executable "git"))))))
    (list
     "--config"
     (format nil "merge-tools.lem-yath-squash.program=~a"
             (jj-toml-string program))
     "--config"
     (format nil "merge-tools.lem-yath-squash.edit-args=[~{~a~^,~}]"
             arguments))))

(defun jj-run-squash-with-patch (root state patch)
  "Run squash STATE at ROOT using the exact selected PATCH."
  (uiop:with-temporary-file
      (:pathname patch-path :stream patch-stream
       :direction :output :element-type 'character)
    (write-string patch patch-stream)
    (finish-output patch-stream)
    (close patch-stream)
    (uiop:with-temporary-file
        (:pathname script-path :stream script-stream
         :direction :output :element-type 'character)
      (write-string (jj-split-script-text) script-stream)
      (finish-output script-stream)
      (close script-stream)
      (run-jj
       root
       (jj-squash-arguments
        state
        (append '("--interactive" "--tool" "lem-yath-squash")
                (jj-squash-tool-config script-path patch-path)))))))

(defun jj-split-command-arguments (buffer revision message)
  "Return non-tool jj split arguments from BUFFER state."
  (let ((arguments
          (list "split" "--revision" revision "--message" message))
        (placement (buffer-value buffer *lem-yath-jj-split-placement-key*))
        (destination
          (buffer-value buffer *lem-yath-jj-split-destination-key*)))
    (when placement
      (setf arguments
            (append arguments
                    (list (ecase placement
                            (:destination "--destination")
                            (:after "--insert-after")
                            (:before "--insert-before"))
                          destination))))
    (when (buffer-value buffer *lem-yath-jj-split-parallel-key*)
      (setf arguments (append arguments '("--parallel"))))
    arguments))

(defun jj-run-split-with-patch (root arguments patch)
  "Run jj split ARGUMENTS at ROOT using selected PATCH."
  (uiop:with-temporary-file
      (:pathname patch-path :stream patch-stream
       :direction :output :element-type 'character)
    (write-string patch patch-stream)
    (finish-output patch-stream)
    (close patch-stream)
    (uiop:with-temporary-file
        (:pathname script-path :stream script-stream
         :direction :output :element-type 'character)
      (write-string (jj-split-script-text) script-stream)
      (finish-output script-stream)
      (close script-stream)
      (run-jj root
              (append arguments
                      '("--interactive" "--tool" "lem-yath-split")
                      (jj-split-tool-config script-path patch-path))))))

(define-command lem-yath-jj-split-execute () ()
  "Execute the selected partial patch as a Jujutsu split."
  (let* ((buffer (current-buffer))
         (root (buffer-value buffer *lem-yath-jj-root-key*))
         (revision (buffer-value buffer *lem-yath-jj-revision-key*))
         (origin (buffer-value buffer *lem-yath-jj-split-origin-key*))
         (patch
           (jj-split-selected-patch
            (buffer-value buffer *lem-yath-jj-split-hunks-key*))))
    (unless patch
      (editor-error "Select at least one Jujutsu hunk or changed region"))
    (let ((message
            (prompt-for-string
             "Selected change description (optional): "
             :history-symbol 'lem-yath-jj-split-description)))
      (jj-run-split-with-patch
       root (jj-split-command-arguments buffer revision message) patch))
    (quit-active-window)
    (when (and origin (not (deleted-buffer-p origin)))
      (render-jj-buffer origin root)
      (jj-restore-revision-point origin revision))
    (message "Jujutsu change split")))

(defun jj-split-set-placement (placement)
  "Set split PLACEMENT by prompting for a destination revset."
  (let* ((buffer (current-buffer))
         (root (buffer-value buffer *lem-yath-jj-root-key*))
         (prompt
           (ecase placement
             (:destination "Split destination revision or revset: ")
             (:after "Split insert-after revision or revset: ")
             (:before "Split insert-before revision or revset: ")))
         (destination
           (jj-prompt-for-revision
            root prompt 'lem-yath-jj-split-destination)))
    (setf (buffer-value buffer *lem-yath-jj-split-placement-key*) placement
          (buffer-value buffer *lem-yath-jj-split-destination-key*) destination)
    (render-jj-split-buffer buffer)
    (message "Jujutsu split placement updated")))

(define-command lem-yath-jj-split-onto () ()
  (jj-split-set-placement :destination))

(define-command lem-yath-jj-split-after () ()
  (jj-split-set-placement :after))

(define-command lem-yath-jj-split-before () ()
  (jj-split-set-placement :before))

(define-command lem-yath-jj-split-parent () ()
  "Reset split placement to the selected revision's existing parent."
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer *lem-yath-jj-split-placement-key*) nil
          (buffer-value buffer *lem-yath-jj-split-destination-key*) nil)
    (render-jj-split-buffer buffer)
    (message "Jujutsu split will use the existing parent")))

(define-command lem-yath-jj-split-toggle-parallel () ()
  "Toggle parallel rather than parent/child split layout."
  (let ((buffer (current-buffer)))
    (setf (buffer-value buffer *lem-yath-jj-split-parallel-key*)
          (not (buffer-value buffer *lem-yath-jj-split-parallel-key*)))
    (render-jj-split-buffer buffer)
    (message "Jujutsu split layout updated")))

(define-command lem-yath-jj-split-help () ()
  (message
   "JJ Split: H/Space hunk, F file, R region, C clear, C-j/C-k hunks, o/a/b placement, c parent, p parallel, s/RET execute, q cancel"))

(define-command lem-yath-jj-split-cancel () ()
  "Cancel partial split and return to the exact Jujutsu history."
  (quit-active-window)
  (message "Jujutsu split cancelled"))

(defun jj-split-buffer-name (root revision)
  (format nil "*lem-yath-jj-split: ~a:~a*"
          (namestring (or (ignore-errors (truename root)) root)) revision))

(define-command lem-yath-jj-split () ()
  "Open a Majutsu-style partial-patch split view for the selected change."
  (let* ((origin (current-buffer))
         (root (jj-current-root))
         (revision (jj-selected-revision))
         (diff (run-jj root
                       (list "diff" "--git" "--context" "3"
                             "--revisions" revision))))
    (when (> (babel:string-size-in-octets diff :encoding :utf-8)
             *jj-split-diff-limit*)
      (editor-error "The Jujutsu split diff exceeds the ~d-byte safety limit"
                    *jj-split-diff-limit*))
    (when (str:blankp diff)
      (editor-error "Cannot split an empty Jujutsu revision"))
    (let ((hunks (parse-jj-split-hunks diff)))
      (unless hunks
        (editor-error
         "The selected revision has no selectable textual Jujutsu hunks"))
      (let ((buffer
              (make-buffer (jj-split-buffer-name root revision)
                           :directory (namestring root))))
        (change-buffer-mode buffer 'lem/buffer/fundamental-mode:fundamental-mode)
        (save-excursion
          (setf (current-buffer) buffer)
          (enable-minor-mode 'lem-yath-jj-split-mode))
        (setf (buffer-value buffer *lem-yath-jj-root-key*) root
              (buffer-value buffer *lem-yath-jj-view-kind-key*) :split
              (buffer-value buffer *lem-yath-jj-revision-key*) revision
              (buffer-value buffer *lem-yath-jj-split-origin-key*) origin
              (buffer-value buffer *lem-yath-jj-split-hunks-key*) hunks
              (buffer-value buffer *lem-yath-jj-split-placement-key*) nil
              (buffer-value buffer *lem-yath-jj-split-destination-key*) nil
              (buffer-value buffer *lem-yath-jj-split-parallel-key*) nil)
        (render-jj-split-buffer buffer)
        (switch-to-buffer buffer)))))

(defun jj-bookmark-names (root)
  "Return the sorted local bookmark names at ROOT."
  (sort
   (remove-if #'str:blankp
              (jj-split-null-fields
               (run-jj root
                       '("bookmark" "list" "--quiet" "--template"
                         "name ++ \"\\0\""))))
   #'string<))

(defun jj-prompt-for-bookmark (root prompt &key allow-new)
  "Read a local bookmark at ROOT, permitting a new name when ALLOW-NEW."
  (let* ((names (jj-bookmark-names root))
         (choices (mapcar (lambda (name) (cons name name)) names)))
    (when (and (null names) (not allow-new))
      (editor-error "There are no local Jujutsu bookmarks"))
    (prompt-for-string
     prompt
     :completion-function
     (lambda (input)
       (completion-annotated-prompt-choices
        (prescient-filter input choices :key #'car :category :jj-bookmark)
        (lambda (name)
          (declare (ignore name))
          "local bookmark")))
     :test-function
     (lambda (input)
       (and (not (str:blankp input))
            (or allow-new (member input names :test #'string=))))
     :history-symbol 'lem-yath-jj-bookmark)))

(defun jj-refresh-after-bookmark-mutation
    (root revision arguments success-message)
  "Run bookmark ARGUMENTS, refresh, and retain selected REVISION."
  (run-jj root arguments)
  (let ((buffer (current-buffer)))
    (render-jj-buffer buffer root)
    (jj-restore-revision-point buffer revision))
  (message success-message))

(defun jj-show-bookmarks (root)
  "Open the local bookmark list for ROOT in a nested read-only view."
  (let ((buffer (make-buffer (jj-bookmark-buffer-name root) :directory root)))
    (change-buffer-mode buffer 'lem/buffer/fundamental-mode:fundamental-mode)
    (save-excursion
      (setf (current-buffer) buffer)
      (enable-minor-mode 'lem-yath-jj-view-mode))
    (render-jj-bookmark-buffer buffer root)
    (switch-to-buffer buffer)))

(defun jj-bookmark-create-or-set (root revision set-p)
  (let ((name
          (jj-prompt-for-bookmark
           root (if set-p "Set bookmark: " "Create bookmark: ")
           :allow-new t)))
    (jj-refresh-after-bookmark-mutation
     root revision
     (list "bookmark" (if set-p "set" "create") name
           "--revision" revision)
     (format nil "Jujutsu bookmark ~a ~a"
             name (if set-p "set" "created")))))

(defun jj-bookmark-move (root revision allow-backwards)
  (let ((name (jj-prompt-for-bookmark root "Move bookmark: ")))
    (jj-refresh-after-bookmark-mutation
     root revision
     (append (list "bookmark" "move" name "--to" revision)
             (when allow-backwards '("--allow-backwards")))
     (format nil "Jujutsu bookmark ~a moved" name))))

(defun jj-bookmark-rename (root revision)
  (let* ((old (jj-prompt-for-bookmark root "Rename bookmark: "))
         (new (jj-prompt-for-bookmark root "New bookmark name: "
                                      :allow-new t)))
    (jj-refresh-after-bookmark-mutation
     root revision (list "bookmark" "rename" old new)
     (format nil "Jujutsu bookmark ~a renamed to ~a" old new))))

(defun jj-bookmark-remove (root revision forget-p)
  (let ((name
          (jj-prompt-for-bookmark
           root (if forget-p "Forget bookmark: " "Delete bookmark: "))))
    (if (prompt-for-y-or-n-p
         (format nil "~a Jujutsu bookmark ~a?"
                 (if forget-p "Forget" "Delete") name))
        (jj-refresh-after-bookmark-mutation
         root revision
         (list "bookmark" (if forget-p "forget" "delete") name)
         (format nil "Jujutsu bookmark ~a ~a"
                 name (if forget-p "forgotten" "deleted")))
        (message "Jujutsu bookmark removal cancelled"))))

(defun jj-bookmark-keymap ()
  "Build the focused local-bookmark popup."
  (let ((keymap (make-keymap :description "JJ Bookmarks")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist (entry
              '(("l" "list local bookmarks")
                ("c" "create at selected revision")
                ("s" "create or set at selected revision")
                ("m" "move to selected revision")
                ("M" "move backwards/sideways to selected revision")
                ("r" "rename local bookmark")
                ("d" "delete and propagate")
                ("f" "forget locally")
                ("q" "cancel")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun dispatch-jj-bookmark (root revision)
  "Read one focused Majutsu-style local bookmark action."
  (unwind-protect
       (progn
         (let ((lem/transient:*transient-popup-delay* 0))
           (keymap-activate (jj-bookmark-keymap)))
         (redraw-display)
         (let* ((key (read-key))
                (name (lem-core::keyseq-to-string (list key))))
           (lem/transient::hide-transient)
           (cond
             ((string= name "l") (jj-show-bookmarks root))
             ((string= name "c")
              (jj-bookmark-create-or-set root revision nil))
             ((string= name "s")
              (jj-bookmark-create-or-set root revision t))
             ((string= name "m") (jj-bookmark-move root revision nil))
             ((string= name "M") (jj-bookmark-move root revision t))
             ((string= name "r") (jj-bookmark-rename root revision))
             ((string= name "d") (jj-bookmark-remove root revision nil))
             ((string= name "f") (jj-bookmark-remove root revision t))
             ((or (string= name "q") (string= name "Escape"))
              (message "Jujutsu bookmark action cancelled"))
             (t (message "No bookmark action is bound to ~a" name)))))
    (lem/transient::hide-transient)))

(define-command lem-yath-jj-bookmark () ()
  "Manage local bookmarks for the selected Jujutsu revision."
  (dispatch-jj-bookmark (jj-current-root) (jj-selected-revision)))

(defun jj-message-buffer-name (root action revision)
  "Return a repository-specific message buffer name."
  (format nil "*lem-yath-jj-~(~a~): ~a:~a*"
          action
          (namestring (or (ignore-errors (truename root)) root))
          revision))

(defun jj-open-message-editor (root action revision initial-text)
  "Edit INITIAL-TEXT for ACTION and REVISION at ROOT."
  (let* ((name (jj-message-buffer-name root action revision))
         (existing (get-buffer name)))
    (when existing
      (switch-to-buffer existing)
      (message "Resume editing; C-c C-c finishes and C-c C-k aborts")
      (return-from jj-open-message-editor existing))
    (let ((buffer (make-buffer name :directory (namestring root))))
      (with-buffer-read-only buffer nil
        (erase-buffer buffer)
        (change-buffer-mode buffer 'lem-yath-jj-message-mode)
        (insert-string (buffer-start-point buffer) initial-text)
        (setf (buffer-value buffer *lem-yath-jj-root-key*) root
              (buffer-value buffer *lem-yath-jj-revision-key*) revision
              (buffer-value buffer *lem-yath-jj-message-action-key*) action
              (buffer-value buffer *lem-yath-jj-message-origin-key*)
              (current-buffer))
        (buffer-end (buffer-point buffer)))
      (buffer-unmark buffer)
      (switch-to-buffer buffer)
      (message "Edit the message; C-c C-c finishes and C-c C-k aborts")
      buffer)))

(defun jj-close-message-editor (buffer)
  "Close BUFFER and return to its live origin, if any."
  (let ((origin (buffer-value buffer *lem-yath-jj-message-origin-key*)))
    (buffer-unmark buffer)
    (delete-buffer buffer)
    (when (and origin (not (deleted-buffer-p origin)))
      (switch-to-buffer origin)
      origin)))

(define-command lem-yath-jj-message-finish () ()
  "Apply the current Jujutsu description or commit message."
  (let* ((buffer (current-buffer))
         (root (buffer-value buffer *lem-yath-jj-root-key*))
         (revision (buffer-value buffer *lem-yath-jj-revision-key*))
         (action (buffer-value buffer *lem-yath-jj-message-action-key*))
         (text (buffer-text buffer)))
    (unless (and root revision (member action '(:describe :commit)))
      (editor-error "This is not a Jujutsu message editor"))
    (ecase action
      (:describe
       (run-jj root (list "describe" revision "--message" text)))
      (:commit
       (run-jj root (list "commit" "--message" text))))
    (alexandria:when-let ((origin (jj-close-message-editor buffer)))
      (render-jj-buffer origin root)
      (if (eq action :commit)
          (jj-restore-working-copy-point origin)
          (jj-restore-revision-point origin revision)))
    (message (if (eq action :commit)
                 "Jujutsu change committed"
                 "Jujutsu description updated"))))

(define-command lem-yath-jj-message-abort () ()
  "Discard the current Jujutsu message edit without mutation."
  (jj-close-message-editor (current-buffer))
  (message "Jujutsu message edit cancelled"))

(define-command lem-yath-jj-describe () ()
  "Edit the selected change's multiline description, like Majutsu `c'."
  (let ((root (jj-current-root))
        (revision (jj-selected-revision)))
    (jj-open-message-editor
     root :describe revision (jj-description root revision))))

(define-command lem-yath-jj-commit () ()
  "Commit the working-copy change through a multiline editor, like Majutsu `C'."
  (let ((root (jj-current-root)))
    (jj-open-message-editor root :commit "@" (jj-description root "@"))))

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

(defun jj-create-and-select-working-copy (arguments)
  "Run `jj new' with ARGUMENTS and select the resulting working copy."
  (let* ((root (jj-current-root))
         (buffer (current-buffer)))
    (run-jj root (cons "new" arguments))
    (render-jj-buffer buffer root)
    (unless (jj-restore-working-copy-point buffer)
      (editor-error "The new Jujutsu working copy is outside the visible history"))
    (message "Jujutsu change created")))

(define-command lem-yath-jj-new-dwim () ()
  "Create and edit a child of the selected row, like Majutsu `O'."
  (jj-create-and-select-working-copy (list (jj-current-log-revision))))

(define-command lem-yath-jj-new-before () ()
  "Insert and edit a change before the selected row, like Majutsu `I'."
  (jj-create-and-select-working-copy
   (list "--insert-before" (jj-current-log-revision))))

(define-command lem-yath-jj-new-after () ()
  "Insert and edit a change after the selected row, like Majutsu `A'."
  (jj-create-and-select-working-copy
   (list "--insert-after" (jj-current-log-revision))))

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

(define-command lem-yath-jj-goto-working-copy () ()
  "Jump to the current working-copy row, like Majutsu `.'."
  (unless (eq :log
              (buffer-value (current-buffer) *lem-yath-jj-view-kind-key*))
    (editor-error "This command requires the Jujutsu history"))
  (unless (jj-restore-working-copy-point (current-buffer))
    (editor-error "The working copy is outside the visible history")))

(define-command lem-yath-jj-goto-parent () ()
  "Jump to a visible parent of the selected row, like Majutsu `['."
  (jj-goto-related-revision :parent))

(define-command lem-yath-jj-goto-child () ()
  "Jump to a visible child of the selected row, like Majutsu `]'."
  (jj-goto-related-revision :child))

(define-command lem-yath-jj-help () ()
  "Show the focused Majutsu-compatible Jujutsu command surface."
  (message
   "Jujutsu: c/C describe/commit, o/O/I/A new, a absorb, ./[/] working-copy/parent/child, s/S squash/split, r rebase, _ revert, R restore, y/Y duplicate, b bookmarks, e edit, u/C-r undo/redo, x abandon, d/RET show, C-j/C-k rows, g r refresh, q quit"))

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
(define-key *lem-yath-jj-view-keymap* "C" 'lem-yath-jj-commit)
(define-key *lem-yath-jj-view-keymap* "o" 'lem-yath-jj-new)
(define-key *lem-yath-jj-view-keymap* "O" 'lem-yath-jj-new-dwim)
(define-key *lem-yath-jj-view-keymap* "I" 'lem-yath-jj-new-before)
(define-key *lem-yath-jj-view-keymap* "A" 'lem-yath-jj-new-after)
(define-key *lem-yath-jj-view-keymap* "a" 'lem-yath-jj-absorb)
(define-key *lem-yath-jj-view-keymap* "s" 'lem-yath-jj-squash)
(define-key *lem-yath-jj-view-keymap* "S" 'lem-yath-jj-split)
(define-key *lem-yath-jj-view-keymap* "r" 'lem-yath-jj-rebase)
(define-key *lem-yath-jj-view-keymap* "_" 'lem-yath-jj-revert)
(define-key *lem-yath-jj-view-keymap* "R" 'lem-yath-jj-restore)
(define-key *lem-yath-jj-view-keymap* "y" 'lem-yath-jj-duplicate)
(define-key *lem-yath-jj-view-keymap* "Y" 'lem-yath-jj-duplicate-dwim)
(define-key *lem-yath-jj-view-keymap* "b" 'lem-yath-jj-bookmark)
(define-key *lem-yath-jj-view-keymap* "e" 'lem-yath-jj-edit)
(define-key *lem-yath-jj-view-keymap* "u" 'lem-yath-jj-undo)
(define-key *lem-yath-jj-view-keymap* "C-r" 'lem-yath-jj-redo)
(define-key *lem-yath-jj-view-keymap* "x" 'lem-yath-jj-abandon)
(define-key *lem-yath-jj-view-keymap* "d" 'lem-yath-jj-show)
(define-key *lem-yath-jj-view-keymap* "Return" 'lem-yath-jj-show)
(define-key *lem-yath-jj-view-keymap* "C-j" 'lem-yath-jj-next-revision)
(define-key *lem-yath-jj-view-keymap* "C-k" 'lem-yath-jj-previous-revision)
(define-key *lem-yath-jj-view-keymap* "." 'lem-yath-jj-goto-working-copy)
(define-key *lem-yath-jj-view-keymap* "]" 'lem-yath-jj-goto-child)
(define-key *lem-yath-jj-view-keymap* "[" 'lem-yath-jj-goto-parent)
(define-key *lem-yath-jj-view-keymap* "?" 'lem-yath-jj-help)

(define-key *lem-yath-jj-squash-mode-keymap* "H"
  'lem-yath-jj-squash-toggle-hunk)
(define-key *lem-yath-jj-squash-mode-keymap* "Space"
  'lem-yath-jj-squash-toggle-hunk)
(define-key *lem-yath-jj-squash-mode-keymap* "F"
  'lem-yath-jj-squash-toggle-file)
(define-key *lem-yath-jj-squash-mode-keymap* "R"
  'lem-yath-jj-squash-toggle-region)
(define-key *lem-yath-jj-squash-mode-keymap* "C"
  'lem-yath-jj-squash-clear)
(define-key *lem-yath-jj-squash-mode-keymap* "C-j"
  'lem-yath-jj-squash-next-hunk)
(define-key *lem-yath-jj-squash-mode-keymap* "C-k"
  'lem-yath-jj-squash-previous-hunk)
(define-key *lem-yath-jj-squash-mode-keymap* "]"
  'lem-yath-jj-squash-next-hunk)
(define-key *lem-yath-jj-squash-mode-keymap* "["
  'lem-yath-jj-squash-previous-hunk)
(define-key *lem-yath-jj-squash-mode-keymap* "s"
  'lem-yath-jj-squash-selection-execute)
(define-key *lem-yath-jj-squash-mode-keymap* "Return"
  'lem-yath-jj-squash-selection-execute)
(define-key *lem-yath-jj-squash-mode-keymap* "q"
  'lem-yath-jj-squash-selection-cancel)
(define-key *lem-yath-jj-squash-mode-keymap* "?"
  'lem-yath-jj-squash-selection-help)

(define-key *lem-yath-jj-split-mode-keymap* "H"
  'lem-yath-jj-split-toggle-hunk)
(define-key *lem-yath-jj-split-mode-keymap* "Space"
  'lem-yath-jj-split-toggle-hunk)
(define-key *lem-yath-jj-split-mode-keymap* "F"
  'lem-yath-jj-split-toggle-file)
(define-key *lem-yath-jj-split-mode-keymap* "R"
  'lem-yath-jj-split-toggle-region)
(define-key *lem-yath-jj-split-mode-keymap* "C"
  'lem-yath-jj-split-clear)
(define-key *lem-yath-jj-split-mode-keymap* "C-j"
  'lem-yath-jj-split-next-hunk)
(define-key *lem-yath-jj-split-mode-keymap* "C-k"
  'lem-yath-jj-split-previous-hunk)
(define-key *lem-yath-jj-split-mode-keymap* "]"
  'lem-yath-jj-split-next-hunk)
(define-key *lem-yath-jj-split-mode-keymap* "["
  'lem-yath-jj-split-previous-hunk)
(define-key *lem-yath-jj-split-mode-keymap* "o" 'lem-yath-jj-split-onto)
(define-key *lem-yath-jj-split-mode-keymap* "a" 'lem-yath-jj-split-after)
(define-key *lem-yath-jj-split-mode-keymap* "b" 'lem-yath-jj-split-before)
(define-key *lem-yath-jj-split-mode-keymap* "c" 'lem-yath-jj-split-parent)
(define-key *lem-yath-jj-split-mode-keymap* "p"
  'lem-yath-jj-split-toggle-parallel)
(define-key *lem-yath-jj-split-mode-keymap* "s" 'lem-yath-jj-split-execute)
(define-key *lem-yath-jj-split-mode-keymap* "Return"
  'lem-yath-jj-split-execute)
(define-key *lem-yath-jj-split-mode-keymap* "q" 'lem-yath-jj-split-cancel)
(define-key *lem-yath-jj-split-mode-keymap* "?" 'lem-yath-jj-split-help)

(define-key *lem-yath-jj-restore-mode-keymap* "H"
  'lem-yath-jj-restore-toggle-hunk)
(define-key *lem-yath-jj-restore-mode-keymap* "Space"
  'lem-yath-jj-restore-toggle-hunk)
(define-key *lem-yath-jj-restore-mode-keymap* "F"
  'lem-yath-jj-restore-toggle-file)
(define-key *lem-yath-jj-restore-mode-keymap* "R"
  'lem-yath-jj-restore-toggle-region)
(define-key *lem-yath-jj-restore-mode-keymap* "C"
  'lem-yath-jj-restore-clear)
(define-key *lem-yath-jj-restore-mode-keymap* "C-j"
  'lem-yath-jj-restore-next-hunk)
(define-key *lem-yath-jj-restore-mode-keymap* "C-k"
  'lem-yath-jj-restore-previous-hunk)
(define-key *lem-yath-jj-restore-mode-keymap* "r"
  'lem-yath-jj-restore-selection-execute)
(define-key *lem-yath-jj-restore-mode-keymap* "Return"
  'lem-yath-jj-restore-selection-execute)
(define-key *lem-yath-jj-restore-mode-keymap* "q"
  'lem-yath-jj-restore-selection-cancel)
(define-key *lem-yath-jj-restore-mode-keymap* "?"
  'lem-yath-jj-restore-selection-help)

(define-key *lem-yath-jj-message-mode-keymap* "C-c C-c"
  'lem-yath-jj-message-finish)
(define-key *lem-yath-jj-message-mode-keymap* "C-c C-k"
  'lem-yath-jj-message-abort)

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
