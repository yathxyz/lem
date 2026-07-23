(in-package :lem-yath)

(setf *org-planning-now-function*
      (lambda () (encode-universal-time 0 0 12 15 7 2026 0)))

(defvar *org-planning-test-snapshot* 0)

(defun org-planning-test-find (text)
  (let ((point (current-point)))
    (buffer-start point)
    (unless (search-forward-regexp point (ppcre:quote-meta-chars text))
      (error "Planning test text not found: ~s" text))
    point))

(define-command lem-yath-test-org-planning-goto-cookie () ()
  (move-point (current-point) (org-planning-test-find "Cookie task")))

(define-command lem-yath-test-org-planning-goto-planned () ()
  (move-point (current-point) (org-planning-test-find "Planned task")))

(define-command lem-yath-test-org-planning-goto-region () ()
  (move-point (current-point) (org-planning-test-find "Region parent"))
  (message "Planning region ready"))

(define-command lem-yath-test-org-planning-region-targets () ()
  (with-open-file
      (stream (merge-pathnames "region-targets"
                               (org-planning-test-directory))
              :direction :output
              :if-does-not-exist :create
              :if-exists :supersede)
    (format stream "visual=~a line=~a~%"
            (lem-vi-mode/visual:visual-p)
            (lem-vi-mode/visual:visual-line-p))
    (dolist (heading (org-planning-target-headings))
      (format stream "~a~%" (line-string heading))))
  (message "Planning region targets recorded"))

(define-key *global-keymap* "F8"
  'lem-yath-test-org-planning-region-targets)

(defun org-planning-test-directory ()
  (uiop:ensure-directory-pathname
   (or (uiop:getenv "LEM_YATH_ORG_PLANNING_SNAPSHOTS")
       (error "LEM_YATH_ORG_PLANNING_SNAPSHOTS is unset"))))

(define-command lem-yath-test-org-date-static () ()
  (let* ((now (funcall *org-planning-now-function*))
         (cases
           '(("2026-07-15" "2026-07-15")
             ("3-2-5" "2003-02-05")
             ("2/5/3" "2003-02-05")
             ("16" "2026-07-16")
             ("14" "2026-08-14")
             ("fri" "2026-07-17")
             ("-tue" "2026-07-14")
             ("+2tue" "2026-07-28")
             ("tomorrow" "2026-07-16")
             ("sep 15" "2026-09-15")
             ("sep 15 2026" "2026-09-15")
             ("22 september" "2026-09-22")
             ("feb 15" "2027-02-15")
             ("sep 15 202" "1970-09-15")
             ("sep 15 2040" "2037-09-15")
             ("w29" "2026-07-13")))
         (failures '()))
    (dolist (case cases)
      (let ((actual (org-parse-date-input (first case) :now now)))
        (unless (equal actual (second case))
          (push (format nil "~s=>~s" (first case) actual) failures))))
    (unless (equal
             (org-parse-date-input "++1m" :default-date "2026-07-31"
                                           :now now)
             "2026-08-31")
      (push "double-relative" failures))
    (when (org-parse-date-input "2026-02-30" :now now)
      (push "invalid-date" failures))
    (multiple-value-bind (lines spans)
        (org-date-render-month "2026-07-01" "2026-07-15" "2026-07-16")
      (unless (and (= (length lines) 8)
                   (search "July 2026" (aref lines 0))
                   (find 'org-date-reader-selected-attribute spans
                         :key #'fourth))
        (push "calendar-render" failures)))
    (with-open-file
        (stream (merge-pathnames "date-static"
                                 (org-planning-test-directory))
                :direction :output
                :if-does-not-exist :create
                :if-exists :supersede)
      (format stream "~a~{ ~a~}~%"
              (if failures "FAIL" "PASS") (nreverse failures)))
    (message "Org date static ~a" (if failures "failed" "passed"))))

(define-command lem-yath-test-org-planning-bindings () ()
  (with-open-file (stream (merge-pathnames "bindings"
                                           (org-planning-test-directory))
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :supersede)
    (dolist (keys '("C-c C-s" "C-c C-d"))
      (format stream "~a ~a~%" keys
              (find-keybind (lem-core::parse-keyspec keys))))))

(define-command lem-yath-test-org-planning-snapshot () ()
  (incf *org-planning-test-snapshot*)
  (with-open-file
      (stream (merge-pathnames
               (format nil "state-~d" *org-planning-test-snapshot*)
               (org-planning-test-directory))
              :direction :output
              :if-does-not-exist :create
              :if-exists :supersede)
    (write-string
     (points-to-string (buffer-start-point (current-buffer))
                       (buffer-end-point (current-buffer)))
     stream))
  (with-open-file
      (stream (merge-pathnames
               (format nil "mode-~d" *org-planning-test-snapshot*)
               (org-planning-test-directory))
              :direction :output
              :if-does-not-exist :create
              :if-exists :supersede)
    (format stream "active=~a buffer=~a~%"
            (class-name (class-of (lem-vi-mode/core:current-state)))
            (class-name
             (class-of
              (lem-vi-mode/core:buffer-state (current-buffer))))))
  (message "Planning snapshot ~d" *org-planning-test-snapshot*))

(define-command lem-yath-test-org-planning-read-only () ()
  (setf (buffer-read-only-p (current-buffer)) t)
  (message "Planning buffer read-only"))

(define-command lem-yath-test-org-planning-writable () ()
  (setf (buffer-read-only-p (current-buffer)) nil)
  (message "Planning buffer writable"))
