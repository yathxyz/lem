;;;; GNU Org countdown timer lifecycle used by the agenda and Org buffers.

(in-package :lem-yath)

(defvar *org-countdown-done-timer* nil)
(defvar *org-countdown-modeline-timer* nil)
(defvar *org-countdown-deadline* nil)
(defvar *org-countdown-title* nil)

(defun org-countdown-active-p ()
  (not (null *org-countdown-done-timer*)))

(defun org-countdown-stop-timer (timer)
  (when timer
    (ignore-errors (stop-timer timer))))

(defun org-countdown-clear ()
  "Stop and forget the active countdown without displaying a notification."
  (let ((done *org-countdown-done-timer*)
        (modeline-timer *org-countdown-modeline-timer*))
    ;; Clear ownership before stopping so already queued callbacks are inert.
    (setf *org-countdown-done-timer* nil
          *org-countdown-modeline-timer* nil
          *org-countdown-deadline* nil
          *org-countdown-title* nil)
    (org-countdown-stop-timer done)
    (org-countdown-stop-timer modeline-timer))
  nil)

(defun org-countdown-seconds-to-hms (seconds)
  (let* ((seconds (max 0 (floor seconds)))
         (hours (floor seconds 3600))
         (remainder (mod seconds 3600))
         (minutes (floor remainder 60)))
    (format nil "~d:~2,'0d:~2,'0d" hours minutes (mod remainder 60))))

(defun org-countdown-remaining-seconds ()
  (and (org-countdown-active-p)
       *org-countdown-deadline*
       (max 0 (- *org-countdown-deadline* (get-universal-time)))))

(defun org-countdown-modeline (window)
  (declare (ignore window))
  (alexandria:if-let ((seconds (org-countdown-remaining-seconds)))
    (format nil " <~a>" (org-countdown-seconds-to-hms seconds))
    ""))

(defun org-countdown-refresh (timer)
  ;; Timer delivery already redraws after this callback on the editor thread.
  (eq timer *org-countdown-modeline-timer*))

(defun org-countdown-finish (timer title)
  (when (eq timer *org-countdown-done-timer*)
    (org-countdown-clear)
    (message "~a: time out" title)))

(defun org-countdown-start (seconds title)
  (org-countdown-clear)
  (let (done modeline-timer)
    (setf *org-countdown-deadline* (+ (get-universal-time) seconds)
          *org-countdown-title* title
          done (make-timer
                (lambda () (org-countdown-finish done title))
                :name "lem-yath Org countdown completion")
          modeline-timer
          (make-timer
           (lambda () (org-countdown-refresh modeline-timer))
           :name "lem-yath Org countdown modeline")
          *org-countdown-done-timer*
          (start-timer done (* 1000 seconds) :repeat nil)
          *org-countdown-modeline-timer*
          (start-timer modeline-timer 1000 :repeat t)))
  (redraw-display)
  seconds)

(defun org-countdown-input-seconds (value)
  "Parse Org timer prompt VALUE.

A bare integer denotes minutes.  One omitted leading field denotes minutes
and seconds, matching `org-timer-fix-incomplete'."
  (let ((value (string-trim '(#\Space #\Tab #\Return) value)))
    (cond
      ((ppcre:scan "^[0-9]+$" value)
       (* 60 (parse-integer value)))
      ((ppcre:scan "^[0-9]+:[0-9]+$" value)
       (destructuring-bind (minutes seconds)
           (mapcar #'parse-integer
                   (uiop:split-string value :separator '(#\:)))
         (+ (* 60 minutes) seconds)))
      ((ppcre:scan "^[0-9]+:[0-9]+:[0-9]+$" value)
       (destructuring-bind (hours minutes seconds)
           (mapcar #'parse-integer
                   (uiop:split-string value :separator '(#\:)))
         (+ (* 3600 hours) (* 60 minutes) seconds)))
      (t nil))))

(defun org-countdown-effort-seconds (&optional (point (current-point)))
  (alexandria:when-let
      ((effort (text-property-at point :agenda-effort)))
    (* 60 (floor (agenda-filter-duration-minutes effort)))))

(defun org-countdown-title-at-point ()
  (or (alexandria:when-let
          ((heading (text-property-at (current-point) :agenda-heading)))
        (agenda-refile-heading-title heading))
      (and (eq (buffer-major-mode (current-buffer)) 'org-mode)
           (alexandria:when-let ((heading (org-current-heading-point)))
             (agenda-refile-heading-title (line-string heading))))
      (buffer-name (current-buffer))))

(defun org-countdown-show-remaining ()
  (alexandria:if-let ((seconds (org-countdown-remaining-seconds)))
    (message "~d minute(s) ~d seconds left before next time out"
             (floor seconds 60) (mod seconds 60))
    (message "No timer set")))

(define-command lem-yath-org-set-timer (argument) (:universal-nil)
  "Set the global Org countdown timer from Effort, a prefix, or a prompt."
  (let* ((raw-prefix (universal-argument-of-this-command))
         (effort-seconds (and (null raw-prefix)
                              (null argument)
                              (org-countdown-effort-seconds)))
         (prompt-p (or (and raw-prefix (eql argument 64))
                       (and (null raw-prefix)
                            (null argument)
                            (null effort-seconds))))
         (input (and prompt-p
                     (prompt-for-string
                      "How much time left? (minutes or h:mm:ss) ")))
         (seconds (cond
                    (effort-seconds effort-seconds)
                    ((and raw-prefix (not (eql argument 64))) 0)
                    ((and argument (null raw-prefix)) (* 60 argument))
                    (input (org-countdown-input-seconds input))))
         (replace-without-confirmation-p
           (and raw-prefix (eql argument 16))))
    (cond
      ((and input (not (ppcre:scan "[0-9]+" input)))
       (org-countdown-show-remaining))
      ((null seconds)
       (message "Cannot parse timer duration: ~s" input))
      ((and (org-countdown-active-p)
            (not replace-without-confirmation-p)
            (not (prompt-for-y-or-n-p "Replace current timer? ")))
       (message "No timer set"))
      (t
       (org-countdown-start seconds (org-countdown-title-at-point))))))

(define-key *lem-yath-agenda-vi-keymap* "c T" 'lem-yath-org-set-timer)
(define-key *lem-yath-agenda-mode-keymap* ";" 'lem-yath-org-set-timer)
(define-key *org-mode-keymap* "C-c C-x ;" 'lem-yath-org-set-timer)

(modeline-remove-status-list 'org-countdown-modeline)
(modeline-add-status-list 'org-countdown-modeline)

(remove-hook *exit-editor-hook* 'org-countdown-clear)
(add-hook *exit-editor-hook* 'org-countdown-clear)
