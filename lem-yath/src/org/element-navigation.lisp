;;;; GNU Org element-tree navigation for Evil-Org's gh/gl/gk/gj/gH maps.

(in-package :lem-yath)

(defstruct (org-element-navigation-node
            (:constructor make-org-element-navigation-node
                (type start end contents-start contents-end parent greater-p)))
  type
  start
  end
  contents-start
  contents-end
  parent
  greater-p)

(defun org-element-navigation-node-from-boundary
    (boundary parent &key type greater-p)
  (when boundary
    (let ((inner-start (%org-boundary-inner-start boundary))
          (inner-end (%org-boundary-inner-end boundary)))
      (make-org-element-navigation-node
       (or type (%org-boundary-node-type boundary))
       (copy-point (%org-boundary-start boundary) :temporary)
       (copy-point (%org-boundary-end boundary) :temporary)
       (and inner-start inner-end (point< inner-start inner-end)
            (copy-point inner-start :temporary))
       (and inner-start inner-end (point< inner-start inner-end)
            (copy-point inner-end :temporary))
       parent greater-p))))

(defun org-element-navigation-expand-blank-lines (origin)
  (with-point ((point origin))
    (line-start point)
    (loop :while (and (not (end-buffer-p point))
                      (org-navigation-blank-line-p point))
          :unless (line-offset point 1)
            :do (move-point point (buffer-end-point (point-buffer point)))
                (return))
    (copy-point point :temporary)))

(defun org-element-navigation-heading-node (heading)
  (when (and heading (org-heading-line-p heading))
    (let ((end (org-subtree-end-point heading))
          (contents-start (org-navigation-line-after heading))
          (parent-heading (org-parent-heading-point heading)))
      (when end
        (unless (and contents-start (point< contents-start end))
          (setf contents-start nil))
        (make-org-element-navigation-node
         :headline
         (with-point ((start heading))
           (line-start start)
           (copy-point start :temporary))
         (copy-point end :temporary)
         contents-start
         (copy-point end :temporary)
         (and parent-heading
              (org-element-navigation-heading-node parent-heading))
         t)))))

(defun org-element-navigation-section-node (origin)
  (alexandria:if-let ((heading (org-current-heading-point origin)))
    (let ((start (org-navigation-line-after heading))
          (end (org-section-end-point heading)))
      (make-org-element-navigation-node
       :section start end start end
       (org-element-navigation-heading-node heading) t))
    (let* ((start (copy-point
                   (buffer-start-point (point-buffer origin)) :temporary))
           (end (or (org-next-heading-point start)
                    (copy-point
                     (buffer-end-point (point-buffer origin)) :temporary))))
      (make-org-element-navigation-node
       :section start end start end nil t))))

(defun org-element-navigation-block-node (origin)
  (alexandria:when-let ((boundary (%org-block-boundary-at origin)))
    (org-element-navigation-node-from-boundary
     boundary
     (org-element-navigation-section-node origin)
     :greater-p (%org-greater-block-boundary-p boundary))))

(defun org-element-navigation-inside-greater-block-node (origin)
  (alexandria:when-let ((block (org-element-navigation-block-node origin)))
    (let ((start (org-element-navigation-node-contents-start block))
          (end (org-element-navigation-node-contents-end block)))
      (and (org-element-navigation-node-greater-p block)
           start end
           (not (point< origin start))
           (point< origin end)
           (null (org-block-marker (line-string origin)))
           block))))

(defun org-element-navigation-base-parent (origin)
  (or (org-element-navigation-inside-greater-block-node origin)
      (org-element-navigation-section-node origin)))

(defun org-element-navigation-parent-item (item)
  (let ((indent (nth-value 0 (org-list-item-columns item))))
    (when indent
      (with-point ((point item))
        (line-start point)
        (loop :while (line-offset point -1)
              :until (or (org-navigation-blank-line-p point)
                         (org-heading-line-p point))
              :when (org-list-item-line-p point)
                :do
                   (let ((candidate-indent
                           (nth-value 0 (org-list-item-columns point)))
                         (candidate-end (org-list-item-tree-end point)))
                     (when (and candidate-indent candidate-end
                                (< candidate-indent indent)
                                (point< item candidate-end))
                       (return (copy-point point :temporary)))))))))

(defun org-element-navigation-first-list-sibling (item)
  (let ((first (copy-point item :temporary)))
    (loop :for previous := (org-list-previous-sibling first)
          :while previous
          :do (move-point first previous))
    first))

(defun org-element-navigation-last-list-sibling (item)
  (let ((last (copy-point item :temporary)))
    (loop :for next := (org-list-next-sibling last)
          :while next
          :do (move-point last next))
    last))

