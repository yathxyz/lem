;;;; Evil-Collection-compatible Magit submodule dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-submodule-timeout* 120)
(defparameter *legit-submodule-output-limit* (* 4 1024 1024))
(defparameter *legit-submodule-candidate-limit* 5000)
(defparameter *legit-submodule-value-limit* 4096)

(defvar *legit-submodule-value-history* nil)
(defvar *legit-submodule-dispatch-window* nil)

(defstruct legit-submodule
  name path url)

(defstruct legit-submodule-options
  force-p recursive-p no-fetch-p strategy remote-p)

(defun legit-submodule-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Submodule commands are available only in a Git repository.")))

(defun legit-submodule-run-program (arguments)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-submodule-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :output-limit *legit-submodule-output-limit*)))

(defun legit-submodule-checked-output (arguments)
  (multiple-value-bind (output error-output status)
      (legit-submodule-run-program arguments)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    output))

(defun legit-submodule-optional-output (arguments)
  (multiple-value-bind (output error-output status)
      (legit-submodule-run-program arguments)
    (cond
      ((and (integerp status) (zerop status)) output)
      ((eql status 1) nil)
      (t (editor-error "~a" (legit-command-error-text output error-output))))))

(defun legit-submodule-refresh ()
  (let ((window (or *legit-submodule-dispatch-window* (current-window))))
    (lem/legit::show-legit-status)
    (when (and window (not (deleted-window-p window)))
      (setf (current-window) window))))

(defun legit-submodule-run (arguments success-message)
  (multiple-value-bind (output error-output status)
      (legit-submodule-run-program arguments)
    (legit-submodule-refresh)
    (if (and (integerp status) (zerop status))
        (progn (message "~a" success-message) t)
        (progn
          (lem/legit::pop-up-message
           (legit-command-error-text output error-output))
          nil))))

