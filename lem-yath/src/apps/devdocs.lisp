;;;; devdocs -> an honest terminal port of devdocs-lookup (SPC h d).
;;;; DevDocs in Emacs fetches a docset's index.json, lets you pick an entry,
;;;; then renders the entry's HTML page. We do the same over curl on a
;;;; background thread, strip the HTML to readable text with cl-ppcre, and show
;;;; it in a read-only "*lem-yath-devdocs*" buffer. No dexador/drakma in the image,
;;;; so all HTTP is curl via uiop; all buffer mutation is marshalled back onto
;;;; the editor thread with send-event. Offline degrades to a message.

(in-package :lem-yath)

(defvar *devdocs-docsets*
  (list "go" "rust" "python~3.12" "nix" "javascript" "typescript")
  "DevDocs slugs offered to `lem-yath-devdocs-lookup', mirroring the languages in
this config. `lem-yath-devdocs-install' adds more for the current session.")

(defvar *devdocs-base-url* "https://documents.devdocs.io"
  "Where DevDocs serves index.json and the per-entry HTML pages.")

(defvar *devdocs-index-cache* (make-hash-table :test 'equal)
  "Slug -> list of (name . path) entries, cached for the session.")

(defvar *devdocs-buffer-name* "*lem-yath-devdocs*")

(defvar *devdocs-curl-timeout* "10"
  "curl --max-time for every DevDocs fetch (seconds, as a string).")

;;; --- mode: read-only viewer with q (quit) and b (browser fallback) ----------

(define-major-mode devdocs-mode ()
    (:name "DevDocs"
     :keymap *devdocs-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(define-key *devdocs-mode-keymap* "q" 'quit-active-window)
(define-key *devdocs-mode-keymap* "b" 'lem-yath-devdocs-open-in-browser)

;;; --- HTTP (curl) ------------------------------------------------------------

(defun devdocs-curl (url)
  "Fetch URL with curl, returning its body string, or NIL on any failure.
Never signals: a missing binary, network error or non-zero exit yields NIL."
  (handler-case
      (multiple-value-bind (out err code)
          (uiop:run-program (list "curl" "-fsSL" "--max-time" *devdocs-curl-timeout* url)
                            :output :string
                            :error-output :string
                            :ignore-error-status t)
        (declare (ignore err))
        (when (and (integerp code) (zerop code) (plusp (length out)))
          out))
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

(defun devdocs-index (slug)
  "Return SLUG's entries as a list of (name . path), fetching+caching on miss.
Returns NIL (and leaves the cache untouched) when offline or unparsable."
  (or (gethash slug *devdocs-index-cache*)
      (alexandria:when-let* ((body (devdocs-curl (devdocs-index-url slug)))
                             (entries (devdocs-parse-index body)))
        (setf (gethash slug *devdocs-index-cache*) entries))))

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

(defun devdocs-show-text (slug path text)
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
          (buffer-value buffer 'devdocs-path) path)
    (move-point (buffer-point buffer) (buffer-start-point buffer))
    (switch-to-buffer buffer)
    (redraw-display)))

(defun devdocs-fetch-and-show (slug name path)
  "On a worker thread: fetch SLUG/PATH's page, strip it, and display it.
Marshals the buffer update back onto the editor thread; degrades to a message."
  (bt2:make-thread
   (lambda ()
     (let ((html (devdocs-curl (devdocs-page-url slug path))))
       (send-event
        (lambda ()
          (if html
              (devdocs-show-text slug path (devdocs-html-to-text html))
              (message "DevDocs: couldn't fetch ~a (offline?)" name))))))
   :name "lem-yath/devdocs"))

;;; --- prompts ----------------------------------------------------------------

(defun devdocs-prompt-docset ()
  "Prompt for a docset slug among *devdocs-docsets* with orderless matching."
  (prompt-for-string "DevDocs docset: "
                     :completion-function
                     (lambda (s) (orderless-filter s *devdocs-docsets*))
                     :test-function (lambda (s) (plusp (length s)))
                     :history-symbol 'lem-yath-devdocs-docset))

(defun devdocs-prompt-entry (entries)
  "Prompt for an entry name among ENTRIES (list of (name . path)), orderless."
  (let ((names (mapcar #'car entries)))
    (prompt-for-string "DevDocs entry: "
                       :completion-function
                       (lambda (s) (orderless-filter s names))
                       :test-function (lambda (s) (member s names :test #'string=))
                       :history-symbol 'lem-yath-devdocs-entry)))

;;; --- commands ---------------------------------------------------------------

(define-command lem-yath-devdocs-install () ()
  "Add a docset slug to *devdocs-docsets* for this session (devdocs-install).
Persisted only in the running image, mirroring how the Emacs command pulls a
docset down on demand."
  (let ((slug (string-trim '(#\Space) (prompt-for-string "Install docset slug: "))))
    (cond ((zerop (length slug))
           (message "DevDocs: no slug given"))
          ((member slug *devdocs-docsets* :test #'string=)
           (message "DevDocs: ~a already available" slug))
          (t
           (setf *devdocs-docsets* (append *devdocs-docsets* (list slug)))
           (message "DevDocs: added ~a" slug)))))

(define-command lem-yath-devdocs-lookup () ()
  "Look up DevDocs documentation (devdocs-lookup, SPC h d).
Pick a docset, then an entry; the page is fetched and rendered on a background
thread, so the editor never blocks. Offline degrades to a message."
  (let ((slug (devdocs-prompt-docset)))
    (when (plusp (length slug))
      (message "DevDocs: fetching index for ~a..." slug)
      (let ((entries (devdocs-index slug)))
        (if (null entries)
            (message "DevDocs: couldn't load index for ~a (offline?)" slug)
            (let ((name (devdocs-prompt-entry entries)))
              (when (and name (plusp (length name)))
                (alexandria:when-let ((path (cdr (assoc name entries :test #'string=))))
                  (message "DevDocs: fetching ~a..." name)
                  (devdocs-fetch-and-show slug name path)))))))))

(define-command lem-yath-devdocs-open-in-browser () ()
  "Open the current DevDocs entry in a browser via xdg-open (fallback `b')."
  (let ((buffer (current-buffer)))
    (alexandria:if-let ((slug (buffer-value buffer 'devdocs-slug))
                        (path (buffer-value buffer 'devdocs-path)))
      (let ((url (devdocs-browser-url slug path)))
        (handler-case
            (progn
              (uiop:launch-program (list "xdg-open" url))
              (message "DevDocs: opened ~a" url))
          (error () (message "DevDocs: couldn't launch browser for ~a" url))))
      (message "DevDocs: no entry in this buffer"))))
