(in-package :lem-yath)

(defvar *notmuch-test-fake-bin* (uiop:getenv "LEM_YATH_NOTMUCH_FAKE_BIN"))
(setf (uiop:getenv "PATH")
      (format nil "~a:~a" *notmuch-test-fake-bin* (uiop:getenv "PATH")))

(defvar *notmuch-test-report* (uiop:getenv "LEM_YATH_NOTMUCH_REPORT"))
(defvar *notmuch-test-source-buffer* (current-buffer))
(defvar *notmuch-test-source-text* (buffer-text (current-buffer)))
(defvar *notmuch-test-query*
  "tag:inbox and subject:\"safe;touch PWNED\"")

(defun notmuch-test-yes-no (value) (if value "yes" "no"))

(defun notmuch-test-key-command (map keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find map (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun notmuch-test-keys-p ()
  (and
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "Return")
       'lem-yath-notmuch-open-thread)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "g")
       'lem-yath-notmuch-refresh)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "q")
       'quit-active-window)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "g")
       'lem-yath-notmuch-show-refresh)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "C-c s e")
       'lem-yath-salta-open-payment-email-from-notmuch)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "q")
       'quit-active-window)))

(defun notmuch-test-log (control &rest arguments)
  (with-open-file (stream *notmuch-test-report* :direction :output
                          :if-exists :append :if-does-not-exist :create)
    (apply #'format stream (concatenate 'string control "~%") arguments)))

(define-command lem-yath-notmuch-test-report () ()
  (let* ((buffer (current-buffer))
         (mode (buffer-major-mode buffer))
         (list-p (eq mode 'notmuch-search-mode))
         (show-p (eq mode 'notmuch-show-mode)))
    (notmuch-test-log
     "STATE mode=~a query=~a row=~a thread=~a message=~a read-only=~a keys=~a body=~a html-hidden=~a source-live=~a source-exact=~a"
     (cond (list-p "list") (show-p "show") (t "other"))
     (notmuch-test-yes-no
      (and list-p
           (string= *notmuch-test-query*
                    (buffer-value buffer 'notmuch-query))))
     (if list-p (or (notmuch-thread-id-at-point) "none") "none")
     (if show-p (or (buffer-value buffer 'notmuch-thread-id) "none") "none")
     (if show-p (or (notmuch-message-id-at-point) "none") "none")
     (notmuch-test-yes-no (buffer-read-only-p buffer))
     (notmuch-test-yes-no (notmuch-test-keys-p))
     (notmuch-test-yes-no
      (and show-p
           (search "Primary plain body." (buffer-text buffer))
           (search "Reply plain body." (buffer-text buffer))))
     (notmuch-test-yes-no
      (and show-p (not (search "ignored html" (buffer-text buffer)))))
     (notmuch-test-yes-no
      (not (deleted-buffer-p *notmuch-test-source-buffer*)))
     (notmuch-test-yes-no
      (and (not (deleted-buffer-p *notmuch-test-source-buffer*))
           (string= *notmuch-test-source-text*
                    (buffer-text *notmuch-test-source-buffer*)))))))

(define-command lem-yath-notmuch-test-open () ()
  (notmuch-search *notmuch-test-query*))

(define-command lem-yath-notmuch-test-empty () ()
  (notmuch-search "tag:empty"))

(define-key *global-keymap* "F1" 'lem-yath-notmuch-test-report)
(define-key *global-keymap* "F3" 'lem-yath-notmuch-test-open)
(define-key *global-keymap* "F4" 'lem-yath-notmuch-test-empty)
(define-key *global-keymap* "F5" 'lem-yath-fetchmail)

(notmuch-test-log "EXEC notmuch=~a xdg-open=~a"
                  (executable-find "notmuch")
                  (executable-find "xdg-open"))
(notmuch-test-log "READY")
