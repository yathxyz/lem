(in-package :lem/buffer/internal)

(defconstant +undo-tree-limit+ 2080000)
(defconstant +undo-tree-strong-limit+ 3120000)
(defconstant +undo-tree-outer-limit+ 48000000)
(defconstant +undo-tree-node-limit+ 65536)
(defconstant +undo-tree-edit-limit+ 262144)
(defparameter *undo-tree-route-work-limit* 134217728)

(defvar *inhibit-undo* nil)
(defvar *undo-tree-replaying-p* nil)
(defvar *undo-touched-buffers* '())

(defun undo-tree-replaying-buffer-p (buffer)
  "Return true only while undo history is replaying BUFFER."
  (eq buffer *undo-tree-replaying-p*))

(defvar *undo-tree-history-move-group* nil)

(defstruct (buffer-change-group
            (:constructor %make-buffer-change-group
                (buffer baseline baseline-preferred first-node-id
                 split-open-p split-parent split-parent-preferred)))
  (buffer nil :read-only t)
  (baseline nil :read-only t)
  (baseline-preferred nil :read-only t)
  (first-node-id 0 :read-only t)
  (split-open-p nil :read-only t)
  (split-parent nil :read-only t)
  (split-parent-preferred nil :read-only t)
  (state :active))

(defun buffer-change-group-active-p (group)
  (and (typep group 'buffer-change-group)
       (eq :active (buffer-change-group-state group))))

(defun retained-change-group-p (group)
  (and (typep group 'buffer-change-group)
       (member (buffer-change-group-state group) '(:active :closing))))

(defun retained-buffer-change-group (buffer)
  (let ((group (buffer-%active-change-group buffer)))
    (and (retained-change-group-p group) group)))

(defun ensure-undo-history-move-allowed (buffer)
  "Refuse nested replay and history travel outside a group's close token."
  (when *undo-tree-replaying-p*
    (editor-error "Cannot move undo history during undo replay"))
  (let ((group (retained-buffer-change-group buffer)))
    (when (and group (not (eq group *undo-tree-history-move-group*)))
      (editor-error "Cannot move undo history while a change group is active")))
  t)

(defun active-change-group-protected-node-p (buffer node)
  (let ((group (buffer-%active-change-group buffer)))
    (and (retained-change-group-p group)
         (eq node (buffer-change-group-baseline group)))))

(defun invalidate-buffer-change-group (buffer)
  (let ((group (buffer-%active-change-group buffer)))
    (when group
      (setf (buffer-change-group-state group) :inactive
            (buffer-%active-change-group buffer) nil)))
  nil)

(defstruct (undo-tree-node
            (:constructor %make-undo-tree-node
                (id &key parent edits (payload-bytes 0) point-position)))
  id
  parent
  (children '())
  preferred
  (edits '())
  (payload-bytes 0)
  point-position
  saved-sequence)

(defstruct (undo-tree-ref
            (:constructor %make-undo-tree-ref (buffer generation id)))
  (buffer nil :read-only t)
  (generation 0 :read-only t)
  (id 0 :read-only t))

(defun make-empty-edit-history ()
  (make-array 0 :adjustable t :fill-pointer 0))

(defun inhibit-undo-p ()
  *inhibit-undo*)

(defmacro with-inhibit-undo (() &body body)
  `(let ((*inhibit-undo* t))
     ,@body))

(defun edit-payload-bytes (edit)
  (babel:string-size-in-octets (edit-string edit) :encoding :utf-8))

(defun copy-retained-edit (edit)
  (make-edit (edit-kind edit)
             (edit-position edit)
             (copy-seq (edit-string edit))))

(defun node-in-buffer-p (buffer node)
  (and node
       (eq node
           (gethash (undo-tree-node-id node)
                    (buffer-%undo-tree-table buffer)))))

(defun make-node-ref (buffer node)
  (and node
       (%make-undo-tree-ref buffer
                            (buffer-%undo-tree-generation buffer)
                            (undo-tree-node-id node))))

(defun ensure-buffer-undo-tree (buffer)
  (unless (buffer-%undo-tree-table buffer)
    (let* ((table (make-hash-table :test #'eql))
           (root (%make-undo-tree-node 0)))
      (setf (gethash 0 table) root
            (buffer-%undo-tree-table buffer) table
            (buffer-%undo-tree-root buffer) root
            (buffer-%undo-tree-current buffer) root
            (buffer-%undo-tree-clean buffer)
            (unless (buffer-%undo-tree-untracked-dirty-p buffer) root)
            (buffer-%undo-tree-last-saved buffer) nil
            (buffer-%undo-tree-next-id buffer) 1
            (buffer-%undo-tree-payload-bytes buffer) 0
            (buffer-%undo-tree-node-count buffer) 1
            (buffer-%undo-tree-edit-count buffer) 0
            (buffer-%undo-tree-pending-payload-bytes buffer) 0
            (buffer-%undo-tree-discard-open-p buffer) nil
            (buffer-%undo-tree-pending-dirty-p buffer) nil
            (buffer-edit-history buffer) (make-empty-edit-history)
            (buffer-redo-stack buffer) nil)))
  (buffer-%undo-tree-root buffer))

(defun buffer-reset-undo-tree (buffer &key dirty saved-sequence truncated release)
  "Invalidate BUFFER's undo tree and optionally create a new root at its text."
  (invalidate-buffer-change-group buffer)
  (setf *undo-touched-buffers* (delete buffer *undo-touched-buffers* :test #'eq))
  (incf (buffer-%undo-tree-generation buffer))
  (setf (buffer-%undo-tree-table buffer) nil
        (buffer-%undo-tree-root buffer) nil
        (buffer-%undo-tree-current buffer) nil
        (buffer-%undo-tree-clean buffer) nil
        (buffer-%undo-tree-last-saved buffer) nil
        (buffer-%undo-tree-next-id buffer) 1
        (buffer-%undo-tree-payload-bytes buffer) 0
        (buffer-%undo-tree-node-count buffer) 0
        (buffer-%undo-tree-edit-count buffer) 0
        (buffer-%undo-tree-pending-payload-bytes buffer) 0
        (buffer-%undo-tree-discard-open-p buffer) nil
        (buffer-%undo-tree-truncated-p buffer) (not (null truncated))
        (buffer-%undo-tree-untracked-dirty-p buffer) (not (null dirty))
        (buffer-%undo-tree-pending-dirty-p buffer) nil
        (buffer-edit-history buffer) (make-empty-edit-history)
        (buffer-redo-stack buffer) nil)
  (unless release
    (let ((root (ensure-buffer-undo-tree buffer)))
      (when saved-sequence
        (setf (undo-tree-node-saved-sequence root) saved-sequence
              (buffer-%undo-tree-last-saved buffer) root
              (buffer-%undo-tree-save-sequence buffer)
              (max saved-sequence
                   (buffer-%undo-tree-save-sequence buffer))))))
  nil)

(defun buffer-release-undo-tree (buffer)
  (buffer-reset-undo-tree buffer :release t))

(defun buffer-clear-undo-tree (buffer)
  (let* ((dirty-p (buffer-modified-p buffer))
         (current (buffer-%undo-tree-current buffer))
         (saved (buffer-%undo-tree-last-saved buffer))
         (saved-sequence
           (and (not dirty-p)
                (eq current saved)
                saved
                (undo-tree-node-saved-sequence saved))))
    (buffer-reset-undo-tree buffer
                            :dirty dirty-p
                            :saved-sequence saved-sequence)))

(defun buffer-mark-undo-tree-clean (buffer saved-p)
  (alexandria:when-let ((group (buffer-%active-change-group buffer)))
    ;; Clean and saved identities may only point at stable, sealed nodes.
    (buffer-accept-change-group group))
  (buffer-undo-tree-finalize buffer)
  (ensure-buffer-undo-tree buffer)
  (let ((current (buffer-%undo-tree-current buffer)))
    (setf (buffer-%undo-tree-clean buffer) current
          (buffer-%undo-tree-untracked-dirty-p buffer) nil
          (buffer-%undo-tree-pending-dirty-p buffer) nil)
    (when saved-p
      (let ((sequence (incf (buffer-%undo-tree-save-sequence buffer))))
        (setf (undo-tree-node-saved-sequence current) sequence
              (buffer-%undo-tree-last-saved buffer) current))))
  nil)

(defun buffer-enable-undo-p (&optional (buffer (current-buffer)))
  "Returns T if undo is enabled for BUFFER and recording is not inhibited."
  (and (buffer-%enable-undo-p buffer) (not *inhibit-undo*)))

(defun buffer-enable-undo (buffer)
  "Enable undo for BUFFER."
  (setf (buffer-%enable-undo-p buffer) t)
  (ensure-buffer-undo-tree buffer)
  nil)

(defun buffer-disable-undo (buffer)
  "Disable undo for BUFFER, release history, and preserve its dirty state."
  (let ((dirty-p (buffer-modified-p buffer)))
    (setf (buffer-%enable-undo-p buffer) nil)
    (buffer-reset-undo-tree buffer :dirty dirty-p :release t))
  nil)

(defun buffer-enable-undo-boundary-p (&optional (buffer (current-buffer)))
  (buffer-%enable-undo-boundary-p buffer))

(defun buffer-enable-undo-boundary (buffer)
  (setf (buffer-%enable-undo-boundary-p buffer) t)
  nil)

(defun buffer-disable-undo-boundary (buffer)
  (setf (buffer-%enable-undo-boundary-p buffer) nil)
  nil)

(defun touch-undo-buffer (buffer)
  (pushnew buffer *undo-touched-buffers* :test #'eq))

(defun buffer-modify (buffer)
  ;; This is a content generation, not a dirty counter.  Saving never resets it.
  (incf (buffer-%modified-tick buffer))
  (cond ((undo-tree-replaying-buffer-p buffer)
         (setf (buffer-%undo-tree-pending-dirty-p buffer) t))
        ((and (buffer-%enable-undo-p buffer) (not *inhibit-undo*))
         (setf (buffer-%undo-tree-pending-dirty-p buffer) t))
        (t
         ;; No retained route can restore a transaction across this edit.
         (invalidate-buffer-change-group buffer)
         (setf (buffer-%undo-tree-untracked-dirty-p buffer) t)))
  (buffer-mark-cancel buffer))

(defun push-undo (buffer edit)
  (when (and (buffer-%enable-undo-p buffer)
             (not *inhibit-undo*)
             (not (undo-tree-replaying-buffer-p buffer))
             (plusp (length (edit-string edit))))
    (ensure-buffer-undo-tree buffer)
    (cond ((buffer-%undo-tree-discard-open-p buffer)
           (setf (buffer-%undo-tree-untracked-dirty-p buffer) t
                 (buffer-%undo-tree-pending-dirty-p buffer) nil)
           (touch-undo-buffer buffer))
          (t
           (let ((cost (edit-payload-bytes edit)))
             (cond ((or (> (+ cost
                              (buffer-%undo-tree-pending-payload-bytes buffer))
                           +undo-tree-outer-limit+)
                        (>= (fill-pointer (buffer-edit-history buffer))
                            +undo-tree-edit-limit+))
                    ;; Retaining a partial oversized command would make its
                    ;; inverse dishonest.  Drop the whole tree immediately and
                    ;; ignore the rest of this command until its boundary.
                    (buffer-reset-undo-tree buffer :dirty t :truncated t)
                    (setf (buffer-%undo-tree-discard-open-p buffer) t)
                    (touch-undo-buffer buffer)
                    (warn "Undo command exceeded its retention limit; history was reset"))
                   (t
                    (initialize-current-undo-point-position buffer edit)
                    (let ((copy (copy-retained-edit edit)))
                      (vector-push-extend copy (buffer-edit-history buffer))
                      (incf (buffer-%undo-tree-payload-bytes buffer) cost)
                      (incf (buffer-%undo-tree-pending-payload-bytes buffer) cost)
                      (incf (buffer-%undo-tree-edit-count buffer))
                      (incf (buffer-%undo-tree-generation buffer))
                      (setf (buffer-%undo-tree-pending-dirty-p buffer) nil)
                      (touch-undo-buffer buffer))))))))
  nil)

(defun initialize-current-undo-point-position (buffer edit)
  "Give a history root its first meaningful source position."
  (let ((current (buffer-%undo-tree-current buffer)))
    (when (and current (null (undo-tree-node-point-position current)))
      (setf (undo-tree-node-point-position current) (edit-position edit)))))

(defun transform-undo-point-position (position edit)
  "Transform POSITION across the untracked EDIT applied to every state."
  (ecase (edit-kind edit)
    (:insert-string
     (if (<= (edit-position edit) position)
         (+ position (length (edit-string edit)))
         position))
    (:delete-string
     (if (< (edit-position edit) position)
         (max (edit-position edit)
              (- position (length (edit-string edit))))
         position))))

(defun transform-sealed-history (buffer source-edit)
  (when (buffer-%undo-tree-table buffer)
    (maphash (lambda (id node)
               (declare (ignore id))
               (dolist (edit (undo-tree-node-edits node))
                 (compute-edit-offset edit source-edit))
               (let ((position (undo-tree-node-point-position node)))
                 (when position
                   (setf (undo-tree-node-point-position node)
                         (transform-undo-point-position
                          position source-edit)))))
             (buffer-%undo-tree-table buffer))))

(defun recompute-undo-position-offset (buffer edit)
  "Transform every retained branch after an untracked edit."
  (transform-sealed-history buffer edit)
  (loop :for retained :across (buffer-edit-history buffer)
        :do (compute-edit-offset retained edit))
  (setf (buffer-%undo-tree-untracked-dirty-p buffer) t
        (buffer-%undo-tree-pending-dirty-p buffer) nil)
  (incf (buffer-%undo-tree-generation buffer))
  nil)

(defun node-payload-sum (node)
  (loop :for edit :in (undo-tree-node-edits node)
        :sum (edit-payload-bytes edit)))

(defun recompute-last-saved-node (buffer)
  (let ((best nil))
    (when (buffer-%undo-tree-table buffer)
      (maphash
       (lambda (id node)
         (declare (ignore id))
         (when (and (undo-tree-node-saved-sequence node)
                    (or (null best)
                        (> (undo-tree-node-saved-sequence node)
                           (undo-tree-node-saved-sequence best))))
           (setf best node)))
       (buffer-%undo-tree-table buffer)))
    (setf (buffer-%undo-tree-last-saved buffer) best)))

(defun prunable-undo-leaf-p (buffer node protected)
  (and (node-in-buffer-p buffer node)
       (not (eq node protected))
       (not (active-change-group-protected-node-p buffer node))
       (not (eq node (buffer-%undo-tree-current buffer)))
       (undo-tree-node-parent node)
       (null (undo-tree-node-children node))))

(defun sorted-prunable-undo-leaves (buffer protected)
  "Collect candidate leaves once, oldest first, for bounded pruning work."
  (let ((leaves '()))
    (maphash
     (lambda (id node)
       (declare (ignore id))
       (when (prunable-undo-leaf-p buffer node protected)
         (push node leaves)))
     (buffer-%undo-tree-table buffer))
    (sort leaves #'< :key #'undo-tree-node-id)))

(defun prune-sorted-undo-leaves (buffer protected)
  "Prune oldest leaves without repeatedly scanning wide sibling lists."
  (let ((child-counts (make-hash-table :test #'eq))
        (removed (make-hash-table :test #'eq))
        (affected-parents (make-hash-table :test #'eq))
        (pruned-p nil))
    (maphash
     (lambda (id node)
       (declare (ignore id))
       (setf (gethash node child-counts)
             (length (undo-tree-node-children node))))
     (buffer-%undo-tree-table buffer))
    (labels ((prunable-p (node)
               (and node
                    (node-in-buffer-p buffer node)
                    (not (eq node protected))
                    (not (active-change-group-protected-node-p buffer node))
                    (not (eq node (buffer-%undo-tree-current buffer)))
                    (undo-tree-node-parent node)
                    (zerop (gethash node child-counts 0))))
             (remove-node (node)
               (let ((parent (undo-tree-node-parent node)))
                 (setf (gethash node removed) t
                       (gethash parent affected-parents) t)
                 (decf (gethash parent child-counts))
                 (when (eq node (buffer-%undo-tree-clean buffer))
                   (setf (buffer-%undo-tree-clean buffer) nil))
                 (when (eq node (buffer-%undo-tree-last-saved buffer))
                   (setf (buffer-%undo-tree-last-saved buffer) nil))
                 (decf (buffer-%undo-tree-payload-bytes buffer)
                       (undo-tree-node-payload-bytes node))
                 (decf (buffer-%undo-tree-edit-count buffer)
                       (length (undo-tree-node-edits node)))
                 (decf (buffer-%undo-tree-node-count buffer))
                 (remhash (undo-tree-node-id node)
                          (buffer-%undo-tree-table buffer))
                 parent)))
      (dolist (leaf (sorted-prunable-undo-leaves buffer protected))
        (let ((node leaf))
          ;; Parent IDs are older than their children, so a newly exposed
          ;; parent can be consumed immediately without a priority queue.
          (loop :while (and (undo-tree-over-retention-limit-p buffer)
                            (prunable-p node))
                :do (setf node (remove-node node)
                          pruned-p t)))
        (unless (undo-tree-over-retention-limit-p buffer)
          (return)))
      ;; Each affected sibling list is filtered once, making a wide root
      ;; linear after the one candidate sort instead of quadratic.
      (maphash
       (lambda (parent value)
         (declare (ignore value))
         (when (node-in-buffer-p buffer parent)
           (setf (undo-tree-node-children parent)
                 (delete-if (lambda (child) (gethash child removed))
                            (undo-tree-node-children parent)))
           (when (gethash (undo-tree-node-preferred parent) removed)
             (setf (undo-tree-node-preferred parent)
                   (first (undo-tree-node-children parent))))))
       affected-parents))
    pruned-p))

(defun advance-undo-root (buffer protected)
  (let* ((root (buffer-%undo-tree-root buffer))
         (children (undo-tree-node-children root)))
    (when (and (= 1 (length children))
               (not (eq (first children) protected))
               (not (active-change-group-protected-node-p buffer root))
               (not (active-change-group-protected-node-p
                     buffer (first children))))
      (let ((new-root (first children)))
        (when (eq root (buffer-%undo-tree-clean buffer))
          (setf (buffer-%undo-tree-clean buffer) nil))
        (when (eq root (buffer-%undo-tree-last-saved buffer))
          (setf (buffer-%undo-tree-last-saved buffer) nil))
        (decf (buffer-%undo-tree-payload-bytes buffer)
              (undo-tree-node-payload-bytes new-root))
        (decf (buffer-%undo-tree-edit-count buffer)
              (length (undo-tree-node-edits new-root)))
        (setf (undo-tree-node-parent new-root) nil
              (undo-tree-node-edits new-root) nil
              (undo-tree-node-payload-bytes new-root) 0
              (buffer-%undo-tree-root buffer) new-root)
        (remhash (undo-tree-node-id root) (buffer-%undo-tree-table buffer))
        (decf (buffer-%undo-tree-node-count buffer))
        t))))

(defun undo-tree-over-retention-limit-p (buffer)
  (or (> (buffer-%undo-tree-payload-bytes buffer) +undo-tree-limit+)
      (> (buffer-%undo-tree-node-count buffer) +undo-tree-node-limit+)
      (> (buffer-%undo-tree-edit-count buffer) +undo-tree-edit-limit+)))

(defun prune-undo-tree (buffer protected)
  (when (undo-tree-over-retention-limit-p buffer)
    (let ((pruned-p nil))
      ;; Linear history is common and can be trimmed from the root in O(n).
      (loop :while (and (undo-tree-over-retention-limit-p buffer)
                        (advance-undo-root buffer protected))
            :do (setf pruned-p t))
      ;; Sort candidates once, update child counts in O(1), and rebuild each
      ;; affected sibling list once.  This bounds wide-tree pruning too.
      (when (undo-tree-over-retention-limit-p buffer)
        (when (prune-sorted-undo-leaves buffer protected)
          (setf pruned-p t)))
      ;; Branch pruning can leave one surviving path; trim that path without
      ;; rescanning the table.
      (loop :while (and (undo-tree-over-retention-limit-p buffer)
                        (advance-undo-root buffer protected))
            :do (setf pruned-p t))
      ;; The newest command is protected through this collection.  It may
      ;; exceed the strong limit, but becomes collectible after the next one.
      (when (or pruned-p
                (> (buffer-%undo-tree-payload-bytes buffer)
                   +undo-tree-strong-limit+))
        (setf (buffer-%undo-tree-truncated-p buffer) t))
      (when (null (buffer-%undo-tree-last-saved buffer))
        (recompute-last-saved-node buffer))))
  nil)

(defun pending-edits-list (buffer)
  (loop :for edit :across (buffer-edit-history buffer) :collect edit))

(defun seal-buffer-undo-command (buffer &optional (prune-p t))
  (ensure-buffer-undo-tree buffer)
  (when (buffer-%undo-tree-discard-open-p buffer)
    (setf (buffer-%undo-tree-discard-open-p buffer) nil
          (buffer-%undo-tree-pending-dirty-p buffer) nil)
    (return-from seal-buffer-undo-command
      (make-node-ref buffer (buffer-%undo-tree-current buffer))))
  (let ((edits (pending-edits-list buffer)))
    (when edits
      (let* ((payload-bytes
               (buffer-%undo-tree-pending-payload-bytes buffer))
             (parent (buffer-%undo-tree-current buffer))
             (id (prog1 (buffer-%undo-tree-next-id buffer)
                   (incf (buffer-%undo-tree-next-id buffer))))
             (node (%make-undo-tree-node
                    id :parent parent :edits edits
                       :payload-bytes payload-bytes
                       :point-position
                       (position-at-point (buffer-point buffer)))))
        (unless (node-in-buffer-p buffer parent)
          (buffer-reset-undo-tree buffer :dirty t :truncated t)
          (editor-error "Undo tree lost its current node"))
        (push node (undo-tree-node-children parent))
        (setf (undo-tree-node-preferred parent) node
              (gethash id (buffer-%undo-tree-table buffer)) node
              (buffer-%undo-tree-current buffer) node
              (buffer-edit-history buffer) (make-empty-edit-history)
              (buffer-%undo-tree-pending-payload-bytes buffer) 0
              (buffer-%undo-tree-pending-dirty-p buffer) nil)
        (incf (buffer-%undo-tree-node-count buffer))
        (incf (buffer-%undo-tree-generation buffer))
        (when prune-p
          (prune-undo-tree buffer node)))))
  (make-node-ref buffer (buffer-%undo-tree-current buffer)))

(defun buffer-undo-tree-finalize (&optional (buffer (current-buffer)))
  "Seal BUFFER's open command and return an opaque reference to its state."
  (check-type buffer buffer)
  (seal-buffer-undo-command buffer))

(defun buffer-undo-boundary (&optional (buffer (current-buffer)))
  "Seal all undo-enabled buffers touched by the completed editor command."
  (check-type buffer buffer)
  (let ((candidates (adjoin buffer (copy-list *undo-touched-buffers*) :test #'eq)))
    (dolist (candidate candidates)
      (cond ((deleted-buffer-p candidate)
             (setf *undo-touched-buffers*
                   (delete candidate *undo-touched-buffers* :test #'eq)))
            ((buffer-enable-undo-boundary-p candidate)
             (seal-buffer-undo-command candidate)
             (setf *undo-touched-buffers*
                   (delete candidate *undo-touched-buffers* :test #'eq))))))
  nil)

(defun proper-list-p (object)
  (or (null object)
      (handler-case (not (null (list-length object)))
        (type-error () nil))))

(defun valid-retained-edit-p (edit)
  (and (typep edit 'edit)
       (member (edit-kind edit) '(:insert-string :delete-string))
       (integerp (edit-position edit))
       (plusp (edit-position edit))
       (stringp (edit-string edit))))

(defun validate-undo-tree (buffer)
  (ensure-buffer-undo-tree buffer)
  (let ((table (buffer-%undo-tree-table buffer))
        (root (buffer-%undo-tree-root buffer))
        (seen (make-hash-table :test #'eq))
        (count 0)
        (edit-count 0)
        (payload 0)
        (stack nil))
    (unless (and (typep root 'undo-tree-node)
                 (null (undo-tree-node-parent root)))
      (editor-error "Malformed undo tree root"))
    (push root stack)
    (loop :while stack
          :for node := (pop stack)
          :do (unless (and (typep node 'undo-tree-node)
                           (eq node (gethash (undo-tree-node-id node) table)))
                (editor-error "Undo tree contains an unowned node"))
              (when (gethash node seen)
                (editor-error "Undo tree contains a cycle"))
              (setf (gethash node seen) t)
              (unless (and (proper-list-p (undo-tree-node-children node))
                           (proper-list-p (undo-tree-node-edits node))
                           (every #'valid-retained-edit-p
                                  (undo-tree-node-edits node)))
                (editor-error "Undo tree contains malformed payload"))
              (unless
                  (or (and (integerp (undo-tree-node-point-position node))
                           (plusp (undo-tree-node-point-position node)))
                      (and (eq node root) (null (undo-tree-node-children node))))
                (editor-error "Undo tree contains an invalid point position"))
              (unless (= (node-payload-sum node)
                         (undo-tree-node-payload-bytes node))
                (editor-error "Undo tree payload accounting mismatch"))
              (when (and (undo-tree-node-preferred node)
                         (not (member (undo-tree-node-preferred node)
                                      (undo-tree-node-children node)
                                      :test #'eq)))
                (editor-error "Undo tree preferred child is invalid"))
              (incf count)
              (incf edit-count (length (undo-tree-node-edits node)))
              (incf payload (undo-tree-node-payload-bytes node))
              (dolist (child (undo-tree-node-children node))
                (unless (and (typep child 'undo-tree-node)
                             (eq (undo-tree-node-parent child) node))
                  (editor-error "Undo tree parent link is invalid"))
                (push child stack)))
    (unless (and (= count (hash-table-count table))
                 (= count (buffer-%undo-tree-node-count buffer))
                 (= edit-count (buffer-%undo-tree-edit-count buffer))
                 (= payload (buffer-%undo-tree-payload-bytes buffer)))
      (editor-error "Undo tree aggregate accounting mismatch"))
    (dolist (node (list (buffer-%undo-tree-current buffer)
                        (buffer-%undo-tree-clean buffer)
                        (buffer-%undo-tree-last-saved buffer)))
      (when (and node (not (gethash node seen)))
        (editor-error "Undo tree state points outside the tree")))
    (unless (buffer-%undo-tree-current buffer)
      (editor-error "Undo tree has no current node"))
    t))

(defun resolve-node-ref (ref)
  (unless (typep ref 'undo-tree-ref)
    (editor-error "Expected an opaque undo-tree node reference"))
  (let ((buffer (undo-tree-ref-buffer ref)))
    (when (or (deleted-buffer-p buffer)
              (not (= (undo-tree-ref-generation ref)
                      (buffer-%undo-tree-generation buffer))))
      (editor-error "Stale undo-tree node reference"))
    (validate-undo-tree buffer)
    (or (gethash (undo-tree-ref-id ref) (buffer-%undo-tree-table buffer))
        (editor-error "Unknown undo-tree node reference"))))

(defun resolve-destination (buffer destination generation)
  (cond ((typep destination 'undo-tree-ref)
         (unless (eq buffer (undo-tree-ref-buffer destination))
           (editor-error "Undo-tree node belongs to another buffer"))
         (resolve-node-ref destination))
        ((integerp destination)
         (unless (and generation
                      (= generation (buffer-%undo-tree-generation buffer)))
           (editor-error "Integer undo-tree IDs require the current generation"))
         (or (gethash destination (buffer-%undo-tree-table buffer))
             (editor-error "Unknown undo-tree node ID ~D" destination)))
        (t
         (editor-error "Invalid undo-tree destination"))))

(defun node-ancestors (node)
  (let ((result '())
        (seen (make-hash-table :test #'eq)))
    (loop :for current := node :then (undo-tree-node-parent current)
          :while current
          :do (when (gethash current seen)
                (editor-error "Undo tree contains a parent cycle"))
              (setf (gethash current seen) t)
              (push current result))
    (nreverse result)))

(defun undo-route (current destination)
  (let* ((current-chain (node-ancestors current))
         (destination-chain (node-ancestors destination))
         (current-set (make-hash-table :test #'eq))
         (lca nil))
    (dolist (node current-chain)
      (setf (gethash node current-set) t))
    (dolist (node destination-chain)
      (when (gethash node current-set)
        (setf lca node)
        (return)))
    (unless lca
      (editor-error "Undo-tree nodes have no common ancestor"))
    (let ((up '())
          (down '()))
      (loop :for node := current :then (undo-tree-node-parent node)
            :until (eq node lca)
            :do (push node up))
      (setf up (nreverse up))
      (loop :for node := destination :then (undo-tree-node-parent node)
            :until (eq node lca)
            :do (push node down))
      (values up down))))

(defun effective-edit-kind (edit inverse-p)
  (if inverse-p
      (ecase (edit-kind edit)
        (:insert-string :delete-string)
        (:delete-string :insert-string))
      (edit-kind edit)))

(defun simulate-one-edit (text edit inverse-p)
  (let* ((kind (effective-edit-kind edit inverse-p))
         (string (edit-string edit))
         (start (1- (edit-position edit)))
         (end (+ start (length string))))
    (unless (and (integerp start) (<= 0 start (length text)))
      (editor-error "Invalid retained undo position"))
    (ecase kind
      (:insert-string
       (concatenate 'string (subseq text 0 start) string (subseq text start)))
      (:delete-string
       (unless (and (<= end (length text))
                    (string= string text :start2 start :end2 end))
         (editor-error "Retained undo deletion does not match buffer text"))
         (concatenate 'string (subseq text 0 start) (subseq text end))))))

(defun validate-route-text-from-string (initial-text up down)
  (let ((text initial-text)
        (text-bytes
          (babel:string-size-in-octets initial-text :encoding :utf-8))
        (work 0)
        (edit-count 0))
    (when (> text-bytes *undo-tree-route-work-limit*)
      (editor-error "Buffer is too large for safe undo-route validation"))
    (labels ((simulate (edit inverse-p)
               (let ((edit-bytes (edit-payload-bytes edit))
                     (kind (effective-edit-kind edit inverse-p)))
                 (incf edit-count)
                 (incf work (+ text-bytes edit-bytes))
                 (when (or (> edit-count +undo-tree-edit-limit+)
                           (> work *undo-tree-route-work-limit*))
                   (editor-error "Undo route exceeds safe validation work"))
                 (setf text (simulate-one-edit text edit inverse-p))
                 (ecase kind
                   (:insert-string (incf text-bytes edit-bytes))
                   (:delete-string (decf text-bytes edit-bytes))))))
      (dolist (node up)
        (dolist (edit (reverse (undo-tree-node-edits node)))
          (simulate edit t)))
      (dolist (node down)
        (dolist (edit (undo-tree-node-edits node))
          (simulate edit nil))))
    text))

(defun validate-route-text (buffer up down)
  (validate-route-text-from-string (buffer-text buffer) up down))

(defun buffer-text-equal-p (buffer text)
  "Compare BUFFER with TEXT without allocating a second buffer-sized string."
  (and (= (length text)
          (1- (position-at-point (buffer-end-point buffer))))
       (with-point ((cursor (buffer-start-point buffer)))
         (loop :for expected :across text
               :for actual := (character-at cursor)
               :unless (and actual (char= actual expected))
                 :do (return nil)
               :do (character-offset cursor 1)
               :finally (return t)))))

(defun apply-undo-route (point up down)
  (let ((*undo-tree-replaying-p* (point-buffer point)))
    (dolist (node up)
      (dolist (edit (reverse (undo-tree-node-edits node)))
        (apply-inverse-edit point edit))
      (setf (undo-tree-node-preferred (undo-tree-node-parent node)) node))
    (dolist (node down)
      (dolist (edit (undo-tree-node-edits node))
        (apply-edit point edit))
      (setf (undo-tree-node-preferred (undo-tree-node-parent node)) node))))

(defun move-to-undo-node (point destination &optional rollback-destination)
  (let* ((buffer (point-buffer point))
         (current (buffer-%undo-tree-current buffer))
         (tree-generation (buffer-%undo-tree-generation buffer))
         (tree-table (buffer-%undo-tree-table buffer))
         (tree-root (buffer-%undo-tree-root buffer)))
    (ensure-undo-history-move-allowed buffer)
    (when (eq current destination)
      (return-from move-to-undo-node (make-node-ref buffer destination)))
    ;; Structural and route-work refusals happen before the recovery handler:
    ;; unchanged content must retain its valid history and dirty identity.
    (validate-undo-tree buffer)
    (multiple-value-bind (up down) (undo-route current destination)
      (let* ((text-before (buffer-text buffer))
             (expected-text
               (validate-route-text-from-string text-before up down))
            (tick-before (buffer-modified-tick buffer)))
        ;; A preview or ordinary undo must never strand the caller at a node
        ;; whose return route exceeds the validation budget.  Validate the
        ;; reverse text before touching the live buffer.
        (when (and rollback-destination
                   (not (eq destination rollback-destination)))
          (multiple-value-bind (return-up return-down)
              (undo-route destination rollback-destination)
            (let ((return-text
                    (validate-route-text-from-string
                     expected-text return-up return-down)))
              ;; Ordinary undo/redo returns to CURRENT, whose text is live and
              ;; can be compared exactly.  A Vundo preview may instead guard
              ;; a more distant entry node; route simulation still validates
              ;; its edits and resource budget, but that historical baseline
              ;; is not the current buffer text.
              (when (and (eq rollback-destination current)
                         (not (buffer-text-equal-p buffer return-text)))
                (editor-error
                 "Undo return route does not reproduce the current buffer")))))
        (handler-case
            (progn
              (apply-undo-route point up down)
              (unless (buffer-text-equal-p buffer expected-text)
                (editor-error
                 "Undo replay was changed by a modification hook"))
              (unless
                  (and (= tree-generation (buffer-%undo-tree-generation buffer))
                       (eq tree-table (buffer-%undo-tree-table buffer))
                       (eq tree-root (buffer-%undo-tree-root buffer))
                       (eq current (buffer-%undo-tree-current buffer))
                       (node-in-buffer-p buffer destination)
                       (every (lambda (node) (node-in-buffer-p buffer node)) up)
                       (every (lambda (node) (node-in-buffer-p buffer node)) down))
                (buffer-reset-undo-tree buffer :dirty t :truncated t)
                (editor-error "Undo history changed during replay"))
              (let ((position (undo-tree-node-point-position destination)))
                (when position
                  (unless
                      (move-to-position
                       point (min position (position-at-point
                                            (buffer-end-point buffer))))
                    (editor-error "Could not restore the undo-state point"))))
              (setf (buffer-%undo-tree-current buffer) destination
                    (buffer-%undo-tree-pending-dirty-p buffer) nil)
              (make-node-ref buffer destination))
          (error (condition)
            ;; Read-only checks and throwing pre-change hooks can refuse the
            ;; first edit without changing text.  Completed edits normally
            ;; advance the tick before after-change hooks run; content equality
            ;; independently guards unusual hook behavior and future edit
            ;; implementations.  Any observed change requires a fail-closed
            ;; dirty recovery root.
            (unless (and (= tick-before (buffer-modified-tick buffer))
                         (buffer-text-equal-p buffer text-before))
              (buffer-reset-undo-tree buffer :dirty t :truncated t))
            (error condition)))))))

(defun buffer-undo-tree-move
    (point destination &optional generation rollback-destination)
  "Move POINT's buffer to DESTINATION and return its opaque node reference.
DESTINATION may be a reference, or an integer ID accompanied by GENERATION.
When ROLLBACK-DESTINATION is non-nil, validate that it can be reached from
DESTINATION within the same safety limits before changing the live buffer."
  (check-type point point)
  (unless (alive-point-p point)
    (editor-error "Cannot move undo history through a dead point"))
  (let ((buffer (point-buffer point)))
    (ensure-undo-history-move-allowed buffer)
    (buffer-undo-tree-finalize buffer)
    (validate-undo-tree buffer)
    (move-to-undo-node
     point
     (resolve-destination buffer destination generation)
     (and rollback-destination
          (resolve-destination buffer rollback-destination generation)))))

(defun buffer-undo (point)
  (let ((buffer (point-buffer point)))
    (ensure-undo-history-move-allowed buffer)
    (buffer-undo-tree-finalize buffer)
    (let* ((current (buffer-%undo-tree-current buffer))
           (parent (undo-tree-node-parent current)))
      (when parent
        (move-to-undo-node point parent current)
        t))))

(defun buffer-redo (point)
  (let ((buffer (point-buffer point)))
    (ensure-undo-history-move-allowed buffer)
    (buffer-undo-tree-finalize buffer)
    (let* ((current (buffer-%undo-tree-current buffer))
           (children (undo-tree-node-children current))
           (preferred (undo-tree-node-preferred current))
           (destination (if (member preferred children :test #'eq)
                            preferred
                            (first children))))
      (when destination
        (move-to-undo-node point destination current)
        t))))

(defun buffer-undo-tree-root (&optional (buffer (current-buffer)))
  (buffer-undo-tree-finalize buffer)
  (make-node-ref buffer (buffer-%undo-tree-root buffer)))

(defun buffer-undo-tree-current (&optional (buffer (current-buffer)))
  (buffer-undo-tree-finalize buffer)
  (make-node-ref buffer (buffer-%undo-tree-current buffer)))

(defun buffer-undo-tree-saved (&optional (buffer (current-buffer)))
  (buffer-undo-tree-finalize buffer)
  (make-node-ref buffer (buffer-%undo-tree-last-saved buffer)))

(defun buffer-undo-tree-truncated-p (&optional (buffer (current-buffer)))
  (buffer-undo-tree-finalize buffer)
  (buffer-%undo-tree-truncated-p buffer))

(defun buffer-undo-tree-node-count (&optional (buffer (current-buffer)))
  (buffer-undo-tree-finalize buffer)
  (buffer-%undo-tree-node-count buffer))

(defun buffer-undo-tree-payload-bytes (&optional (buffer (current-buffer)))
  (buffer-undo-tree-finalize buffer)
  (buffer-%undo-tree-payload-bytes buffer))

(defun snapshot-node (node)
  (list :id (undo-tree-node-id node)
        :parent (and (undo-tree-node-parent node)
                     (undo-tree-node-id (undo-tree-node-parent node)))
        :children (mapcar #'undo-tree-node-id
                          (undo-tree-node-children node))
        :preferred (and (undo-tree-node-preferred node)
                        (undo-tree-node-id (undo-tree-node-preferred node)))
        :point-position (undo-tree-node-point-position node)
        :saved-sequence (undo-tree-node-saved-sequence node)))

(defun buffer-undo-tree-snapshot (&optional (buffer (current-buffer)))
  "Return a copied, mutation-safe description of BUFFER's undo tree."
  (buffer-undo-tree-finalize buffer)
  (validate-undo-tree buffer)
  (let ((nodes '()))
    (maphash (lambda (id node)
               (declare (ignore id))
               (push node nodes))
             (buffer-%undo-tree-table buffer))
    (setf nodes (sort nodes #'< :key #'undo-tree-node-id))
    (list :generation (buffer-%undo-tree-generation buffer)
          :root (undo-tree-node-id (buffer-%undo-tree-root buffer))
          :current (undo-tree-node-id (buffer-%undo-tree-current buffer))
          :clean (and (buffer-%undo-tree-clean buffer)
                      (undo-tree-node-id (buffer-%undo-tree-clean buffer)))
          :last-saved (and (buffer-%undo-tree-last-saved buffer)
                           (undo-tree-node-id
                            (buffer-%undo-tree-last-saved buffer)))
          :truncated (buffer-%undo-tree-truncated-p buffer)
          :node-count (buffer-%undo-tree-node-count buffer)
          :payload-bytes (buffer-%undo-tree-payload-bytes buffer)
          :nodes (mapcar #'snapshot-node nodes))))

(defun buffer-undo-tree-node-id (ref)
  (undo-tree-node-id (resolve-node-ref ref)))

(defun buffer-undo-tree-node-parent (ref)
  (let* ((node (resolve-node-ref ref))
         (buffer (undo-tree-ref-buffer ref)))
    (make-node-ref buffer (undo-tree-node-parent node))))

(defun buffer-undo-tree-node-children (ref)
  (let* ((node (resolve-node-ref ref))
         (buffer (undo-tree-ref-buffer ref)))
    (mapcar (lambda (child) (make-node-ref buffer child))
            (undo-tree-node-children node))))

(defun buffer-undo-tree-node-preferred (ref)
  (let* ((node (resolve-node-ref ref))
         (buffer (undo-tree-ref-buffer ref)))
    (make-node-ref buffer (undo-tree-node-preferred node))))

(defun buffer-undo-tree-node-saved-sequence (ref)
  (undo-tree-node-saved-sequence (resolve-node-ref ref)))

;;; Transactional change groups

(defun ensure-active-change-group (group)
  (unless (and (typep group 'buffer-change-group)
               (buffer-change-group-active-p group))
    (editor-error "Expected an active buffer change group"))
  (let ((buffer (buffer-change-group-buffer group)))
    (when (deleted-buffer-p buffer)
      (editor-error "The change-group buffer has been deleted"))
    (unless (eq group (buffer-%active-change-group buffer))
      (editor-error "The buffer is owned by another change group"))
    (unless (node-in-buffer-p buffer (buffer-change-group-baseline group))
      (editor-error "The change-group baseline is no longer retained"))
    buffer))

(defun begin-change-group-close (group)
  (let ((buffer (ensure-active-change-group group)))
    (when (undo-tree-replaying-buffer-p buffer)
      (editor-error "Cannot close a change group during undo replay"))
    (when (buffer-%undo-tree-pending-dirty-p buffer)
      (editor-error "Cannot close a change group after an unretained edit"))
    (setf (buffer-change-group-state group) :closing)
    buffer))

(defun finish-change-group-close (group buffer)
  (unless (eq group (buffer-%active-change-group buffer))
    (editor-error "The closing change group lost ownership of its buffer"))
  (setf (buffer-change-group-state group) :inactive
        (buffer-%active-change-group buffer) nil)
  t)

(defun restore-change-group-after-failure (group buffer)
  (if (and (not (deleted-buffer-p buffer))
           (eq group (buffer-%active-change-group buffer))
           (node-in-buffer-p buffer (buffer-change-group-baseline group)))
      (setf (buffer-change-group-state group) :active)
      (progn
        (when (and (not (deleted-buffer-p buffer))
                   (eq group (buffer-%active-change-group buffer)))
          (setf (buffer-%active-change-group buffer) nil))
        (setf (buffer-change-group-state group) :inactive)))
  nil)

(defun make-edit-history-from-list (edits)
  (let ((history (make-empty-edit-history)))
    (dolist (edit edits history)
      (vector-push-extend edit history))))

(defstruct (change-group-open-command-state
            (:constructor make-change-group-open-command-state
                (parent children preferred history pending-payload
                 pending-dirty node-count)))
  parent
  children
  preferred
  history
  pending-payload
  pending-dirty
  node-count
  sealed-node)

(defun node-edits-match-history-p (node history)
  (let ((edits (undo-tree-node-edits node)))
    (and (= (length edits) (fill-pointer history))
         (loop :for edit :in edits
               :for index :from 0
               :always (eq edit (aref history index))))))

(defun seal-change-group-open-command (buffer)
  "Temporarily seal BUFFER's pending command without retention pruning."
  (let ((history (buffer-edit-history buffer)))
    (when (plusp (fill-pointer history))
      (let* ((parent (buffer-%undo-tree-current buffer))
             (state
               (make-change-group-open-command-state
                parent
                (undo-tree-node-children parent)
                (undo-tree-node-preferred parent)
                history
                (buffer-%undo-tree-pending-payload-bytes buffer)
                (buffer-%undo-tree-pending-dirty-p buffer)
                (buffer-%undo-tree-node-count buffer))))
        (seal-buffer-undo-command buffer nil)
        (let ((sealed (buffer-%undo-tree-current buffer)))
          (unless (and (eq parent (undo-tree-node-parent sealed))
                       (eq sealed (first (undo-tree-node-children parent)))
                       (eq (change-group-open-command-state-children state)
                           (rest (undo-tree-node-children parent)))
                       (= (1+ (change-group-open-command-state-node-count state))
                          (buffer-%undo-tree-node-count buffer))
                       (eq sealed
                           (gethash (undo-tree-node-id sealed)
                                    (buffer-%undo-tree-table buffer)))
                       (node-edits-match-history-p sealed history)
                       (= (undo-tree-node-payload-bytes sealed)
                          (change-group-open-command-state-pending-payload state))
                       (zerop (fill-pointer (buffer-edit-history buffer)))
                       (zerop (buffer-%undo-tree-pending-payload-bytes buffer))
                       (not (buffer-%undo-tree-pending-dirty-p buffer)))
            (buffer-reset-undo-tree buffer :dirty t :truncated t)
            (editor-error "Could not temporarily seal the change-group command"))
          (setf (change-group-open-command-state-sealed-node state) sealed)
          state)))))

(defun restore-change-group-open-command (buffer state)
  "Detach STATE's temporary node and restore the exact pending command."
  (when state
    (let* ((sealed (change-group-open-command-state-sealed-node state))
           (parent (change-group-open-command-state-parent state)))
      (unless (and (eq sealed (buffer-%undo-tree-current buffer))
                   (eq parent (undo-tree-node-parent sealed))
                   (null (undo-tree-node-children sealed))
                   (eq sealed (first (undo-tree-node-children parent)))
                   (eq (change-group-open-command-state-children state)
                       (rest (undo-tree-node-children parent)))
                   (= (1+ (change-group-open-command-state-node-count state))
                      (buffer-%undo-tree-node-count buffer))
                   (eq sealed
                       (gethash (undo-tree-node-id sealed)
                                (buffer-%undo-tree-table buffer)))
                   (node-edits-match-history-p
                    sealed (change-group-open-command-state-history state)))
        (buffer-reset-undo-tree buffer :dirty t :truncated t)
        (editor-error "Cannot restore the open change-group command"))
      (remhash (undo-tree-node-id sealed) (buffer-%undo-tree-table buffer))
      (setf (undo-tree-node-children parent)
            (change-group-open-command-state-children state)
            (undo-tree-node-preferred parent)
            (change-group-open-command-state-preferred state)
            (buffer-%undo-tree-current buffer) parent
            (buffer-edit-history buffer)
            (change-group-open-command-state-history state)
            (buffer-%undo-tree-pending-payload-bytes buffer)
            (change-group-open-command-state-pending-payload state)
            (buffer-%undo-tree-pending-dirty-p buffer)
            (change-group-open-command-state-pending-dirty state)
            (buffer-%undo-tree-node-count buffer)
            (change-group-open-command-state-node-count state))
      ;; Never recycle a generation or node ID: a refusal hook may have
      ;; observed the temporary node through a public tree accessor.
      (incf (buffer-%undo-tree-generation buffer))
      (touch-undo-buffer buffer)))
  t)

(defun restored-preferred-child (buffer parent saved-preferred)
  "Choose a surviving preferred child without pinning a prunable branch."
  (let ((children (undo-tree-node-children parent))
        (current (undo-tree-node-preferred parent)))
    (flet ((survives-p (node)
             (and node
                  (node-in-buffer-p buffer node)
                  (member node children :test #'eq))))
      (cond ((survives-p saved-preferred) saved-preferred)
            ((survives-p current) current)
            (t (first children))))))

(defun change-group-path-to-current (group current)
  "Return group-owned nodes after the baseline, in chronological order."
  (let ((baseline (buffer-change-group-baseline group))
        (first-id (buffer-change-group-first-node-id group))
        (path '())
        (seen (make-hash-table :test #'eq)))
    (loop :for node := current :then (undo-tree-node-parent node)
          :until (eq node baseline)
          :do (when (or (null node) (gethash node seen))
                (editor-error
                 "The change-group baseline is not an ancestor of current history"))
              (setf (gethash node seen) t)
              (when (< (undo-tree-node-id node) first-id)
                (editor-error
                 "Current history crossed a pre-existing change-group branch"))
              (push node path))
    path))

(defun collect-node-subtree (node)
  (let ((result '())
        (stack (list node))
        (seen (make-hash-table :test #'eq)))
    (loop :while stack
          :for current := (pop stack)
          :do (when (gethash current seen)
                (editor-error "Undo tree contains a cycle"))
              (setf (gethash current seen) t)
              (push current result)
              (dolist (child (undo-tree-node-children current))
                (push child stack)))
    result))

(defun ensure-unmarked-change-group-nodes (buffer nodes)
  "Refuse to splice nodes which establish clean or saved identity."
  (dolist (node nodes)
    (when (or (eq node (buffer-%undo-tree-clean buffer))
              (eq node (buffer-%undo-tree-last-saved buffer))
              (undo-tree-node-saved-sequence node))
      (editor-error "Change group contains clean or saved undo history"))))

(defun ensure-discardable-change-group-nodes (buffer nodes)
  (dolist (node nodes)
    (when (or (eq node (buffer-%undo-tree-current buffer))
              (eq node (buffer-%undo-tree-clean buffer))
              (eq node (buffer-%undo-tree-last-saved buffer))
              (undo-tree-node-saved-sequence node))
      (editor-error "Change group contains protected undo history"))))

(defun remove-discarded-nodes (buffer nodes)
  "Remove sealed NODES and their accounting after their edits were undone."
  (ensure-discardable-change-group-nodes buffer nodes)
  (dolist (node nodes)
    (decf (buffer-%undo-tree-payload-bytes buffer)
          (undo-tree-node-payload-bytes node))
    (decf (buffer-%undo-tree-edit-count buffer)
          (length (undo-tree-node-edits node)))
    (decf (buffer-%undo-tree-node-count buffer))
    (remhash (undo-tree-node-id node) (buffer-%undo-tree-table buffer))))

(defun group-new-root-children (group)
  (let ((first-id (buffer-change-group-first-node-id group)))
    (remove-if (lambda (node) (< (undo-tree-node-id node) first-id))
               (undo-tree-node-children
                (buffer-change-group-baseline group)))))

(defun change-group-new-descendants (group)
  (mapcan #'collect-node-subtree (group-new-root-children group)))

(defun preflight-change-group-close (group buffer remove-baseline-p)
  "Validate close invariants before sealing or replaying any pending edits."
  (change-group-path-to-current group (buffer-%undo-tree-current buffer))
  (let ((nodes (change-group-new-descendants group)))
    (ensure-unmarked-change-group-nodes
     buffer
     (if remove-baseline-p
         (cons (buffer-change-group-baseline group) nodes)
         nodes)))
  (when (buffer-change-group-split-open-p group)
    (unless (eq (buffer-change-group-split-parent group)
                (undo-tree-node-parent
                 (buffer-change-group-baseline group)))
      (editor-error "The split change-group parent is no longer retained")))
  t)

(defun discard-change-group-descendants (group buffer)
  (let* ((baseline (buffer-change-group-baseline group))
         (nodes (change-group-new-descendants group)))
    (remove-discarded-nodes buffer nodes)
    (setf (undo-tree-node-children baseline)
          (remove-if
           (lambda (node)
             (>= (undo-tree-node-id node)
                 (buffer-change-group-first-node-id group)))
           (undo-tree-node-children baseline)))
    (setf (undo-tree-node-preferred baseline)
          (restored-preferred-child
           buffer baseline (buffer-change-group-baseline-preferred group)))))

(defun unseal-split-baseline (group buffer)
  "Restore the open insertion command split when GROUP was prepared."
  (let* ((baseline (buffer-change-group-baseline group))
         (parent (buffer-change-group-split-parent group))
         (edits (undo-tree-node-edits baseline)))
    (unless (and (eq baseline (buffer-%undo-tree-current buffer))
                 (eq parent (undo-tree-node-parent baseline))
                 (null (undo-tree-node-children baseline)))
      (editor-error "Cannot restore the split change-group command"))
    (setf (undo-tree-node-children parent)
          (delete baseline (undo-tree-node-children parent) :test #'eq))
    (setf (undo-tree-node-preferred parent)
          (restored-preferred-child
           buffer parent (buffer-change-group-split-parent-preferred group))
          (buffer-%undo-tree-current buffer) parent
          (buffer-edit-history buffer) (make-edit-history-from-list edits)
          (buffer-%undo-tree-pending-payload-bytes buffer)
          (undo-tree-node-payload-bytes baseline)
          (buffer-%undo-tree-pending-dirty-p buffer) nil)
    (remhash (undo-tree-node-id baseline)
             (buffer-%undo-tree-table buffer))
    (decf (buffer-%undo-tree-node-count buffer))
    (incf (buffer-%undo-tree-generation buffer))
    (touch-undo-buffer buffer)))

(defun buffer-prepare-change-group (&optional (buffer (current-buffer)))
  "Start an undo-honest transaction at BUFFER's current text.

Canceling restores this exact text and removes only history created by the
group.  If an Evil insertion command is open, preparation temporarily seals
it; accepting or canceling reopens it so completion does not split one insert
session into multiple undo steps."
  (check-type buffer buffer)
  (when (deleted-buffer-p buffer)
    (editor-error "Cannot prepare a change group in a deleted buffer"))
  (when (undo-tree-replaying-buffer-p buffer)
    (editor-error "Cannot prepare a change group during undo replay"))
  (unless (and (buffer-%enable-undo-p buffer) (not *inhibit-undo*))
    (editor-error "Buffer change groups require enabled undo recording"))
  (ensure-buffer-undo-tree buffer)
  (when (buffer-%active-change-group buffer)
    (editor-error "Nested buffer change groups are not supported"))
  (when (buffer-%undo-tree-pending-dirty-p buffer)
    (editor-error "Cannot prepare a change group after an unretained edit"))
  (when (buffer-%undo-tree-discard-open-p buffer)
    (editor-error "Cannot prepare a change group after discarded undo data"))
  (let* ((split-open-p (plusp (fill-pointer (buffer-edit-history buffer))))
         (parent (buffer-%undo-tree-current buffer))
         (parent-preferred (undo-tree-node-preferred parent)))
    (seal-buffer-undo-command buffer)
    (let ((baseline (buffer-%undo-tree-current buffer)))
      (when (and split-open-p
                 (not (and (eq parent (undo-tree-node-parent baseline))
                           (undo-tree-node-edits baseline))))
        (editor-error "Could not retain the open command for a change group"))
      (let ((group
              (%make-buffer-change-group
               buffer
               baseline
               (undo-tree-node-preferred baseline)
               (buffer-%undo-tree-next-id buffer)
               split-open-p
               (and split-open-p parent)
               (and split-open-p parent-preferred))))
        (setf (buffer-%active-change-group buffer) group)
        group))))

(defun path-next-node (path node)
  (let ((tail (member node path :test #'eq)))
    (second tail)))

(defun split-group-path-nodes (group buffer)
  (seal-buffer-undo-command buffer)
  (validate-undo-tree buffer)
  (cons (buffer-change-group-baseline group)
        (change-group-path-to-current
         group (buffer-%undo-tree-current buffer))))

(defun split-group-off-path-roots (group path)
  (let ((first-id (buffer-change-group-first-node-id group)))
    (loop :for node :in path
          :for next := (path-next-node path node)
          :append
          (remove-if
           (lambda (child)
             (or (eq child next)
                 (< (undo-tree-node-id child) first-id)))
           (undo-tree-node-children node)))))

(defun amalgamate-split-change-group (group buffer)
  "Move GROUP's accepted linear history back into its open insert command."
  (let* ((path (split-group-path-nodes group buffer))
         (baseline (first path))
         (parent (buffer-change-group-split-parent group))
         (off-path-roots (split-group-off-path-roots group path))
         (off-path (mapcan #'collect-node-subtree off-path-roots))
         (edits (mapcan (lambda (node)
                          (copy-list (undo-tree-node-edits node)))
                        path))
         (payload (loop :for node :in path
                        :sum (undo-tree-node-payload-bytes node))))
    (unless (and (eq (car (last path))
                     (buffer-%undo-tree-current buffer))
                 (eq parent (undo-tree-node-parent baseline)))
      (editor-error "Cannot amalgamate a non-current change-group path"))
    (ensure-unmarked-change-group-nodes buffer (append path off-path))
    (remove-discarded-nodes buffer off-path)
    (dolist (node path)
      (remhash (undo-tree-node-id node)
               (buffer-%undo-tree-table buffer))
      (decf (buffer-%undo-tree-node-count buffer)))
    (setf (undo-tree-node-children parent)
          (delete baseline (undo-tree-node-children parent) :test #'eq))
    (setf (undo-tree-node-preferred parent)
          (restored-preferred-child
           buffer parent (buffer-change-group-split-parent-preferred group))
          (buffer-%undo-tree-current buffer) parent
          (buffer-edit-history buffer) (make-edit-history-from-list edits)
          (buffer-%undo-tree-pending-payload-bytes buffer) payload
          (buffer-%undo-tree-pending-dirty-p buffer) nil)
    (incf (buffer-%undo-tree-generation buffer))
    (touch-undo-buffer buffer)))

(defun buffer-accept-change-group (group)
  "Accept GROUP while preserving normal undo granularity."
  (let ((buffer (begin-change-group-close group))
        (splicing-p nil))
    (handler-case
        (progn
          (when (buffer-change-group-split-open-p group)
            (preflight-change-group-close group buffer t)
            (setf splicing-p t)
            (amalgamate-split-change-group group buffer))
          (finish-change-group-close group buffer))
      (error (condition)
        (if (and splicing-p
                 (eq group (buffer-%active-change-group buffer)))
            (buffer-reset-undo-tree
             buffer :dirty (buffer-modified-p buffer) :truncated t)
            (restore-change-group-after-failure group buffer))
        (error condition)))))

(defun buffer-cancel-change-group (group)
  "Restore GROUP's baseline and discard exactly its retained undo history."
  (let* ((buffer (begin-change-group-close group))
         (baseline (buffer-change-group-baseline group))
         (replay-tick nil)
         (open-state nil))
    (handler-case
        (progn
          (preflight-change-group-close
           group buffer (buffer-change-group-split-open-p group))
          (setf open-state (seal-change-group-open-command buffer))
          (change-group-path-to-current
           group (buffer-%undo-tree-current buffer))
          (setf replay-tick (buffer-modified-tick buffer))
          (let ((*undo-tree-history-move-group* group))
            (move-to-undo-node (buffer-point buffer) baseline))
          (discard-change-group-descendants group buffer)
          (validate-undo-tree buffer)
          (when (buffer-change-group-split-open-p group)
            (unseal-split-baseline group buffer))
          (incf (buffer-%undo-tree-generation buffer))
          (finish-change-group-close group buffer))
      (error (condition)
        (cond
          ((and replay-tick
                (/= replay-tick (buffer-modified-tick buffer))
                (eq group (buffer-%active-change-group buffer)))
           (buffer-reset-undo-tree buffer :dirty t :truncated t))
          (t
           (when open-state
             (restore-change-group-open-command buffer open-state))
           (restore-change-group-after-failure group buffer)))
        (error condition)))))

(defun buffer-abort-change-group (group)
  "Fail closed after GROUP cannot be accepted or canceled.

The live text is preserved, ownership is released, and retained undo history
is reset because it can no longer promise transactional rollback."
  (check-type group buffer-change-group)
  (let ((buffer (buffer-change-group-buffer group)))
    (when (undo-tree-replaying-buffer-p buffer)
      (editor-error "Cannot abort a change group during undo replay"))
    (cond
      ((deleted-buffer-p buffer)
       (setf (buffer-change-group-state group) :inactive)
       t)
      ((eq group (buffer-%active-change-group buffer))
       (buffer-reset-undo-tree
        buffer :dirty (buffer-modified-p buffer) :truncated t)
       t)
      ((eq :inactive (buffer-change-group-state group)) nil)
      (t
       (editor-error "The buffer is owned by another change group")))))
