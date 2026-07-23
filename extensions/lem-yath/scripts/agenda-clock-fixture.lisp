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
    "KEYS state=~a I=~a O=~a cg=~a cc=~a J=~a X=~a plus=~a minus=~a "
    "control-goto=~a control-cancel=~a cr=~a R=~a "
    "m=~a tilde=~a star=~a percent=~a "
    "M=~a u=~a U=~a M-m=~a M-star=~a")
   (agenda-clock-test-state-name)
   (agenda-clock-test-command-name "I")
   (agenda-clock-test-command-name "O")
   (agenda-clock-test-command-name "c g")
   (agenda-clock-test-command-name "c c")
   (agenda-clock-test-command-name "J")
   (agenda-clock-test-command-name "X")
   (agenda-clock-test-command-name "+")
   (agenda-clock-test-command-name "-")
   (agenda-clock-test-command-name "C-c C-x C-j")
   (agenda-clock-test-command-name "C-c C-x C-x")
   (agenda-clock-test-command-name "c r")
   (agenda-clock-test-command-name "R")
   (agenda-clock-test-command-name "m")
   (agenda-clock-test-command-name "~")
   (agenda-clock-test-command-name "*")
   (agenda-clock-test-command-name "%")
   (agenda-clock-test-command-name "M")
   (agenda-clock-test-command-name "u")
   (agenda-clock-test-command-name "U")
   (agenda-clock-test-command-name "M-m")
   (agenda-clock-test-command-name "M-*")))

(defun agenda-clock-test-source-line-count (scanner)
  (let ((buffer (find-file-buffer (merge-pathnames "clock.org" (workdir))))
        (count 0))
    (with-point ((point (buffer-start-point buffer)))
      (loop
        (when (ppcre:scan scanner (line-string point))
          (incf count))
        (unless (line-offset point 1)
          (return))))
    count))

(define-command lem-yath-test-agenda-clock-source-report () ()
  (let ((buffer (find-file-buffer (merge-pathnames "clock.org" (workdir)))))
    (agenda-clock-test-log
     "CLOCK-SOURCE modified=~a open=~d logbook=~d active=~a"
     (if (buffer-modified-p buffer) "yes" "no")
     (agenda-clock-test-source-line-count
      "^\\s*CLOCK: \\[.*\\]\\s*$")
     (agenda-clock-test-source-line-count "^\\s*:LOGBOOK:\\s*$")
     (if (agenda-clock-active-valid-p) "yes" "no"))))

(define-command lem-yath-test-agenda-clock-hide-current-row () ()
  (unless (agenda-row-mark-key-at-point (current-point))
    (editor-error "No agenda row to hide"))
  (with-buffer-read-only (current-buffer) nil
    (with-point ((start (current-point))
                 (end (current-point)))
      (line-start start)
      (if (line-offset end 1)
          (line-start end)
          (line-end end))
      (delete-between-points start end)))
  (buffer-unmark (current-buffer)))

(define-command lem-yath-test-agenda-clock-location-report () ()
  (agenda-clock-test-log
   "CLOCK-LOCATION file=~a line=~d text=~s"
   (if (buffer-filename (current-buffer))
       (file-namestring (buffer-filename (current-buffer)))
       "none")
   (line-number-at-point (current-point))
   (line-string (current-point))))

(define-command lem-yath-test-agenda-clock-return-to-agenda () ()
  (alexandria:if-let ((buffer (get-buffer *agenda-buffer-name*)))
    (switch-to-buffer buffer)
    (editor-error "Agenda buffer is missing")))

(define-command lem-yath-test-agenda-clock-visit-source () ()
  (switch-to-buffer
   (find-file-buffer (merge-pathnames "clock.org" (workdir))))
  (agenda-clock-test-log
   "SOURCE-CONTEXT file=~a state=~a u=~a"
   (file-namestring (buffer-filename (current-buffer)))
   (agenda-clock-test-state-name)
   (agenda-clock-test-command-name "u")))

