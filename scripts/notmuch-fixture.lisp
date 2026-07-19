(in-package :lem-yath)

(defvar *notmuch-test-fake-bin* (uiop:getenv "LEM_YATH_NOTMUCH_FAKE_BIN"))
(setf (uiop:getenv "PATH")
      (format nil "~a:~a" *notmuch-test-fake-bin* (uiop:getenv "PATH")))

(defvar *notmuch-test-report* (uiop:getenv "LEM_YATH_NOTMUCH_REPORT"))
(defvar *notmuch-test-source-buffer* (current-buffer))
(defvar *notmuch-test-source-text* (buffer-text (current-buffer)))
(defvar *notmuch-test-query*
  "tag:inbox and subject:\"safe;touch PWNED\"")
(defvar *notmuch-test-pdf-buffer* nil)
(defvar *notmuch-test-pdf-path* nil)
(defvar *notmuch-test-pdf-directory* nil)
(defvar *notmuch-test-compose-attachment*
  (uiop:getenv "LEM_YATH_NOTMUCH_COMPOSE_ATTACHMENT"))
(defvar *notmuch-test-draft-directory* nil)
(defvar *notmuch-test-forward-directory* nil)

(defun notmuch-test-yes-no (value) (if value "yes" "no"))

(defun notmuch-test-source-exact-p ()
  (and (not (deleted-buffer-p *notmuch-test-source-buffer*))
       (string= *notmuch-test-source-text*
                (buffer-text *notmuch-test-source-buffer*))))

