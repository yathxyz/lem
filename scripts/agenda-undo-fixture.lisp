(in-package :lem-yath)

(setf *agenda-now-function*
      (lambda () (encode-universal-time 0 0 12 12 7 2026 0))
      *agenda-clock-now-function*
      (lambda () (encode-universal-time 0 0 12 12 7 2026 0)))

(defvar *agenda-undo-test-report-serial* 0)

(defun agenda-undo-test-report-path ()
  (or (uiop:getenv "LEM_YATH_AGENDA_UNDO_REPORT")
      (error "LEM_YATH_AGENDA_UNDO_REPORT is unset")))

(defun agenda-undo-test-log (control &rest arguments)
  (with-open-file (stream (agenda-undo-test-report-path)
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :append)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun agenda-undo-test-command-name (keys)
  (let ((command (find-keybind (lem-core::parse-keyspec keys))))
    (if (symbolp command) (symbol-name command) (princ-to-string command))))

(defun agenda-undo-test-buffer (name)
  (find-file-buffer (merge-pathnames name (workdir))))

(defun agenda-undo-test-line (buffer sentinel)
  (with-point ((point (buffer-start-point buffer)))
    (loop
      (when (search sentinel (line-string point))
        (return (line-string point)))
      (unless (line-offset point 1)
        (return "<missing>")))))

(defun agenda-undo-test-next-line (buffer sentinel)
  (with-point ((point (buffer-start-point buffer)))
    (loop
      (when (search sentinel (line-string point))
        (return (if (line-offset point 1)
                    (line-string point)
                    "<eof>")))
      (unless (line-offset point 1)
        (return "<missing>")))))

(defun agenda-undo-test-count-lines (buffer scanner)
  (with-point ((point (buffer-start-point buffer)))
    (loop :with count := 0
          :do (when (ppcre:scan scanner (line-string point))
                (incf count))
          :unless (line-offset point 1)
            :do (return count))))

(defun agenda-undo-test-modified-name (buffer)
  (if (buffer-modified-p buffer) "yes" "no"))

(define-command lem-yath-test-agenda-undo-report () ()
  (let* ((serial (incf *agenda-undo-test-report-serial*))
         (agenda-buffer (current-buffer))
         (records (agenda-undo-records agenda-buffer))
         (saved (agenda-undo-test-buffer "saved.org"))
         (timestamp (agenda-undo-test-buffer "timestamp.org"))
         (bulk (agenda-undo-test-buffer "bulk.org"))
         (archive (agenda-undo-test-buffer "archive.org"))
         (clock (agenda-undo-test-buffer "clock.org"))
         (refresh (agenda-undo-test-buffer "refresh.org"))
         (intervening (agenda-undo-test-buffer "intervening.org")))
    (agenda-undo-test-log
     "REPORT serial=~d records=~d labels=~{~a~^,~} u=~a gr=~a"
     serial (length records)
     (mapcar #'agenda-undo-record-label records)
     (agenda-undo-test-command-name "u")
     (agenda-undo-test-command-name "g r"))
    (agenda-undo-test-log
     "SAVED serial=~d modified=~a text=~s"
     serial (agenda-undo-test-modified-name saved)
     (agenda-undo-test-line saved "Undo saved sentinel"))
    (agenda-undo-test-log
     "TIMESTAMP serial=~d modified=~a planning=~s"
     serial (agenda-undo-test-modified-name timestamp)
     (agenda-undo-test-next-line timestamp "Undo timestamp sentinel"))
    (agenda-undo-test-log
     "BULK serial=~d modified=~a alpha=~s beta=~s"
     serial (agenda-undo-test-modified-name bulk)
     (agenda-undo-test-line bulk "Undo bulk alpha sentinel")
     (agenda-undo-test-line bulk "Undo bulk beta sentinel"))
    (agenda-undo-test-log
     "ARCHIVE serial=~d modified=~a text=~s"
     serial (agenda-undo-test-modified-name archive)
     (agenda-undo-test-line archive "Undo archive sentinel"))
    (agenda-undo-test-log
     "CLOCK serial=~d modified=~a open=~d logbook=~d active=~a"
     serial (agenda-undo-test-modified-name clock)
     (agenda-undo-test-count-lines clock "^\\s*CLOCK: \\[.*\\]\\s*$")
     (agenda-undo-test-count-lines clock "^\\s*:LOGBOOK:\\s*$")
     (if (agenda-clock-active-valid-p) "yes" "no"))
    (agenda-undo-test-log
     "REFRESH serial=~d modified=~a text=~s"
     serial (agenda-undo-test-modified-name refresh)
     (agenda-undo-test-line refresh "Undo refresh sentinel"))
    (agenda-undo-test-log
     "INTERVENING serial=~d modified=~a text=~s"
     serial (agenda-undo-test-modified-name intervening)
     (agenda-undo-test-line intervening "Undo intervening sentinel"))))

(defun agenda-undo-test-goto (sentinel)
  (with-point ((point (buffer-start-point (current-buffer))))
    (loop
      (when (and (agenda-entry-key-at-point point)
                 (search sentinel (line-string point)))
        (move-point (current-point) point)
        (return-from agenda-undo-test-goto))
      (unless (line-offset point 1)
        (error "Agenda undo test row is missing: ~a" sentinel)))))

(defmacro define-agenda-undo-test-goto (name sentinel)
  `(define-command ,name () () (agenda-undo-test-goto ,sentinel)))

(define-agenda-undo-test-goto lem-yath-test-agenda-undo-saved
  "Undo saved sentinel")
(define-agenda-undo-test-goto lem-yath-test-agenda-undo-timestamp
  "Undo timestamp sentinel")
(define-agenda-undo-test-goto lem-yath-test-agenda-undo-bulk-alpha
  "Undo bulk alpha sentinel")
(define-agenda-undo-test-goto lem-yath-test-agenda-undo-bulk-beta
  "Undo bulk beta sentinel")
(define-agenda-undo-test-goto lem-yath-test-agenda-undo-archive
  "Undo archive sentinel")
(define-agenda-undo-test-goto lem-yath-test-agenda-undo-clock
  "Undo clock sentinel")
(define-agenda-undo-test-goto lem-yath-test-agenda-undo-refresh
  "Undo refresh sentinel")
(define-agenda-undo-test-goto lem-yath-test-agenda-undo-intervening
  "Undo intervening sentinel")

(define-command lem-yath-test-agenda-undo-local-edit () ()
  (let ((buffer (agenda-undo-test-buffer "intervening.org")))
    (with-current-buffer buffer
      (with-point ((point (buffer-start-point buffer)))
        (line-end point)
        (insert-string point " local")))))

(let ((keymap *lem-yath-agenda-mode-keymap*))
  (define-key keymap "F2" 'lem-yath-test-agenda-undo-report)
  (define-key keymap "F3" 'lem-yath-test-agenda-undo-saved)
  (define-key keymap "F4" 'lem-yath-test-agenda-undo-timestamp)
  (define-key keymap "F5" 'lem-yath-test-agenda-undo-bulk-alpha)
  (define-key keymap "F6" 'lem-yath-test-agenda-undo-bulk-beta)
  (define-key keymap "F7" 'lem-yath-test-agenda-undo-archive)
  (define-key keymap "F8" 'lem-yath-test-agenda-undo-clock)
  (define-key keymap "F9" 'lem-yath-test-agenda-undo-refresh)
  (define-key keymap "F10" 'lem-yath-test-agenda-undo-intervening)
  (define-key keymap "F11" 'lem-yath-test-agenda-undo-local-edit))
