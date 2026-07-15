(in-package :lem-yath)

(defvar *forge-test-report* (uiop:getenv "LEM_YATH_FORGE_REPORT"))
(defvar *forge-test-root*
  (uiop:ensure-directory-pathname (uiop:getenv "LEM_YATH_FORGE_ROOT")))
(defvar *forge-test-source-buffer* (current-buffer))

(setf *forge-gh-program-override* (uiop:getenv "LEM_YATH_FORGE_FAKE_GH"))

(defun forge-test-yes-no (value) (if value "yes" "no"))

(defun forge-test-encode (value)
  (with-output-to-string (stream)
    (loop :for character :across (or value "")
          :do (case character
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (#\Space (write-char #\_ stream))
                (otherwise (write-char character stream))))))

(defun forge-test-key-command (map keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find map (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun forge-test-keys-p ()
  (and
   (every (lambda (binding)
            (eq (second binding)
                (forge-test-key-command *forge-list-mode-keymap*
                                        (first binding))))
          '(("C-j" lem-yath-forge-next-topic)
            ("C-k" lem-yath-forge-previous-topic)
            ("Return" lem-yath-forge-open-topic)
            ("P" lem-yath-forge-show-pullreqs)
            ("I" lem-yath-forge-show-issues)
            ("a" lem-yath-forge-show-all)
            ("g" lem-yath-forge-refresh)
            ("r" lem-yath-forge-comment)
            ("s" lem-yath-forge-toggle-state)
            ("c i" lem-yath-forge-create-issue)
            ("c p" lem-yath-forge-create-pullreq)))
   (eq (forge-test-key-command *forge-compose-mode-keymap* "C-c C-c")
       'lem-yath-forge-compose-submit)))

(defun forge-test-log (control &rest arguments)
  (with-open-file (stream *forge-test-report* :direction :output
                          :if-exists :append :if-does-not-exist :create)
    (apply #'format stream (concatenate 'string control "~%") arguments)))

(define-command lem-yath-forge-test-report () ()
  (let* ((buffer (current-buffer))
         (mode (buffer-major-mode buffer))
         (repository (or (buffer-value buffer 'forge-repository)
                         (buffer-value buffer 'forge-compose-repository)))
         (topic (or (forge-topic-at-point buffer)
                    (buffer-value buffer 'forge-topic)
                    (buffer-value buffer 'forge-compose-topic)))
         (action (buffer-value buffer 'forge-compose-action)))
    (forge-test-log
     "STATE mode=~a view=~a topic=~a state=~a action=~a cache=~a read-only=~a keys=~a source-live=~a"
     (cond ((eq mode 'lem-yath-forge-list-mode) "list")
           ((eq mode 'lem-yath-forge-topic-mode) "topic")
           ((eq mode 'lem-yath-forge-compose-mode) "compose")
           (t "other"))
     (let ((view (buffer-value buffer 'forge-view)))
       (if view (string-downcase (symbol-name view)) "none"))
     (if topic
         (format nil "~a-~d"
                 (string-downcase (symbol-name (forge-topic-kind topic)))
                 (forge-topic-number topic))
         "none")
     (if topic (string-downcase (forge-topic-state topic)) "none")
     (if action (string-downcase (symbol-name action)) "none")
     (forge-test-yes-no repository)
     (forge-test-yes-no (buffer-read-only-p buffer))
     (forge-test-yes-no (forge-test-keys-p))
     (forge-test-yes-no (not (deleted-buffer-p *forge-test-source-buffer*))))))

(define-command lem-yath-forge-test-status () ()
  (call-with-vcs-buffer-directory
   *forge-test-root*
   (lambda () (lem-yath-legit-status)))
  (let* ((buffer (and (lem/legit::legit-status-active-p)
                      (window-buffer lem/legit::*peek-window*)))
         (text (and buffer (buffer-text buffer)))
         (row (and buffer (buffer-start-point buffer))))
    (when row
      (unless (search-forward row "PR") (setf row nil))
      (when row (line-start row)))
    (forge-test-log
     "STATUS cached=~a topic=~a preview=~a hook=~d"
     (forge-test-yes-no (and text (search "Forge (" text)))
     (forge-test-yes-no (and text (search "PR" text)))
     (forge-test-yes-no (and row (lem/legit::get-move-function row)))
     (count 'insert-legit-forge-section
            lem/legit::*status-section-functions* :key #'car :test #'eq))))

(define-command lem-yath-forge-test-open () ()
  (handler-case
      (lem-yath-forge)
    (error (condition)
      (forge-test-log "OPEN-ERROR ~a" condition)
      (error condition))))

(define-key *global-keymap* "F1" 'lem-yath-forge-test-report)
(define-key *global-keymap* "F2" 'lem-yath-forge-test-status)
(define-key *global-keymap* "F3" 'lem-yath-forge-test-open)

(forge-test-log "READY")
