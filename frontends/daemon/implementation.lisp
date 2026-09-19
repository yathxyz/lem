(in-package :lem-daemon)

(defvar *daemon-root-implementation* nil)

(defvar *byte-cell-strings*
  (let ((strings (make-array (min 256 char-code-limit) :initial-element nil)))
    (dotimes (code (length strings) strings)
      (let ((character (code-char code)))
        (when character (setf (svref strings code) (string character))))))
  "Shared character strings for rows, whose edits replace rather than mutate cells.
Only the representation is shared; character widths are always looked up live.")

(defclass daemon-implementation (lem:implementation)
  ((connection :initarg :connection :initform nil
               :reader daemon-implementation-connection)
   (width :initarg :width :initform 80 :accessor daemon-implementation-width)
   (height :initarg :height :initform 24 :accessor daemon-implementation-height)
   (foreground :initform (make-color 255 255 255)
               :accessor daemon-implementation-foreground)
   (background :initform (make-color 0 0 0)
               :accessor daemon-implementation-background)
   (cursor-shape :initarg :cursor-shape :initform :box
                 :accessor daemon-implementation-cursor-shape)
   (previous-screen :initform nil
                    :accessor daemon-implementation-previous-screen)
   (spare-screen :initform nil :accessor daemon-implementation-spare-screen)
   (previous-screen-width :initform nil
                          :accessor daemon-implementation-previous-screen-width))
  (:default-initargs
   :name :daemon
   :redraw-after-modifying-floating-window t))

(defstruct daemon-view
  x y width height modeline
  (grid (make-hash-table :test #'eql))
  cursor)

(defun drawing-object-width (object)
  (typecase object
    (lem-core/display:text-object
     (string-width (lem-core/display:text-object-string object)))
    (lem-core/display:eol-cursor-object 1)
    (lem-core/display:image-object
     (lem-core/display:image-object-width object))
    (t 0)))

(defconstant +continuation-cell+ :continuation-cell)

(defstruct (cell-row (:constructor %make-cell-row (cells faces)))
  (cells #() :type simple-vector)
  (faces #() :type simple-vector))

(defun make-cell-row (width &optional face)
  (%make-cell-row (make-array width :initial-element " ")
                  (make-array width :initial-element face)))

(defun clear-cell-row (row column &optional face)
  (let ((cells (cell-row-cells row))
        (faces (cell-row-faces row))
        (column (max 0 column)))
    (when (and (< column (length cells))
               (eq +continuation-cell+ (aref cells column)))
      (loop :for index :downfrom (1- column) :to 0
            :when (stringp (aref cells index))
              :do (setf (aref cells index) " " (aref faces index) face)
                  (loop-finish)))
    (loop :for index :from column :below (length cells)
          :do (setf (aref cells index) " " (aref faces index) face)))
  row)

(defun clear-cell-at (row column)
  (let ((cells (cell-row-cells row))
        (faces (cell-row-faces row)))
    (when (<= 0 column (1- (length cells)))
      (let ((start column))
        (when (eq +continuation-cell+ (aref cells start))
          (loop :while (and (plusp start)
                            (eq +continuation-cell+ (aref cells start)))
                :do (decf start)))
        (setf (aref cells start) " " (aref faces start) nil)
        (loop :for index :from (1+ start) :below (length cells)
              :while (eq +continuation-cell+ (aref cells index))
              :do (setf (aref cells index) " " (aref faces index) nil)))))
  row)

;; Let character loops specialize placement with their known width/string types.
(declaim (inline overlay-cell))
(defun overlay-cell (row column string width face)
  "Place one character, returning the next column or NIL at the right edge."
  (let ((cells (cell-row-cells row))
        (faces (cell-row-faces row)))
    (cond
      ((zerop width)
       (loop :for index :downfrom (1- column) :to 0
             :when (and (< index (length cells)) (stringp (aref cells index)))
               :do (setf (aref cells index)
                         (concatenate 'string (aref cells index) string))
                   (loop-finish))
       column)
      ((minusp column) (+ column width))
      ((eql width 1)
       (when (< column (length cells))
         ;; Ordinary cells can be replaced directly. Repair only a wide glyph
         ;; that starts here or whose continuation occupies this column.
         (when (or (eq (aref cells column) +continuation-cell+)
                   (and (< (1+ column) (length cells))
                        (eq (aref cells (1+ column)) +continuation-cell+)))
           (clear-cell-at row column))
         (setf (aref cells column) string (aref faces column) face)
         (1+ column)))
      (t
       (let ((end (+ column width)))
         (when (<= end (length cells))
           (loop :for index :from column :below end
                 :do (clear-cell-at row index))
           (setf (aref cells column) string (aref faces column) face)
           (loop :for index :from (1+ column) :below end
                 :do (setf (aref cells index) +continuation-cell+
                           (aref faces index) face))
           end))))))

(defun overlay-text (row column text &optional face)
  (loop :for character :across text
        :for code := (char-code character)
        :for string := (if (< code 256)
                           (svref *byte-cell-strings* code)
                           (string character))
        :unless (setf column (overlay-cell row column string
                                           (char-width character 0) face))
          :do (return))
  row)

(defun overlay-cells (target column source)
  (loop :for cell :across (cell-row-cells source)
        :for face :across (cell-row-faces source)
        :unless (eq cell +continuation-cell+)
          :do (if (= 1 (length (the string cell)))
                  ;; Row edits replace strings rather than mutating them. Reuse
                  ;; single-character cells, but consult the live width settings.
                  (let ((width (char-width (char cell 0) 0)))
                    (overlay-cell target column cell width face)
                    (incf column width))
                  (progn
                    (overlay-text target column cell face)
                    (incf column (string-width cell)))))
  target)

(defun cell-row-string (row)
  (with-output-to-string (stream)
    (loop :for cell :across (cell-row-cells row)
          :when (stringp cell) :do (write-string cell stream))))

(defun render-object-into-row (row column object &optional base-face)
  (typecase object
    (lem-core/display:extend-to-eol-object
     (overlay-text row column
                   (make-string (max 0 (- (length (cell-row-cells row)) column))
                                :initial-element #\Space)
                   (drawing-face nil (lem-core/display:extend-to-eol-object-color object))))
    (lem-core/display:text-object
     (overlay-text
      row
      (+ column (if (typep object 'lem-core/display:line-end-object)
                    (lem-core/display:line-end-object-offset object) 0))
      (lem-core/display:text-object-string object)
      (merge-drawing-faces
       base-face (drawing-face (lem-core/display:text-object-attribute object)
                               nil (lem-core::cursor-object-p object)))))
    (lem-core/display:eol-cursor-object
     (overlay-text row column " "
                   (drawing-face (lem-core/display:eol-cursor-object-attribute object)
                                  nil (lem-core/display:eol-cursor-object-true-cursor-p object))))))

(defmethod lem-if:make-view ((implementation daemon-implementation)
                             window x y width height use-modeline)
  (declare (ignore implementation window))
  (make-daemon-view :x x :y y :width width :height height
                    :modeline use-modeline))

(defmethod lem-if:delete-view ((implementation daemon-implementation) view)
  (declare (ignore implementation view)))

(defmethod lem-if:clear ((implementation daemon-implementation) view)
  (declare (ignore implementation))
  (clrhash (daemon-view-grid view))
  (setf (daemon-view-cursor view) nil))

(defmethod lem-if:set-view-size ((implementation daemon-implementation)
                                 view width height)
  (declare (ignore implementation))
  (setf (daemon-view-width view) width (daemon-view-height view) height))

(defmethod lem-if:set-view-pos ((implementation daemon-implementation) view x y)
  (declare (ignore implementation))
  (setf (daemon-view-x view) x (daemon-view-y view) y))

(defmethod lem-if:view-width ((implementation daemon-implementation) view)
  (declare (ignore implementation))
  (daemon-view-width view))

(defmethod lem-if:view-height ((implementation daemon-implementation) view)
  (declare (ignore implementation))
  (daemon-view-height view))

(defmethod lem-if:object-width ((implementation daemon-implementation) object)
  (declare (ignore implementation))
  (drawing-object-width object))

(defmethod lem-if:object-height ((implementation daemon-implementation) object)
  (declare (ignore implementation object))
  1)

(defmethod lem-if:get-char-width ((implementation daemon-implementation))
  (declare (ignore implementation)) 1)

(defmethod lem-if:get-char-height ((implementation daemon-implementation))
  (declare (ignore implementation)) 1)

(defmethod lem-if:render-line ((implementation daemon-implementation)
                               view x y objects height)
  (declare (ignore implementation height))
  (let* ((width (daemon-view-width view))
         (base-face (drawing-face nil lem-if:*background-color-of-drawing-window*))
         (row (or (alexandria:when-let ((row (gethash y (daemon-view-grid view))))
                    (and (= width (length (cell-row-cells row))) row))
                  (make-cell-row width))))
    (clear-cell-row row x base-face)
    (loop :with column := x
          :for object :in objects
          :do (when (if (typep object 'lem-core/display:eol-cursor-object)
                        (lem-core/display:eol-cursor-object-true-cursor-p object)
                        (lem-core::cursor-object-p object))
                (setf (daemon-view-cursor view) (cons column y)))
              (render-object-into-row row column object base-face)
              (incf column (drawing-object-width object)))
    (setf (gethash y (daemon-view-grid view)) row)))

(defmethod lem-if:clear-to-end-of-window ((implementation daemon-implementation)
                                          view y)
  (declare (ignore implementation))
  (let ((stale '()))
    (maphash (lambda (row strings)
               (declare (ignore strings))
               (when (>= row y) (push row stale)))
             (daemon-view-grid view))
    (dolist (row stale) (remhash row (daemon-view-grid view)))))

(defmethod lem-if:display-width ((implementation daemon-implementation))
  (daemon-implementation-width implementation))

(defmethod lem-if:display-height ((implementation daemon-implementation))
  (daemon-implementation-height implementation))

(defmethod lem-if:get-foreground-color ((implementation daemon-implementation))
  (daemon-implementation-foreground (or *daemon-root-implementation* implementation)))

(defmethod lem-if:get-background-color ((implementation daemon-implementation))
  (daemon-implementation-background (or *daemon-root-implementation* implementation)))

(defmethod lem-if:update-foreground ((implementation daemon-implementation) name)
  (setf (daemon-implementation-foreground (or *daemon-root-implementation* implementation))
        (parse-color name)))

(defmethod lem-if:update-background ((implementation daemon-implementation) name)
  (setf (daemon-implementation-background (or *daemon-root-implementation* implementation))
        (parse-color name)))

(defmethod lem-if:update-cursor-shape ((implementation daemon-implementation) shape)
  (check-type shape lem:cursor-type)
  (setf (daemon-implementation-cursor-shape implementation) shape))

(defmethod lem-if:display-title ((implementation daemon-implementation))
  "Lem daemon")

(defmethod lem-if:set-display-title ((implementation daemon-implementation) title)
  (declare (ignore title)))

(defmethod lem-if:display-fullscreen-p ((implementation daemon-implementation))
  nil)

(defmethod lem-if:set-display-fullscreen-p ((implementation daemon-implementation)
                                             fullscreen-p)
  (declare (ignore fullscreen-p)))

(defmethod lem-if:render-line-on-modeline
    ((implementation daemon-implementation) view left-objects right-objects
     default-attribute height)
  (declare (ignore height))
  (let* ((width (daemon-view-width view))
         (base-face (drawing-face default-attribute))
         (right-width (loop :for object :in right-objects
                            :sum (drawing-object-width object)))
         (cells (or (alexandria:when-let
                        ((row (gethash (daemon-view-height view) (daemon-view-grid view))))
                      (and (= width (length (cell-row-cells row))) row))
                    (make-cell-row width))))
    (fill (cell-row-cells cells) " ")
    (fill (cell-row-faces cells) base-face)
    (loop :with column := 0
          :for object :in left-objects
          :do (render-object-into-row cells column object base-face)
              (incf column (drawing-object-width object)))
    (loop :with column := (max 0 (- width right-width))
          :for object :in right-objects
          :do (render-object-into-row cells column object base-face)
              (incf column (drawing-object-width object)))
    (setf (gethash (daemon-view-height view) (daemon-view-grid view))
          cells)))

(defun frame-windows (frame)
  (remove-duplicates
   (append (frame-header-windows frame)
           (window-list frame)
           (frame-floating-windows frame))
   :test #'eq))

(defun implementation-screen (implementation &optional rows)
  "Compose a frame, optionally clearing and reusing private ROWS storage."
  (let* ((width (daemon-implementation-width implementation))
         (height (daemon-implementation-height implementation))
         (rows (if (and rows (= height (length rows)))
                   rows
                   (make-array height :initial-element nil)))
         (cursor-x 0)
         (cursor-y 0))
    (dotimes (row height)
      (let ((cells (aref rows row)))
        (if (and cells (= width (length (cell-row-cells cells))))
            (progn
              (fill (cell-row-cells cells) " ")
              (fill (cell-row-faces cells) nil))
            (setf (aref rows row) (make-cell-row width)))))
    (alexandria:when-let ((frame (get-frame implementation)))
      (dolist (window (frame-windows frame))
        (let* ((view (window-view window))
               (view-x (daemon-view-x view))
               (view-y (daemon-view-y view)))
          (maphash
           (lambda (relative-row cells)
            (let ((row (+ view-y relative-row)))
              (when (<= 0 row (1- height))
                (overlay-cells (aref rows row) view-x cells))))
           (daemon-view-grid view))
          (alexandria:when-let ((cursor (daemon-view-cursor view)))
            (when (eq window (frame-current-window frame))
              (setf cursor-x (+ view-x (car cursor))
                    cursor-y (+ view-y (cdr cursor))))))))
    (values rows
            (min (max 0 cursor-x) (max 0 (1- width)))
            (min (max 0 cursor-y) (max 0 (1- height))))))

(defun encode-screen-row (row &optional index)
  (let ((text (cell-row-string row))
        (runs (encode-face-runs (cell-row-cells row) (cell-row-faces row))))
    (if index
        (protocol:make-object "text" text "runs" runs "row" index)
        (protocol:make-object "text" text "runs" runs))))

(defun terminal-escape-delay ()
  (let* ((package (find-package :lem-ncurses/config))
         (symbol (and package (find-symbol "ESCAPE-DELAY" package))))
    (if symbol (variable-value symbol :global) 200)))

(defmethod lem-if:update-display ((implementation daemon-implementation))
  (alexandria:when-let ((connection
                         (daemon-implementation-connection implementation)))
    (multiple-value-bind (rows cursor-x cursor-y)
        ;; Keep the previous frame intact until diffing/encoding has finished.
        ;; The writer owns encoded octets, never these mutable composition grids.
        (implementation-screen implementation
                               (shiftf (daemon-implementation-spare-screen implementation) nil))
      (let* ((previous (daemon-implementation-previous-screen implementation))
             (full-p (or (null previous)
                         (/= (or (daemon-implementation-previous-screen-width
                                  implementation)
                                -1)
                             (daemon-implementation-width implementation))
                         (/= (length previous) (length rows))))
             (changes
               (unless full-p
                 (let ((changed '()))
                   (dotimes (row (length rows))
                     (unless (equalp (aref previous row) (aref rows row))
                       (push (encode-screen-row (aref rows row) row)
                             changed)))
                   (coerce (nreverse changed) 'vector)))))
        (setf (daemon-implementation-spare-screen implementation) previous
              (daemon-implementation-previous-screen implementation) rows
              (daemon-implementation-previous-screen-width implementation)
              (daemon-implementation-width implementation))
        (let* ((cursor-attribute (ensure-attribute 'cursor nil))
               (message
                 (protocol:make-object
                  "version" protocol:+protocol-version+
                  "type" "screen" "full" (and full-p t)
                  "foreground" (wire-color (lem-if:get-foreground-color implementation))
                  "background" (wire-color (lem-if:get-background-color implementation))
                  "mouse" (and (variable-value 'lem:mouse-mode :global) t)
                  "escape-delay" (terminal-escape-delay)
                  "cursor" (protocol:make-object
                            "x" cursor-x "y" cursor-y
                            "shape" (string-downcase
                                     (daemon-implementation-cursor-shape implementation))
                            "color" (wire-color
                                     (or (and cursor-attribute
                                              (attribute-background cursor-attribute))
                                         (lem-if:get-foreground-color implementation))))
                  (if full-p "rows" "changes")
                  (if full-p (map 'vector #'encode-screen-row rows) changes))))
          (daemon-send connection message))))))

(defmethod lem-if:invoke ((implementation daemon-implementation) function)
  (declare (ignore implementation))
  (start-daemon-transport)
  (unwind-protect
       (let ((editor-thread (funcall function)))
         (let ((result (bt2:join-thread editor-thread)))
           (when (typep result 'error)
             (error result))
           result))
    (stop-daemon-transport)))
