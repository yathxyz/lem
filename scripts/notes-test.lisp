(with-open-file (out (uiop:getenv "LEM_YATH_NOTES_REPORT")
                     :direction :output
                     :if-exists :supersede
                     :if-does-not-exist :create)
  (let ((failures 0)
        (stamp "[2026-07-10 Fri 09:30]"))
    (labels ((check (condition label)
               (format out "~a ~a~%" (if condition "PASS" "FAIL") label)
               (unless condition (incf failures)))
             (contents (path)
               (alexandria:read-file-into-string path))
             (rejected-date-p (date)
               (handler-case
                   (progn (lem-yath::daily-note-path date) nil)
                 (error () t))))
      (handler-case
          (progn
            (let* ((fixture-root
                     (uiop:pathname-parent-directory-pathname
                      (lem-yath::workdir)))
                   (base (merge-pathnames "resolution-base/" fixture-root))
                   (absolute (merge-pathnames "absolute-notes/" fixture-root))
                   (missing (merge-pathnames "missing-notes/" fixture-root))
                   (home-work (merge-pathnames
                               "work/" (user-homedir-pathname)))
                   (home-notes (merge-pathnames
                                "notes/" (user-homedir-pathname))))
              (ensure-directories-exist (merge-pathnames ".keep" base))
              (ensure-directories-exist (merge-pathnames ".keep" absolute))
              (check (string= (namestring (lem-yath::resolve-workdir nil base))
                              (namestring home-work))
                     "unset-workdir-falls-back-to-home-work")
              (check (string= (namestring (lem-yath::resolve-workdir "" base))
                              (namestring home-work))
                     "empty-workdir-falls-back-to-home-work")
              (check (string=
                      (namestring (lem-yath::resolve-workdir "notes" base))
                      (namestring (merge-pathnames "notes/" base)))
                     "relative-workdir-resolves-against-launch-directory")
              (check (string=
                      (namestring
                       (lem-yath::resolve-workdir (namestring absolute) base))
                      (namestring absolute))
                     "absolute-workdir-remains-absolute")
              (check (string=
                      (namestring (lem-yath::resolve-workdir "~/notes" base))
                      (namestring home-notes))
                     "tilde-workdir-expands-against-home")
              (check (not (uiop:directory-exists-p missing))
                     "nonexistent-workdir-starts-absent")
              (check (string=
                      (namestring
                       (lem-yath::resolve-workdir (namestring missing) base))
                      (namestring missing))
                     "nonexistent-workdir-resolves-without-creation")
              (check (not (uiop:directory-exists-p missing))
                     "workdir-resolution-does-not-create-directory")
              (check (string=
                      (namestring (lem-yath::workdir))
                      (namestring
                       (uiop:ensure-directory-pathname
                        (uiop:getenv "WORKDIR"))))
                     "runtime-workdir-matches-absolute-environment")
              (check (eq (lem-yath::workdir) lem-yath::*workdir*)
                     "runtime-workdir-is-cached")
              (let ((original (uiop:getenv "WORKDIR")))
                (unwind-protect
                     (progn
                       (setf (uiop:getenv "WORKDIR") "")
                       (check (string= "~/work"
                                       (lem-yath::configured-workdir))
                              "empty-configured-workdir-uses-fallback")
                       (check (string= "~/work" (uiop:getenv "WORKDIR"))
                              "fallback-is-exported-for-subprocesses"))
                  (setf (uiop:getenv "WORKDIR") original))))

            (check (lem-yath::valid-iso-date-p "2024-02-29")
                   "leap-day-valid")
            (check (every #'rejected-date-p
                          '("2023-02-29" "2026-02-30" "2026-13-01"
                            "2026-7-10" " 2026-07-10" "../../etc/x"
                            "2026-07-10/evil"))
                   "invalid-and-unsafe-dates-rejected")
            (let ((daily (lem-yath::daily-note-path "2024-02-29")))
              (check (string= (namestring daily)
                              (namestring
                               (merge-pathnames "roam/2024-02-29.org"
                                                (lem-yath::workdir))))
                     "daily-directly-under-roam")
              (check (null (search "/roam/daily/" (namestring daily)))
                     "no-daily-subdirectory"))
            (check (cl-ppcre:scan
                    "^\\[[0-9]{4}-[0-9]{2}-[0-9]{2} (Mon|Tue|Wed|Thu|Fri|Sat|Sun) [0-9]{2}:[0-9]{2}\\]$"
                    (lem-yath::inactive-org-timestamp))
                   "inactive-timestamp-has-weekday-and-time")

            (let* ((time (encode-universal-time 0 30 9 10 7 2026))
                   (expected
                     (merge-pathnames "roam/journal/20260710.org"
                                      (lem-yath::workdir)))
                   (first (lem-yath::open-journal-entry time))
                   (buffer (lem:current-buffer)))
              (check (uiop:pathname-equal first expected)
                     "journal-uses-compact-date-path")
              (check (uiop:pathname-equal (lem:buffer-filename buffer) expected)
                     "journal-visits-configured-file")
              (check (search "#+TITLE: Fri, 2026-07-10"
                             (lem:buffer-text buffer))
                     "journal-title-matches-configured-format")
              (check (= 1 (cl-ppcre:count-matches
                           "(?m)^\\* 09:30$" (lem:buffer-text buffer)))
                     "journal-appends-time-heading")
              (lem-yath::open-journal-entry time)
              (check (= 1 (cl-ppcre:count-matches
                           "(?m)^#\\+TITLE:" (lem:buffer-text buffer)))
                     "journal-reuse-does-not-duplicate-title")
              (check (= 2 (cl-ppcre:count-matches
                           "(?m)^\\* 09:30$" (lem:buffer-text buffer)))
                     "journal-reuse-appends-another-entry"))

            (dolist (keymap (list lem-vi-mode:*normal-keymap*
                                  lem-vi-mode:*visual-keymap*))
              (check (eq 'lem-yath::lem-yath-journal-new-entry
                         (lem-yath::leader-binding-command keymap "n j j"))
                     "journal-leader-binding"))

            (let ((inbox (merge-pathnames "inbox.org" (lem-yath::workdir))))
              (alexandria:write-string-into-file
               (format nil "#+title: existing~%* Inbox~%intro~%** Existing child~%body~%* Later~%later body~%")
               inbox :if-exists :supersede)
              (lem-yath::write-capture "i" "Inbox item" :timestamp stamp)
              (let* ((text (contents inbox))
                     (entry (search "** Inbox item" text))
                     (later (search "* Later" text)))
                (check (and entry later (< entry later))
                       "inbox-entry-before-next-top-level-heading")
                (check (search ":CREATED: [2026-07-10 Fri 09:30]" text)
                       "inbox-created-timestamp")))

            (let ((todo (merge-pathnames "todo.org" (lem-yath::workdir))))
              (alexandria:write-string-into-file
               (format nil "* Inboxish~%wrong~%* Inbox :tag:~%also wrong~%")
               todo :if-exists :supersede)
              (lem-yath::write-capture "t" "Task item" :timestamp stamp)
              (let ((text (contents todo)))
                (check (search (format nil "* Inbox~%~%** TODO Task item") text)
                       "missing-exact-inbox-created")
                (check (= 1 (cl-ppcre:count-matches "(?m)^\\* Inbox$" text))
                       "exact-inbox-created-once")))

            (let ((reading (merge-pathnames "readlist.org"
                                            (lem-yath::workdir))))
              (alexandria:write-string-into-file
               (format nil "* Inbox~%reading notes~%* Archive~%old~%")
               reading :if-exists :supersede)
              (lem-yath::write-capture "r" "Book item" :timestamp stamp)
              (let* ((text (contents reading))
                     (entry (search "** TODO Book item" text))
                     (archive (search "* Archive" text)))
                (check (and entry archive (< entry archive))
                       "reading-entry-inside-inbox")))

            (let ((public (lem-yath::write-capture
                           "p" "Public item" :timestamp stamp)))
              (let ((text (contents public)))
                (check (string= (namestring public)
                                (namestring
                                 (merge-pathnames "inbox.org"
                                                  (lem-yath::public-org-directory))))
                       "public-target-directory")
                (check (cl-ppcre:scan "(?m)^\\* TODO Public item$" text)
                       "public-entry-is-top-level-todo")
                (check (cl-ppcre:scan
                        "(?m)^:ID: [0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$"
                        text)
                       "public-entry-has-generated-uuid")
                (check (search ":CREATED: [2026-07-10 Fri 09:30]" text)
                       "public-entry-has-created")))

            (check (not (uiop:directory-exists-p
                         (merge-pathnames "roam/daily/"
                                          (lem-yath::workdir))))
                   "tests-created-no-legacy-daily-directory"))
        (error (condition)
          (format out "FAIL unhandled-error: ~a~%" condition)
          (incf failures)))
      (format out "SUMMARY ~a (~d failure~:p)~%"
              (if (zerop failures) "PASS" "FAIL") failures))))

