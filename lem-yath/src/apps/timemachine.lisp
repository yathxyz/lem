;;;; lem-yath apps/timemachine -- git-timemachine port (SPC g t).
;;;;
;;;; History buffers keep the source file's major mode, but are read-only and
;;;; carry a small navigation minor mode.  Git supplies both the path used by
;;;; each revision (so --follow survives renames) and line translation data.

(in-package :lem-yath)

;;; --- state ----------------------------------------------------------------

(defstruct (tm-revision
             (:constructor make-tm-revision (hash date author subject path)))
  hash date author subject path)

(defstruct (tm-location
             (:constructor make-tm-location (line column text)))
  line column text)

(defvar *tm-relpath-key* 'timemachine-relpath
  "Buffer variable holding the current worktree-relative file path.")
(defvar *tm-root-key* 'timemachine-root
  "Buffer variable holding the Git worktree root directory.")
(defvar *tm-revisions-key* 'timemachine-revisions
  "Buffer variable holding TM-REVISION structs, newest first.")
(defvar *tm-index-key* 'timemachine-index
  "Buffer variable holding the index of the displayed revision.")
(defvar *tm-origin-buffer-key* 'timemachine-origin-buffer
  "Buffer variable holding the exact buffer that invoked timemachine.")
(defvar *tm-origin-window-key* 'timemachine-origin-window
  "Buffer variable holding the window that invoked timemachine.")
(defvar *tm-origin-point-key* 'timemachine-origin-point
  "Buffer variable holding a live point in the invoking buffer.")

;;; --- git plumbing ---------------------------------------------------------

