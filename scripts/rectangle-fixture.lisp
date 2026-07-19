(in-package :lem-yath)

(defvar *rectangle-test-failures* 0)

(defun rectangle-test-log (format-control &rest arguments)
  (with-open-file (stream (uiop:getenv "LEM_YATH_RECTANGLE_REPORT")
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream format-control arguments)
    (terpri stream)
    (finish-output stream)))

(defun rectangle-test-check (condition name &optional detail)
  (if condition
      (rectangle-test-log "PASS ~a~@[ -- ~a~]" name detail)
      (progn
        (incf *rectangle-test-failures*)
        (rectangle-test-log "FAIL ~a~@[ -- ~a~]" name detail))))

(defun rectangle-test-buffer-text (buffer)
  (points-to-string (buffer-start-point buffer) (buffer-end-point buffer)))

(defun rectangle-test-set-text (buffer text)
  (with-current-buffer buffer
    (with-buffer-read-only buffer nil
      (delete-between-points (buffer-start-point buffer)
                             (buffer-end-point buffer))
      (insert-string (buffer-start-point buffer) text))
    (move-point (buffer-point buffer) (buffer-start-point buffer))
    (buffer-mark-saved buffer)))

(defun rectangle-test-place (point line column)
  (move-to-line point line)
  (move-to-column point column))

(defun rectangle-test-binding (keymap keys)
  (lem-core::prefix-suffix
   (lem-core::keymap-find keymap (lem-core::parse-keyspec keys))))

(defun rectangle-test-start (buffer)
  (with-current-buffer buffer
    (when (rectangle-mode-active-p buffer)
      (rectangle-end buffer))
    (rectangle-test-place (buffer-point buffer) 1 2)
    (lem-yath-rectangle-mark-mode t)
    (rectangle-test-place (buffer-point buffer) 3 5)
    (setf (rectangle-state-point-column (rectangle-state buffer)) 5)
    (rectangle-update-overlays buffer)))

