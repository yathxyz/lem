(in-package :lem-yath)

(defvar *vcs-test-report* (uiop:getenv "LEM_YATH_VCS_REPORT"))
(defvar *vcs-test-phase* (or (uiop:getenv "LEM_YATH_VCS_PHASE") "unknown"))
(defvar *vcs-test-colocated-root* (uiop:getenv "LEM_YATH_VCS_COLOCATED_ROOT"))
(defvar *vcs-test-git-root* (uiop:getenv "LEM_YATH_VCS_GIT_ROOT"))
(defvar *vcs-test-code-file* (uiop:getenv "LEM_YATH_VCS_CODE_FILE"))
(defvar *vcs-test-markdown-file* (uiop:getenv "LEM_YATH_VCS_MARKDOWN_FILE"))
(defvar *vcs-test-untracked-file*
  (uiop:getenv "LEM_YATH_VCS_UNTRACKED_FILE"))
(defvar *vcs-test-old-hash* (uiop:getenv "LEM_YATH_VCS_OLD_HASH"))
(defvar *vcs-test-sentinel-directory*
  (alexandria:when-let ((directory
                         (uiop:getenv "LEM_YATH_VCS_SENTINEL_DIRECTORY")))
    (namestring (uiop:ensure-directory-pathname directory))))
(defvar *vcs-test-source-buffer* (current-buffer))
(defvar *vcs-test-source-window* (current-window))
(when (string= *vcs-test-phase* "git")
  ;; A nontrivial source location makes q-restoration meaningful.  The older
  ;; revision has an extra line above this anchor, so revision navigation also
  ;; cannot preserve it accidentally by retaining an absolute character index.
  (buffer-start (current-point))
  (line-offset (current-point) 6)
  (character-offset (current-point) 8))
(defvar *vcs-test-source-text* (buffer-text (current-buffer)))
(defvar *vcs-test-source-point* (position-at-point (current-point)))
(defvar *vcs-test-source-mode* (buffer-major-mode (current-buffer)))
(defvar *vcs-test-source-modified* (buffer-modified-p (current-buffer)))
(defvar *vcs-test-source-filename* (buffer-filename (current-buffer)))
(defvar *vcs-test-other-buffer* nil)
(defvar *vcs-test-source-raw-directory* *vcs-test-sentinel-directory*)
(defvar *vcs-test-gutter-baseline* nil)
(defparameter *vcs-test-gutter-debounce-line* 4)

;; Use a valid, deliberately distinctive nested directory object.  VCS
;; commands derive their roots from the visited filename, while this raw value
;; proves that temporary Legit rebinding restores the exact object it found.
(when *vcs-test-source-raw-directory*
  (setf (lem/buffer/internal::buffer-%directory *vcs-test-source-buffer*)
        *vcs-test-source-raw-directory*))

