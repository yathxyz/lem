;;;; lem-yath apps/timemachine -- git-timemachine port (SPC g t).
;;;;
;;;; Step through a file's git history one revision at a time, mirroring
;;;; Emacs's git-timemachine. For the file in the current buffer we collect
;;;; its `git log --follow' history, then show each revision's content in a
;;;; dedicated read-only buffer. Navigation (older/newer/jump/quit) lives in a
;;;; minor mode whose keymap, under vi-mode, takes precedence over normal-state
;;;; bindings (see vi-mode core.lisp compute-keymaps: minor-mode keymaps are
;;;; searched before state keymaps), so p/n/g/q work even in normal mode while
;;;; the buffer keeps the source file's major mode for syntax highlighting.

(in-package :lem-yath)

;;; --- state ----------------------------------------------------------------
;;
;; A revision is (hash date author subject). Per-timemachine-buffer state is
;; stored in buffer variables (lem's buffer-value API): the source file's
;; relative path, the repo root, the revision vector, and the current index.

(defstruct (tm-revision (:constructor make-tm-revision (hash date author subject)))
  hash date author subject)

(defvar *tm-relpath-key* 'timemachine-relpath
  "Buffer variable holding the file's path relative to the repo root.")
(defvar *tm-root-key* 'timemachine-root
  "Buffer variable holding the git repository root directory.")
(defvar *tm-revisions-key* 'timemachine-revisions
  "Buffer variable holding the vector of TM-REVISION structs (newest first).")
(defvar *tm-index-key* 'timemachine-index
  "Buffer variable holding the index of the displayed revision.")

;;; --- git plumbing ---------------------------------------------------------

(defun tm-run-git (args &key directory)
  "Run git with ARGS (a list of strings) in DIRECTORY, returning its stdout
string on success or NIL on any failure. Never signals."
  (handler-case
      (multiple-value-bind (out err code)
          (uiop:run-program (cons "git" args)
                            :directory directory
                            :output :string
                            :error-output :string
                            :ignore-error-status t)
        (declare (ignore err))
        (when (eql code 0) out))
    (error () nil)))

(defun tm-repo-root (directory)
  "Return the git repository root for DIRECTORY as a directory pathname, or NIL."
  (let ((out (tm-run-git '("rev-parse" "--show-toplevel") :directory directory)))
    (when out
      (let ((line (string-right-trim '(#\Newline #\Return #\Space) out)))
        (unless (zerop (length line))
          (uiop:ensure-directory-pathname line))))))

(defun tm-relative-path (filename root)
  "Path of FILENAME relative to repo ROOT, as a string, or NIL if not under it."
  (let ((rel (ignore-errors
               (uiop:enough-pathname (uiop:ensure-absolute-pathname filename)
                                     root))))
    (when (and rel (not (uiop:absolute-pathname-p rel)))
      (namestring rel))))

(defun tm-parse-log (output)
  "Parse `git log' OUTPUT (tab-separated hash/date/author/subject lines) into a
