(in-package :lem-yath)

(defvar *snipe-test-report*
  (uiop:getenv "LEM_YATH_SNIPE_REPORT"))

(defvar *snipe-test-source*
  (uiop:getenv "LEM_YATH_SNIPE_SOURCE"))

(defvar *snipe-test-armed-before-record* nil)

(defun snipe-test-snapshot-before-record (key)
  ;; Capture before key lookup and the production pre-command hook consumes the
  ;; one-command transient.  F12 remains an ordinary, unrelated editor key.
  (when (match-key key :sym "F12")
    (setf *snipe-test-armed-before-record*
          *snipe-immediate-repeat-family*)))

(remove-hook *input-hook* 'snipe-test-snapshot-before-record)
(add-hook *input-hook* 'snipe-test-snapshot-before-record 1000)

(defun snipe-test-log (control &rest arguments)
  (with-open-file (stream *snipe-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun snipe-test-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across (or string "")
          :do (case character
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (#\\ (write-string "\\\\" stream))
                (otherwise (write-char character stream))))))

(defun snipe-test-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun snipe-test-state-text ()
  (let ((text (snipe-test-buffer-text)))
    (if (> (length text) 512)
        (concatenate 'string (subseq text 0 512) "<truncated>")
        text)))

(defun snipe-test-key-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap
                (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun snipe-test-hook-function (entry)
  (if (consp entry) (car entry) entry))

(defun snipe-test-hook-count (hook callback)
  (count callback hook :key #'snipe-test-hook-function :test #'eq))

(defun snipe-test-check-bindings ()
  (every
   #'identity
   (list
    (eq 'lem-yath-snipe-forward
        (snipe-test-key-command lem-vi-mode:*normal-keymap* "s"))
    (eq 'lem-yath-snipe-backward
        (snipe-test-key-command lem-vi-mode:*normal-keymap* "S"))
    (eq 'lem-yath-snipe-find-forward
        (snipe-test-key-command lem-vi-mode:*motion-keymap* "f"))
    (eq 'lem-yath-snipe-find-backward
        (snipe-test-key-command lem-vi-mode:*motion-keymap* "F"))
    (eq 'lem-yath-snipe-till-forward
        (snipe-test-key-command lem-vi-mode:*motion-keymap* "t"))
    (eq 'lem-yath-snipe-till-backward
        (snipe-test-key-command lem-vi-mode:*motion-keymap* "T"))
    (eq 'lem-yath-snipe-repeat
        (snipe-test-key-command lem-vi-mode:*motion-keymap* ";"))
    (eq 'lem-yath-snipe-repeat-backward
        (snipe-test-key-command lem-vi-mode:*motion-keymap* ","))
    (eq 'lem-yath-snipe-operator-forward
        (snipe-test-key-command lem-vi-mode:*operator-keymap* "z"))
    (eq 'lem-yath-snipe-operator-backward
        (snipe-test-key-command lem-vi-mode:*operator-keymap* "Z"))
    (eq 'lem-yath-snipe-operator-forward-exclusive
        (snipe-test-key-command lem-vi-mode:*operator-keymap* "x"))
    (eq 'lem-yath-snipe-operator-backward-exclusive
        (snipe-test-key-command lem-vi-mode:*operator-keymap* "X"))
    (eq 'lem-yath-snipe-repeat
        (snipe-test-key-command *snipe-s-transient-keymap* "s"))
    (eq 'lem-yath-snipe-repeat-backward
        (snipe-test-key-command *snipe-s-transient-keymap* "S"))
    (eq 'lem-yath-snipe-repeat
        (snipe-test-key-command *snipe-f-transient-keymap* "f"))
    (eq 'lem-yath-snipe-repeat-backward
        (snipe-test-key-command *snipe-f-transient-keymap* "F"))
    (eq 'lem-yath-snipe-repeat
        (snipe-test-key-command *snipe-t-transient-keymap* "t"))
    (eq 'lem-yath-snipe-repeat-backward
        (snipe-test-key-command *snipe-t-transient-keymap* "T"))
    (eq 'lem-yath-snipe-repeat
        (snipe-test-key-command *snipe-x-transient-keymap* "x"))
    (eq 'lem-yath-snipe-repeat-backward
        (snipe-test-key-command *snipe-x-transient-keymap* "X")))))

(defun snipe-test-check-motion-types ()
  (every
   #'identity
   (loop :for (name expected)
           :in '((lem-yath-snipe-forward :inclusive)
                 (lem-yath-snipe-backward :inclusive)
                 (lem-yath-snipe-find-forward :inclusive)
                 (lem-yath-snipe-find-backward :inclusive)
                 (lem-yath-snipe-till-forward :exclusive)
                 (lem-yath-snipe-till-backward :exclusive)
                 (lem-yath-snipe-operator-forward :inclusive)
                 (lem-yath-snipe-operator-backward :inclusive)
                 (lem-yath-snipe-operator-forward-exclusive :exclusive)
                 (lem-yath-snipe-operator-backward-exclusive :exclusive))
         :for command := (get-command name)
         :collect (and (typep command 'lem-vi-mode/core:vi-motion)
                       (eq expected
                           (lem-vi-mode/core:vi-motion-type command))))))

(defun snipe-test-lifecycle-ok-p ()
  (and (= 1 (snipe-test-hook-count *pre-command-hook*
                                    'snipe-pre-command-cleanup))
       (zerop (snipe-test-hook-count *post-command-hook*
                                    'snipe-post-command-cleanup))
       (zerop (snipe-test-hook-count *post-command-hook*
                                      'clear-stale-snipe-repeat))))

(define-command lem-yath-test-snipe-static () ()
  (let* ((bindings (snipe-test-check-bindings))
         (types (snipe-test-check-motion-types))
         (lifecycle (snipe-test-lifecycle-ok-p))
         (attributes
           (and (ensure-attribute 'lem-yath-snipe-match-attribute nil)
                (ensure-attribute 'lem-yath-snipe-first-match-attribute nil)))
         (failures (count nil (list bindings types lifecycle attributes))))
    (snipe-test-log
     "STATIC bindings=~a types=~a lifecycle=~a attributes=~a failures=~d"
     (if bindings "yes" "no")
     (if types "yes" "no")
     (if lifecycle "yes" "no")
     (if attributes "yes" "no")
     failures)))

(define-command lem-yath-test-snipe-record () ()
  (let ((search *last-snipe-search*))
    (snipe-test-log
     (concatenate
      'string
      "STATE point=~d line=~d column=~d char=~a text=~a "
      "target=~a direction=~a inclusive=~a count=~a family=~a armed=~a vi=~a overlays=~d")
     (position-at-point (current-point))
     (line-number-at-point (current-point))
     (point-charpos (current-point))
     (or (character-at (current-point)) "none")
     (snipe-test-encode (snipe-test-state-text))
     (if search (snipe-test-encode (getf search :target)) "none")
     (if search (getf search :direction) "none")
     (if search (if (getf search :inclusive) "yes" "no") "none")
     (if search (getf search :count) "none")
     (if search (getf search :family) "none")
     (or *snipe-test-armed-before-record* "none")
     (type-of (lem-vi-mode/core:current-state))
     (length *snipe-overlays*))))

(define-command lem-yath-test-snipe-enable-wrap () ()
  (setf (variable-value 'line-wrap :buffer (current-buffer)) t)
  (move-point (current-point) (buffer-start-point (current-buffer)))
  (move-point (window-view-point (current-window))
              (buffer-start-point (current-buffer)))
  (redraw-display)
  (snipe-test-log "WRAP enabled=yes line=~d column=~d"
                   (line-number-at-point (current-point))
                   (point-charpos (current-point))))

(define-command lem-yath-test-snipe-reload () ()
  (handler-case
      (with-point ((start (current-point))
                   (end (current-point)))
        (or (character-offset end 1) (character-offset start -1))
        (let ((probe (make-overlay start end
                                   'lem-yath-snipe-match-attribute)))
          (setf *snipe-overlays* (list probe))
          (load (pathname *snipe-test-source*))
          (snipe-test-log
           (concatenate
            'string
            "RELOAD bindings=~a lifecycle=~a pre=~d post=~d old=~d "
            "overlays=~d deleted=~a")
           (if (snipe-test-check-bindings) "yes" "no")
           (if (snipe-test-lifecycle-ok-p) "yes" "no")
           (snipe-test-hook-count *pre-command-hook*
                                   'snipe-pre-command-cleanup)
           (snipe-test-hook-count *post-command-hook*
                                   'snipe-post-command-cleanup)
           (snipe-test-hook-count *post-command-hook*
                                   'clear-stale-snipe-repeat)
           (length *snipe-overlays*)
           (if (lem-core::overlay-alive-p probe) "no" "yes"))))
    (error (condition)
      (snipe-test-log "RELOAD ERROR ~a" condition))))

(define-key *global-keymap* "F8" 'lem-yath-test-snipe-enable-wrap)
(define-key *global-keymap* "F10" 'lem-yath-test-snipe-reload)
(define-key *global-keymap* "F11" 'lem-yath-test-snipe-static)
(define-key *global-keymap* "F12" 'lem-yath-test-snipe-record)

(snipe-test-log "READY")
