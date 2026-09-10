(in-package :lem-daemon)

(defconstant +face-bold+ 1)
(defconstant +face-underline+ 2)
(defconstant +face-reverse+ 4)

(defun wire-color (color)
  (when color
    (color-to-hex-string
     (if (typep color 'lem/common/color:color) color (parse-color color)))))

(defun drawing-face (attribute &optional background primary-cursor-p)
  "Capture an attribute by value so later theme changes invalidate redisplay."
  (let ((attribute (ensure-attribute attribute nil)))
    (when (or attribute background)
      (list (and attribute (wire-color (attribute-foreground attribute)))
            (wire-color (or (and attribute (not primary-cursor-p)
                                (attribute-background attribute)) background))
            (logior (if (and attribute (attribute-bold attribute)) +face-bold+ 0)
                    (if (and attribute (attribute-underline attribute)) +face-underline+ 0)
                    (if (and attribute (attribute-reverse attribute))
                        +face-reverse+ 0))))))

(defun merge-drawing-faces (base face)
  (cond ((null face) base)
        ((null base) face)
        (t (list (or (first face) (first base))
                 (or (second face) (second base))
                 (logior (third base) (third face))))))

(defun encode-face-runs (cells faces)
  "Encode styled cell spans as [column, text, foreground, background, flags]."
  (let ((runs '())
        (start 0))
    (loop :while (< start (length cells))
          :for face := (aref faces start)
          :for end := (or (position-if (lambda (other) (not (equal face other)))
                                       faces :start (1+ start))
                         (length cells))
          :do (when face
                (let ((text (with-output-to-string (stream)
                              (loop :for column :from start :below end
                                    :for cell := (aref cells column)
                                    :when (stringp cell) :do (write-string cell stream)))))
                  (push (vector start text (first face) (second face) (third face)) runs)))
              (setf start end))
    (coerce (nreverse runs) 'vector)))