(defun org-element-navigation-plain-list-node (item)
  (when item
    (let* ((first (org-element-navigation-first-list-sibling item))
           (last (org-element-navigation-last-list-sibling item))
           (core-end (org-list-item-tree-end last))
           (parent-item (org-element-navigation-parent-item first))
           (parent
             (if parent-item
                 (org-element-navigation-item-node parent-item)
                 (org-element-navigation-base-parent first))))
      (when core-end
        (make-org-element-navigation-node
         :plain-list first
         (org-element-navigation-expand-blank-lines core-end)
         (copy-point first :temporary)
         (copy-point core-end :temporary)
         parent t)))))

(defun org-element-navigation-item-node (item)
  (when item
    (multiple-value-bind (indent content-column text-column)
        (org-list-item-columns item)
      (declare (ignore indent content-column))
      (let ((end (org-list-item-tree-end item)))
        (when (and text-column end)
          (make-org-element-navigation-node
           :item
           (with-point ((start item))
             (line-start start)
             (copy-point start :temporary))
           (copy-point end :temporary)
           (org-navigation-point-at-column item text-column)
           (copy-point end :temporary)
           (org-element-navigation-plain-list-node item)
           t))))))

(defun org-element-navigation-list-paragraph-end (item)
  (let ((item-end (org-list-item-tree-end item)))
    (when item-end
      (with-point ((point item))
        (line-start point)
        (loop
          (unless (line-offset point 1)
            (return (copy-point item-end :temporary)))
          (when (or (not (point< point item-end))
                    (org-list-item-line-p point)
                    (org-navigation-blank-line-p point)
                    (org-table-line-p point)
                    (org-block-marker (line-string point)))
            (return (copy-point point :temporary))))))))

(defun org-element-navigation-list-paragraph-node (item)
  (multiple-value-bind (indent content-column text-column)
      (org-list-item-columns item)
    (declare (ignore indent content-column))
    (let ((end (org-element-navigation-list-paragraph-end item)))
      (when (and text-column end
                 (< text-column (length (line-string item))))
        (make-org-element-navigation-node
         :paragraph
         (org-navigation-point-at-column item text-column)
         end
         (org-navigation-point-at-column item text-column)
         (copy-point end :temporary)
         (org-element-navigation-item-node item)
         nil)))))

(defun org-element-navigation-list-node-at (origin)
  (alexandria:when-let ((item (org-navigation-list-anchor origin)))
    (multiple-value-bind (indent content-column text-column)
        (org-list-item-columns item)
      (declare (ignore content-column))
      (let ((on-item-line-p (same-line-p origin item))
            (column (point-charpos origin)))
        (cond
          ((or (not on-item-line-p)
               (and text-column (>= column text-column)))
           (or (org-element-navigation-list-paragraph-node item)
               (org-element-navigation-item-node item)))
          ((and (zerop column)
                (point= item
                        (org-element-navigation-first-list-sibling item)))
           (org-element-navigation-plain-list-node item))
          ((and indent (<= column text-column))
           (org-element-navigation-item-node item)))))))

(defun org-element-navigation-table-node (origin)
  (let ((table-origin
          (or (and (org-table-line-p origin) origin)
              (org-navigation-formula-table-origin origin))))
    (when table-origin
      (org-element-navigation-node-from-boundary
       (%org-table-boundary table-origin :kind :character)
       (org-element-navigation-base-parent table-origin)
       :type :table :greater-p t))))

(defun org-element-navigation-table-node-at (origin)
  (alexandria:when-let ((table (org-element-navigation-table-node origin)))
    (if (or (org-navigation-table-formula-line-p origin)
            (and (zerop (point-charpos origin))
                 (same-line-p origin
                              (org-element-navigation-node-start table))))
        table
        (org-element-navigation-node-from-boundary
         (%org-table-row-boundary origin) table
         :type :table-row :greater-p nil))))

(defun org-element-navigation-drawer-node (origin)
  (when (%org-inside-drawer-p origin)
    (with-point ((start origin))
      (line-start start)
      (loop :until (let ((marker (%org-drawer-marker (line-string start))))
                     (and marker (not (eq marker :end))))
            :unless (line-offset start -1)
              :do (return-from org-element-navigation-drawer-node nil))
      (with-point ((end-marker start))
        (loop :until (eq (%org-drawer-marker (line-string end-marker)) :end)
              :unless (line-offset end-marker 1)
                :do (return-from org-element-navigation-drawer-node nil))
        (let* ((raw-contents-start (org-navigation-line-after start))
               (contents-end (copy-point end-marker :temporary))
               (contents-start
                 (and raw-contents-start
                      (point< raw-contents-start contents-end)
                      raw-contents-start)))
          (make-org-element-navigation-node
           :property-drawer
           (copy-point start :temporary)
           (org-navigation-line-after end-marker)
           contents-start
           (and contents-start contents-end)
           (org-element-navigation-base-parent start)
           t))))))

