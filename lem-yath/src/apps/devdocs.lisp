;;;; devdocs -> an honest terminal port of devdocs-lookup (SPC h d).
;;;; DevDocs in Emacs fetches a docset's index.json, lets you pick an entry,
;;;; then renders the entry's HTML page. We do the same over curl on a
;;;; background thread, strip the HTML to readable text with cl-ppcre, and show
;;;; it in a read-only "*lem-yath-devdocs*" buffer. No dexador/drakma in the image,
;;;; so all HTTP is curl via uiop; all buffer mutation is marshalled back onto
;;;; the editor thread with send-event. Offline degrades to a message.

(in-package :lem-yath)

(declaim (ftype function run-project-program))
(declaim (special *project-process-timeout*))

(defvar *devdocs-docsets*
  (list "go" "rust" "python~3.12" "nix" "javascript" "typescript")
  "Common slugs offered initially by `lem-yath-devdocs-lookup'.
`lem-yath-devdocs-install' validates and adds more for the current session.")

(defvar *devdocs-base-url* "https://documents.devdocs.io"
  "Where DevDocs serves index.json and the per-entry HTML pages.")

(defvar *devdocs-index-cache* (make-hash-table :test 'equal)
  "Slug -> list of (name . path) entries, cached for the session.")

(defvar *devdocs-buffer-name* "*lem-yath-devdocs*")

(defvar *devdocs-curl-timeout* 10
  "curl --max-time for every DevDocs fetch, in seconds.")

(defvar *devdocs-output-limit* (* 16 1024 1024)
  "Maximum stdout or stderr accepted from one DevDocs request.")

(defvar *devdocs-request-generation* 0
  "Monotonic owner for asynchronous index and page requests.")

;;; --- mode: read-only viewer with q (quit) and b (browser fallback) ----------

(define-major-mode devdocs-mode ()
    (:name "DevDocs"
     :keymap *devdocs-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode devdocs-mode))
  (list *devdocs-mode-keymap*))

(define-key *devdocs-mode-keymap* "q" 'quit-active-window)
(define-key *devdocs-mode-keymap* "b" 'lem-yath-devdocs-open-in-browser)

;;; --- HTTP (curl) ------------------------------------------------------------

(defun devdocs-curl (url)
  "Fetch URL with curl, returning its body string, or NIL on any failure.
Never signals: a missing binary, network error or non-zero exit yields NIL."
  (handler-case
      (let ((curl (executable-find "curl"))
            (*project-process-timeout* (+ *devdocs-curl-timeout* 2)))
        (unless curl (return-from devdocs-curl nil))
        (multiple-value-bind (out err code)
            (run-project-program
             (list (uiop:native-namestring curl)
                   "-fsSL"
                   "--max-time" (princ-to-string *devdocs-curl-timeout*)
                   url)
             :directory (uiop:getcwd)
             :output-limit *devdocs-output-limit*)
          (declare (ignore err))
          (when (and (eql code 0) (plusp (length out))) out)))
    (error () nil)))

;;; --- index.json -------------------------------------------------------------

(defun devdocs-index-url (slug)
  ;; DevDocs slugs are URL-safe path segments (alnum, '~', '.'), verified to
  ;; work raw; no percent-encoding needed and it would only risk over-encoding.
  (format nil "~a/~a/index.json" *devdocs-base-url* slug))

(defun devdocs-parse-index (json-string)
  "Parse a DevDocs index.json body into a list of (name . path), or NIL."
  (handler-case
      (let* ((json (yason:parse json-string))
             (entries (and (hash-table-p json) (gethash "entries" json))))
        (loop :for entry :in (and (listp entries) entries)
              :for name := (and (hash-table-p entry) (gethash "name" entry))
              :for path := (and (hash-table-p entry) (gethash "path" entry))
              :when (and (stringp name) (stringp path))
                :collect (cons name path)))
    (error () nil)))

(defun devdocs-next-generation ()
  "Invalidate older asynchronous work and return the new request generation."
  (incf *devdocs-request-generation*))

(defun devdocs-request-current-p (generation)
  "Whether GENERATION still owns the interactive DevDocs workflow."
  (= generation *devdocs-request-generation*))

(defun devdocs-with-index (slug generation continuation)
  "Call CONTINUATION with SLUG's entries on the editor thread.
Use the session cache immediately; otherwise fetch off-thread and cache only a
valid latest-generation response."
  (alexandria:if-let ((cached (gethash slug *devdocs-index-cache*)))
    (when (devdocs-request-current-p generation)
      (funcall continuation cached))
    (bt2:make-thread
     (lambda ()
       (let* ((body (devdocs-curl (devdocs-index-url slug)))
              (entries (and body (devdocs-parse-index body))))
         (send-event
          (lambda ()
            (when (devdocs-request-current-p generation)
              (if entries
                  (progn
                    (setf (gethash slug *devdocs-index-cache*) entries)
                    (funcall continuation entries))
                  (message "DevDocs: couldn't load index for ~a (offline?)"
                           slug)))))))
     :name "lem-yath/devdocs-index")))

;;; --- entry page -------------------------------------------------------------

(defun devdocs-path-without-fragment (path)
  "Drop a #fragment from a DevDocs entry PATH (e.g. \"a/b/index#X\" -> \"a/b/index\")."
  (let ((hash (position #\# path)))
    (if hash (subseq path 0 hash) path)))

(defun devdocs-page-url (slug path)
  "URL of the HTML page for SLUG's entry at PATH (fragment dropped, .html added)."
  (format nil "~a/~a/~a.html"
          *devdocs-base-url*
          slug
          (devdocs-path-without-fragment path)))

(defun devdocs-browser-url (slug path)
  "The human devdocs.io URL for SLUG/PATH (browser fallback, keeps the fragment)."
  (format nil "https://devdocs.io/~a/~a" slug path))

;;; --- HTML -> readable text --------------------------------------------------

(defun devdocs-decode-entities (string)
  "Decode the handful of HTML entities DevDocs pages actually use."
  (let ((s string))
    (dolist (pair '(("&lt;" . "<") ("&gt;" . ">") ("&quot;" . "\"")
                    ("&#39;" . "'") ("&#34;" . "\"") ("&nbsp;" . " ")
                    ("&amp;" . "&")))                 ; &amp; last: avoids re-decoding
      (setf s (cl-ppcre:regex-replace-all (cl-ppcre:quote-meta-chars (car pair))
                                          s (cdr pair))))
    s))

(defun devdocs-html-to-text (html)
  "Strip HTML to readable plain text: drop script/style, keep paragraphs and
code blocks legible by turning block-level tags into newlines."
  (handler-case
      (let ((s html))
        ;; Remove whole <script>/<style> elements (content and all).
        (setf s (cl-ppcre:regex-replace-all "(?is)<(script|style)[^>]*>.*?</\\1>" s ""))
        ;; <br> and block-closing tags become single newlines; <p>/<pre>/headings
        ;; and list items get a blank line / newline so structure survives.
        (setf s (cl-ppcre:regex-replace-all "(?i)<br\\s*/?>" s (string #\Newline)))
        (setf s (cl-ppcre:regex-replace-all
                 "(?i)</?(p|pre|div|h[1-6]|ul|ol|table|tr|blockquote|section|article|header)[^>]*>"
                 s (format nil "~%~%")))
        (setf s (cl-ppcre:regex-replace-all "(?i)<li[^>]*>" s (format nil "~%  - ")))
        (setf s (cl-ppcre:regex-replace-all "(?i)</(li|td|th|h[1-6])>" s (string #\Newline)))
        ;; Drop every remaining tag.
        (setf s (cl-ppcre:regex-replace-all "(?s)<[^>]*>" s ""))
        (setf s (devdocs-decode-entities s))
        ;; Collapse runs of blank lines / trailing spaces.
        (setf s (cl-ppcre:regex-replace-all "[ \\t]+(?=\\n)" s ""))
        (setf s (cl-ppcre:regex-replace-all "\\n{3,}" s (format nil "~%~%")))
        (string-trim '(#\Space #\Tab #\Newline #\Return) s))
    (error () html)))

;;; --- rendering --------------------------------------------------------------

(defun devdocs-show-text (slug path text generation)
  "Populate the *lem-yath-devdocs* buffer with TEXT (editor thread only).
Records SLUG/PATH on the buffer so the `b' browser fallback can use them."
  (let ((buffer (make-buffer *devdocs-buffer-name*)))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-end-point buffer)
                     (format nil "DevDocs: ~a/~a~%~a~%~%~a~%"
                             slug (devdocs-path-without-fragment path)
                             "(q quits, b opens in browser)"
                             text)))
    (change-buffer-mode buffer 'devdocs-mode)
    (setf (buffer-value buffer 'devdocs-slug) slug
          (buffer-value buffer 'devdocs-path) path
          (buffer-value buffer 'devdocs-generation) generation)
    (move-point (buffer-point buffer) (buffer-start-point buffer))
    (switch-to-window (pop-to-buffer buffer))
    (redraw-display)))

(defun devdocs-fetch-and-show (slug name path generation)
  "On a worker thread: fetch SLUG/PATH's page, strip it, and display it.
Marshals the buffer update back onto the editor thread; degrades to a message."
  (bt2:make-thread
   (lambda ()
     (let ((html (devdocs-curl (devdocs-page-url slug path))))
       (send-event
        (lambda ()
          (when (devdocs-request-current-p generation)
            (if html
                (devdocs-show-text
                 slug path (devdocs-html-to-text html) generation)
                (message "DevDocs: couldn't fetch ~a (offline?)" name)))))))
   :name "lem-yath/devdocs"))

;;; --- prompts ----------------------------------------------------------------

(defun devdocs-prompt-docset ()
  "Prompt for a docset slug using the configured Prescient matching."
  (prompt-for-string "DevDocs docset: "
                     :completion-function
                     (lambda (s) (prescient-filter s *devdocs-docsets*))
                     :test-function (lambda (s) (plusp (length s)))
                     :history-symbol 'lem-yath-devdocs-docset))

(defun devdocs-prompt-entry (entries)
  "Prompt for an entry name among ENTRIES using Prescient matching."
  (let ((names (mapcar #'car entries)))
    (prompt-for-string "DevDocs entry: "
                       :completion-function
                       (lambda (s) (prescient-filter s names))
                       :test-function (lambda (s) (member s names :test #'string=))
                       :history-symbol 'lem-yath-devdocs-entry)))

;;; --- commands ---------------------------------------------------------------

(defun devdocs-register-docset (slug)
  "Offer SLUG in later completion without duplicating it."
  (unless (member slug *devdocs-docsets* :test #'string=)
    (setf *devdocs-docsets* (append *devdocs-docsets* (list slug)))))

(defun devdocs-prompt-and-fetch-entry (slug entries generation)
  "Prompt within ENTRIES, then fetch the chosen page for GENERATION."
  (when (devdocs-request-current-p generation)
    (let ((name (devdocs-prompt-entry entries)))
      (when (and name (plusp (length name)))
        (alexandria:when-let ((path (cdr (assoc name entries :test #'string=))))
          (message "DevDocs: fetching ~a..." name)
          (devdocs-fetch-and-show slug name path generation))))))

(define-command lem-yath-devdocs-install () ()
  "Fetch and cache a docset index for this session (devdocs-install)."
  (let ((slug (string-trim '(#\Space) (prompt-for-string "Install docset slug: "))))
    (if (zerop (length slug))
        (message "DevDocs: no slug given")
        (let ((generation (devdocs-next-generation)))
          (message "DevDocs: installing ~a..." slug)
          (devdocs-with-index
           slug generation
           (lambda (entries)
             (declare (ignore entries))
             (devdocs-register-docset slug)
             (message "DevDocs: installed ~a for this session" slug)))))))

(define-command lem-yath-devdocs-lookup () ()
  "Look up DevDocs documentation (devdocs-lookup, SPC h d).
Pick a docset, then an entry; the page is fetched and rendered on a background
thread, so the editor never blocks. Offline degrades to a message."
  (let ((slug (devdocs-prompt-docset)))
    (when (plusp (length slug))
      (let ((generation (devdocs-next-generation)))
        (message "DevDocs: fetching index for ~a..." slug)
        (devdocs-with-index
         slug generation
         (lambda (entries)
           (devdocs-prompt-and-fetch-entry slug entries generation)))))))

(define-command lem-yath-devdocs-open-in-browser () ()
  "Open the current DevDocs entry in a browser via xdg-open (fallback `b')."
  (let ((buffer (current-buffer)))
    (alexandria:if-let ((slug (buffer-value buffer 'devdocs-slug))
                        (path (buffer-value buffer 'devdocs-path)))
      (let ((url (devdocs-browser-url slug path)))
        (alexandria:if-let ((opener (executable-find "xdg-open")))
          (handler-case
              (progn
                (uiop:launch-program
                 (list (uiop:native-namestring opener) url)
                 :output nil :error-output nil)
                (message "DevDocs: opened ~a" url))
            (error () (message "DevDocs: couldn't launch browser for ~a" url)))
          (message "DevDocs: xdg-open is unavailable")))
      (message "DevDocs: no entry in this buffer"))))