vector of TM-REVISION structs, newest first."
  (coerce
   (loop :for line :in (uiop:split-string (string-right-trim '(#\Newline) output)
                                          :separator '(#\Newline))
         :unless (zerop (length line))
           :collect (destructuring-bind (&optional hash date author subject)
                        (uiop:split-string line :separator '(#\Tab) :max 4)
                      (make-tm-revision (or hash "") (or date "") (or author "")
                                        (or subject ""))))
   'vector))

(defun tm-collect-history (root relpath)
  "Return the vector of revisions that touched RELPATH (newest first), or NIL."
  (let ((out (tm-run-git (list "log" "--follow"
                               "--format=%h%x09%ad%x09%an%x09%s"
                               "--date=short" "--" relpath)
                         :directory root)))
    (when out
      (let ((revs (tm-parse-log out)))
        (when (plusp (length revs)) revs)))))

(defun tm-revision-content (root relpath rev)
  "Return the file content at REV (a TM-REVISION) for RELPATH, or NIL."
  (tm-run-git (list "show" (format nil "~A:~A" (tm-revision-hash rev) relpath))
              :directory root))

;;; --- navigation minor mode ------------------------------------------------

(define-minor-mode lem-yath-timemachine-mode
    (:name "timemachine"
     :keymap *lem-yath-timemachine-keymap*)
  "Minor mode active in git-timemachine buffers; supplies p/n/g/q navigation.")

(defun tm-buffer-p (buffer)
  "True if BUFFER is a live git-timemachine buffer."
  (buffer-value buffer *tm-revisions-key*))

(defun tm-render (buffer index &key message)
  "Replace BUFFER's content with revision INDEX and update its state/name.
When MESSAGE is non-NIL, echo a `rev k/N: date subject' line."
  (let* ((root (buffer-value buffer *tm-root-key*))
         (relpath (buffer-value buffer *tm-relpath-key*))
         (revs (buffer-value buffer *tm-revisions-key*))
         (rev (aref revs index))
         (content (tm-revision-content root relpath rev)))
    (if (null content)
        (message "timemachine: could not read ~A@~A"
                 relpath (tm-revision-hash rev))
        (progn
          (with-buffer-read-only buffer nil
            (erase-buffer buffer)
            (insert-string (buffer-point buffer) content)
            (buffer-start (buffer-point buffer)))
          (setf (buffer-value buffer *tm-index-key*) index)
          (let ((name (format nil "*timemachine: ~A @ ~A*"
                              (file-namestring relpath) (tm-revision-hash rev))))
            (unless (equal name (buffer-name buffer))
              (ignore-errors (buffer-rename buffer name))))
          (setf (buffer-read-only-p buffer) t)
          (when message
            (message "rev ~D/~D: ~A ~A"
                     (1+ index) (length revs)
                     (tm-revision-date rev) (tm-revision-subject rev)))))))

(defun tm-goto-index (buffer index)
  "Show revision INDEX in BUFFER if in range; otherwise report the boundary."
  (let* ((revs (buffer-value buffer *tm-revisions-key*))
         (n (length revs)))
    (cond ((< index 0) (message "Already at the newest revision"))
          ((>= index n) (message "Already at the oldest revision"))
          (t (tm-render buffer index :message t)))))

(define-command lem-yath-timemachine-older () ()
  "Show the previous (older) revision of the file."
  (let ((buffer (current-buffer)))
    (when (tm-buffer-p buffer)
      (tm-goto-index buffer (1+ (buffer-value buffer *tm-index-key*))))))

(define-command lem-yath-timemachine-newer () ()
  "Show the next (newer) revision of the file."
  (let ((buffer (current-buffer)))
    (when (tm-buffer-p buffer)
      (tm-goto-index buffer (1- (buffer-value buffer *tm-index-key*))))))

(defun tm-revision-label (rev)
  "Orderless-searchable `hash date subject' label for REV."
  (format nil "~A ~A ~A"
          (tm-revision-hash rev) (tm-revision-date rev) (tm-revision-subject rev)))

(define-command lem-yath-timemachine-jump () ()
  "Jump to a revision chosen by fuzzy search over hash/date/subject."
  (let ((buffer (current-buffer)))
    (unless (tm-buffer-p buffer)
      (return-from lem-yath-timemachine-jump))
    (let* ((revs (buffer-value buffer *tm-revisions-key*))
           (labels (map 'list #'tm-revision-label revs))
           (choice (prompt-for-string
                    "Revision: "
                    :completion-function
                    (lambda (input) (orderless-filter input labels))
                    :test-function
                    (lambda (name) (member name labels :test #'string=))))
           (index (position choice labels :test #'string=)))
      (if index
          (tm-render buffer index :message t)
          (message "No such revision")))))

(define-command lem-yath-timemachine-quit () ()
  "Quit the timemachine buffer."
  (let ((buffer (current-buffer)))
    (if (tm-buffer-p buffer)
        (progn
          (setf (buffer-read-only-p buffer) nil)
          (kill-buffer buffer))
        (quit-active-window))))

;;; --- entry point ----------------------------------------------------------

(define-command lem-yath-git-timemachine () ()
  "Step through the git history of the file in the current buffer.
Opens its newest revision read-only; p/n move older/newer, g jumps to a
revision, q quits."
  (let ((filename (buffer-filename (current-buffer))))
    (unless filename
      (message "Buffer is not visiting a file")
      (return-from lem-yath-git-timemachine))
    (let ((root (tm-repo-root (directory-namestring filename))))
      (unless root
        (message "Not inside a git repository")
        (return-from lem-yath-git-timemachine))
      (let ((relpath (tm-relative-path filename root)))
        (unless relpath
          (message "File is outside the repository root")
          (return-from lem-yath-git-timemachine))
        (let ((revisions (tm-collect-history root relpath)))
          (unless revisions
            (message "No git history for ~A" (file-namestring relpath))
            (return-from lem-yath-git-timemachine))
          (let* ((mode (or (lem-core::get-file-mode (pathname relpath))
                           'fundamental-mode))
                 (buffer (make-buffer
                          (format nil "*timemachine: ~A @ ~A*"
                                  (file-namestring relpath)
                                  (tm-revision-hash (aref revisions 0)))
                          :directory (namestring root))))
            ;; Source file's major mode gives syntax highlighting; the
            ;; timemachine minor mode supplies p/n/g/q (which, under vi-mode,
            ;; outrank normal-state keys).
            (change-buffer-mode buffer mode)
            (save-excursion
              (setf (current-buffer) buffer)
              (enable-minor-mode 'lem-yath-timemachine-mode))
            (setf (buffer-value buffer *tm-root-key*) root)
            (setf (buffer-value buffer *tm-relpath-key*) relpath)
            (setf (buffer-value buffer *tm-revisions-key*) revisions)
            (setf (buffer-value buffer *tm-index-key*) 0)
            (tm-render buffer 0 :message t)
            (switch-to-buffer buffer)))))))

;;; --- keymap & leader binding ----------------------------------------------

(define-key *lem-yath-timemachine-keymap* "p" 'lem-yath-timemachine-older)
(define-key *lem-yath-timemachine-keymap* "n" 'lem-yath-timemachine-newer)
(define-key *lem-yath-timemachine-keymap* "g" 'lem-yath-timemachine-jump)
(define-key *lem-yath-timemachine-keymap* "q" 'lem-yath-timemachine-quit)

(define-key lem-vi-mode:*normal-keymap* "Leader g t" 'lem-yath-git-timemachine)
