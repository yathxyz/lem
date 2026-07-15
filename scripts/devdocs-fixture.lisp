(in-package :lem-yath)

(defvar *devdocs-test-fake-bin* (uiop:getenv "LEM_YATH_DEVDOCS_FAKE_BIN"))
(setf (uiop:getenv "PATH")
      (format nil "~a:~a" *devdocs-test-fake-bin* (uiop:getenv "PATH")))

(defvar *devdocs-test-report* (uiop:getenv "LEM_YATH_DEVDOCS_REPORT"))
(defvar *devdocs-test-source-buffer* (current-buffer))
(defvar *devdocs-test-source-text* (buffer-text (current-buffer)))

(defun devdocs-test-yes-no (value) (if value "yes" "no"))

(defun devdocs-test-key-command (map keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find map (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun devdocs-test-keys-p ()
  (and
   (eq (devdocs-test-key-command *devdocs-mode-keymap* "q")
       'quit-active-window)
   (eq (devdocs-test-key-command *devdocs-mode-keymap* "b")
       'lem-yath-devdocs-open-in-browser)))

(defun devdocs-test-log (control &rest arguments)
  (with-open-file (stream *devdocs-test-report* :direction :output
                          :if-exists :append :if-does-not-exist :create)
    (apply #'format stream (concatenate 'string control "~%") arguments)))

(define-command lem-yath-devdocs-test-report () ()
  (let* ((buffer (current-buffer))
         (viewer-p (eq (buffer-major-mode buffer) 'devdocs-mode))
         (text (buffer-text buffer)))
    (devdocs-test-log
     "STATE mode=~a slug=~a path=~a generation=~a installed=~a read-only=~a keys=~a body=~a hidden=~a source-live=~a source-exact=~a"
     (if viewer-p "viewer" "other")
     (if viewer-p (or (buffer-value buffer 'devdocs-slug) "none") "none")
     (if viewer-p (or (buffer-value buffer 'devdocs-path) "none") "none")
     (if viewer-p (or (buffer-value buffer 'devdocs-generation) 0) 0)
     (devdocs-test-yes-no
      (and (member "custom" *devdocs-docsets* :test #'string=)
           (gethash "custom" *devdocs-index-cache*)))
     (devdocs-test-yes-no (buffer-read-only-p buffer))
     (devdocs-test-yes-no (devdocs-test-keys-p))
     (devdocs-test-yes-no
      (and viewer-p
           (search "decoded &" text :test #'char-equal)))
     (devdocs-test-yes-no
      (and viewer-p
           (not (search "hidden script" text))
           (not (search "hidden style" text))))
     (devdocs-test-yes-no
      (not (deleted-buffer-p *devdocs-test-source-buffer*)))
     (devdocs-test-yes-no
      (and (not (deleted-buffer-p *devdocs-test-source-buffer*))
           (string= *devdocs-test-source-text*
                    (buffer-text *devdocs-test-source-buffer*)))))))

(define-key *global-keymap* "F4" 'lem-yath-devdocs-test-report)
(define-key *global-keymap* "F5" 'lem-yath-devdocs-install)

(clrhash *devdocs-index-cache*)
(setf *devdocs-request-generation* 0)
(setf *devdocs-curl-timeout* 5)
(setf *devdocs-output-limit* (* 1024 1024))
(devdocs-test-log "EXEC curl=~a xdg-open=~a"
                  (executable-find "curl")
                  (executable-find "xdg-open"))
(devdocs-test-log "READY")
