(in-package :lem-yath)

(defun sops-test-write (pathname text)
  (with-open-file (stream pathname
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create
                          :external-format :utf-8)
    (write-string text stream)))

(defun sops-test-control (text)
  (sops-test-write (uiop:getenv "LEM_YATH_SOPS_CONTROL") text))

(defun sops-test-report-file (&optional (buffer (current-buffer)))
  (multiple-value-bind (encrypted-p checked-p)
      (sops-filestatus (buffer-filename buffer))
    (sops-test-write
     (uiop:getenv "LEM_YATH_SOPS_REPORT")
     (format nil
             "active=~s creating=~s failed=~s readonly=~s modified=~s error=~s encrypted=~s checked=~s program=~s~%"
             (sops-buffer-active-p buffer)
             (sops-buffer-creating-p buffer)
             (buffer-value buffer 'lem-yath-sops-decrypt-failed)
             (buffer-read-only-p buffer)
             (buffer-modified-p buffer)
             (buffer-value buffer 'lem-yath-sops-last-error)
             encrypted-p checked-p *sops-program*))))

(define-command lem-yath-sops-test-report () ()
  (let ((buffer (current-buffer)))
    (sops-test-report-file buffer)
    (message "SOPS-STATE active=~:[no~;yes~] creating=~:[no~;yes~] failed=~:[no~;yes~] readonly=~:[no~;yes~] modified=~:[no~;yes~] error=~s"
             (sops-buffer-active-p buffer)
             (sops-buffer-creating-p buffer)
             (buffer-value buffer 'lem-yath-sops-decrypt-failed)
             (buffer-read-only-p buffer)
             (buffer-modified-p buffer)
             (buffer-value buffer 'lem-yath-sops-last-error))))

(define-command lem-yath-sops-test-encrypt-fail () ()
  (sops-test-control "encrypt-fail")
  (message "SOPS-CONTROL encrypt-fail"))

(define-command lem-yath-sops-test-clear () ()
  (sops-test-control "")
  (message "SOPS-CONTROL clear"))

(define-command lem-yath-sops-test-external-revert () ()
  (sops-test-write (buffer-filename (current-buffer))
                   "sops:
  mac: fake
ciphertext: SECOND
")
  (sops-revert-buffer (current-buffer))
  (message "SOPS-EXTERNAL-REVERT"))

(define-command lem-yath-sops-test-open-failed () ()
  (sops-test-control "decrypt-fail")
  (find-file (uiop:getenv "LEM_YATH_SOPS_FAILED_FILE"))
  (lem-yath-sops-test-report))

(define-command lem-yath-sops-test-retry () ()
  (sops-test-control "")
  (sops-revert-buffer (current-buffer))
  (message "SOPS-RETRY active=~:[no~;yes~] readonly=~:[no~;yes~]"
           (sops-buffer-active-p)
           (buffer-read-only-p (current-buffer))))

(define-command lem-yath-sops-test-open-plain () ()
  (find-file (uiop:getenv "LEM_YATH_SOPS_PLAIN_FILE"))
  (lem-yath-sops-test-report))

(define-command lem-yath-sops-test-reload () ()
  (load (uiop:getenv "LEM_YATH_SOPS_SOURCE"))
  (message "SOPS-RELOADED"))

(define-command lem-yath-sops-test-open-create-failure () ()
  (sops-open-path (uiop:getenv "LEM_YATH_SOPS_CREATE_FAILURE_FILE"))
  (message "SOPS-CREATE-FAILURE-OPEN"))

(defun sops-test-refused-p (path &optional path-already-exists-p)
  (let ((before (length (buffer-list))))
    (and (handler-case
             (progn (sops-open-path path) nil)
           (error () t))
         (= before (length (buffer-list)))
         (or path-already-exists-p (not (probe-file path))))))

(defun sops-test-template-p (name expected)
  (let* ((path (merge-pathnames name
                                (uiop:ensure-directory-pathname
                                 (uiop:getenv "WORKDIR"))))
         (buffer (find-file-buffer path)))
    (unwind-protect
         (progn
           (sops-start-creation buffer (sops-creation-format path))
           (and (string= expected (sops-buffer-text buffer))
                (sops-buffer-active-p buffer)
                (sops-buffer-creating-p buffer)
                (not (buffer-modified-p buffer))
                (not (probe-file path))))
      (delete-buffer buffer))))

(defun sops-test-template-matrix-p ()
  (every #'identity
         (list
          (sops-test-template-p
           "template.yaml"
           "hello: Welcome to SOPS! Edit this file as you please!
example_key: example_value
# Example comment
example_array:
    - example_value1
    - example_value2
example_number: 1234.56789
example_booleans:
    - true
    - false
")
          (sops-test-template-p
           "template.json"
           "{
    \"hello\": \"Welcome to SOPS! Edit this file as you please!\",
    \"example_key\": \"example_value\",
    \"example_array\": [
        \"example_value1\",
        \"example_value2\"
    ],
    \"example_number\": 1234.56789,
    \"example_booleans\": [
        true,
        false
    ]
}
")
          (sops-test-template-p
           "template.env"
           "# Welcome to SOPS! Edit this file as you please!
example_key=example_value
")
          (sops-test-template-p
           "template.ini"
           "[Welcome!]
; This is an example file.
hello=Welcome to SOPS! Edit this file as you please!
example_key=example_value
")
          (sops-test-template-p
           "template.txt" "hello from emacs sops-mode!
")
          (sops-test-template-p "template.unknown" ""))))

(define-command lem-yath-sops-test-preflight () ()
  (let* ((control (uiop:getenv "LEM_YATH_SOPS_CONTROL"))
         (missing-parent (uiop:getenv "LEM_YATH_SOPS_MISSING_PARENT_FILE"))
         (missing-policy (uiop:getenv "LEM_YATH_SOPS_MISSING_POLICY_FILE"))
         (old-version (uiop:getenv "LEM_YATH_SOPS_OLD_VERSION_FILE"))
         (malformed-version
           (uiop:getenv "LEM_YATH_SOPS_MALFORMED_VERSION_FILE"))
         (directory (uiop:getenv "WORKDIR"))
         (templates-ok (sops-test-template-matrix-p))
         (missing-parent-ok (sops-test-refused-p missing-parent))
         (missing-policy-ok (sops-test-refused-p missing-policy))
         (directory-ok (sops-test-refused-p
                        (namestring
                         (uiop:ensure-directory-pathname directory))
                        t)))
    (sops-test-write control "old-version")
    (setf *sops-version-cache* nil)
    (let ((old-version-ok (sops-test-refused-p old-version)))
      (sops-test-write control "malformed-version")
      (setf *sops-version-cache* nil)
      (let ((malformed-version-ok
              (sops-test-refused-p malformed-version)))
        (sops-test-write control "")
        (setf *sops-version-cache* nil)
        (sops-test-write
         (uiop:getenv "LEM_YATH_SOPS_PREFLIGHT_REPORT")
         (format nil "templates=~s missing-parent=~s missing-policy=~s directory=~s old-version=~s malformed-version=~s~%"
                 templates-ok missing-parent-ok missing-policy-ok directory-ok
                 old-version-ok malformed-version-ok))
        (message "SOPS-PREFLIGHT templates=~:[no~;yes~] missing-parent=~:[no~;yes~] missing-policy=~:[no~;yes~] directory=~:[no~;yes~] old-version=~:[no~;yes~] malformed-version=~:[no~;yes~]"
                 templates-ok missing-parent-ok missing-policy-ok directory-ok
                 old-version-ok malformed-version-ok)))))

(define-key *global-keymap* "F1" 'lem-yath-sops-test-open-plain)
(define-key *global-keymap* "F2" 'lem-yath-sops-test-retry)
(define-key *global-keymap* "F3" 'lem-yath-sops-test-open-failed)
(define-key *global-keymap* "F5" 'lem-yath-sops-test-report)
(define-key *global-keymap* "F6" 'lem-yath-sops-test-encrypt-fail)
(define-key *global-keymap* "F7" 'lem-yath-sops-test-clear)
(define-key *global-keymap* "F8" 'lem-yath-sops-test-external-revert)
(define-key *global-keymap* "F9" 'lem-yath-sops-test-reload)
(define-key *global-keymap* "F10" 'lem-yath-sops-test-open-create-failure)
(define-key *global-keymap* "F11" 'lem-yath-sops-test-preflight)

(sops-test-report-file)
