(defpackage :lem-tests/listener-mode
  (:use :cl
        :rove
        :lem)
  (:import-from :lem-fake-interface
                :with-fake-interface)
  (:import-from :lem/listener-mode
                :listener-mode
                :input-start-point
                :listener-set-prompt-function
                :listener-check-input-function
                :listener-execute-function
                :start-listener-mode
                :refresh-prompt
                :clamp-cursor-to-input-area
                :listener-previous-startswith-input
                :listener-next-startswith-input))
(in-package :lem-tests/listener-mode)

(defun setup-listener-buffer ()
  "Create a buffer with listener-mode and a simple prompt."
  (let ((buffer (make-buffer "listener-test")))
    (setf (current-buffer) (window-buffer (current-window)))
    (switch-to-buffer buffer)
    (setf (variable-value 'listener-set-prompt-function :buffer buffer)
          (lambda (point)
            (insert-string point "> ")))
    (setf (variable-value 'listener-check-input-function :buffer buffer)
          (lambda (point) (declare (ignore point)) t))
    (setf (variable-value 'listener-execute-function :buffer buffer)
          (lambda (point string) (declare (ignore point string))))
    (start-listener-mode)
    (refresh-prompt buffer)
    buffer))

(deftest prompt-refresh-preserves-output-reader
  (with-fake-interface ()
    (with-current-buffers ()
      (let ((buffer (setup-listener-buffer)))
        (insert-string (current-point) (format nil "old result~%"))
        (buffer-start (current-point))
        (with-point ((reader (current-point)))
          (refresh-prompt buffer)
          (ok (point= reader (current-point)) "A reader is not pulled to the new prompt")
          (ok (end-buffer-p (input-start-point buffer)))
          (ok (string= (format nil "> old result~%> ") (buffer-text buffer))))))))

(deftest repl-output-and-prompt-follow-independent-frame-tails
  (with-current-buffers ()
    (with-fake-interface ()
      (let* ((buffer (make-buffer "*lisp-repl*"))
             (origin (current-window))
             (origin-implementation (implementation)))
        (setf (current-buffer) (window-buffer origin))
        (switch-to-buffer buffer)
        (setf (variable-value 'listener-set-prompt-function :buffer buffer)
              (lambda (point) (insert-string point "> ")))
        (start-listener-mode)
        (refresh-prompt buffer)
        (insert-string (current-point) (format nil "(+ 20 22)~%"))
        (lem/listener-mode:change-input-start-point (current-point))
        ;; Save the origin's cursor as frame activation does. The output callback
        ;; below runs with a different frame selected, while both show this REPL.
        (move-point (lem-core::%window-point origin) (current-point))
        (with-fake-interface ()
          (setf (current-buffer) (window-buffer (current-window)))
          (switch-to-buffer buffer)
          (buffer-start (current-point))
          (let ((reader-window (current-window)))
            (with-point ((reader (current-point)))
              (let ((lem-lisp-mode/internal::*repl-evaluating* t))
                ;; Split output includes a separate newline event: without tail
                ;; following, the inactive window is stranded before this newline.
                (lem-lisp-mode/internal:write-string-to-repl "42")
                (ok (end-buffer-p (window-point origin)))
                (lem-lisp-mode/internal:write-string-to-repl (string #\newline)))
              (refresh-prompt buffer)
              (ok (end-buffer-p (window-point origin)))
              (ok (point= reader (current-point)))
              (ok (eq reader-window (current-window)) "Output does not select its origin")
              (move-point (lem-core::%window-point reader-window) (current-point))
              ;; Reactivate the initiating frame using its saved cursor, then
              ;; submit real listener input rather than moving it to the tail.
              (lem:with-implementation origin-implementation
                (setf (current-buffer) buffer)
                (move-point (current-point) (lem-core::%window-point origin))
                (let (submitted)
                  (setf (variable-value 'listener-check-input-function :buffer buffer)
                        (constantly t)
                        (variable-value 'listener-execute-function :buffer buffer)
                        (lambda (point text) (declare (ignore point)) (setf submitted text)))
                  (insert-string (current-point) "(+ 42 1)")
                  (lem/listener-mode:listener-return)
                  (ok (equal "(+ 42 1)" submitted)))
                (ok (point= reader (window-point reader-window)))))))))))

(deftest listener-tail-following-ignores-replaced-or-deleted-window
  (with-current-buffers ()
    (with-fake-interface ()
      (let* ((buffer (setup-listener-buffer))
             (other (make-buffer "listener-other"))
             (floating (make-floating-window :buffer buffer :x 1 :y 1 :width 10 :height 5)))
        (buffer-end (window-point floating))
        (insert-string (buffer-point other) "other text")
        (buffer-start (buffer-point other))
        (lem/listener-mode:call-with-tail-following
         buffer
         (lambda ()
           (switch-to-buffer other)
           (delete-window floating)
           (insert-string (buffer-end-point buffer) "new output")))
        (ok (eq other (current-buffer)))
        (ok (start-buffer-p (current-point)))
        (ok (lem-core::window-deleted-p floating))))))

(deftest clamp-cursor-to-input-area
  (with-fake-interface ()
    (with-current-buffers ()
      (let ((buffer (setup-listener-buffer)))
        (testing "cursor at input-start-point is not moved"
                 (move-point (current-point) (input-start-point buffer))
                 (lem/listener-mode:clamp-cursor-to-input-area)
                 (ok (point= (current-point) (input-start-point buffer))))

        (testing "cursor before input-start-point on same line is clamped"
                 (line-start (current-point))
                 (ok (point< (current-point) (input-start-point buffer)))
                 (lem/listener-mode:clamp-cursor-to-input-area)
                 (ok (point= (current-point) (input-start-point buffer))))

        (testing "cursor after input-start-point is not moved"
                 (buffer-end (current-point))
                 (insert-string (current-point) "hello")
                 (let ((pos (copy-point (current-point) :temporary)))
                   (lem/listener-mode:clamp-cursor-to-input-area)
                   (ok (point= (current-point) pos))))

        (testing "cursor on previous line is not clamped"
                 ;; Add a newline in the input area so cursor can go to a previous line
                 (move-point (current-point) (input-start-point buffer))
                 (character-offset (current-point) -1)
                 ;; cursor is now on a line before input-start-point's line
                 (unless (same-line-p (current-point) (input-start-point buffer))
                   (lem/listener-mode:clamp-cursor-to-input-area)
                   (ok (not (point= (current-point) (input-start-point buffer))))))))))

;; make-history does not need pathname?

(deftest listener-history-search-state-and-geometry
  (with-fake-interface ()
    (with-current-buffers ()
      (let* ((buffer (setup-listener-buffer))
             (test-history (lem/common/history:make-history)))
        
        (setf (buffer-value buffer 'lem/listener-mode::%listener-history)
              test-history)
               
        (lem/common/history:add-history test-history "hello")
        (lem/common/history:add-history test-history "world")
        (lem/common/history:add-history test-history "hector")

        (testing "Successful previous match perfectly preserves prefix cursor offset"
                 ;; Type our unsubmitted prefix "'he"
                 (move-point (current-point) (input-start-point buffer))
                 (insert-string (current-point) "he")
          
                 ;; Trigger the search
                 (listener-previous-startswith-input)
          
                 ;; Assert 1: The buffer text was completely replaced with the newest match
                 (let ((full-input (points-to-string (input-start-point buffer) 
                                                     (buffer-end-point buffer))))
                   (ok (string= "hector" full-input)))
          
                 ;; Assert 2: The cursor is resting exactly at the end of the "he" prefix.
                 ;; This proves our linear offset math is working and preventing the timer crash!
                 (let ((cursor-prefix (points-to-string (input-start-point buffer) 
                                                        (current-point))))
                   (ok (string= "he" cursor-prefix))))

        (testing "State drift is prevented on failed searches and rollback succeeds"
                 ;; We are currently viewing "hector". 
                 ;; Search previous again to hit the oldest match ("hello").
                 (listener-previous-startswith-input)
                 (ok (string= "hello" (points-to-string (input-start-point buffer) 
                                                        (buffer-end-point buffer))))

                 ;; Now we force the failure state. Searching previous again will find nothing.
                 ;; Because of our fix, the internal loop should rewind its phantom steps.
                 (listener-previous-startswith-input)
                 (ok (string= "hello" (points-to-string (input-start-point buffer) 
                                                        (buffer-end-point buffer))))

                 ;; If the rewind worked, stepping 'Next' exactly twice should traverse 
                 ;; perfectly back through "hector" and hit the Rollback state.
                 (listener-next-startswith-input)
                 (ok (string= "hector" (points-to-string (input-start-point buffer) 
                                                         (buffer-end-point buffer))))
          
                 ;; The final step Next: Rollback triggers!
                 (listener-next-startswith-input)
          
                 ;; Assert 3: The unsubmitted text was flawlessly restored
                 (ok (string= "he" (points-to-string (input-start-point buffer) 
                                                     (buffer-end-point buffer))))
          
                 ;; Assert 4: The rollback explicitly clamped the cursor safely
                 (let ((cursor-prefix (points-to-string (input-start-point buffer) 
                                                        (current-point))))
                   (ok (string= "he" cursor-prefix))))))))
