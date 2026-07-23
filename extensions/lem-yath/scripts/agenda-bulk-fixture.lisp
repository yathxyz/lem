(in-package :lem-yath)

(setf *agenda-now-function*
      (lambda () (encode-universal-time 0 0 12 12 7 2026 0)))

(defun agenda-bulk-test-report-path ()
  (or (uiop:getenv "LEM_YATH_AGENDA_BULK_REPORT")
      (error "LEM_YATH_AGENDA_BULK_REPORT is unset")))

(defun agenda-bulk-test-log (format-control &rest arguments)
  (with-open-file (stream (agenda-bulk-test-report-path)
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :append)
    (apply #'format stream format-control arguments)
    (terpri stream)
    (finish-output stream)))

(defun agenda-bulk-test-state-name ()
  (if (lem-yath-emacs-state-p) "emacs" "normal"))

(defun agenda-bulk-test-command-name (keys)
  (let ((command (find-keybind (lem-core::parse-keyspec keys))))
    (if (symbolp command) (symbol-name command) (princ-to-string command))))

(define-command lem-yath-test-agenda-bulk-state () ()
  (let ((rendered 0))
    (agenda-bulk-map-rows
     (lambda (point)
       (when (char= (character-at point 0) #\>)
         (incf rendered))))
    (agenda-bulk-test-log
     "STATE state=~a x=~a B=~a marks=~d rendered=~d"
     (agenda-bulk-test-state-name)
     (agenda-bulk-test-command-name "x")
     (agenda-bulk-test-command-name "B")
     (length (agenda-bulk-marks)) rendered)))

(defun agenda-bulk-test-goto (text)
  (with-point ((point (buffer-start-point (current-buffer))))
    (loop
      (when (search text (line-string point))
        (move-point (current-point) point)
        (return-from agenda-bulk-test-goto))
      (unless (line-offset point 1)
        (error "Agenda bulk test row is missing: ~a" text)))))

(defmacro define-agenda-bulk-test-goto (name text)
  `(define-command ,name () () (agenda-bulk-test-goto ,text)))

(define-agenda-bulk-test-goto lem-yath-test-bulk-todo-alpha
  "Bulk TODO alpha sentinel")
(define-agenda-bulk-test-goto lem-yath-test-bulk-todo-beta
  "Bulk TODO beta sentinel")
(define-agenda-bulk-test-goto lem-yath-test-bulk-current
  "Bulk current fallback sentinel")
(define-agenda-bulk-test-goto lem-yath-test-bulk-schedule-alpha
  "Bulk schedule alpha sentinel")
(define-agenda-bulk-test-goto lem-yath-test-bulk-schedule-beta
  "Bulk schedule beta sentinel")
(define-agenda-bulk-test-goto lem-yath-test-bulk-archive-alpha
  "Bulk archive alpha sentinel")
(define-agenda-bulk-test-goto lem-yath-test-bulk-archive-beta
  "Bulk archive beta sentinel")
(define-agenda-bulk-test-goto lem-yath-test-bulk-refile-alpha
  "Bulk refile alpha sentinel")
(define-agenda-bulk-test-goto lem-yath-test-bulk-refile-beta
  "Bulk refile beta sentinel")
(define-agenda-bulk-test-goto lem-yath-test-bulk-stale
  "Bulk stale sentinel")

(define-command lem-yath-test-agenda-bulk-stale-source () ()
  (let* ((target (first (agenda-bulk-marks)))
         (point (and target (agenda-clock-target-point target))))
    (unless (and point (alive-point-p point))
      (error "No live bulk target to make stale"))
    (with-current-buffer (point-buffer point)
      (with-point ((end point))
        (line-end end)
        (insert-string end " changed"))
      (agenda-bulk-test-log
       "STALE modified=~a text=~s"
       (if (buffer-modified-p (current-buffer)) "yes" "no")
       (line-string point)))))

(let ((keymap *lem-yath-agenda-mode-keymap*))
  (define-key keymap "C-c z k" 'lem-yath-test-agenda-bulk-state)
  (define-key keymap "C-c z 1" 'lem-yath-test-bulk-todo-alpha)
  (define-key keymap "C-c z 2" 'lem-yath-test-bulk-todo-beta)
  (define-key keymap "C-c z 3" 'lem-yath-test-bulk-current)
  (define-key keymap "C-c z 4" 'lem-yath-test-bulk-schedule-alpha)
  (define-key keymap "C-c z 5" 'lem-yath-test-bulk-schedule-beta)
  (define-key keymap "C-c z 6" 'lem-yath-test-bulk-archive-alpha)
  (define-key keymap "C-c z 7" 'lem-yath-test-bulk-archive-beta)
  (define-key keymap "C-c z 8" 'lem-yath-test-bulk-refile-alpha)
  (define-key keymap "C-c z 9" 'lem-yath-test-bulk-refile-beta)
  (define-key keymap "C-c z 0" 'lem-yath-test-bulk-stale)
  (define-key keymap "C-c z s" 'lem-yath-test-agenda-bulk-stale-source))