(define-command lem-yath-test-agenda-clock-report-state () ()
  (let ((in-report-p nil)
        (summary 0)
        (total 0)
        (clock-file 0)
        (public-file 0)
        (parent 0)
        (child 0)
        (decoy 0)
        (source-rows 0))
    (with-point ((point (buffer-start-point (current-buffer))))
      (loop
        (let ((line (line-string point)))
          (when (ppcre:scan
                 "^Clock summary  \\(2026-07-12 through 2026-07-19\\)$"
                 line)
            (setf in-report-p t)
            (incf summary))
          (when in-report-p
            (when (and (ppcre:scan "Total time" line)
                       (ppcre:scan "2:00" line))
              (incf total))
            (when (and (ppcre:scan "clock\\.org" line)
                       (ppcre:scan "File time" line)
                       (ppcre:scan "1:00" line))
              (incf clock-file))
            (when (and (ppcre:scan "public\\.org" line)
                       (ppcre:scan "File time" line)
                       (ppcre:scan "1:00" line))
              (incf public-file))
            (when (and (ppcre:scan "Clock three sentinel" line)
                       (ppcre:scan "1:00" line))
              (incf parent))
            (when (and (ppcre:scan "Nested clock report" line)
                       (ppcre:scan "0:30" line))
              (incf child))
            (when (ppcre:scan "Semantic clock decoy" line)
              (incf decoy))
            (when (text-property-at point :agenda-clock-report-file)
              (incf source-rows))))
        (unless (line-offset point 1) (return))))
    (agenda-clock-test-log
     (concatenate
      'string
      "CLOCK-REPORT enabled=~a summary=~d total=~d clock-file=~d "
      "public-file=~d parent=~d child=~d decoy=~d source-rows=~d")
     (if (agenda-clockreport-mode-p) "yes" "no")
     summary total clock-file public-file parent child decoy source-rows)))

(define-command lem-yath-test-agenda-clock-report-child () ()
  (with-point ((point (buffer-start-point (current-buffer))))
    (loop
      (when (string-equal
             (or (text-property-at point :agenda-clock-report-heading) "")
             "** Nested clock report sentinel")
        (move-point (current-point) point)
        (return-from lem-yath-test-agenda-clock-report-child))
      (unless (line-offset point 1)
        (editor-error "Nested report row is missing")))))

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

(define-command lem-yath-test-agenda-restricted-clock-report () ()
  (let* ((buffer (current-buffer))
         (file (merge-pathnames "clock.org" (workdir)))
         (restriction
           (make-agenda-restriction
            :kind :subtree :file file :start-line 9 :end-line 17))
         (old (buffer-value buffer 'lem-yath-agenda-restriction)))
    (unwind-protect
         (progn
           (setf (buffer-value buffer 'lem-yath-agenda-restriction)
                 restriction)
           (multiple-value-bind (files failures) (agenda-org-files)
             (multiple-value-bind (scoped scoped-failures predicate)
                 (agenda-restriction-scan-scope buffer files failures)
               (declare (ignore scoped-failures))
               (multiple-value-bind (report report-failures)
                   (agenda-clock-collect-report
                    scoped "2026-07-12" "2026-07-19" predicate)
                 (agenda-clock-test-log
                  "RESTRICTED-CLOCK files=~d failures=~d minutes=~d headings=~s"
                  (length (agenda-clock-report-files report))
                  (length report-failures)
                  (agenda-clock-report-minutes report)
                  (mapcan
                   (lambda (report-file)
                     (mapcar #'agenda-clock-report-heading-title
                             (agenda-clock-report-file-headings report-file)))
                   (agenda-clock-report-files report)))))))
      (setf (buffer-value buffer 'lem-yath-agenda-restriction) old))))

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
  (define-key keymap "C-c z v" 'lem-yath-test-agenda-clock-hide-current-row)
  (define-key keymap "C-c z o" 'lem-yath-test-agenda-clock-visit-source)
  (define-key keymap "C-c z w" 'lem-yath-test-agenda-clock-report-state)
  (define-key keymap "C-c z j" 'lem-yath-test-agenda-clock-report-child)
  (define-key keymap "C-c z k" 'lem-yath-test-agenda-clock-keys)
  (define-key keymap "C-c z r" 'lem-yath-test-agenda-clock-report)
  (define-key keymap "C-c z R" 'lem-yath-test-agenda-restricted-clock-report)
  (define-key keymap "C-c z x" 'lem-yath-test-agenda-clock-source-report))

(define-key *global-keymap* "C-c z l"
  'lem-yath-test-agenda-clock-location-report)
(define-key *global-keymap* "C-c z b"
  'lem-yath-test-agenda-clock-return-to-agenda)
(define-key *global-keymap* "C-c z y"
  'lem-yath-test-agenda-clock-source-report)

(agenda-clock-test-log "READY")