(defun vcs-test-log (control &rest arguments)
  (with-open-file (stream *vcs-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun vcs-test-yes-no (value)
  (if value "yes" "no"))

(defun vcs-test-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across (or string "")
          :do (case character
                (#\\ (write-string "\\\\" stream))
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (#\Space (write-char #\_ stream))
                (otherwise (write-char character stream))))))

(defun vcs-test-key-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find keymap
                                      (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun vcs-test-command-version-p (name)
  (alexandria:when-let ((program (executable-find name)))
    (handler-case
        (multiple-value-bind (output error-output code)
            (uiop:run-program (list (namestring program) "--version")
                              :output :string
                              :error-output :string
                              :ignore-error-status t)
          (declare (ignore error-output))
          (and (eql code 0)
               (plusp (length output))))
      (error () nil))))

(defun vcs-test-store-program-p (name)
  (alexandria:when-let ((program (executable-find name)))
    (not (null (search "/nix/store/" (namestring program))))))

(define-command lem-yath-test-vcs-static () ()
  (let ((failures 0))
    (uiop:with-current-directory ((buffer-directory *vcs-test-source-buffer*))
      (flet ((check (condition label)
               (vcs-test-log "~a STATIC ~a"
                             (if condition "PASS" "FAIL") label)
               (unless condition (incf failures))))
      (check (vcs-test-command-version-p "git") "wrapper-git-runs")
      (check (vcs-test-command-version-p "jj") "wrapper-jj-runs")
      (check (vcs-test-store-program-p "git") "wrapper-git-is-pinned")
      (check (vcs-test-store-program-p "jj") "wrapper-jj-is-pinned")
      (dolist (keymap (list lem-vi-mode:*normal-keymap*
                            lem-vi-mode:*visual-keymap*))
        (check (eq 'lem-yath-vcs-status
                   (leader-binding-command keymap "g g"))
               "SPC-g-g-smart")
        (check (eq 'lem-yath-legit-status
                   (leader-binding-command keymap "g G"))
               "SPC-g-G-git")
        (check (eq 'lem-yath-git-blame
                   (leader-binding-command keymap "g B"))
               "SPC-g-B-blame")
        (check (eq 'lem-yath-jj-log
                   (leader-binding-command keymap "g J"))
               "SPC-g-J-jj")
        (check (eq 'lem-yath-git-timemachine
                   (leader-binding-command keymap "g t"))
               "SPC-g-t-timemachine"))
      ;; evil-collection does not shadow ordinary p/n/t in this view.  Its
      ;; history controls are C-k/C-j and the g-t subtree.
      (dolist (binding '(("C-k" lem-yath-timemachine-older)
                         ("C-j" lem-yath-timemachine-newer)
                         ("q" lem-yath-timemachine-quit)))
        (check (eq (second binding)
                   (vcs-test-key-command *lem-yath-timemachine-keymap*
                                         (first binding)))
               (format nil "timemachine-~a" (first binding))))
      (dolist (key '("p" "n" "t"))
        (check (null (vcs-test-key-command *lem-yath-timemachine-keymap* key))
               (format nil "timemachine-does-not-shadow-~a" key)))
      (check (vcs-test-key-command *lem-yath-timemachine-keymap* "g t g")
             "timemachine-gtg-nth")
      (check (vcs-test-key-command *lem-yath-timemachine-keymap* "g t t")
             "timemachine-gtt-fuzzy")
      (check (eq 'lem-yath-timemachine-copy-abbreviated-revision
                 (vcs-test-key-command *lem-yath-timemachine-keymap*
                                       "g t y"))
             "timemachine-gty-copy-short")
      (check (eq 'lem-yath-timemachine-copy-revision
                 (vcs-test-key-command *lem-yath-timemachine-keymap*
                                       "g t Y"))
             "timemachine-gtY-copy-full")
      (check (eq 'lem-yath-timemachine-blame
                 (vcs-test-key-command *lem-yath-timemachine-keymap*
                                       "g t b"))
             "timemachine-gtb-blame")
      (check (eq 'lem-yath-timemachine-blame-quit
                 (vcs-test-key-command
                  *lem-yath-timemachine-blame-keymap* "q"))
             "timemachine-blame-q")
      (dolist (keymap (list *global-keymap*
                            lem-vi-mode:*normal-keymap*
                            lem-vi-mode:*visual-keymap*
                            lem-vi-mode:*insert-keymap*))
        (check (eq 'lem-yath-git-blame
                   (vcs-test-key-command keymap "C-c M-g b"))
               "magit-file-dispatch-blame"))
      (check (eq 'lem-yath-git-blame
                 (vcs-test-key-command
                  (mode-keymap (buffer-major-mode *vcs-test-source-buffer*))
                  "C-c M-g b"))
             "magit-file-dispatch-major-mode")
      (dolist (binding '(("g j" lem-yath-git-blame-next-chunk)
                         ("g k" lem-yath-git-blame-previous-chunk)
                         ("g J" lem-yath-git-blame-next-chunk-same-commit)
                         ("g K" lem-yath-git-blame-previous-chunk-same-commit)
                         ("C-j" lem-yath-git-blame-next-chunk)
                         ("C-k" lem-yath-git-blame-previous-chunk)
                         ("Return" lem-yath-git-blame-show-commit)
                         ("M-w" lem-yath-git-blame-copy-hash)
                         ("q" lem-yath-git-blame-quit)))
        (check (eq (second binding)
                   (vcs-test-key-command *git-blame-mode-keymap*
                                         (first binding)))
               (format nil "magit-blame-~a" (first binding))))
      (dolist (key '("j" "k"))
        (check (null (vcs-test-key-command *git-blame-mode-keymap* key))
               (format nil "magit-blame-does-not-shadow-~a" key)))
      (check (eq 'lem-yath-git-blame-commit-quit
                 (vcs-test-key-command *git-blame-commit-mode-keymap* "q"))
             "magit-blame-commit-q")
      (check (eq 'lem-yath-legit-bisect-or-todo-base
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "B"))
             "magit-bisect-status-dispatch")
      (dolist (binding '(("Tab" lem-yath-legit-toggle-todo-section)
                         ("g" lem-yath-legit-refresh-or-todo-list)
                         ("q" lem-yath-legit-quit-or-todo-status)
                         ("n" lem-yath-legit-next-visible-item)
                         ("C-p" lem-yath-legit-previous-visible-item)
                         ("M-n" lem-yath-legit-next-visible-header)
                         ("M-p" lem-yath-legit-previous-visible-header)))
        (check (eq (second binding)
                   (vcs-test-key-command lem/legit::*peek-legit-keymap*
                                         (first binding)))
               (format nil "magit-todos-~a" (first binding))))
      (check (and (= 10 (legit-todo-section-threshold 0))
                  (= 5 (legit-todo-section-threshold 1))
                  (= 1 (legit-todo-section-threshold 3)))
             "magit-todos-collapse-thresholds")
      (let* ((patch (format nil
                            (concatenate
                             'string
                             "diff --git a/path.lisp b/path.lisp~%"
                             "--- a/path.lisp~%+++ b/path.lisp~%"
                             "@@ -7,2 +7,3 @@~%"
                             "-TODO: deleted~%+ordinary~%"
                             "+TODO(owner): added~%"
                             "+TODO missing colon~%")))
             (items (parse-legit-todo-diff patch)))
        (check (and (= 1 (length items))
                    (string= "path.lisp" (legit-todo-path (first items)))
                    (= 8 (legit-todo-line (first items)))
                    (string= "TODO" (legit-todo-keyword (first items))))
               "magit-todos-added-line-parser"))
      (check (eq 'lem-yath-legit-bisect
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "B"))
             "magit-bisect-diff-dispatch")
      (let ((options (make-legit-bisect-options)))
        (dolist (key '("- n" "- p" "= o" "= n" "B" "s" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-bisect-popup-keymap options nil) key))
                 (format nil "magit-bisect-initial-~a" key)))
        (dolist (key '("B" "g" "m" "k" "r" "s" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                     (legit-bisect-popup-keymap options t) key))
                 (format nil "magit-bisect-active-~a" key))))
      (check (eq 'lem-yath-legit-fetch
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "f"))
             "magit-fetch-status-dispatch")
      (check (eq 'lem-yath-legit-fetch
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "f"))
             "magit-fetch-diff-dispatch")
      (let ((options (make-legit-fetch-options)))
        (dolist (key '("- p" "- t" "- u" "- F"
                       "p" "u" "e" "a" "o" "r" "m" "C" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-fetch-popup-keymap options) key))
                 (format nil "magit-fetch-~a" key))))
      (check (eq 'lem-yath-legit-pull
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "F"))
             "magit-pull-status-dispatch")
      (check (eq 'lem-yath-legit-pull
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "F"))
             "magit-pull-diff-dispatch")
      (let ((options (make-legit-pull-options)))
        (dolist (key '("- f" "- r" "- F" "p" "u" "e" "r" "C" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-pull-popup-keymap options) key))
                 (format nil "magit-pull-~a" key)))
        (check
         (and
          (equal '("--ff-only" "--force")
                 (legit-pull-option-arguments
                  (make-legit-pull-options :ff-only-p t :force-p t)))
          (equal '("--rebase" "--force")
                 (legit-pull-option-arguments
                  (make-legit-pull-options :rebase-p t :force-p t)))
          (handler-case
              (progn
                (legit-pull-option-arguments
                 (make-legit-pull-options :ff-only-p t :rebase-p t))
                nil)
            (error () t)))
         "magit-pull-option-vectors"))
      (dolist (keymap (list lem/legit::*peek-legit-keymap*
                            lem/legit::*legit-diff-mode-keymap*
                            lem/legit::*legit-commits-log-keymap*))
        (check (eq 'lem-yath-legit-log
                   (vcs-test-key-command keymap "l"))
               "magit-log-dispatch"))
      (let ((options (make-legit-log-options)))
        (check (and (= 256 (legit-log-options-limit options))
                    (legit-log-options-decorate-p options))
               "magit-log-status-defaults")
        (dolist (key '("- n" "- A" "- F" "- G" "- S" "- L" "- D"
                       "- -" "- f" "- o" "- r" "- g" "- c" "- d"
                       "= S" "- h" "- p" "- s" "l" "o" "h" "u"
                       "L" "b" "a" "r" "O" "H" "s" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-log-popup-keymap options) key))
                 (format nil "magit-log-~a" key))))
      (let ((options (make-legit-shortlog-options)))
        (dolist (key '("- n" "- s" "- e" "- g" "s" "r" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-shortlog-popup-keymap options) key))
                 (format nil "magit-shortlog-~a" key))))
      (dolist (binding '(("g f" lem-yath-legit-log-next-page)
                         ("g b" lem-yath-legit-log-previous-page)
                         ("g F" lem-yath-legit-log-last-page)
                         ("g B" lem-yath-legit-log-first-page)
                         ("g r" lem-yath-legit-log-refresh)
                         ("=" lem-yath-legit-log-toggle-limit)
                         ("q" lem-yath-legit-log-back-to-status)))
        (check (eq (second binding)
                   (vcs-test-key-command
                    lem/legit::*legit-commits-log-keymap* (first binding)))
               (format nil "magit-log-view-~a" (first binding))))
      (dolist (binding *legit-log-action-bindings*)
        (check (eq (cdr binding)
                   (vcs-test-key-command
                    lem/legit::*legit-commits-log-keymap* (car binding)))
               (format nil "magit-log-action-~a" (car binding))))
      (check (eq *legit-log-commit-dispatch-keymap*
                 (vcs-test-key-command
                  lem/legit::*legit-commits-log-keymap* "c"))
             "magit-log-action-c")
      (dolist (binding '(("c" lem-yath-legit-log-commit)
                         ("a" lem-yath-legit-log-amend)))
        (check (eq (second binding)
                   (vcs-test-key-command
                    *legit-log-commit-dispatch-keymap* (first binding)))
               (format nil "magit-log-commit-~a" (first binding))))
      (dolist (binding '(("C-c C-c" lem-yath-legit-log-message-continue)
                         ("C-Return" lem-yath-legit-log-message-continue)
                         ("C-c C-k" lem-yath-legit-log-message-abort)
                         ("M-q" lem-yath-legit-log-message-abort)))
        (check (eq (second binding)
                   (vcs-test-key-command
                    lem/legit::*legit-commit-mode-keymap* (first binding)))
               (format nil "magit-log-message-~a" (first binding))))
      (check
       (and
        (equal '("--author=A U Thor" "--grep=message;safe"
                 "-Gchange.*safe" "-Sneedle;safe" "-L1,2:file name;safe"
                 "--simplify-by-decoration" "--follow" "--topo-order"
                 "--graph" "--patch" "--stat")
               (legit-log-option-arguments
                (make-legit-log-options
                 :author "A U Thor" :grep "message;safe"
                 :pickaxe-regexp "change.*safe"
                 :pickaxe-string "needle;safe"
                 :trace "1,2:file name;safe" :simplify-decoration-p t
                 :follow-p t :order :topo :graph-p t :patch-p t :stat-p t)))
        (equal '("--reverse")
               (legit-log-option-arguments
                (make-legit-log-options :reverse-p t :graph-p t)))
        (search "%x00LEM-YATH-LOG%x00" (legit-log-format-argument))
        (not (find (code-char 0) (legit-log-format-argument)))
        (handler-case
            (progn
              (legit-log-validate-options
               (make-legit-log-options :follow-p t) '("HEAD"))
              nil)
          (error () t))
        (handler-case
            (progn
              (legit-log-validate-options
               (make-legit-log-options :trace "1,2:file")
               '("HEAD" "HEAD~1"))
              nil)
          (error () t))
        (handler-case
            (progn
              (legit-log-validate-options
               (make-legit-log-options :trace "1,2:file"
                                       :files '("file"))
               '("HEAD"))
              nil)
          (error () t)))
       "magit-log-option-vectors")
      (check
       (and (legit-log-safe-relative-path-p "path with space;safe")
            (not (legit-log-safe-relative-path-p "../escape"))
            (not (legit-log-safe-relative-path-p "/absolute"))
            (not (legit-log-safe-relative-path-p
                  (concatenate 'string "unsafe" (string (code-char 0))))))
       "magit-log-path-boundaries")
      (check (eq 'lem-yath-legit-reset
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "O"))
             "magit-reset-status-dispatch")
      (check (eq 'lem-yath-legit-reset
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "O"))
             "magit-reset-diff-dispatch")
      (check (and (not (eq 'lem-yath-legit-reset
                           (vcs-test-key-command
                            lem/legit::*peek-legit-keymap* "X")))
                  (not (eq 'lem-yath-legit-reset
                           (vcs-test-key-command
                            lem/legit::*legit-diff-mode-keymap* "X"))))
             "magit-reset-old-dispatch-cleared")
      (dolist (key '("b" "f" "m" "s" "h" "k" "i" "w" "q"))
        (check (eq 'nop-command
                   (vcs-test-key-command *legit-reset-dispatch-keymap* key))
               (format nil "magit-reset-~a" key)))
      (check (eq 'lem-yath-legit-merge
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "m"))
             "magit-merge-status-dispatch")
      (check (eq 'lem-yath-legit-merge
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "m"))
             "magit-merge-diff-dispatch")
      (let ((options (make-legit-merge-options)))
        (dolist (key '("- f" "- n" "- s" "- X" "- b" "- w" "- A"
                       "- S" "+ s" "m" "e" "n" "a" "p" "s" "d" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-merge-popup-keymap options nil) key))
                 (format nil "magit-merge-initial-~a" key)))
        (dolist (key '("m" "a" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-merge-popup-keymap options t) key))
                 (format nil "magit-merge-active-~a" key))))
      (check (eq 'lem-yath-legit-revert
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "_"))
             "magit-revert-status-dispatch")
      (check (eq 'lem-yath-legit-revert
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "_"))
             "magit-revert-diff-dispatch")
      (check (eq 'lem-yath-legit-revert-no-commit
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "-"))
             "magit-revert-no-commit-status")
      (check (eq 'lem-yath-legit-revert-no-commit
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "-"))
             "magit-revert-no-commit-diff")
      (let ((options (make-legit-revert-options)))
        (dolist (key '("- m" "- e" "- E" "= s" "- S" "+ s"
                       "_" "v" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-revert-popup-keymap options nil) key))
                 (format nil "magit-revert-initial-~a" key)))
        (dolist (key '("_" "s" "a" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                     (legit-revert-popup-keymap options t) key))
                 (format nil "magit-revert-active-~a" key))))
      (check (eq 'lem-yath-legit-branch-or-todo-toggle
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "b"))
             "magit-branch-status-dispatch")
      (check (eq 'lem-yath-legit-branch
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "b"))
             "magit-branch-diff-dispatch")
      (let ((options (make-legit-branch-options)))
        (dolist (key '("d" "u" "r" "p" "R" "P" "B" "- r" "b" "l"
                       "o" "c" "s" "n" "S" "C" "m" "h" "H" "X"
                       "x" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-branch-popup-keymap options "main") key))
                 (format nil "magit-branch-initial-~a" key)))
        (dolist (key '("d" "u" "r" "p" "R" "P" "B" "a m" "a r"
                       "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-branch-config-popup-keymap "main") key))
                 (format nil "magit-branch-config-~a" key))))
      (check (and (legit-branch-date-prefix-p "2026-07-20-topic/path")
                  (not (legit-branch-date-prefix-p "2026-7-20-topic"))
                  (string= "topic/path"
                           (legit-branch-unshelved-name
                            "2026-07-20-topic/path")))
             "magit-branch-shelved-date-prefix")
      (check (and
              (equal '(("topic" . "origin/topic"))
                     (legit-branch-delete-aliases
                      '("main" "origin/topic") '("origin/topic")))
              (null (legit-branch-delete-aliases
                     '("topic" "origin/topic") '("origin/topic")))
              (null (legit-branch-delete-aliases
                     '("origin/topic" "upstream/topic")
                     '("origin/topic" "upstream/topic"))))
             "magit-branch-delete-safe-aliases")
      (check (eq 'lem-yath-legit-worktree
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "Z"))
             "magit-worktree-status-dispatch")
      (check (eq 'lem-yath-legit-worktree
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "Z"))
             "magit-worktree-diff-dispatch")
      (dolist (key '("b" "c" "m" "k" "g" "q"))
        (check (eq 'nop-command
                   (vcs-test-key-command
                    (legit-worktree-popup-keymap) key))
               (format nil "magit-worktree-~a" key)))
      (let* ((nul (string (code-char 0)))
             (fields
               (legit-worktree-split-nul
                (concatenate
                 'string
                 "worktree /tmp/path with ; marker" nul
                 "HEAD abc" nul
                 "branch refs/heads/topic/path" nul
                 "locked test reason" nul
                 "prunable missing directory" nul nul)))
             (record (legit-worktree-parse-record (subseq fields 0 5))))
        (check (equal fields
                      '("worktree /tmp/path with ; marker"
                        "HEAD abc"
                        "branch refs/heads/topic/path"
                        "locked test reason"
                        "prunable missing directory"
                        "" ""))
               "magit-worktree-nul-record-boundaries")
        (check (and (string= "/tmp/path with ; marker"
                             (legit-worktree-path record))
                    (string= "abc" (legit-worktree-head record))
                    (string= "topic/path" (legit-worktree-branch record))
                    (legit-worktree-locked-p record)
                    (legit-worktree-prunable-p record))
               "magit-worktree-porcelain-fields"))
      (check (string= "/tmp/worktree path;safe"
                      (legit-worktree-normalize-path
                       ".//tmp/worktree path;safe"))
             "magit-worktree-rooted-directory-prompt")
      (check (eq 'lem-yath-legit-push
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "p"))
             "magit-push-status-dispatch")
      (check (eq 'lem-yath-legit-push
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "p"))
             "magit-push-diff-dispatch")
      (let ((options (make-legit-push-options)))
        (dolist (key '("- f" "- F" "- h" "- n" "- u" "- T" "- t"
                       "p" "u" "e" "o" "r" "m" "T" "t" "n" "C" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-push-popup-keymap options) key))
                 (format nil "magit-push-~a" key))))
      (check (eq 'lem-yath-legit-stash
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "z"))
             "magit-stash-status-dispatch")
      (check (eq 'lem-yath-legit-stash
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "z"))
             "magit-stash-diff-dispatch")
      (let ((options (make-legit-stash-options)))
        (dolist (key '("- u" "- a" "z" "i" "w" "x" "Z" "I" "W" "r"
                       "a" "p" "k" "l" "v" "b" "B" "f" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-stash-popup-keymap options) key))
                 (format nil "magit-stash-~a" key))))
      (check (eq 'lem-yath-legit-remote
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "M"))
             "magit-remote-status-dispatch")
      (check (eq 'lem-yath-legit-remote
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "M"))
             "magit-remote-diff-dispatch")
      (let ((options (make-legit-remote-options :fetch-p t)))
        (dolist (key '("u" "U" "s" "S" "O" "h" "- f" "a" "r" "k"
                       "C" "p" "P" "d u" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-remote-popup-keymap options "origin") key))
                 (format nil "magit-remote-~a" key))))
      (check (and (legit-remote-name-valid-p "remote/path;safe")
                  (not (legit-remote-name-valid-p "-unsafe"))
                  (not (legit-remote-name-valid-p "bad name")))
             "magit-remote-name-boundary")
      (check (eq 'lem-yath-legit-submodule
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "'"))
             "magit-submodule-status-dispatch")
      (check (eq 'lem-yath-legit-submodule
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "'"))
             "magit-submodule-diff-dispatch")
      (let ((options (make-legit-submodule-options)))
        (dolist (key '("- f" "- r" "- N" "- C" "- R" "- M" "- U"
                       "a" "r" "p" "u" "s" "d" "k" "l" "f" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-submodule-popup-keymap options) key))
                 (format nil "magit-submodule-~a" key))))
      (check (and
              (legit-submodule-path-valid-p "modules/module path;safe")
              (legit-submodule-path-valid-p
               (make-string 4096 :initial-element #\m))
              (not (legit-submodule-path-valid-p "../escape"))
              (not (legit-submodule-path-valid-p "modules/.git/data"))
              (not (legit-submodule-path-valid-p "/absolute"))
              (not (legit-submodule-path-valid-p
                    (make-string 4097 :initial-element #\m)))
              (not (legit-submodule-path-valid-p
                    (concatenate 'string "unsafe"
                                 (string (code-char 0))))))
             "magit-submodule-path-boundary")
      (let ((options (make-legit-submodule-options
                      :force-p t :recursive-p t :no-fetch-p t
                      :strategy :rebase :remote-p t)))
        (check (equal '("--force" "--recursive" "--no-fetch"
                        "--rebase" "--remote")
                      (legit-submodule-update-arguments options))
               "magit-submodule-update-arguments"))
      (check (eq 'lem-yath-legit-subtree
                 (vcs-test-key-command lem/legit::*peek-legit-keymap* "\""))
             "magit-subtree-status-dispatch")
      (check (eq 'lem-yath-legit-subtree
                 (vcs-test-key-command
                  lem/legit::*legit-diff-mode-keymap* "\""))
             "magit-subtree-diff-dispatch")
      (dolist (key '("i" "e" "q"))
        (check (eq 'nop-command
                   (vcs-test-key-command
                    (legit-subtree-top-popup-keymap) key))
               (format nil "magit-subtree-top-~a" key)))
      (let ((options (make-legit-subtree-import-options)))
        (dolist (key '("- P" "- m" "- s" "a" "c" "m" "f" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-subtree-import-popup-keymap options) key))
                 (format nil "magit-subtree-import-~a" key))))
      (let ((options (make-legit-subtree-export-options)))
        (dolist (key '("- P" "- a" "- b" "- o" "- i" "- j"
                       "p" "s" "q"))
          (check (eq 'nop-command
                     (vcs-test-key-command
                      (legit-subtree-export-popup-keymap options) key))
                 (format nil "magit-subtree-export-~a" key))))
      (check (and
              (legit-subtree-prefix-valid-p "vendor/module path;safe")
              (legit-subtree-prefix-valid-p
               (make-string 4096 :initial-element #\m))
              (not (legit-subtree-prefix-valid-p "../escape"))
              (not (legit-subtree-prefix-valid-p "vendor/.git/data"))
              (not (legit-subtree-prefix-valid-p "/absolute"))
              (not (legit-subtree-prefix-valid-p
                    (make-string 4097 :initial-element #\m)))
              (not (legit-subtree-prefix-valid-p
                    (concatenate 'string "unsafe"
                                 (string (code-char 0))))))
             "magit-subtree-prefix-boundary")
      (check
       (equal '("--message=Import message; safe" "--squash")
              (legit-subtree-import-arguments
               (make-legit-subtree-import-options
                :message "Import message; safe" :squash-p t)))
       "magit-subtree-import-arguments")
      (check
       (equal '("--annotate=[subtree] " "--branch=export/topic"
                "--onto=0123456789abcdef" "--ignore-joins" "--rejoin")
              (legit-subtree-export-arguments
               (make-legit-subtree-export-options
                :annotate "[subtree] " :branch "export/topic"
                :onto "0123456789abcdef" :ignore-joins-p t :rejoin-p t)))
       "magit-subtree-export-arguments")
      (let ((nul (string (code-char 0))))
        (check (equal '("tracked path" "ignored;path")
                      (legit-stash-split-nul
                       (concatenate 'string
                                    "tracked path" nul
                                    "ignored;path" nul)))
               "magit-stash-nul-path-boundaries"))
      (check (and (legit-stash-message-valid-p "")
                  (legit-stash-message-valid-p
                   (make-string 4096 :initial-element #\m))
                  (not (legit-stash-message-valid-p
                        (make-string 4097 :initial-element #\m)))
                  (not (legit-stash-message-valid-p
                        (concatenate 'string "unsafe"
                                     (string (code-char 0))))))
             "magit-stash-message-boundary")
      (check (typep (vcs-test-key-command *lem-yath-jj-view-keymap* "g")
                    'lem-core::keymap)
             "jj-g-is-prefix")
      (check (eq 'lem-yath-jj-refresh
                 (vcs-test-key-command *lem-yath-jj-view-keymap* "g r"))
             "jj-gr-refresh")
      (check (eq 'lem-yath-jj-quit
                 (vcs-test-key-command *lem-yath-jj-view-keymap* "q"))
             "jj-q-quit")
      (check (lem-yath-git-gutter-mode-active-p (current-buffer))
             "local-git-gutter-active")
      (check (not (member 'lem-git-gutter::git-gutter-mode
                          (lem-core::active-global-minor-modes)))
             "upstream-global-gutter-disabled")
      (vcs-test-log
       "EXECUTABLES git=~a jj=~a git-store=~a jj-store=~a"
       (vcs-test-yes-no (vcs-test-command-version-p "git"))
       (vcs-test-yes-no (vcs-test-command-version-p "jj"))
       (vcs-test-yes-no (vcs-test-store-program-p "git"))
       (vcs-test-yes-no (vcs-test-store-program-p "jj")))
      (vcs-test-log "SUMMARY STATIC ~a failures=~d"
                    (if (zerop failures) "PASS" "FAIL") failures)))))

(defun vcs-test-gutter-content (buffer line-number)
  (when (lem-yath-git-gutter-mode-active-p buffer)
    (with-point ((point (buffer-start-point buffer)))
      (when (> line-number 1)
        (line-offset point (1- line-number)))
      (alexandria:when-let
          ((content
             (compute-left-display-area-content
              (ensure-mode-object 'lem-yath-git-gutter-mode)
              buffer point)))
        (lem/buffer/line:content-string content)))))

(defun vcs-test-composed-gutter-content (buffer line-number)
  (with-point ((point (buffer-start-point buffer)))
    (when (> line-number 1)
      (line-offset point (1- line-number)))
    (alexandria:when-let
        ((content
           (compute-left-display-area-content
            (lem-core::get-active-modes-class-instance buffer)
            buffer point)))
      (lem/buffer/line:content-string content))))

(defun vcs-test-gutter-entries (buffer)
  (let ((changes (lem-git-gutter::buffer-git-gutter-changes buffer))
        (entries '()))
    (when changes
      (maphash (lambda (line type)
                 (push (list line type
                             (vcs-test-gutter-content buffer line))
                       entries))
               changes))
    (sort entries #'< :key #'first)))

(defun vcs-test-gutter-summary (entries)
  (with-output-to-string (stream)
    (loop :for (line type content) :in entries
          :for first := t :then nil
          :unless first :do (write-char #\, stream)
          :do (format stream "~d:~(~a~):~a"
                      line type (vcs-test-encode content)))))

(defun vcs-test-entry-p (entries type marker)
  (find-if (lambda (entry)
             (and (eq type (second entry))
                  (string= marker (or (third entry) ""))))
           entries))

(defun vcs-test-entry-at-line (entries line)
  (find line entries :key #'first))

(defun vcs-test-source-raw-exact-p ()
  (eq (lem/buffer/internal::buffer-%directory *vcs-test-source-buffer*)
      *vcs-test-source-raw-directory*))

(defun vcs-test-source-raw-sentinel-p ()
  (equal (lem/buffer/internal::buffer-%directory *vcs-test-source-buffer*)
         *vcs-test-sentinel-directory*))

(defun vcs-test-gutter-operation (label buffer function)
  "Run FUNCTION and attach buffer-path context to any fixture failure."
  (handler-case
      (funcall function)
    (error (condition)
      (error "~a file=~s directory=~s raw-directory=~s cwd=~s: ~a"
             label
             (buffer-filename buffer)
             (ignore-errors (buffer-directory buffer))
             (lem/buffer/internal::buffer-%directory buffer)
             (uiop:getcwd)
             condition))))

(define-command lem-yath-test-vcs-gutter () ()
  (handler-case
      (let* ((code (find-file-buffer *vcs-test-code-file*))
             (markdown (find-file-buffer *vcs-test-markdown-file*))
             (utility (or (get-buffer "*vcs-test-utility*")
                          (make-buffer "*vcs-test-utility*" :temporary t))))
        (vcs-test-gutter-operation
         "utility-mode" utility
         (lambda ()
           (change-buffer-mode
            utility 'lem/buffer/fundamental-mode:fundamental-mode)))
        (vcs-test-gutter-operation
         "initial-sync-code" code
         (lambda () (lem-yath-git-gutter-sync-buffer code)))
        (vcs-test-gutter-operation
         "initial-sync-markdown" markdown
         (lambda () (lem-yath-git-gutter-sync-buffer markdown)))
        (vcs-test-gutter-operation
         "initial-sync-utility" utility
         (lambda () (lem-yath-git-gutter-sync-buffer utility)))
        (vcs-test-gutter-operation
         "initial-refresh-code" code
         (lambda ()
           (lem-git-gutter::update-git-gutter-for-buffer code)))
        (let* ((entries (vcs-test-gutter-entries code))
               (initial (and (vcs-test-entry-p entries :added "+")
                             (vcs-test-entry-p entries :modified "~")
                             (vcs-test-entry-p entries :deleted "_")))
               (markdown-content (vcs-test-gutter-content markdown 1))
               (utility-content (vcs-test-gutter-content utility 1))
               (markdown-composed
                 (vcs-test-composed-gutter-content markdown 1))
               (utility-composed
                 (vcs-test-composed-gutter-content utility 1))
               (timer-scheduled nil)
               (transition-off nil)
               (transition-clean nil))
          (with-point ((point (buffer-start-point code)))
            (lem-yath-git-gutter-after-change point point 0))
          (setf timer-scheduled
                (not (null (lem-git-gutter::buffer-git-gutter-timer code))))
          (vcs-test-gutter-operation
           "code-to-markdown" code
           (lambda ()
             (change-buffer-mode code 'lem-markdown-mode:markdown-mode)))
          (vcs-test-gutter-operation
           "sync-markdown" code
           (lambda () (lem-yath-git-gutter-sync-buffer code)))
          (setf transition-off
                (not (lem-yath-git-gutter-mode-active-p code))
                transition-clean
                (and (null (lem-git-gutter::buffer-git-gutter-timer code))
                     (null (lem-git-gutter::buffer-git-gutter-changes code))
                     (null (lem-git-gutter::buffer-git-gutter-overlays code))
                     (null (vcs-test-composed-gutter-content code 1))))
          (vcs-test-gutter-operation
           "code-to-lisp" code
           (lambda () (change-buffer-mode code 'lem-lisp-mode:lisp-mode)))
          (vcs-test-gutter-operation
           "sync-lisp" code
           (lambda () (lem-yath-git-gutter-sync-buffer code)))
          (vcs-test-gutter-operation
           "refresh-lisp" code
           (lambda ()
             (lem-git-gutter::update-git-gutter-for-buffer code)))
          (setf entries (vcs-test-gutter-entries code))
          (setf *vcs-test-gutter-baseline*
                (vcs-test-gutter-summary entries))
          (let* ((added (vcs-test-entry-p entries :added "+"))
                 (modified (vcs-test-entry-p entries :modified "~"))
                 (deleted (vcs-test-entry-p entries :deleted "_"))
                 (restored (and added modified deleted)))
          (vcs-test-log
           (concatenate
            'string
            "GUTTER code-programming=~a code-mode=~a added=~a modified=~a "
            "deleted=~a initial=~a timer=~a transition-off=~a "
            "transition-clean=~a restored=~a markdown-programming=~a "
            "markdown-mode=~a markdown=~a "
            "markdown-composed=~a markdown-state=~a utility-programming=~a "
            "utility-mode=~a utility=~a utility-composed=~a utility-state=~a "
            "debounce-line=~d debounce-clean=~a markers=~a")
           (vcs-test-yes-no (programming-buffer-p code))
           (vcs-test-yes-no (lem-yath-git-gutter-mode-active-p code))
           (vcs-test-yes-no added)
           (vcs-test-yes-no modified)
           (vcs-test-yes-no deleted)
           (vcs-test-yes-no initial)
           (vcs-test-yes-no timer-scheduled)
           (vcs-test-yes-no transition-off)
           (vcs-test-yes-no transition-clean)
           (vcs-test-yes-no restored)
           (vcs-test-yes-no (programming-buffer-p markdown))
           (vcs-test-yes-no (lem-yath-git-gutter-mode-active-p markdown))
           (if markdown-content (vcs-test-encode markdown-content) "none")
           (if markdown-composed (vcs-test-encode markdown-composed) "none")
           (vcs-test-yes-no
            (lem-git-gutter::buffer-git-gutter-changes markdown))
           (vcs-test-yes-no (programming-buffer-p utility))
           (vcs-test-yes-no (lem-yath-git-gutter-mode-active-p utility))
           (if utility-content (vcs-test-encode utility-content) "none")
           (if utility-composed (vcs-test-encode utility-composed) "none")
           (vcs-test-yes-no
            (lem-git-gutter::buffer-git-gutter-changes utility))
           *vcs-test-gutter-debounce-line*
           (vcs-test-yes-no
            (null (vcs-test-entry-at-line
                   entries *vcs-test-gutter-debounce-line*)))
           (vcs-test-gutter-summary entries))
          (switch-to-buffer code)
          (buffer-start (current-point))
          (line-offset (current-point)
                       (1- *vcs-test-gutter-debounce-line*))
          (redraw-display))))
    (error (condition)
      (vcs-test-log
       (concatenate
        'string
        "GUTTER error=~a code=~a markdown=~a current-file=~a "
        "current-directory=~a cwd=~a")
       (vcs-test-encode (princ-to-string condition))
       (vcs-test-encode *vcs-test-code-file*)
       (vcs-test-encode *vcs-test-markdown-file*)
       (vcs-test-encode (or (buffer-filename (current-buffer)) "none"))
       (vcs-test-encode (ignore-errors (buffer-directory (current-buffer))))
       (vcs-test-encode (namestring (uiop:getcwd)))))))

(define-command lem-yath-test-vcs-debounce-state () ()
  (let* ((buffer *vcs-test-source-buffer*)
         (entries (vcs-test-gutter-entries buffer))
         (summary (vcs-test-gutter-summary entries))
         (target (vcs-test-entry-at-line
                  entries *vcs-test-gutter-debounce-line*)))
    (vcs-test-log
     (concatenate
      'string
      "DEBOUNCE phase=~a timer=~a target=~a type=~a marker=~a "
      "changed=~a baseline=~a source-text=~a modified=~a")
     *vcs-test-phase*
     (vcs-test-yes-no
      (lem-git-gutter::buffer-git-gutter-timer buffer))
     (vcs-test-yes-no target)
     (if target (string-downcase (symbol-name (second target))) "none")
     (if target (vcs-test-encode (or (third target) "")) "none")
     (vcs-test-yes-no
      (and *vcs-test-gutter-baseline*
           (not (string= summary *vcs-test-gutter-baseline*))))
     (vcs-test-yes-no
      (and *vcs-test-gutter-baseline*
           (string= summary *vcs-test-gutter-baseline*)))
     (vcs-test-yes-no
      (string= *vcs-test-source-text* (buffer-text buffer)))
     (vcs-test-yes-no (buffer-modified-p buffer)))))

(defun vcs-test-directory-equal-p (left right)
  (and left right
       (ignore-errors
         (equal (truename (uiop:ensure-directory-pathname left))
                (truename (uiop:ensure-directory-pathname right))))))

(define-command lem-yath-test-vcs-roots () ()
  (let* ((buffer *vcs-test-source-buffer*)
         (directory (vcs-directory buffer))
         (jj (save-excursion
               (setf (current-buffer) buffer)
               (jj-root)))
         (git (git-root directory))
         (history-git (tm-repo-root directory))
         (expected (if (string= *vcs-test-phase* "colocated")
                       *vcs-test-colocated-root*
                       *vcs-test-git-root*)))
    (vcs-test-log
     (concatenate
      'string
      "ROOTS phase=~a jj=~a git=~a history-git=~a expected=~a "
      "raw-exact=~a raw-sentinel=~a")
     *vcs-test-phase*
     (vcs-test-yes-no (vcs-test-directory-equal-p jj expected))
     (vcs-test-yes-no (vcs-test-directory-equal-p git expected))
     (vcs-test-yes-no
      (vcs-test-directory-equal-p history-git expected))
     (vcs-test-yes-no expected)
     (vcs-test-yes-no (vcs-test-source-raw-exact-p))
     (vcs-test-yes-no (vcs-test-source-raw-sentinel-p)))))

(defun vcs-test-jj-buffer-p (buffer)
  (or (string= (buffer-name buffer) "*lem-yath-jj*")
      (search "lem-yath-jj" (buffer-name buffer) :test #'char-equal)))

(define-command lem-yath-test-vcs-dispatch-state () ()
  (let* ((buffer (current-buffer))
         (text (buffer-text buffer))
         (jj-view (vcs-test-jj-buffer-p buffer))
         (legit (and (fboundp 'lem/legit::legit-status-active-p)
                     (lem/legit::legit-status-active-p)))
         (utility-content (ignore-errors
                            (vcs-test-gutter-content buffer 1))))
    (vcs-test-log
     (concatenate
      'string
      "DISPATCH phase=~a kind=~a jj-view=~a legit=~a content=~a exit=~a "
      "programming=~a utility-gutter=~a refresh-probe=~a "
      "raw-exact=~a raw-sentinel=~a buffer=~a")
     *vcs-test-phase*
     (cond (jj-view "jj") (legit "git") (t "other"))
     (vcs-test-yes-no jj-view)
     (vcs-test-yes-no legit)
     (vcs-test-yes-no
      (and jj-view
           (or (search "vcs-colocated" text :test #'char-equal)
               (search "Working copy" text :test #'char-equal))))
     (vcs-test-yes-no (search "[exit 0]" text))
     (vcs-test-yes-no (programming-buffer-p buffer))
     (if utility-content (vcs-test-encode utility-content) "none")
     (vcs-test-yes-no (search "jj-refresh-probe.txt" text
                              :test #'char-equal))
     (vcs-test-yes-no (vcs-test-source-raw-exact-p))
     (vcs-test-yes-no (vcs-test-source-raw-sentinel-p))
     (vcs-test-encode (buffer-name buffer)))))

(define-command lem-yath-test-vcs-legit-state () ()
  (let* ((active (and (fboundp 'lem/legit::legit-status-active-p)
                      (lem/legit::legit-status-active-p)))
         (buffer (and active
                      (window-buffer lem/legit::*peek-window*)))
         (text (and buffer (buffer-text buffer)))
         (todo-point (and buffer (buffer-start-point buffer))))
    (when todo-point
      (unless (search-forward todo-point "nested/deeper/todos.org:1:")
        (setf todo-point nil))
      (when todo-point (line-start todo-point)))
    (vcs-test-log
     (concatenate
      'string
      "LEGIT phase=~a active=~a source-live=~a raw-exact=~a "
      "raw-sentinel=~a todos=~a todo-count=~a todo-properties=~a "
      "todo-hook=~d todo-bottom=~a current=~a")
     *vcs-test-phase*
     (vcs-test-yes-no active)
     (vcs-test-yes-no (and *vcs-test-source-buffer*
                           (not (deleted-buffer-p *vcs-test-source-buffer*))))
     (vcs-test-yes-no (vcs-test-source-raw-exact-p))
     (vcs-test-yes-no (vcs-test-source-raw-sentinel-p))
     (vcs-test-yes-no (and text (search "Todos (17):" text)))
     (vcs-test-yes-no
      (and text
           (let ((hold (search "HOLD: held" text))
                 (todo (search "* TODO tracked implementation task" text))
                 (next (search "NEXT: next" text))
                 (fixme (search "FIXME(owner): tracked documentation task"
                                text)))
             (and hold todo next fixme (< hold todo next fixme)))
           (search "nested/deeper/todos.org:1:" text)
           (search "nested/docs/fixmes.txt:1:" text)
           (search "nested/docs/keywords.txt:14: XXXX*: literal" text)
           (search "nested/deeper/untracked-todo.txt:1: TODO: untracked scanner item"
                   text)
           (not (search "ignored scanner item" text))
           (not (search "submodule scanner item" text))
           (not (search "NOTE: ignored" text))
           (not (search "DONE: ignored" text))
           (not (search "TODO missing required colon" text))))
     (vcs-test-yes-no
      (and todo-point
           (lem/legit::get-move-function todo-point)
           (lem/legit::get-visit-file-function todo-point)))
     (count 'insert-legit-todo-section
            lem/legit::*status-bottom-section-functions*
            :key #'car :test #'eq)
     (vcs-test-yes-no
      (and text
           (let ((latest (search "Latest commits:" text))
                 (todos (search "Todos (17):" text)))
             (and latest todos (< latest todos)))))
     (vcs-test-encode (buffer-name (current-buffer))))))

(define-command lem-yath-test-vcs-todo-preview () ()
  (let* ((buffer (and (lem/legit::legit-status-active-p)
                      (window-buffer lem/legit::*peek-window*)))
         (row (and buffer (buffer-start-point buffer))))
    (when row
      (unless (search-forward row "nested/deeper/todos.org:1:")
        (setf row nil))
      (when row (line-start row)))
    (let* ((move (and row (lem/legit::get-move-function row)))
           (visit (and row (lem/legit::get-visit-file-function row)))
           (source (and move (funcall move)))
           (source-buffer (and source (point-buffer source))))
      (vcs-test-log
       "TODO-PREVIEW row=~a move=~a visit=~a file=~a line=~a text=~a"
       (vcs-test-yes-no row)
       (vcs-test-yes-no source)
       (vcs-test-yes-no
        (and visit
             (string= (funcall visit) "nested/deeper/todos.org")))
       (if (and source-buffer (buffer-filename source-buffer))
           (file-namestring (buffer-filename source-buffer))
           "none")
       (if source (line-number-at-point source) "none")
       (vcs-test-yes-no
        (and source-buffer
             (search "TODO tracked implementation task"
                     (buffer-text source-buffer))))))))

(defun vcs-test-todo-section-kind-p (section kind)
  (let ((key (legit-todo-section-key section)))
    (case kind
      (:worktree (and (= 2 (length key)) (eq :worktree (second key))))
      (:branch (and (= 3 (length key)) (eq :branch (second key))))
      (:keyword (and (member :keyword key) (not (member :path key))))
      (:path (not (null (member :path key)))))))

(defun vcs-test-todo-section (buffer kind)
  (find-if (lambda (section)
             (vcs-test-todo-section-kind-p section kind))
           (legit-todo-buffer-sections buffer)))

(defun vcs-test-todo-keyword-section (buffer path-p)
  (find-if
   (lambda (section)
     (let* ((key (legit-todo-section-key section))
            (keyword-tail (member :keyword key)))
       (and keyword-tail
            (string= "TODO" (second keyword-tail))
            (eq path-p (not (null (member :path key)))))))
   (legit-todo-buffer-sections buffer)))

(defun vcs-test-todo-row-point (buffer text)
  (let ((point (buffer-start-point buffer)))
    (if (search-forward point text)
        (progn (line-start point) point)
        nil)))

(define-command lem-yath-test-vcs-todo-sections () ()
  (let* ((buffer (and (lem/legit::legit-status-active-p)
                      (window-buffer lem/legit::*peek-window*)))
         (sections (and buffer (legit-todo-buffer-sections buffer)))
         (top (and buffer (vcs-test-todo-section buffer :worktree)))
         (branch (and buffer (vcs-test-todo-section buffer :branch)))
         (keyword (and buffer (vcs-test-todo-keyword-section buffer nil)))
         (path (and buffer (vcs-test-todo-keyword-section buffer t)))
         (ordinary-row
           (and buffer
                (vcs-test-todo-row-point
                 buffer "TODO tracked implementation task")))
         (branch-row
           (and buffer
                (vcs-test-todo-row-point buffer "TODO: branch-only")))
         (root (and top (first (legit-todo-section-key top))))
         (policy (and root (legit-todo-branch-policy root)))
         (base-ref (and root (legit-todo-merge-base-ref root))))
    (vcs-test-log
     (concatenate
      'string
      "TODO-SECTIONS total=~d top=~a top-hidden=~a grouped=~a "
      "keyword-hidden=~a path-hidden=~a row-hidden=~a branch=~a "
      "branch-hidden=~a branch-row=~a branch-row-hidden=~a "
      "policy=~a base=~a")
     (length sections)
     (vcs-test-yes-no top)
     (vcs-test-yes-no (and top (legit-todo-section-hidden-p top)))
     (vcs-test-yes-no (and keyword path))
     (vcs-test-yes-no
      (and keyword (legit-todo-section-hidden-p keyword)))
     (vcs-test-yes-no (and path (legit-todo-section-hidden-p path)))
     (vcs-test-yes-no
      (and ordinary-row (legit-todo-line-hidden-p ordinary-row)))
     (vcs-test-yes-no branch)
     (vcs-test-yes-no
      (and branch (legit-todo-section-hidden-p branch)))
     (vcs-test-yes-no branch-row)
     (vcs-test-yes-no
      (and branch-row (legit-todo-line-hidden-p branch-row)))
     (cond ((eq policy :branch) "branch")
           ((eq policy t) "t")
           (t "nil"))
     (or base-ref "automatic"))))

(define-command lem-yath-test-vcs-position-todo-heading () ()
  (let* ((buffer (and (lem/legit::legit-status-active-p)
                      (window-buffer lem/legit::*peek-window*)))
         (section (and buffer (vcs-test-todo-section buffer :worktree))))
    (when section
      (setf (current-window) lem/legit::*peek-window*)
      (move-point (buffer-point buffer)
                  (legit-todo-section-heading section)))))

(define-command lem-yath-test-vcs-todo-list-state () ()
  (let* ((active (lem/legit::legit-status-active-p))
         (buffer (and active (window-buffer lem/legit::*peek-window*)))
         (root (and buffer (legit-todo-list-root buffer)))
         (sections (and buffer (legit-todo-buffer-sections buffer)))
         (top
           (and sections
                (find-if
                 (lambda (section)
                   (let ((key (legit-todo-section-key section)))
                     (and (= 3 (length key))
                          (eq :list (second key))
                          (eq :worktree (third key)))))
                 sections)))
         (grouped
           (and sections
                (find-if (lambda (section)
                           (member :keyword
                                   (legit-todo-section-key section)))
                         sections)))
         (text (and buffer (buffer-text buffer))))
    (vcs-test-log
     "TODO-LIST active=~a root=~a top=~a hidden=~a grouped=~a large=~a title=~a latest=~a"
     (vcs-test-yes-no active)
     (vcs-test-yes-no root)
     (vcs-test-yes-no top)
     (vcs-test-yes-no (and top (legit-todo-section-hidden-p top)))
     (vcs-test-yes-no grouped)
     (vcs-test-yes-no (and text (search "Todos (201):" text)))
     (vcs-test-yes-no (and text (search "TODOs for " text)))
     (vcs-test-yes-no (and text (search "Latest commits:" text))))))

(define-command lem-yath-test-vcs-status-context () ()
  "Report whether physical focus is outside a TODO section in Legit status."
  (let ((status-p
          (and (lem/legit::legit-status-active-p)
               (eq (current-window) lem/legit::*peek-window*))))
    (vcs-test-log
     "STATUS-CONTEXT focus=~a todo=~a"
     (vcs-test-yes-no status-p)
     (vcs-test-yes-no
      (and status-p (legit-todo-context-root (current-point)))))))

(defun vcs-test-position-legit-file (filename &key focus-diff section)
  "Position Legit's status row for FILENAME, optionally focusing its diff."
  (let* ((active (lem/legit::legit-status-active-p))
         (status-buffer
           (and active (window-buffer lem/legit::*peek-window*)))
         (row (and status-buffer (buffer-start-point status-buffer))))
    (when row
      (when section
        (unless (search-forward row section)
          (setf row nil)))
      (when row
        (unless (search-forward row filename)
          (setf row nil)))
      (when row
        (line-start row)
        (setf (current-window) lem/legit::*peek-window*)
        (move-point (buffer-point status-buffer) row)
        (lem/legit::show-matched-line)))
    (let* ((diff-buffer
             (and row (window-buffer lem/legit::*source-window*)))
           (diff-point
             (and diff-buffer (buffer-start-point diff-buffer))))
      (when diff-point
        (unless (search-forward diff-point "@@ ")
          (setf diff-point nil))
        (when diff-point
          (line-start diff-point)))
      (when (and focus-diff diff-point)
        (setf (current-window) lem/legit::*source-window*)
        (move-point (buffer-point diff-buffer) diff-point))
      (vcs-test-log
       "PORCELAIN-POSITION file=~a row=~a diff=~a mode=~a focused=~a"
       (vcs-test-encode filename)
       (vcs-test-yes-no row)
       (vcs-test-yes-no diff-point)
       (vcs-test-yes-no
        (and diff-buffer
             (eq (buffer-major-mode diff-buffer)
                 'lem/legit::legit-diff-mode)))
       (vcs-test-yes-no
        (and focus-diff
             (eq (current-window) lem/legit::*source-window*)))))))

(define-command lem-yath-test-vcs-porcelain-diff () ()
  (vcs-test-position-legit-file "porcelain.txt" :focus-diff t))

(define-command lem-yath-test-vcs-porcelain-staged-diff () ()
  (vcs-test-position-legit-file
   "porcelain.txt" :focus-diff t :section (format nil "~%Staged changes (")))

(define-command lem-yath-test-vcs-focus-legit () ()
  "Focus the live Legit status pane without toggling or rebuilding it."
  (when (lem/legit::legit-status-active-p)
    (setf (current-window) lem/legit::*peek-window*)
    (move-point
     (buffer-point (window-buffer lem/legit::*peek-window*))
     (buffer-start-point (window-buffer lem/legit::*peek-window*)))))

(defun vcs-test-position-legit-region (staged-p)
  "Focus the first replacement's removed row in an unstaged or staged diff."
  (vcs-test-position-legit-file
   "porcelain.txt"
   :focus-diff t
   :section (and staged-p (format nil "~%Staged changes (")))
  (let* ((diff-buffer (window-buffer lem/legit::*source-window*))
         (point (and diff-buffer (buffer-start-point diff-buffer))))
    (when point
      (unless (search-forward point "-porcelain-line-02")
        (setf point nil)))
    (when point
      (line-start point)
      (setf (current-window) lem/legit::*source-window*)
      (move-point (buffer-point diff-buffer) point))
    (vcs-test-log
     "PORCELAIN-REGION staged=~a line=~a mode=~a focused=~a"
     (vcs-test-yes-no staged-p)
     (vcs-test-yes-no point)
     (vcs-test-yes-no
      (and diff-buffer
           (eq (buffer-major-mode diff-buffer)
               'lem/legit::legit-diff-mode)))
     (vcs-test-yes-no
      (eq (current-window) lem/legit::*source-window*)))))

(define-command lem-yath-test-vcs-porcelain-region () ()
  (vcs-test-position-legit-region nil))

(define-command lem-yath-test-vcs-porcelain-staged-region () ()
  (vcs-test-position-legit-region t))

(define-command lem-yath-test-vcs-porcelain-tracked () ()
  (vcs-test-position-legit-file "porcelain.txt"))

(define-command lem-yath-test-vcs-porcelain-untracked () ()
  (vcs-test-position-legit-file "untracked.txt"))

(define-command lem-yath-test-vcs-porcelain-commit () ()
  (let* ((active (lem/legit::legit-status-active-p))
         (status-buffer
           (and active (window-buffer lem/legit::*peek-window*)))
         (status-text (and status-buffer (buffer-text status-buffer)))
         (subject
           (and status-text
                (find-if (lambda (candidate)
                           (search candidate status-text))
                         '("porcelain commit edited in Lem"
                           "porcelain commit reworded twice in Lem"
                           "porcelain commit reworded in Lem"
                           "porcelain commit from Lem"))))
         (row (and status-buffer (buffer-start-point status-buffer))))
    (when (and row subject)
      (unless (search-forward row subject)
        (setf row nil)))
    (unless subject
      (setf row nil))
    (when row
      (line-start row)
      (setf (current-window) lem/legit::*peek-window*)
      (move-point (buffer-point status-buffer) row)
      (lem/legit::show-matched-line))
    (vcs-test-log
     "PORCELAIN-COMMIT row=~a hash=~a rebase=~a subject=~a"
     (vcs-test-yes-no row)
     (vcs-test-yes-no
      (and row (text-property-at row :commit-hash)))
     (vcs-test-yes-no
      (eq (vcs-test-key-command lem/legit::*peek-legit-keymap* "r i")
          'lem/legit::legit-rebase-interactive))
     (vcs-test-yes-no
      (and row
           subject
           (search subject status-text))))))

(define-command lem-yath-test-vcs-cherry-state () ()
  (lem/legit::with-current-project (vcs)
    (declare (ignore vcs))
    (let* ((status-map lem/legit::*peek-legit-keymap*)
           (diff-map lem/legit::*legit-diff-mode-keymap*)
           (subjects '("cherry-success-source"
                       "cherry-apply-source"
                       "cherry-continue-source"
                       "cherry-abort-source"
                       "cherry-skip-source"))
           (candidates
             (handler-case (legit-cherry-pick-candidates)
               (error () nil)))
           (known
             (find-if (lambda (candidate)
                        (search "cherry-success-source" (car candidate)))
                      candidates))
           (initial-map
             (legit-cherry-popup-keymap (make-legit-cherry-options) nil))
           (active-map
             (legit-cherry-popup-keymap (make-legit-cherry-options) t))
           (option-vector
             (and known
                  (legit-cherry-option-arguments
                   (make-legit-cherry-options
                    :strategy "ort" :fast-forward-p nil :reference-p t
                    :edit-p t :gpg-sign "" :signoff-p t)
                   (list (cdr known))))))
      (vcs-test-log
       "CHERRY active=~a dispatch=~a initial=~a active-map=~a options=~a candidate=~a"
       (vcs-test-yes-no (legit-cherry-pick-in-progress-p))
       (vcs-test-yes-no
        (and (eq (vcs-test-key-command status-map "A")
                 'lem-yath-legit-cherry-pick)
             (eq (vcs-test-key-command diff-map "A")
                 'lem-yath-legit-cherry-pick)))
       (vcs-test-yes-no
        (every (lambda (key)
                 (eq (vcs-test-key-command initial-map key) 'nop-command))
               '("- m" "= s" "- F" "- x" "- e" "- S" "+ s"
                 "A" "a" "h" "m" "d" "n" "s" "q")))
       (vcs-test-yes-no
        (every (lambda (key)
                 (eq (vcs-test-key-command active-map key) 'nop-command))
               '("A" "a" "s" "q")))
       (vcs-test-yes-no
        (and
         (equal option-vector
                '("--strategy=ort" "-x" "--edit" "--gpg-sign"
                  "--signoff"))
         (handler-case
             (progn
               (legit-cherry-option-arguments
                (make-legit-cherry-options
                 :fast-forward-p t :edit-p t)
                (list (cdr known)))
               nil)
           (error () t))))
       (vcs-test-yes-no
        (and candidates
             (every (lambda (subject)
                      (some (lambda (candidate)
                              (search subject (car candidate)))
                            candidates))
                    subjects)))))))

(define-command lem-yath-test-vcs-log-action-state () ()
  "Report whether a history action retained its configured log and anchor."
  (let* ((buffer
           (if (lem/legit::legit-status-active-p)
               (window-buffer lem/legit::*peek-window*)
               (current-buffer)))
         (state (buffer-value buffer 'legit-log-state))
         (point (buffer-point buffer))
         (hash (text-property-at point :commit-hash))
         (line (line-string point)))
    (vcs-test-log
     "LOG-ACTION log=~a status=~a state=~a hash=~a line=~a offset=~d"
     (vcs-test-yes-no (string= (buffer-name buffer) "*legit-commits-log*"))
     (vcs-test-yes-no (string= (buffer-name buffer) "*peek-legit*"))
     (vcs-test-yes-no state)
     (vcs-test-yes-no hash)
     (vcs-test-encode line)
     (if state (legit-log-state-offset state) -1))))

(define-command lem-yath-test-vcs-cherry-position () ()
  (let* ((status-buffer
           (and (lem/legit::legit-status-active-p)
                (window-buffer lem/legit::*peek-window*)))
         (status-text (and status-buffer (buffer-text status-buffer)))
         (filename
           (and status-text
                (find-if (lambda (candidate)
                           (search candidate status-text))
                         '("cherry-continue.txt"
                           "cherry-abort.txt"
                           "cherry-skip.txt")))))
    (if filename
        (vcs-test-position-legit-file filename)
        (vcs-test-log
         "PORCELAIN-POSITION file=cherry-conflict row=no diff=no mode=no focused=no"))))

(define-command lem-yath-test-vcs-bisect-state () ()
  (lem/legit::with-current-project (vcs)
    (declare (ignore vcs))
    (let* ((active (legit-bisect-in-progress-p))
           (status-buffer
             (and (lem/legit::legit-status-active-p)
                  (window-buffer lem/legit::*peek-window*)))
           (status-text (and status-buffer (buffer-text status-buffer)))
           (options (make-legit-bisect-options))
           (initial-map (legit-bisect-popup-keymap options nil))
           (active-map (legit-bisect-popup-keymap options t))
           (terms (and active (multiple-value-list (legit-bisect-terms))))
           (log-output
             (and active
                  (multiple-value-bind (output error-output status)
                      (legit-bisect-run-program '("bisect" "log"))
                    (declare (ignore error-output))
                    (and (eql status 0) output))))
           (data
             (and active
                  (handler-case
                      (multiple-value-list (legit-bisect-status-data))
                    (error () nil))))
           (entries (third data)))
      ;; The reporter is also the test harness's deterministic transition into
      ;; the already-open status pane.  Legit may refresh an existing peek
      ;; window without selecting it when invoked from another pane.
      (when status-buffer
        (switch-to-window lem/legit::*peek-window*))
      (vcs-test-log
       (concatenate
        'string
        "BISECT active=~a status=~a diff=~a initial=~a actions=~a "
        "section=~a terms=~a no-checkout=~a first-parent=~a "
        "first-bad=~a hook=~d")
       (vcs-test-yes-no active)
       (vcs-test-yes-no
        (eq 'lem-yath-legit-bisect-or-todo-base
            (vcs-test-key-command lem/legit::*peek-legit-keymap* "B")))
       (vcs-test-yes-no
        (eq 'lem-yath-legit-bisect
            (vcs-test-key-command
             lem/legit::*legit-diff-mode-keymap* "B")))
       (vcs-test-yes-no
        (every (lambda (key)
                 (eq 'nop-command
                     (vcs-test-key-command initial-map key)))
               '("- n" "- p" "= o" "= n" "B" "s" "q")))
       (vcs-test-yes-no
        (every (lambda (key)
                 (eq 'nop-command
                     (vcs-test-key-command active-map key)))
               '("B" "g" "m" "k" "r" "s" "q")))
       (vcs-test-yes-no
        (and active status-text
             (search "Bisect:" status-text)
             (search "Bisect log:" status-text)))
       (if terms
           (format nil "~a/~a" (second terms) (first terms))
           "none")
       (vcs-test-yes-no
        (and active (legit-git-metadata-path-exists-p "BISECT_HEAD")))
       (vcs-test-yes-no
        (and log-output (search "--first-parent" log-output)))
       (vcs-test-yes-no
        (find "first bad" entries
              :key #'legit-bisect-log-entry-term
              :test #'string=))
       (count 'insert-legit-bisect-section
              lem/legit::*status-section-functions*
              :key #'car :test #'eq)))))

(define-command lem-yath-test-vcs-legit-and-bisect-state () ()
  (lem-yath-test-vcs-legit-state)
  (when (string= *vcs-test-phase* "porcelain")
    (handler-case
        (lem-yath-test-vcs-bisect-state)
      (error (condition)
        (vcs-test-log "BISECT error=~a"
                      (vcs-test-encode (princ-to-string condition)))))))

(define-command lem-yath-test-vcs-rebase-state () ()
  (let* ((buffer (current-buffer))
         (text (buffer-text buffer))
         (filename (buffer-filename buffer)))
    (vcs-test-log
     (concatenate
      'string
      "REBASE mode=~a file=~a first=~a second=~a "
      "point=~a fixup=~a edit=~a commit=~a amend=~a diff=~a legacy-free=~a "
      "continue=~a abort=~a modified=~a")
     (vcs-test-yes-no
      (eq (buffer-major-mode buffer) 'lem/legit::legit-rebase-mode))
     (vcs-test-yes-no
      (and filename
           (string= (file-namestring filename) "git-rebase-todo")))
     (vcs-test-yes-no
      (or (search "porcelain commit from Lem" text)
          (search "porcelain commit reworded in Lem" text)))
     (vcs-test-yes-no (search "porcelain-peer" text))
     (vcs-test-yes-no (= (line-number-at-point (buffer-point buffer)) 1))
     (vcs-test-yes-no
      (eq (vcs-test-key-command lem/legit::*legit-rebase-mode-keymap* "f")
          'lem/legit::rebase-mark-line-fixup))
     (vcs-test-yes-no
      (eq (vcs-test-key-command lem/legit::*legit-rebase-mode-keymap* "e")
          'lem/legit::rebase-mark-line-edit))
     (vcs-test-yes-no
      (eq (vcs-test-key-command lem/legit::*peek-legit-keymap* "c c")
          'lem/legit::legit-commit))
     (vcs-test-yes-no
      (eq (vcs-test-key-command lem/legit::*peek-legit-keymap* "c a")
          'lem-yath-legit-amend))
     (vcs-test-yes-no
      (and
       (eq (vcs-test-key-command lem/legit::*legit-diff-mode-keymap* "c c")
           'lem/legit::legit-commit)
       (eq (vcs-test-key-command lem/legit::*legit-diff-mode-keymap* "c a")
           'lem-yath-legit-amend)))
     (vcs-test-yes-no
      (and
       (not (eq (vcs-test-key-command lem/legit::*peek-legit-keymap* "A")
                'lem-yath-legit-amend))
       (not (eq (vcs-test-key-command lem/legit::*legit-diff-mode-keymap* "A")
                'lem-yath-legit-amend))))
     (vcs-test-yes-no
      (eq (vcs-test-key-command lem/legit::*legit-rebase-mode-keymap*
                                "C-c C-c")
          'lem/legit::rebase-continue))
     (vcs-test-yes-no
      (eq (vcs-test-key-command lem/legit::*legit-rebase-mode-keymap*
                                "C-c C-k")
          'lem/legit::rebase-abort))
     (vcs-test-yes-no (buffer-modified-p buffer)))))

(define-command lem-yath-test-vcs-reword-state () ()
  (let* ((buffer (current-buffer))
         (filename (buffer-filename buffer)))
    (if (legit-amend-buffer-p buffer)
        (let ((clean
                (string-right-trim
                 '(#\Space #\Tab #\Newline #\Return)
                 (lem/legit::clean-commit-message
                  (buffer-text buffer)))))
          (vcs-test-log
           (concatenate
            'string
            "AMEND mode=~a file=~a name=~a action=~a subject=~a clean=~a "
            "continue=~a abort=~a commit=~a amend=~a diff=~a legacy-free=~a")
         (vcs-test-yes-no
          (eq (buffer-major-mode buffer) 'lem/legit::legit-commit-mode))
         (vcs-test-yes-no filename)
         (vcs-test-yes-no (string= (buffer-name buffer) "*legit-amend*"))
         (vcs-test-yes-no (legit-amend-buffer-p buffer))
         (vcs-test-yes-no
          (search "porcelain commit reworded twice in Lem"
                  (buffer-text buffer)))
         (vcs-test-yes-no
          (string= clean "porcelain commit reworded twice in Lem"))
         (vcs-test-yes-no
          (eq (vcs-test-key-command lem/legit::*legit-commit-mode-keymap*
                                    "C-c C-c")
              'lem-yath-legit-log-message-continue))
         (vcs-test-yes-no
          (eq (vcs-test-key-command lem/legit::*legit-commit-mode-keymap*
                                    "C-c C-k")
              'lem-yath-legit-log-message-abort))
         (vcs-test-yes-no
          (eq (vcs-test-key-command lem/legit::*peek-legit-keymap* "c c")
              'lem/legit::legit-commit))
         (vcs-test-yes-no
          (eq (vcs-test-key-command lem/legit::*peek-legit-keymap* "c a")
              'lem-yath-legit-amend))
         (vcs-test-yes-no
          (and
           (eq (vcs-test-key-command lem/legit::*legit-diff-mode-keymap* "c c")
               'lem/legit::legit-commit)
           (eq (vcs-test-key-command lem/legit::*legit-diff-mode-keymap* "c a")
               'lem-yath-legit-amend)))
         (vcs-test-yes-no
          (and
           (not (eq (vcs-test-key-command lem/legit::*peek-legit-keymap* "A")
                    'lem-yath-legit-amend))
           (not (eq (vcs-test-key-command lem/legit::*legit-diff-mode-keymap*
                                          "A")
                    'lem-yath-legit-amend))))))
        (vcs-test-log
         (concatenate
          'string
          "REWORD mode=~a file=~a server=~a subject=~a "
          "continue=~a abort=~a")
         (vcs-test-yes-no
          (eq (buffer-major-mode buffer) 'lem/legit::legit-commit-mode))
         (vcs-test-yes-no
          (and filename
               (string= (file-namestring filename) "COMMIT_EDITMSG")))
         (vcs-test-yes-no (server-buffer-requests buffer))
         (vcs-test-yes-no
          (or (search "porcelain commit from Lem" (buffer-text buffer))
              (search "porcelain commit reworded in Lem"
                      (buffer-text buffer))))
         (vcs-test-yes-no
          (eq (vcs-test-key-command lem/legit::*legit-commit-mode-keymap*
                                    "C-c C-c")
              'lem-yath-legit-log-message-continue))
         (vcs-test-yes-no
          (eq (vcs-test-key-command lem/legit::*legit-commit-mode-keymap*
                                    "C-c C-k")
              'lem-yath-legit-log-message-abort))))))

(defun vcs-test-restore-source-point ()
  (let ((point (buffer-point *vcs-test-source-buffer*)))
    (buffer-start point)
    (character-offset point (1- *vcs-test-source-point*))))

(define-command lem-yath-test-vcs-restore-source () ()
  (when (and *vcs-test-source-buffer*
             (not (deleted-buffer-p *vcs-test-source-buffer*)))
    (vcs-test-restore-source-point)
    (switch-to-buffer *vcs-test-source-buffer*)
    (vcs-test-log "RESTORE phase=~a source=yes file=~a"
                  *vcs-test-phase*
                  (vcs-test-encode
                   (file-namestring (buffer-filename (current-buffer)))))))

(define-command lem-yath-test-vcs-timemachine-state () ()
  (let* ((buffer (current-buffer))
         (timemachine (tm-buffer-p buffer))
         (text (buffer-text buffer)))
    (if timemachine
        (let* ((index (buffer-value buffer *tm-index-key*))
               (revisions (buffer-value buffer *tm-revisions-key*))
               (revision (aref revisions index)))
          (with-point ((line (current-point))
                       (end (current-point)))
            (line-start line)
            (move-point end line)
            (line-end end)
            (vcs-test-log
           (concatenate
            'string
            "TIMEMACHINE active=yes index=~d count=~d old=~a new=~a "
            "hash=~a old-hash=~a read-only=~a mode=~a minor=~a "
            "point=~d:~d anchor=~a")
           index
           (length revisions)
           (vcs-test-yes-no (search "vcs-history :old" text))
           (vcs-test-yes-no (search "vcs-history :new" text))
           (tm-revision-hash revision)
           (vcs-test-yes-no
            (string= *vcs-test-old-hash* (tm-revision-hash revision)))
           (vcs-test-yes-no (buffer-read-only-p buffer))
           (vcs-test-encode (symbol-name (buffer-major-mode buffer)))
           (vcs-test-yes-no
            (lem-core::mode-active-p buffer 'lem-yath-timemachine-mode))
           (line-number-at-point (current-point))
           (point-column (current-point))
           (vcs-test-yes-no
            (search "vcs-eight" (points-to-string line end))))))
        (vcs-test-log
         "TIMEMACHINE active=no current=~a"
         (vcs-test-encode (buffer-name buffer))))))

(defun vcs-test-killring-head ()
  (or (lem/common/killring:peek-killring-item (current-killring) 0) ""))

(define-command lem-yath-test-vcs-timemachine-extra-state () ()
  (let* ((buffer (current-buffer))
         (history (tm-buffer-p buffer))
         (blame (tm-blame-buffer-p buffer))
         (parent (and blame (buffer-value buffer *tm-blame-parent-key*)))
         (revision (tm-current-revision (if history buffer parent)))
         (hash (and revision (tm-revision-hash revision)))
         (short (and hash
                     (subseq hash 0 (min *tm-abbreviation-length*
                                         (length hash)))))
         (head (vcs-test-killring-head))
         (text (buffer-text buffer)))
    (vcs-test-log
     (concatenate
      'string
      "TIMEMACHINE-EXTRA history=~a blame=~a parent=~a short=~a full=~a "
      "read-only=~a author=~a date=~a content=~a blame-live=~d")
     (vcs-test-yes-no history)
     (vcs-test-yes-no blame)
     (vcs-test-yes-no (and parent (tm-buffer-p parent)))
     (vcs-test-yes-no (and short (string= head short)))
     (vcs-test-yes-no (and hash (string= head hash)))
     (vcs-test-yes-no (buffer-read-only-p buffer))
     (vcs-test-yes-no (search "Lem Yath Test" text))
     (vcs-test-yes-no (search "2001-01-02" text))
     (vcs-test-yes-no (search "vcs-history :old" text))
     (count-if #'tm-blame-buffer-p (buffer-list)))))

(define-command lem-yath-test-vcs-git-blame-state () ()
  (let* ((buffer (current-buffer))
         (blame (git-blame-buffer-p buffer))
         (commit (git-blame-commit-buffer-p buffer))
         (parent (and commit
                      (buffer-value buffer *git-blame-commit-parent-key*)))
         (blame-buffer (cond (blame buffer)
                             ((git-blame-buffer-p parent) parent)))
         (record (and blame-buffer
                      (git-blame-current-record
                       (buffer-point blame-buffer))))
         (hash (and record (git-blame-record-hash record)))
         (origin (and blame-buffer
                      (buffer-value blame-buffer
                                    *git-blame-origin-buffer-key*)))
         (origin-point
           (and blame-buffer
                (buffer-value blame-buffer *git-blame-origin-point-key*)))
         (text (buffer-text buffer))
         (head (vcs-test-killring-head)))
    (vcs-test-log
     (concatenate
      'string
      "BLAME kind=~a blame=~d commit=~d zero=~a external=~a live=~a "
      "origin=~a origin-point=~a read-only=~a copied=~a show=~a source=~a")
     (cond (blame "blame") (commit "commit") (t "source"))
     (count-if #'git-blame-buffer-p (buffer-list))
     (count-if #'git-blame-commit-buffer-p (buffer-list))
     (vcs-test-yes-no (and hash (git-blame-zero-hash-p hash)))
     (vcs-test-yes-no
      (and record
           (string= "External file (--contents)"
                    (git-blame-record-author record))))
     (vcs-test-yes-no (search "UNSAVED-BLAME-" text))
     (vcs-test-yes-no (eq origin *vcs-test-source-buffer*))
     (vcs-test-yes-no
      (and origin-point
           (eq (point-buffer origin-point) *vcs-test-source-buffer*)
           (= (position-at-point origin-point)
              (position-at-point
               (buffer-point *vcs-test-source-buffer*)))))
     (vcs-test-yes-no (buffer-read-only-p buffer))
     (vcs-test-yes-no (and hash (string= hash head)))
     (vcs-test-yes-no (and commit
                            hash
                            (search (format nil "commit ~a" hash) text)))
     (vcs-test-yes-no (eq buffer *vcs-test-source-buffer*)))))

(define-command lem-yath-test-vcs-history-view-state () ()
  (if (or (git-blame-buffer-p (current-buffer))
          (git-blame-commit-buffer-p (current-buffer))
          (and (eq (current-buffer) *vcs-test-source-buffer*)
               (search "UNSAVED-BLAME-" (buffer-text (current-buffer)))))
      (lem-yath-test-vcs-git-blame-state)
      (lem-yath-test-vcs-timemachine-state)))

(define-command lem-yath-test-vcs-source-state () ()
  (let ((buffer *vcs-test-source-buffer*))
    (vcs-test-log
     (concatenate
      'string
      "SOURCE current=~a live=~a text=~a point=~a mode=~a modified=~a "
      "filename=~a timemachine-live=~d")
     (vcs-test-yes-no (eq (current-buffer) buffer))
     (vcs-test-yes-no (and buffer (not (deleted-buffer-p buffer))))
     (vcs-test-yes-no (and buffer
                           (string= *vcs-test-source-text*
                                    (buffer-text buffer))))
     (vcs-test-yes-no (and buffer
                           (= *vcs-test-source-point*
                              (position-at-point (buffer-point buffer)))))
     (vcs-test-yes-no (and buffer
                           (eq *vcs-test-source-mode*
                               (buffer-major-mode buffer))))
     (vcs-test-yes-no (and buffer
                           (eql *vcs-test-source-modified*
                                (buffer-modified-p buffer))))
     (vcs-test-yes-no (and buffer (buffer-filename buffer)
                           (equal (buffer-filename buffer)
                                  *vcs-test-source-filename*)))
     (count-if #'tm-buffer-p (buffer-list)))))

(define-command lem-yath-test-vcs-prepare-invocation () ()
  "Put an unrelated buffer immediately behind the exact source invocation."
  (let ((other (or (get-buffer "*vcs-test-intervening*")
                   (make-buffer "*vcs-test-intervening*"))))
    (setf *vcs-test-other-buffer* other)
    (vcs-test-restore-source-point)
    (switch-to-buffer other)
    (switch-to-buffer *vcs-test-source-buffer*)
    (vcs-test-log
     "INVOKE source=~a other=~a point=~d:~d"
     (vcs-test-yes-no (eq (current-buffer) *vcs-test-source-buffer*))
     (vcs-test-yes-no (not (deleted-buffer-p other)))
     (line-number-at-point (current-point))
     (point-column (current-point)))))

(define-command lem-yath-test-vcs-detour-timemachine () ()
  "Make an unrelated ordinary buffer newer than the stored invoking buffer."
  (let ((timemachine (current-buffer))
        (other *vcs-test-other-buffer*))
    (when (and (tm-buffer-p timemachine)
               other
               (not (deleted-buffer-p other)))
      (switch-to-buffer other)
      (switch-to-buffer timemachine))
    (vcs-test-log
     "DETOUR timemachine=~a other=~a source-current=~a"
     (vcs-test-yes-no (tm-buffer-p (current-buffer)))
     (vcs-test-yes-no (and other (not (deleted-buffer-p other))))
     (vcs-test-yes-no (eq (current-buffer) *vcs-test-source-buffer*)))))

(define-command lem-yath-test-vcs-untracked-state () ()
  "Visit and report the recreated path that has history but is not tracked."
  (let* ((buffer (find-file-buffer *vcs-test-untracked-file*))
         (root (tm-repo-root
                (directory-namestring *vcs-test-untracked-file*)))
         (relpath (and root
                       (tm-relative-path *vcs-test-untracked-file* root))))
    (switch-to-buffer buffer)
    (vcs-test-log
     (concatenate
      'string
      "UNTRACKED current=~a file=~a tracked=~a history=~a "
      "timemachine-live=~d")
     (vcs-test-yes-no (eq (current-buffer) buffer))
     (vcs-test-yes-no
      (and (buffer-filename buffer)
           (string= (namestring (pathname (buffer-filename buffer)))
                    (namestring (pathname *vcs-test-untracked-file*)))))
     (vcs-test-yes-no (and root relpath
                            (tm-tracked-file-p root relpath)))
     (vcs-test-yes-no (and root relpath
                            (tm-collect-history root relpath)))
     (count-if #'tm-buffer-p (buffer-list)))))

(defun vcs-test-hook-count (hook function)
  (count function hook :key #'car))

(defun vcs-test-reload-state ()
  (list
   :find (vcs-test-hook-count *find-file-hook*
                              'lem-yath-git-gutter-find-file)
   :post (vcs-test-hook-count *post-command-hook*
                              'lem-yath-git-gutter-post-command)
   :save (vcs-test-hook-count
          (variable-value 'after-save-hook :global t)
          'lem-yath-git-gutter-after-save)
   :change (vcs-test-hook-count
            (variable-value 'after-change-functions :global t)
            'lem-yath-git-gutter-after-change)
   :kill (vcs-test-hook-count
          (variable-value 'kill-buffer-hook :global t)
          'lem-yath-git-gutter-kill-buffer)
   :global-mode (count 'lem-git-gutter::git-gutter-mode
                       (lem-core::active-global-minor-modes))
   :source-mode (if (lem-yath-git-gutter-mode-active-p
                     *vcs-test-source-buffer*) 1 0)
   :directory (count #'lem-git-gutter::insert-git-status
                     lem/directory-mode::*file-entry-inserters*)
   :root-marker (count ".git" lem-core/commands/project:*root-files*
                       :test #'string=)
   :todo-hook (count 'insert-legit-todo-section
                     lem/legit::*status-bottom-section-functions*
                     :key #'car :test #'eq)
   :bisect-hook (count 'insert-legit-bisect-section
                       lem/legit::*status-section-functions*
                       :key #'car :test #'eq)
   :bisect (vcs-test-key-command lem/legit::*peek-legit-keymap* "B")
   :fetch (vcs-test-key-command lem/legit::*peek-legit-keymap* "f")
   :pull (vcs-test-key-command lem/legit::*peek-legit-keymap* "F")
   :log (vcs-test-key-command lem/legit::*peek-legit-keymap* "l")
   :reset (vcs-test-key-command lem/legit::*peek-legit-keymap* "O")
   :merge (vcs-test-key-command lem/legit::*peek-legit-keymap* "m")
   :revert (vcs-test-key-command lem/legit::*peek-legit-keymap* "_")
   :branch (vcs-test-key-command lem/legit::*peek-legit-keymap* "b")
   :worktree (vcs-test-key-command lem/legit::*peek-legit-keymap* "Z")
   :push (vcs-test-key-command lem/legit::*peek-legit-keymap* "p")
   :stash (vcs-test-key-command lem/legit::*peek-legit-keymap* "z")
   :remote (vcs-test-key-command lem/legit::*peek-legit-keymap* "M")
   :submodule (vcs-test-key-command lem/legit::*peek-legit-keymap* "'")
   :subtree (vcs-test-key-command lem/legit::*peek-legit-keymap* "\"")
   :log-commit (vcs-test-key-command
                *legit-log-commit-dispatch-keymap* "c")
   :log-amend (vcs-test-key-command
               *legit-log-commit-dispatch-keymap* "a")
   :message-continue (vcs-test-key-command
                      lem/legit::*legit-commit-mode-keymap* "C-c C-c")
   :message-abort (vcs-test-key-command
                   lem/legit::*legit-commit-mode-keymap* "C-c C-k")
   :smart (leader-binding-command lem-vi-mode:*normal-keymap* "g g")
   :git (leader-binding-command lem-vi-mode:*normal-keymap* "g G")
   :jj (leader-binding-command lem-vi-mode:*normal-keymap* "g J")
   :time (leader-binding-command lem-vi-mode:*normal-keymap* "g t")
   :jj-refresh (vcs-test-key-command *lem-yath-jj-view-keymap* "g r")
   :jj-quit (vcs-test-key-command *lem-yath-jj-view-keymap* "q")
   :older (vcs-test-key-command *lem-yath-timemachine-keymap* "C-k")
   :newer (vcs-test-key-command *lem-yath-timemachine-keymap* "C-j")
   :nth (vcs-test-key-command *lem-yath-timemachine-keymap* "g t g")
   :fuzzy (vcs-test-key-command *lem-yath-timemachine-keymap* "g t t")
   :short (vcs-test-key-command *lem-yath-timemachine-keymap* "g t y")
   :full (vcs-test-key-command *lem-yath-timemachine-keymap* "g t Y")
   :blame (vcs-test-key-command *lem-yath-timemachine-keymap* "g t b")
   :blame-quit (vcs-test-key-command
                *lem-yath-timemachine-blame-keymap* "q")
   :p (vcs-test-key-command *lem-yath-timemachine-keymap* "p")
   :n (vcs-test-key-command *lem-yath-timemachine-keymap* "n")
   :t (vcs-test-key-command *lem-yath-timemachine-keymap* "t")
   :quit (vcs-test-key-command *lem-yath-timemachine-keymap* "q")))

(define-command lem-yath-test-vcs-reload () ()
  (handler-case
      (let* ((before (vcs-test-reload-state))
             (source (asdf:system-source-directory "lem-yath")))
        (dotimes (index 2)
          (declare (ignore index))
          (load (merge-pathnames "src/git.lisp" source))
          (load (merge-pathnames "src/git-log-selection.lisp" source))
          (load (merge-pathnames "src/git-bisect.lisp" source))
          (load (merge-pathnames "src/git-fetch.lisp" source))
          (load (merge-pathnames "src/git-reset.lisp" source))
          (load (merge-pathnames "src/git-merge.lisp" source))
          (load (merge-pathnames "src/git-revert.lisp" source))
          (load (merge-pathnames "src/git-branch.lisp" source))
          (load (merge-pathnames "src/git-worktree.lisp" source))
          (load (merge-pathnames "src/git-push.lisp" source))
          (load (merge-pathnames "src/git-pull.lisp" source))
          (load (merge-pathnames "src/git-log.lisp" source))
          (load (merge-pathnames "src/git-stash.lisp" source))
          (load (merge-pathnames "src/git-remote.lisp" source))
          (load (merge-pathnames "src/git-submodule.lisp" source))
          (load (merge-pathnames "src/git-subtree.lisp" source))
          (load (merge-pathnames "src/git-log-actions.lisp" source))
          (load (merge-pathnames "src/git-blame.lisp" source))
          (load (merge-pathnames "src/apps/timemachine.lisp" source)))
        (let ((after (vcs-test-reload-state)))
          (vcs-test-log
           (concatenate
            'string
            "RELOAD same=~a find=~d post=~d save=~d change=~d kill=~d "
            "global=~d source=~d directory=~d root-marker=~d todo-hook=~d "
            "bisect-hook=~d bisect=~a fetch=~a pull=~a log=~a reset=~a merge=~a revert=~a branch=~a worktree=~a push=~a stash=~a remote=~a submodule=~a subtree=~a smart=~a git=~a jj=~a time=~a "
            "jj-refresh=~a jj-quit=~a "
            "older=~a newer=~a nth=~a fuzzy=~a short=~a full=~a blame=~a "
            "blame-quit=~a p=~a n=~a t=~a quit=~a")
           (vcs-test-yes-no (equal before after))
           (getf after :find)
           (getf after :post)
           (getf after :save)
           (getf after :change)
           (getf after :kill)
           (getf after :global-mode)
           (getf after :source-mode)
           (getf after :directory)
           (getf after :root-marker)
           (getf after :todo-hook)
           (getf after :bisect-hook)
           (vcs-test-yes-no
            (eq (getf after :bisect)
                'lem-yath-legit-bisect-or-todo-base))
           (vcs-test-yes-no
            (eq (getf after :fetch) 'lem-yath-legit-fetch))
           (vcs-test-yes-no
            (eq (getf after :pull) 'lem-yath-legit-pull))
           (vcs-test-yes-no
            (eq (getf after :log) 'lem-yath-legit-log))
           (vcs-test-yes-no
            (eq (getf after :reset) 'lem-yath-legit-reset))
           (vcs-test-yes-no
            (eq (getf after :merge) 'lem-yath-legit-merge))
           (vcs-test-yes-no
            (eq (getf after :revert) 'lem-yath-legit-revert))
           (vcs-test-yes-no
            (eq (getf after :branch)
                'lem-yath-legit-branch-or-todo-toggle))
           (vcs-test-yes-no
            (eq (getf after :worktree) 'lem-yath-legit-worktree))
           (vcs-test-yes-no
            (eq (getf after :push) 'lem-yath-legit-push))
           (vcs-test-yes-no
            (eq (getf after :stash) 'lem-yath-legit-stash))
           (vcs-test-yes-no
            (eq (getf after :remote) 'lem-yath-legit-remote))
           (vcs-test-yes-no
            (eq (getf after :submodule) 'lem-yath-legit-submodule))
           (vcs-test-yes-no
            (eq (getf after :subtree) 'lem-yath-legit-subtree))
           (vcs-test-yes-no (eq (getf after :smart) 'lem-yath-vcs-status))
           (vcs-test-yes-no (eq (getf after :git) 'lem-yath-legit-status))
           (vcs-test-yes-no (eq (getf after :jj) 'lem-yath-jj-log))
           (vcs-test-yes-no
            (eq (getf after :time) 'lem-yath-git-timemachine))
           (vcs-test-yes-no
            (eq (getf after :jj-refresh) 'lem-yath-jj-refresh))
           (vcs-test-yes-no
            (eq (getf after :jj-quit) 'lem-yath-jj-quit))
           (vcs-test-yes-no
            (eq (getf after :older) 'lem-yath-timemachine-older))
           (vcs-test-yes-no
            (eq (getf after :newer) 'lem-yath-timemachine-newer))
           (vcs-test-yes-no (getf after :nth))
           (vcs-test-yes-no (getf after :fuzzy))
           (vcs-test-yes-no (getf after :short))
           (vcs-test-yes-no (getf after :full))
           (vcs-test-yes-no (getf after :blame))
           (vcs-test-yes-no (getf after :blame-quit))
           (vcs-test-yes-no (null (getf after :p)))
           (vcs-test-yes-no (null (getf after :n)))
           (vcs-test-yes-no (null (getf after :t)))
           (vcs-test-yes-no
            (eq (getf after :quit) 'lem-yath-timemachine-quit)))))
    (error (condition)
      (vcs-test-log "RELOAD error=~a"
                    (vcs-test-encode (princ-to-string condition))))))

(define-key *global-keymap* "F1" 'lem-yath-test-vcs-static)
(define-key *global-keymap* "F2" 'lem-yath-test-vcs-gutter)
(define-key *global-keymap* "F3" 'lem-yath-test-vcs-dispatch-state)
(define-key *global-keymap* "F4" 'lem-yath-test-vcs-legit-and-bisect-state)
(define-key *global-keymap* "F5" 'lem-yath-test-vcs-history-view-state)
(define-key *global-keymap* "F6" 'lem-yath-test-vcs-restore-source)
(define-key *global-keymap* "F7" 'lem-yath-test-vcs-source-state)
(define-key *global-keymap* "F8" 'lem-yath-test-vcs-reload)
(define-key *global-keymap* "F9" 'lem-yath-test-vcs-roots)
(define-key *global-keymap* "F10" 'lem-yath-test-vcs-prepare-invocation)
(define-key *global-keymap* "F11" 'lem-yath-test-vcs-detour-timemachine)
(defun vcs-test-load-prompt-input ()
  (let ((path (uiop:getenv "LEM_YATH_VCS_PROMPT_INPUT")))
    (when (and path (probe-file path))
      (let ((value (uiop:read-file-string path)))
        (when (plusp (length value))
          (lem/common/killring:push-killring-item
           (current-killring) value)
          t)))))

(define-command lem-yath-test-vcs-f12 () ()
  "Report debounce state or load the acceptance driver's prompt value."
  (unless (vcs-test-load-prompt-input)
    (lem-yath-test-vcs-debounce-state)))

(define-key *global-keymap* "F12" 'lem-yath-test-vcs-f12)
(define-key *global-keymap* "C-c u" 'lem-yath-test-vcs-untracked-state)
(define-key *global-keymap* "C-c h"
  'lem-yath-test-vcs-timemachine-extra-state)
(define-key *global-keymap* "C-c t" 'lem-yath-test-vcs-todo-preview)
(define-key *global-keymap* "C-c T" 'lem-yath-test-vcs-todo-sections)
(define-key *global-keymap* "C-c P" 'lem-yath-test-vcs-position-todo-heading)
(define-key *global-keymap* "C-c O" 'lem-yath-test-vcs-status-context)
(define-key *global-keymap* "C-c Q" 'lem-yath-test-vcs-todo-list-state)
(define-key *global-keymap* "C-c d" 'lem-yath-test-vcs-porcelain-diff)
(define-key *global-keymap* "C-c e" 'lem-yath-test-vcs-porcelain-staged-diff)
(define-key *global-keymap* "C-c f" 'lem-yath-test-vcs-focus-legit)
(define-key *global-keymap* "C-c w" 'lem-yath-test-vcs-porcelain-region)
(define-key *global-keymap* "C-c W" 'lem-yath-test-vcs-porcelain-staged-region)
(define-key *global-keymap* "C-c m" 'lem-yath-test-vcs-porcelain-tracked)
(define-key *global-keymap* "C-c a" 'lem-yath-test-vcs-porcelain-untracked)
(define-key *global-keymap* "C-c r" 'lem-yath-test-vcs-porcelain-commit)
(define-key *global-keymap* "C-c v" 'lem-yath-test-vcs-rebase-state)
(define-key *global-keymap* "C-c y" 'lem-yath-test-vcs-cherry-state)
(define-key *global-keymap* "C-c Y" 'lem-yath-test-vcs-cherry-position)
(define-key *global-keymap* "C-c L" 'lem-yath-test-vcs-log-action-state)
(define-key lem/legit::*peek-legit-keymap*
  "C-c t" 'lem-yath-test-vcs-todo-preview)
(define-key lem/legit::*peek-legit-keymap*
  "C-c T" 'lem-yath-test-vcs-todo-sections)
(define-key lem/legit::*peek-legit-keymap*
  "C-c P" 'lem-yath-test-vcs-position-todo-heading)
(define-key lem/legit::*peek-legit-keymap*
  "C-c O" 'lem-yath-test-vcs-status-context)
(define-key lem/legit::*peek-legit-keymap*
  "C-c Q" 'lem-yath-test-vcs-todo-list-state)
(define-key lem/legit::*peek-legit-keymap*
  "C-c d" 'lem-yath-test-vcs-porcelain-diff)
(define-key lem/legit::*peek-legit-keymap*
  "C-c e" 'lem-yath-test-vcs-porcelain-staged-diff)
(define-key lem/legit::*peek-legit-keymap*
  "C-c w" 'lem-yath-test-vcs-porcelain-region)
(define-key lem/legit::*peek-legit-keymap*
  "C-c W" 'lem-yath-test-vcs-porcelain-staged-region)
(define-key lem/legit::*peek-legit-keymap*
  "C-c m" 'lem-yath-test-vcs-porcelain-tracked)
(define-key lem/legit::*peek-legit-keymap*
  "C-c a" 'lem-yath-test-vcs-porcelain-untracked)
(define-key lem/legit::*peek-legit-keymap*
  "C-c r" 'lem-yath-test-vcs-porcelain-commit)
(define-key lem/legit::*peek-legit-keymap*
  "C-c y" 'lem-yath-test-vcs-cherry-state)
(define-key lem/legit::*peek-legit-keymap*
  "C-c Y" 'lem-yath-test-vcs-cherry-position)
(define-key lem/legit::*legit-commits-log-keymap*
  "C-c L" 'lem-yath-test-vcs-log-action-state)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c d" 'lem-yath-test-vcs-porcelain-diff)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c e" 'lem-yath-test-vcs-porcelain-staged-diff)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c w" 'lem-yath-test-vcs-porcelain-region)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c W" 'lem-yath-test-vcs-porcelain-staged-region)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c m" 'lem-yath-test-vcs-porcelain-tracked)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c a" 'lem-yath-test-vcs-porcelain-untracked)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c y" 'lem-yath-test-vcs-cherry-state)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c Y" 'lem-yath-test-vcs-cherry-position)
(define-key lem/legit::*legit-rebase-mode-keymap*
  "C-c v" 'lem-yath-test-vcs-rebase-state)
(define-key lem/legit::*legit-commit-mode-keymap*
  "C-c v" 'lem-yath-test-vcs-reword-state)

(vcs-test-log "READY phase=~a file=~a"
              *vcs-test-phase*
              (vcs-test-encode
               (or (and (buffer-filename (current-buffer))
                        (namestring (buffer-filename (current-buffer))))
                   "none")))
