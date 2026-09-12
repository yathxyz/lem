(in-package #:lem-structured-notes)

(define-condition notes-workflow-error (error)
  ((code
    :initarg :code
    :reader notes-workflow-error-code)
   (value
    :initarg :value
    :reader notes-workflow-error-value)
   (message
    :initarg :message
    :reader notes-workflow-error-message))
  (:report
   (lambda (condition stream)
     (format stream "Notes workflow error ~s: ~a"
             (notes-workflow-error-code condition)
             (notes-workflow-error-message condition)))))

(defun notes-workflow-error (code value control &rest arguments)
  (error 'notes-workflow-error
         :code code :value value
         :message (apply #'format nil control arguments)))

(defconstant +notes-node-id-random-octets+ 16)
(defconstant +notes-capture-body-character-limit+ (* 1024 1024))

(defun notes-node-id-os-random-data (count)
  #+unix
  (with-open-file
      (stream #p"/dev/urandom" :direction :input
                              :element-type '(unsigned-byte 8))
    (let ((octets (make-array count :element-type '(unsigned-byte 8))))
      (unless (= count (read-sequence octets stream))
        (error "OS entropy source returned fewer octets than requested"))
      octets))
  #-unix
  (declare (ignore count))
  #-unix
  (error "No supported OS entropy source is available"))

(defvar *notes-node-id-random-data-function* #'notes-node-id-os-random-data)

(defun generate-lsm-node-id ()
  "Generate one lowercase RFC 9562 version-4 persistent heading ID."
  (let ((random
          (handler-case
              (funcall *notes-node-id-random-data-function*
                       +notes-node-id-random-octets+)
            (error ()
              (notes-workflow-error
               :notes-node-id-entropy-failure :unavailable
               "OS cryptographic entropy is unavailable")))))
    (unless (and (typep random '(vector (unsigned-byte 8)))
                 (= +notes-node-id-random-octets+ (length random)))
      (notes-workflow-error
       :invalid-notes-node-id-entropy random
       "node ID entropy must contain exactly 16 octets"))
    (let ((octets (copy-seq random)))
      (setf (aref octets 6)
            (logior #x40 (logand #x0f (aref octets 6)))
            (aref octets 8)
            (logior #x80 (logand #x3f (aref octets 8))))
      (string-downcase
       (with-output-to-string (stream)
         (dotimes (index +notes-node-id-random-octets+)
           (when (member index '(4 6 8 10))
             (write-char #\- stream))
           (format stream "~2,'0x" (aref octets index))))))))

(defstruct (notes-workspace
            (:constructor %make-notes-workspace (root roam-root journal-root)))
  (root nil :type pathname :read-only t)
  (roam-root nil :type pathname :read-only t)
  (journal-root nil :type pathname :read-only t))

(defstruct (notes-capture-origin
            (:constructor %make-notes-capture-origin
                (provider scope path node-id date)))
  (provider :lsm :type keyword :read-only t)
  (scope :work :type keyword :read-only t)
  (path "" :type string :read-only t)
  (node-id nil :type (or null string) :read-only t)
  (date nil :type (or null string) :read-only t))

(defun notes-control-character-p (character)
  (let ((code (char-code character)))
    (or (< code 32) (= code 127))))

(defun valid-notes-capture-origin-path-p (path)
  (and (stringp path)
       (plusp (length path))
       (<= (length path) 4096)
       (not (member (char path 0) '(#\/ #\\)))
       (not (find #\\ path))
       (not (find-if #'notes-control-character-p path))
       (let ((start 0)
             (length (length path)))
         (loop
           for end = (or (position #\/ path :start start) length)
           for segment = (subseq path start end)
           always (and (plusp (length segment))
                       (not (member segment '("." "..") :test #'string=)))
           while (< end length)
           do (setf start (1+ end))))))

(defun valid-notes-capture-origin-node-id-p (node-id)
  (and (stringp node-id)
       (plusp (length node-id))
       (<= (length node-id) 4096)
       (not (find-if #'notes-control-character-p node-id))))

(defun make-notes-capture-origin
    (&key provider scope path node-id date)
  "Create immutable, root-relative context for a native LSM capture."
  (unless (member provider '(:org :lsm :file))
    (notes-workflow-error :invalid-capture-origin-provider provider
                          "capture origin provider must be :ORG, :LSM, or :FILE"))
  (unless (member scope '(:work :public))
    (notes-workflow-error :invalid-capture-origin-scope scope
                          "capture origin scope must be :WORK or :PUBLIC"))
  (unless (valid-notes-capture-origin-path-p path)
    (notes-workflow-error
     :invalid-capture-origin-path path
     "capture origin path must be a bounded, root-relative slash path without dot segments or controls"))
  (unless (or (null node-id)
              (valid-notes-capture-origin-node-id-p node-id))
    (notes-workflow-error
     :invalid-capture-origin-node-id node-id
     "capture origin node ID must be NIL or nonempty, bounded, and control-free"))
  (when (and date (not (valid-notes-iso-date-p date)))
    (notes-workflow-error :invalid-capture-origin-date date
                          "capture origin date must be NIL or a real YYYY-MM-DD date"))
  (%make-notes-capture-origin provider scope path node-id date))

(defstruct (notes-document-plan
            (:constructor %make-notes-document-plan
                (kind target-path base-source output-source document-id
                 focus-node-id created-p)))
  (kind :daily :type keyword :read-only t)
  (target-path nil :type pathname :read-only t)
  (base-source nil :type (or null string) :read-only t)
  (output-source "" :type string :read-only t)
  (document-id "" :type string :read-only t)
  (focus-node-id "" :type string :read-only t)
  (created-p nil :type boolean :read-only t))

(defun normalize-notes-directory (pathname context)
  (let* ((directory
           (uiop:ensure-directory-pathname
            (uiop:ensure-absolute-pathname pathname)))
         (components (pathname-directory directory)))
    (unless (and (consp components) (eq :absolute (first components)))
      (notes-workflow-error :relative-notes-directory pathname
                            "~a must resolve to an absolute directory"
                            context))
    (let ((normalized nil))
      (dolist (component (rest components))
        (cond
          ((or (eq component :current)
               (and (stringp component) (string= component "."))))
          ((or (eq component :up)
               (and (stringp component) (string= component "..")))
           (unless normalized
             (notes-workflow-error :notes-directory-escapes-root pathname
                                   "~a traverses above the filesystem root"
                                   context))
           (pop normalized))
          ((and (stringp component)
                (plusp (length component))
                (not (find-if (lambda (character)
                                (or (char= character #\Null)
                                    (char= character #\Newline)
                                    (char= character #\Return)))
                              component)))
           (push component normalized))
          (t
           (notes-workflow-error :unsafe-notes-directory pathname
                                 "~a contains an unsupported pathname component"
                                 context))))
      (make-pathname :host (pathname-host directory)
                     :device (pathname-device directory)
                     :directory (cons :absolute (nreverse normalized))
                     :name nil :type nil :version nil))))

(defun notes-home-relative-pathname (configured home)
  (cond
    ((string= configured "~") home)
    ((and (>= (length configured) 2)
          (char= #\~ (char configured 0))
          (member (char configured 1) '(#\/ #\\)))
     (merge-pathnames (subseq configured 2) home))
    ((and (plusp (length configured))
          (char= #\~ (char configured 0)))
     (notes-workflow-error :unsupported-user-home configured
                           "named-user tilde expansion is not supported"))
    (t nil)))

(defun resolve-notes-workspace
    (configured &key (launch-directory (uiop:getcwd))
                     (home-directory (user-homedir-pathname)))
  "Resolve the shared notes root without creating or changing any filesystem state."
  (unless (or (null configured) (stringp configured) (pathnamep configured))
    (notes-workflow-error :invalid-notes-root configured
                          "configured notes root must be a string, pathname, or NIL"))
  (let* ((launch
           (normalize-notes-directory launch-directory "launch directory"))
         (home (normalize-notes-directory home-directory "home directory"))
         (configured-string
           (cond
             ((null configured) "")
             ((pathnamep configured) (namestring configured))
             (t configured)))
         (selected (if (plusp (length configured-string))
                       configured-string
                       "~/work"))
         (home-relative (notes-home-relative-pathname selected home))
         (selected-path (or home-relative (pathname selected)))
         (absolute
           (if (uiop:absolute-pathname-p selected-path)
               selected-path
               (merge-pathnames selected-path launch)))
         (root (normalize-notes-directory absolute "notes root"))
         (roam-root (merge-pathnames #P"roam/" root)))
    (%make-notes-workspace
     root roam-root (merge-pathnames #P"journal/" roam-root))))

(defun valid-notes-iso-date-p (value)
  (and (stringp value)
       (= 10 (length value))
       (char= #\- (char value 4))
       (char= #\- (char value 7))
       (every #'digit-char-p
              (concatenate 'string (subseq value 0 4)
                           (subseq value 5 7) (subseq value 8 10)))
       (let ((year (parse-integer value :start 0 :end 4))
             (month (parse-integer value :start 5 :end 7))
             (day (parse-integer value :start 8 :end 10)))
         (and (plusp year)
              (<= 1 month 12)
              (<= 1 day (ical-days-in-month year month))))))

(defun require-notes-iso-date (date)
  (unless (valid-notes-iso-date-p date)
    (notes-workflow-error :invalid-daily-date date
                          "daily date must be a real YYYY-MM-DD calendar date"))
  date)

(defun notes-workspace-daily-path (workspace date)
  (unless (notes-workspace-p workspace)
    (notes-workflow-error :invalid-notes-workspace workspace
                          "daily path requires a notes workspace"))
  (merge-pathnames (format nil "~a.md" (require-notes-iso-date date))
                   (notes-workspace-roam-root workspace)))

(defun decode-notes-time (time timezone)
  (unless (and (integerp time) (not (minusp time)))
    (notes-workflow-error :invalid-notes-time time
                          "notes time must be a nonnegative universal time"))
  (when (and timezone
             (not (and (realp timezone) (<= -24 timezone 24))))
    (notes-workflow-error :invalid-notes-timezone timezone
                          "timezone must be NIL or an hour offset from -24 through 24"))
  (if timezone
      (decode-universal-time time timezone)
      (decode-universal-time time)))

(defun notes-time-fields (time timezone)
  (multiple-value-bind (second minute hour day month year day-of-week)
      (decode-notes-time time timezone)
    (values (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)
            (format nil "~4,'0d~2,'0d~2,'0d" year month day)
            (format nil "~2,'0d:~2,'0d" hour minute)
            (elt #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun")
                 day-of-week)
            second)))

(defun notes-workspace-journal-path (workspace time &key timezone)
  (unless (notes-workspace-p workspace)
    (notes-workflow-error :invalid-notes-workspace workspace
                          "journal path requires a notes workspace"))
  (multiple-value-bind (iso compact clock day-name second)
      (notes-time-fields time timezone)
    (declare (ignore iso clock day-name second))
    (merge-pathnames (format nil "~a.md" compact)
                     (notes-workspace-journal-root workspace))))

(defun make-notes-lsm-document (document-id source-uri roots nodes)
  (make-semantic-document
   :id document-id :source-uri source-uri :format :lsm :profile "lsm/1"
   :nodes nodes :root-ids roots :source-revision "notes-workflow/1"))

(defun parse-planned-notes-source (source path)
  (handler-case
      (parse-source (make-instance 'lsm-provider) source
                    :source-id (namestring path)
                    :revision "notes-workflow/verification")
    (error (condition)
      (notes-workflow-error :invalid-existing-lsm source
                            "native notes source is not valid lsm/1: ~a"
                            condition))))

(defun require-planned-document-identity (snapshot document-id node-id title)
  (let* ((document (source-snapshot-document snapshot))
         (node (find-semantic-node document node-id)))
    (unless (string= document-id (semantic-document-id document))
      (notes-workflow-error :mismatched-notes-document-id
                            (semantic-document-id document)
                            "expected document ID ~s" document-id))
    (unless (and node (string= title (semantic-node-title node)))
      (notes-workflow-error :mismatched-notes-root node-id
                            "expected root node ~s titled ~s" node-id title))
    node))

(defun plan-lsm-daily-note (workspace date &key current-source)
  "Plan creation or byte-identical reuse of DATE's native LSM daily note."
  (let* ((date (require-notes-iso-date date))
         (path (notes-workspace-daily-path workspace date))
         (document-id (format nil "daily:~a" date))
         (node-id document-id))
    (if current-source
        (progn
          (unless (stringp current-source)
            (notes-workflow-error :invalid-current-source current-source
                                  "current daily source must be a string or NIL"))
          (require-planned-document-identity
           (parse-planned-notes-source current-source path)
           document-id node-id date)
          (%make-notes-document-plan
           :daily path current-source current-source document-id node-id nil))
        (let* ((node (make-semantic-node :id node-id :level 1 :title date))
               (source
                 (render-lsm-document
                  (make-notes-lsm-document
                   document-id (namestring path) (list node-id) (list node)))))
          (require-planned-document-identity
           (parse-planned-notes-source source path)
           document-id node-id date)
          (%make-notes-document-plan
           :daily path nil source document-id node-id t)))))

(defun journal-entry-ordinal (document compact)
  (let ((prefix (format nil "journal:~a:entry:" compact))
        (maximum 0))
    (dolist (node (semantic-document-nodes document))
      (let ((id (semantic-node-id node)))
        (when (and (> (length id) (length prefix))
                   (string= prefix id :end2 (length prefix))
                   (every #'digit-char-p (subseq id (length prefix))))
          (setf maximum
                (max maximum
                     (parse-integer id :start (length prefix)))))))
    (1+ maximum)))

(defun plan-lsm-journal-entry
    (workspace time &key timezone current-source)
  "Plan one source-preserving native LSM journal entry for TIME."
  (multiple-value-bind (iso compact clock day-name second)
      (notes-time-fields time timezone)
    (declare (ignore second))
    (let* ((path (notes-workspace-journal-path
                  workspace time :timezone timezone))
           (document-id (format nil "journal:~a" compact))
           (root-id document-id)
           (root-title (format nil "~a, ~a" day-name iso)))
      (if current-source
          (progn
            (unless (stringp current-source)
              (notes-workflow-error :invalid-current-source current-source
                                    "current journal source must be a string or NIL"))
            (let* ((snapshot (parse-planned-notes-source current-source path))
                   (document (source-snapshot-document snapshot)))
              (require-planned-document-identity
               snapshot document-id root-id root-title)
              (unless (and (= 1 (length (semantic-document-root-ids document)))
                           (string= root-id
                                    (first (semantic-document-root-ids document))))
                (notes-workflow-error :invalid-journal-roots
                                      (semantic-document-root-ids document)
                                      "journal must contain exactly its configured root"))
              (let* ((ordinal (journal-entry-ordinal document compact))
                     (entry-id
                       (format nil "journal:~a:entry:~4,'0d"
                               compact ordinal))
                     (entry
                       (make-semantic-node
                        :id entry-id :level 2 :title clock
                        :parent-id root-id))
                     (output
                       (concatenate 'string current-source
                                    (render-lsm-node entry)))
                     (verified (parse-planned-notes-source output path))
                     (verified-document
                       (source-snapshot-document verified))
                     (actual (find-semantic-node verified-document entry-id))
                     (reparsed-root
                       (find-semantic-node verified-document root-id)))
                (unless (and actual reparsed-root
                             (string= root-id
                                      (semantic-node-parent-id actual))
                             (member entry-id
                                     (semantic-node-child-ids reparsed-root)
                                     :test #'string=))
                  (notes-workflow-error
                   :invalid-journal-append entry-id
                   "appended journal entry did not reparse under its root"))
                (%make-notes-document-plan
                 :journal path current-source output document-id entry-id nil))))
          (let* ((entry-id (format nil "journal:~a:entry:0001" compact))
                 (entry
                   (make-semantic-node
                    :id entry-id :level 2 :title clock :parent-id root-id))
                 (root
                   (make-semantic-node
                    :id root-id :level 1 :title root-title
                    :child-ids (list entry-id)))
                 (source
                   (render-lsm-document
                    (make-notes-lsm-document
                     document-id (namestring path) (list root-id)
                     (list root entry)))))
            (require-planned-document-identity
             (parse-planned-notes-source source path)
             document-id root-id root-title)
            (%make-notes-document-plan
             :journal path nil source document-id entry-id t))))))

(defun apply-notes-document-plan (plan current-source)
  "Return a plan's exact output only when CURRENT-SOURCE still matches its base."
  (unless (notes-document-plan-p plan)
    (notes-workflow-error :invalid-notes-plan plan
                          "notes application requires a document plan"))
  (unless (equal current-source (notes-document-plan-base-source plan))
    (notes-workflow-error :stale-notes-source current-source
                          "current source differs from the planned base"))
  (copy-seq (notes-document-plan-output-source plan)))

(defparameter *lsm-capture-templates*
  '(("i" "inbox.md" :work nil)
    ("t" "todo.md" :work "TODO")
    ("r" "readlist.md" :work "TODO")
    ("p" "inbox.md" :public "TODO"))
  "Capture key, target basename, workspace scope, and optional task state.")

(defun lsm-capture-template (key)
  (unless (and (stringp key) (= 1 (length key)))
    (notes-workflow-error :invalid-capture-key key
                          "capture key must be one of i, t, r, or p"))
  (or (assoc key *lsm-capture-templates* :test #'string=)
      (notes-workflow-error :unknown-capture-key key
                            "capture key must be one of i, t, r, or p")))

(defun require-capture-title (title)
  (unless (and (stringp title)
               (plusp (length title))
               (<= (length title) 4096)
               (not (find-if (lambda (character)
                               (member character
                                       '(#\Null #\Newline #\Return)))
                             title)))
    (notes-workflow-error :invalid-capture-title title
                          "capture title must be nonempty, single-line text of at most 4096 characters"))
  title)

(defun require-lsm-capture-body-source (source)
  (unless (stringp source)
    (notes-workflow-error
     :invalid-capture-body-source source
     "capture body source must be a string"))
  (when (> (length source) +notes-capture-body-character-limit+)
    (notes-workflow-error
     :capture-body-character-limit-exceeded (length source)
     "capture body exceeds the ~d-character safety limit"
     +notes-capture-body-character-limit+))
  (when (find #\Null source)
    (notes-workflow-error
     :invalid-capture-body-source source
     "capture body must not contain NUL"))
  (let ((octet-length
          (loop for character across source
                sum (utf8-character-octets character))))
    (when (> octet-length +notes-capture-body-character-limit+)
      (notes-workflow-error
       :capture-body-octet-limit-exceeded octet-length
       "UTF-8 capture body exceeds the ~d-octet safety limit"
       +notes-capture-body-character-limit+)))
  source)

(defun parse-lsm-capture-body-source (source)
  "Parse bounded Markdown SOURCE as one canonical native LSM node body.

Headings and reserved LSM directives are refused because capture owns the
new node's identity, hierarchy, facets, and properties.  This keeps arbitrary
draft text from smuggling semantic metadata into the capture plan."
  (require-lsm-capture-body-source source)
  (when (zerop (length source))
    (return-from parse-lsm-capture-body-source nil))
  (let* ((document-id "capture-body:document")
         (node-id "capture-body:node")
         (wrapped
           (format nil
                   "---~%lem:~%  profile: \"lsm/1\"~%  document-id: ~s~%---~%~%# Capture body~%~%:::{lem-node}~%id: ~s~%:::~%~%~a"
                   document-id node-id source))
         (snapshot
           (parse-source (make-instance 'lsm-provider) wrapped
                         :source-id "capture-body.md"
                         :revision "capture-body/input"))
         (document (source-snapshot-document snapshot))
         (nodes (semantic-document-nodes document))
         (node (find-semantic-node document node-id)))
    (unless (and node
                 (= 1 (length nodes))
                 (= 1 (length (semantic-document-root-ids document)))
                 (string= node-id
                          (first (semantic-document-root-ids document)))
                 (null (semantic-node-parent-id node))
                 (null (semantic-node-child-ids node))
                 (null (semantic-node-event node))
                 (null (semantic-node-task node))
                 (null (semantic-node-calendar-bindings node))
                 (null (semantic-node-properties node))
                 (null (remove-if #'generated-lsm-evidence-p
                                  (semantic-node-extensions node))))
      (notes-workflow-error
       :capture-body-semantic-injection source
       "capture body must not contain headings or reserved LSM semantic directives"))
    (handler-case
        (progn
          ;; The canonical writer is the authority for the Markdown/MyST
          ;; subset accepted by an editable capture body.
          (render-lsm-node
           (make-semantic-node
            :id node-id :level 1 :title "Capture body"
            :body (semantic-node-body node)))
          (semantic-node-body node))
      (semantic-model-error (condition)
        (notes-workflow-error
         :unsupported-capture-body source
         "capture body is outside the canonical LSM Markdown subset: ~a"
         condition)))))

(defun notes-created-timestamp (time timezone)
  (multiple-value-bind (second minute hour day month year)
      (decode-notes-time time timezone)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d"
            year month day hour minute second)))

(defun notes-workspace-capture-path
    (workspace key &key public-workspace)
  (destructuring-bind (template-key basename scope task-state)
      (lsm-capture-template key)
    (declare (ignore template-key task-state))
    (let ((target-workspace
            (ecase scope
              (:work workspace)
              (:public
               (or public-workspace
                   (notes-workflow-error
                    :missing-public-workspace key
                    "public capture requires an explicit public workspace"))))))
      (unless (notes-workspace-p target-workspace)
        (notes-workflow-error :invalid-notes-workspace target-workspace
                              "capture target requires a notes workspace"))
      (merge-pathnames basename
                       (notes-workspace-root target-workspace)))))

(defun next-capture-ordinal (document prefix)
  (let ((maximum 0))
    (dolist (node (semantic-document-nodes document))
      (let ((id (semantic-node-id node)))
        (when (and (> (length id) (length prefix))
                   (string= prefix id :end2 (length prefix))
                   (every #'digit-char-p (subseq id (length prefix))))
          (setf maximum
                (max maximum
                     (parse-integer id :start (length prefix)))))))
    (1+ maximum)))

(defun require-notes-capture-origin (origin target-scope)
  (when origin
    (unless (notes-capture-origin-p origin)
      (notes-workflow-error :invalid-capture-origin origin
                            "capture origin must be a notes-capture-origin or NIL"))
    (make-notes-capture-origin
     :provider (notes-capture-origin-provider origin)
     :scope (notes-capture-origin-scope origin)
     :path (notes-capture-origin-path origin)
     :node-id (notes-capture-origin-node-id origin)
     :date (notes-capture-origin-date origin))
    (when (and (eq target-scope :public)
               (not (eq (notes-capture-origin-scope origin) :public)))
      (notes-workflow-error
       :private-origin-for-public-capture origin
       "public capture context may refer only to a public origin")))
  origin)

(defun lsm-capture-properties (created origin)
  (append
   (list (cons "created" created))
   (when origin
     (list
      (cons "capture-origin-provider"
            (string-downcase
             (symbol-name (notes-capture-origin-provider origin))))
      (cons "capture-origin-scope"
            (string-downcase
             (symbol-name (notes-capture-origin-scope origin))))
      (cons "capture-origin-path" (notes-capture-origin-path origin))))
   (when (and origin (notes-capture-origin-node-id origin))
     (list
      (cons "capture-origin-node-id"
            (notes-capture-origin-node-id origin))))
   (when (and origin (notes-capture-origin-date origin))
     (list (cons "capture-origin-date"
                 (notes-capture-origin-date origin))))))

(defun make-lsm-capture-node
    (id level title created task-state &key parent-id origin body)
  (make-semantic-node
   :id id :level level :title title :parent-id parent-id
   :body body
   :properties (lsm-capture-properties created origin)
   :task (and task-state
              (make-task-facet
               :workflow-id "org/default" :state task-state :done-p nil))))

(defun verify-lsm-capture-node
    (source path document-id node-id title created task-state parent-id origin
     body)
  (let* ((snapshot (parse-planned-notes-source source path))
         (document (source-snapshot-document snapshot))
         (node (find-semantic-node document node-id)))
    (unless (string= document-id (semantic-document-id document))
      (notes-workflow-error :mismatched-capture-document-id
                            (semantic-document-id document)
                            "expected capture document ID ~s" document-id))
    (unless (and node
                 (string= title (semantic-node-title node))
                 (equal (lsm-capture-properties created origin)
                        (semantic-node-properties node))
                 (equivalent-list-p body (semantic-node-body node)
                                    #'content-node-equivalent-p)
                 (equal parent-id (semantic-node-parent-id node))
                 (if task-state
                     (and (semantic-node-task node)
                          (string= task-state
                                   (task-facet-state
                                    (semantic-node-task node)))
                          (not (task-facet-done-p
                                (semantic-node-task node))))
                     (null (semantic-node-task node))))
      (notes-workflow-error :invalid-capture-node node-id
                            "captured node did not reparse with its planned semantics"))
    snapshot))

(defun plan-lsm-capture
    (workspace key title time
     &key timezone current-source public-workspace origin
          (body-source ""))
  "Plan one native LSM capture without inventing unavailable editor context."
  (require-capture-title title)
  (let ((body (parse-lsm-capture-body-source body-source)))
    (destructuring-bind (template-key basename scope task-state)
        (lsm-capture-template key)
      (declare (ignore template-key))
      (require-notes-capture-origin origin scope)
      (let* ((path
                (notes-workspace-capture-path
                 workspace key :public-workspace public-workspace))
             (stem (pathname-name (pathname basename)))
             (scope-name (string-downcase (symbol-name scope)))
             (document-id (format nil "capture:~a:~a" scope-name stem))
             (prefix (format nil "~a:entry:" document-id))
             (created (notes-created-timestamp time timezone)))
        (if current-source
            (progn
              (unless (stringp current-source)
                (notes-workflow-error
                 :invalid-current-source current-source
                 "current capture source must be a string or NIL"))
              (let* ((snapshot
                       (parse-planned-notes-source current-source path))
                     (document (source-snapshot-document snapshot)))
                (unless (string= document-id
                                 (semantic-document-id document))
                  (notes-workflow-error
                   :mismatched-capture-document-id
                   (semantic-document-id document)
                   "expected capture document ID ~s" document-id))
                (let* ((root-id (and (eq scope :work) document-id))
                       (root
                         (and root-id
                              (find-semantic-node document root-id))))
                  (when root-id
                    (unless (and root
                                 (string= "Inbox"
                                          (semantic-node-title root))
                                 (= 1
                                    (length
                                     (semantic-document-root-ids document)))
                                 (string= root-id
                                          (first
                                           (semantic-document-root-ids
                                            document))))
                      (notes-workflow-error
                       :invalid-capture-root root-id
                       "work capture document must have one Inbox root")))
                  (let* ((ordinal (next-capture-ordinal document prefix))
                         (node-id (format nil "~a~4,'0d" prefix ordinal))
                         (parent-id root-id)
                         (level (if parent-id 2 1))
                         (node
                           (make-lsm-capture-node
                            node-id level title created task-state
                            :parent-id parent-id :origin origin :body body))
                         (output
                           (concatenate 'string current-source
                                        (render-lsm-node node))))
                    (verify-lsm-capture-node
                     output path document-id node-id title created task-state
                     parent-id origin body)
                    (%make-notes-document-plan
                     :capture path current-source output document-id node-id
                     nil)))))
            (let* ((node-id (format nil "~a0001" prefix))
                   (root-id (and (eq scope :work) document-id))
                   (node
                     (make-lsm-capture-node
                      node-id (if root-id 2 1) title created task-state
                      :parent-id root-id :origin origin :body body))
                   (root
                     (and root-id
                          (make-semantic-node
                           :id root-id :level 1 :title "Inbox"
                           :child-ids (list node-id))))
                   (roots (if root (list root-id) (list node-id)))
                   (nodes (if root (list root node) (list node)))
                   (output
                     (render-lsm-document
                      (make-notes-lsm-document
                       document-id (namestring path) roots nodes))))
              (verify-lsm-capture-node
               output path document-id node-id title created task-state
               root-id origin body)
              (%make-notes-document-plan
               :capture path nil output document-id node-id t)))))))
