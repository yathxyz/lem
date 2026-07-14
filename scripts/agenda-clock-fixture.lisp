(in-package :lem-yath)

(defvar *agenda-clock-test-time*
  (encode-universal-time 0 0 12 12 7 2026 0))

(setf *agenda-now-function*
      (lambda () (encode-universal-time 0 0 12 12 7 2026 0))
      *agenda-clock-now-function* (lambda () *agenda-clock-test-time*))

(defun agenda-clock-test-log (control &rest arguments)
  (with-open-file (stream (or (uiop:getenv "LEM_YATH_AGENDA_CLOCK_REPORT")
                              (error "Clock report path is unset"))
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun agenda-clock-test-state-name ()
  (let ((state (lem-vi-mode/core:current-state)))
    (cond
      ((typep state 'lem-yath-emacs-state) "emacs")
      ((typep state 'lem-vi-mode:normal) "normal")
      ((typep state 'lem-vi-mode:insert) "insert")
      (t (string-downcase (symbol-name (type-of state)))))))

(defun agenda-clock-test-command-name (keys)
  (let ((command (find-keybind (lem-core::parse-keyspec keys))))
    (if (symbolp command) (symbol-name command) (princ-to-string command))))

(defun agenda-clock-test-find-row (text &optional (occurrence 1))
  (with-point ((point (buffer-start-point (current-buffer))))
    (loop :with seen := 0
          :do (when (and (agenda-row-mark-key-at-point point)
                         (search text (line-string point)))
                (incf seen)
                (when (= seen occurrence)
                  (return (copy-point point :temporary))))
          :unless (line-offset point 1)
            :do (error "Agenda row not found: ~s occurrence ~d"
                       text occurrence))))

(defun agenda-clock-test-goto (text &optional (occurrence 1))
  (move-point (current-point)
              (agenda-clock-test-find-row text occurrence)))

(define-command lem-yath-test-agenda-clock-one () ()
  (agenda-clock-test-goto "Clock one sentinel"))

(define-command lem-yath-test-agenda-clock-two () ()
  (agenda-clock-test-goto "Clock two sentinel"))

(define-command lem-yath-test-agenda-clock-three () ()
  (agenda-clock-test-goto "Clock three sentinel"))

(define-command lem-yath-test-agenda-clock-public () ()
  (agenda-clock-test-goto "Public clock sentinel"))

(define-command lem-yath-test-agenda-clock-duplicate-one () ()
  (agenda-clock-test-goto "Duplicate clock sentinel" 1))

(define-command lem-yath-test-agenda-clock-duplicate-two () ()
  (agenda-clock-test-goto "Duplicate clock sentinel" 2))

(defun agenda-clock-test-set-time (hour minute)
  (setf *agenda-clock-test-time*
        (encode-universal-time 0 minute hour 12 7 2026 0))
  (message "Clock test time ~2,'0d:~2,'0d" hour minute))

(define-command lem-yath-test-agenda-clock-1215 () ()
  (agenda-clock-test-set-time 12 15))

(define-command lem-yath-test-agenda-clock-1245 () ()
  (agenda-clock-test-set-time 12 45))

(define-command lem-yath-test-agenda-clock-1300 () ()
  (agenda-clock-test-set-time 13 0))

(define-command lem-yath-test-agenda-clock-1330 () ()
  (agenda-clock-test-set-time 13 30))

(define-command lem-yath-test-agenda-clock-1400 () ()
  (agenda-clock-test-set-time 14 0))

(define-command lem-yath-test-agenda-clock-1430 () ()
  (agenda-clock-test-set-time 14 30))

(define-command lem-yath-test-agenda-clock-1500 () ()
  (agenda-clock-test-set-time 15 0))

(define-command lem-yath-test-agenda-clock-1515 () ()
  (agenda-clock-test-set-time 15 15))

(define-command lem-yath-test-agenda-clock-stale () ()
  (let* ((file (text-property-at (current-point) :agenda-file))
         (buffer (and file (find-file-buffer file))))
    (unless buffer (error "No source for stale-row test"))
    (with-current-buffer buffer
      (insert-string (buffer-start-point buffer)
                     (format nil "# unsaved stale clock row~%")))
    (agenda-clock-test-log "STALE modified=yes file=~a"
                           (uiop:native-namestring file))
    (dolist (mark (agenda-bulk-marks))
      (let ((point (agenda-clock-target-point mark)))
        (agenda-clock-test-log
         "STALE-MARK valid=~a line=~a text=~s"
         (if (agenda-clock-target-valid-p mark) "yes" "no")
         (if (alive-point-p point) (line-number-at-point point) "dead")
         (and (alive-point-p point) (line-string point)))))))

(define-command lem-yath-test-agenda-clock-keys () ()
  (agenda-clock-test-log
   (concatenate
    'string
    "KEYS state=~a I=~a O=~a m=~a tilde=~a star=~a percent=~a M=~a "
    "u=~a U=~a M-m=~a M-star=~a")
   (agenda-clock-test-state-name)
   (agenda-clock-test-command-name "I")
   (agenda-clock-test-command-name "O")
   (agenda-clock-test-command-name "m")
   (agenda-clock-test-command-name "~")
   (agenda-clock-test-command-name "*")
   (agenda-clock-test-command-name "%")
   (agenda-clock-test-command-name "M")
   (agenda-clock-test-command-name "u")
   (agenda-clock-test-command-name "U")
   (agenda-clock-test-command-name "M-m")
   (agenda-clock-test-command-name "M-*")))

(define-command lem-yath-test-agenda-clock-report () ()
  (let ((marked-rows 0)
        (entry-rows 0))
    (with-point ((point (buffer-start-point (current-buffer))))
      (loop
        (when (agenda-row-mark-key-at-point point)
          (incf entry-rows)
          (when (char= (or (character-at point) #\Space) #\>)
            (incf marked-rows)
            (agenda-clock-test-log "MARK text=~s" (line-string point))))
        (unless (line-offset point 1) (return))))
    (agenda-clock-test-log
     "STATE state=~a marks=~d rendered=~d global=~a point-line=~a point=~s"
     (agenda-clock-test-state-name)
     (length (agenda-bulk-marks))
     marked-rows
     (if (agenda-clock-active-valid-p) "yes" "no")
     (or (text-property-at (current-point) :agenda-line) "none")
     (line-string (current-point)))
    (agenda-clock-test-log "STATE-ENTRIES count=~d" entry-rows)))

(dolist (keymap (list *lem-yath-agenda-vi-keymap*
                      *lem-yath-agenda-mode-keymap*))
  (define-key keymap "C-c z 1" 'lem-yath-test-agenda-clock-one)
  (define-key keymap "C-c z 2" 'lem-yath-test-agenda-clock-two)
  (define-key keymap "C-c z 3" 'lem-yath-test-agenda-clock-three)
  (define-key keymap "C-c z p" 'lem-yath-test-agenda-clock-public)
  (define-key keymap "C-c z d" 'lem-yath-test-agenda-clock-duplicate-one)
  (define-key keymap "C-c z D" 'lem-yath-test-agenda-clock-duplicate-two)
  (define-key keymap "C-c z a" 'lem-yath-test-agenda-clock-1215)
  (define-key keymap "C-c z b" 'lem-yath-test-agenda-clock-1245)
  (define-key keymap "C-c z c" 'lem-yath-test-agenda-clock-1300)
  (define-key keymap "C-c z e" 'lem-yath-test-agenda-clock-1330)
  (define-key keymap "C-c z f" 'lem-yath-test-agenda-clock-1400)
  (define-key keymap "C-c z g" 'lem-yath-test-agenda-clock-1430)
  (define-key keymap "C-c z h" 'lem-yath-test-agenda-clock-1500)
  (define-key keymap "C-c z i" 'lem-yath-test-agenda-clock-1515)
  (define-key keymap "C-c z s" 'lem-yath-test-agenda-clock-stale)
  (define-key keymap "C-c z k" 'lem-yath-test-agenda-clock-keys)
  (define-key keymap "C-c z r" 'lem-yath-test-agenda-clock-report))

(agenda-clock-test-log "READY")