(defun org-element-navigation-property-node (origin drawer)
  (make-org-element-navigation-node
   :node-property
   (with-point ((start origin))
     (line-start start)
     (copy-point start :temporary))
   (org-navigation-line-after origin)
   nil nil drawer nil))

(defun org-element-navigation-leaf-line-node (origin type parent)
  (with-point ((start origin))
    (line-start start)
    (let ((core-end (org-navigation-line-after start)))
      (make-org-element-navigation-node
       type
       (copy-point start :temporary)
       (org-element-navigation-expand-blank-lines core-end)
       nil nil parent nil))))

(defun org-element-navigation-special-line-node (origin)
  (let ((line (line-string origin))
        (parent (org-element-navigation-base-parent origin)))
    (cond
      ((cl-ppcre:scan
        "(?i)^\\s*(?:SCHEDULED|DEADLINE|CLOSED):" line)
       (org-element-navigation-leaf-line-node origin :planning parent))
      ((org-navigation-clock-line-p origin)
       (org-element-navigation-leaf-line-node origin :clock parent))
      ((org-navigation-keyword-line-p origin)
       (org-element-navigation-leaf-line-node origin :keyword parent))
      ((org-navigation-property-line-p line)
       (org-element-navigation-leaf-line-node origin :property parent)))))

(defun org-element-navigation-paragraph-node (origin)
  (when (org-navigation-ordinary-line-p origin)
    (multiple-value-bind (start core-end)
        (org-navigation-ordinary-bounds origin)
      (when (and start core-end)
        (make-org-element-navigation-node
         :paragraph start
         (org-element-navigation-expand-blank-lines core-end)
         (copy-point start :temporary)
         (copy-point core-end :temporary)
         (org-element-navigation-base-parent origin)
         nil)))))

(defun org-element-navigation-nonblank-node-at (origin)
  (cond
    ((org-heading-line-p origin)
     (org-element-navigation-heading-node origin))
    ((%org-inside-drawer-p origin)
     (let ((drawer (org-element-navigation-drawer-node origin)))
       (if (and drawer
                (not (eq (%org-drawer-marker (line-string origin)) :end))
                (not (same-line-p origin
                                  (org-element-navigation-node-start drawer))))
           (org-element-navigation-property-node origin drawer)
           drawer)))
    ((org-navigation-table-formula-line-p origin)
     (org-element-navigation-table-node-at origin))
    ((org-table-line-p origin)
     (org-element-navigation-table-node-at origin))
    ((org-navigation-list-anchor origin)
     (org-element-navigation-list-node-at origin))
    ((alexandria:when-let
         ((block (org-element-navigation-block-node origin)))
       (if (or (not (org-element-navigation-node-greater-p block))
               (org-block-marker (line-string origin)))
           block
           (let ((*org-recursive-block-list-navigation-p* t))
             (or (org-element-navigation-list-node-at origin)
                 (org-element-navigation-paragraph-node origin)
                 block)))))
    ((org-element-navigation-special-line-node origin))
    ((org-element-navigation-paragraph-node origin))))

(defun org-element-navigation-previous-nonblank-point (origin)
  (with-point ((point origin))
    (line-start point)
    (loop
      (unless (line-offset point -1)
        (return nil))
      (unless (org-navigation-blank-line-p point)
        (line-end point)
        (return (copy-point point :temporary))))))

(defun org-element-navigation-node-at (origin)
  (if (org-navigation-blank-line-p origin)
      (alexandria:when-let
          ((previous (org-element-navigation-previous-nonblank-point origin)))
        (alexandria:when-let
            ((node (org-element-navigation-nonblank-node-at previous)))
          (and (point< origin (org-element-navigation-node-end node)) node)))
      (org-element-navigation-nonblank-node-at origin)))

(defun org-element-navigation-move-to (point)
  (when point
    (move-point (current-point) point)
    t))

(defun org-element-navigation-forward-once ()
  (alexandria:when-let ((node (org-element-navigation-node-at (current-point))))
    (let* ((end (org-element-navigation-node-end node))
           (parent (org-element-navigation-node-parent node))
           (target
             (if (and parent
                      (org-element-navigation-node-contents-end parent)
                      (point= end
                              (org-element-navigation-node-contents-end parent)))
                 (org-element-navigation-node-end parent)
                 end)))
      (and (not (point= target (current-point)))
           (org-element-navigation-move-to target)))))

