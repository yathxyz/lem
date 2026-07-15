(in-package :lem-yath)

(defvar *elfeed-test-fake-bin* (uiop:getenv "LEM_YATH_ELFEED_FAKE_BIN"))
(setf (uiop:getenv "PATH")
      (format nil "~a:~a" *elfeed-test-fake-bin* (uiop:getenv "PATH")))

(defvar *elfeed-test-report* (uiop:getenv "LEM_YATH_ELFEED_REPORT"))
(defvar *elfeed-test-source-buffer* (current-buffer))
(defvar *elfeed-test-source-text* (buffer-text (current-buffer)))

(defun elfeed-test-yes-no (value) (if value "yes" "no"))

(defun elfeed-test-key-command (map keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find map (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun elfeed-test-keys-p ()
  (and
   (eq (elfeed-test-key-command *lem-yath-feeds-mode-keymap* "Return")
       'lem-yath-elfeed-show-entry)
   (eq (elfeed-test-key-command *lem-yath-feeds-mode-keymap* "g")
       'lem-yath-elfeed)
   (eq (elfeed-test-key-command *lem-yath-feeds-mode-keymap* "q")
       'lem-yath-elfeed-quit)
   (eq (elfeed-test-key-command *lem-yath-feeds-mode-keymap* "b")
       'lem-yath-elfeed-open-url)
   (eq (elfeed-test-key-command *lem-yath-feeds-mode-keymap* "A")
       'lem-yath-elfeed-archive)
   (eq (elfeed-test-key-command *lem-yath-feed-entry-mode-keymap* "b")
       'lem-yath-elfeed-open-url)
   (eq (elfeed-test-key-command *lem-yath-feed-entry-mode-keymap* "A")
       'lem-yath-elfeed-archive)
   (eq (elfeed-test-key-command *lem-yath-feed-entry-mode-keymap* "q")
       'lem-yath-elfeed-quit)))

(defun elfeed-test-log (control &rest arguments)
  (with-open-file (stream *elfeed-test-report* :direction :output
                          :if-exists :append :if-does-not-exist :create)
    (apply #'format stream (concatenate 'string control "~%") arguments)))

(define-command lem-yath-elfeed-test-report () ()
  (let* ((buffer (current-buffer))
         (mode (buffer-major-mode buffer))
         (list-p (eq mode 'lem-yath-feeds-mode))
         (entry-p (eq mode 'lem-yath-feed-entry-mode))
         (row (and list-p (elfeed-entry-at-point)))
         (entry (and entry-p (buffer-value buffer *elfeed-entry-key*)))
         (text (buffer-text buffer)))
    (elfeed-test-log
     "STATE mode=~a row=~a entry=~a generation=~a read-only=~a keys=~a body=~a hidden=~a source-live=~a source-exact=~a"
     (cond (list-p "list") (entry-p "entry") (t "other"))
     (or (getf row :id) "none")
     (or (getf entry :id) "none")
     (or (buffer-value buffer *elfeed-generation-key*) 0)
     (elfeed-test-yes-no (buffer-read-only-p buffer))
     (elfeed-test-yes-no (elfeed-test-keys-p))
     (elfeed-test-yes-no
      (and entry-p
           (search "Second body & decoded." text)
           (search "https://example.invalid/102?x=1&safe=touch%20PWNED" text)))
     (elfeed-test-yes-no
      (and entry-p
           (not (search "hidden script" text))
           (not (search "hidden style" text))))
     (elfeed-test-yes-no
      (not (deleted-buffer-p *elfeed-test-source-buffer*)))
     (elfeed-test-yes-no
      (and (not (deleted-buffer-p *elfeed-test-source-buffer*))
           (string= *elfeed-test-source-text*
                    (buffer-text *elfeed-test-source-buffer*)))))))

(define-command lem-yath-elfeed-test-open () ()
  (lem-yath-elfeed))

(define-key *global-keymap* "F3" 'lem-yath-elfeed-test-open)
(define-key *global-keymap* "F4" 'lem-yath-elfeed-test-report)

(setf *elfeed-curl-timeout* 5)
(setf *elfeed-output-limit* (* 1024 1024))
(elfeed-test-log "EXEC curl=~a xdg-open=~a"
                 (executable-find "curl")
                 (executable-find "xdg-open"))
(elfeed-test-log "READY")
