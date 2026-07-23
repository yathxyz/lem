(in-package :lem/buffer/internal)

(deftype edit-kind ()
  '(member :insert-string :delete-string))

(defstruct (edit (:constructor make-edit (kind position string)))
  (kind (alexandria:required-argument :kind)
        :type edit-kind
        :read-only t)
  (position (alexandria:required-argument :position)
            :type (integer 1 *))
  (string (alexandria:required-argument :string)
          :type string
          :read-only t))

(defun valid-edit-position-p (point position &optional (delete-length 0))
  (let ((end-position
          (position-at-point (buffer-end-point (point-buffer point)))))
    (and (integerp position)
         (<= 1 position end-position)
         (<= (+ position delete-length) end-position))))

(defun expected-delete-text-p (point edit)
  (with-point ((end point))
    (and (or (zerop (length (edit-string edit)))
             (character-offset end (length (edit-string edit))))
         (string= (edit-string edit) (points-to-string point end)))))

(defun apply-edit (point edit)
  (ecase (edit-kind edit)
    ((:insert-string)
     (unless (valid-edit-position-p point (edit-position edit))
       (editor-error "Invalid undo insertion position ~D" (edit-position edit)))
     (move-to-position point (edit-position edit))
     (with-point ((p point))
       (insert-string/point point (edit-string edit))
       (move-point point p)))
    ((:delete-string)
     (unless (valid-edit-position-p point
                                    (edit-position edit)
                                    (length (edit-string edit)))
       (editor-error "Undo deletion is out of bounds at ~D"
                     (edit-position edit)))
     (move-to-position point (edit-position edit))
     (unless (expected-delete-text-p point edit)
       (editor-error "Undo deletion does not match buffer text at ~D"
                     (edit-position edit)))
     (delete-char/point point (length (edit-string edit))))))

(defun apply-inverse-edit (point edit)
  (ecase (edit-kind edit)
    ((:insert-string)
     (apply-edit point
                 (make-edit :delete-string
                            (edit-position edit)
                            (edit-string edit))))
    ((:delete-string)
     (apply-edit point
                 (make-edit :insert-string
                            (edit-position edit)
                            (edit-string edit))))))

(defun compute-edit-offset (dest src)
  "Shift DEST's recorded position past the untracked edit SRC. The arithmetic
is the certified kernel's offset algebra (SPEC-VK VK-4;
verified/buffer-edit.lisp `k-shift-position-insert' / `k-shift-position-delete',
proved position-tracking by `k-shift-position-*-tracks-content')."
  (setf (edit-position dest)
        (ecase (edit-kind src)
          ((:insert-string)
           (lem/kernel:k-shift-position-insert (edit-position dest)
                                               (edit-position src)
                                               (length (edit-string src))))
          ((:delete-string)
           (lem/kernel:k-shift-position-delete (edit-position dest)
                                               (edit-position src)
                                               (length (edit-string src)))))))
