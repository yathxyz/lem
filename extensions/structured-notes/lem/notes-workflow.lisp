(in-package #:lem-structured-notes/lem-adapter)

(eval-when (:compile-toplevel :load-toplevel :execute) (require :sb-posix))

(define-condition notes-adapter-error (error)
  ((code :initarg :code :reader notes-adapter-error-code)
   (message :initarg :message :reader notes-adapter-error-message))
  (:report (lambda (condition stream) (write-string (notes-adapter-error-message condition) stream))))
(defun adapter-error (code message) (error 'notes-adapter-error :code code :message message))
(defun require-editor ()
  (let ((editor (lem:find-editor-thread)))
    (when (and editor (not (eq editor (bt2:current-thread))))
      (adapter-error :wrong-thread "Notes buffer operations belong on the editor thread"))))

(defstruct (lem-notes-workspace-context (:constructor %make-workspaces (workspace public-workspace)))
  (workspace nil :read-only t) (public-workspace nil :read-only t))
(defvar *lem-notes-workspace-context* nil)
(defvar *buffer-sequence* 0)
(defconstant +maximum-source-characters+ (* 1024 1024))

(defun literal-pathname (value)
  (unless (or (stringp value) (pathnamep value))
    (adapter-error :invalid-path "Notes paths must be absolute local pathnames"))
  (let ((text (if (pathnamep value) (uiop:native-namestring value) value)))
    (unless (and (plusp (length text)) (char= #\/ (char text 0))
                 (not (search "//" text))
                 (not (find-if (lambda (c) (or (< (char-code c) 32) (= 127 (char-code c)))) text)))
      (adapter-error :invalid-path "Notes paths must be absolute local pathnames without controls"))
    (sb-ext:parse-native-namestring text)))

(defun configured-workspace (root)
  (handler-case
      (let* ((path (uiop:ensure-directory-pathname (literal-pathname root)))
             (canonical (truename path)))
        (unless (sb-posix:s-isdir (sb-posix:stat-mode (sb-posix:stat (uiop:native-namestring canonical))))
          (adapter-error :unavailable-workspace "Notes workspace must be an existing directory"))
        (resolve-notes-workspace canonical))
    (notes-adapter-error (condition) (error condition))
    (error () (adapter-error :unavailable-workspace "Notes workspace is unavailable; configure an existing directory"))))

(defun configure-lem-notes-workspaces (&key work-root public-root)
  "Pin explicit existing roots once. Never read environment defaults or create directories."
  (let* ((candidate (%make-workspaces (configured-workspace work-root)
                                    (when public-root (configured-workspace public-root))))
         (old *lem-notes-workspace-context*))
    (flet ((root (workspace) (when workspace (notes-workspace-root workspace))))
      (cond ((null old) (setf *lem-notes-workspace-context* candidate))
            ((and (equal (root (lem-notes-workspace-context-workspace old))
                         (root (lem-notes-workspace-context-workspace candidate)))
                  (equal (root (lem-notes-workspace-context-public-workspace old))
                         (root (lem-notes-workspace-context-public-workspace candidate)))) old)
            (t (adapter-error :conflicting-workspaces "Notes workspaces are already pinned to different roots"))))))

(defun lem-current-notes-workspaces ()
  "Return configured roots; attaching a client never selects a notes workspace."
  (or *lem-notes-workspace-context*
      (adapter-error :unavailable-workspace "Notes workspace is unavailable; configure explicit roots before using LSM commands")))

(defun require-workspace (workspace)
  (let ((context (lem-current-notes-workspaces)))
    (unless (member workspace (list (lem-notes-workspace-context-workspace context)
                                   (lem-notes-workspace-context-public-workspace context)) :test #'eq)
      (adapter-error :unconfigured-workspace "This workspace is not one of the configured notes roots")))
  workspace)

(defun target-info (target)
  "Validate one literal root-relative target before an explicit file visit."
  (let* ((path (literal-pathname target)) (text (uiop:native-namestring path))
         (context (lem-current-notes-workspaces))
         (workspace
           (find-if (lambda (workspace)
                      (and workspace
                           (let ((root (uiop:native-namestring (notes-workspace-root workspace))))
                             (and (< (length root) (length text))
                                  (string= root text :end2 (length root))))))
                    (list (lem-notes-workspace-context-workspace context)
                          (lem-notes-workspace-context-public-workspace context)))))
    (unless workspace (adapter-error :outside-workspace "Notes target is outside the configured roots"))
    (let* ((root (uiop:native-namestring (notes-workspace-root workspace)))
           (parts (uiop:split-string (subseq text (length root)) :separator "/"))
           (current root) (exists nil))
      (unless (every (lambda (part) (and (plusp (length part)) (not (member part '("." "..") :test #'equal)))) parts)
        (adapter-error :invalid-target "Notes targets cannot contain empty or dot path segments"))
      (loop for rest on parts for last = (null (cdr rest))
            do (setf current (concatenate 'string current (car rest)))
               (let ((stat (handler-case (sb-posix:lstat current)
                             (sb-posix:syscall-error (condition)
                               (unless (and last (= sb-posix:enoent (sb-posix:syscall-errno condition)))
                                 (adapter-error :unavailable-parent "Notes parent directory is unavailable; create it explicitly first"))))))
                 (when stat
                   (let ((mode (sb-posix:stat-mode stat)))
                     (unless (if last (sb-posix:s-isreg mode) (sb-posix:s-isdir mode))
                       (adapter-error :unsafe-target "Notes paths must use ordinary directories and regular files, without symlinks"))
                     (when last
                       (when (> (sb-posix:stat-size stat) (* 4 +maximum-source-characters+))
                         (adapter-error :source-too-large "Notes source exceeds the bounded editor workflow"))
                       (setf exists t)))))
               (unless last (setf current (concatenate 'string current "/"))))
      (values text exists workspace))))

;; This opaque object is captured BEFORE pure planning. A pathname and matching
;; text cannot recreate its live buffer identity or erase an intervening edit.
(defstruct (notes-source (:constructor %make-source (buffer tick filename source existed authority identity)))
  (buffer nil :read-only t) (tick 0 :read-only t) (filename "" :read-only t)
  (source "" :read-only t) (existed nil :read-only t) (authority nil :read-only t)
  (identity nil :read-only t))

(defun lem-capture-notes-source (buffer)
  "Capture a bounded live file buffer and its revision before constructing any plan."
  (require-editor)
  (unless (and (lem:bufferp buffer) (not (lem:deleted-buffer-p buffer)) (lem:buffer-filename buffer))
    (adapter-error :unavailable-buffer "Notes editing requires a live file buffer; recovered unnamed text needs an explicit file association"))
  (when (> (1- (lem:position-at-point (lem:buffer-end-point buffer))) +maximum-source-characters+)
    (adapter-error :source-too-large "Notes source exceeds the bounded editor workflow"))
  (multiple-value-bind (filename existed) (target-info (lem:buffer-filename buffer))
    (%make-source buffer (lem:buffer-modified-tick buffer) (copy-seq filename) (lem:buffer-text buffer) existed
                  (lem-current-notes-workspaces)
                  (or (lem:buffer-value buffer 'notes-identity)
                      (setf (lem:buffer-value buffer 'notes-identity) (incf *buffer-sequence*))))))

(defun lem-notes-source-base (context)
  "Return a copied base for a pure document planner; NIL denotes a new empty file."
  (check-type context notes-source)
  (if (or (notes-source-existed context) (plusp (length (notes-source-source context))))
      (copy-seq (notes-source-source context)) nil))

(defun require-current-source (context)
  (require-editor)
  (unless (typep context 'notes-source)
    (adapter-error :missing-provenance "Notes application requires its original planning-time source context"))
  (let ((buffer (notes-source-buffer context)))
    (unless (and (eq (notes-source-authority context) (lem-current-notes-workspaces))
                 (not (lem:deleted-buffer-p buffer))
                 (eql (notes-source-identity context) (lem:buffer-value buffer 'notes-identity))
                 (= (notes-source-tick context) (lem:buffer-modified-tick buffer))
                 (equal (notes-source-filename context) (lem:buffer-filename buffer))
                 (equal (notes-source-source context) (lem:buffer-text buffer)))
      (adapter-error :stale-source "Notes source changed or was replaced after planning; make a fresh plan"))
    (when (lem:buffer-read-only-p buffer)
      (adapter-error :read-only-source "Notes target buffer is read-only"))
    buffer))

(defun source-revision (context)
  (format nil "lem-notes/~d/~d" (notes-source-identity context) (notes-source-tick context)))

(defun lem-current-lsm-snapshot (buffer)
  "Return the semantic snapshot and its opaque live planning context as a second value."
  (let ((context (lem-capture-notes-source buffer)))
    (values (parse-source (make-instance 'lsm-provider) (notes-source-source context)
                          :source-id (notes-source-filename context) :revision (source-revision context))
            context)))

(defun stage-output (context output)
  (let ((buffer (require-current-source context)) (proposal nil))
    (when (equal output (notes-source-source context)) (return-from stage-output nil))
    (handler-case
        (progn
          (setf proposal (proposals:capture-region (lem:buffer-start-point buffer) (lem:buffer-end-point buffer)))
          (proposals:stage-replacement proposal output))
      (error (condition)
        (when proposal (proposals:reject-proposal proposal) (proposals:forget-proposal proposal))
        (error condition)))))

(defun lem-stage-notes-document-plan (context plan)
  "Verify and stage a pure daily/journal/capture plan. Return proposal (or NIL for reuse) and focus."
  (require-current-source context)
  (unless (and (notes-document-plan-p plan)
               (equal (notes-source-filename context)
                      (uiop:native-namestring (notes-document-plan-target-path plan))))
    (adapter-error :mismatched-plan "Notes plan does not target its captured buffer"))
  (let* ((output (apply-notes-document-plan plan (lem-notes-source-base context)))
         (snapshot (parse-source (make-instance 'lsm-provider) output
                                 :source-id (notes-source-filename context) :revision "notes-plan/verification"))
         (node (find-semantic-node (source-snapshot-document snapshot) (notes-document-plan-focus-node-id plan))))
    (unless node (adapter-error :missing-focus "Notes plan output does not contain its focus node"))
    (values (stage-output context output) (1+ (source-span-character-start (semantic-node-span node))))))

(defun edit-focus-id (plan)
  (let ((operation (first (edit-plan-operations plan))))
    (unless operation (adapter-error :empty-plan "Notes edit requires an operation"))
    (case (edit-operation-kind operation)
      (:assign-node-id (edit-operation-payload operation))
      (:insert-heading-after-subtree (getf (edit-operation-payload operation) :new-node-id))
      (otherwise (edit-operation-target-id operation)))))

(defun lem-stage-lsm-edit-plan (context plan snapshot)
  "Verify domain identity/fingerprints and live provenance, then stage without editing or saving."
  (require-current-source context)
  (unless (and (typep plan 'edit-plan) (typep snapshot 'source-snapshot)
               (typep (source-snapshot-provider snapshot) 'lsm-provider)
               (eq (edit-plan-provider plan) (source-snapshot-provider snapshot))
               (equal (source-snapshot-source-id snapshot) (notes-source-filename context))
               (equal (source-snapshot-revision snapshot) (source-revision context))
               (equal (lsm-syntax-document-source (source-snapshot-syntax-tree snapshot)) (notes-source-source context)))
    (adapter-error :mismatched-plan "LSM edit requires the snapshot from its planning-time source context"))
  (let* ((updated (apply-source-edit (source-snapshot-provider snapshot) plan snapshot
                                   :new-revision "notes-plan/verified-candidate"))
         (node (find-semantic-node (source-snapshot-document updated) (edit-focus-id plan))))
    (unless node (adapter-error :missing-focus "LSM edit output does not contain its focus node"))
    (values (stage-output context (lsm-syntax-document-source (source-snapshot-syntax-tree updated)))
            (1+ (source-span-character-start (semantic-node-span node))) updated)))

(defun apply-staged (context proposal focus)
  (let ((buffer (require-current-source context)))
    (when proposal
      (handler-case (proposals:apply-proposal proposal)
        (error (condition)
          (proposals:reject-proposal proposal) (proposals:forget-proposal proposal)
          (error condition))))
    (lem:move-to-position (lem:buffer-point buffer) focus)
    buffer))

(defun lem-apply-notes-document-plan (context plan)
  "Apply a deliberately requested document edit as one unsaved undo unit."
  (multiple-value-bind (proposal focus) (lem-stage-notes-document-plan context plan)
    (values (apply-staged context proposal focus) focus)))
(defun lem-apply-lsm-edit-plan (context plan snapshot)
  "Apply a deliberately requested semantic edit as one unsaved undo unit."
  (multiple-value-bind (proposal focus updated) (lem-stage-lsm-edit-plan context plan snapshot)
    (values updated (apply-staged context proposal focus) focus)))

(defun lem-current-lsm-node (buffer snapshot)
  (let ((position (1- (lem:position-at-point (lem:buffer-point buffer)))) (current nil))
    (dolist (node (semantic-document-nodes (source-snapshot-document snapshot)))
      (when (and (<= (source-span-character-start (semantic-node-span node)) position)
                 (or (null current) (> (source-span-character-start (semantic-node-span node))
                                       (source-span-character-start (semantic-node-span current)))))
        (setf current node)))
    (or current (adapter-error :missing-node "Point is before the first semantic LSM heading"))))

(defun lem-assign-current-lsm-node-id (buffer proposed-id)
  "Create or reuse the current heading ID, leaving any change unsaved."
  (multiple-value-bind (snapshot context) (lem-current-lsm-snapshot buffer)
    (let ((node (lem-current-lsm-node buffer snapshot)))
      (multiple-value-bind (id plan) (plan-lsm-node-id snapshot (semantic-node-id node) :proposed-id proposed-id)
        (when plan (lem-apply-lsm-edit-plan context plan snapshot))
        id))))

(defun lem-set-current-lsm-task-state (buffer state)
  "Set the current LSM task state as one unsaved undo unit."
  (multiple-value-bind (snapshot context) (lem-current-lsm-snapshot buffer)
    (let* ((node (lem-current-lsm-node buffer snapshot))
           (operation (make-edit-operation :kind :set-task-state :target-id (semantic-node-id node)
                                           :payload (list :state state :done-p
                                                          (not (null (member (string-upcase state) '("DONE" "CANCELLED") :test #'equal))))))
           (plan (plan-source-edit (source-snapshot-provider snapshot) snapshot operation)))
      (lem-apply-lsm-edit-plan context plan snapshot))))

(defun call-with-notes-target (target planner switch-p)
  (require-editor)
  (multiple-value-bind (filename) (target-info target)
    (let* ((existing (remove-if-not (lambda (buffer) (equal filename (lem:buffer-filename buffer))) (lem:buffer-list)))
           (buffer nil) (created nil) (complete nil))
      (when (cdr existing) (adapter-error :ambiguous-buffer "Several buffers visit this notes target; resolve the duplicate first"))
      (unwind-protect
           (progn
             ;; Only an explicit operator visit reaches normal file hooks. Keep
             ;; new buffers private until planning and application succeed.
             (setf buffer (or (first existing) (lem:find-file-buffer filename :temporary t))
                   created (null existing))
             (let* ((context (lem-capture-notes-source buffer))
                    (plan (funcall planner (lem-notes-source-base context))))
               (lem-apply-notes-document-plan context plan))
             (when created
               (setf (lem/buffer/internal::buffer-%name buffer) (lem:unique-buffer-name (lem:buffer-name buffer))
                     (slot-value buffer 'lem/buffer/internal::temporary) nil)
               (lem/buffer/internal::add-buffer buffer))
             (setf complete t)
             (when switch-p (lem:switch-to-window (lem:pop-to-buffer buffer)))
             buffer)
        (when (and created buffer (not complete))
          (unwind-protect (ignore-errors (lem:delete-buffer buffer))
            (unless (lem:deleted-buffer-p buffer) (lem/buffer/internal::buffer-free buffer))))))))

(defun lem-open-lsm-daily-note (workspace date &key (switch-p t))
  "Open DATE's daily note without creating directories or saving."
  (require-workspace workspace)
  (call-with-notes-target (notes-workspace-daily-path workspace date)
                         (lambda (source) (plan-lsm-daily-note workspace date :current-source source)) switch-p))
(defun lem-append-lsm-journal-entry (workspace time &key timezone (switch-p t))
  "Append one journal entry without creating directories or saving."
  (require-workspace workspace)
  (call-with-notes-target (notes-workspace-journal-path workspace time :timezone timezone)
                         (lambda (source) (plan-lsm-journal-entry workspace time :timezone timezone :current-source source)) switch-p))
(defun lem-capture-lsm-note (workspace key title time &key timezone public-workspace origin (body-source "") (switch-p t))
  "Append one capture without creating directories or saving."
  (require-workspace workspace)
  (when public-workspace (require-workspace public-workspace))
  (call-with-notes-target (notes-workspace-capture-path workspace key :public-workspace public-workspace)
                         (lambda (source) (plan-lsm-capture workspace key title time :timezone timezone :current-source source
                                                          :public-workspace public-workspace :origin origin :body-source body-source)) switch-p))

(defun work-workspace () (lem-notes-workspace-context-workspace (lem-current-notes-workspaces)))
(defun lem-notes-now () (get-universal-time))
(defun lem-notes-today ()
  (multiple-value-bind (second minute hour day month year) (decode-universal-time (lem-notes-now))
    (declare (ignore second minute hour)) (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)))
(lem:define-command structured-notes-lsm-open-today () ()
  "Open today's LSM daily note, leaving changes unsaved."
  (lem-open-lsm-daily-note (work-workspace) (lem-notes-today)))
(lem:define-command structured-notes-lsm-journal-entry () ()
  "Append an unsaved LSM journal entry."
  (lem-append-lsm-journal-entry (work-workspace) (lem-notes-now)))
(lem:define-command structured-notes-lsm-capture () ()
  "Capture explicitly into the configured LSM workspace, without saving."
  (let* ((context (lem-current-notes-workspaces))
         (key (lem:prompt-for-string "LSM capture key (i/t/r/p): "))
         (title (lem:prompt-for-string "LSM capture title: ")))
    (lem-capture-lsm-note (lem-notes-workspace-context-workspace context) key title (lem-notes-now)
                          :public-workspace (lem-notes-workspace-context-public-workspace context))))
(lem:define-command structured-notes-lsm-assign-id () ()
  "Assign or reuse the current LSM heading ID without saving."
  (lem:message "LSM node ID: ~a" (lem-assign-current-lsm-node-id (lem:current-buffer) (generate-lsm-node-id))))
