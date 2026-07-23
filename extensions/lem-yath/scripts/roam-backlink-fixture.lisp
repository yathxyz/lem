(in-package :lem-yath)

(defvar *roam-backlink-test-report*
  (or (uiop:getenv "LEM_YATH_ROAM_BACKLINK_REPORT")
      (error "LEM_YATH_ROAM_BACKLINK_REPORT is unset")))

(defun roam-backlink-test-log (control &rest arguments)
  (with-open-file (stream *roam-backlink-test-report*
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :append)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun roam-backlink-test-yes-no (value)
  (if value "yes" "no"))

(defun roam-backlink-test-occurrences (snapshot id)
  (gethash id (roam-backlink-snapshot-backlinks snapshot)))

(defun roam-backlink-test-owner-ids (occurrences)
  (mapcar (lambda (occurrence)
            (roam-node-id
             (roam-backlink-occurrence-source-node occurrence)))
          occurrences))

(defun roam-backlink-test-run-static ()
  (let* ((buffers-before (length (buffer-list)))
         (snapshot (roam-backlink-build-snapshot))
         (buffers-after (length (buffer-list)))
         (target (roam-backlink-test-occurrences snapshot "target-id"))
         (reflinks
           (gethash "target-id" (roam-backlink-snapshot-reflinks snapshot)))
         (child (roam-backlink-test-occurrences snapshot "child-id"))
         (heading
           (find "source-heading-id" target :test #'string=
                 :key (lambda (occurrence)
                        (roam-node-id
                         (roam-backlink-occurrence-source-node occurrence))))))
    (roam-backlink-test-log
     "STATIC target=~d child=~d reflinks=~d owners=~{~a~^,~} ref-owners=~{~a~^,~} child-owner=~a no-buffers=~a"
     (length target)
     (length child)
     (length reflinks)
     (roam-backlink-test-owner-ids target)
     (roam-backlink-test-owner-ids reflinks)
     (and child
          (roam-node-id
           (roam-backlink-occurrence-source-node (first child))))
     (roam-backlink-test-yes-no (= buffers-before buffers-after)))
    (roam-backlink-test-log
     "STATIC-DETAIL heading-outline=~s heading-preview=~a decoy=~a alias=~a"
     (and heading (roam-backlink-occurrence-outline heading))
     (roam-backlink-test-yes-no
      (and heading
           (search "Heading preview"
                   (roam-backlink-occurrence-preview heading))))
     (roam-backlink-test-yes-no
      (some (lambda (occurrence)
              (search "decoy" (roam-backlink-occurrence-link-text occurrence)
                      :test #'char-equal))
            target))
     (roam-backlink-test-yes-no
      (find "markdown-source-id" (roam-backlink-test-owner-ids target)
            :test #'string=)))))

(defun roam-backlink-test-panel ()
  (get-buffer *roam-backlink-buffer-name*))

(defun roam-backlink-test-side-window ()
  (frame-rightside-window (current-frame)))

(defun roam-backlink-test-current-occurrence-count (panel)
  (let* ((snapshot (buffer-value panel 'lem-yath-roam-backlink-snapshot))
         (key (buffer-value panel 'lem-yath-roam-backlink-target-key))
         (id (and (consp key) (first key))))
    (if (and snapshot (stringp id))
        (length (gethash id (roam-backlink-snapshot-backlinks snapshot)))
        0)))

(defun roam-backlink-test-current-reflink-count (panel)
  (let* ((snapshot (buffer-value panel 'lem-yath-roam-backlink-snapshot))
         (key (buffer-value panel 'lem-yath-roam-backlink-target-key))
         (id (and (consp key) (first key))))
    (if (and snapshot (stringp id))
        (length (gethash id (roam-backlink-snapshot-reflinks snapshot)))
        0)))

(define-command lem-yath-test-backlink-report-panel () ()
  (let* ((panel (roam-backlink-test-panel))
         (window (roam-backlink-test-side-window))
         (key (and panel
                   (buffer-value panel 'lem-yath-roam-backlink-target-key))))
    (roam-backlink-test-log
     "PANEL live=~a visible=~a width=~a display=~d target=~a occurrences=~d reflinks=~d"
     (roam-backlink-test-yes-no (roam-backlink-buffer-live-p panel))
     (roam-backlink-test-yes-no
      (and panel window (eq panel (window-buffer window))))
     (if window (window-width window) "none")
     (display-width)
     (if (and (consp key) (stringp (first key))) (first key) "none")
     (if panel (roam-backlink-test-current-occurrence-count panel) 0)
     (if panel (roam-backlink-test-current-reflink-count panel) 0)))
  (message "Backlink panel reported"))

(defun roam-backlink-test-origin-window ()
  (alexandria:when-let ((panel (roam-backlink-test-panel)))
    (buffer-value panel 'lem-yath-roam-backlink-origin-window)))

(defun roam-backlink-test-switch-to-origin ()
  (let ((window (roam-backlink-test-origin-window)))
    (unless (and window (member window (window-list) :test #'eq))
      (error "No live backlink origin window"))
    (switch-to-window window)
    window))

(defun roam-backlink-test-find-text (text)
  (let ((point (current-point)))
    (buffer-start point)
    (unless (search-forward-regexp point (cl-ppcre:quote-meta-chars text))
      (error "Backlink test text not found: ~s" text))
    point))

(define-command lem-yath-test-backlink-goto-target () ()
  (roam-backlink-test-switch-to-origin)
  (find-file (merge-pathnames "target.org" (roam-directory)))
  (buffer-start (current-point))
  (message "Backlink target file node"))

(define-command lem-yath-test-backlink-goto-child () ()
  (roam-backlink-test-switch-to-origin)
  (find-file (merge-pathnames "target.org" (roam-directory)))
  (move-point (current-point) (roam-backlink-test-find-text "Child body"))
  (message "Backlink child node"))

(defun roam-backlink-test-first-property-point (buffer property)
  (with-point ((point (buffer-start-point buffer))
               (end (buffer-end-point buffer)))
    (loop :while (point< point end)
          :when (text-property-at point property)
            :do (return (copy-point point :temporary))
          :do (character-offset point 1))))

(define-command lem-yath-test-backlink-select-first () ()
  (let ((window (roam-backlink-test-side-window))
        (panel (roam-backlink-test-panel)))
    (unless (and window panel (eq panel (window-buffer window)))
      (error "Backlink panel is not visible"))
    (switch-to-window window)
    (alexandria:if-let ((point
                         (roam-backlink-test-first-property-point
                          panel :roam-backlink)))
      (progn
        (move-point (current-point) point)
        (message "First backlink selected"))
      (error "No rendered backlink occurrence"))))

(define-command lem-yath-test-backlink-select-first-reflink () ()
  (let ((window (roam-backlink-test-side-window))
        (panel (roam-backlink-test-panel)))
    (unless (and window panel (eq panel (window-buffer window)))
      (error "Backlink panel is not visible"))
    (switch-to-window window)
    (alexandria:if-let ((point
                         (roam-backlink-test-first-property-point
                          panel :roam-reflink)))
      (progn
        (move-point (current-point) point)
        (message "First reflink selected"))
      (error "No rendered reflink occurrence"))))

(define-command lem-yath-test-backlink-report-origin () ()
  (let* ((panel (roam-backlink-test-panel))
         (window (and panel
                      (buffer-value panel
                                    'lem-yath-roam-backlink-origin-window)))
         (buffer (and window (window-buffer window)))
         (point (and buffer (buffer-point buffer))))
    (roam-backlink-test-log
     "ORIGIN file=~a line=~a column=~a text=~s"
     (if (and buffer (buffer-filename buffer))
         (file-namestring (buffer-filename buffer))
         "none")
     (if point (line-number-at-point point) "none")
     (if point (point-charpos point) "none")
     (if point (line-string point) "")))
  (message "Backlink origin reported"))

(define-command lem-yath-test-backlink-edit-and-save () ()
  (roam-backlink-test-switch-to-origin)
  (find-file (merge-pathnames "markdown.md" (roam-directory)))
  (let* ((literal "[[Target Alias]]")
         (replacement "[[Child Target]]")
         (start (roam-backlink-test-find-text literal))
         (end (copy-point start :temporary)))
    (character-offset start (- (length literal)))
    (delete-between-points start end)
    (insert-string start replacement)
    (save-buffer (current-buffer)))
  (message "Backlink source changed and saved"))

(define-command lem-yath-test-backlink-foreign-ownership () ()
  (let ((panel (roam-backlink-test-panel))
        (foreign (make-buffer "*backlink-foreign-side*" :enable-undo-p nil)))
    (with-buffer-read-only foreign nil
      (erase-buffer foreign)
      (insert-string (buffer-end-point foreign) "Foreign side window"))
    (make-rightside-window foreign :width 24)
    (roam-backlink-close-panel panel)
    (let ((window (roam-backlink-test-side-window)))
      (roam-backlink-test-log
       "FOREIGN retained=~a"
       (roam-backlink-test-yes-no
        (and window (eq foreign (window-buffer window))))))
    (roam-backlink-test-switch-to-origin)
    (org-roam-buffer-toggle)
    (roam-backlink-test-log
     "FOREIGN-REOPEN visible=~a"
     (roam-backlink-test-yes-no
      (roam-backlink-panel-visible-p panel))))
  (message "Foreign side ownership reported"))

(define-command lem-yath-test-backlink-report-closed () ()
  (roam-backlink-test-log
   "CLOSED side=~a panel-visible=~a"
   (roam-backlink-test-yes-no (roam-backlink-test-side-window))
   (roam-backlink-test-yes-no
    (roam-backlink-panel-visible-p (roam-backlink-test-panel))))
  ;; Reopen through the real command only after the closed state is captured,
  ;; leaving a live panel for the subsequent reload-cleanup assertion.
  (org-roam-buffer-toggle)
  (message "Backlink closed state reported and panel reopened"))

(define-command lem-yath-test-backlink-reload-cleanup () ()
  (roam-backlink-reload-cleanup)
  (roam-backlink-test-log
   "RELOAD side=~a panel-live=~a post-hook=~a save-hook=~a"
   (roam-backlink-test-yes-no (roam-backlink-test-side-window))
   (roam-backlink-test-yes-no
    (roam-backlink-buffer-live-p (roam-backlink-test-panel)))
   (roam-backlink-test-yes-no
    (member 'roam-backlink-post-command *post-command-hook*))
   (roam-backlink-test-yes-no
    (member 'roam-backlink-after-save
            (variable-value 'after-save-hook :global t))))
  (message "Backlink reload cleanup reported"))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*
                      *lem-yath-roam-backlink-mode-keymap*
                      *lem-yath-roam-backlink-vi-keymap*))
  (define-key keymap "F5" 'lem-yath-test-backlink-report-panel)
  (define-key keymap "F3" 'lem-yath-test-backlink-select-first-reflink)
  (define-key keymap "F4" 'lem-yath-test-backlink-edit-and-save)
  (define-key keymap "F6" 'lem-yath-test-backlink-goto-child)
  (define-key keymap "F7" 'lem-yath-test-backlink-goto-target)
  (define-key keymap "F8" 'lem-yath-test-backlink-select-first)
  (define-key keymap "F9" 'lem-yath-test-backlink-report-origin)
  (define-key keymap "F10" 'lem-yath-test-backlink-foreign-ownership)
  (define-key keymap "F11" 'lem-yath-test-backlink-report-closed)
  (define-key keymap "F12" 'lem-yath-test-backlink-reload-cleanup))

(roam-backlink-test-run-static)
