(defpackage :lem-tests/showparen
  (:use :cl :rove :lem))
(in-package :lem-tests/showparen)

(defclass paren-test-interface (lem-fake-interface:fake-interface)
  ((mouse-x :initform -1 :accessor mouse-x)
   (mouse-y :initform -1 :accessor mouse-y)))

(defmethod lem-if:get-mouse-position ((interface paren-test-interface))
  (values (mouse-x interface) (mouse-y interface)))

(defun highlight-columns ()
  ;; Inspect the real overlay list owned by the paren feature.
  (sort (mapcar (lambda (overlay) (point-charpos (overlay-start overlay)))
                lem/show-paren::*brackets-overlays*) #'<))

(deftest show-paren-reports-display-changes
  (with-current-buffers ()
    (with-implementation (make-instance 'paren-test-interface)
      (setup-first-frame)
      (let ((buffer (make-buffer nil :temporary t :syntax-table lem-lisp-syntax:*syntax-table*))
            (lem/show-paren::*brackets-overlays* nil))
        (unwind-protect
             (progn
               (switch-to-buffer buffer)
               (insert-string (current-point) "(a) z")
               (buffer-start (current-point))
               (ok (lem/show-paren::update-show-paren))
               (ok (equal '(0 2) (highlight-columns)))
               (character-offset (current-point) 1)
               (ok (lem/show-paren::update-show-paren) "removing old highlights needs redisplay")
               (ok (null (highlight-columns)))
               (ng (lem/show-paren::update-show-paren) "no old or new highlights need no redisplay")
               (setf (mouse-x (implementation)) 2 (mouse-y (implementation)) 0)
               (ok (lem/show-paren::update-show-paren) "mouse hover still creates highlights")
               (ok (equal '(0 2) (highlight-columns)))
               (setf (mouse-x (implementation)) -1 (mouse-y (implementation)) -1)
               (ok (lem/show-paren::update-show-paren) "leaving a mouse match clears its highlights")
               (ng (lem/show-paren::update-show-paren))
               (setf (variable-value 'lem/show-paren:enable :buffer buffer) nil)
               (ng (lem/show-paren::update-show-paren))
               (ok (string= "(a) z" (buffer-text buffer)))
               (ok (= 1 (point-charpos (current-point)))))
          (mapc #'delete-overlay lem/show-paren::*brackets-overlays*)
          (delete-buffer buffer))))))