(defun tm-run-git (args &key directory)
  "Run Git with the argument list ARGS in DIRECTORY.
Return stdout on success and NIL on failure.  No command is interpreted by a
shell."
  (handler-case
      (multiple-value-bind (out err code)
          (uiop:run-program
           (append '("git" "--no-pager" "-c" "color.ui=false") args)
           :directory directory
           :output :string
           :error-output :string
           :ignore-error-status t)
        (declare (ignore err))
        (when (eql code 0) out))
    (error () nil)))

(defun tm-repo-root (directory)
  "Return DIRECTORY's Git worktree root as a directory pathname, or NIL."
  (let ((out (tm-run-git '("rev-parse" "--show-toplevel")
                         :directory directory)))
    (when out
      (let ((line (string-right-trim '(#\Newline #\Return #\Space) out)))
        (unless (zerop (length line))
          (uiop:ensure-directory-pathname line))))))

(defun tm-relative-path (filename root)
  "Return FILENAME relative to ROOT, or NIL when it is outside ROOT."
  (let ((rel (ignore-errors
               (uiop:enough-pathname (uiop:ensure-absolute-pathname filename)
                                     root))))
    (when (and rel (not (uiop:absolute-pathname-p rel)))
      (namestring rel))))

(defun tm-split-character (string delimiter)
  "Split STRING at DELIMITER, retaining empty fields."
  (loop :with start := 0
        :for end := (position delimiter string :start start)
        :collect (subseq string start end)
        :while end
        :do (setf start (1+ end))))

(defun tm-parse-log-record (record)
  "Parse one NUL-delimited `git log --name-only' RECORD."
  (let* ((fields (tm-split-character record #\Null))
         (hash (nth 0 fields))
         (date (nth 1 fields))
         (author (nth 2 fields))
         (subject (nth 3 fields))
         ;; With -z, Git separates the pretty record and its filename with a
         ;; NUL followed by one formatting newline.  The filename itself stays
         ;; NUL-delimited, so spaces, tabs, and shell metacharacters are data.
         (path
           (loop :for field :in (nthcdr 4 fields)
                 :for clean := (string-left-trim '(#\Newline #\Return) field)
                 :when (plusp (length clean))
                   :return clean)))
    (when (and hash date author subject path (plusp (length hash)))
      (make-tm-revision hash date author subject path))))

(defun tm-parse-log (output)
  "Parse Git log OUTPUT into a newest-first vector of TM-REVISION structs."
  (coerce
   (loop :for record :in (tm-split-character output (code-char #x1e))
         :for revision := (and (plusp (length record))
                               (tm-parse-log-record record))
         :when revision :collect revision)
   'vector))

(defun tm-collect-history (root relpath)
  "Return revisions touching RELPATH under ROOT, newest first.
Each revision records the filename emitted for that commit, which is the
important difference from replaying every commit against today's path."
  (let ((out
          (tm-run-git
           (list "log" "--follow" "--find-renames" "--name-only" "-z"
                 "--format=%x1e%H%x00%ad%x00%an%x00%s%x00"
                 "--date=short" "--" relpath)
           :directory root)))
    (when out
      (let ((revisions (tm-parse-log out)))
        (when (plusp (length revisions)) revisions)))))

(defun tm-tracked-file-p (root relpath)
  "Return true when RELPATH is currently tracked in ROOT's Git index."
  (not (null
        (tm-run-git (list "ls-files" "--error-unmatch" "--" relpath)
                    :directory root))))

(defun tm-revision-content (root revision)
  "Return REVISION's file content from ROOT, or NIL on failure."
  (tm-run-git
   (list "show"
         (format nil "~A:~A"
                 (tm-revision-hash revision)
                 (tm-revision-path revision)))
   :directory root))

;;; --- location translation ------------------------------------------------

(defun tm-current-location (&optional (point (current-point)))
  "Capture POINT's logical line, display column, and complete line text."
  (with-point ((start point)
               (end point))
    (line-start start)
    (move-point end start)
    (line-end end)
    (make-tm-location (line-number-at-point point)
                      (point-column point)
                      (points-to-string start end))))

(defun tm-blame-lines (output)
  "Return the original and final line numbers from porcelain blame OUTPUT."
  (when output
    (let* ((end (or (position #\Newline output) (length output)))
           (header (subseq output 0 end))
           (fields (remove "" (tm-split-character header #\Space)
                           :test #'string=)))
      (when (>= (length fields) 3)
        (values (parse-integer (second fields) :junk-allowed t)
                (parse-integer (third fields) :junk-allowed t))))))

(defun tm-map-worktree-line (root relpath line)
  "Map worktree LINE in RELPATH to its line in the newest committed content."
  (multiple-value-bind (original final)
      (tm-blame-lines
       (tm-run-git
        (list "blame" "--line-porcelain" "-L"
              (format nil "~D,~D" line line) "--" relpath)
        :directory root))
    (declare (ignore final))
    original))

(defun tm-map-revision-line (root current target current-index target-index line)
  "Translate LINE from CURRENT to TARGET using Git's rename-aware blame.
Indices are newest-first.  Normal blame maps a newer line to an older origin;
reverse blame maps an older line forward to its newer destination."
  (cond
    ((= current-index target-index) line)
    ((> target-index current-index)
     (multiple-value-bind (original final)
         (tm-blame-lines
          (tm-run-git
           (list "blame" "--line-porcelain" "-L"
                 (format nil "~D,~D" line line)
                 (format nil "~A..~A"
                         (tm-revision-hash target)
                         (tm-revision-hash current))
                 "--" (tm-revision-path current))
           :directory root))
       (declare (ignore final))
       original))
    (t
     (multiple-value-bind (original final)
         (tm-blame-lines
          (tm-run-git
           (list "blame" "--reverse" "--line-porcelain" "-L"
                 (format nil "~D,~D" line line)
                 (format nil "~A..~A"
                         (tm-revision-hash current)
                         (tm-revision-hash target))
                 "--" (tm-revision-path current))
           :directory root))
       (declare (ignore original))
       final))))

(defun tm-find-matching-line (content text expected-line)
  "Find TEXT in CONTENT, preferring the occurrence nearest EXPECTED-LINE."
  (let ((best nil)
        (best-distance nil))
    (loop :for candidate :in (tm-split-character content #\Newline)
          :for line :from 1
          :when (string= candidate text)
            :do (let ((distance (abs (- line expected-line))))
                  (when (or (null best-distance) (< distance best-distance))
                    (setf best line
                          best-distance distance))))
    best))

(defun tm-position-buffer (buffer content location)
  "Place BUFFER's point at LOCATION, clamped to CONTENT's available text."
  (let* ((point (buffer-point buffer))
         (expected (max 1 (tm-location-line location)))
         (matching (tm-find-matching-line content
                                          (tm-location-text location)
                                          expected))
         (line (or matching expected)))
    (buffer-start point)
    (unless (move-to-line point line)
      (buffer-end point))
    (line-start point)
    (move-to-column point (tm-location-column location))))

;;; --- navigation minor mode ------------------------------------------------

(define-minor-mode lem-yath-timemachine-mode
    (:name "timemachine"
     :keymap *lem-yath-timemachine-keymap*)
  "Navigation mode for read-only git-timemachine history buffers.")

(defun tm-buffer-p (buffer)
  "True when BUFFER is a live git-timemachine history buffer."
  (and (bufferp buffer)
       (not (deleted-buffer-p buffer))
       (buffer-value buffer *tm-revisions-key*)))

(defun tm-render (buffer index &key message location)
  "Replace BUFFER with revision INDEX and restore LOCATION when supplied."
  (let* ((root (buffer-value buffer *tm-root-key*))
         (revisions (buffer-value buffer *tm-revisions-key*))
         (revision (aref revisions index))
         (content (tm-revision-content root revision)))
    (if (null content)
        (message "timemachine: could not read ~A@~A"
                 (tm-revision-path revision)
                 (tm-revision-hash revision))
        (progn
          (with-buffer-read-only buffer nil
            (erase-buffer buffer)
            (insert-string (buffer-point buffer) content)
            (when location
              (tm-position-buffer buffer content location)))
          (buffer-unmark buffer)
          (setf (buffer-value buffer *tm-index-key*) index
                (buffer-read-only-p buffer) t)
          (when message
            (message "rev ~D/~D: ~A ~A"
                     (- (length revisions) index)
                     (length revisions)
                     (tm-revision-date revision)
                     (tm-revision-subject revision)))
          t))))

(defun tm-transition-location (buffer target-index)
  "Capture BUFFER's location and translate it for TARGET-INDEX."
  (let* ((location (tm-current-location (buffer-point buffer)))
         (root (buffer-value buffer *tm-root-key*))
         (revisions (buffer-value buffer *tm-revisions-key*))
         (current-index (buffer-value buffer *tm-index-key*))
         (current (aref revisions current-index))
         (target (aref revisions target-index))
         (mapped (tm-map-revision-line root current target
                                       current-index target-index
                                       (tm-location-line location))))
    (when mapped
      (setf (tm-location-line location) mapped))
    location))

(defun tm-goto-index (buffer index)
  "Show revision INDEX in BUFFER, reporting history boundaries."
  (let* ((revisions (buffer-value buffer *tm-revisions-key*))
         (count (length revisions)))
    (cond ((< index 0)
           (message "Already at the newest revision"))
          ((>= index count)
           (message "Already at the oldest revision"))
          (t
           (tm-render buffer index
                      :message t
                      :location (tm-transition-location buffer index))))))

(define-command lem-yath-timemachine-older () ()
  "Show the previous, older revision of the file."
  (let ((buffer (current-buffer)))
    (when (tm-buffer-p buffer)
      (tm-goto-index buffer
                     (1+ (buffer-value buffer *tm-index-key*))))))

(define-command lem-yath-timemachine-newer () ()
  "Show the next, newer revision of the file."
  (let ((buffer (current-buffer)))
    (when (tm-buffer-p buffer)
      (tm-goto-index buffer
                     (1- (buffer-value buffer *tm-index-key*))))))

(define-command lem-yath-timemachine-nth () ()
  "Show an oldest-based revision number, matching git-timemachine's prompt."
  (let ((buffer (current-buffer)))
    (unless (tm-buffer-p buffer)
      (return-from lem-yath-timemachine-nth))
    (let* ((revisions (buffer-value buffer *tm-revisions-key*))
           (count (length revisions))
           (number (prompt-for-integer "Enter revision number: ")))
      (if (<= 1 number count)
          (tm-goto-index buffer (- count number))
          (message "Only ~D revisions exist." count)))))

(define-command lem-yath-timemachine-jump () ()
  "Show the revision selected by its commit subject."
  (let ((buffer (current-buffer)))
    (unless (tm-buffer-p buffer)
      (return-from lem-yath-timemachine-jump))
    (let* ((revisions (buffer-value buffer *tm-revisions-key*))
           (subjects (map 'list #'tm-revision-subject revisions))
           (choice
             (prompt-for-string
              "Commit message: "
              :completion-function
              (lambda (input) (prescient-filter input subjects))
              :test-function
              (lambda (subject)
                (member subject subjects :test #'string=))))
           (index (position choice subjects :test #'string=)))
      (if index
          (tm-goto-index buffer index)
          (message "No such revision")))))

(defun tm-release-origin-point (buffer)
  "Release BUFFER's saved origin point exactly once."
  (alexandria:when-let ((point (buffer-value buffer *tm-origin-point-key*)))
    (setf (buffer-value buffer *tm-origin-point-key*) nil)
    (ignore-errors (delete-point point))))

(defun tm-origin-live-p (buffer)
  "True when BUFFER's saved invocation buffer and point still exist."
  (let ((origin (buffer-value buffer *tm-origin-buffer-key*))
        (point (buffer-value buffer *tm-origin-point-key*)))
    (and (bufferp origin)
         (not (deleted-buffer-p origin))
         point
         (ignore-errors (eq (point-buffer point) origin)))))

(define-command lem-yath-timemachine-quit () ()
  "Kill the history view and restore its exact invoking buffer and point."
  (let ((buffer (current-buffer)))
    (if (not (tm-buffer-p buffer))
        (quit-active-window)
        (let ((origin (buffer-value buffer *tm-origin-buffer-key*))
              (window (buffer-value buffer *tm-origin-window-key*))
              (point (buffer-value buffer *tm-origin-point-key*)))
          (if (tm-origin-live-p buffer)
              (progn
                (when (and window (not (deleted-window-p window)))
                  (setf (current-window) window))
                (unless (eq (current-buffer) origin)
                  (switch-to-buffer origin nil nil))
                (move-point (current-point) point)
                (tm-release-origin-point buffer)
                (delete-buffer buffer))
              (progn
                (tm-release-origin-point buffer)
                (setf (buffer-read-only-p buffer) nil)
                (kill-buffer buffer)))))))

(defun tm-kill-buffer-hook (&optional (buffer (current-buffer)))
  "Release a saved origin point when a timemachine buffer is killed directly."
  (when (and (bufferp buffer)
             (buffer-value buffer *tm-origin-point-key*))
    (tm-release-origin-point buffer)))

;;; --- entry point ----------------------------------------------------------

(defun tm-buffer-name (root relpath)
  "Return the stable, repository-and-path-unique history buffer name."
  (format nil "*timemachine: ~A*"
          (namestring (merge-pathnames relpath root))))

(define-command lem-yath-git-timemachine () ()
  "Open the current file's newest committed revision in a history buffer."
  (let* ((origin (current-buffer))
         (filename (buffer-filename origin)))
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
        (unless (tm-tracked-file-p root relpath)
          (message "File is not tracked by Git")
          (return-from lem-yath-git-timemachine))
        (let ((revisions (tm-collect-history root relpath)))
          (unless revisions
            (message "No git history for ~A" (file-namestring relpath))
            (return-from lem-yath-git-timemachine))
          (let* ((origin-window (current-window))
                 (origin-point (copy-point (current-point) :right-inserting))
                 (location (tm-current-location (current-point)))
                 (mapped-line
                   (tm-map-worktree-line root relpath
                                         (tm-location-line location)))
                 (mode (or (lem-core::get-file-mode (pathname relpath))
                           'lem/buffer/fundamental-mode:fundamental-mode))
                 (buffer (make-buffer (tm-buffer-name root relpath)
                                      :directory (namestring root)
                                      :enable-undo-p nil)))
            (when mapped-line
              (setf (tm-location-line location) mapped-line))
            ;; A stable name deliberately reuses an existing view for this
            ;; repo/path.  Dispose its former invocation point before replacing
            ;; the state so repeated entry cannot leak a point.
            (tm-release-origin-point buffer)
            (change-buffer-mode buffer mode)
            (save-excursion
              (setf (current-buffer) buffer)
              (enable-minor-mode 'lem-yath-timemachine-mode))
            (setf (buffer-value buffer *tm-root-key*) root
                  (buffer-value buffer *tm-relpath-key*) relpath
                  (buffer-value buffer *tm-revisions-key*) revisions
                  (buffer-value buffer *tm-index-key*) 0
                  (buffer-value buffer *tm-origin-buffer-key*) origin
                  (buffer-value buffer *tm-origin-window-key*) origin-window
                  (buffer-value buffer *tm-origin-point-key*) origin-point)
            (if (tm-render buffer 0 :message t :location location)
                (switch-to-buffer buffer)
                (progn
                  (tm-release-origin-point buffer)
                  (setf (buffer-value buffer *tm-revisions-key*) nil)))))))))

;;; --- evil-collection-compatible keymap ------------------------------------

(defun tm-normal-g-keymap ()
  "Return vi normal state's existing `g' suffix keymap, if one exists."
  (alexandria:when-let
      ((prefix
         (lem-core::keymap-find lem-vi-mode:*normal-keymap*
                                (lem-core::parse-keyspec "g"))))
    (let ((suffix (lem-core::prefix-suffix prefix)))
      (when (typep suffix 'lem-core::keymap)
        suffix))))

;; DEFINE-MINOR-MODE uses DEFVAR for its map.  Remove legacy bindings first so
;; evaluating this file over an older session is deterministic and idempotent.
(dolist (key '("p" "n" "t" "g" "C-k" "C-j" "q"))
  (undefine-key *lem-yath-timemachine-keymap* key))

(defparameter *lem-yath-timemachine-g-keymap*
  (make-keymap :description '*lem-yath-timemachine-g-keymap*
               :base (tm-normal-g-keymap)))
(defparameter *lem-yath-timemachine-gt-keymap*
  (make-keymap :description '*lem-yath-timemachine-gt-keymap*))

(define-key *lem-yath-timemachine-gt-keymap*
  "g" 'lem-yath-timemachine-nth)
(define-key *lem-yath-timemachine-gt-keymap*
  "t" 'lem-yath-timemachine-jump)
(define-key *lem-yath-timemachine-g-keymap*
  "t" *lem-yath-timemachine-gt-keymap*)
(define-key *lem-yath-timemachine-keymap*
  "g" *lem-yath-timemachine-g-keymap*)
(define-key *lem-yath-timemachine-keymap*
  "C-k" 'lem-yath-timemachine-older)
(define-key *lem-yath-timemachine-keymap*
  "C-j" 'lem-yath-timemachine-newer)
(define-key *lem-yath-timemachine-keymap*
  "q" 'lem-yath-timemachine-quit)

(remove-hook (variable-value 'kill-buffer-hook :global t)
             'tm-kill-buffer-hook)
(add-hook (variable-value 'kill-buffer-hook :global t)
          'tm-kill-buffer-hook)
