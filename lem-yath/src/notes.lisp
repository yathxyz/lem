;;;; Notes layer: org-roam-dailies / org-journal / org-capture, reduced to
;;;; their actually-used workflows over the same on-disk layout.  Roam note
;;;; discovery and selection live separately in roam.lisp.
;;;;   $WORKDIR/roam/          dailies (%Y-%m-%d.org, no daily/ subdirectory)
;;;;   $WORKDIR/roam/journal/  org-journal (%Y%m%d.org)
;;;;   $WORKDIR/{inbox,todo,readlist}.org   capture targets
;;;;   $PUBLIC_ORG_DIR/inbox.org            public TODO capture target

(in-package :lem-yath)

(defun public-org-directory ()
  "The public notes root, mirroring $PUBLIC_ORG_DIR (default ~/public-org)."
  (uiop:ensure-directory-pathname
   (let ((configured (uiop:getenv "PUBLIC_ORG_DIR")))
     (if (and configured (plusp (length configured)))
         configured
         (merge-pathnames "public-org/" (user-homedir-pathname))))))

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

(defun inactive-org-timestamp (&optional (time (get-universal-time)))
  "Return TIME in the same minute-precision inactive form as Org's %U."
  (multiple-value-bind (sec min hour day month year day-of-week)
      (decode-universal-time time)
    (declare (ignore sec))
    (format nil "[~4,'0d-~2,'0d-~2,'0d ~a ~2,'0d:~2,'0d]"
            year month day
            (elt #("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun") day-of-week)
            hour min)))

(defun daily-note-path (date)
  "Return DATE's daily path directly under the roam root.
Signal an error before constructing a pathname unless DATE is valid YYYY-MM-DD."
  (unless (valid-iso-date-p date)
    (error "Invalid daily date (expected YYYY-MM-DD): ~s" date))
  (merge-pathnames (format nil "~a.org" date) (roam-directory)))

(defun open-daily-note (date)
  (let ((path (daily-note-path date)))
    (ensure-directories-exist path)
    (let ((new (not (uiop:probe-file* path))))
      (find-file path)
      (when new
        (insert-string (current-point) (format nil "#+title: ~a~%~%" date))))))

(define-command lem-yath-dailies-today () ()
  "Open today's daily note (org-roam-dailies-goto-today)."
  (multiple-value-bind (iso) (decoded-date-strings)
    (open-daily-note iso)))

(define-command lem-yath-dailies-date () ()
  "Open a daily note by date (org-roam-dailies-goto-date)."
  (let ((date (prompt-for-string "Date (YYYY-MM-DD): ")))
    (cond
      ((zerop (length date)))
      ((valid-iso-date-p date) (open-daily-note date))
      (t (message "Invalid date; use a real calendar date in YYYY-MM-DD form")))))

(defun open-journal-entry (&optional (time (get-universal-time)))
  "Open TIME's journal file and append its configured time heading."
  (multiple-value-bind (iso compact dow) (decoded-date-strings time)
    (let ((path (merge-pathnames (format nil "journal/~a.org" compact)
                                 (roam-directory))))
      (ensure-directories-exist path)
      (let ((new (and (not (uiop:probe-file* path))
                      (not (get-file-buffer path)))))
        (find-file path)
        (let ((buffer (current-buffer)))
          (when new
            (insert-string (current-point)
                           (format nil "#+TITLE: ~a, ~a~%" dow iso)))
          (multiple-value-bind (sec min hour) (decode-universal-time time)
            (declare (ignore sec))
            (move-point (buffer-point buffer) (buffer-end-point buffer))
            (insert-string (buffer-point buffer)
                           (format nil "~%* ~2,'0d:~2,'0d~%" hour min))))
        path))))

(define-command lem-yath-journal-new-entry () ()
  "New org-journal entry in $WORKDIR/roam/journal/%Y%m%d.org."
  (open-journal-entry))

;;; --- capture (org-capture templates i/t/p/r) -------------------------------

(defparameter *capture-templates*
  '(("i" "Inbox" :work "inbox.org" nil :inbox)
    ("t" "TODO" :work "todo.org" "TODO " :inbox)
    ("p" "Public TODO" :public "inbox.org" "TODO " :file)
    ("r" "Reading" :work "readlist.org" "TODO " :inbox))
  "Key, label, root, target file, TODO prefix, and placement for each capture.")

