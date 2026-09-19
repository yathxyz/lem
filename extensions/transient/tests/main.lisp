(defpackage :lem/transient/tests
  (:use :cl :rove :lem/transient))

(in-package :lem/transient/tests)

(deftest hiding-an-absent-transient-does-not-redraw
  (lem:with-current-buffers ()
    (lem-fake-interface:with-recording-interface ()
      (lem:redraw-display)
      ;; Isolate the popup's ownership state; count actual completed redraws.
      (let ((lem/transient::*transient-popup-window* nil)
            (lem/transient::*transient-previous-bottom-state* nil)
            (lem/transient::*transient-shown-keymap* nil)
            (lem/transient::*transient-delay-timer* nil)
            (redraws 0))
        (let ((lem:*after-redraw-display-hook* nil))
          (lem:add-hook lem:*after-redraw-display-hook* (lambda () (incf redraws)))
          (unwind-protect
               (progn
                 (lem/transient::hide-transient)
                 (ok (zerop redraws) "an already absent menu does not redraw")
                 (lem/transient::show-transient
                  (lem/transient::parse-transient
                   '((:key "a" :suffix 'lem:nop-command :description "test"))))
                 (ok (lem:mode-active-p (lem:current-buffer) 'transient-mode))
                 (setf redraws 0)
                 (lem/transient::hide-transient)
                 (ok (plusp redraws) "closing a visible menu still redraws")
                 (ng (lem:frame-bottomside-window (lem:current-frame)))
                 (ng (lem:mode-active-p (lem:current-buffer) 'transient-mode))
                 (setf redraws 0)
                 (lem/transient::hide-transient)
                 (ok (zerop redraws) "repeated hiding stays idle")
                 ;; Bind the timer manager explicitly so the pending timer is
                 ;; isolated from any manager left by another test.
                 (let ((lem/common/timer::*timer-manager*
                         (make-instance 'lem/common/timer:timer-manager))
                       (lem/transient::*transient-popup-delay* 60000))
                   (lem/transient::show-transient-with-delay
                    (lem/transient::parse-transient '((:key "b" :description "pending"))))
                   (let ((timer lem/transient::*transient-delay-timer*))
                     (ok timer)
                     (lem/transient::hide-transient)
                     (ok (loop :repeat 100
                               :when (lem:timer-expired-p timer) :return t
                               :do (sleep 0.01))
                         "the canceled timer thread exits")
                     (ng lem/transient::*transient-delay-timer*)
                     (ok (zerop redraws) "canceling an unseen menu does not redraw")))
                 ;; Even without an owned window, active mode state is visible.
                 (transient-mode t)
                 (lem/transient::hide-transient)
                 (ok (plusp redraws) "clearing active mode state still redraws"))
            (lem/transient::hide-transient)))))))

(defun segments->string (segments)
  "flatten rendered segment lines to a plain string."
  (with-output-to-string (s)
    (loop for line in segments
          for first := t then nil
          do (unless first (write-char #\newline s))
             (dolist (seg line)
               (write-string (car seg) s)))))

(deftest keymap-creation
  (testing "lem/transient::parse-transient produces keymap with correct properties"
    (let ((km (lem/transient::parse-transient
               '(:description "test"
                 :display-style :column
                 (:key "a" :suffix 'lem:nop-command :description "do a")
                 (:key "b" :suffix 'lem:nop-command :description "do b")))))
      (ok (lem/transient::keymap-show-p km))
      (ok (eq :column (lem/transient::keymap-display-style km)))
      (ok (string= "test" (lem:keymap-description km)))
      (ok (= 2 (length (lem:keymap-prefixes km)))))))

(deftest key-binding-and-idempotency
  (testing "assign-transient-key adds binding and replaces on repeat"
    (let ((km (make-instance 'lem:keymap)))
      (assign-transient-key km "z" '(:suffix 'lem:nop-command :description "first"))
      (ok (= 1 (length (lem:keymap-prefixes km))))
      (assign-transient-key km "z" '(:suffix 'lem:nop-command :description "updated"))
      (ok (= 1 (length (lem:keymap-prefixes km))) "no duplicate on re-bind")
      (ok (string= "updated" (lem:prefix-description (first (lem:keymap-prefixes km)))))))
  (testing "multi-key sequences interpreted as an intermediate prefix chain"
    (let ((km (make-instance 'lem:keymap)))
      (assign-transient-key km "e a" '(:suffix 'lem:nop-command))
      (let ((inter (first (lem:keymap-prefixes km))))
        (ok (lem:prefix-intermediate-p inter))
        (ok (typep (prefix-suffix inter) 'lem:keymap))
        (ok (= 1 (length (lem:keymap-prefixes (prefix-suffix inter)))))))))

(deftest keymap-containment
  (testing "lem/transient::keymap-contains-p works for nested and unrelated keymaps"
    (let* ((inner (lem/transient::parse-transient '((:key "x" :suffix 'lem:nop-command))))
           (outer (make-instance 'lem:keymap)))
      (lem:keymap-add-child outer inner)
      (ok (lem/transient::keymap-contains-p outer inner))
      (ng (lem/transient::keymap-contains-p inner outer)))))

(deftest infix-values
  (testing "toggle starts nil, can be flipped"
    (let ((p (parse-prefix '(:key "t" :type :toggle))))
      (ng (prefix-value p))
      (setf (prefix-value p) t)
      (ok (prefix-value p))))
  (testing "choice defaults to first option, can be changed"
    (let ((p (parse-prefix '(:key "c" :type :choice :choices '("alpha" "beta")))))
      (ok (string= "alpha" (prefix-value p)))
      (setf (prefix-value p) "beta")
      (ok (string= "beta" (prefix-value p)))))
  (testing "variable-synced infix reads and writes to symbol"
    (let ((var (gensym "TV-")))
      (set var "initial")
      (let ((p (make-instance 'lem/transient::infix)))
        (setf (lem/transient::infix-variable p) var)
        (ok (string= "initial" (prefix-value p)))
        (setf (prefix-value p) "changed")
        (ok (string= "changed" (symbol-value var)))))))

(deftest prefix-lookup-by-id
  (testing "find-prefix-by-id locates prefix by id, returns nil when missing"
    (let ((km (lem/transient::parse-transient '((:key "a" :id :my-id :suffix 'lem:nop-command)
                                                (:key "b" :suffix 'lem:nop-command)))))
      (let ((found (find-prefix-by-id km :my-id)))
        (ok found)
        (ok (eq :my-id (lem/transient::prefix-id found))))
      (ng (find-prefix-by-id km :missing)))))

(deftest grid-buffer-text
  (let* ((km (lem/transient::parse-transient
              '(:display-style :row
                (:keymap
                 :description "nav"
                 (:key "h" :description "left")
                 (:key "j" :description "down")
                 (:key "k" :description "up"))
                (:keymap
                 :description "edit"
                 (:key "d" :description "delete")
                 (:key "y" :description "yank")))))
         (layout (lem/transient::generate-layout km))
         (text (segments->string (lem/transient::render-layout-to-segments layout))))
      (ok (string= "[nav]  | [edit]  
h left | d delete
j down | y yank  
k up   |         " text))))
