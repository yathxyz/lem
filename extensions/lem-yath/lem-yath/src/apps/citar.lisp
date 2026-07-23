;;;; lem-yath apps/citar -- citar -> a lite bibliography front-end over BibTeX.
;;;;
;;;; Mirrors the Emacs citar setup: two bib files are searched in order
;;;; (~/work/librarium/nodes.bib then zotero.bib), candidates are presented as
;;;; "key: author (year) title", and on selection the attached resource is
;;;; resolved like citar-open: the `file' field first (pdf/html opened
;;;; externally with xdg-open, everything else via find-file), then `url'
;;;; (xdg-open), then a note under $WORKDIR/roam/references/<key>.{org,md}.
;;;; A tolerant hand-rolled parser is used: there is no biblatex library in the
;;;; image, and the goal is graceful degradation, not a conformant reader.

(in-package :lem-yath)

(declaim (ftype function project-path-in-directory-p))

(defvar *citar-bib-files*
  (list (merge-pathnames "librarium/nodes.bib" (workdir))
        (merge-pathnames "librarium/zotero.bib" (workdir)))
  "BibTeX files searched in order, mirroring citar's bibliography list.")

(defvar *citar-fields* '("title" "author" "year" "file" "url")
  "BibTeX fields kept on each parsed entry plist (plus :key and :type).")

;;; --- BibTeX parsing --------------------------------------------------------

