;;;; Visual navigation for Lem's retained undo tree (SPC u).

(in-package :lem-yath)

;; A source reload must use the old definitions to roll a live preview back
;; before replacing its mode, keymap, or session representation.
(eval-when (:load-toplevel :execute)
  (when (fboundp 'vundo-cleanup-for-reload)
    (vundo-cleanup-for-reload)))

(defconstant +vundo-window-height+ 3)
(defparameter +vundo-buffer-name+ "*vundo*")
(defparameter *vundo-render-node-limit* 4096)
(defparameter *vundo-render-depth-limit* 256)

(defvar *lem-yath-vundo-mode-keymap* (make-keymap))
(defvar *vundo-session* nil)
(defvar *vundo-pending-bottom-restore* nil)

(define-attribute vundo-current-attribute
  (t :foreground :base0D :bold t))
(define-attribute vundo-saved-attribute
  (t :foreground :base0B))
(define-attribute vundo-last-saved-attribute
  (t :foreground :base0A :bold t))
(define-attribute vundo-marked-attribute
  (t :foreground :base0E :bold t))

(defstruct vundo-session
  origin-buffer
  origin-window
  origin-point-position
  origin-view-position
  origin-read-only-p
  generation
  entry-id
  selected-id
  snapshot
  node-table
  tree-buffer
  tree-window
  previous-bottom-buffer
  previous-bottom-height
  previous-bottom-point-position
  previous-bottom-view-position
  previous-bottom-cursor-invisible-p
  previous-bottom-horizontal-scroll-start
  marked-id
  diff-buffer
  diff-window
  move-in-progress-p
  closing-p)

(define-major-mode lem-yath-vundo-mode nil
    (:name "Vundo"
     :keymap *lem-yath-vundo-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t
        (variable-value 'line-wrap :buffer (current-buffer)) nil
        (variable-value 'highlight-line :buffer (current-buffer)) nil))

;; Pinned Lem's Vi dispatcher puts state maps ahead of ordinary major-mode
;; maps.  Register this map explicitly so f/b/n/p are vundo motions rather
;; than Vi operators while the tree window has focus.
(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-vundo-mode))
  (list *lem-yath-vundo-mode-keymap*))

(defun vundo-core-function (name)
  (let ((symbol (find-symbol name :lem)))
    (unless (and symbol (fboundp symbol))
      (editor-error "The retained undo-tree API is unavailable: ~A" name))
    (symbol-function symbol)))

(defun vundo-core-snapshot (buffer)
  (funcall (vundo-core-function "BUFFER-UNDO-TREE-SNAPSHOT") buffer))

(defun vundo-invoke-core-move
    (point destination-id generation &optional rollback-destination-id)
  (funcall (vundo-core-function "BUFFER-UNDO-TREE-MOVE")
           point destination-id generation rollback-destination-id))

(defun vundo-session-core-move
    (session destination-id rollback-destination-id)
  "Move within SESSION while guaranteeing cancellation can return safely."
  (let* ((buffer (vundo-session-origin-buffer session))
         (point (buffer-point buffer))
         (read-only-p (buffer-read-only-p buffer)))
    ;; The source is locked against user/background edits while the visualizer
    ;; is active.  Only a prevalidated core replay route may lift that lock.
    (setf (buffer-read-only-p buffer) nil
          (vundo-session-move-in-progress-p session) t)
    (unwind-protect
         (let ((result
                 (vundo-invoke-core-move
                  point destination-id (vundo-session-generation session)
                  rollback-destination-id)))
           (unless (eq *vundo-session* session)
             ;; A change hook can kill/reload Vundo before the core commits its
             ;; destination.  The outer replay then finishes after cleanup's
             ;; nested rollback saw the old current node.  Its prevalidated
             ;; return route must be applied here before control escapes.
             (when (vundo-live-buffer-p buffer)
               (vundo-invoke-core-move
                (buffer-point buffer)
                rollback-destination-id
                (vundo-session-generation session)))
             (when (and (vundo-live-buffer-p buffer)
                        (not (eql rollback-destination-id
                                  (vundo-session-entry-id session))))
               ;; Diff extraction first returns to the selected preview; that
               ;; preview's entry route was preflighted when it was selected.
               (vundo-invoke-core-move
                (buffer-point buffer)
                (vundo-session-entry-id session)
                (vundo-session-generation session)))
             ;; Nested cleanup restored location before the outer replay
             ;; finished.  Reapply it after the compensating route.
             (vundo-restore-origin-location session)
             (vundo-focus-origin-or-fallback session)
             (editor-error "vundo session closed during undo replay"))
           result)
      ;; A re-entrant close has already restored the source's original lock.
      ;; Do not overwrite that result with the temporary session-owned lock.
      (setf (vundo-session-move-in-progress-p session) nil)
      (when (and (vundo-live-buffer-p buffer)
                 (eq *vundo-session* session)
                 (not (vundo-session-closing-p session)))
        (setf (buffer-read-only-p buffer) read-only-p)))))

(defun vundo-session-node (session id)
  (and id (gethash id (vundo-session-node-table session))))

(defun vundo-live-buffer-p (buffer)
  (and buffer (not (deleted-buffer-p buffer))))

(defun vundo-position-point (buffer position)
  (let ((point (copy-point (buffer-start-point buffer) :right-inserting)))
    (move-to-position point
                      (max 1 (min position
                                  (position-at-point
                                   (buffer-end-point buffer)))))
    point))

(defun vundo-reset-window-buffer (window buffer point-position view-position)
  "Display BUFFER in WINDOW with fresh buffer-owned window points."
  (let ((old-point (lem-core::%window-point window))
        (old-view (window-view-point window))
        (new-point (vundo-position-point buffer point-position))
        (new-view (vundo-position-point buffer view-position)))
    (lem-core::set-window-buffer buffer window)
    (lem-core::set-window-point new-point window)
    (lem-core::set-window-view-point new-view window)
    (ignore-errors (delete-point old-point))
    (ignore-errors (delete-point old-view))
    window))

(defun vundo-sync-origin-window-point (session)
  (let ((window (vundo-session-origin-window session))
        (buffer (vundo-session-origin-buffer session)))
    (when (and window buffer (not (deleted-window-p window))
               (vundo-live-buffer-p buffer))
      (move-point (window-point window) (buffer-point buffer))
      ;; Keep the live preview visible even though focus remains in the tree.
      (let ((top-line
              (max 1
                   (- (line-number-at-point (buffer-point buffer))
                      (floor (window-height window) 2)))))
        (move-to-line (window-view-point window) top-line)
        (line-start (window-view-point window))))))

(defun vundo-node-marker (session node)
  (if (eql (getf node :id) (vundo-session-selected-id session))
      #\●
      #\○))

(defun vundo-node-table (snapshot)
  (let ((table (make-hash-table :test #'eql)))
    (map nil
         (lambda (node)
           (setf (gethash (getf node :id) table) node))
         (getf snapshot :nodes))
    table))

(defun vundo-selected-ancestor-path (session table)
  "Return selected-to-root IDs iteratively, stopping at malformed cycles."
  (let ((id (vundo-session-selected-id session))
        (seen (make-hash-table :test #'eql))
        (path nil))
    (loop :while (and id (not (gethash id seen)))
          :for node := (gethash id table)
          :while node
          :do (setf (gethash id seen) t)
              (push id path)
              (setf id (getf node :parent)))
    (nreverse path)))

(defun vundo-render-root (session table)
  "Choose a bounded ancestor root while keeping the selected node visible."
  (let ((path (vundo-selected-ancestor-path session table)))
    (if (> (length path) *vundo-render-depth-limit*)
        (nth (1- *vundo-render-depth-limit*) path)
        (getf (vundo-session-snapshot session) :root))))

(defun vundo-collect-render-nodes (session table root-id)
  "Return an ID set, visit order, and whether the displayed tree is clipped."
  (let ((included (make-hash-table :test #'eql))
        (path-set (make-hash-table :test #'eql))
        (stack (list (list root-id 0)))
        (ids nil)
        (count 0)
        (clipped (not (eql root-id
                           (getf (vundo-session-snapshot session) :root)))))
    (dolist (id (vundo-selected-ancestor-path session table))
      (setf (gethash id path-set) t))
    (loop :while (and stack (< count *vundo-render-node-limit*))
          :for entry := (pop stack)
          :for id := (first entry)
          :for depth := (second entry)
          :for node := (gethash id table)
          :do
             (when (and node (not (gethash id included)))
               (setf (gethash id included) t)
               (push id ids)
               (incf count)
               (let ((children
                       (remove-if-not (lambda (child)
                                        (gethash child table))
                                      (getf node :children))))
                 (if (>= depth (1- *vundo-render-depth-limit*))
                     (when children (setf clipped t))
                     (let* ((path-child
                              (find-if (lambda (child)
                                         (gethash child path-set))
                                       children))
                            (ordered
                              (if path-child
                                  (cons path-child
                                        (remove path-child children
                                                :test #'eql))
                                  children)))
                       ;; STACK order affects only which nodes survive the cap;
                       ;; layout still uses the core's newest-first child order.
                       (setf stack
                             (append
                              (mapcar (lambda (child)
                                        (list child (1+ depth)))
                                      ordered)
                              stack)))))))
    (when stack (setf clipped t))
    (values included (nreverse ids) clipped)))

(defun vundo-render-heights (table included root-id)
  "Compute subtree row counts with an explicit postorder stack."
  (let ((heights (make-hash-table :test #'eql))
        (stack (list (cons root-id nil))))
    (loop :while stack
          :for entry := (pop stack)
          :for id := (car entry)
          :for visited := (cdr entry)
          :for node := (gethash id table)
          :when node
            :do
               (let ((children
                       (remove-if-not (lambda (child)
                                        (gethash child included))
                                      (getf node :children))))
                 (if visited
                     (setf (gethash id heights)
                           (max 1 (loop :for child :in children
                                        :sum (gethash child heights 1))))
                     (progn
                       (push (cons id t) stack)
                       (dolist (child children)
                         (push (cons child nil) stack))))))
    heights))

(defun vundo-render-coordinates (table included heights root-id)
  "Return ID -> (ROW . COLUMN) coordinates without recursive traversal."
  (let ((coordinates (make-hash-table :test #'eql))
        (stack (list (list root-id 0 0))))
    (loop :while stack
          :for entry := (pop stack)
          :for id := (first entry)
          :for depth := (second entry)
          :for row := (third entry)
          :for node := (gethash id table)
          :when (and node (gethash id included))
            :do
               (setf (gethash id coordinates) (cons row (* 3 depth)))
               (let ((next-row row)
                     (entries nil))
                 (dolist (child (getf node :children))
                   (when (gethash child included)
                     (push (list child (1+ depth) next-row) entries)
                     (incf next-row (gethash child heights 1))))
                 (dolist (child-entry entries)
                   (push child-entry stack))))
    coordinates))

(defun vundo-last-included-children (table included ids)
  "Map each rendered parent ID to its final rendered child in linear work."
  (let ((last-children (make-hash-table :test #'eql)))
    (dolist (id ids)
      (let ((node (gethash id table))
            (last nil))
        (dolist (child (and node (getf node :children)))
          (when (gethash child included)
            (setf last child)))
        (when last
          (setf (gethash id last-children) last))))
    last-children))

(defun vundo-render-row (rows row)
  (or (gethash row rows)
      (setf (gethash row rows)
            (make-array 16 :element-type 'character
                            :adjustable t :fill-pointer 0))))

(defun vundo-render-put (rows row column character)
  (let ((line (vundo-render-row rows row)))
    (loop :while (<= (length line) column)
          :do (vector-push-extend #\Space line))
    (let ((old (aref line column)))
      (setf (aref line column)
            (cond ((char= old #\Space) character)
                  ((or (char= old #\●) (char= old #\○)) old)
                  ((char= old character) old)
                  ((or (and (char= old #\│) (char= character #\─))
                       (and (char= old #\─) (char= character #\│)))
                   #\├)
                  (t character))))))

(defun vundo-node-attribute (session snapshot node)
  (let ((id (getf node :id)))
    (cond ((eql id (vundo-session-selected-id session))
           'vundo-current-attribute)
          ((eql id (vundo-session-marked-id session))
           'vundo-marked-attribute)
          ((eql id (getf snapshot :last-saved))
           'vundo-last-saved-attribute)
          ((getf node :saved-sequence)
           'vundo-saved-attribute)
          (t nil))))

(defun vundo-put-node-attributes (buffer positions table session snapshot)
  (maphash
   (lambda (id coordinate)
     (alexandria:when-let ((attribute
                            (vundo-node-attribute
                             session snapshot (gethash id table))))
       (with-point ((start (buffer-start-point buffer)))
         (move-to-line start (1+ (car coordinate)))
         (move-to-column start (cdr coordinate))
         (with-point ((end start))
           (character-offset end 1)
           (put-text-property start end :attribute attribute)))))
   positions))

(defun vundo-position-tree-window (session selected-coordinate)
  (let ((buffer (vundo-session-tree-buffer session))
        (window (vundo-session-tree-window session)))
    (when selected-coordinate
      (move-to-line (buffer-point buffer) (1+ (car selected-coordinate)))
      (move-to-column (buffer-point buffer) (cdr selected-coordinate))
      (when window
        (move-to-line (window-view-point window)
                      (1+ (max 0 (1- (car selected-coordinate)))))
        (move-to-column (window-view-point window) 0)
        (setf (window-parameter window 'lem-core::horizontal-scroll-start)
              (max 0 (- (cdr selected-coordinate)
                        (floor (window-width window) 2))))))))

(defun vundo-render-tree (session)
  "Render a capped horizontal Unicode tree using only snapshot node IDs."
  (let* ((buffer (vundo-session-tree-buffer session))
         (snapshot (vundo-session-snapshot session))
         (table (vundo-session-node-table session))
         (root-id (vundo-render-root session table)))
    (multiple-value-bind (included ids clipped)
        (vundo-collect-render-nodes session table root-id)
      (let* ((heights (vundo-render-heights table included root-id))
             (positions
               (vundo-render-coordinates table included heights root-id))
             (last-children
               (vundo-last-included-children table included ids))
             (rows (make-hash-table :test #'eql))
             (max-row 0))
        ;; Draw edges first, then node glyphs so a crossing can never hide a
        ;; node.  Every child list remains in the core's newest-first order.
        (dolist (id ids)
          (let* ((node (gethash id table))
                 (parent-id (getf node :parent))
                 (parent (and parent-id (gethash parent-id table)))
                 (coordinate (gethash id positions))
                 (parent-coordinate (and parent (gethash parent-id positions))))
            (when parent-coordinate
              (let* ((row (car coordinate))
                     (column (cdr coordinate))
                     (parent-row (car parent-coordinate))
                     (parent-column (cdr parent-coordinate))
                     (last-child (gethash parent-id last-children)))
                (if (= row parent-row)
                    (loop :for x :from (1+ parent-column) :below column
                          :do (vundo-render-put rows row x #\─))
                    (progn
                      (loop :for y :from (1+ parent-row) :below row
                            :do (vundo-render-put rows y parent-column #\│))
                      (vundo-render-put
                       rows row parent-column
                       (if (eql id last-child) #\└ #\├))
                      (loop :for x :from (1+ parent-column) :below column
                            :do (vundo-render-put rows row x #\─))))))))
        (dolist (id ids)
          (let* ((node (gethash id table))
                 (coordinate (gethash id positions)))
            (when coordinate
              (setf max-row (max max-row (car coordinate)))
              (vundo-render-put rows (car coordinate) (cdr coordinate)
                                (vundo-node-marker session node)))))
        (with-buffer-read-only buffer nil
          (erase-buffer buffer)
          (let ((point (buffer-point buffer)))
            (dotimes (row (1+ max-row))
              (let ((line (gethash row rows)))
                (when line
                  (insert-string point
                                 (string-right-trim '(#\Space)
                                                    (coerce line 'string)))))
              (insert-character point #\Newline))
            (insert-string
             point
             (format nil
                     "~:[~;clipped  ~]~:[~;core-truncated  ~]~D nodes  ~D bytes"
                     clipped (getf snapshot :truncated)
                     (getf snapshot :node-count 0)
                     (getf snapshot :payload-bytes 0))))
          (setf (buffer-value buffer :vundo-rendered-ids) ids
                (buffer-value buffer :vundo-selected-id)
                (vundo-session-selected-id session))
          (vundo-put-node-attributes buffer positions table session snapshot))
        (setf (buffer-read-only-p buffer) t)
        (vundo-position-tree-window
         session (gethash (vundo-session-selected-id session) positions))))))

(defun vundo-refresh (session)
  (let* ((buffer (vundo-session-origin-buffer session))
         (snapshot (vundo-core-snapshot buffer)))
    (setf (vundo-session-snapshot session) snapshot
          (vundo-session-node-table session) (vundo-node-table snapshot)
          (vundo-session-generation session) (getf snapshot :generation)
          (vundo-session-selected-id session) (getf snapshot :current))
    (vundo-sync-origin-window-point session)
    (vundo-render-tree session)
    snapshot))

(defun vundo-move-to (destination-id)
  (let ((session *vundo-session*))
    (unless session
      (editor-error "No active vundo session"))
    (unless destination-id
      (return-from vundo-move-to nil))
    (handler-case
        (progn
          (vundo-session-core-move
           session destination-id (vundo-session-entry-id session))
          (vundo-refresh session)
          t)
      (error (condition)
        (let ((generation-still-valid-p
                (handler-case
                    (= (vundo-session-generation session)
                       (getf (vundo-core-snapshot
                              (vundo-session-origin-buffer session))
                             :generation))
                  (error () nil))))
          (if generation-still-valid-p
              (message "vundo: ~A" condition)
              (progn
                ;; A fail-closed core recovery invalidates every entry ID.
                ;; Keep its truthful dirty root and release the UI lock.
                (vundo-close-session session :rollback nil
                                             :restore-location t)
                (message "vundo closed after undo recovery: ~A" condition))))
        nil))))

(defun vundo-selected-node (session)
  (vundo-session-node session (vundo-session-selected-id session)))

(defun vundo-linear-destination (session start-id count)
  "Follow first children or parents COUNT steps, stopping at an edge."
  (let ((id start-id)
        (forward-p (plusp count)))
    (dotimes (step (abs count) id)
      (let* ((node (vundo-session-node session id))
             (next (and node
                        (if forward-p
                            (first (getf node :children))
                            (getf node :parent)))))
        (unless next (return id))
        (setf id next)))))

(defun vundo-move-linear (count)
  (let* ((session *vundo-session*)
         (selected (and session (vundo-session-selected-id session)))
         (destination
           (and selected
                (vundo-linear-destination session selected count))))
    (when (and destination (not (eql destination selected)))
      (vundo-move-to destination))))

(define-command lem-yath-vundo-backward (&optional (count 1)) (:universal)
  (let* ((session *vundo-session*)
         (selected (and session (vundo-session-selected-id session))))
    (when selected (vundo-move-linear (- count)))))

(define-command lem-yath-vundo-forward (&optional (count 1)) (:universal)
  (vundo-move-linear count))

(defun vundo-move-sibling (offset)
  (let* ((session *vundo-session*)
         (node (and session (vundo-selected-node session)))
         (parent (and node
                      (vundo-session-node session (getf node :parent))))
         (siblings (and parent (getf parent :children)))
         (index (and siblings
                     (position (getf node :id) siblings :test #'eql))))
    (when index
      (let ((destination
              (max 0 (min (+ index offset) (1- (length siblings))))))
        (unless (= destination index)
          (vundo-move-to (nth destination siblings)))))))

(define-command lem-yath-vundo-next (&optional (count 1)) (:universal)
  (vundo-move-sibling count))

(define-command lem-yath-vundo-previous (&optional (count 1)) (:universal)
  (vundo-move-sibling (- count)))

(defun vundo-stem-root-node-p (session node)
  (alexandria:when-let ((parent
                         (vundo-session-node session (getf node :parent))))
    (> (length (getf parent :children)) 1)))

(defun vundo-stem-end-node-p (node)
  (/= (length (getf node :children)) 1))

(define-command lem-yath-vundo-stem-root () ()
  "Move to the beginning of the current stem, like vundo's `a'."
  (let* ((session *vundo-session*)
         (node (and session (vundo-selected-node session)))
         (destination nil))
    (when node
      ;; Vundo moves backward at least once, then stops when the new node is
      ;; itself a child of a branching node.
      (setf node (vundo-session-node session (getf node :parent)))
      (loop :while node
            :do (setf destination (getf node :id))
            :until (vundo-stem-root-node-p session node)
            :do (setf node
                      (vundo-session-node session (getf node :parent))))
      (vundo-move-to destination))))

(define-command lem-yath-vundo-next-root () ()
  "Move forward to the beginning of the next stem, like vundo's `w'."
  (let* ((session *vundo-session*)
         (node (and session (vundo-selected-node session)))
         (destination nil))
    (when node
      (setf node
            (vundo-session-node session (first (getf node :children))))
      (loop :while node
            :do (setf destination (getf node :id))
            :until (vundo-stem-root-node-p session node)
            :do (setf node
                      (vundo-session-node
                       session (first (getf node :children)))))
      (vundo-move-to destination))))

(define-command lem-yath-vundo-stem-end () ()
  "Move forward to the end of the current stem, like vundo's `e'."
  (let* ((session *vundo-session*)
         (node (and session (vundo-selected-node session)))
         (destination nil))
    (when node
      (setf node
            (vundo-session-node session (first (getf node :children))))
      (loop :while node
            :do (setf destination (getf node :id))
            :until (vundo-stem-end-node-p node)
            :do (setf node
                      (vundo-session-node
                       session (first (getf node :children)))))
      (vundo-move-to destination))))

(defun vundo-actually-saved-node-p (node)
  (not (null (getf node :saved-sequence))))

(defun vundo-saved-nodes-by-sequence (snapshot)
  (sort (remove-if-not #'vundo-actually-saved-node-p
                       (copy-list (getf snapshot :nodes)))
        #'> :key (lambda (node) (getf node :saved-sequence))))

(defun vundo-find-saved-by-history (snapshot start-id direction)
  "Find Vundo 2.4's previous or next actual save from START-ID.

From a saved node, save-event order is authoritative.  From an unsaved node,
the closest modification ID in the requested direction is used.  A generic
clean marker is deliberately not an actual save."
  (let* ((start (find start-id (getf snapshot :nodes)
                      :key (lambda (node) (getf node :id)) :test #'eql))
         (saved (vundo-saved-nodes-by-sequence snapshot)))
    (if (vundo-actually-saved-node-p start)
        (let ((index (position start-id saved
                               :key (lambda (node) (getf node :id))
                               :test #'eql)))
          (alexandria:when-let
              ((node (and index
                          (if (eq direction :backward)
                              (nth (1+ index) saved)
                              (and (> index 0) (nth (1- index) saved))))))
            (getf node :id)))
        (cond ((eq direction :backward)
               (loop :with best := nil
                     :for node :in saved
                     :for id := (getf node :id)
                     :when (and (< id start-id)
                                (or (null best) (> id best)))
                       :do (setf best id)
                     :finally (return best)))
              (t
               (loop :with best := nil
                     :for node :in saved
                     :for id := (getf node :id)
                     :when (and (> id start-id)
                                (or (null best) (< id best)))
                       :do (setf best id)
                     :finally (return best)))))))

(defun vundo-find-saved-by-count (snapshot start-id count)
  "Find the saved node COUNT events behind START-ID, matching Vundo 2.4."
  (let* ((direction (if (minusp count) :forward :backward))
         (remaining (abs count))
         (start (find start-id (getf snapshot :nodes)
                      :key (lambda (node) (getf node :id)) :test #'eql))
         (current start-id))
    ;; From an unsaved state, the closest saved node consumes the first step.
    ;; Vundo also chooses that node for a zero prefix.
    (unless (vundo-actually-saved-node-p start)
      (setf current
            (vundo-find-saved-by-history snapshot current direction))
      (when (and current (plusp remaining))
        (decf remaining)))
    (loop :while (and current (plusp remaining))
          :do (setf current
                    (vundo-find-saved-by-history
                     snapshot current direction))
              (decf remaining))
    current))

(define-command lem-yath-vundo-goto-last-saved
    (&optional (count 1)) (:universal)
  (let* ((session *vundo-session*)
         (snapshot (and session (vundo-session-snapshot session)))
         (selected (and session (vundo-session-selected-id session)))
         (destination
           (and snapshot
                (vundo-find-saved-by-count snapshot selected count))))
    (if destination
        (vundo-move-to destination)
        (message "vundo: no such saved node"))))

(define-command lem-yath-vundo-goto-next-saved
    (&optional (count 1)) (:universal)
  (let* ((session *vundo-session*)
         (snapshot (and session (vundo-session-snapshot session)))
         (destination
           (and snapshot
                (vundo-find-saved-by-count
                 snapshot (vundo-session-selected-id session) (- count)))))
    (if destination
        (vundo-move-to destination)
        (message "vundo: no such saved node"))))

(define-command lem-yath-vundo-save () ()
  "Save the live preview state without accepting or closing vundo."
  (let ((session *vundo-session*))
    (unless session (editor-error "No active vundo session"))
    (let* ((buffer (vundo-session-origin-buffer session))
           (read-only-p (buffer-read-only-p buffer)))
      (unwind-protect
           (progn
             (setf (buffer-read-only-p buffer) nil)
             (alexandria:when-let
                 ((filename (lem-core/commands/file:save-buffer buffer)))
               (message "Wrote ~A" filename)))
        (when (and (vundo-live-buffer-p buffer)
                   (eq *vundo-session* session)
                   (not (vundo-session-closing-p session)))
          (setf (buffer-read-only-p buffer) read-only-p))))
    (when (eq *vundo-session* session)
      (vundo-refresh session))))

(define-command lem-yath-vundo-mark () ()
  (let ((session *vundo-session*))
    (when session
      (setf (vundo-session-marked-id session)
            (vundo-session-selected-id session))
      (vundo-render-tree session))))

(define-command lem-yath-vundo-unmark () ()
  (let ((session *vundo-session*))
    (when session
      (setf (vundo-session-marked-id session) nil)
      (vundo-render-tree session))))

(defparameter *vundo-diff-character-limit* (* 256 1024))
(defparameter *vundo-diff-output-limit* (* 2 1024 1024))

(defun vundo-bounded-buffer-text (buffer)
  (let* ((start (buffer-start-point buffer))
         (end (buffer-end-point buffer))
         (characters (count-characters start end)))
    (when (> characters *vundo-diff-character-limit*)
      (editor-error "vundo diff is limited to ~D characters per state"
                    *vundo-diff-character-limit*))
    (points-to-string start end)))

(defun vundo-node-text (session node-id)
  "Copy NODE-ID text and transactionally return to the selected preview."
  (let* ((buffer (vundo-session-origin-buffer session))
         (selected-id (vundo-session-selected-id session))
         (point-position (position-at-point (buffer-point buffer)))
         (moved-p nil))
    (unless (eql node-id selected-id)
      (vundo-session-core-move session node-id selected-id)
      (setf moved-p t))
    (unwind-protect
         (vundo-bounded-buffer-text buffer)
      (when (and moved-p (eq *vundo-session* session))
        (vundo-session-core-move
         session selected-id (vundo-session-entry-id session))
        (move-to-position
         (buffer-point buffer)
         (max 1 (min point-position
                     (position-at-point (buffer-end-point buffer)))))
        (vundo-sync-origin-window-point session)))))

(defun vundo-private-temporary-pathname (label)
  (merge-pathnames
   (format nil "lem-yath-vundo-~A.~D.~16,'0X"
           label
           #+sbcl (sb-posix:getpid)
           #-sbcl 0
           (random (ash 1 60)))
   (uiop:temporary-directory)))

(defun vundo-write-private-temporary-file (label text)
  "Write TEXT through an O_EXCL/O_NOFOLLOW mode-0600 temporary file."
  #+sbcl
  (let ((pathname (vundo-private-temporary-pathname label))
        (descriptor nil)
        (stream nil)
        (complete-p nil))
    (unwind-protect
         (progn
           (setf descriptor
                 (sb-posix:open
                  (uiop:native-namestring pathname)
                  (logior sb-posix:o-creat sb-posix:o-excl
                          sb-posix:o-wronly sb-posix:o-nofollow)
                  #o600))
           (sb-posix:fchmod descriptor #o600)
           (setf stream
                 (sb-sys:make-fd-stream
                  descriptor :output t :element-type 'character
                  :external-format :utf-8 :buffering :full
                  :name (uiop:native-namestring pathname)))
           (write-string text stream)
           (finish-output stream)
           (close stream)
           (setf stream nil
                 descriptor nil
                 complete-p t)
           pathname)
      (when stream
        (ignore-errors (close stream :abort t))
        (setf descriptor nil))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor)))
      (unless complete-p
        (ignore-errors (delete-file pathname)))))
  #-sbcl
  (error "Secure vundo diff files require the supported SBCL runtime"))

(defun vundo-unified-diff (old new old-label new-label)
  (alexandria:if-let ((diff (formatting-executable "diff")))
    (let ((old-path nil)
          (new-path nil))
      (unwind-protect
           (progn
             (setf old-path (vundo-write-private-temporary-file "old" old)
                   new-path (vundo-write-private-temporary-file "new" new))
             (multiple-value-bind (stdout stderr status)
                 (uiop:run-program
                  (formatting-timeout-command
                   (list diff "-u" "--label" old-label
                         (uiop:native-namestring old-path)
                         "--label" new-label
                         (uiop:native-namestring new-path)))
                  :output :string
                  :error-output :string
                  :ignore-error-status t)
               (when (> (length stdout) *vundo-diff-output-limit*)
                 (editor-error "vundo diff exceeded ~D output characters"
                               *vundo-diff-output-limit*))
               (case status
                 (0 (format nil "No differences.~%"))
                 (1 stdout)
                 (otherwise
                  (editor-error
                   "diff failed: ~A"
                   (formatting-error-summary stderr))))))
        (when old-path (ignore-errors (delete-file old-path)))
        (when new-path (ignore-errors (delete-file new-path)))))
    (editor-error "The diff executable is unavailable")))

(defun vundo-close-diff (session)
  (let ((window (vundo-session-diff-window session))
        (buffer (vundo-session-diff-buffer session)))
    (setf (vundo-session-diff-window session) nil
          (vundo-session-diff-buffer session) nil)
    (when (and window
               (not (deleted-window-p window))
               (not (eq window (vundo-session-origin-window session)))
               (not (eq window (vundo-session-tree-window session))))
      (ignore-errors (delete-window window)))
    (when (vundo-live-buffer-p buffer)
      (ignore-errors (delete-buffer buffer)))))

(defun vundo-show-diff (session text)
  (vundo-close-diff session)
  (let ((buffer (make-buffer "*vundo diff*" :enable-undo-p nil)))
    (buffer-disable-undo buffer)
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-point buffer) text)
      (buffer-start (buffer-point buffer)))
    (setf (buffer-read-only-p buffer) t)
    (setf (vundo-session-diff-buffer session) buffer)
    (let ((tree-window (vundo-session-tree-window session)))
      (handler-case
          (progn
            (vundo-focus-origin-or-fallback session)
            (setf (vundo-session-diff-window session)
                  (pop-to-buffer buffer)))
        (error (condition)
          (vundo-close-diff session)
          (error condition)))
      (when tree-window (setf (current-window) tree-window)))))

(define-command lem-yath-vundo-diff () ()
  "Show a bounded unified diff from the marked (or parent) node to current."
  (let* ((session *vundo-session*)
         (node (and session (vundo-selected-node session)))
         (new-id (and node (getf node :id)))
         (old-id (and node
                      (or (vundo-session-marked-id session)
                          (getf node :parent)))))
    (unless old-id
      (editor-error "vundo: mark a node or select a node with a parent"))
    (let ((new (vundo-node-text session new-id))
          (old (vundo-node-text session old-id)))
      (vundo-show-diff
       session
       (vundo-unified-diff old new
                           (format nil "node ~A" old-id)
                           (format nil "node ~A" new-id))))))

(defun vundo-restore-origin-location (session)
  (let ((buffer (vundo-session-origin-buffer session))
        (window (vundo-session-origin-window session)))
    (when (vundo-live-buffer-p buffer)
      (move-to-position
       (buffer-point buffer)
       (max 1 (min (vundo-session-origin-point-position session)
                   (position-at-point (buffer-end-point buffer))))))
    (when (and window (not (deleted-window-p window)))
      (move-to-position
       (window-view-point window)
       (max 1 (min (vundo-session-origin-view-position session)
                   (position-at-point
                    (buffer-end-point (window-buffer window)))))))))

(defun vundo-focus-origin-or-fallback (session)
  (let ((origin-window (vundo-session-origin-window session)))
    (cond ((and origin-window (not (deleted-window-p origin-window)))
           (setf (current-window) origin-window))
          ((first (window-list))
           (setf (current-window) (first (window-list)))))))

(defun vundo-restore-bottom-window (session)
  (let* ((window (frame-bottomside-window (current-frame)))
         (previous (vundo-session-previous-bottom-buffer session)))
    (cond ((and window previous (vundo-live-buffer-p previous))
           (vundo-reset-window-buffer
            window previous
            (vundo-session-previous-bottom-point-position session)
            (vundo-session-previous-bottom-view-position session))
           (resize-bottomside-window
            window (vundo-session-previous-bottom-height session))
           (if (vundo-session-previous-bottom-cursor-invisible-p session)
               (hide-cursor window)
               (show-cursor window))
           (setf (window-parameter
                  window 'lem-core::horizontal-scroll-start)
                 (vundo-session-previous-bottom-horizontal-scroll-start
                  session)))
          (window
           (delete-bottomside-window)))))

(defun vundo-restore-pending-bottom-window ()
  (alexandria:when-let ((session *vundo-pending-bottom-restore*))
    (setf *vundo-pending-bottom-restore* nil)
    (let ((previous (vundo-session-previous-bottom-buffer session)))
      (when (and previous (vundo-live-buffer-p previous))
        (if (frame-bottomside-window (current-frame))
            (message "vundo could not restore the previous bottom pane: occupied")
            (progn
              (make-bottomside-window
               previous :height (vundo-session-previous-bottom-height session))
              (vundo-restore-bottom-window session)))))))

(defun vundo-attempt-session-rollback (session)
  "Return true after rollback, or keep a usable locked session on failure."
  (let* ((buffer (vundo-session-origin-buffer session))
         (old-generation (vundo-session-generation session)))
    (setf (buffer-read-only-p buffer) nil)
    (handler-case
        (progn
          (vundo-invoke-core-move
           (buffer-point buffer)
           (vundo-session-entry-id session)
           old-generation)
          t)
      (error (condition)
        (when (vundo-live-buffer-p buffer)
          (setf (buffer-read-only-p buffer) t))
        (setf (vundo-session-closing-p session) nil)
        (handler-case
            (let* ((snapshot (vundo-core-snapshot buffer))
                   (generation (getf snapshot :generation)))
              (setf (vundo-session-snapshot session) snapshot
                    (vundo-session-node-table session)
                    (vundo-node-table snapshot)
                    (vundo-session-generation session) generation
                    (vundo-session-selected-id session)
                    (getf snapshot :current))
              (unless (= generation old-generation)
                ;; Fail-closed core recovery invalidates the old entry ID.
                ;; Keep the recovered state visible until the user explicitly
                ;; accepts or quits this new truthful root.
                (setf (vundo-session-entry-id session)
                      (getf snapshot :current)
                      (vundo-session-marked-id session) nil)
                (vundo-close-diff session))
              (vundo-sync-origin-window-point session)
              (vundo-render-tree session))
          (error (refresh-condition)
            (message "vundo rollback refresh failed: ~A" refresh-condition)))
        (message "vundo rollback refused; session remains open: ~A" condition)
        nil))))

(defun vundo-close-session
    (session &key rollback restore-location tree-buffer-being-killed-p
                  bottom-window-being-deleted-p)
  (when (and session (not (vundo-session-closing-p session)))
    (setf (vundo-session-closing-p session) t)
    (labels ((cleanup-step (label function)
               (handler-case (funcall function)
                 (error (condition)
                   (message "vundo ~A cleanup failed: ~A" label condition)))))
      (when (and rollback
                 (not (vundo-session-move-in-progress-p session))
                 (vundo-live-buffer-p
                  (vundo-session-origin-buffer session))
                 (not (vundo-attempt-session-rollback session)))
        (unless (or tree-buffer-being-killed-p
                    bottom-window-being-deleted-p)
          (return-from vundo-close-session nil))
        ;; A window/buffer already being destroyed cannot host the retained
        ;; session.  Continue fail-closed after reporting the rollback error.
        (setf (vundo-session-closing-p session) t))
      (unwind-protect
           (progn
             (cleanup-step "diff" (lambda () (vundo-close-diff session)))
             (cleanup-step
              "focus" (lambda () (vundo-focus-origin-or-fallback session)))
             (when restore-location
               (cleanup-step
                "location"
                (lambda () (vundo-restore-origin-location session))))
             (cleanup-step
              "source lock"
              (lambda ()
                (when (vundo-live-buffer-p
                       (vundo-session-origin-buffer session))
                  (setf (buffer-read-only-p
                         (vundo-session-origin-buffer session))
                        (vundo-session-origin-read-only-p session)))))
             (unless bottom-window-being-deleted-p
               (cleanup-step
                "bottom window"
                (lambda () (vundo-restore-bottom-window session))))
             (unless tree-buffer-being-killed-p
               (cleanup-step
                "tree buffer"
                (lambda ()
                  (when (vundo-live-buffer-p
                         (vundo-session-tree-buffer session))
                    (delete-buffer (vundo-session-tree-buffer session)))))))
        (when (eq *vundo-session* session)
          (setf *vundo-session* nil)))
      t)))

(define-command lem-yath-vundo-quit () ()
  (vundo-close-session *vundo-session* :rollback t :restore-location t))

(define-command lem-yath-vundo-confirm () ()
  (vundo-close-session *vundo-session* :rollback nil :restore-location nil))

(defun vundo-tree-window-delete-hook ()
  (let ((session *vundo-session*))
    (when (and session (not (vundo-session-closing-p session)))
      ;; DELETE-WINDOW runs this hook after removing the window but before
      ;; freeing or marking it deleted.  Detach the side-window owner now and
      ;; never ask cleanup to delete/restore the half-deleted object.
      (when (eq (frame-bottomside-window (current-frame))
                (vundo-session-tree-window session))
        (setf (frame-bottomside-window (current-frame)) nil))
      (when (vundo-live-buffer-p
             (vundo-session-previous-bottom-buffer session))
        ;; The caller may be DELETE-BOTTOMSIDE-WINDOW, which clears the frame
        ;; slot only after this hook returns.  Restore the displaced occupant
        ;; from the next post-command hook, after the old window is fully free.
        (setf *vundo-pending-bottom-restore* session))
      (vundo-close-session session :rollback t :restore-location t
                                  :bottom-window-being-deleted-p t))))

(defun vundo-tree-window-live-p (session)
  (let ((window (vundo-session-tree-window session)))
    (and window
         (not (deleted-window-p window))
         (eq (window-buffer window) (vundo-session-tree-buffer session)))))

(defun vundo-restore-refused-session-view (session)
  "Reclaim a switched-away tree window after rollback was refused."
  (let ((window (vundo-session-tree-window session))
        (buffer (vundo-session-tree-buffer session)))
    (when (and window buffer
               (not (deleted-window-p window))
               (vundo-live-buffer-p buffer)
               (eq window (frame-bottomside-window (current-frame))))
      (vundo-reset-window-buffer window buffer 1 1)
      (hide-cursor window)
      (setf (current-window) window)
      (vundo-render-tree session)
      t)))

(defun vundo-post-command-hook ()
  (vundo-restore-pending-bottom-window)
  (let ((session *vundo-session*))
    (when (and session
               (not (vundo-session-closing-p session))
               (not (vundo-tree-window-live-p session)))
      (unless (vundo-close-session
               session :rollback t :restore-location t)
        (if (vundo-restore-refused-session-view session)
            (message "vundo close refused; restored the undo-tree view")
            (progn
              ;; With no recoverable owner window, retaining a locked orphan
              ;; is worse than releasing the truthful current preview.
              (vundo-close-session session :rollback nil
                                           :restore-location t)
              (message
               "vundo rollback refused and its view was lost; closed fail-safe")))))))

(defun vundo-kill-buffer-hook (buffer)
  (let ((session *vundo-session*))
    (when (and session (eq buffer (vundo-session-diff-buffer session)))
      ;; Lem switches windows away from BUFFER before this hook runs.  Close
      ;; the remembered split explicitly before dropping its only handle.
      (let ((window (vundo-session-diff-window session)))
        (setf (vundo-session-diff-buffer session) nil
              (vundo-session-diff-window session) nil)
        (when (and window
                   (not (deleted-window-p window))
                   (not (eq window (vundo-session-origin-window session)))
                   (not (eq window (vundo-session-tree-window session))))
          (ignore-errors (delete-window window)))))
    (when (and session (not (vundo-session-closing-p session)))
      (cond ((eq buffer (vundo-session-origin-buffer session))
             ;; The source is disappearing, so there is nowhere to roll back.
             (vundo-close-session session :rollback nil
                                          :restore-location nil))
            ((eq buffer (vundo-session-tree-buffer session))
             ;; Kill hooks run before Lem frees BUFFER.  Treat killing the
             ;; visualizer as cancel, but let the outer deletion free it once.
             (vundo-close-session
              session :rollback t :restore-location t
                      :tree-buffer-being-killed-p t))))))

(defun vundo-cleanup-for-reload ()
  (when *vundo-session*
    (unless (vundo-close-session
             *vundo-session* :rollback t :restore-location t)
      (editor-error "Cannot reload while vundo rollback is refused")))
  (vundo-restore-pending-bottom-window))

(define-command lem-yath-vundo () ()
  "Open a live, rollback-capable visual navigator for the current undo tree."
  (when *vundo-session*
    (unless (vundo-close-session
             *vundo-session* :rollback t :restore-location t)
      (editor-error "Existing vundo session refused rollback")))
  ;; A fast SPC u must cancel the leader's delayed/help popup before vundo
  ;; inspects and temporarily claims the frame's bottom-side window.
  (lem/transient::hide-transient)
  (let* ((origin-buffer (current-buffer))
         (origin-window (current-window))
         (snapshot (vundo-core-snapshot origin-buffer))
         (current-id (getf snapshot :current))
         (bottom-window (frame-bottomside-window (current-frame))))
    (when (buffer-read-only-p origin-buffer)
      (editor-error "Cannot open vundo for a read-only buffer"))
    (when (or (null current-id) (<= (getf snapshot :node-count 0) 1))
      (editor-error "There is no undo history"))
    (when (eq origin-window bottom-window)
      (editor-error "Cannot open vundo from the bottom-side window"))
    (let* ((tree-buffer (make-buffer +vundo-buffer-name+ :enable-undo-p nil))
           (session
             (make-vundo-session
              :origin-buffer origin-buffer
              :origin-window origin-window
              :origin-point-position
              (position-at-point (buffer-point origin-buffer))
              :origin-view-position
              (position-at-point (window-view-point origin-window))
              :origin-read-only-p (buffer-read-only-p origin-buffer)
              :generation (getf snapshot :generation)
              :entry-id current-id
              :selected-id current-id
              :snapshot snapshot
              :node-table (vundo-node-table snapshot)
              :tree-buffer tree-buffer
              :previous-bottom-buffer (and bottom-window
                                            (window-buffer bottom-window))
              :previous-bottom-height (and bottom-window
                                            (window-height bottom-window))
              :previous-bottom-point-position
              (and bottom-window
                   (position-at-point (lem-core::%window-point bottom-window)))
              :previous-bottom-view-position
              (and bottom-window
                   (position-at-point (window-view-point bottom-window)))
              :previous-bottom-cursor-invisible-p
              (and bottom-window (window-cursor-invisible-p bottom-window))
              :previous-bottom-horizontal-scroll-start
              (and bottom-window
                   (window-parameter
                    bottom-window 'lem-core::horizontal-scroll-start)))))
      (setf *vundo-session* session)
      (let ((opened nil))
        (unwind-protect
             (progn
               ;; Reused names must not inherit undo data from an interrupted
               ;; older load.  The tree is derived display state only.
               (buffer-disable-undo tree-buffer)
               (change-buffer-mode tree-buffer 'lem-yath-vundo-mode)
               (let ((tree-window
                       (make-bottomside-window
                        tree-buffer :height +vundo-window-height+)))
                 (setf (vundo-session-tree-window session) tree-window)
                 (add-hook (window-delete-hook tree-window)
                           'vundo-tree-window-delete-hook)
                 (resize-bottomside-window tree-window +vundo-window-height+)
                 (vundo-reset-window-buffer tree-window tree-buffer 1 1)
                 (hide-cursor tree-window)
                 (setf (buffer-read-only-p origin-buffer) t)
                 (setf (current-window) tree-window)
                 (vundo-render-tree session)
                 (setf opened t)))
          (unless opened
            (vundo-close-session session :rollback nil
                                         :restore-location t)))))))

(define-key *lem-yath-vundo-mode-keymap* "f" 'lem-yath-vundo-forward)
(define-key *lem-yath-vundo-mode-keymap* "Right" 'lem-yath-vundo-forward)
(define-key *lem-yath-vundo-mode-keymap* "b" 'lem-yath-vundo-backward)
(define-key *lem-yath-vundo-mode-keymap* "Left" 'lem-yath-vundo-backward)
(define-key *lem-yath-vundo-mode-keymap* "n" 'lem-yath-vundo-next)
(define-key *lem-yath-vundo-mode-keymap* "Down" 'lem-yath-vundo-next)
(define-key *lem-yath-vundo-mode-keymap* "p" 'lem-yath-vundo-previous)
(define-key *lem-yath-vundo-mode-keymap* "Up" 'lem-yath-vundo-previous)
(define-key *lem-yath-vundo-mode-keymap* "a" 'lem-yath-vundo-stem-root)
(define-key *lem-yath-vundo-mode-keymap* "w" 'lem-yath-vundo-next-root)
(define-key *lem-yath-vundo-mode-keymap* "e" 'lem-yath-vundo-stem-end)
(define-key *lem-yath-vundo-mode-keymap* "l"
  'lem-yath-vundo-goto-last-saved)
(define-key *lem-yath-vundo-mode-keymap* "r"
  'lem-yath-vundo-goto-next-saved)
(define-key *lem-yath-vundo-mode-keymap* "m" 'lem-yath-vundo-mark)
(define-key *lem-yath-vundo-mode-keymap* "u" 'lem-yath-vundo-unmark)
(define-key *lem-yath-vundo-mode-keymap* "d" 'lem-yath-vundo-diff)
(define-key *lem-yath-vundo-mode-keymap* "q" 'lem-yath-vundo-quit)
(define-key *lem-yath-vundo-mode-keymap* "C-g" 'lem-yath-vundo-quit)
(define-key *lem-yath-vundo-mode-keymap* "Return" 'lem-yath-vundo-confirm)
(define-key *lem-yath-vundo-mode-keymap* "C-x C-s" 'lem-yath-vundo-save)

(remove-hook (variable-value 'kill-buffer-hook :global t)
             'vundo-kill-buffer-hook)
(add-hook (variable-value 'kill-buffer-hook :global t)
          'vundo-kill-buffer-hook)
(remove-hook *post-command-hook* 'vundo-post-command-hook)
(add-hook *post-command-hook* 'vundo-post-command-hook -400)