(defun org-element-navigation-heading-backward-target (heading)
  (let ((level (org-heading-level-at heading)))
    (with-point ((point heading))
      (loop :while (line-offset point -1)
            :for candidate := (org-heading-level-at point)
            :when (and candidate (< candidate level))
              :return (copy-point point :temporary)
            :when (eql candidate level)
              :return (copy-point point :temporary)))))

(defun org-element-navigation-backward-once ()
  (if (org-heading-line-p (current-point))
      (org-element-navigation-move-to
       (org-element-navigation-heading-backward-target (current-point)))
      (alexandria:when-let
          ((node (org-element-navigation-node-at (current-point))))
        (let ((start (org-element-navigation-node-start node)))
          (cond
            ((not (point= start (current-point)))
             (org-element-navigation-move-to start))
            (t
             (alexandria:when-let
                 ((previous
                    (org-element-navigation-previous-nonblank-point start)))
               (alexandria:when-let
                   ((previous-node
                      (org-element-navigation-node-at previous)))
                 (let ((target
                         (org-element-navigation-node-start previous-node))
                       (parent
                         (org-element-navigation-node-parent previous-node)))
                   (loop :while
                           (and parent
                                (not (point< start
                                            (org-element-navigation-node-end
                                             parent))))
                         :do (setf target
                                   (org-element-navigation-node-start parent)
                                   parent
                                   (org-element-navigation-node-parent parent)))
                   (org-element-navigation-move-to target))))))))))

(defun org-element-navigation-up-once ()
  (cond
    ((org-heading-line-p (current-point))
     (org-element-navigation-move-to
      (org-parent-heading-point (current-point))))
    (t
     (alexandria:when-let
         ((node (org-element-navigation-node-at (current-point))))
       (let ((parent (org-element-navigation-node-parent node)))
         (when (and parent
                    (eq (org-element-navigation-node-type parent) :section))
           (setf parent (org-element-navigation-node-parent parent)))
         (and parent
              (org-element-navigation-move-to
               (org-element-navigation-node-start parent))))))))

(defun org-element-navigation-down-once ()
  (alexandria:when-let ((node (org-element-navigation-node-at (current-point))))
    (let ((type (org-element-navigation-node-type node))
          (contents-start
            (org-element-navigation-node-contents-start node)))
      (cond
        ((and contents-start (member type '(:plain-list :table)))
         (with-point ((target contents-start))
           (character-offset target 1)
           (org-element-navigation-move-to target)))
        ((and contents-start
              (org-element-navigation-node-greater-p node))
         (org-element-navigation-move-to contents-start))))))

(defun org-element-navigation-top-once ()
  (alexandria:when-let ((heading (org-current-heading-point (current-point))))
    (let ((root (copy-point heading :temporary)))
      (loop :for parent := (org-parent-heading-point root)
            :while parent
            :do (move-point root parent))
      (unless (point= root (current-point))
        (org-element-navigation-move-to root)))))

(defun org-element-navigation-move (count forward-function backward-function)
  (let ((count (or count 1)))
    (dotimes (_ (abs count))
      (unless (funcall (if (minusp count)
                           backward-function
                           forward-function))
        (return)))))

(lem-vi-mode:define-motion lem-yath-org-forward-element (&optional (count 1))
    (:universal)
  (:type :exclusive)
  (org-run-evil-exclusive-motion
   #'org-element-navigation-move count
   #'org-element-navigation-forward-once
   #'org-element-navigation-backward-once))

(lem-vi-mode:define-motion lem-yath-org-backward-element (&optional (count 1))
    (:universal)
  (:type :exclusive)
  (org-run-evil-exclusive-motion
   #'org-element-navigation-move count
   #'org-element-navigation-backward-once
   #'org-element-navigation-forward-once))

(lem-vi-mode:define-motion lem-yath-org-up-element (&optional (count 1))
    (:universal)
  (:type :exclusive)
  (org-run-evil-exclusive-motion
   #'org-element-navigation-move count
   #'org-element-navigation-up-once
   #'org-element-navigation-down-once))

(lem-vi-mode:define-motion lem-yath-org-down-element (&optional (count 1))
    (:universal)
  (:type :exclusive)
  (org-run-evil-exclusive-motion
   #'org-element-navigation-move count
   #'org-element-navigation-down-once
   #'org-element-navigation-up-once))

(lem-vi-mode:define-motion lem-yath-org-top () ()
  (:type :exclusive :jump t)
  (org-run-evil-exclusive-motion #'org-element-navigation-top-once))
