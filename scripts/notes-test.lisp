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