(defun notmuch-test-key-command (map keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find map (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun notmuch-test-active-key-command (keys)
  (alexandria:when-let
      ((prefix (lem-core::lookup-keybind (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun notmuch-test-keys-p ()
  (and
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "Return")
       'lem-yath-notmuch-open-thread)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "g")
       'lem-yath-notmuch-refresh)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "a")
       'lem-yath-notmuch-archive-thread)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "d")
       'lem-yath-notmuch-toggle-deleted)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "!")
       'lem-yath-notmuch-toggle-unread)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "=")
       'lem-yath-notmuch-toggle-flagged)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "+")
       'lem-yath-notmuch-add-tag)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "-")
       'lem-yath-notmuch-remove-tag)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "C")
       'lem-yath-notmuch-compose)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "c c")
       'lem-yath-notmuch-compose)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "c r")
       'lem-yath-notmuch-reply-sender)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "c R")
       'lem-yath-notmuch-reply-all)
   (eq (notmuch-test-key-command *notmuch-search-mode-keymap* "q")
       'quit-active-window)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "g")
       'lem-yath-notmuch-show-refresh)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "Return")
       'lem-yath-notmuch-open-part)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "a")
       'lem-yath-notmuch-show-archive-message-next-thread)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "x")
       'lem-yath-notmuch-show-archive-message-next-exit)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "A")
       'lem-yath-notmuch-show-archive-thread-next)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "X")
       'lem-yath-notmuch-show-archive-thread-exit)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "d")
       'lem-yath-notmuch-show-toggle-deleted)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "=")
       'lem-yath-notmuch-show-toggle-flagged)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "+")
       'lem-yath-notmuch-show-add-tag)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "-")
       'lem-yath-notmuch-show-remove-tag)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "C")
       'lem-yath-notmuch-compose)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "c c")
       'lem-yath-notmuch-compose)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "c r")
       'lem-yath-notmuch-reply-sender)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "c R")
       'lem-yath-notmuch-reply-all)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "c f")
       'lem-yath-notmuch-forward-message)
   (eq (notmuch-test-key-command *notmuch-show-mode-keymap* "e")
       'lem-yath-notmuch-resume-draft)
   (eq (notmuch-test-key-command *notmuch-compose-mode-keymap* "C-c C-c")
       'lem-yath-notmuch-compose-send)
   (eq (notmuch-test-key-command *notmuch-compose-mode-keymap* "C-c C-a")
       'lem-yath-notmuch-compose-attach-file)
   (eq (notmuch-test-key-command *notmuch-compose-mode-keymap* "C-c C-k")
       'lem-yath-notmuch-compose-cancel)
   (eq (notmuch-test-key-command *notmuch-compose-mode-keymap* "C-c C-p")
       'lem-yath-notmuch-compose-postpone)
   (eq (notmuch-test-key-command *notmuch-compose-mode-keymap* "C-x C-s")
       'lem-yath-notmuch-compose-save-draft)
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

(define-command lem-yath-notmuch-test-pdf-report () ()
  (let* ((buffer (current-buffer))
         (path (buffer-value buffer 'notmuch-temp-attachment))
         (directory (buffer-value buffer 'notmuch-temp-directory))
         (file-stat (and path (ignore-errors
                                (sb-posix:lstat
                                 (uiop:native-namestring path)))))
         (directory-stat (and directory (ignore-errors
                                          (sb-posix:lstat
                                           (uiop:native-namestring directory))))))
    (setf *notmuch-test-pdf-buffer* buffer
          *notmuch-test-pdf-path* path
          *notmuch-test-pdf-directory* directory)
    (notmuch-test-log
     "PDF mode=~a page=~a temporary=~a file-private=~a dir-private=~a source=~a"
     (notmuch-test-yes-no (eq (buffer-major-mode buffer) 'document-pdf-mode))
     (or (buffer-value buffer 'document-page) "none")
     (notmuch-test-yes-no
      (and (buffer-temporary-p buffer)
           (buffer-value buffer 'document-ephemeral-p)))
     (notmuch-test-yes-no
      (and file-stat
           (= (logand (sb-posix:stat-mode file-stat) sb-posix:s-ifmt)
              sb-posix:s-ifreg)
           (zerop (logand (sb-posix:stat-mode file-stat) #o077))))
     (notmuch-test-yes-no
      (and directory-stat
           (= (logand (sb-posix:stat-mode directory-stat) sb-posix:s-ifmt)
              sb-posix:s-ifdir)
           (zerop (logand (sb-posix:stat-mode directory-stat) #o077))))
     (notmuch-test-yes-no (notmuch-test-source-exact-p)))))

(define-command lem-yath-notmuch-test-cleanup-report () ()
  (notmuch-test-log
   "CLEAN buffer=~a file=~a directory=~a source=~a"
   (notmuch-test-yes-no
    (and *notmuch-test-pdf-buffer*
         (deleted-buffer-p *notmuch-test-pdf-buffer*)))
   (notmuch-test-yes-no
    (and *notmuch-test-pdf-path*
         (not (uiop:file-exists-p *notmuch-test-pdf-path*))))
   (notmuch-test-yes-no
    (and *notmuch-test-pdf-directory*
         (not (uiop:directory-exists-p *notmuch-test-pdf-directory*))))
   (notmuch-test-yes-no (notmuch-test-source-exact-p))))

(define-command lem-yath-notmuch-test-compose-report () ()
  (let* ((buffer (current-buffer))
         (text (buffer-text buffer))
         (compose-p (eq (buffer-major-mode buffer) 'notmuch-compose-mode)))
    (notmuch-test-log
     "COMPOSE mode=~a from=~a to=~a subject=~a quote=~a all=~a reply=~a sent=~a fcc=~a read-only=~a keys=~a active-send=~a source=~a"
     (notmuch-test-yes-no compose-p)
     (notmuch-test-yes-no
      (and compose-p
           (search "From: \"Yanni \\\"Safe\\\"\" <yanni@example.invalid>" text)))
     (notmuch-test-yes-no
      (and compose-p (search "To: Bob <bob@example.invalid>" text)))
     (notmuch-test-yes-no (and compose-p (search "Subject: Re: Second thread" text)))
     (notmuch-test-yes-no (and compose-p (search "> Primary plain body." text)))
     (notmuch-test-yes-no
      (and compose-p (search "Cc: Team <team@example.invalid>" text)))
     (notmuch-test-yes-no
      (and compose-p (buffer-value buffer 'notmuch-compose-reply-query)))
     (notmuch-test-yes-no
      (and compose-p (buffer-value buffer 'notmuch-compose-sent-message)))
     (notmuch-test-yes-no
      (and compose-p (buffer-value buffer 'notmuch-compose-fcc-done-p)))
     (notmuch-test-yes-no (and compose-p (buffer-read-only-p buffer)))
     (notmuch-test-yes-no (notmuch-test-keys-p))
     (notmuch-test-yes-no
      (eq (notmuch-test-active-key-command "C-c C-c")
          'lem-yath-notmuch-compose-send))
     (notmuch-test-yes-no (notmuch-test-source-exact-p)))))

(defun notmuch-test-address-context-for (text token expected)
  (let ((buffer (make-buffer "*notmuch-address-context-test*")))
    (unwind-protect
         (with-current-buffer buffer
           (erase-buffer buffer)
           (change-buffer-mode buffer 'notmuch-compose-mode)
           (insert-string (buffer-point buffer) text)
           (setf (buffer-value buffer 'notmuch-compose-header-limit)
                 (notmuch-compose-header-limit-point buffer))
           (let ((offset (search token text))
                 (point (buffer-point buffer)))
             (buffer-start point)
             (and offset
                  (progn
                    (character-offset point (+ offset (length token)))
                    (multiple-value-bind (start end prefix)
                        (notmuch-address-context point)
                      (prog1 (if expected
                                 (and start end (string= prefix token))
                                 (null start))
                        (when start (delete-point start))
                        (when end (delete-point end))))))))
      (buffer-unmark buffer)
      (delete-buffer buffer))))

(defun notmuch-test-address-context-matrix ()
  (list
   (notmuch-test-address-context-for
    (format nil "From: Me <me@unit.test>~%To: ali~%Subject: x~%~%body")
    "ali" t)
   (notmuch-test-address-context-for
    (format nil "From: Me <me@unit.test>~%Cc: ali~%Subject: x~%~%body")
    "ali" t)
   (notmuch-test-address-context-for
    (format nil "From: Me <me@unit.test>~%Bcc: ali~%Subject: x~%~%body")
    "ali" t)
   (notmuch-test-address-context-for
    (format nil "From: Me <me@unit.test>~%Subject: ali~%~%body")
    "ali" nil)
   (notmuch-test-address-context-for
    (format nil "From: Me <me@unit.test>~%Subject: x~%~%To: ali")
    "ali" nil)))

(define-command lem-yath-notmuch-test-address-report () ()
  (let* ((buffer (current-buffer))
         (text (buffer-text buffer))
         (cache (buffer-value buffer 'notmuch-address-cache))
         (error-text (buffer-value buffer 'notmuch-address-last-error))
         (matrix (notmuch-test-address-context-matrix)))
    (notmuch-test-log
     "ADDRESS mode=~a to=~a subject=~a body=~a spec=~a cache=~a failure=~a idle=~a matrix=~a contexts=~{~a~^,~} source=~a"
     (notmuch-test-yes-no
      (eq (buffer-major-mode buffer) 'notmuch-compose-mode))
     (notmuch-test-yes-no
      (search "To: Alice Example <alice@example.invalid>, Team Address <team@example.invalid>, err"
              text))
     (notmuch-test-yes-no (search "Subject: ali" text))
     (notmuch-test-yes-no (search (format nil "~%~%ali") text))
     (notmuch-test-yes-no
      (variable-value 'lem/language-mode:completion-spec :buffer buffer))
     (notmuch-test-yes-no
      (and cache
           (nth-value 1 (gethash "ali" cache))
           (nth-value 1 (gethash "tea" cache))))
     (notmuch-test-yes-no
      (and error-text (search "injected address failure" error-text)))
     (notmuch-test-yes-no
      (null (buffer-value buffer 'notmuch-address-request)))
     (notmuch-test-yes-no (every #'identity matrix))
     (mapcar #'notmuch-test-yes-no matrix)
     (notmuch-test-yes-no (notmuch-test-source-exact-p)))))

(define-command lem-yath-notmuch-test-attachment-report () ()
  (let* ((buffer (current-buffer))
         (compose-p (eq (buffer-major-mode buffer) 'notmuch-compose-mode))
         (pathname (and *notmuch-test-compose-attachment*
                        (ignore-errors
                          (truename *notmuch-test-compose-attachment*))))
         (marker
           (and pathname
                (format nil
                        "<#part type=\"application/octet-stream\" filename=\"~a\" disposition=attachment>"
                        (notmuch-compose-mml-escape
                         (uiop:native-namestring pathname)))))
         (size (and pathname
                    (ignore-errors
                      (notmuch-compose-attachment-size pathname)))))
    (notmuch-test-log
     "ATTACH mode=~a marker=~a regular=~a bounded=~a count=~a keys=~a active=~a postpone=~a save=~a source=~a"
     (notmuch-test-yes-no compose-p)
     (notmuch-test-yes-no
      (and compose-p marker (search marker (buffer-text buffer))))
     (notmuch-test-yes-no (and size (not (minusp size))))
     (notmuch-test-yes-no
      (and size (<= size *notmuch-compose-attachment-byte-limit*)))
     (if compose-p (notmuch-compose-attachment-marker-count buffer) 0)
     (notmuch-test-yes-no (notmuch-test-keys-p))
     (notmuch-test-yes-no
      (eq (notmuch-test-active-key-command "C-c C-a")
          'lem-yath-notmuch-compose-attach-file))
     (notmuch-test-yes-no
      (eq (notmuch-test-active-key-command "C-c C-p")
          'lem-yath-notmuch-compose-postpone))
     (notmuch-test-yes-no
      (eq (notmuch-test-active-key-command "C-x C-s")
          'lem-yath-notmuch-compose-save-draft))
     (notmuch-test-yes-no (notmuch-test-source-exact-p)))))

(defun notmuch-test-file-bytes-equal-p (left right)
  (handler-case
      (with-open-file (left-stream left :element-type '(unsigned-byte 8))
        (with-open-file (right-stream right :element-type '(unsigned-byte 8))
          (and (= (file-length left-stream) (file-length right-stream))
               (loop :for left-byte := (read-byte left-stream nil nil)
                     :for right-byte := (read-byte right-stream nil nil)
                     :do (cond
                           ((or (null left-byte) (null right-byte))
                            (return (and (null left-byte)
                                         (null right-byte))))
                           ((/= left-byte right-byte)
                            (return nil)))))))
    (error () nil)))

(define-command lem-yath-notmuch-test-draft-report () ()
  (let* ((buffer (current-buffer))
         (compose-p (eq (buffer-major-mode buffer) 'notmuch-compose-mode))
         (directory (and compose-p
                         (buffer-value buffer
                                       'notmuch-compose-draft-directory)))
         (files (and directory
                     (ignore-errors (uiop:directory-files directory))))
         (file (and (= (length files) 1) (first files)))
         (directory-stat
           (and directory
                (ignore-errors
                  (sb-posix:lstat (uiop:native-namestring directory))))))
    (when directory
      (setf *notmuch-test-draft-directory* directory))
    (notmuch-test-log
     "DRAFT mode=~a tracked=~a private=~a extracted=~a bytes=~a marker=~a keys=~a active-save=~a active-postpone=~a error=~a cleaned=~a source=~a"
     (notmuch-test-yes-no compose-p)
     (notmuch-test-yes-no
      (and compose-p
           (buffer-value buffer 'notmuch-compose-draft-query)))
     (notmuch-test-yes-no
      (and directory-stat
           (= (logand (sb-posix:stat-mode directory-stat) sb-posix:s-ifmt)
              sb-posix:s-ifdir)
           (zerop (logand (sb-posix:stat-mode directory-stat) #o077))))
     (notmuch-test-yes-no (and file (uiop:file-exists-p file)))
     (notmuch-test-yes-no
      (and file *notmuch-test-compose-attachment*
           (notmuch-test-file-bytes-equal-p
            file *notmuch-test-compose-attachment*)))
     (notmuch-test-yes-no
      (and compose-p
           (= 1 (notmuch-compose-attachment-marker-count buffer))))
     (notmuch-test-yes-no (notmuch-test-keys-p))
     (notmuch-test-yes-no
      (eq (notmuch-test-active-key-command "C-x C-s")
          'lem-yath-notmuch-compose-save-draft))
     (notmuch-test-yes-no
      (eq (notmuch-test-active-key-command "C-c C-p")
          'lem-yath-notmuch-compose-postpone))
     (notmuch-test-yes-no
      (and compose-p
           (buffer-value buffer 'notmuch-compose-draft-last-error)))
     (notmuch-test-yes-no
      (and *notmuch-test-draft-directory*
           (not (uiop:directory-exists-p
                 *notmuch-test-draft-directory*))))
     (notmuch-test-yes-no (notmuch-test-source-exact-p)))))

(define-command lem-yath-notmuch-test-forward-report () ()
  (let* ((buffer (current-buffer))
         (compose-p (eq (buffer-major-mode buffer) 'notmuch-compose-mode))
         (text (buffer-text buffer))
         (directory (and compose-p
                         (buffer-value buffer
                                       'notmuch-compose-draft-directory)))
         (files (and directory
                     (ignore-errors (uiop:directory-files directory))))
         (file (and (= (length files) 1) (first files)))
         (directory-stat
           (and directory
                (ignore-errors
                  (sb-posix:lstat (uiop:native-namestring directory))))))
    (when directory
      (setf *notmuch-test-forward-directory* directory))
    (notmuch-test-log
     "FORWARD mode=~a tracked=~a subject=~a reference=~a headers=~a body=~a delimiters=~a marker=~a private=~a bytes=~a keys=~a cleaned=~a source=~a"
     (notmuch-test-yes-no compose-p)
     (notmuch-test-yes-no
      (and compose-p
           (buffer-value buffer 'notmuch-compose-forward-query)))
     (notmuch-test-yes-no
      (and compose-p (search "Subject: [Bob] Second thread" text)))
     (notmuch-test-yes-no
      (and compose-p
           (search "References: <payment+safe|touch@example.invalid>"
                   text)))
     (notmuch-test-yes-no
      (and compose-p
           (search "From: Bob <bob@example.invalid>" text)
           (search "To: Yanni <yanni@example.invalid>" text)
           (search "Cc: Team <team@example.invalid>" text)
           (search "Date: Wed, 15 Jul 2026 20:00:00 +0100" text)))
     (notmuch-test-yes-no
      (and compose-p (search "Primary plain body." text)))
     (notmuch-test-yes-no
      (and compose-p
           (search "-------------------- Start of forwarded message --------------------"
                   text)
           (search "-------------------- End of forwarded message --------------------"
                   text)))
     (notmuch-test-yes-no
      (and compose-p (= 1 (notmuch-compose-attachment-marker-count buffer))))
     (notmuch-test-yes-no
      (and directory-stat
           (= (logand (sb-posix:stat-mode directory-stat) sb-posix:s-ifmt)
              sb-posix:s-ifdir)
           (zerop (logand (sb-posix:stat-mode directory-stat) #o077))))
     (notmuch-test-yes-no
      (and file
           (notmuch-test-file-bytes-equal-p
            file (uiop:getenv "LEM_YATH_NOTMUCH_PDF"))))
     (notmuch-test-yes-no (notmuch-test-keys-p))
     (notmuch-test-yes-no
      (and *notmuch-test-forward-directory*
           (not (uiop:directory-exists-p
                 *notmuch-test-forward-directory*))))
     (notmuch-test-yes-no (notmuch-test-source-exact-p)))))

(defun notmuch-test-extraction-refusal
    (attachment &key output-limit timeout)
  (let* ((directory (notmuch-private-temp-directory))
         (pathname (merge-pathnames "attachment.pdf" directory))
         (refused-p nil))
    (unwind-protect
         (handler-case
             (let ((*notmuch-attachment-output-limit*
                     (or output-limit *notmuch-attachment-output-limit*))
                   (*notmuch-process-timeout*
                     (or timeout *notmuch-process-timeout*)))
               (notmuch-extract-raw-part attachment pathname))
           (error () (setf refused-p t)))
      (notmuch-remove-temp-attachment pathname directory))
    (values refused-p
            (and (not (uiop:file-exists-p pathname))
                 (not (uiop:directory-exists-p directory))))))

(define-command lem-yath-notmuch-test-refusals () ()
  (multiple-value-bind (output output-clean)
      (notmuch-test-extraction-refusal
       (make-notmuch-attachment
        :message-id "payment+safe|touch@example.invalid"
        :part-id 7 :filename "large.pdf")
       :output-limit 32)
    (multiple-value-bind (nonpdf nonpdf-clean)
        (notmuch-test-extraction-refusal
         (make-notmuch-attachment
          :message-id "bad@example.invalid"
          :part-id 8 :filename "bad.pdf"))
      (multiple-value-bind (timeout timeout-clean)
          (notmuch-test-extraction-refusal
           (make-notmuch-attachment
            :message-id "slow@example.invalid"
            :part-id 9 :filename "slow.pdf")
           :timeout 1)
        (multiple-value-bind (invalid invalid-clean)
            (notmuch-test-extraction-refusal
             (make-notmuch-attachment
              :message-id (format nil "invalid~%id@example.invalid")
              :part-id 7 :filename "invalid.pdf"))
          (notmuch-test-log
           "REFUSAL output=~a nonpdf=~a timeout=~a invalid=~a clean=~a source=~a"
           (notmuch-test-yes-no output)
           (notmuch-test-yes-no nonpdf)
           (notmuch-test-yes-no timeout)
           (notmuch-test-yes-no invalid)
           (notmuch-test-yes-no
            (and output-clean nonpdf-clean timeout-clean invalid-clean))
           (notmuch-test-yes-no (notmuch-test-source-exact-p))))))))

(define-command lem-yath-notmuch-test-open () ()
  (notmuch-search *notmuch-test-query*))

(define-command lem-yath-notmuch-test-empty () ()
  (notmuch-search "tag:empty"))

(define-command lem-yath-notmuch-test-drafts () ()
  (notmuch-search "tag:draft"))

(define-key *global-keymap* "F1" 'lem-yath-notmuch-test-report)
(define-key *global-keymap* "F2" 'lem-yath-notmuch-test-pdf-report)
(define-key *global-keymap* "F3" 'lem-yath-notmuch-test-open)
(define-key *global-keymap* "F4" 'lem-yath-notmuch-test-empty)
(define-key *global-keymap* "F5" 'lem-yath-fetchmail)
(define-key *global-keymap* "F6" 'lem-yath-notmuch-test-compose-report)
(define-key *global-keymap* "F7" 'lem-yath-notmuch-test-address-report)
(define-key *global-keymap* "F8" 'lem-yath-notmuch-test-cleanup-report)
(define-key *global-keymap* "F9" 'lem-yath-notmuch-test-refusals)
(define-key *global-keymap* "F10" 'lem-yath-notmuch-test-attachment-report)
(define-key *global-keymap* "F11" 'lem-yath-notmuch-test-drafts)
(define-key *global-keymap* "F12" 'lem-yath-notmuch-test-draft-report)
(notmuch-test-log "EXEC notmuch=~a xdg-open=~a"
                  (executable-find "notmuch")
                  (executable-find "xdg-open"))
(notmuch-test-log "READY")