(defmacro with-rectangle-test-buffer ((buffer) &body body)
  `(let ((,buffer (make-buffer "*rectangle-test*")))
     (unwind-protect
          (progn
            (rectangle-test-set-text
             ,buffer (format nil "abcdef~%xy~%123456~%"))
            (rectangle-test-start ,buffer)
            ,@body)
       (when (rectangle-mode-active-p ,buffer)
         (with-current-buffer ,buffer (rectangle-end ,buffer)))
       (delete-buffer ,buffer))))

(defun rectangle-test-operation (name command expected-text expected-line expected-column)
  (with-rectangle-test-buffer (buffer)
    (with-current-buffer buffer
      (funcall command)
      (rectangle-test-check
       (and (string= expected-text (rectangle-test-buffer-text buffer))
            (= expected-line (line-number-at-point (buffer-point buffer)))
            (= expected-column (point-column (buffer-point buffer)))
            (not (rectangle-mode-active-p buffer)))
       name
       (format nil "text=~s point=~d:~d mode=~a"
               (rectangle-test-buffer-text buffer)
               (line-number-at-point (buffer-point buffer))
               (point-column (buffer-point buffer))
               (rectangle-mode-active-p buffer))))))

(defun rectangle-test-static ()
  (setf *rectangle-test-failures* 0)
  (with-rectangle-test-buffer (buffer)
    (with-current-buffer buffer
      (lem-yath-duplicate-dwim 2)
      (let ((state (rectangle-state buffer)))
        (rectangle-test-check
         (and (string=
               (format nil "abcdecdecdef~%xy         ~%123453453456~%")
               (rectangle-test-buffer-text buffer))
              (rectangle-mode-active-p buffer)
              (= 1 (line-number-at-point (rectangle-state-anchor state)))
              (= 2 (rectangle-state-anchor-column state))
              (= 3 (line-number-at-point (buffer-point buffer)))
              (= 5 (rectangle-state-point-column state))
              (= 3 (length (rectangle-state-overlays state))))
         "duplicate-dwim-duplicates-rectangle-right"
         (format nil "text=~s" (rectangle-test-buffer-text buffer))))))
  (with-rectangle-test-buffer (buffer)
    (with-current-buffer buffer
      (lem-yath-rectangle-previous-line)
      (lem-yath-rectangle-forward-char 2)
      (let ((short-line-column (point-column (buffer-point buffer)))
            (state-column
              (rectangle-state-point-column (rectangle-state buffer))))
        (lem-yath-rectangle-next-line)
        (rectangle-test-check
         (and (= 2 short-line-column)
              (= 7 state-column)
              (= 3 (line-number-at-point (buffer-point buffer)))
              (= 6 (point-column (buffer-point buffer)))
              (= 7 (rectangle-state-point-column (rectangle-state buffer))))
         "rectangle-movement-retains-virtual-column"))))
  (with-rectangle-test-buffer (buffer)
    (with-current-buffer buffer
      (lem-yath-rectangle-exchange-point-and-mark)
      (let ((state (rectangle-state buffer)))
        (rectangle-test-check
         (and (= 3 (line-number-at-point (rectangle-state-anchor state)))
              (= 5 (rectangle-state-anchor-column state))
              (= 1 (line-number-at-point (buffer-point buffer)))
              (= 2 (rectangle-state-point-column state)))
         "rectangle-exchange-rotates-to-opposite-corners"))))
  (rectangle-test-operation
   "delete-rectangle"
   #'lem-yath-delete-rectangle
   (format nil "abf~%xy~%126~%") 3 2)
  (rectangle-test-operation
   "clear-rectangle"
   #'lem-yath-clear-rectangle
   (format nil "ab   f~%xy~%12   6~%") 3 2)
  (rectangle-test-operation
   "open-rectangle"
   #'lem-yath-open-rectangle
   (format nil "ab   cdef~%xy~%12   3456~%") 1 2)
  (with-rectangle-test-buffer (buffer)
    (with-current-buffer buffer
      (lem-yath-open-rectangle t)
      (rectangle-test-check
       (string= (format nil "ab   cdef~%xy   ~%12   3456~%")
                (rectangle-test-buffer-text buffer))
       "open-rectangle-prefix-fills-short-lines")))
  (with-rectangle-test-buffer (buffer)
    (with-current-buffer buffer
      (rectangle-transform-lines
       (rectangle-state buffer) (rectangle-string-transform "Z"))
      (rectangle-test-check
       (string= (format nil "abZf~%xyZ~%12Z6~%")
                (rectangle-test-buffer-text buffer))
       "string-rectangle-transform")))
  (with-rectangle-test-buffer (buffer)
    (with-current-buffer buffer
      (lem-yath-rectangle-number-lines)
      (rectangle-test-check
       (and (string= (format nil "ab1 cdef~%xy2 ~%123 3456~%")
                     (rectangle-test-buffer-text buffer))
            (= 3 (line-number-at-point (buffer-point buffer)))
            (= 7 (point-column (buffer-point buffer))))
       "rectangle-number-lines-default"
       (format nil "text=~s" (rectangle-test-buffer-text buffer)))))
  (with-rectangle-test-buffer (buffer)
    (with-current-buffer buffer
      (setf *killed-rectangle* nil)
      (lem-yath-kill-rectangle)
      (rectangle-test-check
       (and (equal '("cde" "   " "345") *killed-rectangle*)
            (string= (format nil "abf~%xy~%126~%")
                     (rectangle-test-buffer-text buffer)))
       "kill-rectangle-retains-padded-rows")))
  (with-rectangle-test-buffer (buffer)
    (with-current-buffer buffer
      (setf *killed-rectangle* nil)
      (lem-yath-copy-rectangle-as-kill)
      (rectangle-test-check
       (and (equal '("cde" "   " "345") *killed-rectangle*)
            (string= (format nil "abcdef~%xy~%123456~%")
                     (rectangle-test-buffer-text buffer))
            (not (rectangle-mode-active-p buffer)))
       "copy-rectangle-retains-buffer-and-padded-rows")))
  (let ((buffer (make-buffer "*rectangle-yank-test*")))
    (unwind-protect
         (with-current-buffer buffer
           (rectangle-test-set-text buffer (format nil "one~%two~%"))
           (rectangle-test-place (buffer-point buffer) 1 1)
           (setf *killed-rectangle* '("AA" "BB" "CC"))
           (lem-yath-yank-rectangle)
           (rectangle-test-check
            (and (string= (format nil "oAAne~%tBBwo~% CC")
                          (rectangle-test-buffer-text buffer))
                 (= 3 (line-number-at-point (buffer-point buffer)))
                 (= 3 (point-column (buffer-point buffer))))
            "yank-rectangle-extends-buffer"
            (format nil "text=~s" (rectangle-test-buffer-text buffer))))
      (delete-buffer buffer)))
  (multiple-value-bind (prefix middle suffix width)
      (rectangle-line-parts (format nil "a~cb" #\Tab) 2 6 8)
    (rectangle-test-check
     (and (string= "a " prefix)
          (string= "    " middle)
          (string= "  b" suffix)
          (= width 9))
     "tab-boundaries-coerce-only-crossing-cells"
     (format nil "prefix=~s middle=~s suffix=~s width=~d"
             prefix middle suffix width)))
  (rectangle-test-check
   (and (string= "7" (rectangle-number-format "%d" 7))
        (string= "  7" (rectangle-number-format "%3d" 7))
        (string= "007" (rectangle-number-format "%03d" 7))
        (string= "-07" (rectangle-number-format "%03d" -7))
        (string= "% 7" (rectangle-number-format "%% %d" 7)))
   "safe-emacs-number-formats")
  (rectangle-test-check
   (and
    (every
     (lambda (entry)
       (destructuring-bind (keys command) entry
         (eq command (rectangle-test-binding *global-keymap* keys))))
     '(("C-x Space" lem-yath-rectangle-mark-mode)
       ("C-x r c" lem-yath-clear-rectangle)
       ("C-x r k" lem-yath-kill-rectangle)
       ("C-x r d" lem-yath-delete-rectangle)
       ("C-x r y" lem-yath-yank-rectangle)
       ("C-x r o" lem-yath-open-rectangle)
       ("C-x r t" lem-yath-string-rectangle)
       ("C-x r N" lem-yath-rectangle-number-lines)
       ("C-x r M-w" lem-yath-copy-rectangle-as-kill)))
    (every
     (lambda (entry)
       (destructuring-bind (keys command) entry
         (eq command (rectangle-test-binding *rectangle-mode-keymap* keys))))
     '(("C-g" lem-yath-rectangle-cancel)
       ("C-n" lem-yath-rectangle-next-line)
       ("C-p" lem-yath-rectangle-previous-line)
       ("Left" lem-yath-rectangle-backward-char)
       ("Right" lem-yath-rectangle-forward-char)
       ("C-x C-x" lem-yath-rectangle-exchange-point-and-mark))))
   "rectangle-stock-bindings")
  (rectangle-test-log "SUMMARY ~:[PASS~;FAIL~] failures=~d"
                      (plusp *rectangle-test-failures*)
                      *rectangle-test-failures*))

(define-command rectangle-test-physical-setup () ()
  (let ((buffer (current-buffer)))
    (when (rectangle-mode-active-p buffer)
      (rectangle-end buffer))
    (rectangle-test-set-text
     buffer (format nil "abcdef~%xy~%123456~%"))
    (rectangle-test-place (buffer-point buffer) 1 2)
    (when (typep (current-global-mode) 'lem-vi-mode:vi-mode)
      (setf (lem-vi-mode/core:buffer-state buffer) 'lem-vi-mode/states:normal))))

(define-command rectangle-test-report-duplicate () ()
  (let* ((buffer (current-buffer))
         (state (rectangle-state buffer)))
    (rectangle-test-log
     "PHYSICAL-DUPLICATE text=~:[no~;yes~] mode=~:[no~;yes~] anchor=~a point=~a overlays=~d"
     (string= (format nil "abcdecdecdef~%xy         ~%123453453456~%")
              (rectangle-test-buffer-text buffer))
     (rectangle-mode-active-p buffer)
     (and state
          (format nil "~d:~d"
                  (line-number-at-point (rectangle-state-anchor state))
                  (rectangle-state-anchor-column state)))
     (and state
          (format nil "~d:~d"
                  (line-number-at-point (buffer-point buffer))
                  (rectangle-state-point-column state)))
     (length (and state (rectangle-state-overlays state))))))

(define-command rectangle-test-report-undo () ()
  (rectangle-test-log
   "PHYSICAL-UNDO text=~:[no~;yes~] mode=~:[no~;yes~]"
   (string= (format nil "abcdef~%xy~%123456~%")
            (rectangle-test-buffer-text (current-buffer)))
   (rectangle-mode-active-p (current-buffer))))

(define-command rectangle-test-report-kill () ()
  (rectangle-test-log
   "PHYSICAL-KILL text=~:[no~;yes~] mode=~:[no~;yes~] killed=~:[no~;yes~]"
   (string= (format nil "abf~%xy~%126~%")
            (rectangle-test-buffer-text (current-buffer)))
   (rectangle-mode-active-p (current-buffer))
   (equal '("cde" "   " "345") *killed-rectangle*)))

(define-command rectangle-test-report-string () ()
  (rectangle-test-log
   "PHYSICAL-STRING text=~:[no~;yes~] mode=~:[no~;yes~] point=~d:~d"
   (string= (format nil "abZf~%xyZ~%12Z6~%")
            (rectangle-test-buffer-text (current-buffer)))
   (rectangle-mode-active-p (current-buffer))
   (line-number-at-point (buffer-point (current-buffer)))
   (point-column (buffer-point (current-buffer)))))

(define-command rectangle-test-report-string-cancel () ()
  (rectangle-test-log
   "PHYSICAL-STRING-CANCEL text=~:[no~;yes~] mode=~:[no~;yes~] point=~d:~d"
   (string= (format nil "abcdef~%xy~%123456~%")
            (rectangle-test-buffer-text (current-buffer)))
   (rectangle-mode-active-p (current-buffer))
   (line-number-at-point (buffer-point (current-buffer)))
   (rectangle-state-point-column (rectangle-state (current-buffer)))))

(define-key *global-keymap* "F9" 'rectangle-test-physical-setup)
(define-key *global-keymap* "F8" 'rectangle-test-report-duplicate)
(define-key *global-keymap* "F7" 'rectangle-test-report-undo)
(define-key *global-keymap* "F6" 'rectangle-test-report-kill)
(define-key *global-keymap* "F5" 'rectangle-test-report-string)
(define-key *global-keymap* "F4" 'rectangle-test-report-string-cancel)

(rectangle-test-static)
