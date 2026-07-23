;;;; Magit-compatible Git log, reflog, and shortlog dispatch for Legit.

(in-package :lem-yath)

(defparameter *legit-log-timeout* 120)
(defparameter *legit-log-output-limit* (* 16 1024 1024))
(defparameter *legit-log-value-limit* 4096)
(defparameter *legit-log-candidate-limit* 5000)
(defparameter *legit-log-revision-limit* 64)
(defparameter *legit-log-file-limit* 64)
(defparameter *legit-log-count-limit* 1000000)

(defvar *legit-log-author-history* nil)
(defvar *legit-log-grep-history* nil)
(defvar *legit-log-pickaxe-history* nil)
(defvar *legit-log-revision-history* nil)
(defvar *legit-log-file-history* nil)
(defvar *legit-log-trace-history* nil)
(defvar *legit-log-shortlog-group-history* nil)

(defparameter *legit-log-record-marker*
  (format nil "~cLEM-YATH-LOG~c" #\Null #\Null))

(define-attribute legit-log-graph-1
  (t :foreground :base0D))
(define-attribute legit-log-graph-2
  (t :foreground :base0B))
(define-attribute legit-log-graph-3
  (t :foreground :base0A))
(define-attribute legit-log-graph-4
  (t :foreground :base0E))
(define-attribute legit-log-graph-5
  (t :foreground :base09))
(define-attribute legit-log-graph-6
  (t :foreground :base0C))

(defparameter *legit-log-graph-attributes*
  '(legit-log-graph-1 legit-log-graph-2 legit-log-graph-3
    legit-log-graph-4 legit-log-graph-5 legit-log-graph-6))

(defstruct (legit-log-options
            (:constructor make-legit-log-options
                (&key (limit 256) author grep pickaxe-regexp pickaxe-string
                      trace files simplify-decoration-p follow-p order
                      reverse-p graph-p color-p (decorate-p t) signatures-p
                      header-p patch-p stat-p)))
  limit
  author
  grep
  pickaxe-regexp
  pickaxe-string
  trace
  files
  simplify-decoration-p
  follow-p
  order
  reverse-p
  graph-p
  color-p
  decorate-p
  signatures-p
  header-p
  patch-p
  stat-p)

(defstruct legit-log-state
  (kind :log)
  title
  revisions
  options
  (offset 0)
  reflog-ref)

(defstruct legit-log-entry
  hash
  short-hash
  author
  timestamp
  refs
  signature
  subject
  body
  graph
  detail)

(defstruct (legit-shortlog-options
            (:constructor make-legit-shortlog-options
                (&key (numbered-p t) (summary-p t) email-p group)))
  numbered-p
  summary-p
  email-p
  group)

(defun legit-log-require-git (vcs)
  (unless (typep vcs 'lem/porcelain/git::vcs-git)
    (editor-error "Log is available only in a Git repository.")))

(defun legit-log-run-program (arguments)
  "Run bounded Git ARGUMENTS in Legit's current repository."
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *legit-log-timeout*))
    (run-project-program
     (cons (uiop:native-namestring git) arguments)
     :directory (uiop:getcwd)
     :environment
     (legit-rebase-child-environment
      "GIT_PAGER" "cat" "LC_ALL" "C")
     :output-limit *legit-log-output-limit*)))

(defun legit-log-checked-output (arguments)
  (multiple-value-bind (output error-output status)
      (legit-log-run-program arguments)
    (unless (and (integerp status) (zerop status))
      (editor-error "~a" (legit-command-error-text output error-output)))
    output))

(defun legit-log-bounded-value (value description &key allow-empty-p)
  (let ((value (and value (str:trim value))))
    (when (and (not allow-empty-p) (or (null value) (str:blankp value)))
      (editor-error "A ~a is required." description))
    (when (and value (> (length value) *legit-log-value-limit*))
      (editor-error "The ~a is limited to 4096 characters." description))
    value))

