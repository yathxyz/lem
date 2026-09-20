(defpackage :lem-tests/buffer/line
  (:use :cl :rove)
  (:local-nicknames (:line :lem/buffer/line)))
(in-package :lem-tests/buffer/line)

(defun reference-normalization (elements)
  ;; Preserve the original public behavior, including zero-width ranges,
  ;; duplicate sort keys, EQL boundaries and the left value's identity.
  (cond ((null elements) nil)
        ((null (cdr elements)) elements)
        (t
         (unless (loop :for (current next) :on elements
                       :while next
                       :always (<= (first current) (first next)))
           (setf elements (sort (copy-list elements) #'< :key #'first)))
         (nreverse
          (reduce (lambda (result next)
                    (let ((current (first result)))
                      (if (and current
                               (eql (second current) (first next))
                               (equal (third current) (third next)))
                          (cons (list (first current) (second next) (third current))
                                (rest result))
                          (cons next result))))
                  elements :initial-value nil)))))

(defun check-normalization (elements)
  (let* ((snapshot (copy-tree elements))
         (spine (copy-list elements))
         (expected (reference-normalization elements))
         (actual (line:normalization-elements elements)))
    (assert (equal expected actual))
    (assert (equal snapshot elements))
    (assert (every #'eq spine elements))
    (assert (every (lambda (a b) (eq (third a) (third b))) expected actual))
    (when (cdr elements)
      (loop :for tail :on actual
            :do (assert (loop :for input-tail :on elements
                              :never (eq tail input-tail))))
      (setf (car actual) :changed)
      (assert (equal snapshot elements)))))

(deftest normalization-boundaries-and-order
  (let ((ranges (loop :for start :from 0 :to 4
                      :append (loop :for end :from start :to 4
                                    :append (list (list start end :a)
                                                  (list start end :b)))))
        (cases 0))
    (check-normalization nil)
    (dolist (a ranges)
      (check-normalization (list a))
      (dolist (b ranges)
        (check-normalization (list a b))
        (dolist (c ranges)
          (check-normalization (list a b c))
          (incf cases))))
    (ok (= cases 27000)
        "all three-range combinations preserve order, values and input ownership")))

(deftest normalization-merges-do-not-change-input-ranges
  (let* ((left-value (list :face (copy-seq "same")))
         (right-value (copy-tree left-value))
         (ranges (list (list 4 6 right-value :extra)
                       (list 0 2 left-value :extra)
                       (list 2 4 right-value :extra)))
         (snapshot (copy-tree ranges))
         (result (line:normalization-elements ranges)))
    (ok (equal result (list (list 0 6 left-value))))
    (ok (eq left-value (third (first result))))
    (ng (member (first result) ranges :test #'eq))
    (setf (second (first result)) 100)
    (ok (equal snapshot ranges)))
  (dolist (ranges '(((1 2 nil) (0 1 nil) (3 4 nil))
                    ((2 3 :a) (0 1.0 :a) (1 2 :a))
                    ((3 4 :a) (0 2 :a) (1 3 :a))
                    ((4 4 :a) (0 0 :a) (2 2 :a))
                    ((8 9 :a) (4 6 :a) (0 2 :a) (2 4 :a) (6 8 :a))))
    (check-normalization (copy-tree ranges)))
  (ok t "gaps, overlap, empty ranges, NIL values and unequal numeric types retain their behavior"))
