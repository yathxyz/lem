(in-package :lem-yath)

(setf *org-planning-now-function*
      (lambda () (encode-universal-time 0 0 12 15 7 2026 0)))

(defvar *org-timestamp-test-snapshot* 0)

(defun org-timestamp-test-directory ()
  (uiop:ensure-directory-pathname
   (or (uiop:getenv "LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS")
       (error "LEM_YATH_ORG_TIMESTAMP_SNAPSHOTS is unset"))))

(defun org-timestamp-test-find (text)
  (let ((point (current-point)))
    (buffer-start point)
    (unless (search-forward-regexp point (ppcre:quote-meta-chars text))
      (error "Timestamp test text not found: ~s" text))
    point))

(defmacro define-org-timestamp-test-goto (name text)
  `(define-command ,name () ()
     (move-point (current-point) (org-timestamp-test-find ,text))))

(defmacro define-org-timestamp-test-goto-line-end (name text)
  `(define-command ,name () ()
     (let ((point (org-timestamp-test-find ,text)))
       (line-end point)
       (move-point (current-point) point))))

(defmacro define-org-timestamp-test-goto-field (name text backward)
  `(define-command ,name () ()
     (let ((point (org-timestamp-test-find ,text)))
       (character-offset point (- ,backward))
       (move-point (current-point) point))))

(define-org-timestamp-test-goto lem-yath-test-timestamp-goto-heading
  "Timestamp task")
(define-org-timestamp-test-goto-line-end lem-yath-test-timestamp-goto-active
  "Insert active:")
(define-org-timestamp-test-goto-line-end lem-yath-test-timestamp-goto-inactive
  "Insert inactive:")
(define-org-timestamp-test-goto lem-yath-test-timestamp-goto-replace
  "09:30-10:30 +1w -2d>")
(define-org-timestamp-test-goto lem-yath-test-timestamp-goto-convert
  "2026-07-20 Mon +2w>")
(define-org-timestamp-test-goto lem-yath-test-timestamp-goto-shift
  "08:00-09:00 +1m]")
(define-org-timestamp-test-goto-line-end lem-yath-test-timestamp-goto-forced
  "Forced time:")
(define-org-timestamp-test-goto-line-end lem-yath-test-timestamp-goto-immediate
  "Immediate:")
(define-org-timestamp-test-goto-line-end lem-yath-test-timestamp-goto-cancel
  "Cancelled:")
(define-org-timestamp-test-goto-line-end lem-yath-test-timestamp-goto-range-active
  "Range active:")
(define-org-timestamp-test-goto-line-end lem-yath-test-timestamp-goto-range-mixed
  "Range mixed:")
(define-org-timestamp-test-goto lem-yath-test-timestamp-goto-range-existing
  "2026-07-10 Fri +1w>")
(define-org-timestamp-test-goto-line-end
  lem-yath-test-timestamp-goto-range-interrupted
  "Range interrupted:")
(define-org-timestamp-test-goto-line-end
  lem-yath-test-timestamp-goto-range-cancelled
  "Range cancelled:")
(define-org-timestamp-test-goto
  lem-yath-test-timestamp-goto-clock-heading "Clock shifts")
(define-org-timestamp-test-goto-field
  lem-yath-test-timestamp-goto-clock-minute "10:01" 1)
(define-org-timestamp-test-goto-field
  lem-yath-test-timestamp-goto-clock-hour "Sat 12" 1)
(define-org-timestamp-test-goto-field
  lem-yath-test-timestamp-goto-clock-prefix "14:00" 1)
(define-org-timestamp-test-goto-field
  lem-yath-test-timestamp-goto-clock-month "2024-01" 1)
(define-org-timestamp-test-goto-field
  lem-yath-test-timestamp-goto-clock-day "CLOCK: [2026-07-20" 1)
(define-org-timestamp-test-goto-field
  lem-yath-test-timestamp-goto-clock-year "2020" 1)
(define-org-timestamp-test-goto-field
  lem-yath-test-timestamp-goto-clock-open "16:00" 1)
(define-org-timestamp-test-goto-field
  lem-yath-test-timestamp-goto-clock-meta "19:30" 1)
(define-org-timestamp-test-goto-field
  lem-yath-test-timestamp-goto-clock-read-only "20:00" 1)
(define-org-timestamp-test-goto
  lem-yath-test-timestamp-goto-outside-clock "Outside clock shift")
(define-org-timestamp-test-goto
  lem-yath-test-timestamp-goto-list-continuation "shift continuation")
(define-org-timestamp-test-goto
  lem-yath-test-timestamp-goto-table-first "| left")
(define-org-timestamp-test-goto
  lem-yath-test-timestamp-goto-table-last "right |")

(define-command lem-yath-test-org-timestamp-bindings () ()
  (with-open-file (stream (merge-pathnames "bindings"
                                           (org-timestamp-test-directory))
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :supersede)
    (dolist (keys '("C-c ." "C-c !" "C-c Left" "C-c Right" "C-x u"
                    "Shift-Left" "Shift-Right"
                    "C-Shift-h" "C-Shift-l" "C-Shift-k" "C-Shift-j"
                    "C-c H" "C-c L" "C-c K" "C-c J"))
      (format stream "~a ~a~%" keys
              (if (string= keys "C-x u")
                  (lem-vi-mode/core:with-state *lem-yath-emacs-state*
                    (find-keybind (lem-core::parse-keyspec keys)))
                  (find-keybind (lem-core::parse-keyspec keys))))))
  (message "Timestamp bindings captured"))

(define-command lem-yath-test-org-timestamp-snapshot () ()
  (incf *org-timestamp-test-snapshot*)
  (with-open-file
      (stream (merge-pathnames
               (format nil "state-~d" *org-timestamp-test-snapshot*)
               (org-timestamp-test-directory))
              :direction :output
              :if-does-not-exist :create
              :if-exists :supersede)
    (write-string
     (points-to-string (buffer-start-point (current-buffer))
                       (buffer-end-point (current-buffer)))
     stream))
  (message "Timestamp snapshot ~d" *org-timestamp-test-snapshot*))

(define-command lem-yath-test-org-timestamp-read-only () ()
  (setf (buffer-read-only-p (current-buffer)) t)
  (message "Timestamp buffer read-only"))

(define-command lem-yath-test-org-timestamp-writable () ()
  (setf (buffer-read-only-p (current-buffer)) nil)
  (message "Timestamp buffer writable"))
