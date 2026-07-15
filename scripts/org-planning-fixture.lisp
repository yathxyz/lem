(in-package :lem-yath)

(setf *org-planning-now-function*
      (lambda () (encode-universal-time 0 0 12 15 7 2026 0)))

(defvar *org-planning-test-snapshot* 0)

(defun org-planning-test-directory ()
  (uiop:ensure-directory-pathname
   (or (uiop:getenv "LEM_YATH_ORG_PLANNING_SNAPSHOTS")
       (error "LEM_YATH_ORG_PLANNING_SNAPSHOTS is unset"))))

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
  (message "Planning snapshot ~d" *org-planning-test-snapshot*))

(define-command lem-yath-test-org-planning-read-only () ()
  (setf (buffer-read-only-p (current-buffer)) t)
  (message "Planning buffer read-only"))

(define-command lem-yath-test-org-planning-writable () ()
  (setf (buffer-read-only-p (current-buffer)) nil)
  (message "Planning buffer writable"))
