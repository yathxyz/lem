;;;; Project navigation: project.el + Consult-style project workflows.

(in-package :lem-yath)

(defparameter *project-switch-directory-choice* "… (choose a dir)"
  "Synthetic project-switch candidate that opens a directory prompt.")

(defparameter *project-rg-ignored-directories*
  '("SCCS" "RCS" "CVS" "MCVS" ".src" ".svn" ".git" ".hg" ".bzr"
    "_MTN" "_darcs" "{arch}" "node_modules" "build" "dist")
  "Directory names excluded by project regexp searches, matching Emacs.")

(defparameter *project-process-timeout* 30
  "Maximum seconds allowed for project discovery and search subprocesses.")

(defparameter *project-process-output-limit* (* 32 1024 1024)
  "Maximum characters retained from a project discovery subprocess.")

(defparameter *project-grep-output-limit* (* 4 1024 1024)
  "Maximum characters retained from one project regexp search.")

(defparameter *project-file-candidate-limit* 100000
  "Maximum file candidates offered by one project prompt.")

(defparameter *project-grep-result-limit* 5000
  "Maximum match rows rendered by one project regexp search.")

(defparameter *project-rg-batch-size* 256
  "Maximum project files passed to one ripgrep process.")

(defparameter *project-rg-batch-character-limit* 65536
  "Maximum combined filename characters passed to one ripgrep process.")

(defvar *project-grep-last-pattern* ""
  "Last regexp submitted through the project search command.")

(defvar *project-file-request-generation* 0)
(defvar *project-grep-request-generation* 0)
(defvar *active-project-file-request* nil)
(defvar *active-project-grep-request* nil)

(defstruct project-request-origin
  buffer
  window)

(define-condition project-request-cancelled (condition) ())

(defstruct (project-request
            (:constructor %make-project-request (generation origin)))
  generation
  origin
  (cancelled-p nil)
  process
  (lock (bt2:make-lock :name "lem-yath/project-request")))

(defun capture-project-request-origin ()
  (make-project-request-origin :buffer (current-buffer)
                               :window (current-window)))

(defun project-request-origin-current-p (origin)
  (and (not (deleted-buffer-p (project-request-origin-buffer origin)))
       (not (deleted-window-p (project-request-origin-window origin)))
       (eq (project-request-origin-buffer origin) (current-buffer))
       (eq (project-request-origin-window origin) (current-window))))

(defun make-live-project-request (generation origin)
  (%make-project-request generation origin))

(defun project-request-live-p (request)
  "Whether REQUEST may still launch work or publish a result."
  (bt2:with-lock-held ((project-request-lock request))
    (not (project-request-cancelled-p request))))

(defun cancel-project-request (request)
  "Cancel REQUEST and terminate only the subprocess owned by REQUEST."
  (let ((process nil))
    (bt2:with-lock-held ((project-request-lock request))
      (unless (project-request-cancelled-p request)
        (setf (project-request-cancelled-p request) t
              process (project-request-process request)
              (project-request-process request) nil)))
    (when process
      (ignore-errors (uiop:terminate-process process)))
    (not (null process))))

(defun active-project-request (kind)
  (ecase kind
    (:file *active-project-file-request*)
    (:grep *active-project-grep-request*)))

(defun (setf active-project-request) (request kind)
  (ecase kind
    (:file (setf *active-project-file-request* request))
    (:grep (setf *active-project-grep-request* request)))
  request)

(defun activate-project-request (kind request)
  "Make REQUEST active for KIND after cancelling the previous request."
  (alexandria:when-let ((previous (active-project-request kind)))
    (cancel-project-request previous))
  (setf (active-project-request kind) request))

(defun current-project-request-p (kind request)
  (and (eq request (active-project-request kind))
       (project-request-live-p request)))

(defun clear-active-project-request (kind request)
  (when (eq request (active-project-request kind))
    (setf (active-project-request kind) nil)))

(defun cancel-pending-project-requests ()
  "Invalidate background project work before the user's next command."
  (alexandria:when-let ((request *active-project-file-request*))
    (setf *active-project-file-request* nil)
    (incf *project-file-request-generation*)
    (cancel-project-request request))
  (alexandria:when-let ((request *active-project-grep-request*))
    (setf *active-project-grep-request* nil)
    (incf *project-grep-request-generation*)
    (cancel-project-request request)))

(defun canonical-project-directory (directory)
  "Return existing DIRECTORY as a canonical directory pathname."
  (uiop:ensure-directory-pathname
   (truename (uiop:ensure-directory-pathname directory))))

(defun project-native-directory (directory)
  "Return the canonical native namestring for DIRECTORY, ending in a slash."
  (uiop:native-namestring (canonical-project-directory directory)))

(defun project-path-in-directory-p (path directory)
  "Whether existing PATH is DIRECTORY or lies below it, resolving symlinks."
  (handler-case
      (let ((root (project-native-directory directory))
            (path (uiop:native-namestring (truename path))))
        (or (string= path (string-right-trim "/" root))
            (alexandria:starts-with-subseq root path)))
    (error () nil)))