(defun citar-skip-ws (text i)
  "Index of the first non-whitespace char in TEXT at or after I."
  (let ((len (length text)))
    (loop :while (and (< i len)
                      (member (char text i) '(#\Space #\Tab #\Newline #\Return)))
          :do (incf i))
    i))

(defun citar-read-braced (text i)
  "Read a {brace-balanced} value starting at the opening brace index I.
Returns (values string index-after-closing-brace). Tolerates nested braces."
  (let ((len (length text))
        (out (make-string-output-stream))
        (depth 0))
    (do ((stop nil))
        ((or stop (>= i len)) (values (get-output-stream-string out) i))
      (let ((ch (char text i)))
        (cond
          ((char= ch #\{) (when (plusp depth) (write-char ch out)) (incf depth))
          ((char= ch #\})
           (decf depth)
           (if (zerop depth)
               (setf stop t)
               (write-char ch out)))
          (t (write-char ch out))))
      (incf i))))

(defun citar-read-quoted (text i)
  "Read a \"quoted\" value starting at the opening quote index I.
Returns (values string index-after-closing-quote). Braces inside are kept
balanced so a quote within {} does not terminate the value."
  (let ((len (length text))
        (out (make-string-output-stream))
        (depth 0)
        (escaped-p nil))
    (incf i) ; skip opening quote
    (do ((stop nil))
        ((or stop (>= i len)) (values (get-output-stream-string out) i))
      (let ((ch (char text i)))
        (cond
          ((char= ch #\{) (incf depth) (write-char ch out))
          ((char= ch #\}) (when (plusp depth) (decf depth)) (write-char ch out))
          ((and (char= ch #\") (zerop depth) (not escaped-p))
           (setf stop t))
          (t (write-char ch out)))
        (setf escaped-p (and (char= ch #\\) (not escaped-p))))
      (incf i))))

(defun citar-read-bare (text i)
  "Read a bare (unbraced, unquoted) value -- a number or @string key -- as a
run of non-delimiter characters. Returns (values string index)."
  (let ((len (length text))
        (out (make-string-output-stream)))
    (do ()
        ((or (>= i len)
             (member (char text i) '(#\, #\} #\Space #\Tab #\Newline #\Return)))
         (values (get-output-stream-string out) i))
      (write-char (char text i) out)
      (incf i))))

(defun citar-read-parens (text i)
  "Read a (paren-balanced) entry body starting at the opening paren index I.
Returns (values string index-after-closing-paren). Some BibTeX dialects wrap
entries in parens instead of braces."
  (let ((len (length text))
        (out (make-string-output-stream))
        (depth 0))
    (do ((stop nil))
        ((or stop (>= i len)) (values (get-output-stream-string out) i))
      (let ((ch (char text i)))
        (cond
          ((char= ch #\() (when (plusp depth) (write-char ch out)) (incf depth))
          ((char= ch #\))
           (decf depth)
           (if (zerop depth)
               (setf stop t)
               (write-char ch out)))
          (t (write-char ch out))))
      (incf i))))

(defun citar-normalize-value (string)
  "Collapse internal whitespace (multi-line fields) and trim STRING."
  (string-trim '(#\Space #\Tab #\Newline #\Return)
               (cl-ppcre:regex-replace-all "\\s+" (or string "") " ")))

(defun citar-find-entry-start (text i)
  "Index just past the next @ in TEXT at or after I, or NIL if none remain."
  (let ((at (position #\@ text :start i)))
    (and at (1+ at))))

(defun citar-parse-fields (text i end)
  "Parse `key = value' pairs from TEXT in [I, END) into a plist of lowercased
field name strings -> normalized values, keeping only *citar-fields*."
  (let ((fields '()))
    (loop
      (setf i (citar-skip-ws text i))
      (when (>= i end) (return))
      ;; read field name up to '='
      (let ((eq (position #\= text :start i :end end)))
        (unless eq (return))
        (let ((name (string-downcase
                     (string-trim '(#\Space #\Tab #\Newline #\Return)
                                  (subseq text i eq))))
              (j (citar-skip-ws text (1+ eq))))
          (when (< j end)
            (multiple-value-bind (value next)
                (case (char text j)
                  (#\{ (citar-read-braced text j))
                  (#\" (citar-read-quoted text j))
                  (t (citar-read-bare text j)))
              (when (member name *citar-fields* :test #'string=)
                (setf (getf fields (intern (string-upcase name) :keyword))
                      (citar-normalize-value value)))
              ;; advance past the value, then past an optional trailing comma
              (setf i (citar-skip-ws text next))
              (when (and (< i end) (char= (char text i) #\,))
                (incf i)))))))
    fields))

(defun citar-parse-string (text)
  "Parse BibTeX TEXT into a list of entry plists.
Each plist holds :key, :type and any of *citar-fields* that were present.
@comment and @string preambles are skipped gracefully; malformed entries are
dropped rather than aborting the whole parse."
  (let ((entries '())
        (i 0))
    (loop
      (let ((start (citar-find-entry-start text i)))
        (unless start (return))
        ;; entry type: letters up to '{' or '('
        (let ((open (position-if (lambda (c) (member c '(#\{ #\())) text :start start)))
          (unless open (return))
          (let ((type (string-downcase
                       (string-trim '(#\Space #\Tab #\Newline #\Return)
                                    (subseq text start open)))))
            ;; Read the brace/paren-delimited body to bound the entry.
            (multiple-value-bind (body body-end)
                (if (char= (char text open) #\{)
                    (citar-read-braced text open)
                    (citar-read-parens text open))
              (setf i body-end)
              ;; Skip non-entry preambles.
              (unless (member type '("comment" "string" "preamble") :test #'string=)
                (let ((comma (position #\, body)))
                  (when comma
                    (let* ((key (string-trim '(#\Space #\Tab #\Newline #\Return)
                                             (subseq body 0 comma)))
                           (plist (citar-parse-fields body (1+ comma) (length body))))
                      (when (plusp (length key))
                        (push (list* :key key :type type plist) entries)))))))))))
    (nreverse entries)))

(defun citar-parse-file (path)
  "Parse the bib file at PATH, returning entry plists or NIL when absent/bad."
  (when (uiop:probe-file* path)
    (handler-case
        (citar-parse-string (alexandria:read-file-into-string path :external-format :utf-8))
      (error (e)
        (message "citar: failed to parse ~a: ~a" path e)
        nil))))

(defun citar-entries ()
  "Parse every existing bib file in *citar-bib-files* (in order) and return the
concatenated list of entry plists. Earlier files take precedence on duplicate
keys, matching citar's lookup order."
  (let ((seen (make-hash-table :test 'equal))
        (out '()))
    (dolist (file *citar-bib-files*)
      (dolist (entry (citar-parse-file file))
        (let ((key (getf entry :key)))
          (unless (gethash key seen)
            (setf (gethash key seen) t)
            (push entry out)))))
    (nreverse out)))

;;; --- candidate formatting & lookup -----------------------------------------

(defun citar-author-short (author)
  "Shorten an `author' field to the first surname-ish token for display."
  (let ((a (or author "")))
    (cond
      ((zerop (length a)) "")
      ;; "Last, First and ..." -> "Last"
      ((find #\, a) (string-trim " " (subseq a 0 (position #\, a))))
      ;; "First Last and ..." -> first author, last word
      (t (let* ((first-author (first (cl-ppcre:split "\\s+and\\s+" a)))
                (words (cl-ppcre:split "\\s+" (string-trim " " first-author))))
           (or (car (last words)) ""))))))

(defun citar-candidate-label (entry)
  "Render ENTRY as \"key: author (year) title\" for completion."
  (format nil "~a: ~a (~a) ~a"
          (getf entry :key)
          (citar-author-short (getf entry :author))
          (or (getf entry :year) "")
          (or (getf entry :title) "")))

(defun citar-prompt-entry (prompt entries)
  "Prompt for one of ENTRIES via Prescient-filtered completion; return it or NIL."
  (let* ((labeled (mapcar (lambda (e) (cons (citar-candidate-label e) e)) entries))
         (labels (mapcar #'car labeled))
         (choice (prompt-for-string
                  prompt
                  :completion-function (lambda (s) (prescient-filter s labels))
                  :test-function (lambda (s) (plusp (length s)))
                  :history-symbol 'lem-yath-citar)))
    (cdr (assoc choice labeled :test #'string=))))

;;; --- resource resolution (citar-open) --------------------------------------

(defun citar-file-paths (file-field)
  "Extract candidate file paths from a BibTeX `file' field.
Handles `path;path' (multiple, semicolon-separated) and the Zotero
`:path:mimetype' form (leading colon, trailing mime/type), returning the inner
paths in order."
  (loop :for raw :in (cl-ppcre:split ";" (or file-field ""))
        :for item := (string-trim '(#\Space #\Tab) raw)
        :when (plusp (length item))
          :collect (if (char= (char item 0) #\:)
                       ;; Zotero ":/abs/path.pdf:application/pdf" -> middle segment.
                       (let ((parts (cl-ppcre:split ":" item)))
                         (or (find-if (lambda (p) (plusp (length p))) parts) item))
                       item)))

(defun citar-existing-file (file-field)
  "First plausible existing path from a `file' field, or NIL."
  (loop :for raw :in (citar-file-paths file-field)
        :for path := (if (alexandria:starts-with-subseq "file://" raw)
                         (subseq raw (length "file://"))
                         raw)
        :for expanded := (ignore-errors (expand-file-name path))
        :for existing := (and expanded (uiop:probe-file* expanded))
        :when existing :return existing))

(defun citar-open-external (target)
  "Open TARGET (a path or url) in the desktop default app via xdg-open.
Degrades to a message when xdg-open is unavailable."
  (alexandria:if-let ((opener (executable-find "xdg-open")))
      (handler-case
          (progn
            (uiop:launch-program
             (list (uiop:native-namestring opener)
                   (princ-to-string target))
             :output nil :error-output nil)
            (message "Opened externally: ~a" target))
        (error (e) (message "citar: xdg-open failed: ~a" e)))
      (message "xdg-open not found; cannot open ~a" target)))

(defun citar-http-url-p (string)
  "Whether STRING is an HTTP(S) URL suitable for external opening."
  (and (stringp string)
       (or (alexandria:starts-with-subseq "https://" string)
           (alexandria:starts-with-subseq "http://" string))))

(defun citar-external-extension-p (path)
  "True when PATH should be opened externally (pdf/html) rather than find-file."
  (let ((type (string-downcase (or (pathname-type (pathname path)) ""))))
    (member type '("pdf" "html" "htm") :test #'string=)))

(defun citar-note-path (key)
  "Existing note path for KEY under $WORKDIR/roam/references/, or NIL.
Checks .org then .md, mirroring citar-notes-paths."
  (when (and (stringp key)
             (plusp (length key))
             (not (find #\/ key))
             (not (find #\\ key)))
    (let ((dir (merge-pathnames "roam/references/" (workdir))))
      (loop :for type :in '("org" "md")
            :for candidate := (ignore-errors
                                (merge-pathnames
                                 (format nil "~a.~a" key type)
                                 dir))
            :for existing := (and candidate
                                  (ignore-errors (uiop:probe-file* candidate)))
            :when (and existing (project-path-in-directory-p existing dir))
              :return existing))))

(defun citar-open-entry (entry)
  "Resolve and open ENTRY's resource, mirroring citar-open's precedence:
file field -> url -> note. Reports when nothing is available."
  (let ((key (getf entry :key))
        (path (citar-existing-file (getf entry :file)))
        (url (getf entry :url))
        (note nil))
    (setf note (citar-note-path key))
    (cond
      (path
       (if (citar-external-extension-p path)
           (citar-open-external path)
           (find-file path)))
      ((citar-http-url-p url)
       (citar-open-external url))
      (note (find-file note))
      (t (message "No file, url or note for ~a" key)))))

;;; --- commands --------------------------------------------------------------

(define-command lem-yath-citar-open () ()
  "Pick a bibliography entry and open its resource (citar-open).
Resolution order: the `file' field (pdf/html externally, else find-file),
then `url' externally, then a note under $WORKDIR/roam/references/."
  (let ((entries (citar-entries)))
    (if (null entries)
        (message "No bibliography entries (checked ~{~a~^, ~})" *citar-bib-files*)
        (alexandria:when-let ((entry (citar-prompt-entry "Open citation: " entries)))
          (citar-open-entry entry)))))

(define-command lem-yath-citar-insert-key () ()
  "Pick a bibliography entry and insert @<key> at point (citar-insert-citation)."
  (let ((entries (citar-entries)))
    (if (null entries)
        (message "No bibliography entries (checked ~{~a~^, ~})" *citar-bib-files*)
        (alexandria:when-let ((entry (citar-prompt-entry "Insert key: " entries)))
          (insert-string (current-point) (format nil "@~a" (getf entry :key)))))))
