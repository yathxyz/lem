;;;; Magit-compatible current-file blame for Lem's Git porcelain.

(in-package :lem-yath)

(defparameter *git-blame-timeout* 15)
(defparameter *git-blame-input-limit* (* 8 1024 1024))
(defparameter *git-blame-output-limit* (* 32 1024 1024))
(defparameter *git-blame-hash-width* 12)

(defstruct git-blame-record
  hash author author-time summary content)

(defvar *git-blame-records-key* 'lem-yath-git-blame-records)
(defvar *git-blame-root-key* 'lem-yath-git-blame-root)
(defvar *git-blame-origin-buffer-key* 'lem-yath-git-blame-origin-buffer)
(defvar *git-blame-origin-window-key* 'lem-yath-git-blame-origin-window)
(defvar *git-blame-origin-point-key* 'lem-yath-git-blame-origin-point)
(defvar *git-blame-commit-parent-key* 'lem-yath-git-blame-commit-parent)
(defvar *git-blame-mode-keymap*
  (make-keymap :description "Magit blame"))
(defvar *git-blame-commit-mode-keymap*
  (make-keymap :description "Magit commit"))
(defvar *git-file-dispatch-keymap*
  (make-keymap :description "Magit file"))

(define-major-mode lem-yath-git-blame-mode nil
    (:name "Magit-Blame" :keymap *git-blame-mode-keymap*)
  "Read-only current-file addition blame, following Magit's file workflow.")

(define-major-mode lem-yath-git-blame-commit-mode nil
    (:name "Magit-Commit" :keymap *git-blame-commit-mode-keymap*)
  "Read-only commit child opened from a blame chunk.")

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-git-blame-mode))
  (list *git-blame-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps
    ((mode lem-yath-git-blame-commit-mode))
  (list *git-blame-commit-mode-keymap*))

(defun git-blame-field-value (line prefix)
  (when (alexandria:starts-with-subseq prefix line)
    (subseq line (length prefix))))

(defun git-blame-parse-output (output)
  "Parse Git line-porcelain OUTPUT into one record per blamed line."
  (let ((records '())
        (current nil))
    (dolist (line (str:lines output))
      (let ((header
              (cl-ppcre:register-groups-bind
                  (hash)
                  ("^([0-9a-f]{40,64}) ([0-9]+) ([0-9]+)(?: [0-9]+)?$"
                   line)
                (when hash
                  hash))))
        (cond
          (header
           (setf current (make-git-blame-record :hash header)))
          ((null current))
          ((git-blame-field-value line "author ")
           (setf (git-blame-record-author current)
                 (git-blame-field-value line "author ")))
          ((git-blame-field-value line "author-time ")
           (setf (git-blame-record-author-time current)
                 (parse-integer
                  (git-blame-field-value line "author-time ")
                  :junk-allowed t)))
          ((git-blame-field-value line "summary ")
           (setf (git-blame-record-summary current)
                 (git-blame-field-value line "summary ")))
          ((and (plusp (length line)) (char= (char line 0) #\Tab))
           (setf (git-blame-record-content current) (subseq line 1))
           (push current records)
           (setf current nil)))))
    (nreverse records)))

(defun git-blame-unix-date (timestamp)
  (if (integerp timestamp)
      (multiple-value-bind (second minute hour day month year)
          (decode-universal-time (+ timestamp 2208988800) 0)
        (declare (ignore second minute hour))
        (format nil "~4,'0d-~2,'0d-~2,'0d" year month day))
      "----------"))

(defun git-blame-short-hash (hash)
  (subseq hash 0 (min *git-blame-hash-width* (length hash))))

(defun git-blame-zero-hash-p (hash)
  (and (plusp (length hash))
       (every (lambda (character) (char= character #\0)) hash)))

(defun git-blame-annotation (record repeated-p)
  (if repeated-p
      (make-string 42 :initial-element #\Space)
      (format nil "~a ~a ~a"
              (completion-pad-annotation-field
               (git-blame-short-hash (git-blame-record-hash record)) 12)
              (completion-pad-annotation-field
               (completion-truncate-display-width
                (or (git-blame-record-author record) "unknown") 18)
               18)
              (git-blame-unix-date
               (git-blame-record-author-time record)))))

(defun git-blame-root-and-path (git filename)
  "Return the nearest Git root and safe relative path for FILENAME."
  (let* ((directory (uiop:pathname-directory-pathname filename))
         (top (project-git-rev-parse git directory "--show-toplevel")))
    (unless top
      (editor-error "Not inside a Git repository."))
    (let ((root (canonical-project-directory top)))
      (unless (project-path-in-directory-p filename root)
        (editor-error "The visited file is outside the Git worktree."))
      (let ((relative
              (namestring
               (uiop:enough-pathname (truename filename) root))))
        (unless (safe-project-relative-path-p relative)
          (editor-error "Git cannot safely address the visited file."))
        (values root relative)))))

(defun git-blame-run (git root relative contents)
  "Blame live CONTENTS for RELATIVE at ROOT, including unsaved edits."
  (when (> (length contents) *git-blame-input-limit*)
    (editor-error "Blame is limited to 8 MiB buffers."))
  (let ((*project-process-timeout* *git-blame-timeout*))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (list (uiop:native-namestring git)
               "-C" (project-native-directory root)
               "--no-pager" "-c" "color.ui=false"
               "blame" "--line-porcelain" "--contents" "-"
               "--" relative)
         :input contents
         :output-limit *git-blame-output-limit*)
      (unless (and (integerp status) (zerop status))
        (editor-error "~a" (legit-command-error-text output error-output)))
      output)))

(defun git-blame-buffer-name (root relative)
  (format nil "*Magit blame: ~a*"
          (namestring (merge-pathnames relative root))))

(defun git-blame-release-origin-point (buffer)
  (alexandria:when-let
      ((point (buffer-value buffer *git-blame-origin-point-key*)))
    (setf (buffer-value buffer *git-blame-origin-point-key*) nil)
    (ignore-errors (delete-point point))))

(defun git-blame-buffer-p (buffer)
  (and (bufferp buffer)
       (not (deleted-buffer-p buffer))
       (eq (buffer-major-mode buffer) 'lem-yath-git-blame-mode)))

(defun git-blame-commit-buffer-p (buffer)
  (and (bufferp buffer)
       (not (deleted-buffer-p buffer))
       (eq (buffer-major-mode buffer) 'lem-yath-git-blame-commit-mode)))

(defun git-blame-render (buffer relative records target-line)
  (setf (buffer-value buffer *git-blame-records-key*)
        (coerce records 'vector))
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (let ((point (buffer-point buffer))
          (previous-hash nil))
      (insert-string
       point
       (format nil "Blame: ~a    gj/gk chunks  gJ/gK same commit  RET show  M-w copy  q quit~%"
               (completion-bounded-annotation relative)))
      (dolist (record records)
        (let ((same-p (equal previous-hash
                             (git-blame-record-hash record))))
          (insert-string
           point
           (format nil "~a | ~a~%"
                   (git-blame-annotation record same-p)
                   (git-blame-record-content record)))
          (setf previous-hash (git-blame-record-hash record))))))
  (buffer-unmark buffer)
  (setf (buffer-read-only-p buffer) t)
  (move-to-line (buffer-point buffer)
                (1+ (max 1 (min target-line (length records))))))

(define-command lem-yath-git-blame () ()
  "Show Magit-style addition blame for the current file and live contents."
  (let* ((origin (current-buffer))
         (filename (buffer-filename origin))
         (git (or (executable-find "git")
                  (editor-error "Git is unavailable."))))
    (unless filename
      (editor-error "Buffer is not visiting a file."))
    (multiple-value-bind (root relative)
        (git-blame-root-and-path git filename)
      (let* ((line (line-number-at-point (current-point)))
             (records
               (git-blame-parse-output
                (git-blame-run git root relative (buffer-text origin)))))
        (unless records
          (editor-error "Git returned no blame records for this file."))
        (let ((buffer
                (make-buffer (git-blame-buffer-name root relative)
                             :directory (namestring root)
                             :enable-undo-p nil)))
          (git-blame-release-origin-point buffer)
          (change-buffer-mode buffer 'lem-yath-git-blame-mode)
          (setf (buffer-value buffer *git-blame-root-key*) root
                (buffer-value buffer *git-blame-origin-buffer-key*) origin
                (buffer-value buffer *git-blame-origin-window-key*)
                (current-window)
                (buffer-value buffer *git-blame-origin-point-key*)
                (copy-point (current-point) :right-inserting))
          (git-blame-render buffer relative records line)
          (switch-to-buffer buffer)
          (message "Blamed ~d lines from the live buffer." (length records)))))))

(defun git-blame-records (&optional (buffer (current-buffer)))
  (buffer-value buffer *git-blame-records-key*))

(defun git-blame-current-index (&optional (point (current-point)))
  "Return the zero-based blame record index at POINT."
  (let* ((records (git-blame-records (point-buffer point)))
         (index (- (line-number-at-point point) 2)))
    (when (and records (<= 0 index) (< index (length records)))
      index)))

(defun git-blame-current-record (&optional (point (current-point)))
  (alexandria:when-let ((index (git-blame-current-index point)))
    (aref (git-blame-records (point-buffer point)) index)))

(defun git-blame-goto-index (index)
  (move-to-line (current-point) (+ index 2))
  (git-blame-report-current-record))

(defun git-blame-report-current-record ()
  (alexandria:when-let ((record (git-blame-current-record)))
    (message "~a  ~a  ~a"
             (git-blame-short-hash (git-blame-record-hash record))
             (or (git-blame-record-author record) "unknown")
             (or (git-blame-record-summary record) ""))))

(define-command lem-yath-git-blame-next-chunk () ()
  (alexandria:when-let ((index (git-blame-current-index)))
    (let* ((records (git-blame-records))
           (hash (git-blame-record-hash (aref records index)))
           (target
             (loop :for candidate :from (1+ index) :below (length records)
                   :unless (string= hash
                                    (git-blame-record-hash
                                     (aref records candidate)))
                     :return candidate)))
      (if target
          (git-blame-goto-index target)
          (message "No more blame chunks.")))))

(define-command lem-yath-git-blame-previous-chunk () ()
  (alexandria:when-let ((index (git-blame-current-index)))
    (let* ((records (git-blame-records))
           (hash (git-blame-record-hash (aref records index)))
           (different
             (loop :for candidate :downfrom (1- index) :to 0
                   :unless (string= hash
                                    (git-blame-record-hash
                                     (aref records candidate)))
                     :return candidate)))
      (if (null different)
          (message "No earlier blame chunks.")
          (let ((target different)
                (previous-hash
                  (git-blame-record-hash (aref records different))))
            (loop :while (and (plusp target)
                              (string= previous-hash
                                       (git-blame-record-hash
                                        (aref records (1- target)))))
                  :do (decf target))
            (git-blame-goto-index target))))))

(defun git-blame-move-same-commit (previous-p)
  (alexandria:when-let ((index (git-blame-current-index)))
    (let* ((records (git-blame-records))
           (wanted (git-blame-record-hash (aref records index)))
           (target
             (if previous-p
                 (loop :for candidate :downfrom (1- index) :to 0
                       :when (and
                              (string= wanted
                                       (git-blame-record-hash
                                        (aref records candidate)))
                              (or (zerop candidate)
                                  (not
                                   (string= wanted
                                            (git-blame-record-hash
                                             (aref records (1- candidate)))))))
                         :return candidate)
                 (loop :for candidate :from (1+ index)
                         :below (length records)
                       :when (and
                              (string= wanted
                                       (git-blame-record-hash
                                        (aref records candidate)))
                              (not
                               (string= wanted
                                        (git-blame-record-hash
                                         (aref records (1- candidate))))))
                         :return candidate))))
      (if target
          (git-blame-goto-index target)
          (message "No other chunk from this commit.")))))

(define-command lem-yath-git-blame-next-chunk-same-commit () ()
  (git-blame-move-same-commit nil))

(define-command lem-yath-git-blame-previous-chunk-same-commit () ()
  (git-blame-move-same-commit t))

(define-command lem-yath-git-blame-copy-hash () ()
  "Copy the current chunk hash, or the active region like Magit's M-w."
  (let ((buffer (current-buffer)))
    (cond
      ((buffer-mark-p buffer)
       (copy-to-clipboard-with-killring
        (points-to-string (region-beginning buffer) (region-end buffer))))
      ((git-blame-current-record)
       (let ((hash (git-blame-record-hash (git-blame-current-record))))
         (copy-to-clipboard-with-killring hash)
         (message "~a" hash))))))

(defun git-blame-show-commit-output (root hash)
  (let ((git (or (executable-find "git")
                 (editor-error "Git is unavailable.")))
        (*project-process-timeout* *git-blame-timeout*))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (list (uiop:native-namestring git)
               "-C" (project-native-directory root)
               "--no-pager" "-c" "color.ui=false"
               "show" "--format=fuller" "--decorate=short" "--stat"
               "--patch" hash)
         :output-limit *git-blame-output-limit*)
      (unless (and (integerp status) (zerop status))
        (editor-error "~a" (legit-command-error-text output error-output)))
      output)))

(define-command lem-yath-git-blame-show-commit () ()
  (alexandria:when-let ((record (git-blame-current-record)))
    (let ((hash (git-blame-record-hash record)))
      (when (git-blame-zero-hash-p hash)
        (editor-error "This line contains uncommitted buffer content."))
      (let* ((parent (current-buffer))
             (root (buffer-value parent *git-blame-root-key*))
             (output (git-blame-show-commit-output root hash))
             (buffer
               (make-buffer
                (format nil "*Magit commit: ~a*" (git-blame-short-hash hash))
                :directory (namestring root)
                :enable-undo-p nil)))
        (change-buffer-mode buffer 'lem-yath-git-blame-commit-mode)
        (with-buffer-read-only buffer nil
          (erase-buffer buffer)
          (insert-string (buffer-point buffer) output)
          (buffer-start (buffer-point buffer)))
        (buffer-unmark buffer)
        (setf (buffer-value buffer *git-blame-commit-parent-key*) parent
              (buffer-read-only-p buffer) t)
        (switch-to-buffer buffer)))))

(define-command lem-yath-git-blame-commit-quit () ()
  (let* ((buffer (current-buffer))
         (parent (buffer-value buffer *git-blame-commit-parent-key*)))
    (if (and (git-blame-commit-buffer-p buffer)
             (git-blame-buffer-p parent))
        (progn
          (switch-to-buffer parent)
          (delete-buffer buffer))
        (progn
          (setf (buffer-read-only-p buffer) nil)
          (kill-buffer buffer)))))

(define-command lem-yath-git-blame-quit () ()
  "Close blame and restore the exact invoking buffer, window, and point."
  (let* ((buffer (current-buffer))
         (origin (buffer-value buffer *git-blame-origin-buffer-key*))
         (window (buffer-value buffer *git-blame-origin-window-key*))
         (point (buffer-value buffer *git-blame-origin-point-key*)))
    (if (not (git-blame-buffer-p buffer))
        (quit-active-window)
        (if (and (bufferp origin)
                 (not (deleted-buffer-p origin))
                 point
                 (ignore-errors (eq (point-buffer point) origin)))
            (progn
              (when (and window (not (deleted-window-p window)))
                (setf (current-window) window))
              (switch-to-buffer origin nil nil)
              (move-point (current-point) point)
              (git-blame-release-origin-point buffer)
              (delete-buffer buffer))
            (progn
              (git-blame-release-origin-point buffer)
              (setf (buffer-read-only-p buffer) nil)
              (kill-buffer buffer))))))

(defun git-blame-kill-buffer-hook (&optional (buffer (current-buffer)))
  (when (and (bufferp buffer)
             (buffer-value buffer *git-blame-origin-point-key*))
    (git-blame-release-origin-point buffer)))

(defun git-blame-normal-g-keymap ()
  (alexandria:when-let
      ((prefix
         (lem-core::keymap-find lem-vi-mode:*normal-keymap*
                                (lem-core::parse-keyspec "g"))))
    (let ((suffix (lem-core::prefix-suffix prefix)))
      (when (typep suffix 'lem-core::keymap) suffix))))

;; Reset maps before rebinding so reloading this module is deterministic.
(dolist (key '("g" "C-j" "C-k" "Return" "M-w" "q"))
  (undefine-key *git-blame-mode-keymap* key))
(dolist (key '("q" "C-c C-k"))
  (undefine-key *git-blame-commit-mode-keymap* key))
(undefine-key *git-file-dispatch-keymap* "b")

(defparameter *git-blame-g-keymap*
  (make-keymap :description "Magit blame navigation"
               :base (git-blame-normal-g-keymap)))
(define-key *git-blame-g-keymap* "j" 'lem-yath-git-blame-next-chunk)
(define-key *git-blame-g-keymap* "k" 'lem-yath-git-blame-previous-chunk)
(define-key *git-blame-g-keymap* "J"
  'lem-yath-git-blame-next-chunk-same-commit)
(define-key *git-blame-g-keymap* "K"
  'lem-yath-git-blame-previous-chunk-same-commit)
(define-key *git-blame-mode-keymap* "g" *git-blame-g-keymap*)
(define-key *git-blame-mode-keymap* "C-j" 'lem-yath-git-blame-next-chunk)
(define-key *git-blame-mode-keymap* "C-k" 'lem-yath-git-blame-previous-chunk)
(define-key *git-blame-mode-keymap* "Return" 'lem-yath-git-blame-show-commit)
(define-key *git-blame-mode-keymap* "M-w" 'lem-yath-git-blame-copy-hash)
(define-key *git-blame-mode-keymap* "q" 'lem-yath-git-blame-quit)
(define-key *git-blame-commit-mode-keymap* "q"
  'lem-yath-git-blame-commit-quit)
(define-key *git-blame-commit-mode-keymap* "C-c C-k"
  'lem-yath-git-blame-commit-quit)
(define-key *git-file-dispatch-keymap* "b" 'lem-yath-git-blame)

(remove-hook (variable-value 'kill-buffer-hook :global t)
             'git-blame-kill-buffer-hook)
(add-hook (variable-value 'kill-buffer-hook :global t)
          'git-blame-kill-buffer-hook)
