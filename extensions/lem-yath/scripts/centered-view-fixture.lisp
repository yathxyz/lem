(in-package :lem-yath)

(defvar *centered-view-test-report*
  (uiop:getenv "LEM_YATH_CENTERED_VIEW_REPORT"))

(defun centered-view-test-log (control &rest arguments)
  (with-open-file (stream *centered-view-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun centered-view-test-windows (buffer)
  (sort (remove-if-not (lambda (window)
                         (eq buffer (window-buffer window)))
                       (window-list))
        #'<
        :key #'window-x))

(defun centered-view-test-record (label)
  (redraw-display :force t)
  (let* ((buffer (current-buffer))
         (windows (centered-view-test-windows buffer)))
    (centered-view-test-log
     "CENTER label=~a active=~a wrap=~a target=~d windows=~d geometry=~{~d:~d:~d:~d~^,~}"
     label
     (if (mode-active-p buffer 'centered-view-mode) "yes" "no")
     (if (variable-value 'line-wrap :default buffer) "yes" "no")
     *centered-view-width*
     (length windows)
     (mapcan (lambda (window)
               (list (window-width window)
                     (window-left-width window)
                     (window-right-width window)
                     (lem-core::window-body-width window)))
             windows))))

(define-command lem-yath-test-centered-view-state () ()
  (let ((windows (centered-view-test-windows (current-buffer))))
    (cond
      ((> (length windows) 1)
       (call-command 'lem-core/commands/window:delete-other-windows nil)
       (centered-view-test-record "unsplit"))
      (t
       (centered-view-test-record "state")))))

(define-command lem-yath-test-centered-view-width-80 () ()
  (setf *centered-view-width* 80)
  (centered-view-mark-visible-windows (current-buffer))
  (centered-view-test-record "width-80"))

(define-command lem-yath-test-centered-view-width-100 () ()
  (setf *centered-view-width* 100)
  (centered-view-mark-visible-windows (current-buffer))
  (centered-view-test-record "width-100")
  (split-window-vertically (current-window))
  (centered-view-test-record "split"))

(define-command lem-yath-test-centered-view-reload () ()
  (load (merge-pathnames "src/centered-view.lisp"
                         (asdf:system-source-directory "lem-yath")))
  (centered-view-test-record "reload"))

(define-key lem-vi-mode:*normal-keymap* "F5"
  'lem-yath-test-centered-view-state)
(define-key lem-vi-mode:*normal-keymap* "F6"
  'lem-yath-test-centered-view-width-80)
(define-key lem-vi-mode:*normal-keymap* "F7"
  'lem-yath-test-centered-view-width-100)
(define-key lem-vi-mode:*normal-keymap* "F8"
  'lem-yath-test-centered-view-reload)
(centered-view-test-log "READY")