(defun legit-submodule-value-valid-p (value description)
  (when (or (null value) (str:blankp value))
    (editor-error "A ~a is required." description))
  (when (> (length value) *legit-submodule-value-limit*)
    (editor-error "The ~a is limited to 4096 characters." description))
  (when (or (find (code-char 0) value) (find #\Newline value))
    (editor-error "The ~a cannot contain NUL or a newline." description))
  (when (char= (char value 0) #\-)
    (editor-error "The ~a cannot begin with an option marker." description))
  value)

(defun legit-submodule-path-valid-p (path)
  "Return true for a bounded relative path which cannot escape its root."
  (and (stringp path)
       (str:non-blank-string-p path)
       (<= (length path) *legit-submodule-value-limit*)
       (not (find (code-char 0) path))
       (not (find #\Newline path))
       (char/= (char path 0) #\/)
       (let ((components (uiop:split-string path :separator "/")))
         (and components
              (not (some (lambda (component)
                           (member component '("" "." ".." ".git")
                                   :test #'string=))
                         components))))))

(defun legit-submodule-validate-path (path)
  (unless (legit-submodule-path-valid-p path)
    (editor-error "The submodule path must be a bounded relative path without .git, . or .. components."))
  path)

(defun legit-submodule-config-value (arguments)
  (alexandria:when-let ((output (legit-submodule-optional-output arguments)))
    (string-right-trim '(#\Newline #\Return) output)))

(defun legit-submodule-modules ()
  "Read bounded submodule declarations from .gitmodules."
  (unless (probe-file (merge-pathnames ".gitmodules" (uiop:getcwd)))
    (return-from legit-submodule-modules nil))
  (let* ((output
           (legit-submodule-optional-output
            '("config" "-z" "--file" ".gitmodules" "--name-only"
              "--get-regexp" "^submodule\\..*\\.path$")))
         (keys (if output (project-split-nul output) nil)))
    (when (> (length keys) *legit-submodule-candidate-limit*)
      (editor-error "Git returned more than ~d submodules."
                    *legit-submodule-candidate-limit*))
    (loop
      :for key :in keys
      :for prefix := "submodule."
      :for suffix := ".path"
      :when (and (alexandria:starts-with-subseq prefix key)
                 (alexandria:ends-with-subseq suffix key))
        :collect
        (let* ((name (subseq key (length prefix)
                             (- (length key) (length suffix))))
               (path
                 (legit-submodule-config-value
                  (list "config" "--file" ".gitmodules" "--get" key)))
               (url
                 (legit-submodule-config-value
                  (list "config" "--file" ".gitmodules" "--get"
                        (format nil "submodule.~a.url" name)))))
          (legit-submodule-value-valid-p name "submodule name")
          (legit-submodule-validate-path path)
          (when url (legit-submodule-value-valid-p url "submodule URL"))
          (make-legit-submodule :name name :path path :url url)))))

(defun legit-submodule-root ()
  (uiop:ensure-directory-pathname (uiop:getcwd)))

(defun legit-submodule-directory (module &optional (root (legit-submodule-root)))
  (uiop:ensure-directory-pathname
   (merge-pathnames (legit-submodule-path module) root)))

(defun legit-submodule-populated-p (module)
  (probe-file (merge-pathnames ".git" (legit-submodule-directory module))))

(defun legit-submodule-registered-p (module)
  (not (null
        (legit-submodule-config-value
         (list "config" "--get"
               (format nil "submodule.~a.url" (legit-submodule-name module)))))))

(defun legit-submodule-read (prompt predicate)
  (let* ((modules (remove-if-not predicate (legit-submodule-modules)))
         (paths (mapcar #'legit-submodule-path modules)))
    (unless modules
      (editor-error "There are no eligible submodules for this action."))
    (let ((path
            (prompt-for-string
             prompt
             :initial-value (if (= (length paths) 1) (first paths) "")
             :history-symbol '*legit-submodule-value-history*
             :completion-function
             (lambda (query) (completion-strings query paths))
             :test-function
             (lambda (value) (member value paths :test #'string=)))))
      (find path modules :key #'legit-submodule-path :test #'string=))))

(defun legit-submodule-default-name (url)
  (let* ((trimmed (string-right-trim "/" url))
         (slash (position #\/ trimmed :from-end t))
         (colon (position #\: trimmed :from-end t))
         (start (1+ (max (or slash -1) (or colon -1))))
         (base (subseq trimmed start)))
    (if (and (> (length base) 4)
             (alexandria:ends-with-subseq ".git" base))
        (subseq base 0 (- (length base) 4))
        base)))

(defun legit-submodule-add (options)
  (alexandria:when-let
      ((url
         (prompt-for-string "Submodule URL: "
                            :history-symbol '*legit-submodule-value-history*)))
    (legit-submodule-value-valid-p url "submodule URL")
    (let ((default (legit-submodule-default-name url)))
      (alexandria:when-let
          ((path
             (prompt-for-string "Submodule path: " :initial-value default
                                :history-symbol '*legit-submodule-value-history*)))
        (legit-submodule-validate-path path)
        (alexandria:when-let
            ((name
               (prompt-for-string "Submodule name: " :initial-value default
                                  :history-symbol '*legit-submodule-value-history*)))
          (legit-submodule-value-valid-p name "submodule name")
          (legit-submodule-run
           (append '("submodule" "add")
                   (when (legit-submodule-options-force-p options) '("--force"))
                   (list "--name" name "--" url path))
           (format nil "Added submodule ~a." path)))))))

(defun legit-submodule-register ()
  (alexandria:when-let
      ((module (legit-submodule-read "Register submodule: "
                                     (complement #'legit-submodule-registered-p))))
    (legit-submodule-run
     (list "submodule" "init" "--" (legit-submodule-path module))
     (format nil "Registered submodule ~a." (legit-submodule-path module)))))

(defun legit-submodule-populate (options)
  (alexandria:when-let
      ((module (legit-submodule-read "Populate submodule: "
                                     (complement #'legit-submodule-populated-p))))
    (legit-submodule-run
     (append '("submodule" "update" "--init")
             (when (legit-submodule-options-recursive-p options)
               '("--recursive"))
             (list "--" (legit-submodule-path module)))
     (format nil "Populated submodule ~a." (legit-submodule-path module)))))

(defun legit-submodule-update-arguments (options)
  (append
   (when (legit-submodule-options-force-p options) '("--force"))
   (when (legit-submodule-options-recursive-p options) '("--recursive"))
   (when (legit-submodule-options-no-fetch-p options) '("--no-fetch"))
   (case (legit-submodule-options-strategy options)
     (:checkout '("--checkout")) (:rebase '("--rebase")) (:merge '("--merge")))
   (when (legit-submodule-options-remote-p options) '("--remote"))))

(defun legit-submodule-update (options)
  (alexandria:when-let
      ((module (legit-submodule-read "Update submodule: "
                                     #'legit-submodule-populated-p)))
    (legit-submodule-run
     (append '("submodule" "update")
             (legit-submodule-update-arguments options)
             (list "--" (legit-submodule-path module)))
     (format nil "Updated submodule ~a." (legit-submodule-path module)))))

(defun legit-submodule-synchronize (options)
  (alexandria:when-let
      ((module (legit-submodule-read "Synchronize submodule: "
                                     #'legit-submodule-populated-p)))
    (legit-submodule-run
     (append '("submodule" "sync")
             (when (legit-submodule-options-recursive-p options)
               '("--recursive"))
             (list "--" (legit-submodule-path module)))
     (format nil "Synchronized submodule ~a." (legit-submodule-path module)))))

(defun legit-submodule-unpopulate (options)
  (alexandria:when-let
      ((module (legit-submodule-read "Unpopulate submodule: "
                                     #'legit-submodule-populated-p)))
    (let ((path (legit-submodule-path module)))
      (when (prompt-for-y-or-n-p (format nil "Unpopulate submodule ~a? " path))
        (legit-submodule-run
         (append '("submodule" "deinit")
                 (when (legit-submodule-options-force-p options) '("--force"))
                 (list "--" path))
         (format nil "Unpopulated submodule ~a." path))))))

(defun legit-submodule-dirty-p (module)
  (let ((directory (uiop:native-namestring
                    (legit-submodule-directory module))))
    (str:non-blank-string-p
     (legit-submodule-checked-output
      (list "-C" directory "status" "--porcelain"
            "--untracked-files=all")))))

(defun legit-submodule-remove (options)
  (alexandria:when-let
      ((module (legit-submodule-read "Remove submodule: " (constantly t))))
    (let* ((path (legit-submodule-path module))
           (dirty-p (and (legit-submodule-populated-p module)
                         (legit-submodule-dirty-p module))))
      (when (and dirty-p (not (legit-submodule-options-force-p options)))
        (editor-error "Submodule ~a is dirty; enable -f to preserve it in a stash before removal." path))
      (when (prompt-for-y-or-n-p (format nil "Remove submodule ~a? " path))
        (when (and dirty-p
                   (not (prompt-for-y-or-n-p
                         (format nil "Stash dirty content and force removal of ~a? " path))))
          (return-from legit-submodule-remove nil))
        (when dirty-p
          (legit-submodule-checked-output
           (list "-C" (uiop:native-namestring
                        (legit-submodule-directory module))
                 "stash" "push" "--include-untracked"
                 "--message" "lem-yath submodule removal backup")))
        ;; Preserve the module repository under .git/modules, matching Magit's
        ;; normal remove action rather than its prefix-only trash-gitdirs path.
        (when (legit-submodule-populated-p module)
          (legit-submodule-checked-output
           (list "submodule" "absorbgitdirs" "--" path))
          (legit-submodule-checked-output
           (append '("submodule" "deinit")
                   (when (legit-submodule-options-force-p options) '("--force"))
                   (list "--" path))))
        (legit-submodule-run
         (append '("rm")
                 (when (legit-submodule-options-force-p options) '("--force"))
                 (list "--" path))
         (format nil "Removed submodule ~a; its Git directory was preserved." path))))))

(defun legit-submodule-status-text (module)
  (let* ((directory (uiop:native-namestring
                     (legit-submodule-directory module)))
         (hash (or (legit-submodule-config-value
                    (list "-C" directory "rev-parse" "--short" "HEAD"))
                   "unknown"))
         (branch (or (legit-submodule-config-value
                      (list "-C" directory "symbolic-ref" "--short" "HEAD"))
                     "detached"))
         (dirty (legit-submodule-dirty-p module)))
    (format nil "~a  ~a  ~a~:[~;  dirty~]"
            (legit-submodule-path module) branch hash dirty)))

(defun legit-submodule-list ()
  "Show a bounded textual list of populated modules without leaving Legit."
  (let ((modules (remove-if-not #'legit-submodule-populated-p
                                (legit-submodule-modules))))
    (unless modules
      (editor-error "There are no populated submodules."))
    (lem/legit::pop-up-message
     (format nil "Populated submodules:~%~{~a~^~%~}"
             (mapcar #'legit-submodule-status-text modules)))))

(defun legit-submodule-fetch ()
  (legit-submodule-run
   '("fetch" "--recurse-submodules" "--verbose" "--jobs=4")
   "Fetched repository and populated submodules."))

(defun legit-submodule-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-submodule-popup-keymap (options)
  (let ((keymap (make-keymap :description "Submodule")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          `(("- f" ,(format nil "[~a] force"
                             (if (legit-submodule-options-force-p options) "x" " ")))
            ("- r" ,(format nil "[~a] recursive"
                             (if (legit-submodule-options-recursive-p options) "x" " ")))
            ("- N" ,(format nil "[~a] do not fetch"
                             (if (legit-submodule-options-no-fetch-p options) "x" " ")))
            ("- C" ,(format nil "[~a] checkout tip"
                             (if (eq (legit-submodule-options-strategy options) :checkout) "x" " ")))
            ("- R" ,(format nil "[~a] rebase onto tip"
                             (if (eq (legit-submodule-options-strategy options) :rebase) "x" " ")))
            ("- M" ,(format nil "[~a] merge tip"
                             (if (eq (legit-submodule-options-strategy options) :merge) "x" " ")))
            ("- U" ,(format nil "[~a] use upstream tip"
                             (if (legit-submodule-options-remote-p options) "x" " ")))
            ("a" "add") ("r" "register") ("p" "populate")
            ("u" "update") ("s" "synchronize") ("d" "unpopulate")
            ("k" "remove") ("l" "list modules") ("f" "fetch modules")
            ("q" "cancel")))
      (legit-submodule-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun legit-submodule-read-popup-key ()
  (let* ((first (read-key))
         (name (lem-core::keyseq-to-string (list first))))
    (if (string= name "-")
        (format nil "- ~a"
                (lem-core::keyseq-to-string (list (read-key))))
        name)))

(defun legit-submodule-toggle-strategy (options strategy)
  (setf (legit-submodule-options-strategy options)
        (unless (eq (legit-submodule-options-strategy options) strategy)
          strategy)))

(defun dispatch-legit-submodule ()
  (let ((options (make-legit-submodule-options))
        (*legit-submodule-dispatch-window* (current-window)))
    (unwind-protect
         (loop
           :for keymap := (legit-submodule-popup-keymap options)
           :do
              (let ((lem/transient:*transient-popup-delay* 0))
                (keymap-activate keymap))
              (redraw-display)
              (let ((name (legit-submodule-read-popup-key)))
                (lem/transient::hide-transient)
                (cond
                  ((or (string= name "q") (string= name "Escape"))
                   (message "Submodule dispatch cancelled.") (return nil))
                  ((string= name "- f")
                   (setf (legit-submodule-options-force-p options)
                         (not (legit-submodule-options-force-p options))))
                  ((string= name "- r")
                   (setf (legit-submodule-options-recursive-p options)
                         (not (legit-submodule-options-recursive-p options))))
                  ((string= name "- N")
                   (setf (legit-submodule-options-no-fetch-p options)
                         (not (legit-submodule-options-no-fetch-p options))))
                  ((string= name "- U")
                   (setf (legit-submodule-options-remote-p options)
                         (not (legit-submodule-options-remote-p options))))
                  ((string= name "- C") (legit-submodule-toggle-strategy options :checkout))
                  ((string= name "- R") (legit-submodule-toggle-strategy options :rebase))
                  ((string= name "- M") (legit-submodule-toggle-strategy options :merge))
                  ((string= name "a") (legit-submodule-add options) (return t))
                  ((string= name "r") (legit-submodule-register) (return t))
                  ((string= name "p") (legit-submodule-populate options) (return t))
                  ((string= name "u") (legit-submodule-update options) (return t))
                  ((string= name "s") (legit-submodule-synchronize options) (return t))
                  ((string= name "d") (legit-submodule-unpopulate options) (return t))
                  ((string= name "k") (legit-submodule-remove options) (return t))
                  ((string= name "l") (legit-submodule-list) (return t))
                  ((string= name "f") (legit-submodule-fetch) (return t))
                  (t (message "No submodule action is bound to ~a" name)
                     (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-submodule () ()
  "Open the configured Magit-compatible Git submodule transient."
  (lem/legit::with-current-project (vcs)
    (legit-submodule-require-git vcs)
    (dispatch-legit-submodule)))

;; Reset all maps before binding so a source reload is deterministic.
(undefine-key lem/legit::*peek-legit-keymap* "'")
(undefine-key lem/legit::*legit-diff-mode-keymap* "'")
(define-key lem/legit::*peek-legit-keymap* "'" 'lem-yath-legit-submodule)
(define-key lem/legit::*legit-diff-mode-keymap* "'" 'lem-yath-legit-submodule)
