(defpackage :lem-tests/buffer/internal
  (:use :cl
        :rove))
(in-package :lem-tests/buffer/internal)

(defun check-corruption (buffer)
  (handler-case (lem/buffer/internal:check-buffer-corruption buffer)
    (lem/buffer/internal:corruption-warning ()
      (fail "corruption"))))

(defun collect-line-plist (buffer)
  (loop :for line := (lem/buffer/internal::point-line (lem:buffer-start-point buffer))
        :then (lem/buffer/line:line-next line)
        :while line
        :collect (lem/buffer/line:line-plist line)))

(deftest point-nondecreasing-order
  (let* ((buffer (lem:make-buffer "point-order" :temporary t))
         (other (lem:make-buffer "point-order-other" :temporary t))
         (points '()))
    (unwind-protect
         (progn
           (lem:insert-string (lem:buffer-point buffer) (format nil "ab~%cd"))
           (lem:with-point ((point (lem:buffer-start-point buffer)))
             (dotimes (offset 6)
               (push (lem:copy-point point :temporary) points)
               (lem:character-offset point 1)))
           (setf points (nreverse points))
           ;; Numeric offsets independently specify order across columns and
           ;; lines. Exercise fixed arguments and the remaining variadic tail.
           (loop :for arity :from 1 :to 5
                 :do (let ((checked 0) (correct t))
                       (labels ((check-sequences (remaining offsets)
                                  (if (zerop remaining)
                                      (progn
                                        (incf checked)
                                        (unless (eq (apply #'<= offsets)
                                                    (apply #'lem:point<=
                                                           (mapcar (lambda (offset)
                                                                     (nth offset points))
                                                                   offsets)))
                                          (setf correct nil)))
                                      (dolist (offset '(0 1 3 5))
                                        (check-sequences (1- remaining)
                                                         (cons offset offsets))))))
                         (check-sequences arity '()))
                       (ok (and correct (= checked (expt 4 arity)))
                           (format nil "all orderings of ~D points" arity))))
           ;; A later buffer mismatch must signal even after an earlier pair
           ;; is out of order; explicitly supplied NIL is not a missing arg.
           (loop :for arity :from 2 :to 6
                 :do (dotimes (index arity)
                       (dolist (invalid (list nil (lem:buffer-point other)))
                         (let ((arguments (loop :for i :below arity
                                                :collect (nth (mod (- arity i) 6)
                                                              points))))
                           (setf (nth index arguments) invalid)
                           (ok (signals (apply #'lem:point<= arguments) 'error)))))))
      (lem:delete-buffer buffer)
      (lem:delete-buffer other))))

(deftest point-equality
  (let ((buffer (lem:make-buffer "point-equality" :temporary t))
        (other (lem:make-buffer "point-equality-other" :temporary t))
        (points '())
        (conditions '()))
    (unwind-protect
         (progn
           (lem:insert-string (lem:buffer-point buffer) (format nil "ab~%cd"))
           (lem:with-point ((point (lem:buffer-start-point buffer)))
             (dotimes (offset 6)
               (push (lem:copy-point point :temporary) points)
               (lem:character-offset point 1)))
           (setf points (nreverse points))
           (loop :for arity :from 1 :to 6
                 :do (let ((checked 0) (correct t))
                       (labels ((check-sequences (remaining offsets)
                                  (if (zerop remaining)
                                      (progn
                                        (incf checked)
                                        (unless (eq (apply #'= offsets)
                                                    (apply #'lem:point=
                                                           (mapcar (lambda (offset)
                                                                     (nth offset points))
                                                                   offsets)))
                                          (setf correct nil)))
                                      (dolist (offset '(0 1 3 5))
                                        (check-sequences (1- remaining)
                                                         (cons offset offsets))))))
                         (check-sequences arity '()))
                       (ok (and correct (= checked (expt 4 arity)))
                           (format nil "all equalities of ~D points" arity))))
           (lem:with-point ((copy (first points)))
             (ok (lem:point= copy (first points))
                 "distinct point objects can denote the same position"))
           (ok (signals (funcall (symbol-function 'lem:point=)) 'error))
           (ok (signals (lem:point= nil) 'error))
           ;; Validate the complete argument list even when earlier points
           ;; differ. Supplied NIL must not be treated as an omitted point.
           (loop :for arity :from 2 :to 6
                 :do (dotimes (index arity)
                       (dolist (invalid (list nil (lem:buffer-point other)))
                         (let ((arguments (loop :for i :below arity
                                                :collect (nth (mod i 6) points))))
                           (setf (nth index arguments) invalid)
                           (let ((condition (handler-case (progn (apply #'lem:point= arguments) nil)
                                              (error (condition) condition))))
                             (ok (typep condition 'error))
                             (when condition (push condition conditions)))))))
           ;; An assertion condition may retain its arguments after unwinding.
           ;; They must remain safe to print after the comparator has returned.
           #+sbcl (sb-ext:gc :full t)
           (ok (every (lambda (condition)
                        (plusp (length (princ-to-string condition))))
                      conditions)))
      (lem:delete-buffer buffer)
      (lem:delete-buffer other))))

(deftest edit-modification-generation
  (let* ((buffer (lem:make-buffer "edit-generation" :temporary t :enable-undo-p nil))
         (point (lem:buffer-point buffer)))
    (unwind-protect
         (progn
           (lem:insert-string point (format nil "one~%two~%three"))
           ;; Interior edits leave the end point's line and column unchanged.
           (dolist (line '(1 2 3))
             (lem:move-to-line point line)
             (let ((tick (lem:buffer-modified-tick buffer)))
               (lem:insert-string point "x")
               (ok (= (1+ tick) (lem:buffer-modified-tick buffer)))
               (lem:character-offset point -1)
               (lem:delete-character point 1)
               (ok (= (+ tick 2) (lem:buffer-modified-tick buffer)))))
           (lem:buffer-start point)
           (let ((tick (lem:buffer-modified-tick buffer)))
             (lem:insert-character point #\Newline)
             (lem:character-offset point -1)
             (lem:delete-character point 1)
             (ok (= (+ tick 2) (lem:buffer-modified-tick buffer))))
           (lem:buffer-end point)
           (let ((tick (lem:buffer-modified-tick buffer)))
             (lem:insert-string point "")
             (lem:delete-character point 0)
             (lem:delete-character point 1)
             (ok (= tick (lem:buffer-modified-tick buffer))
                 "empty edits and deletion past EOF do not dirty the buffer")))
      (lem:delete-buffer buffer))))

(deftest positions-after-unrecorded-edits
  (let* ((buffer (lem:make-buffer "position-cache" :temporary t :enable-undo-p nil))
         (point (lem:buffer-point buffer)))
    (unwind-protect
         (flet ((check-positions ()
                  (lem:with-point ((p (lem:buffer-start-point buffer)))
                    (loop :for expected :from 1
                          :do (ok (= expected (lem:position-at-point p)))
                          :while (lem:character-offset p 1)))))
           (lem:insert-string point (format nil "abc~%漢字~%end"))
           ;; Cache a later line, then edit before it without undo recording
           ;; first looking up (and thereby moving the cache to) the source.
           (lem:position-at-point (lem:buffer-end-point buffer))
           (lem:buffer-start point)
           (lem:insert-string point (format nil "prefix~%"))
           (check-positions)
           (lem:buffer-start point)
           (lem:with-inhibit-undo () (lem:delete-character point 9))
           (check-positions)
           (lem:erase-buffer buffer)
           (check-positions)
           (lem:insert-string point (format nil "fresh~%text"))
           (check-positions))
      (lem:delete-buffer buffer))))

(deftest positions-after-renderer-writes
  (dolist (undo-p '(nil t))
    (let* ((buffer (lem:make-buffer "renderer-position-cache" :temporary t
                                                           :enable-undo-p undo-p))
           (point (lem:buffer-point buffer)))
      (unwind-protect
           (progn
             (lem:insert-string point (format nil "abc~%漢字~%end"))
             (let ((tick (lem:buffer-modified-tick buffer))
                   (first-line (lem/buffer/internal:point-line (lem:buffer-start-point buffer))))
               (dolist (text '("longer replacement" "" "短"))
                 (lem:position-at-point (lem:buffer-end-point buffer))
                 (lem/buffer/line:set-line-string text first-line)
                 (ok (= tick (lem:buffer-modified-tick buffer)))
                 (ok (= (lem:position-at-point (lem:buffer-end-point buffer))
                        (1+ (length (lem:buffer-text buffer))))))))
        (lem:delete-buffer buffer)))))

(deftest insert-newline-test
  ;; Arrange
  (let* ((buffer (lem:make-buffer "test" :temporary t))
         (point (lem:buffer-point buffer)))
    (lem:insert-string point "a" :key1 100)
    (lem:insert-string point "bcdefg" :key2 200)
    (lem:insert-string point "hijklmnopqrstuvwxyz" :key3 300)

    ;; Act
    (lem:move-to-line point 1)
    (lem:move-to-column point 2)
    (lem:insert-character point #\newline)

    (lem:move-to-line point 2)
    (lem:move-to-column point 4)
    (lem:insert-character point #\newline)

    (lem:move-to-line point 3)
    (lem:move-to-column point 10)
    (lem:insert-character point #\newline)

    ;; Assertions
    (check-corruption buffer)
    (ok (= 4 (lem:buffer-nlines buffer)))
    (ok (equal "ab
cdef
ghijklmnop
qrstuvwxyz"
               (lem:buffer-text buffer)))
    (ok (equal '((:KEY3 NIL :KEY2 ((1 2 200)) :KEY1 ((0 1 100 NIL)))
                 (:KEY3 NIL)
                 (:KEY3 ((1 10 300)))
                 NIL)
               (collect-line-plist buffer)))))

(deftest exact-buffer-text-comparison
  ;; Exercise undo's integrity predicate directly, including equal-length
  ;; corruption and line boundaries that a length check alone cannot detect.
  (let* ((buffer (lem:make-buffer "text-comparison" :temporary t :enable-undo-p nil))
         (point (lem:buffer-point buffer)))
    (unwind-protect
         (dolist (text (list "" "abc" "漢字😀" (format nil "~%")
                             (format nil "a~%~%漢字😀~%end~%")))
           (lem:erase-buffer buffer)
           (lem:insert-string point text)
           (ok (lem/buffer/internal::buffer-text-equal-p buffer text))
           (ng (lem/buffer/internal::buffer-text-equal-p
                buffer (concatenate 'string text "x")))
           (unless (zerop (length text))
             (ng (lem/buffer/internal::buffer-text-equal-p
                  buffer (subseq text 0 (1- (length text))))))
           (dotimes (i (length text))
             (let ((changed (copy-seq text)))
               (setf (char changed i) #\?)
               (ng (lem/buffer/internal::buffer-text-equal-p buffer changed)))))
      (lem:delete-buffer buffer))))

(deftest undo-adjacent-route-still-validates-tree
  ;; Deliberately corrupt an internal parent link outside the one-edge route.
  ;; The ordinary undo API must reject it before applying any edit.
  (let* ((buffer (lem:make-buffer "undo-route-validation" :temporary t))
         (point (lem:buffer-point buffer)))
    (unwind-protect
         (progn
           (lem:insert-string point "abc")
           (lem:buffer-undo-boundary buffer)
           (lem:insert-string point "x")
           (lem:buffer-undo-boundary buffer)
           (let ((root (lem/buffer/internal::buffer-%undo-tree-root buffer))
                 (current (lem/buffer/internal::buffer-%undo-tree-current buffer))
                 (tick (lem:buffer-modified-tick buffer)))
             (unwind-protect
                  (progn
                    (setf (lem/buffer/internal::undo-tree-node-parent root) current)
                    (ok (signals (lem:buffer-undo point) 'lem/buffer/errors:editor-error))
                    (ok (string= "abcx" (lem:buffer-text buffer)))
                    (ok (= tick (lem:buffer-modified-tick buffer))))
               (setf (lem/buffer/internal::undo-tree-node-parent root) nil))))
      (lem:delete-buffer buffer))))

(deftest undo-redo
  (let* ((buffer (lem:make-buffer "test" :temporary t))
         (point (lem:buffer-point buffer)))
    (lem:insert-string point "Hello")
    (lem:buffer-undo-boundary buffer)
    (lem:insert-string point " World")
    (lem:buffer-undo-boundary buffer)
    (lem:buffer-undo point)
    (ok (equal "Hello" (lem:buffer-text buffer)))
    (lem:buffer-redo point)
    (ok (equal "Hello World" (lem:buffer-text buffer)))

    (check-corruption buffer)))

(deftest retained-undo-clean-identity-and-generation
  (let* ((buffer (lem:make-buffer "undo-clean-identity" :temporary t :enable-undo-p t))
         (point (lem:buffer-point buffer)))
    (unwind-protect
         (progn
           (lem:insert-string point "A")
           (lem:buffer-undo-boundary buffer)
           (let ((tick (lem:buffer-modified-tick buffer)))
             (lem:buffer-mark-saved buffer)
             (ok (= tick (lem:buffer-modified-tick buffer)))
             (ng (lem:buffer-modified-p buffer))
             (let* ((saved (lem:buffer-undo-tree-snapshot buffer))
                    (saved-id (getf saved :current)))
               (lem:insert-string point "")
               (lem:delete-character point 1)
               (lem:buffer-undo-boundary buffer)
               (ok (= tick (lem:buffer-modified-tick buffer)))
               (ok (equal saved (lem:buffer-undo-tree-snapshot buffer))
                   "no-op edits preserve both saved identity and history")
               (lem:buffer-undo point)
               (ok (string= "" (lem:buffer-text buffer)))
               (ok (= (1+ tick) (lem:buffer-modified-tick buffer)))
               (ok (lem:buffer-modified-p buffer))
               (lem:insert-string point "B")
               (lem:buffer-undo-boundary buffer)
               (ok (= (+ tick 2) (lem:buffer-modified-tick buffer)))
               (ok (lem:buffer-modified-p buffer)
                   "a sibling of the saved state must never appear clean")
               (lem:buffer-undo point)
               (ok (string= "" (lem:buffer-text buffer)))
               (lem:buffer-redo point)
               (ok (string= "B" (lem:buffer-text buffer)))
               (ok (= (+ tick 4) (lem:buffer-modified-tick buffer)))
               (let ((branch (lem:buffer-undo-tree-snapshot buffer)))
                 (ok (= 3 (getf branch :node-count))
                     "both children of the root remain retained")
                 (ok (= saved-id (getf branch :last-saved)))
                 (lem:buffer-undo-tree-move point saved-id (getf branch :generation)))
               (ok (string= "A" (lem:buffer-text buffer)))
               (ok (= (+ tick 6) (lem:buffer-modified-tick buffer)))
               (ng (lem:buffer-modified-p buffer)
                   "returning to the saved node restores clean identity"))))
      (lem:delete-buffer buffer))))

(deftest inhibited-edit-undo-route-integrity
  ;; A prefix/suffix can be carried through undo. An insertion inside the
  ;; retained payload cannot be silently deleted along with that payload.
  (dolist (offset '(0 1 3))
    (let* ((buffer (lem:make-buffer "inhibited-undo-route" :temporary t :enable-undo-p t))
           (point (lem:buffer-point buffer)))
      (unwind-protect
           (progn
             (lem:insert-string point "abc")
             (lem:buffer-undo-boundary buffer)
             (lem:buffer-mark-saved buffer)
             (lem:buffer-start point)
             (lem:character-offset point offset)
             (lem:with-inhibit-undo () (lem:insert-string point "x"))
             (lem:buffer-undo-boundary buffer)
             (let ((text (lem:buffer-text buffer))
                   (position (lem:position-at-point point))
                   (tick (lem:buffer-modified-tick buffer))
                   (snapshot (lem:buffer-undo-tree-snapshot buffer)))
               (if (= offset 1)
                   (progn
                     (ok (signals (lem:buffer-undo point) 'lem/buffer/errors:editor-error))
                     (ok (string= text (lem:buffer-text buffer)))
                     (ok (= position (lem:position-at-point point)))
                     (ok (= tick (lem:buffer-modified-tick buffer)))
                     (ok (equal snapshot (lem:buffer-undo-tree-snapshot buffer))
                         "refusal preserves history before any replay"))
                   (progn
                     (ok (lem:buffer-undo point))
                     (ok (string= "x" (lem:buffer-text buffer)))
                     (ok (= (1+ tick) (lem:buffer-modified-tick buffer)))
                     (ok (lem:buffer-redo point))
                     (ok (string= text (lem:buffer-text buffer)))))
               (ok (lem:buffer-modified-p buffer)
                   "an untracked edit remains dirty across history moves"))
             (check-corruption buffer))
        (lem:delete-buffer buffer)))))

(deftest |`buffer-end-point` points to the end of the buffer|
  ;; Arrange
  (let* ((buffer (lem:make-buffer "test" :temporary t))
         (point (lem:buffer-point buffer)))
    (lem:insert-string point "aaaaaaaaaa")

    ;; Act
    (lem:move-to-line point 1)
    (lem:move-to-column point 5)
    (lem:delete-character point 10)

    ;; Assertion
    (let ((end-point (lem:buffer-end-point buffer)))
      (ok (= 5 (lem:point-charpos end-point)))
      (ok (= 1 (lem:line-number-at-point point))))
    (check-corruption buffer)))

(deftest call-after-change-hook
  (let ((buffer (lem:make-buffer "test" :temporary t))
        received-parameters)
    (lem:add-hook (lem:variable-value 'lem:after-change-functions :buffer buffer)
                  (lambda (start end old-len)
                    (setf received-parameters (list start end old-len))))
    (lem:insert-string (lem:buffer-point buffer) "a")
    (when (ok received-parameters)
      (destructuring-bind (start end old-len)
          received-parameters
        (ok (= 1 (lem:position-at-point start)))
        (ok (= 2 (lem:position-at-point end)))
        (ok (= 0 old-len))))))

(defun print-buffer (point &key (cursor #'cl-ansi-text:red) (stream *standard-output*))
  (let* ((buffer (lem:point-buffer point))
         (text (str:concat (lem:buffer-text buffer) "  "))
         (pos (1- (lem:position-at-point point))))
    (format stream
            "~A~A~A~%"
            (subseq text 0 pos)
            (funcall cursor (string (char text pos)) :style :background)
            (subseq text (1+ pos)))))

(defun on-before-change (name)
  (lambda (point arg)
    (etypecase arg
      (string
       (format t "~A inserts ~S into position ~S~%" name arg (lem:position-at-point point)))
      (integer
       (format t
               "~A deletes ~S letters from position ~S~%"
               name
               arg
               (lem:position-at-point point))))))

(defun on-after-change (cursor)
  (lambda (start end old-len)
    (declare (ignore end old-len))
    (let* ((buffer (lem:point-buffer start))
           (point (lem:buffer-point buffer)))
      (print-buffer point :cursor cursor))))

(deftest multiuser-undo-case-1
  ;; Arrange
  (let* ((alice-buffer (lem:make-buffer "Alice's buffer" :temporary t))
         (bob-buffer (lem:make-buffer "Bob's buffer" :temporary t)))

    (lem:add-hook (lem:variable-value 'lem:before-change-functions :buffer alice-buffer)
                  (on-before-change "Alice"))
    (lem:add-hook (lem:variable-value 'lem:after-change-functions :buffer alice-buffer)
                  (on-after-change  #'cl-ansi-text:red))

    (lem:add-hook (lem:variable-value 'lem:before-change-functions :buffer bob-buffer)
                  (on-before-change "Bob"))
    (lem:add-hook (lem:variable-value 'lem:after-change-functions :buffer bob-buffer)
                  (on-after-change  #'cl-ansi-text:green))

    (format t "~%## Arrange~%")

    (lem:with-point ((alice-point (lem:buffer-point alice-buffer) :right-inserting)
                     (alice-temporary-point (lem:buffer-point alice-buffer) :left-inserting)
                     (bob-point (lem:buffer-point bob-buffer) :right-inserting)
                     (bob-temporary-point (lem:buffer-point bob-buffer) :left-inserting))


      (lem:buffer-disable-undo alice-buffer)
      (lem:buffer-disable-undo bob-buffer)

      (lem:insert-string alice-point "___")
      (lem:buffer-start alice-point)

      (lem:insert-string bob-point "___")
      (lem:buffer-start bob-point)
      (lem:character-offset bob-point 2)

      (lem:buffer-enable-undo alice-buffer)
      (lem:buffer-enable-undo bob-buffer)

      ;; Act
      (format t "~%## Act~%")

      (write-line "### Alice inserts \"a\"")
      (lem:insert-string alice-point "a")
      (lem:with-inhibit-undo ()
        (lem:insert-string (lem:move-to-position bob-temporary-point
                                                 (lem:position-at-point alice-point))
                           "a"))

      (terpri)

      (write-line "### Bob inserts \"b\"")
      (lem:insert-string bob-point "b")
      (lem:with-inhibit-undo ()
        (lem:insert-string (lem:move-to-position alice-temporary-point
                                                 (lem:position-at-point bob-point))
                           "b"))

      (terpri)

      (write-line "### Alice undo")
      (lem:buffer-undo alice-point)
      (lem:with-inhibit-undo ()
        (lem:delete-character (lem:move-to-position bob-temporary-point
                                                    (lem:position-at-point alice-point))
                              1))

      (terpri)

      (write-line "### Bob undo")
      (lem:buffer-undo bob-point)
      (lem:with-inhibit-undo ()
        (lem:delete-character (lem:move-to-position alice-temporary-point
                                                    (lem:position-at-point bob-point))
                              1))

      (terpri)
      (format t "Alice: ")
      (print-buffer alice-point :cursor #'cl-ansi-text:red)
      (format t "Bob:   ")
      (print-buffer bob-point :cursor #'cl-ansi-text:green)

      ;; Assertion
      (terpri)
      (ok (equal "___" (lem:buffer-text alice-buffer)))
      (ok (equal "___" (lem:buffer-text bob-buffer))))))

(deftest multiuser-undo-case-2
  ;; Arrange
  (let* ((alice-buffer (lem:make-buffer "Alice's buffer" :temporary t))
         (bob-buffer (lem:make-buffer "Bob's buffer" :temporary t)))

    (lem:add-hook (lem:variable-value 'lem:before-change-functions :buffer alice-buffer)
                  (on-before-change "Alice"))
    (lem:add-hook (lem:variable-value 'lem:after-change-functions :buffer alice-buffer)
                  (on-after-change  #'cl-ansi-text:red))

    (lem:add-hook (lem:variable-value 'lem:before-change-functions :buffer bob-buffer)
                  (on-before-change "Bob"))
    (lem:add-hook (lem:variable-value 'lem:after-change-functions :buffer bob-buffer)
                  (on-after-change  #'cl-ansi-text:green))

    (format t "~%## Arrange~%")

    (lem:with-point ((alice-point (lem:buffer-point alice-buffer) :right-inserting)
                     (alice-temporary-point (lem:buffer-point alice-buffer) :left-inserting)
                     (bob-point (lem:buffer-point bob-buffer) :right-inserting)
                     (bob-temporary-point (lem:buffer-point bob-buffer) :left-inserting))

      ;; Act
      (format t "~%## Act~%")

      (write-line "### Alice inserts \"abc\"")
      (lem:insert-string alice-point "abc")
      (lem:with-inhibit-undo ()
        (lem:insert-string (lem:move-to-position bob-temporary-point
                                                 (lem:position-at-point alice-point))
                           "abc"))

      (terpri)

      (write-line "### Bob deletes \"abc\"")
      (lem:delete-character (lem:buffer-start bob-point) 3)
      (lem:with-inhibit-undo ()
        (lem:delete-character (lem:move-to-position alice-temporary-point
                                                    (lem:position-at-point bob-point))
                              3))

      (terpri)

      ;; Assertion
      (pass "No internal errors within recompute-undo-position-offset"))))