(defun capture-template-for-key (key)
  (assoc key *capture-templates* :test #'string=))

(defun capture-target-path (template)
  (destructuring-bind (key label root file prefix placement) template
    (declare (ignore key label prefix placement))
    (merge-pathnames file
                     (ecase root
                       (:work (workdir))
                       (:public (public-org-directory))))))

(defun org-top-level-heading-p (line)
  (and (> (length line) 1)
       (char= (char line 0) #\*)
       (member (char line 1) '(#\Space #\Tab))))

(defun exact-inbox-heading-p (line)
  (string= (string-right-trim '(#\Space #\Tab #\Return) line)
           "* Inbox"))

(defun inbox-subtree-insertion-position (contents)
  "Return where a capture belongs and whether exact top-level `* Inbox' exists."
  (let ((length (length contents))
        (inside-inbox nil)
        (start 0))
    (loop
      (let* ((newline (position #\Newline contents :start start))
             (end (or newline length))
             (line (subseq contents start end)))
        (cond
          ((and inside-inbox (org-top-level-heading-p line))
           (return (values start t)))
          ((exact-inbox-heading-p line)
           (setf inside-inbox t)))
        (unless newline
          (return (values length inside-inbox)))
        (setf start (1+ newline))))))

(defun blank-line-separator (text)
  "Return the newlines needed to put a blank line after non-empty TEXT."
  (let ((length (length text)))
    (cond
      ((zerop length) "")
      ((and (> length 1)
            (char= (char text (1- length)) #\Newline)
            (char= (char text (- length 2)) #\Newline))
       "")
      ((char= (char text (1- length)) #\Newline) (string #\Newline))
      (t (format nil "~%~%")))))

(defun append-org-fragment (contents fragment)
  (concatenate 'string contents (blank-line-separator contents) fragment))

(defun insert-in-inbox-subtree (contents entry)
  "Insert ENTRY at the end of exact top-level `* Inbox' in CONTENTS.
When the heading is absent, append it rather than using a similarly named or
tagged heading.  The result is a pure string transformation."
  (multiple-value-bind (position foundp)
      (inbox-subtree-insertion-position contents)
    (if foundp
        (let ((before (subseq contents 0 position))
              (after (subseq contents position)))
          (concatenate 'string
                       before
                       (blank-line-separator before)
                       entry
                       (if (zerop (length after)) "" (string #\Newline))
                       after))
        (append-org-fragment
         contents
         (format nil "* Inbox~%~%~a" entry)))))

(defun capture-entry-string (text prefix timestamp &key (level 2) id)
  (with-output-to-string (stream)
    (format stream "~a ~@[~a~]~a~%:PROPERTIES:~%"
            (make-string level :initial-element #\*) prefix text)
    (when id
      (format stream ":ID: ~a~%" id))
    (format stream ":CREATED: ~a~%:END:~%" timestamp)))

(defun read-file-or-empty (path)
  (if (uiop:probe-file* path)
      (alexandria:read-file-into-string path)
      ""))

(defun write-capture (key text &key
                                 (timestamp (inactive-org-timestamp))
                                 id)
  "Write TEXT using capture template KEY and return its target pathname.
TIMESTAMP and ID are injectable so the filesystem behavior can be tested
without depending on the clock or UUID generator."
  (let ((template (capture-template-for-key key)))
    (unless template
      (error "Unknown capture template: ~s" key))
    (destructuring-bind (template-key label root file prefix placement) template
      (declare (ignore template-key label root file))
      (let* ((path (capture-target-path template))
             (publicp (eq placement :file))
             (entry (capture-entry-string
                     text prefix timestamp
                     :level (if publicp 1 2)
                     :id (and publicp (or id (uuid-v4)))))
             (contents (read-file-or-empty path))
             (updated (ecase placement
                        (:inbox (insert-in-inbox-subtree contents entry))
                        (:file (append-org-fragment contents entry)))))
        (ensure-directories-exist path)
        (alexandria:write-string-into-file updated path :if-exists :supersede)
        path))))

(define-command lem-yath-capture () ()
  "Run the i/t/p/r capture workflow over work and public Org directories."
  (let* ((labels (mapcar #'second *capture-templates*))
         (choice (prompt-for-string
                  "Capture to: "
                  :completion-function (lambda (s) (prescient-filter s labels))
                  :test-function (lambda (s) (member s labels :test #'string=))))
         (template (find choice *capture-templates* :key #'second :test #'string=)))
    (unless template
      (return-from lem-yath-capture))
    (destructuring-bind (key label root file prefix placement) template
      (declare (ignore label root prefix placement))
      (let ((text (prompt-for-string "Entry: ")))
        (when (plusp (length text))
          (write-capture key text)
          (message "Captured to ~a" file))))))
