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
        (state (agenda-view-state)))
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
     "STATE command=~a span=~a keyword=~a rows=~d keywords=~s dates=~s entries=~s"
     (agenda-view-state-command state)
     (agenda-view-state-span state)
     (agenda-view-state-todo-keyword state)
     (length rows)
     (nreverse keywords)
     (nreverse dates)
     (nreverse rows))))

(define-key *lem-yath-agenda-mode-keymap* "C-c z d"
  'lem-yath-test-agenda-dispatch-state)
