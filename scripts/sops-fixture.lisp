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
             "active=~s failed=~s readonly=~s modified=~s error=~s encrypted=~s checked=~s program=~s~%"
             (sops-buffer-active-p buffer)
             (buffer-value buffer 'lem-yath-sops-decrypt-failed)
             (buffer-read-only-p buffer)
             (buffer-modified-p buffer)
             (buffer-value buffer 'lem-yath-sops-last-error)
             encrypted-p checked-p *sops-program*))))

(define-command lem-yath-sops-test-report () ()
  (let ((buffer (current-buffer)))
    (sops-test-report-file buffer)
    (message "SOPS-STATE active=~:[no~;yes~] failed=~:[no~;yes~] readonly=~:[no~;yes~] modified=~:[no~;yes~] error=~s"
             (sops-buffer-active-p buffer)
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

(define-key *global-keymap* "F1" 'lem-yath-sops-test-open-plain)
(define-key *global-keymap* "F2" 'lem-yath-sops-test-retry)
(define-key *global-keymap* "F3" 'lem-yath-sops-test-open-failed)
(define-key *global-keymap* "F5" 'lem-yath-sops-test-report)
(define-key *global-keymap* "F6" 'lem-yath-sops-test-encrypt-fail)
(define-key *global-keymap* "F7" 'lem-yath-sops-test-clear)
(define-key *global-keymap* "F8" 'lem-yath-sops-test-external-revert)
(define-key *global-keymap* "F9" 'lem-yath-sops-test-reload)

(sops-test-report-file)
