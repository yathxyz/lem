;;;; Configured compilation probes. Async waits live in the external driver.
(in-package :lem-yath)

(defvar *managed-compilation-test-session* nil)
(defvar *managed-compilation-test-limit* (* 8 1024 1024))

(defun managed-compilation-test-start (command directory)
  (let* ((source (or (get-buffer "managed-compilation-source")
                     (make-buffer "managed-compilation-source")))
         (*compilation-output-limit* *managed-compilation-test-limit*))
    (switch-to-buffer source)
    (setf *managed-compilation-test-session*
          (compilation-start-session source (current-window) command
                                     (uiop:ensure-directory-pathname directory)
                                     (lint-capture-environment)))
    (lem-toolkit/jobs:job-id
     (compilation-session-managed-job *managed-compilation-test-session*))))

(defun managed-compilation-test-snapshot ()
  (let* ((session *managed-compilation-test-session*)
         (buffer (compilation-session-buffer session))
         (text (if (compilation-session-owns-buffer-p session) (buffer-text buffer) ""))
         (job (lem-toolkit/jobs:job-snapshot (compilation-session-managed-job session))))
    (remhash "stdout" job)
    (remhash "stderr" job)
    (lem-daemon/recovery-store:object
     "state" (string-downcase (compilation-session-state session))
     "job" job
     "view-alive" (if (compilation-session-owns-buffer-p session) t yason:false)
     "text" (if (> (length text) 4096)
                (concatenate 'string (subseq text 0 2048) (subseq text (- (length text) 2048)))
                text)
     "text-length" (length text)
     "diagnostics" (length (compilation-session-diagnostics session))
     "point-line" (if (compilation-session-owns-buffer-p session)
                      (line-number-at-point (buffer-point buffer)) 0))))

(defun managed-compilation-test-kill-view ()
  (delete-buffer (compilation-session-buffer *managed-compilation-test-session*))
  (not (null (compilation-process-alive-p *managed-compilation-test-session*))))

(defun managed-compilation-test-static ()
  (assert (lem-toolkit/jobs:job-manager-ready-p (ensure-toolkit-job-manager)))
  (assert (not (fboundp 'compilation-guardian-python-program)))
  (assert (search "make -k -j" (compilation-default-command)))
  (let ((parser (make-compilation-session
                 :directory (compilation-session-directory *managed-compilation-test-session*))))
    (loop for sample in '("main.c:2:3: error: gcc"
                          "  --> secondary.rs:3:5"
                          "worker.go:4:2: go"
                          "  File \"test_sample.py\", line 5, in test"
                          "test_sample.py:6:7: F401 ruff"
                          "error: bad at default.nix:7:4"
                          "Meson encountered an error in file meson.build, line 8, column 9:")
          for line from 1
          do (assert (compilation-parse-diagnostic parser sample line))))
  (let* ((session *managed-compilation-test-session*)
         (buffer (compilation-session-buffer session))
         (text (buffer-text buffer)))
    (assert (buffer-read-only-p buffer))
    (assert (not (buffer-enable-undo-p buffer)))
    (assert (handler-case (progn (insert-string (buffer-point buffer) "forbidden") nil)
              (lem/buffer/errors:read-only-error () t)))
    (assert (string= text (buffer-text buffer)))
    (assert (= 1 (line-number-at-point (buffer-point buffer)))))
  t)

(defun managed-compilation-test-navigation ()
  (let ((session *managed-compilation-test-session*))
    (switch-to-buffer (compilation-session-buffer session))
    (buffer-start (current-point))
    (lem-yath-compilation-next-error)
    (assert (eq (current-buffer) (compilation-session-buffer session)))
    (lem-yath-compilation-visit-error)
    (assert (equal "sample" (pathname-name (buffer-filename (current-buffer)))))
    (assert (= 2 (line-number-at-point (current-point))))
    (assert (= 2 (point-charpos (current-point)))))
  t)
