(defpackage :lem-tests/display-attributes
  (:use :cl :rove :lem-core))
(in-package :lem-tests/display-attributes)

(defun describe-attribute (attribute)
  (when attribute
    (let ((attribute (ensure-attribute attribute)))
      (list (attribute-foreground attribute)
            (attribute-background attribute)
            (attribute-bold attribute)
            (attribute-reverse attribute)
            (attribute-underline attribute)
            ;; Include duplicate keys and ordering, beyond public field equality.
            (lem-core::attribute-plist attribute)))))

(defun attribute-at-cell (ranges index)
  (third (find-if (lambda (range)
                    (<= (first range) index (1- (second range))))
                  ranges)))

(defun combine-descriptions (under over)
  ;; An independent per-cell oracle: overlay fields take precedence, while
  ;; property lists retain both entries in overlay-first order.
  (if (null under)
      over
      (append (mapcar (lambda (upper lower) (or upper lower))
                      (subseq over 0 5) (subseq under 0 5))
              (list (append (sixth over) (sixth under))))))

(deftest overlay-range-boundaries
  (let* ((under (make-attribute :foreground "red" :bold t
                                :plist '(:under t :shared :under)))
         (over (make-attribute :background "blue" :underline t
                               :plist '(:shared :over)))
         (checked 0))
    (labels ((check-ranges (ranges start end)
               (let* ((snapshot (copy-tree ranges))
                      ;; This private renderer helper owns interval splitting.
                      (result (lem-core::overlay-attributes ranges start end over)))
                 (assert (equal snapshot ranges))
                 (dotimes (index 9)
                   (let* ((original (describe-attribute (attribute-at-cell ranges index)))
                          (expected (if (<= start index (1- end))
                                        (combine-descriptions original (describe-attribute over))
                                        original)))
                     (assert (equal expected
                                    (describe-attribute (attribute-at-cell result index))))))
                 (incf checked))))
      (loop :for start :from 0 :to 6
            :do (loop :for end :from start :to 6
                      :do (loop :for under-start :from 0 :to 6
                                :do (loop :for under-end :from under-start :to 6
                                          :do (check-ranges
                                               (list (list under-start under-end under))
                                               start end)))))
      (ok (= checked 784) "all ordered boundaries, including empty and touching ranges")
      (dolist (ranges (list nil
                           (list (list 0 2 under) (list 4 6 under) (list 7 8 under))
                           (list (list 0 3 under) (list 3 8 over))
                           (list (list 0 1 over) (list 5 8 under))))
        (loop :for start :from 0 :to 8
              :do (loop :for end :from start :to 8
                        :do (check-ranges ranges start end))))
      (ok (= checked 964) "gaps, adjacent attributes, and multiple covered ranges"))))

(deftest overlay-range-ownership
  (let* ((under (make-attribute :foreground "red"))
         (over (make-attribute :background "blue"))
         (ranges (list (list 0 8 under) (list 10 12 under)))
         (snapshot (copy-tree ranges))
         (result (lem-core::overlay-attributes ranges 2 4 over)))
    (ok (every (lambda (range) (not (member range ranges :test #'eq))) result)
        "returned interval cells can be edited independently")
    (setf (first (first result)) 100)
    (ok (equal snapshot ranges))))

(deftest overlay-provider-snapshot
  (let* ((provider (gensym "ATTRIBUTE-PROVIDER"))
         (under (make-attribute :foreground "red"))
         (over (make-attribute :background "blue"))
         (ranges (list (list 0 2 provider) (list 3 5 under)))
         (calls 0))
    ;; Attribute providers are executable. Resolving one must not change the
    ;; already captured boundaries of a later input interval.
    (setf (get provider 'lem-core::attribute)
          (lambda ()
            (incf calls)
            (setf (first (second ranges)) 100)
            under))
    (unwind-protect
         (let ((result (lem-core::overlay-attributes ranges 0 6 over)))
           (ok (= calls 1))
           (ok (equal (mapcar (lambda (range) (subseq range 0 2)) result)
                      '((0 2) (2 3) (3 5) (5 6))))
           (ok (equal (describe-attribute (attribute-at-cell result 4))
                      (combine-descriptions (describe-attribute under)
                                            (describe-attribute over)))))
      (remprop provider 'lem-core::attribute))))
