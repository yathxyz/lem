;; Standalone CLOS dispatch reproducer; no Lem, Qlot, or frontend required.
;; Run: sbcl --noinform --no-userinit --no-sysinit --script this-file.lisp
(defpackage :lem-bench/cold-command-dispatch
  (:use :cl))
(in-package :lem-bench/cold-command-dispatch)

(defclass mode () ())
(defclass derived-mode (mode) ())
(defclass command () ())
(defvar *events* nil)

(defgeneric dispatch (mode command argument)
  (:documentation "Model Lem's mode-first command dispatch without editing text."))

(defmethod dispatch :around ((mode mode) command argument)
  (declare (ignore command argument))
  (push :around-enter *events*)
  (multiple-value-prog1 (call-next-method)
    (push :around-exit *events*)))

(defmethod dispatch :before ((mode mode) command argument)
  (declare (ignore command argument))
  (push :before *events*))

(defmethod dispatch :after ((mode mode) command argument)
  (declare (ignore command argument))
  (push :after *events*))

(defun measure (phase mode command argument expected)
  (let* ((*events* nil)
         (start (get-internal-real-time))
         (result (multiple-value-list (dispatch mode command argument)))
         (elapsed (- (get-internal-real-time) start)))
    (assert (equal result (list expected argument)))
    (assert (equal (reverse *events*)
                   '(:around-enter :before :after :around-exit)))
    (format t "~A,~,3F~%" phase
            (* 1000d0 (/ elapsed internal-time-units-per-second)))))

;; Keep each primary method distinct, as DEFINE-COMMAND does. No slot access
;; in these methods: it would select a different SBCL dispatch strategy.
(loop :for index :below 1200
      :for name := (intern (format nil "COMMAND-~D" index))
      :do (eval `(defclass ,name (command) ()))
          (eval `(defmethod dispatch (mode (command ,name) argument)
                   (declare (ignore mode command))
                   (values ,index argument))))

(format t "Implementation: ~A ~A~%phase,milliseconds~%"
        (lisp-implementation-type) (lisp-implementation-version))
(let ((mode (make-instance 'mode))
      (command (make-instance 'command-0)))
  (measure "cold" mode command nil 0)
  (measure "repeat" mode command nil 0)
  (measure "different-command" mode (make-instance 'command-1) nil 1)
  (measure "warm" mode command nil 0)
  ;; Method replacement must invalidate dispatch caches.
  (eval '(defmethod dispatch (mode (command command-0) argument)
           (declare (ignore mode command))
           (values :redefined argument)))
  (measure "redefined" mode command 3 :redefined)
  ;; More-specific mode methods must retain CALL-NEXT-METHOD semantics.
  (eval '(defmethod dispatch ((mode derived-mode) command argument)
           (multiple-value-bind (result argument) (call-next-method)
             (values (list :derived result) argument))))
  (change-class mode 'derived-mode)
  (measure "changed-mode" mode command 4 '(:derived :redefined))
  ;; EQL specializers still discriminate values of the same argument class.
  (eval '(defmethod dispatch ((mode derived-mode) (command command-0)
                             (argument (eql :special)))
           (values :eql argument)))
  (measure "eql-match" mode command :special :eql)
  (measure "eql-miss" mode command :other '(:derived :redefined))
  (remove-method #'dispatch
                 (find-method #'dispatch nil
                              (list (find-class 'derived-mode)
                                    (find-class 't) (find-class 't))))
  (measure "removed-mode-method" mode command :other :redefined))

(format t "Dispatch semantics checks passed.~%")
