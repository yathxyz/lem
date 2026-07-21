(in-package :lem-yath)

(setf *agenda-now-function*
      (lambda () (encode-universal-time 0 0 12 17 7 2026 0)))

(defun agenda-dispatch-test-log (control &rest arguments)
  (with-open-file
      (stream (or (uiop:getenv "LEM_YATH_AGENDA_DISPATCH_REPORT")
                  (error "Agenda dispatch report path is unset"))
              :direction :output
              :if-exists :append
              :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(define-command lem-yath-test-agenda-dispatch-state () ()
  (let ((rows '())
        (keywords '())
        (dates '())
        (state (agenda-view-state))
        (restriction
          (buffer-value (current-buffer) 'lem-yath-agenda-restriction)))
    (with-point ((point (buffer-start-point (current-buffer))))
      (loop
        (when (agenda-source-row-p point)
          (push (line-string point) rows)
          (alexandria:when-let
              ((keyword (text-property-at point :agenda-keyword)))
            (push keyword keywords))
          (alexandria:when-let
              ((date (text-property-at point :agenda-display-date)))
            (push date dates)))
        (unless (line-offset point 1) (return))))
    (agenda-dispatch-test-log
     (concatenate
      'string
      "STATE command=~a span=~a keyword=~a rows=~d keywords=~s dates=~s "
      "entries=~s restriction=~a range=~a..~a")
     (agenda-view-state-command state)
     (agenda-view-state-span state)
     (agenda-view-state-todo-keyword state)
     (length rows)
     (nreverse keywords)
     (nreverse dates)
     (nreverse rows)
     (and restriction (agenda-restriction-kind restriction))
     (and restriction (agenda-restriction-start-line restriction))
     (and restriction (agenda-restriction-end-line restriction)))))

(define-command lem-yath-test-agenda-dispatch-region () ()
  "Activate an exact source region spanning the second and third headings."
  (let ((buffer (current-buffer)))
    (with-point ((start (buffer-start-point buffer))
                 (end (buffer-start-point buffer)))
      (line-offset start 5)
      (line-offset end 9)
      (setf (buffer-mark buffer) (copy-point start :left-inserting))
      (move-point (buffer-point buffer) end)))
  (lem-yath-agenda-dispatch))

(define-command lem-yath-test-agenda-dispatch-partial-region () ()
  "Restrict the first heading while excluding its following deadline line."
  (let ((buffer (current-buffer)))
    (with-point ((start (buffer-start-point buffer))
                 (end (buffer-start-point buffer)))
      (line-offset end 1)
      (setf (buffer-mark buffer) (copy-point start :left-inserting))
      (move-point (buffer-point buffer) end)))
  (lem-yath-agenda-dispatch))

(define-command lem-yath-test-agenda-dispatch-cancel-region () ()
  (buffer-mark-cancel (current-buffer)))

(define-key *lem-yath-agenda-mode-keymap* "C-c z d"
  'lem-yath-test-agenda-dispatch-state)

(define-key *org-mode-keymap* "C-c z r"
  'lem-yath-test-agenda-dispatch-region)

(define-key *org-mode-keymap* "C-c z c"
  'lem-yath-test-agenda-dispatch-cancel-region)

(define-key *org-mode-keymap* "C-c z p"
  'lem-yath-test-agenda-dispatch-partial-region)
