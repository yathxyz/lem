;;;; Mail: notmuch -> a minimal Lem client.
;;;;
;;;; The Emacs config used `M-x notmuch` / `notmuch-search` over a
;;;; Proton Bridge -> mbsync (isync) -> notmuch pipeline. This port keeps the
;;;; daily read path: a newest-first thread search list, opening a thread into
;;;; a headers+plain-text view, and a `mbsync -a && notmuch new` fetch.
;;;;
;;;; All notmuch interaction is via the CLI with --format=json, parsed by yason
;;;; (JSON arrays -> lists, objects -> hash-tables with string keys, null -> NIL).
;;;; The `notmuch show` tree nests parts arbitrarily, so the walk is defensive.

(in-package :vile)

(defparameter *notmuch-default-query* "tag:inbox"
  "Initial query offered by `vile-notmuch' (mirrors notmuch's inbox view).")

(defparameter *notmuch-search-limit* 100
  "Maximum number of threads requested from `notmuch search'.")

(defparameter *notmuch-list-buffer-name* "*vile-mail*")
(defparameter *notmuch-fetch-buffer-name* "*vile-fetchmail*")

;;; --- helpers ---------------------------------------------------------------

(defun notmuch-available-p ()
  "True when the notmuch binary is on PATH."
  (and (executable-find "notmuch") t))

(defun notmuch-run-json (args)
  "Run notmuch with ARGS (a list of strings), parse stdout as JSON.
Returns the parsed value, or NIL on any process/parse failure."
  (handler-case
      (multiple-value-bind (out err code)
          (uiop:run-program (cons "notmuch" args)
                            :output :string
                            :error-output :string
                            :ignore-error-status t)
        (declare (ignore err))
        (if (and (eql code 0) (plusp (length out)))
            (yason:parse out)
            nil))
    (error () nil)))

(defun notmuch-string (value)
  "Coerce a JSON-derived VALUE to a display string (NIL -> \"\")."
  (cond ((null value) "")
        ((stringp value) value)
        (t (princ-to-string value))))

