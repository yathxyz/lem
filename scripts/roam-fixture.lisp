(in-package :lem-yath)

(defvar *roam-test-report-path* (uiop:getenv "LEM_YATH_ROAM_REPORT"))
(defvar *roam-test-origin* (pathname (uiop:getenv "LEM_YATH_ROAM_ORIGIN")))
(defvar *roam-test-markdown-origin*
  (pathname (uiop:getenv "LEM_YATH_ROAM_MARKDOWN_ORIGIN")))
(defvar *roam-test-text-origin*
  (pathname (uiop:getenv "LEM_YATH_ROAM_TEXT_ORIGIN")))
(defvar *roam-test-race-outside*
  (pathname (uiop:getenv "LEM_YATH_ROAM_RACE_OUTSIDE")))

(defun roam-test-report (control &rest arguments)
  (with-open-file (stream *roam-test-report-path*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun roam-test-yes-no (value)
  (if value "yes" "no"))

(defun roam-test-node (nodes id)
  (find id nodes :test #'string= :key #'roam-node-id))

(defun roam-test-count-substring (needle haystack)
  (loop :with start := 0
        :for position := (search needle haystack :start2 start)
        :while position
        :count t
        :do (setf start (+ position (length needle)))))

(defun roam-test-editor-error-p (thunk)
  (handler-case
      (progn (funcall thunk) nil)
    (editor-error () t)))

(defun roam-test-directory-entry-name (pathname)
  (string-right-trim "/" (uiop:native-namestring pathname)))

(defun roam-test-containment-race-status ()
  (let* ((root (truename (roam-directory)))
         (parent (merge-pathnames "race-parent/" root))
         (saved (merge-pathnames "race-parent-saved/" root))
         (captured (truename (merge-pathnames "probe.txt" parent)))
         (parent-name (roam-test-directory-entry-name parent))
         (saved-name (roam-test-directory-entry-name saved))
         (outside-name
           (roam-test-directory-entry-name *roam-test-race-outside*))
         (renamed-p nil)
         (linked-p nil))
    (unwind-protect
         (handler-case
             (progn
               (sb-posix:rename parent-name saved-name)
               (setf renamed-p t)
               (sb-posix:symlink outside-name parent-name)
               (setf linked-p t)
               (nth-value 2 (roam-read-note captured root)))
           (error () :test-error))
      (when linked-p
        (ignore-errors (sb-posix:unlink parent-name)))
      (when renamed-p
        (ignore-errors (sb-posix:rename saved-name parent-name))))))

(defun roam-test-run-static ()
  (let* ((buffers-before (length (buffer-list)))
         (nodes (note-nodes))
         (file (roam-test-node nodes "file-id"))
         (heading (roam-test-node nodes "heading-id"))
         (markdown (roam-test-node nodes "markdown-id"))
         (markdown-block (roam-test-node nodes "markdown-block-id"))
         (mutable (roam-test-node nodes "mutable-old"))
         (duplicate-a (roam-test-node nodes "duplicate-a"))
         (duplicate-b (roam-test-node nodes "duplicate-b"))
         (unclosed (roam-test-node nodes "unclosed-file"))
         (files (note-files))
         (buffers-after (length (buffer-list)))
         (failures 0))
    (labels ((check (condition label)
               (roam-test-report "~a ~a"
                                 (if condition "PASS" "FAIL") label)
               (unless condition (incf failures))))
      (check (= 11 (length nodes)) "node-count")
      (check (= 8 (length files)) "unique-file-count")
      (check (= buffers-before buffers-after) "index-opens-no-buffers")
      (check (and file
                  (eq :org-file (roam-node-kind file))
                  (string= "File Node" (roam-node-title file))
                  (equal '("File Alias" "bare alias")
                         (roam-node-aliases file))
                  (equal '("filetag" "shared") (roam-node-tags file)))
             "org-file-metadata")
      (check (and heading
                  (eq :org-heading (roam-node-kind heading))
                  (= 14 (roam-node-line heading))
                  (= 2 (roam-node-level heading))
                  (string= "Heading Node" (roam-node-title heading))
                  (equal '("Heading Alias" "mixed")
                         (roam-node-aliases heading))
                  (equal '("filetag" "shared" "ancestor" "local")
                         (roam-node-tags heading)))
             "org-heading-metadata")
      (check (and duplicate-a duplicate-b
                  (string= (roam-node-title duplicate-a)
                           (roam-node-title duplicate-b))
                  (/= (roam-node-line duplicate-a)
                      (roam-node-line duplicate-b)))
             "duplicate-title-distinct-identity")
      (check (and markdown
                  (eq :markdown-file (roam-node-kind markdown))
                  (string= "Markdown Node" (roam-node-title markdown))
                  (equal '("project" "deep-work")
                         (roam-node-tags markdown))
                  (equal '("Mark Alias" "MarkBare")
                         (roam-node-aliases markdown)))
             "markdown-flow-metadata")
      (check (and markdown-block
                  (string= "Block Markdown" (roam-node-title markdown-block))
                  (equal '("block-one" "block_two")
                         (roam-node-tags markdown-block)))
             "markdown-zettlr-metadata")
      (check (and mutable (string= "MutableAlias"
                                   (first (roam-node-aliases mutable))))
             "mutable-node-indexed")
      (check (and unclosed
                  (null (roam-test-node nodes "block-decoy")))
             "unclosed-block-fails-closed")
      (check (and (null (roam-test-node nodes "late-drawer"))
                  (null (roam-test-node nodes "sync-conflict"))
                  (null (roam-test-node nodes "binary-id"))
                  (null (roam-test-node nodes "invalid-id"))
                  (null (roam-test-node nodes "oversized-id")))
             "unsafe-and-nonnodes-excluded")
      (check (and (roam-test-node nodes "hidden-id")
                  (roam-test-node nodes "ignored-id"))
             "hidden-and-ignored-notes-indexed")
      (check (equal '("heading-id")
                    (mapcar #'roam-node-id
                            (prescient-filter
                             "Heading Alias #local" nodes
                             :key #'roam-node-search-text
                             :rank-p nil)))
             "metadata-filtering")
      (check (and (equal '("heading-id")
                         (mapcar #'roam-node-id
                                 (prescient-filter
                                  "heading" nodes
                                  :key #'roam-node-search-text :rank-p nil)))
                  (null (prescient-filter
                         "HEADING" nodes
                         :key #'roam-node-search-text :rank-p nil)))
             "smart-case-filtering")
      (check (and (null (roam-unique-node-for-prompt-text
                         "sub/duplicates.org" nodes))
                  (alexandria:when-let
                      ((node (roam-unique-node-for-prompt-text
                              "markdown.md" nodes)))
                    (string= "markdown-id" (roam-node-id node))))
             "direct-path-identity")
      (check (eq :oversized
                 (nth-value
                  2
                  (roam-read-note
                   (merge-pathnames "oversized.org" (roam-directory))
                   (truename (roam-directory)))))
             "oversized-status")
      (check (roam-test-editor-error-p
              (lambda ()
                (let ((*roam-file-count-limit* 1)) (note-nodes))))
             "file-count-limit")
      (check (roam-test-editor-error-p
              (lambda ()
                (let ((*roam-total-byte-limit* 1)) (note-nodes))))
             "aggregate-byte-limit")
      (check (roam-test-editor-error-p
              (lambda ()
                (let ((*roam-node-count-limit* 0)) (note-nodes))))
             "node-count-limit")
      (check (eq :outside (roam-test-containment-race-status))
             "descriptor-containment-race")
      (roam-test-report "STATIC ~a failures=~d"
                        (if (zerop failures) "PASS" "FAIL") failures))))

(defun roam-test-current-relative-path ()
  (let ((file (buffer-filename (current-buffer)))
        (root (ignore-errors (truename (roam-directory)))))
    (and file
         root
         (ignore-errors
           (let ((resolved (truename file)))
             (and (roam-path-in-root-p resolved root)
                  (enough-namestring resolved root)))))))

(define-command lem-yath-test-roam-reset-origin () ()
  (find-file *roam-test-origin*)
  (buffer-end (current-point))
  (roam-test-report "ORIGIN-RESET file=~a line=~d"
                    (pathname-name *roam-test-origin*)
                    (line-number-at-point (current-point))))

(define-command lem-yath-test-roam-current () ()
  (roam-test-report "CURRENT file=~a line=~d"
                    (or (roam-test-current-relative-path) "outside")
                    (line-number-at-point (current-point))))

(define-command lem-yath-test-roam-origin-state () ()
  (let ((buffer (find-file-buffer *roam-test-origin*)))
    (with-current-buffer buffer
      (let* ((text (points-to-string (buffer-start-point buffer)
                                     (buffer-end-point buffer)))
             (link "[[id:heading-id][Heading Node]]"))
        (roam-test-report "ORIGIN link=~a count=~d modified=~a"
                          (roam-test-yes-no (search link text))
                          (roam-test-count-substring link text)
                          (roam-test-yes-no (buffer-modified-p buffer)))))))

(define-command lem-yath-test-roam-reset-markdown-origin () ()
  (find-file *roam-test-markdown-origin*)
  (buffer-end (current-point))
  (roam-test-report "MARKDOWN-RESET line=~d"
                    (line-number-at-point (current-point))))

(define-command lem-yath-test-roam-markdown-state () ()
  (let ((buffer (find-file-buffer *roam-test-markdown-origin*)))
    (with-current-buffer buffer
      (let* ((text (points-to-string (buffer-start-point buffer)
                                     (buffer-end-point buffer)))
             (link "[[Markdown Node]]"))
        (roam-test-report "MARKDOWN link=~a count=~d modified=~a"
                          (roam-test-yes-no (search link text))
                          (roam-test-count-substring link text)
                          (roam-test-yes-no (buffer-modified-p buffer)))))))

(define-command lem-yath-test-roam-dirty-target () ()
  (let ((target (merge-pathnames "file-node.org" (roam-directory))))
    (find-file target)
    (buffer-start (current-point))
    (insert-string (current-point) "UNSAVED\n")
    (let ((target-buffer (current-buffer)))
      (find-file *roam-test-origin*)
      (buffer-end (current-point))
      (roam-test-report "DIRTY target=~a origin-line=~d"
                        (roam-test-yes-no
                         (buffer-modified-p target-buffer))
                        (line-number-at-point (current-point))))))

(define-command lem-yath-test-roam-reset-text-origin () ()
  (find-file *roam-test-text-origin*)
  (buffer-end (current-point))
  (roam-test-report "TEXT-RESET line=~d"
                    (line-number-at-point (current-point))))

(define-key *global-keymap* "F5" 'lem-yath-test-roam-reset-origin)
(define-key *global-keymap* "F6" 'lem-yath-test-roam-current)
(define-key *global-keymap* "F7" 'lem-yath-test-roam-origin-state)
(define-key *global-keymap* "F8" 'lem-yath-test-roam-reset-markdown-origin)
(define-key *global-keymap* "F9" 'lem-yath-test-roam-markdown-state)
(define-key *global-keymap* "F10" 'lem-yath-test-roam-dirty-target)
(define-key *global-keymap* "F11" 'lem-yath-test-roam-reset-text-origin)

(with-open-file (stream *roam-test-report-path*
                        :direction :output
                        :if-exists :supersede
                        :if-does-not-exist :create))
(roam-test-run-static)
(roam-test-report "READY boot=~a" (roam-test-yes-no (boot-ok-p)))