(defun legit-log-split-nul (text)
  (remove ""
          (uiop:split-string text :separator (string #\Null))
          :test #'string=))

(defun legit-log-ref-candidates ()
  (let ((refs
          (remove-if
           #'str:blankp
           (str:lines
            (legit-log-checked-output
             '("for-each-ref" "--format=%(refname:short)"
               "refs/heads" "refs/remotes" "refs/tags"))))))
    (when (> (length refs) *legit-log-candidate-limit*)
      (editor-error "Git returned more than ~d log references."
                    *legit-log-candidate-limit*))
    (remove-duplicates (cons "HEAD" refs) :test #'string=)))

(defun legit-log-current-ref ()
  (or (legit-fetch-current-branch) "HEAD"))

(defun legit-log-valid-revision-p (revision)
  (multiple-value-bind (output error-output status)
      (legit-log-run-program
       (list "rev-list" "--max-count=1" revision "--"))
    (declare (ignore output error-output))
    (and (integerp status) (zerop status))))

(defun legit-log-validate-revisions (revisions)
  (when (> (length revisions) *legit-log-revision-limit*)
    (editor-error "A log is limited to ~d revisions."
                  *legit-log-revision-limit*))
  (dolist (revision revisions)
    (legit-log-bounded-value revision "revision")
    (when (char= (char revision 0) #\-)
      (editor-error "A selected revision cannot begin with an option marker."))
    (unless (legit-log-valid-revision-p revision)
      (editor-error "Git cannot resolve revision ~a." revision)))
  revisions)

(defun legit-log-parse-revisions (input)
  (let ((revisions
          (remove-if
           #'str:blankp
           (cl-ppcre:split "[,[:space:]]+"
                           (legit-log-bounded-value input "revision")))))
    (unless revisions
      (editor-error "At least one revision is required."))
    (legit-log-validate-revisions revisions)))

(defun legit-log-read-revisions (prompt &optional initial-value)
  (alexandria:when-let
      ((input
         (prompt-for-string
          prompt
          :initial-value (or initial-value "")
          :history-symbol '*legit-log-revision-history*
          :completion-function
          (lambda (query)
            (completion-strings query (legit-log-ref-candidates))))))
    (legit-log-parse-revisions input)))

(defun legit-log-path-candidates ()
  (let ((paths
          (legit-log-split-nul
           (legit-log-checked-output '("ls-files" "-z" "--")))))
    (when (> (length paths) *legit-log-candidate-limit*)
      (editor-error "Git returned more than ~d tracked paths."
                    *legit-log-candidate-limit*))
    paths))

(defun legit-log-safe-relative-path-p (path)
  (and (str:non-blank-string-p path)
       (not (char= (char path 0) #\/))
       (not (find #\Null path))
       (not (member ".." (uiop:split-string path :separator "/")
                    :test #'string=))))

(defun legit-log-validate-paths (paths candidates)
  (when (> (length paths) *legit-log-file-limit*)
    (editor-error "A log is limited to ~d path filters."
                  *legit-log-file-limit*))
  (dolist (path paths)
    (legit-log-bounded-value path "path")
    (unless (legit-log-safe-relative-path-p path)
      (editor-error "Log paths must be safe repository-relative paths."))
    (unless (member path candidates :test #'string=)
      (editor-error "Path ~a is not tracked in the current worktree." path)))
  paths)

(defun legit-log-parse-paths (input candidates)
  (let* ((input (legit-log-bounded-value input "path"))
         (paths
           (if (member input candidates :test #'string=)
               (list input)
               (mapcar #'str:trim
                       (uiop:split-string input :separator ",")))))
    (legit-log-validate-paths paths candidates)))

(defun legit-log-read-paths ()
  (let ((candidates (legit-log-path-candidates)))
    (unless candidates
      (editor-error "The repository has no tracked paths."))
    (alexandria:when-let
        ((input
           (prompt-for-string
            "Log path(s), comma separated: "
            :history-symbol '*legit-log-file-history*
            :completion-function
            (lambda (query) (completion-strings query candidates)))))
      (legit-log-parse-paths input candidates))))

(defun legit-log-read-string-option (prompt history description)
  (alexandria:when-let
      ((value (prompt-for-string prompt :history-symbol history)))
    (legit-log-bounded-value value description)))

(defun legit-log-read-limit ()
  (alexandria:when-let
      ((value
         (prompt-for-string
          "Limit number of commits: "
          :history-symbol '*legit-log-revision-history*)))
    (let ((number (parse-integer value :junk-allowed t)))
      (unless (and number (plusp number)
                   (string= value (princ-to-string number)))
        (editor-error "The commit limit must be a positive integer."))
      (min number 1000000))))

(defun legit-log-read-trace ()
  (let ((paths (legit-log-path-candidates)))
    (unless paths
      (editor-error "The repository has no tracked paths to trace."))
    (alexandria:when-let
        ((range
           (prompt-for-string
            "Trace lines (START,END): "
            :history-symbol '*legit-log-trace-history*)))
      (unless (cl-ppcre:scan "^[1-9][0-9]*,[1-9][0-9]*$" range)
        (editor-error "A trace range must have the form START,END."))
      (destructuring-bind (start end)
          (mapcar #'parse-integer (uiop:split-string range :separator ","))
        (when (> start end)
          (editor-error "The trace start cannot follow its end.")))
      (alexandria:when-let
          ((path
             (prompt-for-string
              "Trace file: "
              :history-symbol '*legit-log-file-history*
              :completion-function
              (lambda (query) (completion-strings query paths)))))
        (legit-log-validate-paths (list path) paths)
        (format nil "~a:~a" range path)))))

(defun legit-log-order-argument (order)
  (ecase order
    ((nil) nil)
    (:topo "--topo-order")
    (:author-date "--author-date-order")
    (:date "--date-order")))

(defun legit-log-option-arguments (options)
  "Return the exact Git option vector for OPTIONS, excluding page bounds."
  (remove
   nil
   (list
    (and (legit-log-options-author options)
         (format nil "--author=~a" (legit-log-options-author options)))
    (and (legit-log-options-grep options)
         (format nil "--grep=~a" (legit-log-options-grep options)))
    (and (legit-log-options-pickaxe-regexp options)
         (format nil "-G~a" (legit-log-options-pickaxe-regexp options)))
    (and (legit-log-options-pickaxe-string options)
         (format nil "-S~a" (legit-log-options-pickaxe-string options)))
    (and (legit-log-options-trace options)
         (format nil "-L~a" (legit-log-options-trace options)))
    (and (legit-log-options-simplify-decoration-p options)
         "--simplify-by-decoration")
    (and (legit-log-options-follow-p options) "--follow")
    (legit-log-order-argument (legit-log-options-order options))
    (and (legit-log-options-reverse-p options) "--reverse")
    (and (legit-log-options-graph-p options)
         (not (legit-log-options-reverse-p options))
         "--graph")
    (and (legit-log-options-patch-p options) "--patch")
    (and (legit-log-options-stat-p options) "--stat"))))

(defun legit-log-validate-options (options revisions)
  (when (and (legit-log-options-follow-p options)
             (/= (length (legit-log-options-files options)) 1))
    (editor-error "Follow requires exactly one selected path."))
  (when (and (legit-log-options-trace options)
             (/= (length revisions) 1))
    (editor-error "Line tracing requires exactly one revision."))
  (when (and (legit-log-options-trace options)
             (legit-log-options-files options))
    (editor-error "Line tracing already selects its path; clear path filters."))
  t)

(defun legit-log-format-argument ()
  "--format=%x00LEM-YATH-LOG%x00%H%x00%h%x00%an%x00%at%x00%D%x00%G?%x00%s%x00%b%x00")

(defun legit-log-query-arguments
    (state count &optional (format-argument (legit-log-format-argument)))
  (let* ((options (legit-log-state-options state))
         (revisions (legit-log-state-revisions state))
         (files (legit-log-options-files options)))
    (legit-log-validate-options options revisions)
    (append
     (list "--no-pager" "log" "--color=never" "--no-ext-diff"
           format-argument
           (format nil "--skip=~d" (legit-log-state-offset state))
           (format nil "--max-count=~d" count))
     (legit-log-option-arguments options)
     revisions
     (when (and files (null (legit-log-options-trace options)))
       (cons "--" files)))))

(defun legit-log-line-start-before (text position)
  (let ((newline (position #\Newline text :end position :from-end t)))
    (if newline (1+ newline) 0)))

(defun legit-log-read-nul-field (text start limit)
  (let ((end (position #\Null text :start start :end limit)))
    (unless end
      (error "Malformed bounded Git log record."))
    (values (subseq text start end) (1+ end))))

(defun legit-log-parse-record (text marker next-marker)
  (let* ((graph-start (legit-log-line-start-before text marker))
         (graph (subseq text graph-start marker))
         (record-start (+ marker (length *legit-log-record-marker*)))
         (record-end
           (if next-marker
               (legit-log-line-start-before text next-marker)
               (length text)))
         (cursor record-start)
         fields)
    (loop :repeat 8 :do
      (multiple-value-bind (field next)
          (legit-log-read-nul-field text cursor record-end)
        (push field fields)
        (setf cursor next)))
    (setf fields (nreverse fields))
    (destructuring-bind
        (hash short-hash author timestamp refs signature subject body)
        fields
      (make-legit-log-entry
       :hash hash
       :short-hash short-hash
       :author author
       :timestamp timestamp
       :refs refs
       :signature signature
       :subject subject
       :body body
       :graph graph
       :detail (string-trim '(#\Space #\Tab #\Newline #\Return)
                            (subseq text cursor record-end))))))

(defun legit-log-parse-output (text)
  "Parse marker-delimited Git log TEXT without trusting line-oriented subjects."
  (loop :with start := 0
        :for marker := (search *legit-log-record-marker* text :start2 start)
        :while marker
        :for next := (search *legit-log-record-marker* text
                             :start2 (+ marker
                                        (length *legit-log-record-marker*)))
        :collect (legit-log-parse-record text marker next)
        :do (setf start (or next (length text)))
        :while next))

(defun legit-log-page-size (options offset)
  (let ((normal lem/porcelain:*commits-log-page-size*)
        (limit (legit-log-options-limit options)))
    (if limit
        (max 0 (min normal (- limit offset)))
        normal)))

(defun legit-log-query (state)
  (let* ((options (legit-log-state-options state))
         (page-size
           (legit-log-page-size options (legit-log-state-offset state))))
    (if (zerop page-size)
        (values nil nil)
        (let* ((requested (1+ page-size))
               (entries
                 (legit-log-parse-output
                  (legit-log-checked-output
                   (legit-log-query-arguments state requested))))
               (has-next (> (length entries) page-size)))
          (values (subseq entries 0 (min page-size (length entries)))
                  has-next)))))

(defun legit-log-reflog-query (state)
  (let* ((options (legit-log-state-options state))
         (page-size
           (legit-log-page-size options (legit-log-state-offset state)))
         (requested (1+ page-size))
         (format
           "--format=%x00LEM-YATH-LOG%x00%H%x00%h%x00%an%x00%at%x00%gd%x00%G?%x00%gs%x00%x00")
         (output
           (legit-log-checked-output
            (list "--no-pager" "reflog" "show" "--color=never"
                  format
                  (format nil "--skip=~d" (legit-log-state-offset state))
                  (format nil "--max-count=~d" requested)
                  (legit-log-state-reflog-ref state))))
         (entries (legit-log-parse-output output))
         (has-next (> (length entries) page-size)))
    (values (subseq entries 0 (min page-size (length entries))) has-next)))

(defun legit-log-format-date (timestamp)
  (let ((seconds (parse-integer timestamp :junk-allowed t)))
    (if seconds
        (multiple-value-bind (_second _minute _hour day month year)
            (decode-universal-time (+ seconds 2208988800) 0)
          (declare (ignore _second _minute _hour))
          (format nil "~4,'0d-~2,'0d-~2,'0d" year month day))
        "unknown-date")))

(defun legit-log-graph-attribute (index)
  (nth (mod index (length *legit-log-graph-attributes*))
       *legit-log-graph-attributes*))

(defun legit-log-insert-detail-line (buffer text &optional attribute)
  (let ((point (buffer-point buffer)))
    (insert-string point "  " :read-only t)
    (insert-string point text :attribute attribute :read-only t)
    (insert-string point (string #\Newline) :read-only t)))

(defun legit-log-insert-entry (collector entry index options)
  (let ((buffer (lem/legit::collector-buffer collector))
        (hash (legit-log-entry-hash entry))
        (graph (legit-log-entry-graph entry)))
    (lem/legit::with-appending-source
        (point
         :move-function (lem/legit::make-show-commit-function hash)
         :visit-file-function (lambda ())
         :stage-function (lambda ())
         :unstage-function (lambda ()))
      (with-point ((start point))
        (when (str:non-blank-string-p graph)
          (insert-string point graph
                         :attribute
                         (and (legit-log-options-color-p options)
                              (legit-log-graph-attribute index))
                         :read-only t))
        (insert-string point (legit-log-entry-short-hash entry)
                       :attribute 'lem/legit::filename-attribute
                       :read-only t)
        (when (and (legit-log-options-signatures-p options)
                   (not (string= (legit-log-entry-signature entry) "N")))
          (insert-string point
                         (format nil " [~a]" (legit-log-entry-signature entry))
                         :read-only t))
        (when (and (legit-log-options-decorate-p options)
                   (str:non-blank-string-p (legit-log-entry-refs entry)))
          (insert-string point
                         (format nil " (~a)" (legit-log-entry-refs entry))
                         :attribute 'legit-log-graph-2
                         :read-only t))
        (insert-string point (format nil " ~a" (legit-log-entry-subject entry))
                       :read-only t)
        (put-text-property start point :commit-hash hash)))
    (when (legit-log-options-header-p options)
      (legit-log-insert-detail-line
       buffer
       (format nil "Author: ~a  Date: ~a"
               (legit-log-entry-author entry)
               (legit-log-format-date (legit-log-entry-timestamp entry))))
      (dolist (line (remove-if #'str:blankp
                               (str:lines (legit-log-entry-body entry))))
        (legit-log-insert-detail-line buffer line)))
    (when (str:non-blank-string-p (legit-log-entry-detail entry))
      (dolist (line (str:lines (legit-log-entry-detail entry)))
        (legit-log-insert-detail-line buffer line)))))

(defun legit-log-display (state)
  "Render STATE in Legit's two-pane log view and retain pagination state."
  (multiple-value-bind (entries has-next)
      (if (eq (legit-log-state-kind state) :reflog)
          (legit-log-reflog-query state)
          (legit-log-query state))
    (lem/legit::with-collecting-sources
        (collector :buffer :commits-log
                   :minor-mode 'lem/legit::legit-commits-log-mode
                   :read-only nil)
      (lem/legit::collector-insert
       (format nil "~a (offset ~d):"
               (legit-log-state-title state)
               (legit-log-state-offset state))
       :header t)
      (if entries
          (loop :for entry :in entries
                :for index :from 0
                :do (legit-log-insert-entry
                     collector entry index (legit-log-state-options state)))
          (lem/legit::collector-insert "<no commits>"))
      (let ((buffer (lem/legit::collector-buffer collector)))
        (setf (buffer-value buffer 'legit-log-state) state
              (buffer-value buffer 'legit-log-has-next) has-next
              (buffer-value buffer 'legit-log-page-count) (length entries))))))

(defun legit-log-buffer-state ()
  (or (buffer-value (current-buffer) 'legit-log-state)
      (editor-error "This is not a configured log view.")))

(define-command lem-yath-legit-log-next-page () ()
  (lem/legit::with-current-project (vcs)
    (legit-log-require-git vcs)
    (let* ((state (legit-log-buffer-state))
           (count (or (buffer-value (current-buffer) 'legit-log-page-count) 0)))
      (unless (buffer-value (current-buffer) 'legit-log-has-next)
        (message "No more commits to display.")
        (return-from lem-yath-legit-log-next-page nil))
      (let ((next (copy-legit-log-state state)))
        (incf (legit-log-state-offset next) count)
        (legit-log-display next)))))

(define-command lem-yath-legit-log-previous-page () ()
  (lem/legit::with-current-project (vcs)
    (legit-log-require-git vcs)
    (let* ((state (legit-log-buffer-state))
           (previous (copy-legit-log-state state)))
      (setf (legit-log-state-offset previous)
            (max 0 (- (legit-log-state-offset state)
                      lem/porcelain:*commits-log-page-size*)))
      (legit-log-display previous))))

(define-command lem-yath-legit-log-first-page () ()
  (lem/legit::with-current-project (vcs)
    (legit-log-require-git vcs)
    (let ((state (copy-legit-log-state (legit-log-buffer-state))))
      (setf (legit-log-state-offset state) 0)
      (legit-log-display state))))

(defun legit-log-count (state)
  (let* ((count-state (copy-legit-log-state state))
         (limit (legit-log-options-limit (legit-log-state-options state)))
         (requested (1+ (or limit *legit-log-count-limit*))))
    (setf (legit-log-state-offset count-state) 0)
    (if (eq (legit-log-state-kind state) :reflog)
        (let ((output
                (legit-log-checked-output
                 (list "reflog" "show" "--format=%x00"
                       (format nil "--max-count=~d" requested)
                       (legit-log-state-reflog-ref state)))))
          (let ((count (count #\Null output)))
            (when (and (null limit) (> count *legit-log-count-limit*))
              (editor-error "Last-page lookup is limited to ~d reflog entries."
                            *legit-log-count-limit*))
            (if limit (min count limit) count)))
        (let* ((options (copy-legit-log-options
                         (legit-log-state-options state)))
               (_ (setf (legit-log-options-order options) nil
                        (legit-log-options-reverse-p options) nil
                        (legit-log-options-graph-p options) nil
                        (legit-log-options-color-p options) nil
                        (legit-log-options-decorate-p options) nil
                        (legit-log-options-signatures-p options) nil
                        (legit-log-options-header-p options) nil
                        (legit-log-options-patch-p options) nil
                        (legit-log-options-stat-p options) nil
                        (legit-log-state-options count-state) options))
               (arguments
                 (legit-log-query-arguments
                  count-state requested "--format=%x00"))
               (output (legit-log-checked-output arguments))
               (count (count #\Null output)))
          (declare (ignore _))
          (when (and (null limit) (> count *legit-log-count-limit*))
            (editor-error "Last-page lookup is limited to ~d commits."
                          *legit-log-count-limit*))
          (if limit (min count limit) count)))))

(define-command lem-yath-legit-log-last-page () ()
  (lem/legit::with-current-project (vcs)
    (legit-log-require-git vcs)
    (let* ((state (legit-log-buffer-state))
           (count (legit-log-count state))
           (page-size lem/porcelain:*commits-log-page-size*)
           (last (copy-legit-log-state state)))
      (setf (legit-log-state-offset last)
            (if (zerop count) 0 (* (floor (1- count) page-size) page-size)))
      (legit-log-display last))))

(define-command lem-yath-legit-log-refresh () ()
  (lem/legit::with-current-project (vcs)
    (legit-log-require-git vcs)
    (legit-log-display (legit-log-buffer-state))))

(define-command lem-yath-legit-log-toggle-limit () ()
  (lem/legit::with-current-project (vcs)
    (legit-log-require-git vcs)
    (let* ((state (copy-legit-log-state (legit-log-buffer-state)))
           (options (copy-legit-log-options (legit-log-state-options state))))
      (setf (legit-log-options-limit options)
            (unless (legit-log-options-limit options)
              lem/porcelain:*commits-log-page-size*)
            (legit-log-state-options state) options
            (legit-log-state-offset state) 0)
      (legit-log-display state))))

(define-command lem-yath-legit-log-back-to-status () ()
  "Return from a log-family view without triggering Legit's status toggle."
  (lem/legit::with-current-project (vcs)
    (legit-log-require-git vcs)
    (lem/legit::show-legit-status)))

(defun legit-log-symbolic-ref (revision)
  (multiple-value-bind (output error-output status)
      (legit-log-run-program
       (list "rev-parse" "--abbrev-ref" "--symbolic-full-name" revision))
    (declare (ignore error-output))
    (and (eql status 0) (str:non-blank-string-p output) (str:trim output))))

(defun legit-log-local-ref-p (reference)
  (multiple-value-bind (output error-output status)
      (legit-log-run-program
       (list "show-ref" "--verify" "--quiet"
             (format nil "refs/heads/~a" reference)))
    (declare (ignore output error-output))
    (eql status 0)))

(defun legit-log-related-revisions ()
  (let* ((current (legit-fetch-current-branch))
         (primary (or current "HEAD"))
         (upstream (legit-log-symbolic-ref "@{upstream}"))
         (push (legit-log-symbolic-ref "@{push}"))
         (previous (and (null current) (legit-log-symbolic-ref "@{-1}")))
         (up-up
           (and upstream
                (legit-log-local-ref-p upstream)
                (legit-log-symbolic-ref (format nil "~a@{upstream}" upstream)))))
    (remove-duplicates
     (remove nil (list primary (and (null current) "HEAD") previous
                       push upstream up-up))
     :test #'string=)))

(defun legit-log-open (title revisions options)
  (legit-log-display
   (make-legit-log-state
    :kind :log :title title :revisions revisions
    :options (copy-legit-log-options options))))

(defun legit-log-open-reflog (title reference)
  (legit-log-display
   (make-legit-log-state
    :kind :reflog :title title :revisions nil
    :reflog-ref reference :options (make-legit-log-options))))

(defun legit-log-add-popup-entry (keymap key description)
  (define-key keymap key 'nop-command)
  (setf (lem-core::prefix-description
         (lem-core::keymap-find keymap (lem-core::parse-keyspec key)))
        description))

(defun legit-log-checked-description (value description)
  (format nil "[~a] ~a" (if value "x" " ") description))

(defun legit-log-value-description (value description)
  (format nil "~a: ~a" description (or value "<unset>")))

(defun legit-log-popup-keymap (options)
  "Build the normally visible pinned Magit log transient."
  (let* ((filters (make-keymap :description "Filters"))
         (formatting (make-keymap :description "Formatting"))
         (actions (make-keymap :description "Actions"))
         (keymap (make-keymap :description "Log"
                              :children (list filters formatting actions))))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :row
          (lem/transient::keymap-display-style filters) :column
          (lem/transient::keymap-display-style formatting) :column
          (lem/transient::keymap-display-style actions) :column)
    (dolist
        (entry
          `(("- n" ,(legit-log-value-description
                      (and (legit-log-options-limit options)
                           (princ-to-string
                            (legit-log-options-limit options)))
                      "limit"))
            ("- A" ,(legit-log-value-description
                      (legit-log-options-author options) "author"))
            ("- F" ,(legit-log-value-description
                      (legit-log-options-grep options) "message"))
            ("- G" ,(legit-log-value-description
                      (legit-log-options-pickaxe-regexp options) "changes"))
            ("- S" ,(legit-log-value-description
                      (legit-log-options-pickaxe-string options) "occurrences"))
            ("- L" ,(legit-log-value-description
                      (legit-log-options-trace options) "line trace"))
            ("- D" ,(legit-log-checked-description
                      (legit-log-options-simplify-decoration-p options)
                      "simplify by decoration"))
            ("- -" ,(legit-log-value-description
                      (and (legit-log-options-files options)
                           (format nil "~{~a~^, ~}"
                                   (legit-log-options-files options)))
                      "paths"))
            ("- f" ,(legit-log-checked-description
                      (legit-log-options-follow-p options) "follow renames"))))
      (legit-log-add-popup-entry filters (first entry) (second entry)))
    (dolist
        (entry
          `(("- o" ,(format nil "order: ~a"
                             (or (legit-log-options-order options) "default")))
            ("- r" ,(legit-log-checked-description
                      (legit-log-options-reverse-p options) "reverse"))
            ("- g" ,(legit-log-checked-description
                      (legit-log-options-graph-p options) "graph"))
            ("- c" ,(legit-log-checked-description
                      (legit-log-options-color-p options) "graph color"))
            ("- d" ,(legit-log-checked-description
                      (legit-log-options-decorate-p options) "refnames"))
            ("= S" ,(legit-log-checked-description
                      (legit-log-options-signatures-p options) "signatures"))
            ("- h" ,(legit-log-checked-description
                      (legit-log-options-header-p options) "headers"))
            ("- p" ,(legit-log-checked-description
                      (legit-log-options-patch-p options) "patches"))
            ("- s" ,(legit-log-checked-description
                      (legit-log-options-stat-p options) "diffstats"))))
      (legit-log-add-popup-entry formatting (first entry) (second entry)))
    (dolist (entry '(("l" "current") ("o" "other") ("h" "HEAD")
                     ("u" "related") ("L" "local branches")
                     ("b" "all branches") ("a" "all references")
                     ("r" "current reflog") ("O" "other reflog")
                     ("H" "HEAD reflog") ("s" "shortlog")
                     ("q" "cancel")))
      (legit-log-add-popup-entry actions (first entry) (second entry)))
    keymap))

(defun legit-log-read-popup-key ()
  (let* ((first (read-key))
         (name (lem-core::keyseq-to-string (list first))))
    (if (member name '("-" "=") :test #'string=)
        (format nil "~a ~a" name
                (lem-core::keyseq-to-string (list (read-key))))
        name)))

(defun legit-log-cycle-order (order)
  (ecase order
    ((nil) :topo)
    (:topo :author-date)
    (:author-date :date)
    (:date nil)))

(defun legit-shortlog-option-arguments (options)
  (remove nil
          (list
           (and (legit-shortlog-options-numbered-p options) "--numbered")
           (and (legit-shortlog-options-summary-p options) "--summary")
           (and (legit-shortlog-options-email-p options) "--email")
           (and (legit-shortlog-options-group options)
                (format nil "--group=~a"
                        (legit-shortlog-options-group options))))))

(defun legit-shortlog-popup-keymap (options)
  (let ((keymap (make-keymap :description "Shortlog")))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :column)
    (dolist
        (entry
          `(("- n" ,(legit-log-checked-description
                      (legit-shortlog-options-numbered-p options)
                      "sort by commit count"))
            ("- s" ,(legit-log-checked-description
                      (legit-shortlog-options-summary-p options)
                      "summary only"))
            ("- e" ,(legit-log-checked-description
                      (legit-shortlog-options-email-p options)
                      "email addresses"))
            ("- g" ,(legit-log-value-description
                      (legit-shortlog-options-group options) "group"))
            ("s" "since") ("r" "range") ("q" "cancel")))
      (legit-log-add-popup-entry keymap (first entry) (second entry)))
    keymap))

(defun legit-shortlog-read-group ()
  (alexandria:when-let
      ((group
         (prompt-for-string
          "Group by (author, committer, trailer:NAME): "
          :history-symbol '*legit-log-shortlog-group-history*
          :completion-function
          (lambda (query)
            (completion-strings query '("author" "committer" "trailer:"))))))
    (legit-log-bounded-value group "shortlog group")
    (unless (or (member group '("author" "committer") :test #'string=)
                (and (alexandria:starts-with-subseq "trailer:" group)
                     (> (length group) (length "trailer:"))))
      (editor-error "Use author, committer, or trailer:NAME."))
    group))

(defun legit-shortlog-display (title revision options)
  (let ((output
          (legit-log-checked-output
           (append (list "--no-pager" "shortlog")
                   (legit-shortlog-option-arguments options)
                   (list revision)))))
    (lem/legit::with-collecting-sources
        (collector :buffer :commits-log
                   :minor-mode 'lem/legit::legit-commits-log-mode
                   :read-only nil)
      (lem/legit::collector-insert title :header t)
      (if (str:blankp output)
          (lem/legit::collector-insert "<no commits>")
          (dolist (line (str:lines output))
            (lem/legit::with-appending-source
                (point
                 :move-function (lambda () (lem/legit::show-diff ""))
                 :visit-file-function (lambda ())
                 :stage-function (lambda ())
                 :unstage-function (lambda ()))
              (insert-string point line :read-only t)))))))

(defun dispatch-legit-shortlog ()
  (let ((options (make-legit-shortlog-options)))
    (unwind-protect
         (loop
           (let ((lem/transient:*transient-popup-delay* 0))
             (keymap-activate (legit-shortlog-popup-keymap options)))
           (redraw-display)
           (let ((name (legit-log-read-popup-key)))
             (lem/transient::hide-transient)
             (cond
               ((or (string= name "q") (string= name "Escape"))
                (return nil))
               ((string= name "- n")
                (setf (legit-shortlog-options-numbered-p options)
                      (not (legit-shortlog-options-numbered-p options))))
               ((string= name "- s")
                (setf (legit-shortlog-options-summary-p options)
                      (not (legit-shortlog-options-summary-p options))))
               ((string= name "- e")
                (setf (legit-shortlog-options-email-p options)
                      (not (legit-shortlog-options-email-p options))))
               ((string= name "- g")
                (setf (legit-shortlog-options-group options)
                      (if (legit-shortlog-options-group options)
                          nil
                          (legit-shortlog-read-group))))
               ((string= name "s")
                (alexandria:when-let
                    ((revisions (legit-log-read-revisions "Shortlog since: ")))
                  (unless (= (length revisions) 1)
                    (editor-error "Shortlog accepts one starting revision."))
                  (let ((revision (first revisions)))
                    (legit-shortlog-display
                     (format nil "Shortlog since ~a:" revision)
                     (format nil "~a.." revision) options)))
                (return t))
               ((string= name "r")
                (alexandria:when-let
                    ((revisions (legit-log-read-revisions "Shortlog range: ")))
                  (unless (= (length revisions) 1)
                    (editor-error "Shortlog accepts one revision or range."))
                  (legit-shortlog-display
                   (format nil "Shortlog for ~a:" (first revisions))
                   (first revisions) options))
                (return t))
               (t (message "No shortlog action is bound to ~a" name)
                  (return nil)))))
      (lem/transient::hide-transient))))

(defun dispatch-legit-log ()
  "Display and execute the normally visible pinned Magit log surface."
  (let ((options
          (alexandria:if-let
              ((state (buffer-value (current-buffer) 'legit-log-state)))
            (copy-legit-log-options (legit-log-state-options state))
            (make-legit-log-options))))
    (unwind-protect
         (loop
           (let ((lem/transient:*transient-popup-delay* 0))
             (keymap-activate (legit-log-popup-keymap options)))
           (redraw-display)
           (let ((name (legit-log-read-popup-key)))
             (lem/transient::hide-transient)
             (cond
               ((or (string= name "q") (string= name "Escape"))
                (message "Log cancelled.")
                (return nil))
               ((string= name "- n")
                (setf (legit-log-options-limit options)
                      (if (legit-log-options-limit options)
                          nil (legit-log-read-limit))))
               ((string= name "- A")
                (setf (legit-log-options-author options)
                      (if (legit-log-options-author options) nil
                          (legit-log-read-string-option
                           "Limit to author: " '*legit-log-author-history*
                           "author pattern"))))
               ((string= name "- F")
                (setf (legit-log-options-grep options)
                      (if (legit-log-options-grep options) nil
                          (legit-log-read-string-option
                           "Search commit messages: " '*legit-log-grep-history*
                           "message pattern"))))
               ((string= name "- G")
                (setf (legit-log-options-pickaxe-regexp options)
                      (if (legit-log-options-pickaxe-regexp options) nil
                          (legit-log-read-string-option
                           "Search changed lines (regexp): "
                           '*legit-log-pickaxe-history* "change regexp"))))
               ((string= name "- S")
                (setf (legit-log-options-pickaxe-string options)
                      (if (legit-log-options-pickaxe-string options) nil
                          (legit-log-read-string-option
                           "Search changed occurrence: "
                           '*legit-log-pickaxe-history* "occurrence"))))
               ((string= name "- L")
                (setf (legit-log-options-trace options)
                      (if (legit-log-options-trace options) nil
                          (legit-log-read-trace))))
               ((string= name "- D")
                (setf (legit-log-options-simplify-decoration-p options)
                      (not (legit-log-options-simplify-decoration-p options))))
               ((string= name "- -")
                (setf (legit-log-options-files options)
                      (if (legit-log-options-files options) nil
                          (legit-log-read-paths))))
               ((string= name "- f")
                (setf (legit-log-options-follow-p options)
                      (not (legit-log-options-follow-p options))))
               ((string= name "- o")
                (setf (legit-log-options-order options)
                      (legit-log-cycle-order
                       (legit-log-options-order options))))
               ((string= name "- r")
                (setf (legit-log-options-reverse-p options)
                      (not (legit-log-options-reverse-p options))))
               ((string= name "- g")
                (setf (legit-log-options-graph-p options)
                      (not (legit-log-options-graph-p options))))
               ((string= name "- c")
                (setf (legit-log-options-color-p options)
                      (not (legit-log-options-color-p options))))
               ((string= name "- d")
                (setf (legit-log-options-decorate-p options)
                      (not (legit-log-options-decorate-p options))))
               ((string= name "= S")
                (setf (legit-log-options-signatures-p options)
                      (not (legit-log-options-signatures-p options))))
               ((string= name "- h")
                (setf (legit-log-options-header-p options)
                      (not (legit-log-options-header-p options))))
               ((string= name "- p")
                (setf (legit-log-options-patch-p options)
                      (not (legit-log-options-patch-p options))))
               ((string= name "- s")
                (setf (legit-log-options-stat-p options)
                      (not (legit-log-options-stat-p options))))
               ((string= name "l")
                (legit-log-open "Current log" (list (legit-log-current-ref)) options)
                (return t))
               ((string= name "o")
                (alexandria:when-let
                    ((revisions (legit-log-read-revisions "Log revision(s): ")))
                  (legit-log-open "Selected log" revisions options))
                (return t))
               ((string= name "h")
                (legit-log-open "HEAD log" '("HEAD") options)
                (return t))
               ((string= name "u")
                (legit-log-open "Related log" (legit-log-related-revisions) options)
                (return t))
               ((string= name "L")
                (legit-log-open "Local branches" '("--branches") options)
                (return t))
               ((string= name "b")
                (legit-log-open "All branches" '("--branches" "--remotes") options)
                (return t))
               ((string= name "a")
                (legit-log-open "All references" '("--all") options)
                (return t))
               ((string= name "r")
                (let ((ref (legit-log-current-ref)))
                  (legit-log-open-reflog (format nil "Reflog ~a" ref) ref))
                (return t))
               ((string= name "O")
                (alexandria:when-let
                    ((references
                       (legit-log-read-revisions "Reflog reference: ")))
                  (unless (= (length references) 1)
                    (editor-error "Reflog accepts one reference."))
                  (let ((reference (first references)))
                  (legit-log-open-reflog
                   (format nil "Reflog ~a" reference) reference)))
                (return t))
               ((string= name "H")
                (legit-log-open-reflog "Reflog HEAD" "HEAD")
                (return t))
               ((string= name "s")
                (dispatch-legit-shortlog)
                (return t))
               (t (message "No log action is bound to ~a" name)
                  (return nil)))))
      (lem/transient::hide-transient))))

(define-command lem-yath-legit-log () ()
  "Open the configured Magit-compatible Git log transient."
  (lem/legit::with-current-project (vcs)
    (legit-log-require-git vcs)
    (dispatch-legit-log)))

(define-key lem/legit::*peek-legit-keymap* "l" 'lem-yath-legit-log)
(define-key lem/legit::*legit-diff-mode-keymap* "l" 'lem-yath-legit-log)
(define-key lem/legit::*legit-commits-log-keymap* "l" 'lem-yath-legit-log)
(define-key lem/legit::*legit-commits-log-keymap* "g f"
            'lem-yath-legit-log-next-page)
(define-key lem/legit::*legit-commits-log-keymap* "g b"
            'lem-yath-legit-log-previous-page)
(define-key lem/legit::*legit-commits-log-keymap* "g F"
            'lem-yath-legit-log-last-page)
(define-key lem/legit::*legit-commits-log-keymap* "g B"
            'lem-yath-legit-log-first-page)
(define-key lem/legit::*legit-commits-log-keymap* "g r"
            'lem-yath-legit-log-refresh)
(define-key lem/legit::*legit-commits-log-keymap* "="
            'lem-yath-legit-log-toggle-limit)
(define-key lem/legit::*legit-commits-log-keymap* "q"
            'lem-yath-legit-log-back-to-status)