(defun notmuch-tags-string (tags)
  "Render a list of tag strings as \"(a b c)\", or \"\" when empty."
  (if (and (listp tags) tags)
      (format nil "(~{~a~^ ~})" (mapcar #'notmuch-string tags))
      ""))

;;; --- thread list buffer ----------------------------------------------------

(defvar *notmuch-search-mode-keymap* (make-keymap :description '*notmuch-search-mode-keymap*))

(define-major-mode notmuch-search-mode nil
    (:name "Notmuch"
     :keymap *notmuch-search-mode-keymap*)
  ;; Nothing extra; the buffer is filled and made read-only by the caller.
  )

(define-key *notmuch-search-mode-keymap* "Return" 'vile-notmuch-open-thread)
(define-key *notmuch-search-mode-keymap* "q" 'quit-active-window)
(define-key *notmuch-search-mode-keymap* "g" 'vile-notmuch-refresh)

(defun notmuch-render-search (buffer threads query)
  "Fill BUFFER with one line per thread in THREADS (parsed search JSON).
Stores QUERY and a line-number->thread-id map as buffer-local values, then
makes the buffer read-only and switches it to `notmuch-search-mode'."
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (let ((point (buffer-point buffer))
          (line->id (make-hash-table :test 'eql)))
      (if (null threads)
          (insert-string point (format nil "No threads for query: ~a~%" query))
          (loop :for thread :in threads
                :for line :from 1
                :do (let ((id (notmuch-string (gethash "thread" thread)))
                          (date (notmuch-string (gethash "date_relative" thread)))
                          (authors (notmuch-string (gethash "authors" thread)))
                          (subject (notmuch-string (gethash "subject" thread)))
                          (tags (notmuch-tags-string (gethash "tags" thread))))
                      (setf (gethash line line->id) id)
                      (insert-string
                       point
                       (format nil "~13a  ~25a  ~a ~a~%"
                               date authors subject tags)))))
      (setf (buffer-value buffer 'notmuch-line->id) line->id)
      (setf (buffer-value buffer 'notmuch-query) query)
      (buffer-start point)))
  (change-buffer-mode buffer 'notmuch-search-mode)
  (setf (buffer-read-only-p buffer) t)
  buffer)

(defun notmuch-search (query)
  "Run a newest-first `notmuch search' for QUERY and render the result list.
Degrades to a message when notmuch is missing or the query fails."
  (unless (notmuch-available-p)
    (message "notmuch not found on PATH")
    (return-from notmuch-search))
  (let ((result (notmuch-run-json
                 (list "search" "--format=json"
                       (format nil "--limit=~d" *notmuch-search-limit*)
                       "--sort=newest-first" query))))
    (cond
      ((null result)
       (message "notmuch search failed or returned nothing for: ~a" query))
      ((not (listp result))
       (message "Unexpected notmuch search output"))
      (t
       (let ((buffer (make-buffer *notmuch-list-buffer-name*)))
         (notmuch-render-search buffer result query)
         (pop-to-buffer buffer)
         (message "~d thread~:p" (length result)))))))

(define-command vile-notmuch () ()
  "Prompt for a notmuch query and show matching threads (M-x notmuch).
Defaults to \"tag:inbox\"; results are newest-first, one thread per line."
  (unless (notmuch-available-p)
    (message "notmuch not found on PATH")
    (return-from vile-notmuch))
  (let ((query (prompt-for-string "notmuch query: "
                                  :initial-value *notmuch-default-query*
                                  :history-symbol 'vile-notmuch)))
    (when (plusp (length query))
      (notmuch-search query))))

(define-command vile-notmuch-refresh () ()
  "Re-run the current query in the *vile-mail* list buffer (g)."
  (let ((buffer (current-buffer)))
    (let ((query (buffer-value buffer 'notmuch-query)))
      (if query
          (notmuch-search query)
          (message "No notmuch query to refresh")))))

;;; --- thread show buffer ----------------------------------------------------

(defun notmuch-thread-id-at-point ()
  "The thread id for the line at point in the *vile-mail* buffer, or NIL."
  (let* ((buffer (current-buffer))
         (map (buffer-value buffer 'notmuch-line->id)))
    (when (hash-table-p map)
      (gethash (line-number-at-point (current-point)) map))))

(defun notmuch-collect-text-parts (node acc)
  "Defensively walk a `notmuch show' NODE, pushing text/plain bodies onto ACC.
NODE may be a list (forest / part list / [message replies] pair) or a part
hash-table. Returns the updated accumulator (reversed at the call site)."
  (handler-case
      (cond
        ((null node) acc)
        ((listp node)
         (dolist (child node acc)
           (setf acc (notmuch-collect-text-parts child acc))))
        ((hash-table-p node)
         (let ((content-type (notmuch-string (gethash "content-type" node)))
               (content (gethash "content" node)))
           (cond
             ;; Leaf text/plain part with a string body.
             ((and (string-equal content-type "text/plain")
                   (stringp content))
              (cons content acc))
             ;; A multipart part: content is a list of sub-parts.
             ((listp content)
              (notmuch-collect-text-parts content acc))
             ;; A message object: descend into its body.
             ((gethash "body" node)
              (notmuch-collect-text-parts (gethash "body" node) acc))
             (t acc))))
        (t acc))
    (error () acc)))

(defun notmuch-collect-messages (node acc)
  "Walk the `notmuch show' tree NODE, collecting message hash-tables into ACC.
A message is a hash-table carrying a \"headers\" key."
  (handler-case
      (cond
        ((null node) acc)
        ((hash-table-p node)
         (if (gethash "headers" node)
             (let ((acc (cons node acc)))
               ;; Replies are not under this hash-table; they sit beside it in
               ;; the enclosing pair, so just return.
               acc)
             acc))
        ((listp node)
         (dolist (child node acc)
           (setf acc (notmuch-collect-messages child acc))))
        (t acc))
    (error () acc)))

(defun notmuch-render-message (point message)
  "Insert one MESSAGE (a hash-table) — headers then text/plain body — at POINT."
  (let ((headers (gethash "headers" message)))
    (when (hash-table-p headers)
      (dolist (field '("From" "To" "Date" "Subject"))
        (let ((value (gethash field headers)))
          (when value
            (insert-string point (format nil "~a: ~a~%" field
                                         (notmuch-string value))))))))
  (insert-string point (format nil "~%"))
  (let* ((body (gethash "body" message))
         (parts (nreverse (notmuch-collect-text-parts body '()))))
    (if parts
        (dolist (part parts)
          (insert-string point part)
          (insert-string point (format nil "~%")))
        (insert-string point (format nil "[no text/plain body]~%"))))
  (insert-string point (format nil "~%~a~%~%" (make-string 60 :initial-element #\-))))

(defun notmuch-show (thread-id)
  "Run `notmuch show' for THREAD-ID and render headers + text/plain bodies."
  (unless (notmuch-available-p)
    (message "notmuch not found on PATH")
    (return-from notmuch-show))
  (let ((tree (notmuch-run-json
               (list "show" "--format=json" "--include-html=false" thread-id))))
    (when (null tree)
      (message "notmuch show failed for ~a" thread-id)
      (return-from notmuch-show))
    (let* ((messages (nreverse (notmuch-collect-messages tree '())))
           (buffer (make-buffer (format nil "*vile-mail: ~a*" thread-id))))
      (with-buffer-read-only buffer nil
        (erase-buffer buffer)
        (let ((point (buffer-point buffer)))
          (if messages
              (dolist (message messages)
                (notmuch-render-message point message))
              (insert-string point (format nil "No messages in thread ~a~%" thread-id)))
          (buffer-start point)))
      (setf (buffer-read-only-p buffer) t)
      (pop-to-buffer buffer))))

(define-command vile-notmuch-open-thread () ()
  "Open the thread on the current *vile-mail* line in a read-only view (Return)."
  (let ((id (notmuch-thread-id-at-point)))
    (if id
        (notmuch-show id)
        (message "No thread on this line"))))

;;; --- fetch mail ------------------------------------------------------------

(define-command vile-fetchmail () ()
  "Fetch and index new mail: `mbsync -a && notmuch new' (yath/fetchmail).
Streams progress into *vile-fetchmail*."
  (cond
    ((not (executable-find "mbsync"))
     (message "mbsync not found on PATH"))
    ((not (notmuch-available-p))
     (message "notmuch not found on PATH"))
    (t
     (stream-to-buffer (list "sh" "-c" "mbsync -a && notmuch new")
                       *notmuch-fetch-buffer-name*))))
