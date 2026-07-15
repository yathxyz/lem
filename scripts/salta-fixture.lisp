(in-package :lem-yath)

(defvar *salta-test-fake-bin* (uiop:getenv "LEM_YATH_SALTA_FAKE_BIN"))
(setf (uiop:getenv "PATH")
      (format nil "~a:~a" *salta-test-fake-bin* (uiop:getenv "PATH")))

(defvar *salta-test-report* (uiop:getenv "LEM_YATH_SALTA_REPORT"))
(defvar *salta-test-source-buffer* (current-buffer))
(defvar *salta-test-source-text* (buffer-text (current-buffer)))

(defun salta-test-yes-no (value)
  (if value "yes" "no"))

(defun salta-test-log (control &rest arguments)
  (with-open-file (stream *salta-test-report* :direction :output
                          :if-exists :append :if-does-not-exist :create)
    (apply #'format stream (concatenate 'string control "~%") arguments)))

(defun salta-test-key-command (map keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find map (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun salta-test-keys-p ()
  (and
   (eq (salta-test-key-command *salta-list-mode-keymap* "Return")
       'salta-list-open)
   (eq (salta-test-key-command *salta-list-mode-keymap* "r")
       'salta-list-reckoner)
   (eq (salta-test-key-command *salta-list-mode-keymap* "w")
       'salta-list-copy-id)
   (eq (salta-test-key-command *salta-list-mode-keymap* "g")
       'salta-list-refresh)
   (eq (salta-test-key-command *salta-list-mode-keymap* "q")
       'quit-active-window)
   (eq (salta-test-key-command *salta-detail-mode-keymap* "w")
       'salta-detail-copy-id)
   (eq (salta-test-key-command *salta-detail-mode-keymap* "r")
       'salta-detail-reckoner)
   (eq (salta-test-key-command *salta-detail-mode-keymap* "c")
       'salta-detail-claims)
   (eq (salta-test-key-command *salta-detail-mode-keymap* "p")
       'salta-detail-payments)
   (eq (salta-test-key-command *salta-detail-mode-keymap* "g")
       'salta-list-refresh)
   (eq (salta-test-key-command *salta-detail-mode-keymap* "q")
       'quit-active-window)))

(defun salta-test-kill ()
  (or (lem/common/killring:peek-killring-item (current-killring) 0) "none"))

(define-command lem-yath-salta-test-report () ()
  (let* ((buffer (current-buffer))
         (mode (buffer-major-mode buffer))
         (list-p (eq mode 'salta-list-mode))
         (detail-p (eq mode 'salta-detail-mode))
         (text (buffer-text buffer)))
    (salta-test-log
     "STATE mode=~a name=~a row=~a app=~a code=~a generation=~a read-only=~a keys=~a kill=~a numeric=~a source-live=~a source-exact=~a"
     (cond (list-p "list") (detail-p "detail") (t "other"))
     (buffer-name buffer)
     (or (and list-p (salta-current-row-id)) "none")
     (or (buffer-value buffer :salta-application-id) "none")
     (or (buffer-value buffer :salta-application-code) "none")
     *salta-request-generation*
     (salta-test-yes-no (buffer-read-only-p buffer))
     (salta-test-yes-no (salta-test-keys-p))
     (salta-test-kill)
     (salta-test-yes-no
      (and (= 0d0 (salta-number "#.(error \"unsafe\")"))
           (string= "2.00" (salta-money "1.999"))))
     (salta-test-yes-no (not (deleted-buffer-p *salta-test-source-buffer*)))
     (salta-test-yes-no
      (and (not (deleted-buffer-p *salta-test-source-buffer*))
           (string= *salta-test-source-text*
                    (buffer-text *salta-test-source-buffer*))))
     text)))

(define-command lem-yath-salta-test-source () ()
  (unless (deleted-buffer-p *salta-test-source-buffer*)
    (switch-to-buffer *salta-test-source-buffer*)))

(define-command lem-yath-salta-test-detail () ()
  (alexandria:when-let ((buffer (get-buffer "*salta: APP-001*")))
    (switch-to-buffer buffer)))

(define-key *global-keymap* "F4" 'lem-yath-salta-test-report)
(define-key *global-keymap* "F5" 'lem-yath-salta-test-source)
(define-key *global-keymap* "F6" 'lem-yath-salta-test-detail)

(setf *salta-contractor-cache* nil)
(setf *salta-request-generation* 0)
(setf *salta-request-timeout* 5)
(setf *salta-output-limit* (* 1024 1024))
(salta-test-log "EXEC curl=~a" (executable-find "curl"))
(salta-test-log "READY")
