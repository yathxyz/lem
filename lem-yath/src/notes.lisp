;;;; Notes layer: org-roam / org-roam-dailies / org-journal / org-capture,
;;;; reduced to their actually-used workflows over the same on-disk layout:
;;;;   $WORKDIR/roam/          org+md notes (roam, incl. md-roam)
;;;;   $WORKDIR/roam/daily/    dailies (%Y-%m-%d.org)
;;;;   $WORKDIR/roam/journal/  org-journal (%Y%m%d.org)
;;;;   $WORKDIR/{inbox,todo,readlist}.org   capture targets

(in-package :lem-yath)

(defun roam-directory ()
  (uiop:ensure-directory-pathname (merge-pathnames "roam/" (workdir))))

(defun note-files ()
  "Relative paths of all org/md notes under the roam directory.
Uses fd when available (as org-roam did), else find."
  (let* ((root (roam-directory))
         (command (if (executable-find "fd")
                      (list "fd" "--type" "f" "--extension" "org" "--extension" "md"
                            "." (namestring root))
                      (list "find" (namestring root)
                            "-name" "*.org" "-o" "-name" "*.md")))
         (output (ignore-errors
                   (uiop:run-program command :output :string
                                             :ignore-error-status t))))
    (loop :for line :in (uiop:split-string (or output "") :separator (string #\Newline))
          :for trimmed := (string-trim " " line)
          :unless (or (zerop (length trimmed))
                      (search ".sync-conflict-" trimmed))
            :collect (enough-namestring trimmed root))))

(defun prompt-for-note (prompt)
  (let ((files (note-files)))
    (unless files
      (message "No notes found under ~a" (roam-directory))
      (return-from prompt-for-note nil))
    (prompt-for-string prompt
                       :completion-function (lambda (s) (orderless-filter s files))
                       :test-function (lambda (s) (plusp (length s)))
                       :history-symbol 'lem-yath-roam)))

(define-command lem-yath-roam-find () ()
  "Find/open a roam note (org-roam-node-find)."
  (alexandria:when-let ((choice (prompt-for-note "Roam node: ")))
    (find-file (merge-pathnames choice (roam-directory)))))

(define-command lem-yath-roam-random () ()
  "Open a random roam note (org-roam-node-random)."
  (let ((files (note-files)))
    (if files
        (find-file (merge-pathnames (elt files (random (length files)))
                                    (roam-directory)))
        (message "No notes found under ~a" (roam-directory)))))

(define-command lem-yath-roam-insert () ()
  "Insert a link to a roam note (org-roam-node-insert).
Org-style link in .org buffers, markdown-style otherwise."
  (alexandria:when-let ((choice (prompt-for-note "Insert link to: ")))
    (let* ((title (pathname-name (pathname choice)))
           (file (ignore-errors (buffer-filename (current-buffer))))
           (org-p (and file (string-equal "org" (pathname-type (pathname file))))))
      (insert-string (current-point)
                     (if org-p
                         (format nil "[[file:~a][~a]]" choice title)
                         (format nil "[~a](~a)" title choice))))))

;;; --- Org heading IDs -------------------------------------------------------

(defun uuid-v4 ()
  (format nil "~8,'0x-~4,'0x-~4,'0x-~4,'0x-~12,'0x"
          (random (ash 1 32))
          (random (ash 1 16))
          (logior #x4000 (random #x1000))
          (logior #x8000 (random #x4000))
          (random (ash 1 48))))

(defun org-heading-point ()
  "Return the current or nearest preceding Org heading."
  (with-point ((point (current-point)))
    (line-start point)
    (loop
      (when (cl-ppcre:scan "^\\*+\\s+" (line-string point))
        (return (copy-point point :temporary)))
      (unless (line-offset point -1)
        (return nil)))))

(defun org-property-id (drawer-start)
  "Return the ID in the property drawer at DRAWER-START, if present."
  (with-point ((point drawer-start))
    (loop
      (let ((line (line-string point)))
        (when (alexandria:starts-with-subseq ":ID:" line)
          (return (string-trim '(#\Space #\Tab) (subseq line 4))))
        (when (string= line ":END:")
          (return nil)))
      (unless (line-offset point 1)
        (return nil)))))

(defun org-property-drawer-end (drawer-start)
  (with-point ((point drawer-start))
    (loop
      (when (string= (line-string point) ":END:")
        (return (copy-point point :temporary)))
      (unless (line-offset point 1)
        (return nil)))))

(define-command lem-yath-org-id-get-create () ()
  "Return or create an :ID: property on the current Org heading."
  (alexandria:if-let ((heading (org-heading-point)))
    (with-point ((drawer heading))
      (unless (line-offset drawer 1)
        (line-end drawer)
        (insert-character drawer #\Newline))
      (line-start drawer)
      (cond
        ((string= (line-string drawer) ":PROPERTIES:")
         (alexandria:if-let ((existing (org-property-id drawer)))
           (message "Org ID: ~a" existing)
           (alexandria:if-let ((end (org-property-drawer-end drawer)))
             (let ((id (uuid-v4)))
               (insert-string end (format nil ":ID: ~a~%" id))
               (message "Created Org ID: ~a" id))
             (message "Malformed Org property drawer: missing :END:"))))
        (t
         (let ((id (uuid-v4)))
           (insert-string drawer
                          (format nil ":PROPERTIES:~%:ID: ~a~%:END:~%" id))
           (message "Created Org ID: ~a" id)))))
    (message "No Org heading at point")))

;;; --- dailies & journal ------------------------------------------------------

(defun decoded-date-strings (&optional (time (get-universal-time)))
  (multiple-value-bind (sec min hour day month year day-of-week)
      (decode-universal-time time)
    (declare (ignore sec min hour))
    (values (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)
            (format nil "~4,'0d~2,'0d~2,'0d" year month day)
            (elt #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun") day-of-week))))

(define-command lem-yath-dailies-today () ()
  "Open today's daily note (org-roam-dailies-goto-today)."
  (multiple-value-bind (iso) (decoded-date-strings)
    (let ((path (merge-pathnames (format nil "daily/~a.org" iso) (roam-directory))))
      (ensure-directories-exist path)
      (let ((new (not (uiop:probe-file* path))))
        (find-file path)
        (when new
          (insert-string (current-point) (format nil "#+title: ~a~%~%" iso)))))))

(define-command lem-yath-dailies-date () ()
  "Open a daily note by date (org-roam-dailies-goto-date)."
  (let ((date (prompt-for-string "Date (YYYY-MM-DD): ")))
    (when (plusp (length date))
      (let ((path (merge-pathnames (format nil "daily/~a.org" date) (roam-directory))))
        (ensure-directories-exist path)
        (let ((new (not (uiop:probe-file* path))))
          (find-file path)
          (when new
            (insert-string (current-point) (format nil "#+title: ~a~%~%" date))))))))

(define-command lem-yath-journal-new-entry () ()
  "New org-journal entry in $WORKDIR/roam/journal/%Y%m%d.org."
  (multiple-value-bind (iso compact dow) (decoded-date-strings)
    (let ((path (merge-pathnames (format nil "journal/~a.org" compact)
                                 (roam-directory))))
      (ensure-directories-exist path)
      (let ((new (not (uiop:probe-file* path))))
        (find-file path)
        (let ((buffer (current-buffer)))
          (when new
            (insert-string (current-point)
                           (format nil "#+TITLE: ~a, ~a~%" dow iso)))
          (multiple-value-bind (sec min hour) (decode-universal-time (get-universal-time))
            (declare (ignore sec))
            (move-point (buffer-point buffer) (buffer-end-point buffer))
            (insert-string (buffer-point buffer)
                           (format nil "~%* ~2,'0d:~2,'0d~%" hour min))))))))

;;; --- capture (org-capture templates i/t/r) ----------------------------------

(defparameter *capture-templates*
  '(("inbox" "inbox.org" nil)
    ("todo" "todo.org" "TODO ")
    ("reading" "readlist.org" "TODO "))
  "Template name, target file under $WORKDIR, optional TODO prefix.")

(define-command lem-yath-capture () ()
  "Capture a line into inbox/todo/readlist under \"* Inbox\" (org-capture)."
  (let* ((names (mapcar #'first *capture-templates*))
         (choice (prompt-for-string
                  "Capture to: "
                  :completion-function (lambda (s) (orderless-filter s names))
                  :test-function (lambda (s) (member s names :test #'string=))))
         (template (assoc choice *capture-templates* :test #'string=)))
    (unless template
      (return-from lem-yath-capture))
    (destructuring-bind (name file prefix) template
      (declare (ignore name))
      (let ((text (prompt-for-string "Entry: ")))
        (when (plusp (length text))
          (multiple-value-bind (iso) (decoded-date-strings)
            (let ((path (merge-pathnames file (workdir))))
              (ensure-directories-exist path)
              (unless (uiop:probe-file* path)
                (alexandria:write-string-into-file (format nil "* Inbox~%") path))
              (with-open-file (s path :direction :output :if-exists :append)
                (format s "** ~@[~a~]~a~%:PROPERTIES:~%:CREATED: [~a]~%:END:~%"
                        prefix text iso))
              (message "Captured to ~a" file))))))))
