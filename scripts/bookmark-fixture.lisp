(in-package :lem-yath)

(defvar *bookmark-test-report*
  (uiop:getenv "LEM_YATH_BOOKMARK_TEST_REPORT"))

(defvar *bookmark-test-phase*
  (or (uiop:getenv "LEM_YATH_BOOKMARK_TEST_PHASE") "unknown"))

(defvar *bookmark-test-bookmarks-source*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_BOOKMARKS_SOURCE")))

(defvar *bookmark-test-persistence-source*
  (uiop:parse-native-namestring
   (uiop:getenv "LEM_YATH_PERSISTENCE_SOURCE")))

(defun bookmark-test-log (control &rest arguments)
  (with-open-file (stream *bookmark-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun bookmark-test-entry-description (entry)
  (format nil "~a@~a@~a"
          (first entry)
          (file-namestring (second entry))
          (or (third entry) "none")))

(defun bookmark-test-record (label)
  (let ((point (current-point)))
    (bookmark-test-log
     "BOOKMARKS phase=~a label=~a entries=~{~a~^|~} file=~a line=~d column=~d position=~d"
     *bookmark-test-phase*
     label
     (mapcar #'bookmark-test-entry-description
             (bookmark-persistence-snapshot))
     (if (buffer-filename (current-buffer))
         (file-namestring (buffer-filename (current-buffer)))
         "none")
     (line-number-at-point point)
     (point-column point)
     (position-at-point point))))

(define-command lem-yath-test-bookmark-record () ()
  (bookmark-test-record "record"))

(define-command lem-yath-test-bookmark-writer-a () ()
  (let ((seed (gethash "seed" lem-bookmark::*bookmark-table*)))
    (when seed
      (setf (lem-bookmark:bookmark-position seed)
            (position-at-point (current-point))))
    (lem-bookmark::%bookmark-insert "only-a" (current-buffer))
    (flush-persistence-state :record-places nil)
    (bookmark-test-record "writer-a")))

(define-command lem-yath-test-bookmark-writer-b () ()
  (alexandria:when-let ((seed
                         (gethash "seed" lem-bookmark::*bookmark-table*)))
    (lem-bookmark::%bookmark-delete seed))
  (lem-bookmark::%bookmark-insert "only-b" (current-buffer))
  (flush-persistence-state :record-places nil)
  (bookmark-test-record "writer-b"))

(define-command lem-yath-test-bookmark-reload () ()
  (load *bookmark-test-bookmarks-source*)
  (load *bookmark-test-persistence-source*)
  (load *bookmark-test-bookmarks-source*)
  (load *bookmark-test-persistence-source*)
  (bookmark-test-log
   "RELOAD exit-hooks=~d baseline=~a live=~a"
   (count 'persistence-exit-hook *exit-editor-hook*
          :key #'car :test #'eq)
   (if (equal *bookmark-persistence-baseline*
              (bookmark-persistence-snapshot))
       "stable"
       "changed")
   (mapcar #'bookmark-test-entry-description
           (bookmark-persistence-snapshot))))

(define-command lem-yath-test-bookmark-clear-prompt () ()
  (lem/prompt-window::replace-prompt-input ""))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F5" 'lem-yath-test-bookmark-record)
  (define-key keymap "F6" 'lem-yath-test-bookmark-writer-a)
  (define-key keymap "F7" 'lem-yath-test-bookmark-writer-b)
  (define-key keymap "F8" 'lem-yath-test-bookmark-reload))

(define-key lem/prompt-window::*prompt-mode-keymap*
  "F4" 'lem-yath-test-bookmark-clear-prompt)

(bookmark-test-log "READY phase=~a" *bookmark-test-phase*)
