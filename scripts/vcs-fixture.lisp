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
                    (if (zerop failures) "PASS" "FAIL") failures))))

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
      (unless (search-forward todo-point "nested/deeper/todos.txt:1:")
        (setf todo-point nil))
      (when todo-point (line-start todo-point)))
    (vcs-test-log
     (concatenate
      'string
      "LEGIT phase=~a active=~a source-live=~a raw-exact=~a "
      "raw-sentinel=~a todos=~a todo-count=~a todo-properties=~a "
      "todo-hook=~d current=~a")
     *vcs-test-phase*
     (vcs-test-yes-no active)
     (vcs-test-yes-no (and *vcs-test-source-buffer*
                           (not (deleted-buffer-p *vcs-test-source-buffer*))))
     (vcs-test-yes-no (vcs-test-source-raw-exact-p))
     (vcs-test-yes-no (vcs-test-source-raw-sentinel-p))
     (vcs-test-yes-no (and text (search "TODO/FIXME (2):" text)))
     (vcs-test-yes-no
      (and text
           (search "nested/deeper/todos.txt:1:" text)
           (search "nested/docs/fixmes.txt:1:" text)))
     (vcs-test-yes-no
      (and todo-point
           (lem/legit::get-move-function todo-point)
           (lem/legit::get-visit-file-function todo-point)))
     (count 'insert-legit-todo-section
            lem/legit::*status-section-functions*
            :key #'car :test #'eq)
     (vcs-test-encode (buffer-name (current-buffer))))))

(define-command lem-yath-test-vcs-todo-preview () ()
  (let* ((buffer (and (lem/legit::legit-status-active-p)
                      (window-buffer lem/legit::*peek-window*)))
         (row (and buffer (buffer-start-point buffer))))
    (when row
      (unless (search-forward row "nested/deeper/todos.txt:1:")
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
             (string= (funcall visit) "nested/deeper/todos.txt")))
       (if (and source-buffer (buffer-filename source-buffer))
           (file-namestring (buffer-filename source-buffer))
           "none")
       (if source (line-number-at-point source) "none")
       (vcs-test-yes-no
        (and source-buffer
             (search "TODO tracked implementation task"
                     (buffer-text source-buffer))))))))

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

(define-command lem-yath-test-vcs-porcelain-tracked () ()
  (vcs-test-position-legit-file "porcelain.txt"))

(define-command lem-yath-test-vcs-porcelain-untracked () ()
  (vcs-test-position-legit-file "untracked.txt"))

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
                     lem/legit::*status-section-functions*
                     :key #'car :test #'eq)
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
          (load (merge-pathnames "src/apps/timemachine.lisp" source)))
        (let ((after (vcs-test-reload-state)))
          (vcs-test-log
           (concatenate
            'string
            "RELOAD same=~a find=~d post=~d save=~d change=~d kill=~d "
            "global=~d source=~d directory=~d root-marker=~d todo-hook=~d "
            "smart=~a git=~a jj=~a time=~a jj-refresh=~a jj-quit=~a "
            "older=~a newer=~a nth=~a "
            "fuzzy=~a p=~a n=~a t=~a quit=~a")
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
(define-key *global-keymap* "F4" 'lem-yath-test-vcs-legit-state)
(define-key *global-keymap* "F5" 'lem-yath-test-vcs-timemachine-state)
(define-key *global-keymap* "F6" 'lem-yath-test-vcs-restore-source)
(define-key *global-keymap* "F7" 'lem-yath-test-vcs-source-state)
(define-key *global-keymap* "F8" 'lem-yath-test-vcs-reload)
(define-key *global-keymap* "F9" 'lem-yath-test-vcs-roots)
(define-key *global-keymap* "F10" 'lem-yath-test-vcs-prepare-invocation)
(define-key *global-keymap* "F11" 'lem-yath-test-vcs-detour-timemachine)
(define-key *global-keymap* "F12" 'lem-yath-test-vcs-debounce-state)
(define-key *global-keymap* "C-c u" 'lem-yath-test-vcs-untracked-state)
(define-key *global-keymap* "C-c t" 'lem-yath-test-vcs-todo-preview)
(define-key *global-keymap* "C-c d" 'lem-yath-test-vcs-porcelain-diff)
(define-key *global-keymap* "C-c e" 'lem-yath-test-vcs-porcelain-staged-diff)
(define-key *global-keymap* "C-c m" 'lem-yath-test-vcs-porcelain-tracked)
(define-key *global-keymap* "C-c a" 'lem-yath-test-vcs-porcelain-untracked)
(define-key lem/legit::*peek-legit-keymap*
  "C-c t" 'lem-yath-test-vcs-todo-preview)
(define-key lem/legit::*peek-legit-keymap*
  "C-c d" 'lem-yath-test-vcs-porcelain-diff)
(define-key lem/legit::*peek-legit-keymap*
  "C-c e" 'lem-yath-test-vcs-porcelain-staged-diff)
(define-key lem/legit::*peek-legit-keymap*
  "C-c m" 'lem-yath-test-vcs-porcelain-tracked)
(define-key lem/legit::*peek-legit-keymap*
  "C-c a" 'lem-yath-test-vcs-porcelain-untracked)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c d" 'lem-yath-test-vcs-porcelain-diff)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c e" 'lem-yath-test-vcs-porcelain-staged-diff)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c m" 'lem-yath-test-vcs-porcelain-tracked)
(define-key lem/legit::*legit-diff-mode-keymap*
  "C-c a" 'lem-yath-test-vcs-porcelain-untracked)

(vcs-test-log "READY phase=~a file=~a"
              *vcs-test-phase*
              (vcs-test-encode
               (or (and (buffer-filename (current-buffer))
                        (namestring (buffer-filename (current-buffer))))
                   "none")))
