;;;; GitHub Forge parity through the authenticated `gh' command.
;;;;
;;;; The Emacs configuration loads Forge after Magit, disables Forge's direct
;;;; bindings, and leaves its status sections enabled.  This module mirrors
;;;; that shape: explicit commands and dedicated buffers, plus a cache-backed
;;;; Legit section.  Ordinary Legit redraws never perform network I/O.

(in-package :lem-yath)

(declaim (ftype function run-project-program open-with-xdg))
(declaim (special *project-process-timeout*))

(defparameter *forge-result-limit* 50)
(defparameter *forge-output-limit* (* 2 1024 1024))
(defparameter *forge-process-timeout* 20)
(defparameter *forge-status-topic-limit* 5)

(defvar *forge-gh-program-override* nil
  "Test-only pathname/string used instead of resolving gh on PATH.")
(defvar *forge-cache* (make-hash-table :test 'equal))
(defvar *forge-list-buffer-name* "*lem-yath-forge*")
(defvar *forge-topic-buffer-name* "*lem-yath-forge-topic*")
(defvar *forge-preview-buffer-name* "*lem-yath-forge-preview*")
(defvar *forge-compose-buffer-name* "*lem-yath-forge-compose*")

(defstruct forge-topic
  kind number title author state url updated draft head base body comments)

(defstruct forge-repository
  root slug pullreqs issues fetched-at)

(defvar *forge-list-mode-keymap*
  (make-keymap :description '*forge-list-mode-keymap*))
(defvar *forge-topic-mode-keymap*
  (make-keymap :description '*forge-topic-mode-keymap*))
(defvar *forge-compose-mode-keymap*
  (make-keymap :description '*forge-compose-mode-keymap*))

(define-major-mode lem-yath-forge-list-mode nil
    (:name "Forge" :keymap *forge-list-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(define-major-mode lem-yath-forge-topic-mode nil
    (:name "Forge-Topic" :keymap *forge-topic-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(define-major-mode lem-yath-forge-compose-mode nil
    (:name "Forge-Compose" :keymap *forge-compose-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-forge-list-mode))
  (list *forge-list-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-forge-topic-mode))
  (list *forge-topic-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-forge-compose-mode))
  (list *forge-compose-mode-keymap*))

(defun forge-native-name (pathname)
  (etypecase pathname
    (pathname (uiop:native-namestring pathname))
    (string pathname)))

(defun forge-gh-program ()
  (or *forge-gh-program-override*
      (executable-find "gh")
      (editor-error "GitHub CLI (gh) is unavailable")))

(defun forge-run (root arguments &key json)
  "Run gh with direct ARGUMENTS at ROOT, returning stdout or parsed JSON."
  (let ((*project-process-timeout* *forge-process-timeout*))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (cons (forge-native-name (forge-gh-program)) arguments)
         :directory root :output-limit *forge-output-limit*)
      (unless (and (integerp status) (zerop status))
        (editor-error "gh failed (~a): ~a" status
                      (completion-bounded-annotation
                       (if (str:blankp error-output)
                           output
                           error-output))))
      (if json
          (handler-case
              (yason:parse output)
            (error (condition)
              (editor-error "gh returned invalid JSON: ~a" condition)))
          (string-trim '(#\Space #\Tab #\Newline #\Return) output)))))

(defun forge-run-git (root arguments)
  "Run Git with direct ARGUMENTS at ROOT; return trimmed stdout on success."
  (alexandria:when-let ((git (executable-find "git")))
    (let ((*project-process-timeout* 5))
      (multiple-value-bind (output error-output status)
          (run-project-program
           (cons (uiop:native-namestring git) arguments)
           :directory root :output-limit 65536)
        (declare (ignore error-output))
        (when (and (integerp status) (zerop status))
          (string-trim '(#\Space #\Tab #\Newline #\Return) output))))))

(defun forge-remote-slug (url)
  "Return OWNER/REPOSITORY for a github.com remote URL, otherwise NIL."
  (when (and url (plusp (length url)))
    (cl-ppcre:register-groups-bind (owner repository)
        ("(?i)^(?:https?://|git://|ssh://git@|git@)?github\\.com[/:]([^/]+)/([^/]+?)(?:\\.git)?/?$"
         url)
      (when (and owner repository)
        (format nil "~a/~a" owner repository)))))

(defun forge-resolve-repository-slug (root)
  "Resolve ROOT's GitHub repository from origin, then other remotes."
  (or (forge-remote-slug
       (forge-run-git root '("remote" "get-url" "origin")))
      (let ((remotes (forge-run-git root '("remote"))))
        (loop :for remote :in (and remotes
                                   (uiop:split-string remotes
                                                      :separator '(#\Newline)))
              :for url := (forge-run-git
                           root (list "remote" "get-url" remote))
              :for slug := (forge-remote-slug url)
              :when slug :return slug))
      (editor-error "No github.com remote is configured for this repository")))

(defun forge-context-root ()
  (or (alexandria:when-let
          ((repository
             (or (buffer-value (current-buffer) 'forge-repository)
                 (buffer-value (current-buffer) 'forge-compose-repository))))
        (forge-repository-root repository))
      (git-root)
      (editor-error "The current buffer is not inside a Git repository")))

(defun forge-json-string (object key)
  (let ((value (and (hash-table-p object) (gethash key object))))
    (cond ((null value) "")
          ((stringp value) value)
          (t (princ-to-string value)))))

(defun forge-json-author (object)
  (let ((author (and (hash-table-p object) (gethash "author" object))))
    (if (hash-table-p author)
        (forge-json-string author "login")
        "")))

(defun forge-json-number (object)
  (let ((value (and (hash-table-p object) (gethash "number" object))))
    (if (integerp value) value
        (or (parse-integer (princ-to-string value) :junk-allowed t) 0))))

(defun forge-topic-from-json (kind object)
  (make-forge-topic
   :kind kind
   :number (forge-json-number object)
   :title (forge-json-string object "title")
   :author (forge-json-author object)
   :state (forge-json-string object "state")
   :url (forge-json-string object "url")
   :updated (forge-json-string object "updatedAt")
   :draft (and (gethash "isDraft" object) t)
   :head (forge-json-string object "headRefName")
   :base (forge-json-string object "baseRefName")
   :body (forge-json-string object "body")
   :comments (gethash "comments" object)))

(defun forge-list-json (root slug kind)
  (let ((noun (if (eq kind :pullreq) "pr" "issue"))
        (fields (if (eq kind :pullreq)
                    "number,title,author,state,isDraft,url,updatedAt,headRefName,baseRefName"
                    "number,title,author,state,url,updatedAt")))
    (mapcar (lambda (object) (forge-topic-from-json kind object))
            (forge-run
             root
             (list noun "list" "--repo" slug "--state" "open"
                   "--limit" (princ-to-string *forge-result-limit*)
                   "--json" fields)
             :json t))))

(defun forge-fetch (root)
  "Fetch open pull requests and issues for ROOT and replace its cache entry."
  (let* ((root (uiop:ensure-directory-pathname (truename root)))
         (key (uiop:native-namestring root))
         (slug (forge-resolve-repository-slug root))
         (repository
           (make-forge-repository
            :root root :slug slug
            :pullreqs (forge-list-json root slug :pullreq)
            :issues (forge-list-json root slug :issue)
            :fetched-at (get-universal-time))))
    (setf (gethash key *forge-cache*) repository)
    repository))

(defun forge-cached-repository (root)
  (when root
    (gethash (uiop:native-namestring
              (uiop:ensure-directory-pathname (truename root)))
             *forge-cache*)))

(defun forge-topics-for-view (repository view)
  (ecase view
    (:pullreqs (forge-repository-pullreqs repository))
    (:issues (forge-repository-issues repository))
    (:all (append (forge-repository-pullreqs repository)
                  (forge-repository-issues repository)))))

(defun forge-topic-label (topic)
  (format nil "~a #~d"
          (if (eq (forge-topic-kind topic) :pullreq) "PR" "Issue")
          (forge-topic-number topic)))

(defun forge-topic-line (topic)
  (format nil "~7a  #~5d [~a]~:[~; [DRAFT]~] ~a~@[ — ~a~]"
          (if (eq (forge-topic-kind topic) :pullreq) "PR" "Issue")
          (forge-topic-number topic)
          (string-upcase (forge-topic-state topic))
          (forge-topic-draft topic)
          (forge-topic-title topic)
          (unless (str:blankp (forge-topic-author topic))
            (forge-topic-author topic))))

(defun forge-find-topic-line (buffer kind number)
  (let ((rows (buffer-value buffer 'forge-topic-rows)))
    (when (hash-table-p rows)
      (loop :for line :being :the :hash-keys :of rows
              :using (hash-value topic)
            :when (and (eq kind (forge-topic-kind topic))
                       (= number (forge-topic-number topic)))
              :return line))))

(defun forge-render-list (buffer repository view &optional selected)
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (let ((point (buffer-point buffer))
          (rows (make-hash-table :test 'eql))
          (topics (forge-topics-for-view repository view)))
      (insert-string point
                     (format nil "GitHub Forge: ~a~%View: ~a   ~d open topic~:p~%~%"
                             (forge-repository-slug repository)
                             (string-downcase (symbol-name view))
                             (length topics)))
      (dolist (topic topics)
        (setf (gethash (line-number-at-point point) rows) topic)
        (insert-string point (format nil "~a~%" (forge-topic-line topic))))
      (when (null topics)
        (insert-string point (format nil "<no open topics>~%")))
      (insert-string point
                     (format nil
                             "~%P pull requests  I issues  a all  g refresh  Return inspect  ? help~%"))
      (setf (buffer-value buffer 'forge-repository) repository
            (buffer-value buffer 'forge-view) view
            (buffer-value buffer 'forge-topic-rows) rows
            (buffer-directory buffer) (forge-repository-root repository))
      (buffer-start point)
      (let ((line (and selected
                       (forge-find-topic-line buffer
                                              (car selected) (cdr selected)))))
        (when line
          (move-to-line point line)))))
  (change-buffer-mode buffer 'lem-yath-forge-list-mode)
  (buffer-unmark buffer)
  (setf (buffer-read-only-p buffer) t)
  buffer)

(defun forge-topic-at-point (&optional (buffer (current-buffer)))
  (let ((rows (buffer-value buffer 'forge-topic-rows)))
    (and (hash-table-p rows)
         (gethash (line-number-at-point (buffer-point buffer)) rows))))

(defun forge-move-topic (direction)
  (let* ((point (current-point))
         (rows (buffer-value (current-buffer) 'forge-topic-rows))
         (line (line-number-at-point point))
         (lines (and (hash-table-p rows)
                     (sort (loop :for key :being :the :hash-keys :of rows
                                 :collect key)
                           #'<)))
         (target (if (plusp direction)
                     (find-if (lambda (candidate) (> candidate line)) lines)
                     (car (last (remove-if-not
                                 (lambda (candidate) (< candidate line))
                                 lines))))))
    (when target (move-to-line point target))))

(define-command lem-yath-forge-next-topic () () (forge-move-topic 1))
(define-command lem-yath-forge-previous-topic () () (forge-move-topic -1))

(defun forge-show-list (root view &key refresh)
  (let* ((repository (if refresh
                         (forge-fetch root)
                         (or (forge-cached-repository root)
                             (forge-fetch root))))
         (buffer (make-buffer *forge-list-buffer-name*)))
    (forge-render-list buffer repository view)
    (switch-to-window (pop-to-buffer buffer))
    (forge-move-topic 1)
    repository))

(define-command lem-yath-forge () ()
  "Open cached/fetched GitHub pull requests and issues for this repository."
  (forge-show-list (forge-context-root) :all))

(define-command lem-yath-forge-list-pullreqs () ()
  (forge-show-list (forge-context-root) :pullreqs))

(define-command lem-yath-forge-list-issues () ()
  (forge-show-list (forge-context-root) :issues))

(defun forge-switch-view (view)
  (let ((repository (buffer-value (current-buffer) 'forge-repository)))
    (if repository
        (progn
          (forge-render-list (current-buffer) repository view)
          (forge-move-topic 1))
        (editor-error "This is not a Forge list buffer"))))

(define-command lem-yath-forge-show-pullreqs () ()
  (forge-switch-view :pullreqs))
(define-command lem-yath-forge-show-issues () ()
  (forge-switch-view :issues))
(define-command lem-yath-forge-show-all () () (forge-switch-view :all))

(define-command lem-yath-forge-refresh () ()
  "Explicitly fetch Forge topics and preserve the selected topic and view."
  (let* ((buffer (current-buffer))
         (repository (buffer-value buffer 'forge-repository))
         (view (or (buffer-value buffer 'forge-view) :all))
         (topic (forge-topic-at-point buffer))
         (selected (and topic
                        (cons (forge-topic-kind topic)
                              (forge-topic-number topic)))))
    (unless repository (editor-error "This is not a Forge list buffer"))
    (let ((updated (forge-fetch (forge-repository-root repository))))
      (forge-render-list buffer updated view selected)
      (message "Fetched ~d pull request~:p and ~d issue~:p"
               (length (forge-repository-pullreqs updated))
               (length (forge-repository-issues updated))))))

(defun forge-topic-view-json (repository topic)
  (let ((noun (if (eq (forge-topic-kind topic) :pullreq) "pr" "issue"))
        (fields (if (eq (forge-topic-kind topic) :pullreq)
                    "number,title,body,author,state,url,comments,isDraft,headRefName,baseRefName,updatedAt"
                    "number,title,body,author,state,url,comments,updatedAt")))
    (forge-topic-from-json
     (forge-topic-kind topic)
     (forge-run (forge-repository-root repository)
                (list noun "view" (princ-to-string (forge-topic-number topic))
                      "--repo" (forge-repository-slug repository)
                      "--json" fields)
                :json t))))

(defun forge-format-comment (comment)
  (format nil "~%--- ~a · ~a ---~%~a~%"
          (forge-json-author comment)
          (forge-json-string comment "createdAt")
          (forge-json-string comment "body")))

(defun forge-render-topic (buffer repository topic &key preview)
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (let ((point (buffer-point buffer)))
      (insert-string
       point
       (format nil "~a: ~a~%State: ~a~:[~; · draft~]~%Author: ~a~%URL: ~a~%~:[~;Branches: ~a -> ~a~%~]~%~a~%"
               (forge-topic-label topic) (forge-topic-title topic)
               (forge-topic-state topic) (forge-topic-draft topic)
               (forge-topic-author topic) (forge-topic-url topic)
               (eq (forge-topic-kind topic) :pullreq)
               (forge-topic-head topic) (forge-topic-base topic)
               (forge-topic-body topic)))
      (dolist (comment (forge-topic-comments topic))
        (insert-string point (forge-format-comment comment)))
      (unless preview
        (insert-string point
                       (format nil
                               "~%r comment  s close/reopen  b browser  g refresh  q quit~%")))
      (setf (buffer-value buffer 'forge-repository) repository
            (buffer-value buffer 'forge-topic) topic
            (buffer-directory buffer) (forge-repository-root repository))
      (buffer-start point)))
  (change-buffer-mode buffer 'lem-yath-forge-topic-mode)
  (buffer-unmark buffer)
  (setf (buffer-read-only-p buffer) t)
  buffer)

(define-command lem-yath-forge-open-topic () ()
  (let* ((repository (buffer-value (current-buffer) 'forge-repository))
         (topic (forge-topic-at-point)))
    (unless (and repository topic) (editor-error "No Forge topic on this row"))
    (let ((full (forge-topic-view-json repository topic))
          (buffer (make-buffer *forge-topic-buffer-name*)))
      (forge-render-topic buffer repository full)
      (switch-to-window (pop-to-buffer buffer)))))

(define-command lem-yath-forge-topic-refresh () ()
  (let* ((buffer (current-buffer))
         (repository (buffer-value buffer 'forge-repository))
         (topic (buffer-value buffer 'forge-topic)))
    (unless (and repository topic) (editor-error "This is not a Forge topic buffer"))
    (forge-render-topic buffer repository
                        (forge-topic-view-json repository topic))))

(define-command lem-yath-forge-browse () ()
  (let ((topic (or (forge-topic-at-point)
                   (buffer-value (current-buffer) 'forge-topic))))
    (if (and topic (not (str:blankp (forge-topic-url topic))))
        (open-with-xdg (forge-topic-url topic))
        (editor-error "No Forge topic URL at point"))))

(defun forge-compose-open (repository action &optional topic)
  (let ((buffer (make-buffer *forge-compose-buffer-name*)))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (change-buffer-mode buffer 'lem-yath-forge-compose-mode)
      (let ((point (buffer-point buffer)))
        (ecase action
          ((:issue :pullreq)
           (insert-string point (format nil "Title: ~%---~%")))
          (:comment
           (insert-string point
                          (format nil "Comment on ~a~%---~%"
                                  (forge-topic-label topic)))))
        (setf (buffer-value buffer 'forge-compose-repository) repository
              (buffer-value buffer 'forge-compose-action) action
              (buffer-value buffer 'forge-compose-topic) topic
              (buffer-directory buffer) (forge-repository-root repository))
        (buffer-start point)
        (if (member action '(:issue :pullreq))
            (progn
              (move-to-line point 1)
              (line-end point))
            (buffer-end point))))
    (buffer-unmark buffer)
    (switch-to-window (pop-to-buffer buffer))
    (message "Write the body, then C-c C-c to submit or C-c C-k to cancel")))

(defun forge-compose-parts (buffer)
  (let* ((text (buffer-text buffer))
         (separator (format nil "~%---~%"))
         (marker (search separator text)))
    (unless marker (editor-error "Compose separator (---) is missing"))
    (values (subseq text 0 marker)
            (subseq text (+ marker (length separator))))))

(defun forge-close-compose (buffer)
  (buffer-unmark buffer)
  (delete-buffer buffer))

(define-command lem-yath-forge-compose-submit () ()
  (let* ((buffer (current-buffer))
         (repository (buffer-value buffer 'forge-compose-repository))
         (action (buffer-value buffer 'forge-compose-action))
         (topic (buffer-value buffer 'forge-compose-topic)))
    (unless (and repository action) (editor-error "This is not a Forge composition"))
    (multiple-value-bind (heading body) (forge-compose-parts buffer)
      (let ((root (forge-repository-root repository))
            (slug (forge-repository-slug repository)))
        (ecase action
          ((:issue :pullreq)
           (let ((title (string-trim
                         '(#\Space #\Tab)
                         (if (str:starts-with-p "Title:" heading)
                             (subseq heading 6)
                             heading))))
             (when (str:blankp title) (editor-error "A title is required"))
             (forge-run root
                        (list (if (eq action :pullreq) "pr" "issue")
                              "create" "--repo" slug
                              "--title" title "--body" body))))
          (:comment
           (when (str:blankp body) (editor-error "A comment body is required"))
           (forge-run root
                      (list (if (eq (forge-topic-kind topic) :pullreq)
                                "pr" "issue")
                            "comment" (princ-to-string (forge-topic-number topic))
                            "--repo" slug "--body" body))))
        (forge-fetch root)
        (forge-close-compose buffer)
        (message "Forge submission completed")))))

(define-command lem-yath-forge-compose-cancel () ()
  (let ((buffer (current-buffer)))
    (when (or (not (buffer-modified-p buffer))
              (prompt-for-y-or-n-p "Discard this Forge composition?"))
      (forge-close-compose buffer))))

(defun forge-current-repository-and-topic ()
  (let ((repository (buffer-value (current-buffer) 'forge-repository))
        (topic (or (forge-topic-at-point)
                   (buffer-value (current-buffer) 'forge-topic))))
    (unless (and repository topic) (editor-error "No Forge topic at point"))
    (values repository topic)))

(define-command lem-yath-forge-comment () ()
  (multiple-value-bind (repository topic)
      (forge-current-repository-and-topic)
    (forge-compose-open repository :comment topic)))

(define-command lem-yath-forge-create-issue () ()
  (let* ((root (forge-context-root))
         (repository (or (forge-cached-repository root) (forge-fetch root))))
    (forge-compose-open repository :issue)))

(define-command lem-yath-forge-create-pullreq () ()
  (let* ((root (forge-context-root))
         (repository (or (forge-cached-repository root) (forge-fetch root))))
    (forge-compose-open repository :pullreq)))

(define-command lem-yath-forge-toggle-state () ()
  (multiple-value-bind (repository topic)
      (forge-current-repository-and-topic)
    (let* ((open-p (string-equal "OPEN" (forge-topic-state topic)))
           (verb (if open-p "close" "reopen"))
           (noun (if (eq (forge-topic-kind topic) :pullreq) "pr" "issue")))
      (when (or (not open-p)
                (prompt-for-y-or-n-p
                 (format nil "Close ~a?" (forge-topic-label topic))))
        (forge-run (forge-repository-root repository)
                   (list noun verb (princ-to-string (forge-topic-number topic))
                         "--repo" (forge-repository-slug repository)))
        (setf (forge-topic-state topic) (if open-p "CLOSED" "OPEN"))
        (forge-fetch (forge-repository-root repository))
        (when (eq (buffer-major-mode (current-buffer))
                  'lem-yath-forge-topic-mode)
          (forge-render-topic (current-buffer) repository topic))
        (message "~a ~a" (string-capitalize verb) (forge-topic-label topic))))))

(define-command lem-yath-forge-help () ()
  (message
   "Forge: C-j/C-k or j/k move; Return inspect; P/I/a views; g refresh; r comment; s state; b browser; c i/c p create; q quit"))

(define-key *forge-list-mode-keymap* "C-j" 'lem-yath-forge-next-topic)
(define-key *forge-list-mode-keymap* "C-k" 'lem-yath-forge-previous-topic)
(define-key *forge-list-mode-keymap* "j" 'lem-yath-forge-next-topic)
(define-key *forge-list-mode-keymap* "k" 'lem-yath-forge-previous-topic)
(define-key *forge-list-mode-keymap* "Return" 'lem-yath-forge-open-topic)
(define-key *forge-list-mode-keymap* "P" 'lem-yath-forge-show-pullreqs)
(define-key *forge-list-mode-keymap* "I" 'lem-yath-forge-show-issues)
(define-key *forge-list-mode-keymap* "a" 'lem-yath-forge-show-all)
(define-key *forge-list-mode-keymap* "g" 'lem-yath-forge-refresh)
(define-key *forge-list-mode-keymap* "r" 'lem-yath-forge-comment)
(define-key *forge-list-mode-keymap* "s" 'lem-yath-forge-toggle-state)
(define-key *forge-list-mode-keymap* "b" 'lem-yath-forge-browse)
(define-key *forge-list-mode-keymap* "c i" 'lem-yath-forge-create-issue)
(define-key *forge-list-mode-keymap* "c p" 'lem-yath-forge-create-pullreq)
(define-key *forge-list-mode-keymap* "?" 'lem-yath-forge-help)
(define-key *forge-list-mode-keymap* "q" 'quit-active-window)

(define-key *forge-topic-mode-keymap* "g" 'lem-yath-forge-topic-refresh)
(define-key *forge-topic-mode-keymap* "r" 'lem-yath-forge-comment)
(define-key *forge-topic-mode-keymap* "s" 'lem-yath-forge-toggle-state)
(define-key *forge-topic-mode-keymap* "b" 'lem-yath-forge-browse)
(define-key *forge-topic-mode-keymap* "?" 'lem-yath-forge-help)
(define-key *forge-topic-mode-keymap* "q" 'quit-active-window)

(define-key *forge-compose-mode-keymap* "C-c C-c"
  'lem-yath-forge-compose-submit)
(define-key *forge-compose-mode-keymap* "C-c C-k"
  'lem-yath-forge-compose-cancel)

(defun forge-make-preview-function (repository topic)
  (lambda ()
    (let ((buffer (make-buffer *forge-preview-buffer-name*)))
      (forge-render-topic buffer repository topic :preview t)
      (buffer-point buffer))))

(defun insert-legit-forge-section (vcs collector)
  "Append cached GitHub topics to Legit without doing network I/O."
  (declare (ignore collector))
  (when (string-equal "git" (lem/porcelain::vcs-name vcs))
    (let* ((root (ignore-errors
                   (uiop:ensure-directory-pathname (truename (uiop:getcwd)))))
           (repository (and root (forge-cached-repository root))))
      (lem/legit::collector-insert "")
      (if repository
          (let* ((pullreqs (forge-repository-pullreqs repository))
                 (issues (forge-repository-issues repository))
                 (topics (append pullreqs issues)))
            (lem/legit::collector-insert
             (format nil "Forge (~d pull request~:p, ~d issue~:p; cached):"
                     (length pullreqs) (length issues))
             :header t)
            (if topics
                (dolist (topic (subseq topics 0
                                      (min (length topics)
                                           *forge-status-topic-limit*)))
                  (lem/legit::with-appending-source
                      (point :move-function
                             (forge-make-preview-function repository topic))
                    (insert-string point (forge-topic-line topic)
                                   :read-only t)))
                (lem/legit::collector-insert "<no open topics>")))
          (progn
            (lem/legit::collector-insert "Forge (not fetched):" :header t)
            (lem/legit::collector-insert
             "Run M-x lem-yath-forge to fetch pull requests and issues."))))))

(remove-hook lem/legit::*status-section-functions*
             'insert-legit-forge-section)
(add-hook lem/legit::*status-section-functions*
          'insert-legit-forge-section)
