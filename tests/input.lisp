(defpackage :lem-tests/input
  (:use :cl :rove :lem))
(in-package :lem-tests/input)

;; Script the clock across an exact deadline without changing the real timer
;; scheduler/event queue. Internal access isolates those subsystems.
(defclass input-test-timer-manager (lem/common/timer:timer-manager)
  ((times :initarg :times :accessor input-test-times)))

(defmethod lem/common/timer::get-microsecond-time ((manager input-test-timer-manager))
  (unless (input-test-times manager)
    (error "Input test consumed its scripted timer clock"))
  (pop (input-test-times manager)))

(defun set-input-test-function (symbol function)
  #+sbcl (sb-ext:with-unlocked-packages (:lem-core)
           (setf (symbol-function symbol) function))
  #-sbcl (setf (symbol-function symbol) function))

(deftest idle-polls-redraw-only-after-callbacks
  (dolist (repeat '(nil t))
    (let* ((lem/common/timer::*timer-manager*
             (make-instance 'input-test-timer-manager :times (list 0 10 10 10 11 11 11)))
           (lem/common/timer::*idle-timer-list* nil)
           (lem/common/timer::*processed-idle-timer-list* nil)
           (lem-core::*editor-event-queue* (lem/common/queue:make-concurrent-queue))
           (lem-core::*routed-input-session* nil)
           (lem-core::*deferred-routed-input-events* nil)
           (key (make-key :sym "x"))
           (callbacks 0)
           (redraws nil)
           (original-redraw (symbol-function 'redraw-display))
           (timer (lem/common/timer:make-idle-timer
                   (lambda () (incf callbacks) (send-event key) nil) :name "input redraw test")))
      (unwind-protect
           (progn
             ;; Count the real input loop's redraw requests without a frontend.
             (set-input-test-function 'redraw-display
              (lambda (&key force)
                (declare (ignore force))
                (push callbacks redraws)))
             (lem/common/timer:start-timer timer 10 :repeat repeat)
             (ok (eq key (lem-core::read-event-internal)))
             (ok (= 1 callbacks))
             (ok (equal '(1) redraws)
                 "the empty deadline poll does not redraw; the NIL-returning callback does")
             (ok (eql (not repeat) (lem/common/timer:timer-expired-p timer))))
        (set-input-test-function 'redraw-display original-redraw)))))

(deftest input-waits-through-idle-deadline
  ;; Before expiry, queued input takes precedence and no timer polling occurs.
  ;; Once overdue, callbacks still run before the queued key, as before.
  (dolist (case '((9 0.002 0) (10 0.001 0) (11 nil 1)))
    (destructuring-bind (now timeout expected-callbacks) case
      (let* ((lem/common/timer::*timer-manager*
               (make-instance 'input-test-timer-manager :times (list 0 now now now)))
             (lem/common/timer::*idle-timer-list* nil)
             (lem/common/timer::*processed-idle-timer-list* nil)
             (lem-core::*editor-event-queue* (lem/common/queue:make-concurrent-queue))
             (lem-core::*routed-input-session* nil)
             (lem-core::*deferred-routed-input-events* nil)
             (key (make-key :sym "x"))
             (callbacks 0)
             (redraws 0)
             (timeouts nil)
             (original-receive (symbol-function 'lem-core::receive-event))
             (original-redraw (symbol-function 'redraw-display))
             (timer (lem/common/timer:make-idle-timer
                     (lambda () (incf callbacks) nil) :name "input deadline test")))
        (unwind-protect
             (progn
               (set-input-test-function
                'lem-core::receive-event
                (lambda (timeout)
                  (push timeout timeouts)
                  (funcall original-receive timeout)))
               (set-input-test-function
                'redraw-display
                (lambda (&key force) (declare (ignore force)) (incf redraws)))
               (lem/common/timer:start-timer timer 10)
               (send-event key)
               (ok (eq key (lem-core::read-event-internal)))
               (ok (equal (list timeout) timeouts)
                   "the wait includes the strict expiry tick and wakes for queued input")
               (ok (= expected-callbacks callbacks redraws))
               (ok (eql (plusp expected-callbacks)
                        (lem/common/timer:timer-expired-p timer))))
          (set-input-test-function 'lem-core::receive-event original-receive)
          (set-input-test-function 'redraw-display original-redraw))))))

(deftest keys-equal-p-test
  (ok (lem-core::keys-equal-p (make-key :sym "x") (make-key :sym "x")))
  (ok (lem-core::keys-equal-p (make-key :ctrl t :sym "c") (make-key :ctrl t :sym "c")))
  (ng (lem-core::keys-equal-p (make-key :sym "x") (make-key :sym "y")))
  (ng (lem-core::keys-equal-p (make-key :ctrl t :sym "c") (make-key :sym "c"))))

(deftest meta-prefix-key-p-with-t-test
  (ok (lem-core::meta-prefix-key-p (make-key :sym "Escape") t))
  (ng (lem-core::meta-prefix-key-p (make-key :sym "x") t))
  (ng (lem-core::meta-prefix-key-p (make-key :meta t :sym "Escape") t)))

(deftest meta-prefix-key-p-with-single-key-test
  ;; Note: C-[ is converted to Escape by Lem's key conversion, so we use C-; instead
  (let ((prefix-key (make-key :ctrl t :sym ";")))
    (ok (lem-core::meta-prefix-key-p (make-key :ctrl t :sym ";") prefix-key))
    (ng (lem-core::meta-prefix-key-p (make-key :sym "Escape") prefix-key))
    (ng (lem-core::meta-prefix-key-p (make-key :sym "x") prefix-key))))

(deftest meta-prefix-key-p-with-key-list-test
  (let ((prefix-keys (list (make-key :sym "Escape")
                           (make-key :ctrl t :sym ";"))))
    (ok (lem-core::meta-prefix-key-p (make-key :sym "Escape") prefix-keys))
    (ok (lem-core::meta-prefix-key-p (make-key :ctrl t :sym ";") prefix-keys))
    (ng (lem-core::meta-prefix-key-p (make-key :sym "x") prefix-keys))))

(deftest add-meta-modifier-test
  (let ((key (lem-core::add-meta-modifier (make-key :sym "x"))))
    (ok (key-meta key))
    (ok (equal "x" (key-sym key))))
  (let ((key (lem-core::add-meta-modifier (make-key :ctrl t :sym "c"))))
    (ok (key-meta key))
    (ok (key-ctrl key))
    (ok (equal "c" (key-sym key)))))

(deftest meta-prefix-disabled-test
  (lem/common/var:with-global-variable-value (meta-prefix-keys nil)
    (let ((escape-key (make-key :sym "Escape"))
          (x-key (make-key :sym "x")))
      (let ((result (lem-core::maybe-convert-to-meta
                     escape-key
                     (lambda () x-key))))
        (ok (match-key result :sym "Escape"))))))

(deftest meta-prefix-with-t-test
  (lem/common/var:with-global-variable-value (meta-prefix-keys t)
    (let ((escape-key (make-key :sym "Escape"))
          (x-key (make-key :sym "x")))
      (let ((result (lem-core::maybe-convert-to-meta
                     escape-key
                     (lambda () x-key))))
        (ok (key-meta result))
        (ok (equal "x" (key-sym result)))))))

(deftest meta-prefix-double-press-test
  (lem/common/var:with-global-variable-value (meta-prefix-keys t)
    (let ((escape-key (make-key :sym "Escape")))
      (let ((result (lem-core::maybe-convert-to-meta
                     escape-key
                     (lambda () escape-key))))
        (ok (match-key result :sym "Escape"))
        (ng (key-meta result))))))

(deftest meta-prefix-preserves-modifiers-test
  (lem/common/var:with-global-variable-value (meta-prefix-keys t)
    (let ((escape-key (make-key :sym "Escape"))
          (ctrl-c-key (make-key :ctrl t :sym "c")))
      (let ((result (lem-core::maybe-convert-to-meta
                     escape-key
                     (lambda () ctrl-c-key))))
        (ok (key-meta result))
        (ok (key-ctrl result))
        (ok (equal "c" (key-sym result)))))))

(deftest non-prefix-key-passes-through-test
  (lem/common/var:with-global-variable-value (meta-prefix-keys t)
    (let ((x-key (make-key :sym "x")))
      (let ((result (lem-core::maybe-convert-to-meta
                     x-key
                     (lambda () (error "Should not be called")))))
        (ok (match-key result :sym "x"))))))

(deftest custom-prefix-key-test
  ;; Note: C-[ is converted to Escape by Lem's key conversion, so we use C-; instead
  (let ((custom-key (make-key :ctrl t :sym ";")))
    (lem/common/var:with-global-variable-value (meta-prefix-keys custom-key)
      (let ((x-key (make-key :sym "x")))
        ;; C-; + x -> M-x
        (let ((result (lem-core::maybe-convert-to-meta
                       custom-key
                       (lambda () x-key))))
          (ok (key-meta result))
          (ok (equal "x" (key-sym result))))
        ;; Escape should not trigger with custom key
        (let ((escape-key (make-key :sym "Escape")))
          (let ((result (lem-core::maybe-convert-to-meta
                         escape-key
                         (lambda () (error "Should not be called")))))
            (ok (match-key result :sym "Escape"))))))))

(deftest multiple-prefix-keys-test
  ;; Note: C-[ is converted to Escape by Lem's key conversion, so we use C-; instead
  (let ((prefix-keys (list (make-key :sym "Escape")
                           (make-key :ctrl t :sym ";"))))
    (lem/common/var:with-global-variable-value (meta-prefix-keys prefix-keys)
      (let ((x-key (make-key :sym "x")))
        ;; Escape + x -> M-x
        (let ((result (lem-core::maybe-convert-to-meta
                       (make-key :sym "Escape")
                       (lambda () x-key))))
          (ok (key-meta result))
          (ok (equal "x" (key-sym result))))
        ;; C-; + x -> M-x
        (let ((result (lem-core::maybe-convert-to-meta
                       (make-key :ctrl t :sym ";")
                       (lambda () x-key))))
          (ok (key-meta result))
          (ok (equal "x" (key-sym result))))))))