(defun project-timeout-command (arguments)
  "Prefix argv list ARGUMENTS with a hard GNU timeout."
  (let ((timeout (or (executable-find "timeout")
                     (error "GNU timeout is unavailable; refusing an unbounded project command"))))
    (append (list (namestring timeout)
                  "--signal=TERM"
                  "--kill-after=1"
                  (princ-to-string *project-process-timeout*))
            arguments)))

(defun read-project-process-output (stream process limit)
  "Read STREAM up to LIMIT characters, terminating PROCESS on overflow."
  (let ((buffer (make-string 8192))
        (count 0)
        (output (make-string-output-stream)))
    (loop :for length := (read-sequence buffer stream)
          :until (zerop length)
          :do (incf count length)
              (when (> count limit)
                ;; TERM lets GNU timeout propagate cancellation to its child.
                (ignore-errors (uiop:terminate-process process))
                (error "Project command produced more than ~d characters" limit))
              (write-sequence buffer output :end length))
    (get-output-stream-string output)))

(defun launch-project-process
    (arguments directory request &key input environment)
  "Launch ARGUMENTS and atomically assign the process to REQUEST.

INPUT is an optional character stream.  ENVIRONMENT is an optional SBCL-style
list of NAME=VALUE strings captured by the editor thread."
  (flet ((start-process ()
           (apply #'uiop:launch-program
                  (project-timeout-command arguments)
                  :directory directory
                  :output :stream
                  :error-output :stream
                  (append (when input (list :input input))
                          (when environment
                            (list :environment environment))))))
    (if request
        (bt2:with-lock-held ((project-request-lock request))
          (when (project-request-cancelled-p request)
            (error 'project-request-cancelled))
          (setf (project-request-process request) (start-process)))
        (start-process))))

(defun release-project-process (request process)
  "Forget PROCESS only when it is still the subprocess owned by REQUEST."
  (when request
    (bt2:with-lock-held ((project-request-lock request))
      (when (eq process (project-request-process request))
        (setf (project-request-process request) nil)))))

(defun run-project-program
    (arguments &key directory request
                    input environment
                    (output-limit *project-process-output-limit*))
  "Run argv list ARGUMENTS with a timeout and separately bounded output.

Return bounded stdout, bounded stderr, and the exit status.  When REQUEST is
provided, cancellation and process ownership are atomic and request-local."
  (let ((process nil)
        (finished-p nil)
        (error-thread nil)
        (input-stream (and input (make-string-input-stream input))))
    (unwind-protect
         (progn
           (setf process
                 (launch-project-process arguments directory request
                                         :input input-stream
                                         :environment environment))
           (let ((error-output "")
                 (error-failure nil))
             (setf error-thread
                   (bt2:make-thread
                    (lambda ()
                      (handler-case
                          (setf error-output
                                (with-open-stream
                                    (stream
                                      (uiop:process-info-error-output process))
                                  (read-project-process-output
                                   stream process output-limit)))
                        (error (condition)
                          (setf error-failure (princ-to-string condition)))))
                    :name "lem-yath/project-stderr"))
             (let ((output
                   (with-open-stream
                       (stream (uiop:process-info-output process))
                     (read-project-process-output stream process output-limit))))
               (let ((status (uiop:wait-process process)))
                 (bt2:join-thread error-thread)
                 (setf error-thread nil
                       finished-p t)
                 (when error-failure
                   (error "~a" error-failure))
                 (values output error-output status)))))
      (when (and process (not finished-p))
        (ignore-errors (uiop:terminate-process process))
        (ignore-errors (uiop:wait-process process)))
      (when error-thread
        (ignore-errors (bt2:join-thread error-thread)))
      (when input-stream
        (ignore-errors (close input-stream)))
      (release-project-process request process))))

(defun project-git-rev-parse (git directory argument &key request)
  "Return trimmed output from one successful Git rev-parse ARGUMENT."
  (multiple-value-bind (output error-output status)
      (run-project-program
       (list (namestring git) "-C" (project-native-directory directory)
             "rev-parse" argument)
       :request request)
    (declare (ignore error-output))
    (when (and (integerp status) (zerop status))
      (string-trim '(#\Space #\Tab #\Newline #\Return) output))))

(defun project-git-root (directory &key request)
  "Return DIRECTORY's canonical Git root, merging initialized submodules."
  (alexandria:when-let ((git (executable-find "git")))
    (handler-case
        (alexandria:when-let
            ((top (project-git-rev-parse
                   git directory "--show-toplevel" :request request)))
          (when (plusp (length top))
            (loop :with root := (canonical-project-directory top)
                  :for super :=
                    (project-git-rev-parse
                     git root "--show-superproject-working-tree"
                     :request request)
                  :while (and super (plusp (length super)))
                  :do (setf root (canonical-project-directory super))
                  :finally (return root))))
      (project-request-cancelled (condition) (error condition))
      (error () nil))))

(defun project-marker-present-p (directory)
  "Whether DIRECTORY contains a project marker known to pinned Lem."
  (or (some (lambda (name)
              (uiop:directory-exists-p
               (merge-pathnames
                (uiop:ensure-directory-pathname name) directory)))
            lem-core/commands/project:*root-directories*)
      (some (lambda (name)
              (uiop:file-exists-p (merge-pathnames name directory)))
            lem-core/commands/project:*root-files*)))

(defun project-marker-root (directory)
  "Walk upward from DIRECTORY and return the nearest marked project root."
  (labels ((walk (current)
             (cond
               ((project-marker-present-p current) current)
               (t
                (let ((parent
                        (uiop:pathname-parent-directory-pathname current)))
                  (unless (uiop:pathname-equal parent current)
                    (walk parent)))))))
    (handler-case
        (walk (canonical-project-directory directory))
      (error () nil))))

(defun lem-yath-project-root-for-directory (directory)
  "Return a recognized canonical project root for DIRECTORY, or NIL."
  (or (project-git-root directory)
      (project-marker-root directory)))

(defun project-history ()
  "Return Lem's existing persistent project history."
  (lem-core/commands/project::history))

(defun remember-project-root (root)
  "Canonicalize ROOT and persist it as the most-recently used project."
  (let* ((root (canonical-project-directory root))
         (name (uiop:native-namestring root))
         (history (project-history)))
    (unless (string= name (or (lem/common/history:last-history history) ""))
      (lem/common/history:add-history history name
                                      :allow-duplicates nil
                                      :move-to-top t
                                      :test #'string=)
      (lem/common/history:save-file history))
    root))

(defun saved-project-roots ()
  "Return live saved project roots in most-recently used order."
  (remove-duplicates
   (loop :for entry :in
           (reverse (lem/common/history:history-data-list (project-history)))
         :for root := (handler-case
                          (canonical-project-directory entry)
                        (error () nil))
         :when root
           :collect root)
   :test #'uiop:pathname-equal
   :from-end t))

(defun register-buffer-project (buffer)
  "Remember BUFFER's recognized project without inventing a fallback root."
  (when (and (member buffer (buffer-list) :test #'eq)
             (buffer-filename buffer))
    (alexandria:when-let
        ((root (lem-yath-project-root-for-directory
                (buffer-directory buffer))))
      (remember-project-root root))))

(defun current-project-directory ()
  "Return and remember the current project, prompting outside a project."
  (let* ((directory (buffer-directory (current-buffer)))
         (root (lem-yath-project-root-for-directory directory)))
    (unless root
      (let ((chosen
              (prompt-for-directory
               "Project directory: "
               :directory directory
               :default directory
               :existing t)))
        (setf root
              (or (lem-yath-project-root-for-directory chosen)
                  (canonical-project-directory chosen)))))
    (remember-project-root root)))

(defun project-display-string (string)
  "Escape control characters in STRING so it occupies one prompt row."
  (completion-path-display-string string))

(defun project-root-choices (&optional current-root)
  "Return prompt display/root pairs for known projects and directory choice."
  (let* ((roots (if current-root
                    (cons current-root (saved-project-roots))
                    (saved-project-roots)))
         (roots (remove-duplicates roots
                                   :test #'uiop:pathname-equal
                                   :from-end t)))
    (append
     (mapcar (lambda (root)
               (cons (project-display-string
                      (uiop:native-namestring root))
                     root))
             roots)
     (list (cons *project-switch-directory-choice* nil)))))

(defun prompt-for-project-root ()
  "Choose a remembered project or an arbitrary directory, then remember it."
  (let* ((current
           (lem-yath-project-root-for-directory
            (buffer-directory (current-buffer))))
         (choices (project-root-choices current))
         (labels (mapcar #'car choices))
         (initial (and current
                       (car (find current choices
                                  :key #'cdr
                                  :test #'uiop:pathname-equal))))
         (choice
           (prompt-for-string
            (if initial "Project (current): " "Project: ")
            :completion-function
            (lambda (input) (prescient-filter input labels))
            :test-function
            (lambda (input)
              (or (zerop (length input))
                  (member input labels :test #'string=))))))
    (when (zerop (length choice))
      (setf choice (or initial *project-switch-directory-choice*)))
    (if (string= choice *project-switch-directory-choice*)
        (let* ((directory (buffer-directory (current-buffer)))
               (selected
                 (prompt-for-directory "Project directory: "
                                       :directory directory
                                       :default directory
                                       :existing t)))
          (remember-project-root
           (or (lem-yath-project-root-for-directory selected)
               (canonical-project-directory selected))))
        (remember-project-root (cdr (assoc choice choices :test #'string=))))))

(defun project-split-nul (string)
  "Return nonempty NUL-terminated records from STRING."
  (loop :with start := 0
        :for end := (position #\Null string :start start)
        :while end
        :when (< start end)
          :collect (subseq string start end)
        :do (setf start (1+ end))))

(defun normalize-project-relative-path (path)
  "Remove fd/rg's harmless leading ./ from relative PATH."
  (if (alexandria:starts-with-subseq "./" path)
      (subseq path 2)
      path))

(defun safe-project-relative-path-p (path)
  "Whether PATH is a nonempty relative path that cannot escape its root."
  (let ((components (and (plusp (length path))
                         (uiop:split-string path :separator "/"))))
    (and components
         (char/= #\/ (char path 0))
         (not (some (lambda (component)
                      (or (string= component ".")
                          (string= component "..")))
                    components)))))

(defun project-native-relative-path (root relative)
  "Return safe RELATIVE below ROOT without wildcard interpretation."
  (unless (safe-project-relative-path-p relative)
    (error "Unsafe project-relative path: ~s" relative))
  (uiop:parse-native-namestring
   (concatenate 'string (project-native-directory root) relative)))

(defun project-directory-strictly-below-p (directory parent)
  "Whether canonical DIRECTORY is strictly beneath canonical PARENT."
  (handler-case
      (let ((directory (project-native-directory directory))
            (parent (project-native-directory parent)))
        (and (not (string= directory parent))
             (alexandria:starts-with-subseq parent directory)))
    (error () nil)))

(defun git-project-submodules (root)
  "Return safe submodule paths declared by ROOT's .gitmodules file."
  (let ((path (merge-pathnames ".gitmodules" root)))
    (when (uiop:file-exists-p path)
      (with-open-file (stream path)
        (loop :for line := (read-line stream nil)
              :while line
              :for registers :=
                (nth-value
                 1
                 (cl-ppcre:scan-to-strings
                  "^[ \\t]*path[ \\t]*=[ \\t]*(.*?)[ \\t]*$" line))
              :for submodule := (and registers (aref registers 0))
              :when (and submodule
                         (safe-project-relative-path-p submodule))
                :collect submodule)))))

(defun project-directory-path-p (path)
  (and (plusp (length path))
       (char= (char path (1- (length path))) #\/)))

(defun project-glob-quote (string)
  "Quote glob metacharacters in one literal filename component."
  (with-output-to-string (stream)
    (loop :for character :across string
          :do (when (find character "\\*?[]{}" :test #'char=)
                (write-char #\\ stream))
              (write-char character stream))))

(defun git-project-files (root &key request visited-roots)
  "Return Git files below ROOT, recursively merging initialized submodules."
  (alexandria:when-let ((git (executable-find "git")))
    (let* ((root (canonical-project-directory root))
           (visited-roots (or visited-roots (make-hash-table :test #'equal)))
           (root-key (project-native-directory root)))
      (when (gethash root-key visited-roots)
        (return-from git-project-files nil))
      (setf (gethash root-key visited-roots) t)
      (let ((submodules (git-project-submodules root)))
      (multiple-value-bind (output error-output status)
          (run-project-program
           (list (namestring git) "-C" (project-native-directory root)
                 "ls-files" "-z" "--cached" "--others" "--exclude-standard"
                 "--deduplicate" "--sparse")
           :request request)
        (unless (and (integerp status) (zerop status))
          (error "git ls-files failed: ~a"
                 (string-trim '(#\Space #\Tab #\Newline #\Return)
                              error-output)))
        (nconc
         (remove-if
          (lambda (file)
            (or (project-directory-path-p file)
                (member file submodules :test #'string=)))
         (project-split-nul output))
         (loop :for submodule :in submodules
               :for subpath := (project-native-relative-path root submodule)
               :for subroot := (alexandria:when-let
                                    ((directory
                                       (uiop:directory-exists-p subpath)))
                                  (canonical-project-directory directory))
               :when (and subroot
                          (project-directory-strictly-below-p subroot root)
                          (alexandria:when-let
                              ((detected
                                 (project-git-rev-parse
                                  git subroot "--show-toplevel"
                                  :request request)))
                            (uiop:pathname-equal
                             (canonical-project-directory detected)
                             subroot)))
                 :append
                 (handler-case
                     (mapcar
                      (lambda (file)
                        (format nil "~a/~a" submodule file))
                      (git-project-files
                       subroot
                       :request request
                       :visited-roots visited-roots))
                   (project-request-cancelled (condition) (error condition))
                   (error () nil)))))))))

(defun fd-project-files (root &key request)
  "Return non-ignored files below non-Git ROOT using fd."
  (let ((fd (or (executable-find "fd")
                (error "fd is not available"))))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (append
          (list (namestring fd) "--type" "f" "--hidden" "--print0"
                "--strip-cwd-prefix")
          (loop :for directory :in *project-rg-ignored-directories*
                :append (list "--exclude" (project-glob-quote directory)))
          (list "."))
         :directory root
         :request request)
      (if (and (integerp status) (zerop status))
          (project-split-nul output)
          (error "fd failed: ~a"
                 (string-trim '(#\Space #\Tab #\Newline #\Return)
                              error-output))))))

(defun project-file-candidates (root &key request)
  "Return sorted project-relative files, respecting Git ignore semantics."
  (let* ((root (canonical-project-directory root))
         (git-root (project-git-root root :request request))
         (files (if (and git-root (uiop:pathname-equal git-root root))
                    (git-project-files root :request request)
                    (fd-project-files root :request request))))
    (when (> (length files) *project-file-candidate-limit*)
      (error "Project has more than ~d file candidates"
             *project-file-candidate-limit*))
    (sort
     (remove-duplicates
      (loop :for file :in files
            :for relative := (normalize-project-relative-path file)
            :when (safe-project-relative-path-p relative)
              :collect relative)
      :test #'string=)
     #'string<)))

(defun project-absolute-path (root relative)
  "Return RELATIVE below ROOT without Common Lisp wildcard interpretation."
  (project-native-relative-path root relative))

(defun current-project-relative-file (root candidates)
  "Return the current buffer's project-relative filename when it is a candidate."
  (alexandria:when-let ((filename (buffer-filename (current-buffer))))
    (let ((root-name (project-native-directory root))
          (file-name (uiop:native-namestring filename)))
      (when (alexandria:starts-with-subseq root-name file-name)
        (let ((relative (subseq file-name (length root-name))))
          (and (member relative candidates :test #'string=) relative))))))

(defun prompt-for-project-file-candidates (root files)
  "Prompt among already collected FILES below ROOT and return the exact path."
  (let* ((choices
           (mapcar (lambda (file)
                     (cons (project-display-string file) file))
                   files))
         (labels (mapcar #'car choices))
         (current (current-project-relative-file root files))
         (initial (and current (project-display-string current))))
    (unless choices
      (editor-error "No files in project ~a" root))
    (let ((choice
            (prompt-for-string
             (if initial "Project file (current): " "Project file: ")
             :completion-function
             (lambda (input)
               (completion-annotated-prompt-choices
                (prescient-filter input choices
                                  :key #'car
                                  :category :project-file)
                (lambda (file)
                  (completion-file-detail
                   (project-absolute-path root file)))))
             :test-function
             (lambda (input)
               (or (and initial (zerop (length input)))
                   (member input labels :test #'string=))))))
      (when (and initial (zerop (length choice)))
        (setf choice initial))
      (cdr (assoc choice choices :test #'string=)))))

(defun prompt-for-project-file (root)
  "Collect, prompt for, and return an exact project-relative filename."
  (prompt-for-project-file-candidates root (project-file-candidates root)))

(defun deliver-project-file-candidates (root files request)
  "Prompt for FILES when REQUEST still belongs to its live origin."
  (when (current-project-request-p :file request)
    (clear-active-project-request :file request)
    (when (project-request-origin-current-p
           (project-request-origin request))
      (handler-case
          (alexandria:when-let
              ((relative (prompt-for-project-file-candidates root files)))
            (find-file (project-absolute-path root relative)))
        (editor-abort (condition) (error condition))
        (error (condition)
          (message "Project file selection failed: ~a" condition))))))

(defun deliver-project-file-error (text request)
  "Report a file discovery error for the still-current request."
  (when (current-project-request-p :file request)
    (clear-active-project-request :file request)
    (when (project-request-origin-current-p
           (project-request-origin request))
      (message "Project file discovery failed: ~a" text))))

(defun project-find-file-at-root (root)
  "Collect files off-thread, then prompt for and visit one in ROOT."
  (let* ((root (remember-project-root root))
         (generation (incf *project-file-request-generation*))
         (request
           (make-live-project-request
            generation (capture-project-request-origin))))
    (activate-project-request :file request)
    (message "Collecting project files…")
    (bt2:make-thread
     (lambda ()
       (handler-case
           (let ((files (project-file-candidates root :request request)))
             (when (project-request-live-p request)
               (send-event
                (lambda ()
                  (deliver-project-file-candidates
                   root files request)))))
         (project-request-cancelled () nil)
         (error (condition)
           (when (project-request-live-p request)
             (let ((text (princ-to-string condition)))
               (send-event
                (lambda ()
                    (deliver-project-file-error text request))))))))
     :name "lem-yath/project-files")))

(define-command lem-yath-project-find-file () ()
  "Find a tracked or unignored file in the current project."
  (project-find-file-at-root (current-project-directory)))

(defun project-directory-candidates (files)
  "Return root and every ancestor directory represented by relative FILES."
  (let ((directories (list ".")))
    (dolist (file files)
      (loop :for slash := (position #\/ file)
              :then (position #\/ file :start (1+ slash))
            :while slash
            :do (push (subseq file 0 (1+ slash)) directories)))
    (sort (remove-duplicates directories :test #'string=) #'string<)))

(defun current-project-relative-directory (root directories)
  "Return the current buffer directory relative to ROOT when selectable."
  (let ((root-name (project-native-directory root))
        (directory-name
          (project-native-directory (buffer-directory (current-buffer)))))
    (when (alexandria:starts-with-subseq root-name directory-name)
      (let ((relative (subseq directory-name (length root-name))))
        (if (zerop (length relative))
            "."
            (and (member relative directories :test #'string=) relative))))))

(defun prompt-for-project-directory-candidates (root directories)
  "Prompt among already collected project-relative DIRECTORIES."
  (let* ((choices
           (mapcar (lambda (directory)
                     (cons (project-display-string directory) directory))
                   directories))
         (labels (mapcar #'car choices))
         (current (current-project-relative-directory root directories))
         (initial (and current (project-display-string current)))
         (choice
           (prompt-for-string
            (if initial
                "Project directory (current): "
                "Project directory: ")
            :completion-function
            (lambda (input) (prescient-filter input labels))
            :test-function
            (lambda (input)
              (or (and initial (zerop (length input)))
                  (member input labels :test #'string=))))))
    (when (and initial (zerop (length choice)))
      (setf choice initial))
    (cdr (assoc choice choices :test #'string=))))

(defun deliver-project-directory-candidates
    (root directories request)
  "Prompt for DIRECTORIES when REQUEST still belongs to its live origin."
  (when (current-project-request-p :file request)
    (clear-active-project-request :file request)
    (when (project-request-origin-current-p
           (project-request-origin request))
      (handler-case
          (alexandria:when-let
              ((relative
                 (prompt-for-project-directory-candidates root directories)))
            (find-file
             (if (string= relative ".")
                 root
                 (project-native-relative-path root relative))))
        (editor-abort (condition) (error condition))
        (error (condition)
          (message "Project directory selection failed: ~a" condition))))))

(defun project-find-directory-at-root (root)
  "Collect project directories off-thread, then prompt for and open one."
  (let* ((root (remember-project-root root))
         (generation (incf *project-file-request-generation*))
         (request
           (make-live-project-request
            generation (capture-project-request-origin))))
    (activate-project-request :file request)
    (message "Collecting project directories…")
    (bt2:make-thread
     (lambda ()
       (handler-case
           (let ((directories
                   (project-directory-candidates
                    (project-file-candidates root :request request))))
             (when (project-request-live-p request)
               (send-event
                (lambda ()
                  (deliver-project-directory-candidates
                   root directories request)))))
         (project-request-cancelled () nil)
         (error (condition)
           (when (project-request-live-p request)
             (let ((text (princ-to-string condition)))
               (send-event
                (lambda ()
                    (deliver-project-file-error text request))))))))
     :name "lem-yath/project-directories")))

(defun project-write-backslashes (stream count)
  (loop :repeat count :do (write-char #\\ stream)))

(defun project-regexp-to-extended (regexp)
  "Convert Emacs regexp grouping and alternation syntax to extended regexp.

This mirrors Emacs 31's `xref--regexp-to-extended': outside bracket classes,
an escaped (), {}, or | becomes special and an unescaped one becomes literal."
  (with-output-to-string (stream)
    (loop :with length := (length regexp)
          :with index := 0
          :while (< index length)
          :do
             (let ((slashes 0))
               (loop :while (and (< index length)
                                 (char= (char regexp index) #\\))
                     :do (incf slashes)
                         (incf index))
               (when (= index length)
                 (project-write-backslashes stream slashes)
                 (return))
               (let ((character (char regexp index)))
                 (cond
                   ((and (char= character #\[) (evenp slashes))
                    (project-write-backslashes stream slashes)
                    (write-char character stream)
                    (incf index)
                    ;; A leading `]' (also after `^') is a literal member of
                    ;; an Emacs bracket class, not its terminator.
                    (when (and (< index length)
                               (char= (char regexp index) #\^))
                      (write-char #\^ stream)
                      (incf index))
                    (when (and (< index length)
                               (char= (char regexp index) #\]))
                      (write-char #\] stream)
                      (incf index))
                    (loop :with escaped-p := nil
                          :while (< index length)
                          :for class-character := (char regexp index)
                          :do (write-char class-character stream)
                              (incf index)
                              (cond
                                (escaped-p (setf escaped-p nil))
                                ((char= class-character #\\)
                                 (setf escaped-p t))
                                ((char= class-character #\])
                                 (return)))))
                   ((find character "(){}|" :test #'char=)
                    (if (oddp slashes)
                        (project-write-backslashes stream (1- slashes))
                        (progn
                          (project-write-backslashes stream slashes)
                          (write-char #\\ stream)))
                    (write-char character stream)
                    (incf index))
                   (t
                    (project-write-backslashes stream slashes)
                    (write-char character stream)
                    (incf index))))))))

(defun project-rg-arguments (pattern files)
  "Build a direct argv tail for regexp PATTERN over explicit project FILES."
  (append
   (list "--json" "--color" "never" "--smart-case" "--"
         (project-regexp-to-extended pattern))
   files))

(defun project-file-batches (files)
  "Partition FILES into argv-safe ripgrep batches."
  (let ((batches '())
        (batch '())
        (characters 0))
    (dolist (file files)
      (when (and batch
                 (or (>= (length batch) *project-rg-batch-size*)
                     (> (+ characters (length file))
                        *project-rg-batch-character-limit*)))
        (push (nreverse batch) batches)
        (setf batch nil
              characters 0))
      (push file batch)
      (incf characters (length file)))
    (when batch
      (push (nreverse batch) batches))
    (nreverse batches)))

(defun project-rg-match (line)
  "Parse one ripgrep JSON LINE into (relative-file line content), or NIL."
  (handler-case
      (let* ((object (yason:parse line))
             (type (and (hash-table-p object) (gethash "type" object))))
        (when (string= type "match")
          (let* ((data (gethash "data" object))
                 (path-object (and (hash-table-p data) (gethash "path" data)))
                 (lines-object (and (hash-table-p data) (gethash "lines" data)))
                 (path (and (hash-table-p path-object)
                            (gethash "text" path-object)))
                 (content (and (hash-table-p lines-object)
                               (gethash "text" lines-object)))
                 (line-number (and (hash-table-p data)
                                   (gethash "line_number" data))))
            (when (and (stringp path) (stringp content)
                       (integerp line-number))
              (let ((path (normalize-project-relative-path path)))
                (when (safe-project-relative-path-p path)
                  (list path line-number
                        (string-right-trim '(#\Newline #\Return)
                                           content))))))))
    (error () nil)))

(defun parse-project-rg-output (output)
  "Return match tuples from one ripgrep JSON OUTPUT string."
  (loop :for line :in (uiop:split-string output :separator '(#\Newline))
        :for match := (project-rg-match line)
        :when match
          :collect match))

(defun project-rg-results (root pattern &key request cancelled-p)
  "Run ripgrep safely over ROOT's exact project files and return match tuples."
  (let ((rg (or (executable-find "rg")
                (error "ripgrep is not available")))
        (files (project-file-candidates root :request request))
        (results '())
        (output-count 0))
    (unless files
      (error "Project has no files"))
    (dolist (batch (project-file-batches files))
      (when (or (and request (not (project-request-live-p request)))
                (and cancelled-p (funcall cancelled-p)))
        (return-from project-rg-results nil))
      (multiple-value-bind (output error-output status)
          (run-project-program
           (cons (namestring rg) (project-rg-arguments pattern batch))
           :directory root
           :request request
           :output-limit (max 1 (- *project-grep-output-limit*
                                   output-count)))
        (incf output-count (length output))
        (cond
          ((and (integerp status) (zerop status))
           (setf results
                 (nconc results (parse-project-rg-output output))))
          ((eql status 1))
          (t
           (error "ripgrep failed: ~a"
                  (string-trim '(#\Space #\Tab #\Newline #\Return)
                               error-output)))))
      (when (> (length results) *project-grep-result-limit*)
        (error "Project regexp produced more than ~d matches"
               *project-grep-result-limit*)))
    results))

(defun project-result-move-function (root relative line-number)
  "Return a source-preview function for one project grep result."
  (lambda ()
    (let ((buffer (find-file-buffer
                   (project-absolute-path root relative))))
      (move-to-line (buffer-point buffer) line-number))))

(defun display-project-grep-results (root results)
  "Display editable project grep RESULTS using Lem's peek-source UI."
  (lem/peek-source:with-collecting-sources (collector :read-only nil)
    (setf (buffer-directory (lem/peek-source:collector-buffer collector)) root)
    (loop :for (file line-number content) :in results
          :do
             (lem/peek-source:with-appending-source
                 (point :move-function
                        (project-result-move-function root file line-number))
               (insert-string point (project-display-string file)
                              :attribute 'lem/peek-source:filename-attribute
                              :mode 'lem/grep::peek-grep-mode
                              :read-only t)
               (insert-string point ":" :read-only t)
               (insert-string point (princ-to-string line-number)
                              :attribute 'lem/peek-source:position-attribute
                              :read-only t)
               (insert-string point ":" :read-only t :content-start t)
               (insert-string point content)))
    (add-hook
     (variable-value
      'after-change-functions
      :buffer (lem/peek-source:collector-buffer collector))
     'lem/grep::change-grep-buffer)))

(define-command lem-yath-peek-source-escape () ()
  "Leave a non-Normal Vi state before dismissing a peek-source UI."
  (let ((state (lem-vi-mode/core:current-state)))
    (cond
      ((lem-vi-mode/visual:visual-p)
       (lem-vi-mode/visual:vi-visual-end))
      ((and state
            (not (lem-vi-mode/core:state=
                  state
                  (lem-vi-mode/core:ensure-state
                   'lem-vi-mode/states:normal))))
       (lem-vi-mode/commands:vi-normal))
      (t
       (lem/peek-source::peek-source-quit)))))

(defun deliver-project-grep-results (root results request)
  "Display RESULTS when REQUEST still belongs to its live origin."
  (when (current-project-request-p :grep request)
    (clear-active-project-request :grep request)
    (when (project-request-origin-current-p
           (project-request-origin request))
      (if results
          (display-project-grep-results root results)
          (message "No match")))))

(defun deliver-project-grep-error (text request)
  "Report a regexp failure for the still-current request."
  (when (current-project-request-p :grep request)
    (clear-active-project-request :grep request)
    (when (project-request-origin-current-p
           (project-request-origin request))
      (message "Project regexp failed: ~a" text))))

(defun project-grep-at-root (root pattern)
  "Search regexp PATTERN off-thread in ROOT and display editable results."
  (when (zerop (length pattern))
    (editor-error "Project regexp cannot be empty"))
  (let* ((root (remember-project-root root))
         (generation (incf *project-grep-request-generation*))
         (request
           (make-live-project-request
            generation (capture-project-request-origin))))
    (activate-project-request :grep request)
    (setf *project-grep-last-pattern* pattern)
    (message "Searching project…")
    (bt2:make-thread
     (lambda ()
       (handler-case
           (let ((results
                   (project-rg-results
                    root pattern :request request)))
             (when (project-request-live-p request)
               (send-event
                (lambda ()
                  (deliver-project-grep-results
                   root results request)))))
         (project-request-cancelled () nil)
         (error (condition)
           (when (project-request-live-p request)
             (let ((text (princ-to-string condition)))
               (send-event
                (lambda ()
                  (deliver-project-grep-error
                   text request))))))))
     :name "lem-yath/project-grep")))

(define-command lem-yath-project-grep () ()
  "Search a regexp in the current project with ripgrep."
  (let ((pattern
          (prompt-for-string "Project regexp: "
                             :initial-value *project-grep-last-pattern*
                             :history-symbol 'lem-yath-project-grep)))
    (project-grep-at-root (current-project-directory) pattern)))

(defun project-buffers-at-root (root &optional (buffers (buffer-list)))
  "Return switchable BUFFERS whose buffer directory is within ROOT."
  (let ((root (canonical-project-directory root)))
    (loop :for buffer :in buffers
          :when (and (not (deleted-buffer-p buffer))
                     (not (not-switchable-buffer-p buffer))
                     (project-path-in-directory-p
                      (buffer-directory buffer) root))
            :collect buffer)))

(defun call-in-project-buffer-directory (root function)
  "Call FUNCTION with the current Lem buffer directory temporarily at ROOT."
  (let* ((buffer (current-buffer))
         (old-directory (lem/buffer/internal::buffer-%directory buffer))
         (root (canonical-project-directory root)))
    (unwind-protect
         (progn
           (setf (buffer-directory buffer) root)
           (funcall function))
      (unless (deleted-buffer-p buffer)
        ;; Preserve the exact prior local value, including NIL or a path that
        ;; the invoked command removed while it was running.
        (setf (lem/buffer/internal::buffer-%directory buffer)
              old-directory)))))

(defun project-open-root (root)
  "Open ROOT in Lem's directory editor."
  (find-file (remember-project-root root)))

(defun project-open-vcs (root)
  "Open Git status for ROOT, the Lem counterpart to Emacs `project-vc-dir'."
  (remember-project-root root)
  (lem-yath-legit-status-at root))

(defun project-open-shell (root)
  "Create a terminal rooted at ROOT."
  (setf root (remember-project-root root))
  (call-in-project-buffer-directory
   root
   (lambda ()
     (alexandria:if-let ((command (find-command "terminal")))
       (progn
         (call-command command t)
         ;; Pinned terminal-mode passes its cwd to libvterm but leaves Lem's
         ;; buffer directory unset.  Keep later project-buffer discovery exact.
         (setf (buffer-directory (current-buffer)) root))
       (editor-error "Lem terminal support is unavailable")))))

(defun project-execute-command (root)
  "Read and execute an arbitrary command with ROOT as the buffer directory."
  (remember-project-root root)
  (call-in-project-buffer-directory
   root
   (lambda () (lem-core/commands/other:execute-command nil))))

(defun project-switch-keymap ()
  "Build the transient keymap for Emacs-compatible project dispatch."
  (let ((keymap (make-keymap :description "Project command")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist (entry '(("f" "find file")
                     ("g" "find regexp")
                     ("d" "find directory")
                     ("v" "Git VC directory")
                     ("e" "shell")
                     ("o" "other command")
                     ("q" "cancel")))
      (destructuring-bind (key description) entry
        (define-key keymap key 'nop-command)
        (setf (lem-core::prefix-description
               (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
              description)))
    keymap))

(defun invoke-project-switch-key (root key)
  "Invoke project action KEY at ROOT; return whether KEY was recognized."
  (cond
    ((string= key "f") (project-find-file-at-root root) t)
    ((string= key "g")
     (let ((pattern
             (prompt-for-string "Project regexp: "
                                :initial-value *project-grep-last-pattern*
                                :history-symbol 'lem-yath-project-grep)))
       (project-grep-at-root root pattern))
     t)
    ((string= key "d") (project-find-directory-at-root root) t)
    ((string= key "v") (project-open-vcs root) t)
    ((string= key "e") (project-open-shell root) t)
    ((string= key "o") (project-execute-command root) t)
    ((or (string= key "q") (string= key "Escape")) t)
    (t nil)))

(defun dispatch-project-switch (root)
  "Show the project command transient and dispatch one key at ROOT."
  (unwind-protect
       (let ((keymap (project-switch-keymap)))
         (loop
           (let ((lem/transient:*transient-popup-delay* 0))
             (keymap-activate keymap))
           (redraw-display)
           (let* ((key (read-key))
                  (name (lem-core::keyseq-to-string (list key))))
             (lem/transient::hide-transient)
             (when (invoke-project-switch-key root name)
               (return))
             (message "No project command is bound to ~a" name))))
    (lem/transient::hide-transient)))

(define-command lem-yath-project-switch () ()
  "Choose a remembered or arbitrary project, then dispatch a project command."
  (dispatch-project-switch (prompt-for-project-root)))

(define-command lem-yath-project-root-directory () ()
  "Open the current project's root directory."
  (project-open-root (current-project-directory)))

;; Preserve the standard project prefix as well as the configured leader keys.
(define-key *global-keymap* "C-x p f" 'lem-yath-project-find-file)
(define-key *global-keymap* "C-x p g" 'lem-yath-project-grep)
(define-key *global-keymap* "C-x p p" 'lem-yath-project-switch)
(define-key *global-keymap* "C-x p d" 'lem-yath-project-root-directory)
(define-key lem/peek-source:*peek-source-keymap*
  "Escape" 'lem-yath-peek-source-escape)

;; Hot reloads must not multiply registration work.
(remove-hook *find-file-hook* 'register-buffer-project)
(add-hook *find-file-hook* 'register-buffer-project)
(remove-hook *pre-command-hook* 'cancel-pending-project-requests)
(add-hook *pre-command-hook* 'cancel-pending-project-requests)
(cancel-pending-project-requests)
(ignore-errors (register-buffer-project (current-buffer)))
