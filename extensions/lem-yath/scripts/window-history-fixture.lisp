(in-package :lem-yath)

(defvar *window-history-test-report*
  (uiop:getenv "LEM_YATH_WINDOW_HISTORY_REPORT"))

(defvar *window-history-test-buffer-b* nil)
(defvar *window-history-test-buffer-c* nil)

(defun window-history-test-log (control &rest arguments)
  (with-open-file (stream *window-history-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun window-history-test-buffer (name marker)
  (let ((buffer (or (get-buffer name) (make-buffer name))))
    (with-current-buffer buffer
      (when (point= (buffer-start-point buffer) (buffer-end-point buffer))
        (insert-string
         (buffer-start-point buffer)
         (with-output-to-string (stream)
           (dotimes (line 24)
             (format stream "~a line ~2,'0d~%" marker (1+ line)))))))
    buffer))

(defun window-history-test-tree (tree)
  (if (lem-core::window-tree-leaf-p tree)
      (buffer-name (window-buffer tree))
      (format nil "~a(~a,~a)"
              (if (eq (lem-core::window-node-split-type tree) :hsplit)
                  "H" "V")
              (window-history-test-tree (lem-core::window-node-left tree))
              (window-history-test-tree (lem-core::window-node-right tree)))))

(defun window-history-test-binding (keys)
  (let ((command (find-keybind (lem-core::parse-keyspec keys))))
    (if (symbolp command) (symbol-name command) (princ-to-string command))))

(defun window-history-test-state (label)
  (let* ((frame (current-frame))
         (windows (window-list frame))
         (history (ensure-window-layout-history frame)))
    (window-history-test-log
     "STATE label=~a tree=~a selected=~a windows=~d geometry=~{~a~^,~} points=~{~a~^,~} undo=~d redo=~d hook=~d left=~a right=~a"
     label
     (window-history-test-tree (lem-core::frame-window-tree frame))
     (buffer-name (window-buffer (current-window)))
     (length windows)
     (mapcar (lambda (window)
               (format nil "~a:~d:~d:~d:~d"
                       (buffer-name (window-buffer window))
                       (window-x window)
                       (window-y window)
                       (window-width window)
                       (window-height window)))
             windows)
     (mapcar (lambda (window)
               (format nil "~a:~d:~d"
                       (buffer-name (window-buffer window))
                       (position-at-point (window-point window))
                       (position-at-point (window-view-point window))))
             windows)
     (length (window-layout-history-undo history))
     (length (window-layout-history-redo history))
     (count 'record-current-window-layout *post-command-hook* :key #'car)
     (window-history-test-binding "C-c Left")
     (window-history-test-binding "C-c Right"))))

(define-command lem-yath-test-window-history-report () ()
  (window-history-test-state "report"))

(define-command lem-yath-test-window-history-buffer-b () ()
  (switch-to-buffer *window-history-test-buffer-b*))

(define-command lem-yath-test-window-history-buffer-c () ()
  (switch-to-buffer *window-history-test-buffer-c*))

(define-command lem-yath-test-window-history-end () ()
  (buffer-end (current-point)))

(define-command lem-yath-test-window-history-reload () ()
  (load (merge-pathnames "src/window-history.lisp"
                         (asdf:system-source-directory "lem-yath"))))

(define-command lem-yath-test-window-history-small-limit () ()
  (setf *window-layout-history-limit* 3))

(setf *window-history-test-buffer-b*
      (window-history-test-buffer "WINNER-B" "B"))
(setf *window-history-test-buffer-c*
      (window-history-test-buffer "WINNER-C" "C"))

(define-key lem-vi-mode:*normal-keymap* "F5"
  'lem-yath-test-window-history-report)
(define-key lem-vi-mode:*normal-keymap* "F6"
  'lem-yath-test-window-history-buffer-b)
(define-key lem-vi-mode:*normal-keymap* "F7"
  'lem-yath-test-window-history-buffer-c)
(define-key lem-vi-mode:*normal-keymap* "F8"
  'lem-yath-test-window-history-end)
(define-key lem-vi-mode:*normal-keymap* "F9"
  'lem-yath-test-window-history-small-limit)
(define-key lem-vi-mode:*normal-keymap* "F10"
  'lem-yath-test-window-history-reload)

(window-history-test-log "READY")
