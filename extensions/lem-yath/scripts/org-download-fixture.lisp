(in-package :lem-yath)

(let ((directory (uiop:getenv "LEM_YATH_ORG_DOWNLOAD_TEST_BIN")))
  (when (and directory (plusp (length directory)))
    (setf (uiop:getenv "PATH")
          (format nil "~a:~a" directory (or (uiop:getenv "PATH") "")))))

(defvar *org-download-test-report*
  (uiop:getenv "LEM_YATH_ORG_DOWNLOAD_REPORT"))
(defvar *org-download-test-serial* 0)
(defvar *org-download-test-time*
  (encode-universal-time 56 34 12 16 7 2026))

(setf *org-download-now-function* (lambda () *org-download-test-time*)
      *org-download-byte-limit* 1024
      *org-download-process-timeout* 5)

(defun org-download-test-log (control &rest arguments)
  (with-open-file (stream *org-download-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun org-download-test-goto (text)
  (with-point ((point (buffer-start-point (current-buffer))))
    (unless (search-forward point text)
      (error "Missing Org download fixture row: ~a" text))
    (unless (line-offset point 1)
      (error "Missing insertion line after Org download fixture row: ~a" text))
    (line-start point)
    (move-point (current-point) point)))

(defun org-download-test-push (text)
  (lem/common/killring:push-killring-item (current-killring) text))

(defun org-download-test-buffer ()
  (window-buffer (current-window)))

(defun org-download-test-buffer-text (buffer)
  (points-to-string (buffer-start-point buffer)
                    (buffer-end-point buffer)))

(defun org-download-test-encode (text)
  (with-output-to-string (output)
    (loop :for character :across text
          :do (case character
                (#\\ (write-string "\\\\" output))
                (#\Newline (write-string "\\n" output))
                (#\Return (write-string "\\r" output))
                (#\Tab (write-string "\\t" output))
                (otherwise (write-char character output))))))

(define-command lem-yath-test-org-download-goto-yank () ()
  (org-download-test-goto "Yank insertion point"))

(define-command lem-yath-test-org-download-goto-clipboard () ()
  (org-download-test-goto "Clipboard insertion point"))

(define-command lem-yath-test-org-download-valid-url () ()
  (org-download-test-push (uiop:getenv "LEM_YATH_ORG_DOWNLOAD_URL")))

(define-command lem-yath-test-org-download-local-url () ()
  (incf *org-download-test-time*)
  (org-download-test-push (uiop:getenv "LEM_YATH_ORG_DOWNLOAD_FILE_URL")))

(define-command lem-yath-test-org-download-bad-image () ()
  (incf *org-download-test-time*)
  (org-download-test-push "https://images.example/not-image.png"))

(define-command lem-yath-test-org-download-large-image () ()
  (incf *org-download-test-time*)
  (org-download-test-push "https://images.example/large.png"))

(define-command lem-yath-test-org-download-invalid-kill () ()
  (org-download-test-push "this is not a URL"))

(define-command lem-yath-test-org-download-use-xclip () ()
  (setf (uiop:getenv "XDG_SESSION_TYPE") "x11")
  (incf *org-download-test-time*))

(define-command lem-yath-test-org-download-read-only () ()
  (setf (buffer-read-only-p (current-buffer)) t))

(define-command lem-yath-test-org-download-writable () ()
  (setf (buffer-read-only-p (current-buffer)) nil))

(define-command lem-yath-test-org-download-report () ()
  (let ((buffer (org-download-test-buffer)))
    (incf *org-download-test-serial*)
    (org-download-test-log
     "STATE serial=~d modified=~a readonly=~a text=~a"
     *org-download-test-serial*
     (if (buffer-modified-p buffer) "yes" "no")
     (if (buffer-read-only-p buffer) "yes" "no")
     (org-download-test-encode (org-download-test-buffer-text buffer)))))

(define-command lem-yath-test-org-download-commands () ()
  (org-download-test-log
   "COMMANDS yank=~a clipboard=~a"
   (if (get-command 'org-download-yank) "yes" "no")
   (if (get-command 'org-download-clipboard) "yes" "no")))

(define-key lem-vi-mode:*normal-keymap* "F2"
  'lem-yath-test-org-download-goto-yank)
(define-key lem-vi-mode:*normal-keymap* "F3"
  'lem-yath-test-org-download-goto-clipboard)
(define-key lem-vi-mode:*normal-keymap* "F4"
  'lem-yath-test-org-download-report)
(define-key lem-vi-mode:*normal-keymap* "F5"
  'lem-yath-test-org-download-valid-url)
(define-key lem-vi-mode:*normal-keymap* "F6"
  'lem-yath-test-org-download-bad-image)
(define-key lem-vi-mode:*normal-keymap* "F7"
  'lem-yath-test-org-download-local-url)
(define-key lem-vi-mode:*normal-keymap* "F8"
  'lem-yath-test-org-download-use-xclip)
(define-key lem-vi-mode:*normal-keymap* "F9"
  'lem-yath-test-org-download-large-image)
(define-key lem-vi-mode:*normal-keymap* "F10"
  'lem-yath-test-org-download-invalid-kill)
(define-key lem-vi-mode:*normal-keymap* "F12"
  'lem-yath-test-org-download-commands)
(define-key lem-vi-mode:*normal-keymap* "C-c z r"
  'lem-yath-test-org-download-read-only)
(define-key lem-vi-mode:*normal-keymap* "C-c z w"
  'lem-yath-test-org-download-writable)

(org-download-test-log "READY")