(in-package :lem-yath)

(defvar *notes-test-origin*
  (pathname (uiop:getenv "LEM_YATH_NOTES_ORIGIN")))

(defun notes-test-report (control &rest arguments)
  (with-open-file (stream (uiop:getenv "LEM_YATH_NOTES_REPORT")
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun notes-test-fixed-time ()
  (encode-universal-time 0 30 9 10 7 2026))

(defun notes-test-fixed-id ()
  "12345678-1234-4123-8123-123456789abc")

(defun notes-test-file-text (pathname)
  (if (uiop:probe-file* pathname)
      (alexandria:read-file-into-string pathname)
      ""))

(defun notes-test-count (needle text)
  (loop :with count := 0
        :for start := (search needle text)
          :then (search needle text :start2 (+ start (length needle)))
        :while start
        :do (incf count)
        :finally (return count)))

(defun notes-test-yes-no (value)
  (if value "yes" "no"))

(defun notes-test-state-name ()
  (or (lem-vi-mode/core::state-name
       (lem-vi-mode/core:buffer-state (current-buffer)))
      "none"))

(defun notes-test-hook-count (buffer function)
  (if (and buffer (not (deleted-buffer-p buffer)))
      (count function (variable-value 'kill-buffer-hook :buffer buffer)
             :test #'eq
             :key (lambda (entry) (if (consp entry) (car entry) entry)))
      0))

(define-command lem-yath-test-notes-reset-origin () ()
  (find-file *notes-test-origin*)
  (buffer-start (current-point))
  (unless (search-forward-regexp (current-point) "SELECTED")
    (error "Notes capture origin marker is missing."))
  (search-backward (current-point) "SELECTED")
  (setf (lem-vi-mode/core:buffer-state) 'lem-vi-mode/states:normal)
  (notes-test-report "ORIGIN line=~d column=~d state=~a"
                     (line-number-at-point (current-point))
                     (point-charpos (current-point))
                     (notes-test-state-name)))

(define-command lem-yath-test-notes-capture-state () ()
  (let* ((request lem-yath::*org-capture-request*)
         (session lem-yath::*org-capture-session*)
         (capture (and session
                       (lem-yath::org-capture-session-capture-buffer session)))
         (text (if capture (lem:buffer-text capture) ""))
         (origin (cond
                   (request
                    (lem-yath::org-capture-request-origin-buffer request))
                   (session
                   (lem-yath::org-capture-request-origin-buffer
                     (lem-yath::org-capture-session-request session)))))
         (template (and session
                        (lem-yath::org-capture-session-template session))))
    (notes-test-report
     "CAPTURE request=~a session=~a key=~a current=~a line=~d column=~d state=~a mode=~a title=~a initial=~a annotation=~a origin-hook=~d capture-hook=~d"
     (notes-test-yes-no request)
     (notes-test-yes-no session)
     (if template (first template) "none")
     (buffer-name (current-buffer))
     (line-number-at-point (current-point))
     (point-charpos (current-point))
     (notes-test-state-name)
     (notes-test-yes-no
      (and capture
           (mode-active-p capture 'lem-yath::lem-yath-org-capture-mode)))
     (notes-test-yes-no (search "Captured task" text))
     (notes-test-yes-no (search "SELECTED" text))
     (notes-test-yes-no
      (search "::2][source.org:2]]" text))
     (notes-test-hook-count origin
                            'lem-yath::org-capture-origin-kill-buffer-hook)
     (notes-test-hook-count capture
                            'lem-yath::org-capture-buffer-kill-hook))))

(define-command lem-yath-test-notes-target-state () ()
  (let* ((todo (notes-test-file-text
                (merge-pathnames "todo.org" (lem-yath::workdir))))
         (inbox (notes-test-file-text
                 (merge-pathnames "inbox.org" (lem-yath::workdir))))
         (public (notes-test-file-text
                  (merge-pathnames "inbox.org"
                                   (lem-yath::public-org-directory))))
         (capture (and lem-yath::*org-capture-session*
                       (lem-yath::org-capture-session-capture-buffer
                        lem-yath::*org-capture-session*))))
    (notes-test-report
     "TARGET todo=~d inbox=~d public=~d selected=~d annotation=~d id=~d request=~a session=~a capture-live=~a current=~a line=~d state=~a"
     (notes-test-count "Captured task" todo)
     (notes-test-count "Aborted item" inbox)
     (notes-test-count "Public context" public)
     (notes-test-count "SELECTED" public)
     (+ (notes-test-count "::2][source.org:2]]" todo)
        (notes-test-count "::2][source.org:2]]" public))
     (notes-test-count "12345678-1234-4123-8123-123456789abc" public)
     (notes-test-yes-no lem-yath::*org-capture-request*)
     (notes-test-yes-no lem-yath::*org-capture-session*)
     (notes-test-yes-no
      (and capture (not (deleted-buffer-p capture))))
     (buffer-name (current-buffer))
     (line-number-at-point (current-point))
     (notes-test-state-name))))

(define-command lem-yath-test-notes-reload () ()
  (load (merge-pathnames "src/org-capture.lisp"
                         (asdf:system-source-directory "lem-yath")))
  (let ((capture (and *org-capture-session*
                      (org-capture-session-capture-buffer
                       *org-capture-session*))))
    (notes-test-report
     "RELOAD request=~a session=~a capture-live=~a current=~a line=~d state=~a origin-hook=~d"
     (notes-test-yes-no *org-capture-request*)
     (notes-test-yes-no *org-capture-session*)
     (notes-test-yes-no
      (and capture (not (deleted-buffer-p capture))))
     (buffer-name (current-buffer))
     (line-number-at-point (current-point))
     (notes-test-state-name)
     (notes-test-hook-count (current-buffer)
                            'org-capture-origin-kill-buffer-hook))))

(define-command lem-yath-test-notes-toggle-occupied-capture () ()
  (alexandria:if-let
      ((buffer (find *org-capture-buffer-name* (buffer-list)
                     :key #'buffer-name :test #'string=)))
    (progn
      (delete-buffer buffer)
      (notes-test-report "OCCUPIED live=no sentinel=no"))
    (let ((buffer (make-buffer *org-capture-buffer-name*)))
      (insert-string (buffer-start-point buffer) "USER SENTINEL")
      (notes-test-report "OCCUPIED live=yes sentinel=~a"
                         (notes-test-yes-no
                          (search "USER SENTINEL" (buffer-text buffer)))))))

(setf lem-yath::*org-capture-time-function* #'notes-test-fixed-time
      lem-yath::*org-capture-id-function* #'notes-test-fixed-id)

(define-key *global-keymap* "F5" 'lem-yath-test-notes-reset-origin)
(define-key *global-keymap* "F6" 'lem-yath-test-notes-capture-state)
(define-key *global-keymap* "F7" 'lem-yath-test-notes-target-state)
(define-key *global-keymap* "F8" 'lem-yath-test-notes-reload)
(define-key *global-keymap* "F9" 'lem-yath-test-notes-toggle-occupied-capture)

(lem-yath-test-notes-reset-origin)
(notes-test-report "READY boot=~a"
                   (notes-test-yes-no (lem-yath::boot-ok-p)))
