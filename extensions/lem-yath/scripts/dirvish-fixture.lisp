(in-package :lem-yath)

(defvar *dirvish-test-report* (uiop:getenv "LEM_YATH_DIRVISH_REPORT"))
(defvar *dirvish-test-root*
  (uiop:ensure-directory-pathname (uiop:getenv "LEM_YATH_DIRVISH_ROOT")))
(defvar *dirvish-test-source*
  (or (uiop:getenv "LEM_YATH_DIRVISH_SOURCE")
      (merge-pathnames "src/dirvish.lisp"
                       (asdf:system-source-directory "lem-yath"))))
(defvar *dirvish-test-origin-a* nil)
(defvar *dirvish-test-origin-b* nil)
(defvar *dirvish-test-origin-c* nil)
(defvar *dirvish-test-origin-tree* nil)
(defvar *dirvish-test-origin-shape* nil)
(defvar *dirvish-test-mx-preview* nil)

(defun dirvish-test-log (control &rest arguments)
  (with-open-file (stream *dirvish-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun dirvish-test-visible (string)
  (substitute #\. #\Space string))

(defun dirvish-test-basename (pathname)
  (if (uiop:directory-pathname-p pathname)
      (string-right-trim
       "/" (lem/directory-mode/file:pathname-directory-last-name pathname))
      (file-namestring pathname)))

(defun dirvish-test-row (basename)
  (with-point ((line (buffer-start-point (current-buffer))))
    (loop
      (let ((pathname (lem/directory-mode/internal:get-pathname line)))
        (when (and pathname
                   (string= basename (dirvish-test-basename pathname)))
          (let* ((active-modes
                   (lem-core::get-active-modes-class-instance
                    (current-buffer)))
                 (lem-core::*active-modes* active-modes)
                 (logical-line
                   (lem-core::create-logical-line
                    line nil active-modes (current-window))))
            (return
              (list (lem-core::logical-line-string logical-line)
                    (text-property-at line :dirvish-size)
                    (line-string line)
                    pathname)))))
      (unless (line-offset line 1)
        (return nil)))))

(defun dirvish-test-open-directory ()
  (switch-to-buffer
   (lem/directory-mode/internal:directory-buffer *dirvish-test-root*)))

(defun dirvish-test-buffer (name text)
  (let ((buffer (make-buffer name)))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-start-point buffer) text))
    (buffer-unmark buffer)
    buffer))

(defun dirvish-test-window-tree (tree &optional shape-only-p)
  (if (lem-core::window-tree-leaf-p tree)
      (if shape-only-p
          (list :leaf (window-width tree) (window-height tree))
          (list :leaf
                (buffer-name (window-buffer tree))
                (window-width tree)
                (window-height tree)))
      (list (lem-core::window-node-split-type tree)
            (dirvish-test-window-tree
             (lem-core::window-node-left tree) shape-only-p)
            (dirvish-test-window-tree
             (lem-core::window-node-right tree) shape-only-p))))

(defun dirvish-test-setup-origin-layout ()
  (delete-other-windows)
  (switch-to-buffer *dirvish-test-origin-a*)
  (let ((left (current-window)))
    (split-window-horizontally left :width 31)
    (let ((top-right (get-next-window left)))
      (switch-to-window top-right)
      (switch-to-buffer *dirvish-test-origin-b*)
      (split-window-vertically top-right :height 9)
      (let ((bottom-right (get-next-window top-right)))
        (switch-to-window bottom-right)
        (switch-to-buffer *dirvish-test-origin-c*)
        (switch-to-window top-right))))
  (setf *dirvish-test-origin-tree*
        (dirvish-test-window-tree (lem-core::frame-window-tree (current-frame)))
        *dirvish-test-origin-shape*
        (dirvish-test-window-tree
         (lem-core::frame-window-tree (current-frame)) t)))

(defun dirvish-test-current-name ()
  (alexandria:when-let
      ((pathname
         (lem/directory-mode/internal:get-pathname (current-point))))
    (dirvish-test-basename pathname)))

(defun dirvish-test-source-path-visible-p (buffer)
  (with-point ((point (buffer-start-point buffer)))
    (and (not (lem-core::line-hidden-p point))
         (search (dirvish-native-path (buffer-directory buffer))
                 (line-string point)))))

(defun dirvish-test-source-blank-hidden-p (buffer)
  (with-point ((point (buffer-start-point buffer)))
    (and (line-offset point 1)
         (lem-core::line-hidden-p point)
         (line-offset point 1)
         (not (lem-core::line-hidden-p point)))))

(defun dirvish-test-modeline-text (window)
  (with-output-to-string (stream)
    (lem-core::modeline-apply
     window
     (lambda (text attribute alignment)
       (declare (ignore attribute alignment))
       (write-string text stream))
     'modeline)))

(define-command lem-yath-test-dirvish-chrome () ()
  (alexandria:if-let ((session (current-dirvish-session)))
    (let* ((root-window (dirvish-session-root-window session))
           (root-buffer (window-buffer root-window))
           (footer (dirvish-test-modeline-text root-window)))
      (dirvish-test-log
       "CHROME header=source navigable=~d path=~a blank=~a footer=~a preview=~a"
       (length (window-list))
       (if (dirvish-test-source-path-visible-p root-buffer) "yes" "no")
       (if (dirvish-test-source-blank-hidden-p root-buffer) "yes" "no")
       (if (and (search "name|mtime" footer)
                (search "/" footer))
           "yes" "no")
       (if (equal '("")
                  (lem-core::window-modeline-format
                   (dirvish-session-preview-window session)))
           "blank" "changed")))
    (let* ((window (current-window))
           (buffer (window-buffer window))
           (text (dirvish-test-modeline-text window)))
      (dirvish-test-log
       "ORDINARY header=~a blank=~a modeline=~a sort=~a index=~a selected=~a"
       (if (dirvish-test-source-path-visible-p buffer) "yes" "no")
       (if (dirvish-test-source-blank-hidden-p buffer) "yes" "no")
       (if (equal +dirvish-ordinary-modeline-format+
                  (variable-value 'modeline-format :default buffer))
           "yes" "no")
       (if (search "name|mtime" text) "yes" "no")
       (if (search (format nil "/~3d "
                           (max 0 (- (buffer-nlines buffer) 3)))
                   text)
           "yes" "no")
       (if (dirvish-window-selected-path window) "yes" "no")))))

(define-command lem-yath-test-dirvish-symlink () ()
  (let* ((session (current-dirvish-session))
         (root (and session (dirvish-session-root-window session)))
         (text (and root (dirvish-test-modeline-text root))))
    (dirvish-test-log
     "SYMLINK row=~a segment=~a target=~a"
     (or (dirvish-test-current-name) "none")
     (if (and text (search "→" text)) "yes" "no")
     (if (and text (search "open.txt" text)) "yes" "no"))))

(define-command lem-yath-test-dirvish-record () ()
  (dirvish-test-open-directory)
  (destructuring-bind (file-line file-size file-source file-path)
      (dirvish-test-row "size.bin")
    (declare (ignore file-path))
    (destructuring-bind (directory-line directory-size directory-source
                         directory-path)
        (dirvish-test-row "child")
      (declare (ignore directory-path))
      (dirvish-test-log
       (concatenate
        'string
        "DISPLAY width=~d file-cells=~d file-tail=~a file-size=~a "
        "file-source=~a directory-cells=~d directory-tail=~a "
        "directory-size=~a directory-source=~a modified=~a readonly=~a")
       (lem-core::window-body-width (current-window))
       (lem/common/character:string-width file-line)
       (dirvish-test-visible (subseq file-line (- (length file-line) 6)))
       (dirvish-test-visible file-size)
       (dirvish-test-visible file-source)
       (lem/common/character:string-width directory-line)
       (dirvish-test-visible
        (subseq directory-line (- (length directory-line) 6)))
       (dirvish-test-visible directory-size)
       (dirvish-test-visible directory-source)
       (if (buffer-modified-p (current-buffer)) "yes" "no")
       (if (buffer-read-only-p (current-buffer)) "yes" "no")))))

(define-command lem-yath-test-dirvish-visit () ()
  (dirvish-test-open-directory)
  (destructuring-bind (line size source pathname)
      (dirvish-test-row "open.txt")
    (declare (ignore line size source))
    (find-file pathname)
    (dirvish-test-log
     "VISIT file=~a text=~a"
     (file-namestring (buffer-filename (current-buffer)))
     (string-right-trim '(#\Newline #\Return) (buffer-text (current-buffer))))))

(define-command lem-yath-test-dirvish-reload () ()
  (load *dirvish-test-source*)
  (load *dirvish-test-source*)
  (dirvish-test-open-directory)
  (lem/directory-mode/internal:update-buffer (current-buffer))
  (dirvish-test-log
   "RELOAD inserters=~d exact=~a transformer=~a"
   (length lem/directory-mode/internal:*file-entry-inserters*)
   (if (equal lem/directory-mode/internal:*file-entry-inserters*
              (list #'insert-dirvish-directory-entry))
       "yes" "no")
   (if (eq (variable-value
            'lem-core::display-line-transform-function :global)
           'transform-lem-yath-display-line)
       "yes" "no")))

(define-command lem-yath-test-dirvish-fullframe () ()
  (dirvish-test-setup-origin-layout)
  (dirvish-open-directory *dirvish-test-root*)
  (let* ((session (current-dirvish-session))
         (windows (window-list))
         (parent (dirvish-session-parent-window session))
         (root (dirvish-session-root-window session))
         (preview (dirvish-session-preview-window session))
         (preview-text
           (buffer-text (dirvish-session-preview-buffer session))))
    (dirvish-test-log
     (concatenate
      'string
      "FULL windows=~d widths=~{~d~^,~} modes=~a,~a,~a focus=~a "
      "command=~a preview-parent=~a readonly=~a")
     (length windows)
     (mapcar #'window-width windows)
     (buffer-major-mode (window-buffer parent))
     (buffer-major-mode (window-buffer root))
     (buffer-major-mode (window-buffer preview))
     (if (eq (current-window) root) "root" "other")
     (if (get-command 'dirvish) "yes" "no")
     (if (search (dirvish-native-path
                  (uiop:pathname-parent-directory-pathname
                   *dirvish-test-root*))
                 preview-text)
         "yes" "no")
     (if (buffer-read-only-p (dirvish-session-preview-buffer session))
         "yes" "no"))))

(define-command lem-yath-test-dirvish-preview () ()
  (let* ((session (current-dirvish-session))
         (preview (and session (dirvish-session-preview-buffer session)))
         (text (and preview (buffer-text preview))))
    (dirvish-test-log
     "PREVIEW row=~a path=~a text=~a readonly=~a timer=~a"
     (or (dirvish-test-current-name) "none")
     (if (and session
              (search "open.txt" (or (dirvish-session-preview-path session) "")))
         "open.txt" "other")
     (if (and text (search "DIRVISH VISIT" text)) "yes" "no")
     (if (and preview (buffer-read-only-p preview)) "yes" "no")
     (if (and session (dirvish-session-preview-timer session))
         "pending" "idle"))))

(define-command lem-yath-test-dirvish-open-report () ()
  (dirvish-test-log
   "OPEN session=~a file=~a shape=~a side=~a selected=~a"
   (if (current-dirvish-session) "yes" "no")
   (if (buffer-filename (current-buffer))
       (file-namestring (buffer-filename (current-buffer)))
       "none")
   (if (equal *dirvish-test-origin-shape*
              (dirvish-test-window-tree
               (lem-core::frame-window-tree (current-frame)) t))
       "restored" "changed")
   (if (equal (mapcar #'buffer-name
                      (mapcar #'window-buffer (window-list)))
              (list "DIRVISH-ORIGIN-A" "open.txt" "DIRVISH-ORIGIN-C"))
       "preserved" "changed")
   (buffer-name (current-buffer))))

(define-command lem-yath-test-dirvish-quit-setup () ()
  (dirvish-test-setup-origin-layout)
  (dirvish-open-directory *dirvish-test-root*)
  (dirvish-test-log "QUIT-READY session=~a"
                    (if (current-dirvish-session) "yes" "no")))

(define-command lem-yath-test-dirvish-quit-report () ()
  (dirvish-test-log
   "QUIT session=~a tree=~a selected=~a preview-live=~a"
   (if (current-dirvish-session) "yes" "no")
   (if (equal *dirvish-test-origin-tree*
              (dirvish-test-window-tree
               (lem-core::frame-window-tree (current-frame))))
       "restored" "changed")
   (buffer-name (current-buffer))
   (if (get-buffer "*Dirvish Preview*") "yes" "no")))

(define-command lem-yath-test-dirvish-toggle () ()
  (dirvish-test-setup-origin-layout)
  (dirvish-open-directory *dirvish-test-root*)
  (dirvish-layout-toggle)
  (dirvish-test-log
   "TOGGLE session=~a shape=~a selected-mode=~a sides=~a"
   (if (current-dirvish-session) "yes" "no")
   (if (equal *dirvish-test-origin-shape*
              (dirvish-test-window-tree
               (lem-core::frame-window-tree (current-frame)) t))
       "restored" "changed")
   (buffer-major-mode (current-buffer))
   (if (equal (mapcar #'buffer-name
                      (mapcar #'window-buffer (window-list)))
              (list "DIRVISH-ORIGIN-A"
                    (buffer-name (current-buffer))
                    "DIRVISH-ORIGIN-C"))
       "preserved" "changed")))

(define-command lem-yath-test-dirvish-safe-preview () ()
  (let ((binary
          (dirvish-preview-text
           (merge-pathnames "size.bin" *dirvish-test-root*)))
        (special
          (dirvish-preview-text
           (merge-pathnames "special.fifo" *dirvish-test-root*)))
        (crowded
          (dirvish-preview-text
           (merge-pathnames "zz-crowded/" *dirvish-test-root*)))
        (small-directory (dirvish-preview-text *dirvish-test-root*)))
    (let ((archive
            (dirvish-preview-text
             (merge-pathnames "preview-archive;safe.zip" *dirvish-test-root*)))
          (epub
            (dirvish-preview-text
             (merge-pathnames "preview-book.epub" *dirvish-test-root*)))
          (pdf
            (dirvish-preview-text
             (merge-pathnames "preview-paper.pdf" *dirvish-test-root*)))
          (media
            (dirvish-preview-text
             (merge-pathnames "preview-image.png" *dirvish-test-root*)))
          (oversized
            (dirvish-preview-text
             (merge-pathnames "zz-oversized.pdf" *dirvish-test-root*))))
    (dirvish-test-log
     (concatenate
      'string
      "SAFE binary=~a special=~a bounded=~a eof=~a archive=~a "
      "epub=~a pdf=~a media=~a oversized=~a debounce=~d throttle=~d limit=~d "
      "timeout=~d output=~d input=~d")
     (if (search "binary" binary) "yes" "no")
     (if (search "Special files are never opened" special) "yes" "no")
     (if (search "first 200 entries shown" crowded) "yes" "no")
     (if (and (search "open.txt" small-directory)
              (not (search "Preview unavailable" small-directory)))
         "yes" "no")
     (if (search "zz-archive-member.txt" archive) "yes" "no")
     (if (search "Dirvish EPUB body" epub) "yes" "no")
     (if (search "Dirvish PDF Page" pdf) "yes" "no")
     (if (search "PNG image data" media) "yes" "no")
     (if (search "larger than 128 MiB" oversized) "yes" "no")
     +dirvish-preview-debounce-milliseconds+
     +dirvish-preview-throttle-milliseconds+
     +dirvish-preview-directory-limit+
     +dirvish-preview-process-timeout+
     +dirvish-preview-process-output-limit+
     +dirvish-preview-derived-input-limit+))))

(define-command lem-yath-test-dirvish-derived-setup () ()
  (dirvish-test-setup-origin-layout)
  (dirvish-open-directory *dirvish-test-root*)
  (let* ((session (current-dirvish-session))
         (root (dirvish-session-root-window session))
         (pathname (merge-pathnames "open.txt" *dirvish-test-root*)))
    (dirvish-position-on-path root pathname)
    (dirvish-refresh-session session t)
    (dirvish-test-log "DERIVED-READY row=~a session=~a"
                      (dirvish-test-current-name)
                      (if session "yes" "no"))))

(define-command lem-yath-test-dirvish-derived-report () ()
  (let* ((session (current-dirvish-session))
         (text (and session
                    (buffer-text (dirvish-session-preview-buffer session)))))
    (dirvish-test-log
     "DERIVED row=~a archive=~a epub=~a pdf=~a media=~a extracted=~a request=~a"
     (or (dirvish-test-current-name) "none")
     (if (and text (search "zz-archive-member.txt" text)) "yes" "no")
     (if (and text (search "Dirvish EPUB body" text)) "yes" "no")
     (if (and text (search "Dirvish PDF Page" text)) "yes" "no")
     (if (and text (search "PNG image data" text)) "yes" "no")
     (if (probe-file (merge-pathnames "zz-archive-member.txt"
                                      *dirvish-test-root*))
         "yes" "no")
     (if (and session (dirvish-session-preview-request session))
         "pending" "idle"))))

(define-command lem-yath-test-dirvish-mx-report () ()
  (let ((session (current-dirvish-session)))
    (when session
      (setf *dirvish-test-mx-preview*
            (dirvish-session-preview-buffer session)))
    (dirvish-test-log
     "MX session=~a windows=~d focus=~a selected-mode=~a preview-live=~a"
     (if session "yes" "no")
     (length (window-list))
     (if (and session
              (eq (current-window) (dirvish-session-root-window session)))
         "root" "other")
     (buffer-major-mode (current-buffer))
     (if (dirvish-live-buffer-p *dirvish-test-mx-preview*) "yes" "no"))))

(define-key *global-keymap* "F2" 'lem-yath-test-dirvish-record)
(define-key *global-keymap* "F3" 'lem-yath-test-dirvish-visit)
(define-key *global-keymap* "F4" 'lem-yath-test-dirvish-reload)
(define-key *global-keymap* "F5" 'lem-yath-test-dirvish-fullframe)
(define-key *global-keymap* "F6" 'lem-yath-test-dirvish-preview)
(define-key *global-keymap* "F7" 'lem-yath-test-dirvish-open-report)
(define-key *global-keymap* "F8" 'lem-yath-test-dirvish-quit-setup)
(define-key *global-keymap* "F9" 'lem-yath-test-dirvish-quit-report)
(define-key *global-keymap* "F10" 'lem-yath-test-dirvish-toggle)
(define-key *global-keymap* "F11" 'lem-yath-test-dirvish-safe-preview)
(define-key *global-keymap* "F12" 'lem-yath-test-dirvish-mx-report)
(define-key *global-keymap* "C-c D" 'lem-yath-test-dirvish-derived-setup)
(define-key *global-keymap* "C-c R" 'lem-yath-test-dirvish-derived-report)
(define-key *global-keymap* "C-c H" 'lem-yath-test-dirvish-chrome)
(define-key *global-keymap* "C-c S" 'lem-yath-test-dirvish-symlink)

(setf *dirvish-test-origin-a*
      (dirvish-test-buffer "DIRVISH-ORIGIN-A" "origin A\n")
      *dirvish-test-origin-b*
      (dirvish-test-buffer "DIRVISH-ORIGIN-B" "origin B\n")
      *dirvish-test-origin-c*
      (dirvish-test-buffer "DIRVISH-ORIGIN-C" "origin C\n"))

(dirvish-test-open-directory)
(dirvish-test-log
 "STATIC mode=~a inserters=~d exact=~a bytes=~a count=~a"
 (buffer-major-mode (current-buffer))
 (length lem/directory-mode/internal:*file-entry-inserters*)
 (if (equal lem/directory-mode/internal:*file-entry-inserters*
            (list #'insert-dirvish-directory-entry))
     "yes" "no")
 (dirvish-test-visible (dirvish-human-readable 1536 1024))
 (dirvish-test-visible (dirvish-human-readable 3 1000)))
(dirvish-test-log "READY")
