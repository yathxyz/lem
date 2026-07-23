(in-package :lem-daemon)

(defclass daemon-implementation (lem:implementation)
  ((connection :initarg :connection :initform nil
               :reader daemon-implementation-connection)
   (width :initarg :width :initform 80 :accessor daemon-implementation-width)
   (height :initarg :height :initform 24 :accessor daemon-implementation-height)
   (previous-screen :initform nil
                    :accessor daemon-implementation-previous-screen)
   (previous-screen-width :initform nil
                          :accessor daemon-implementation-previous-screen-width))
  (:default-initargs
   :name :daemon
   :redraw-after-modifying-floating-window t))

(defstruct daemon-view
  x y width height modeline
  (grid (make-hash-table :test #'eql))
  cursor)

(defun drawing-object-text (object)
  (typecase object
    (lem-core/display:text-object
     (lem-core/display:text-object-string object))
    (lem-core/display:eol-cursor-object " ")
    (t "")))

(defun drawing-object-width (object)
  (typecase object
    (lem-core/display:text-object
     (string-width (lem-core/display:text-object-string object)))
    (lem-core/display:eol-cursor-object 1)
    (lem-core/display:image-object
     (lem-core/display:image-object-width object))
    (t 0)))

(defconstant +continuation-cell+ :continuation-cell)

(defun make-cell-row (width)
  (make-array width :initial-element " "))

(defun clear-cell-row (row column)
  (let ((column (max 0 column)))
    (when (and (< column (length row))
               (eq +continuation-cell+ (aref row column)))
      (loop :for index :downfrom (1- column) :to 0
            :when (stringp (aref row index))
              :do (setf (aref row index) " ") (loop-finish)))
    (loop :for index :from column :below (length row)
          :do (setf (aref row index) " ")))
  row)

(defun clear-cell-at (row column)
  (when (< column (length row))
    (let ((start column))
      (when (eq +continuation-cell+ (aref row start))
        (loop :while (and (plusp start)
                          (eq +continuation-cell+ (aref row start)))
              :do (decf start)))
      (setf (aref row start) " ")
      (loop :for index :from (1+ start) :below (length row)
            :while (eq +continuation-cell+ (aref row index))
            :do (setf (aref row index) " "))))
  row)

(defun overlay-text (row column text)
  (loop :with column := column
        :for character :across text
        :for string := (string character)
        :for width := (string-width string)
        :do (cond
              ((zerop width)
               (loop :for index :downfrom (1- column) :to 0
                     :when (stringp (aref row index))
                       :do (setf (aref row index)
                                 (concatenate 'string (aref row index) string))
                           (loop-finish)))
              ((<= (+ column width) (length row))
               (loop :for index :from column :below (+ column width)
                     :do (clear-cell-at row index))
               (setf (aref row column) string)
               (loop :for index :from (1+ column) :below (+ column width)
                     :do (setf (aref row index) +continuation-cell+))
               (incf column width))
              (t (return))))
  row)

(defun overlay-cells (target column source)
  (loop :for cell :across source
        :unless (eq cell +continuation-cell+)
          :do (overlay-text target column cell)
              (incf column (string-width cell)))
  target)

(defun cell-row-string (row)
  (with-output-to-string (stream)
    (loop :for cell :across row
          :when (stringp cell) :do (write-string cell stream))))

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
         (row (or (alexandria:when-let ((row (gethash y (daemon-view-grid view))))
                    (and (= width (length row)) row))
                  (make-cell-row width))))
    (clear-cell-row row x)
    (loop :with column := x
          :for object :in objects
          :do (when (lem-core::cursor-object-p object)
                (setf (daemon-view-cursor view) (cons column y)))
              (overlay-text row column (drawing-object-text object))
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
  (make-color 255 255 255))

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
  (declare (ignore default-attribute height))
  (let* ((width (daemon-view-width view))
         (right-width (loop :for object :in right-objects
                            :sum (drawing-object-width object)))
         (cells (make-cell-row width)))
    (loop :with column := 0
          :for object :in left-objects
          :do (overlay-text cells column (drawing-object-text object))
              (incf column (drawing-object-width object)))
    (loop :with column := (max 0 (- width right-width))
          :for object :in right-objects
          :do (overlay-text cells column (drawing-object-text object))
              (incf column (drawing-object-width object)))
    (setf (gethash (daemon-view-height view) (daemon-view-grid view))
          cells)))

(defun frame-windows (frame)
  (remove-duplicates
   (append (frame-header-windows frame)
           (window-list frame)
           (frame-floating-windows frame))
   :test #'eq))

(defun implementation-screen (implementation)
  (let* ((width (daemon-implementation-width implementation))
         (height (daemon-implementation-height implementation))
         (rows (make-array height))
         (cursor-x 0)
         (cursor-y 0))
    (dotimes (row height)
      (setf (aref rows row) (make-cell-row width)))
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
    (dotimes (row height)
      (setf (aref rows row) (cell-row-string (aref rows row))))
    (values rows
            (min (max 0 cursor-x) (max 0 (1- width)))
            (min (max 0 cursor-y) (max 0 (1- height))))))

(defmethod lem-if:update-display ((implementation daemon-implementation))
  (alexandria:when-let ((connection
                         (daemon-implementation-connection implementation)))
    (multiple-value-bind (rows cursor-x cursor-y)
        (implementation-screen implementation)
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
                     (unless (string= (aref previous row) (aref rows row))
                       (push (protocol:make-object
                              "row" row "text" (aref rows row))
                             changed)))
                   (coerce (nreverse changed) 'vector)))))
        (setf (daemon-implementation-previous-screen implementation) rows
              (daemon-implementation-previous-screen-width implementation)
              (daemon-implementation-width implementation))
        (daemon-send
         connection
         (if full-p
             (protocol:make-object
              "version" protocol:+protocol-version+
              "type" "screen" "full" t "rows" rows
              "cursor" (protocol:make-object "x" cursor-x "y" cursor-y))
             (protocol:make-object
              "version" protocol:+protocol-version+
              "type" "screen" "full" nil "changes" changes
              "cursor" (protocol:make-object "x" cursor-x "y" cursor-y))))))))

(defmethod lem-if:invoke ((implementation daemon-implementation) function)
  (declare (ignore implementation))
  (start-daemon-transport)
  (unwind-protect
       (let ((editor-thread (funcall function)))
         (bt2:join-thread editor-thread))
    (stop-daemon-transport)))
