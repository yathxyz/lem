;;;; Mail: notmuch -> a focused Lem reader.
;;;;
;;;; The Emacs config used `M-x notmuch` / `notmuch-search` over a
;;;; Proton Bridge -> mbsync (isync) -> notmuch pipeline. This port keeps the
;;;; daily path: a newest-first thread search list, opening a thread into a
;;;; headers+plain-text view, Evil-collection-compatible archive/tag triage,
;;;; new/reply composition through the configured local SMTP bridge, Notmuch
;;;; FCC, owner-private PDF attachment preview, and a `mbsync -a && notmuch
;;;; new` fetch.
;;;;
;;;; All notmuch interaction is via the CLI with --format=json, parsed by yason
;;;; (JSON arrays -> lists, objects -> hash-tables with string keys, null -> NIL).
;;;; The `notmuch show` tree nests parts arbitrarily, so the walk is defensive.

(in-package :lem-yath)

(defparameter *notmuch-default-query* "tag:inbox"
  "Initial query offered by `lem-yath-notmuch' (mirrors notmuch's inbox view).")

(defparameter *notmuch-search-limit* 100
  "Maximum number of threads requested from `notmuch search'.")

(defparameter *notmuch-process-timeout* 20)
(defparameter *notmuch-output-limit* (* 4 1024 1024))
(defparameter *notmuch-attachment-output-limit* (* 128 1024 1024))
(defparameter *notmuch-message-output-limit* (* 10 1024 1024))
(defparameter *notmuch-submit-timeout* 45)
(defparameter *notmuch-address-prefix-length* 3)
(defparameter *notmuch-address-result-limit* 2000)
(defparameter *notmuch-address-output-limit* (* 1024 1024))
(defparameter *notmuch-compose-attachment-count-limit* 16)
(defparameter *notmuch-compose-attachment-byte-limit* (* 7 1024 1024))

(defparameter *notmuch-compose-content-types*
  '(("txt" . "text/plain")
    ("text" . "text/plain")
    ("md" . "text/markdown")
    ("csv" . "text/csv")
    ("html" . "text/html")
    ("htm" . "text/html")
    ("json" . "application/json")
    ("pdf" . "application/pdf")
    ("zip" . "application/zip")
    ("gz" . "application/gzip")
    ("tar" . "application/x-tar")
    ("png" . "image/png")
    ("jpg" . "image/jpeg")
    ("jpeg" . "image/jpeg")
    ("gif" . "image/gif")
    ("webp" . "image/webp")
    ("svg" . "image/svg+xml")
    ("mp3" . "audio/mpeg")
    ("mp4" . "video/mp4")
    ("docx" . "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    ("xlsx" . "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    ("pptx" . "application/vnd.openxmlformats-officedocument.presentationml.presentation")))

(defparameter *notmuch-list-buffer-name* "*lem-yath-mail*")
(defparameter *notmuch-fetch-buffer-name* "*lem-yath-fetchmail*")
(defparameter *notmuch-compose-buffer-name* "*lem-yath-mail-compose*")

(defstruct notmuch-attachment
  message-id
  part-id
  filename)

(declaim (special *project-process-timeout*))

;;; --- helpers ---------------------------------------------------------------

(defun notmuch-available-p ()
  "True when the notmuch binary is on PATH."
  (and (executable-find "notmuch") t))

(defun notmuch-run-json (args)
  "Run notmuch with ARGS (a list of strings), parse stdout as JSON.
Returns the parsed value and true on success, or NIL/NIL on failure.  The
second value distinguishes a valid empty JSON array from a failed command."
  (handler-case
      (let ((program (executable-find "notmuch"))
            (*project-process-timeout* *notmuch-process-timeout*))
        (unless program (return-from notmuch-run-json (values nil nil)))
        (multiple-value-bind (out err code)
            (run-project-program
             (cons (uiop:native-namestring program) args)
             :directory (or (ignore-errors (buffer-directory (current-buffer)))
                            (uiop:getcwd))
             :output-limit *notmuch-output-limit*)
          (declare (ignore err))
          (if (and (eql code 0) (plusp (length out)))
              (values (yason:parse out) t)
              (values nil nil))))
    (error () (values nil nil))))

(defun notmuch-run-command (args)
  "Run notmuch with direct argv ARGS and return true only on exit status zero."
  (handler-case
      (let ((program (executable-find "notmuch"))
            (*project-process-timeout* *notmuch-process-timeout*))
        (unless program (return-from notmuch-run-command nil))
        (multiple-value-bind (out err code)
            (run-project-program
             (cons (uiop:native-namestring program) args)
             :directory (or (ignore-errors (buffer-directory (current-buffer)))
                            (uiop:getcwd))
             :output-limit *notmuch-output-limit*)
          (declare (ignore out))
          (if (eql code 0)
              t
              (progn
                (message "notmuch failed~@[: ~a~]"
                         (alexandria:when-let
                             ((text (string-trim '(#\Space #\Tab #\Newline
                                                   #\Return)
                                                 err)))
                           (and (plusp (length text)) text)))
                nil))))
    (error (condition)
      (message "notmuch failed: ~a" condition)
      nil)))

(defun notmuch-command-error-text (error-output fallback)
  "Return one bounded, single-line command error from ERROR-OUTPUT."
  (let* ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return)
                               (or error-output "")))
         (single-line
           (substitute #\Space #\Return (substitute #\Space #\Newline trimmed))))
    (if (plusp (length single-line))
        (subseq single-line 0 (min 500 (length single-line)))
        fallback)))

(defun notmuch-run-text (args &key input (output-limit *notmuch-output-limit*)
                                    (timeout *notmuch-process-timeout*))
  "Run Notmuch ARGS and return stdout, accepting optional string INPUT."
  (let ((program (or (executable-find "notmuch")
                     (editor-error "notmuch not found on PATH")))
        (*project-process-timeout* timeout))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (cons (uiop:native-namestring program) args)
         :directory (or (ignore-errors (buffer-directory (current-buffer)))
                        (uiop:getcwd))
         :input input
         :output-limit output-limit)
      (unless (and (integerp status) (zerop status))
        (editor-error "notmuch failed: ~a"
                      (notmuch-command-error-text error-output
                                                  (format nil "exit ~a" status))))
      output)))

(defun notmuch-config-value (key)
  "Return one required, control-free Notmuch configuration KEY."
  (let ((value
          (string-trim '(#\Space #\Tab #\Newline #\Return)
                       (notmuch-run-text (list "config" "get" key)))))
    (unless (and (plusp (length value))
                 (<= (length value) 4096)
                 (notany (lambda (character)
                           (or (char= character #\Null)
                               (char= character #\Newline)
                               (char= character #\Return)))
                         value))
      (editor-error "Notmuch configuration ~a is missing or invalid" key))
    value))

(defun notmuch-optional-config-values (key)
  "Return bounded, nonempty lines from optional Notmuch configuration KEY."
  (handler-case
      (loop :for line :in (uiop:split-string
                            (notmuch-run-text (list "config" "get" key))
                            :separator '(#\Newline))
            :for value := (string-trim '(#\Space #\Tab #\Return) line)
            :when (and (plusp (length value))
                       (<= (length value) 4096)
                       (not (find #\Null value)))
              :collect value)
    (error () nil)))

(defun notmuch-user-emails ()
  "Return the primary and alternate Notmuch identities in configured order."
  (remove-duplicates
   (cons (notmuch-config-value "user.primary_email")
         (notmuch-optional-config-values "user.other_email"))
   :test #'string-equal))

(defun notmuch-from-header (&optional primary-email)
  "Return the configured Notmuch primary identity as an RFC 822 From value."
  (let ((name (notmuch-config-value "user.name"))
        (email (or primary-email
                   (notmuch-config-value "user.primary_email"))))
    (format nil "\"~a\" <~a>"
            (with-output-to-string (stream)
              (loop :for character :across name
                    :do (when (or (char= character #\\)
                                  (char= character #\"))
                          (write-char #\\ stream))
                        (write-char character stream)))
            email)))

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

(defun notmuch-query-value (prefix value label)
  "Return PREFIX followed by an exactly quoted notmuch VALUE.

LABEL names VALUE in validation errors.  Direct argv prevents shell parsing;
quoting here prevents notmuch's query parser from interpreting metacharacters."
  (unless (and (stringp value)
               (plusp (length value))
               (<= (length value) 4096)
               (notany (lambda (character)
                         (or (char= character #\Null)
                             (char= character #\Newline)
                             (char= character #\Return)))
                       value))
    (editor-error "The ~a is invalid" label))
  (with-output-to-string (stream)
    (write-string prefix stream)
    (write-char #\" stream)
    (loop :for character :across value
          :do (when (or (char= character #\\) (char= character #\"))
                (write-char #\\ stream))
              (write-char character stream))
    (write-char #\" stream)))

(defun notmuch-bare-thread-id (thread-id)
  "Return THREAD-ID without an optional `thread:' query prefix."
  (if (and (stringp thread-id) (eql 0 (search "thread:" thread-id)))
      (subseq thread-id 7)
      thread-id))

(defun notmuch-thread-id-query (thread-id)
  "Return an exact query for bare or legacy-prefixed THREAD-ID."
  (notmuch-query-value "thread:" (notmuch-bare-thread-id thread-id)
                       "thread ID"))

(defun notmuch-message-id-query (message-id)
  "Return an exact, quoted notmuch id: query for MESSAGE-ID."
  (notmuch-query-value "id:" message-id "Message-ID"))

(defun notmuch-message-ids-query (message-ids)
  "Return one exact disjunction covering MESSAGE-IDS."
  (unless message-ids
    (editor-error "No messages are available for this operation"))
  (if (null (rest message-ids))
      (notmuch-message-id-query (first message-ids))
      (format nil "(~{~a~^ or ~})"
              (mapcar #'notmuch-message-id-query message-ids))))

(defun notmuch-tag-name-valid-p (tag)
  "True for one bounded tag that is safe to pass as a direct argv value."
  (and (stringp tag)
       (plusp (length tag))
       (<= (length tag) 4096)
       (notany (lambda (character)
                 (or (char= character #\Null)
                     (char= character #\Newline)
                     (char= character #\Return)))
               tag)))

(defun notmuch-prompt-tag (action)
  "Read one tag for ACTION, rejecting empty and control-bearing values."
  (prompt-for-string (format nil "Tag to ~a: " action)
                     :history-symbol 'lem-yath-notmuch-tag
                     :test-function #'notmuch-tag-name-valid-p))

(defun notmuch-change-tags (query tag-changes)
  "Apply TAG-CHANGES to the exact notmuch QUERY through direct argv."
  (and tag-changes
       (notmuch-run-command
        (append (list "tag") tag-changes (list "--" query)))))

(defun notmuch-updated-tags (tags tag-changes)
  "Return TAGS after applying +tag/-tag strings from TAG-CHANGES."
  (let ((result (copy-list (if (listp tags) tags '()))))
    (dolist (change tag-changes result)
      (when (and (stringp change) (> (length change) 1))
        (let ((operation (char change 0))
              (tag (subseq change 1)))
          (cond ((char= operation #\+)
                 (pushnew tag result :test #'string=))
                ((char= operation #\-)
                 (setf result (remove tag result :test #'string=)))))))))

(defun notmuch-next-id (ids current-id)
  "Return the ID after CURRENT-ID in IDS, or NIL at the end."
  (let ((tail (member current-id ids :test #'string=)))
    (second tail)))

;;; --- address completion ---------------------------------------------------

(defun notmuch-address-header-name-p (name)
  (member name '("To" "Cc" "Bcc") :test #'string-equal))

(defun notmuch-address-context (point)
  "Return replacement points and input at POINT in a recipient header.

Only To, Cc, and Bcc before the composition's header/body separator qualify.
The replacement starts after the nearest comma or header colon, preserving all
earlier recipients and their whitespace."
  (let* ((buffer (point-buffer point))
         (header-limit (buffer-value buffer 'notmuch-compose-header-limit)))
    (when (and (eq (buffer-major-mode buffer) 'notmuch-compose-mode)
               header-limit
               (alive-point-p header-limit)
               (eq buffer (point-buffer header-limit))
               (point< point header-limit))
      (with-point ((line-start-point point))
        (line-start line-start-point)
        (let* ((before (points-to-string line-start-point point))
               (colon (position #\: before)))
          (when (and colon
                     (notmuch-address-header-name-p
                      (subseq before 0 colon)))
            (let* ((comma (position #\, before :start (1+ colon)
                                                :from-end t))
                   (start-index (1+ (or comma colon))))
              (loop :while (and (< start-index (length before))
                                (let ((character
                                        (char before start-index)))
                                  (or (char= character #\Space)
                                      (char= character #\Tab))))
                    :do (incf start-index))
              (let ((prefix (subseq before start-index))
                    (start (copy-point line-start-point :right-inserting))
                    (end (copy-point point :left-inserting)))
                (character-offset start start-index)
                (values start end prefix)))))))))

(defun notmuch-compose-header-limit-point (buffer)
  "Return a tracked point at BUFFER's first header/body separator."
  (let* ((text (buffer-text buffer))
         (lf (search (format nil "~%~%") text))
         (crlf (search (format nil "~c~c~c~c"
                               #\Return #\Newline #\Return #\Newline)
                       text))
         (offset (cond ((and lf crlf) (min lf crlf))
                       (lf lf)
                       (crlf crlf))))
    (when offset
      (let ((point (copy-point (buffer-start-point buffer) :right-inserting)))
        (character-offset point offset)
        point))))

(defun notmuch-address-query (prefix user-emails)
  "Build the safe sent-mail recipient query for PREFIX and USER-EMAILS."
  (unless user-emails
    (error "Notmuch has no configured user email addresses"))
  (unless (and (= (length prefix) *notmuch-address-prefix-length*)
               (every (lambda (character)
                        (or (char<= #\a (char-downcase character) #\z)
                            (char<= #\0 character #\9)
                            (char= character #\_)))
                      prefix))
    (error "Notmuch address prefix is not a safe wildcard term"))
  (format nil "(~{~a~^ or ~}) and (to:~a*)"
          (mapcar (lambda (email)
                    (notmuch-query-value "from:" email "user email"))
                  user-emails)
          prefix))

(defun notmuch-address-valid-result-p (value)
  (and (plusp (length value))
       (<= (length value) 4096)
       (notany (lambda (character)
                 (or (char= character #\Null)
                     (char= character #\Newline)
                     (char= character #\Return)))
               value)))

(defun notmuch-address-results (output)
  "Parse bounded text OUTPUT into distinct mailbox candidates."
  (let ((seen (make-hash-table :test #'equalp))
        (results '()))
    (dolist (line (uiop:split-string output :separator '(#\Newline))
                  (nreverse results))
      (let ((value (string-trim '(#\Space #\Tab #\Return) line)))
        (when (and (< (length results) *notmuch-address-result-limit*)
                   (notmuch-address-valid-result-p value)
                   (not (gethash value seen)))
          (setf (gethash value seen) t)
          (push value results))))))

(defun notmuch-run-address-query (program directory query request)
  "Run one cancellable, bounded Notmuch address QUERY off the editor thread."
  (let ((*project-process-timeout* *notmuch-process-timeout*))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (list program "address" "--format=text" "--output=recipients"
               "--deduplicate=address" query)
         :directory directory
         :request request
         :output-limit *notmuch-address-output-limit*)
      (unless (and (integerp status) (zerop status))
        (error "~a"
               (notmuch-command-error-text error-output
                                           "notmuch address failed")))
      (notmuch-address-results output))))

(defun notmuch-address-items (mailboxes start end)
  (mapcar
   (lambda (mailbox)
     (lem/completion-mode:make-completion-item
      :label mailbox
      :filter-text mailbox
      :insert-text mailbox
      :detail "Notmuch address"
      :start start
      :end end))
   mailboxes))

(defun notmuch-address-delete-points (&rest points)
  (dolist (point points)
    (when (and point (alive-point-p point))
      (ignore-errors (delete-point point)))))

(defun notmuch-address-return (then mailboxes start end)
  "Call completion callback THEN and release its provider-owned range."
  (unwind-protect
       (funcall then
                (and mailboxes
                     (notmuch-address-items mailboxes start end)))
    (notmuch-address-delete-points start end)))

(defun notmuch-address-cancel-request (buffer)
  (let ((request (buffer-value buffer 'notmuch-address-request))
        (start (buffer-value buffer 'notmuch-address-request-start))
        (end (buffer-value buffer 'notmuch-address-request-end)))
    (setf (buffer-value buffer 'notmuch-address-request) nil
          (buffer-value buffer 'notmuch-address-request-key) nil
          (buffer-value buffer 'notmuch-address-request-callback) nil
          (buffer-value buffer 'notmuch-address-request-start) nil
          (buffer-value buffer 'notmuch-address-request-end) nil)
    (notmuch-address-delete-points start end)
    (and request (cancel-project-request request))))

(defun notmuch-address-deliver (buffer request mailboxes error-text)
  "Publish one address result only while REQUEST still belongs to BUFFER."
  (when (and (not (deleted-buffer-p buffer))
             (eq request (buffer-value buffer 'notmuch-address-request)))
    (let ((key (buffer-value buffer 'notmuch-address-request-key))
          (then (buffer-value buffer 'notmuch-address-request-callback))
          (start (buffer-value buffer 'notmuch-address-request-start))
          (end (buffer-value buffer 'notmuch-address-request-end)))
      (setf (buffer-value buffer 'notmuch-address-request) nil
            (buffer-value buffer 'notmuch-address-request-key) nil
            (buffer-value buffer 'notmuch-address-request-callback) nil
            (buffer-value buffer 'notmuch-address-request-start) nil
            (buffer-value buffer 'notmuch-address-request-end) nil
            (buffer-value buffer 'notmuch-address-last-error) error-text)
      ;; Remember empty and failed prefixes for this composition as well.
      ;; Otherwise every command after a transient failure can respawn the
      ;; same process while the unchanged header still has focus.
      (setf (gethash key (buffer-value buffer 'notmuch-address-cache))
            mailboxes)
      (when then
        (if (and (null error-text)
                 start end
                 (alive-point-p start)
                 (alive-point-p end))
            (notmuch-address-return then mailboxes start end)
            (progn
              (notmuch-address-delete-points start end)
              (funcall then nil)))))))

(defun notmuch-address-start-request
    (buffer key query start end then)
  "Start the single latest address request for BUFFER."
  (notmuch-address-cancel-request buffer)
  (let* ((generation
           (1+ (or (buffer-value buffer 'notmuch-address-generation) 0)))
         (request (make-live-project-request generation nil))
         (program (or (executable-find "notmuch")
                      (error "notmuch not found on PATH")))
         (directory (or (ignore-errors (buffer-directory buffer))
                        (uiop:getcwd))))
    (setf (buffer-value buffer 'notmuch-address-generation) generation
          (buffer-value buffer 'notmuch-address-request) request
          (buffer-value buffer 'notmuch-address-request-key) key
          (buffer-value buffer 'notmuch-address-request-callback) then
          (buffer-value buffer 'notmuch-address-request-start) start
          (buffer-value buffer 'notmuch-address-request-end) end
          (buffer-value buffer 'notmuch-address-last-error) nil)
    (bt2:make-thread
     (lambda ()
       (handler-case
           (let ((mailboxes
                   (notmuch-run-address-query
                    (uiop:native-namestring program) directory query request)))
             (send-event
              (lambda ()
                (notmuch-address-deliver buffer request mailboxes nil))))
         (project-request-cancelled () nil)
         (error (condition)
           (let ((text (notmuch-command-error-text
                        (princ-to-string condition)
                        "notmuch address failed")))
             (send-event
              (lambda ()
                (notmuch-address-deliver buffer request nil text)))))))
     :name "lem-yath/notmuch-address")))

(defun notmuch-address-completion-provider (point then)
  "Asynchronously complete the current recipient token at POINT."
  (multiple-value-bind (start end prefix)
      (notmuch-address-context point)
    (declare (ignore prefix))
    (multiple-value-bind (symbol-start symbol-end symbol-prefix)
        (auto-completion-symbol-bounds point)
      (declare (ignore symbol-start symbol-end))
      (if (or (null start)
              (< (length symbol-prefix) *notmuch-address-prefix-length*))
        (progn
          (notmuch-address-delete-points start end)
          (funcall then nil))
        (let* ((buffer (point-buffer point))
               (key (string-downcase
                     (subseq symbol-prefix
                             0 *notmuch-address-prefix-length*)))
               (cache (buffer-value buffer 'notmuch-address-cache)))
          (multiple-value-bind (mailboxes present-p) (gethash key cache)
            (cond
              (present-p
               (notmuch-address-return then mailboxes start end))
              ((and (buffer-value buffer 'notmuch-address-request)
                    (string= key
                             (buffer-value buffer
                                           'notmuch-address-request-key)))
               ;; Keep one subprocess for an extending prefix, but publish to
               ;; the newest completion generation and replacement range.
               (notmuch-address-delete-points
                (buffer-value buffer 'notmuch-address-request-start)
                (buffer-value buffer 'notmuch-address-request-end))
               (setf (buffer-value buffer 'notmuch-address-request-callback)
                     then
                     (buffer-value buffer 'notmuch-address-request-start) start
                     (buffer-value buffer 'notmuch-address-request-end) end))
              (t
               (handler-case
                   (notmuch-address-start-request
                    buffer key
                    (notmuch-address-query
                     key (buffer-value buffer 'notmuch-address-user-emails))
                    start end then)
                 (error (condition)
                   (setf (buffer-value buffer 'notmuch-address-last-error)
                         (notmuch-command-error-text
                          (princ-to-string condition)
                          "notmuch address failed"))
                   (notmuch-address-delete-points start end)
                   (funcall then nil)))))))))))

(defun notmuch-address-completion-spec ()
  (lem/completion-mode:make-completion-spec
   #'notmuch-address-completion-provider
   :async t
   :test-function #'auto-completion-case-fold-input-valid-p))

;;; --- thread list buffer ----------------------------------------------------

(defvar *notmuch-search-mode-keymap*
  (make-keymap :description '*notmuch-search-mode-keymap*))
(defvar *notmuch-show-mode-keymap*
  (make-keymap :description '*notmuch-show-mode-keymap*))
(defvar *notmuch-compose-mode-keymap*
  (make-keymap :description '*notmuch-compose-mode-keymap*))

(define-major-mode notmuch-search-mode nil
    (:name "Notmuch"
     :keymap *notmuch-search-mode-keymap*)
  ;; Nothing extra; the buffer is filled and made read-only by the caller.
  )

(define-major-mode notmuch-show-mode nil
    (:name "Notmuch-Show"
     :keymap *notmuch-show-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(define-major-mode notmuch-compose-mode nil
    (:name "Notmuch-Compose"
     :keymap *notmuch-compose-mode-keymap*)
  "Edit a plain-text RFC 822 message for Notmuch SMTP submission."
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        (notmuch-address-completion-spec)))

(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode notmuch-search-mode))
  (list *notmuch-search-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode notmuch-show-mode))
  (list *notmuch-show-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode notmuch-compose-mode))
  (list *notmuch-compose-mode-keymap*))

(define-key *notmuch-search-mode-keymap* "Return" 'lem-yath-notmuch-open-thread)
(define-key *notmuch-search-mode-keymap* "q" 'quit-active-window)
(define-key *notmuch-search-mode-keymap* "g" 'lem-yath-notmuch-refresh)
(define-key *notmuch-search-mode-keymap* "a" 'lem-yath-notmuch-archive-thread)
(define-key *notmuch-search-mode-keymap* "d" 'lem-yath-notmuch-toggle-deleted)
(define-key *notmuch-search-mode-keymap* "!" 'lem-yath-notmuch-toggle-unread)
(define-key *notmuch-search-mode-keymap* "=" 'lem-yath-notmuch-toggle-flagged)
(define-key *notmuch-search-mode-keymap* "+" 'lem-yath-notmuch-add-tag)
(define-key *notmuch-search-mode-keymap* "-" 'lem-yath-notmuch-remove-tag)
(define-key *notmuch-search-mode-keymap* "C" 'lem-yath-notmuch-compose)
(define-key *notmuch-search-mode-keymap* "c c" 'lem-yath-notmuch-compose)
(define-key *notmuch-search-mode-keymap* "c r" 'lem-yath-notmuch-reply-sender)
(define-key *notmuch-search-mode-keymap* "c R" 'lem-yath-notmuch-reply-all)
(define-key *notmuch-show-mode-keymap* "q" 'quit-active-window)
(define-key *notmuch-show-mode-keymap* "g" 'lem-yath-notmuch-show-refresh)
(define-key *notmuch-show-mode-keymap* "Return" 'lem-yath-notmuch-open-part)
(define-key *notmuch-show-mode-keymap* "a" 'lem-yath-notmuch-show-archive-message-next-thread)
(define-key *notmuch-show-mode-keymap* "x" 'lem-yath-notmuch-show-archive-message-next-exit)
(define-key *notmuch-show-mode-keymap* "A" 'lem-yath-notmuch-show-archive-thread-next)
(define-key *notmuch-show-mode-keymap* "X" 'lem-yath-notmuch-show-archive-thread-exit)
(define-key *notmuch-show-mode-keymap* "d" 'lem-yath-notmuch-show-toggle-deleted)
(define-key *notmuch-show-mode-keymap* "=" 'lem-yath-notmuch-show-toggle-flagged)
(define-key *notmuch-show-mode-keymap* "+" 'lem-yath-notmuch-show-add-tag)
(define-key *notmuch-show-mode-keymap* "-" 'lem-yath-notmuch-show-remove-tag)
(define-key *notmuch-show-mode-keymap* "C" 'lem-yath-notmuch-compose)
(define-key *notmuch-show-mode-keymap* "c c" 'lem-yath-notmuch-compose)
(define-key *notmuch-show-mode-keymap* "c r" 'lem-yath-notmuch-reply-sender)
(define-key *notmuch-show-mode-keymap* "c R" 'lem-yath-notmuch-reply-all)
(define-key *notmuch-show-mode-keymap* "c f" 'lem-yath-notmuch-forward-message)
(define-key *notmuch-show-mode-keymap* "e" 'lem-yath-notmuch-resume-draft)
(define-key *notmuch-compose-mode-keymap* "C-c C-c"
  'lem-yath-notmuch-compose-send)
(define-key *notmuch-compose-mode-keymap* "C-c C-a"
  'lem-yath-notmuch-compose-attach-file)
(define-key *notmuch-compose-mode-keymap* "C-c C-p"
  'lem-yath-notmuch-compose-postpone)
(define-key *notmuch-compose-mode-keymap* "C-c C-k"
  'lem-yath-notmuch-compose-cancel)
(define-key *notmuch-compose-mode-keymap* "C-x C-s"
  'lem-yath-notmuch-compose-save-draft)

;;; --- compose, reply, and submit -------------------------------------------

(defun notmuch-compose-existing-buffer ()
  (alexandria:when-let ((buffer (get-buffer *notmuch-compose-buffer-name*)))
    (unless (deleted-buffer-p buffer) buffer)))

(defun notmuch-compose-position-point (buffer)
  "Place BUFFER's point after the first editable recipient header."
  (let ((point (buffer-point buffer)))
    (buffer-start point)
    (cond ((search-forward point "To:") (line-end point))
          ((search-forward point "Subject:") (line-end point))
          (t (buffer-end point)))))

(defun notmuch-compose-attachment-size (pathname)
  "Return PATHNAME's size after requiring a regular file."
  #+sbcl
  (let ((stat (sb-posix:stat (uiop:native-namestring pathname))))
    (unless (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
               sb-posix:s-ifreg)
      (editor-error "Attachment is not a regular file: ~a" pathname))
    (sb-posix:stat-size stat))
  #-sbcl
  (declare (ignore pathname))
  #-sbcl
  (editor-error "Safe attachment composition requires the supported SBCL runtime"))

(defun notmuch-compose-attachment-path (value)
  "Return VALUE as an existing canonical, size-bounded attachment path."
  (let ((pathname
          (or (ignore-errors (truename value))
              (editor-error "Attachment does not exist: ~a" value))))
    (let ((size (notmuch-compose-attachment-size pathname)))
      (when (> size *notmuch-compose-attachment-byte-limit*)
        (editor-error "Attachment exceeds the ~d MiB composition limit: ~a"
                      (floor *notmuch-compose-attachment-byte-limit* 1048576)
                      pathname)))
    pathname))

(defun notmuch-compose-content-type (pathname)
  (or (cdr (assoc (string-downcase (or (pathname-type pathname) ""))
                  *notmuch-compose-content-types* :test #'string=))
      "application/octet-stream"))

(defun notmuch-compose-mml-escape (value)
  "Escape VALUE for one double-quoted MML marker attribute."
  (when (find-if (lambda (character)
                   (member character '(#\Null #\Newline #\Return)))
                 value)
    (editor-error "Attachment path contains a control character"))
  (with-output-to-string (stream)
    (loop :for character :across value
          :do (case character
                (#\& (write-string "&amp;" stream))
                (#\< (write-string "&lt;" stream))
                (#\> (write-string "&gt;" stream))
                (#\" (write-string "&quot;" stream))
                (otherwise (write-char character stream))))))

(defun notmuch-compose-attachment-marker-count (buffer)
  (let ((text (buffer-text buffer)))
    (loop :with offset := 0
          :for marker := (search "<#part " text :start2 offset)
          :while marker
          :count marker
          :do (setf offset (+ marker 7)))))

(define-command lem-yath-notmuch-compose-attach-file () ()
  "Attach one local file using Emacs message-mode's `C-c C-a' route."
  (let ((buffer (current-buffer)))
    (unless (eq (buffer-major-mode buffer) 'notmuch-compose-mode)
      (editor-error "Not in a Notmuch composition"))
    (when (>= (notmuch-compose-attachment-marker-count buffer)
              *notmuch-compose-attachment-count-limit*)
      (editor-error "A message may contain at most ~d attachments"
                    *notmuch-compose-attachment-count-limit*))
    (alexandria:when-let
        ((choice
           (prompt-for-file
            "Attach file: "
            :directory (or (ignore-errors (buffer-directory buffer))
                           (uiop:getcwd))
            :default nil :existing t)))
      (let* ((pathname (notmuch-compose-attachment-path choice))
             (native-name (uiop:native-namestring pathname))
             (marker
               (format nil
                       "<#part type=\"~a\" filename=\"~a\" disposition=attachment>"
                       (notmuch-compose-content-type pathname)
                       (notmuch-compose-mml-escape native-name)))
             (point (current-point)))
        (unless (or (start-buffer-p point)
                    (char= (or (character-at point -1) #\Newline) #\Newline))
          (insert-character point #\Newline))
        (insert-string point marker)
        (unless (char= (or (character-at point) #\Null) #\Newline)
          (insert-character point #\Newline))
        (message "Attached ~a; C-c C-c will build multipart MIME"
                 (file-namestring pathname))))))

(defun notmuch-compose-open
    (text &key reply-query forward-query user-emails
               draft-query draft-directory)
  "Open TEXT in the single Notmuch composition buffer.

REPLY-QUERY is tagged `+replied' only after SMTP and FCC both succeed.
FORWARD-QUERY is tagged `+forwarded' at the same success boundary.
DRAFT-QUERY identifies the saved version replaced by save or deleted after a
successful send.  DRAFT-DIRECTORY owns attachment snapshots for a resumed
draft and is removed when the composition closes."
  (alexandria:when-let ((existing (notmuch-compose-existing-buffer)))
    (switch-to-buffer existing nil)
    (editor-error "A Notmuch composition is already open"))
  (let ((origin (current-buffer))
        (buffer (make-buffer *notmuch-compose-buffer-name*)))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (change-buffer-mode buffer 'notmuch-compose-mode)
      (insert-string (buffer-point buffer) text)
      (setf (buffer-directory buffer)
            (or (ignore-errors (buffer-directory origin)) (uiop:getcwd))
            (buffer-value buffer 'notmuch-compose-origin) origin
            (buffer-value buffer 'notmuch-compose-reply-query) reply-query
            (buffer-value buffer 'notmuch-compose-forward-query) forward-query
            (buffer-value buffer 'notmuch-compose-sent-message) nil
            (buffer-value buffer 'notmuch-compose-fcc-done-p) nil
            (buffer-value buffer 'notmuch-compose-reply-tag-done-p) nil
            (buffer-value buffer 'notmuch-compose-forward-tag-done-p) nil
            (buffer-value buffer 'notmuch-compose-draft-query) draft-query
            (buffer-value buffer 'notmuch-compose-draft-directory)
            draft-directory
            (buffer-value buffer 'notmuch-compose-draft-tag-done-p) nil
            (buffer-value buffer 'notmuch-compose-draft-last-error) nil
            (buffer-value buffer 'notmuch-compose-header-limit)
            (notmuch-compose-header-limit-point buffer)
            (buffer-value buffer 'notmuch-address-user-emails)
            (or user-emails (notmuch-user-emails))
            (buffer-value buffer 'notmuch-address-cache)
            (make-hash-table :test #'equal)
            (buffer-value buffer 'notmuch-address-generation) 0
            (buffer-value buffer 'notmuch-address-request) nil
            (buffer-value buffer 'notmuch-address-last-error) nil)
      (add-hook (variable-value 'kill-buffer-hook :buffer buffer)
                'notmuch-compose-kill-buffer-hook)
      (notmuch-compose-position-point buffer))
    (buffer-unmark buffer)
    (switch-to-buffer buffer nil)
    (message "Write mail; C-c C-c sends, C-c C-p postpones, C-x C-s saves, C-c C-k cancels")
    buffer))

(define-command lem-yath-notmuch-compose () ()
  "Compose new mail (`C' or `cc' in Notmuch views)."
  (let ((user-emails (notmuch-user-emails)))
    (notmuch-compose-open
     (format nil "From: ~a~%To: ~%Subject: ~%~%"
             (notmuch-from-header (first user-emails)))
     :user-emails user-emails)))

(defun notmuch-current-reply-query ()
  "Return the exact message or thread query selected in a Notmuch view."
  (let ((buffer (current-buffer)))
    (cond
      ((eq (buffer-major-mode buffer) 'notmuch-show-mode)
       (alexandria:if-let ((message-id (notmuch-message-id-at-point)))
         (notmuch-message-id-query message-id)
         (editor-error "No message at point")))
      ((eq (buffer-major-mode buffer) 'notmuch-search-mode)
       (alexandria:if-let ((thread-id (notmuch-thread-id-at-point)))
         (notmuch-thread-id-query thread-id)
         (editor-error "No thread at point")))
      (t (editor-error "Not in a Notmuch message or search view")))))

(defun notmuch-compose-reply (reply-all-p)
  "Compose a reply at point; include all recipients when REPLY-ALL-P."
  (let* ((query (notmuch-current-reply-query))
         (template
           (notmuch-run-text
            (list "reply" "--format=default"
                  (if reply-all-p "--reply-to=all" "--reply-to=sender")
                  query)
            :output-limit *notmuch-message-output-limit*)))
    (unless (plusp (length template))
      (editor-error "notmuch produced an empty reply template"))
    (notmuch-compose-open template :reply-query query)))

(define-command lem-yath-notmuch-reply-sender () ()
  "Reply to the sender at point (`cr')."
  (notmuch-compose-reply nil))

(define-command lem-yath-notmuch-reply-all () ()
  "Reply to the sender and all recipients at point (`cR')."
  (notmuch-compose-reply t))

(defun notmuch-draft-helper-program ()
  "Return the packaged helper used to snapshot and restore Notmuch drafts."
  (or (alexandria:when-let
          ((configured (uiop:getenv "LEM_YATH_NOTMUCH_DRAFT_PROGRAM")))
        (and (plusp (length configured))
             (probe-file configured)
             configured))
      (notmuch-smtp-submit-program)))

(defun notmuch-draft-run-helper (arguments raw-message)
  "Run the draft helper with direct ARGUMENTS and bounded RAW-MESSAGE input."
  (let ((*project-process-timeout* *notmuch-submit-timeout*))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (cons (notmuch-draft-helper-program) arguments)
         :directory (or (ignore-errors (buffer-directory (current-buffer)))
                        (uiop:getcwd))
         :input raw-message
         :output-limit *notmuch-message-output-limit*)
      (unless (and (integerp status) (zerop status) (plusp (length output)))
        (editor-error "~a"
                      (notmuch-command-error-text error-output
                                                  "draft helper failed")))
      output)))

(defun notmuch-draft-message-id (wire)
  "Return the bare Message-ID from a prepared draft WIRE message."
  (dolist (raw-line (uiop:split-string wire :separator '(#\Newline)))
    (let ((line (string-right-trim '(#\Return) raw-line)))
      (when (zerop (length line)) (return))
      (when (zerop (or (search "Message-ID:" line :test #'char-equal) -1))
        (let ((value (string-trim '(#\Space #\Tab)
                                  (subseq line (length "Message-ID:")))))
          (when (and (> (length value) 2)
                     (char= (char value 0) #\<)
                     (char= (char value (1- (length value))) #\>))
            (return (subseq value 1 (1- (length value))))))))))

(defun notmuch-draft-query-valid-p (query)
  "True when QUERY is one exact quoted id: or thread: query we generated."
  (and (stringp query)
       (plusp (length query))
       (<= (length query) 4105)
       (let ((prefix-length
               (cond ((zerop (or (search "id:\"" query) -1)) 4)
                     ((zerop (or (search "thread:\"" query) -1)) 8))))
         (when (and prefix-length
                    (> (length query) (1+ prefix-length))
                    (char= (char query (1- (length query))) #\"))
           (loop :with escaped-p := nil
                 :for index :from prefix-length
                            :below (1- (length query))
                 :for character := (char query index)
                 :do (cond
                       (escaped-p
                        (unless (or (char= character #\\)
                                    (char= character #\"))
                          (return nil))
                        (setf escaped-p nil))
                       ((char= character #\\)
                        (setf escaped-p t))
                       ((or (char= character #\")
                            (char= character #\Null)
                            (char= character #\Newline)
                            (char= character #\Return))
                        (return nil)))
                 :finally (return (not escaped-p)))))))

(defun notmuch-draft-strip-metadata (text)
  "Remove private action metadata from resumed draft TEXT.
Returns editable text, optional reply query, and optional forward query."
  (let ((reply-prefix "X-Lem-Yath-Reply-Query:")
        (forward-prefix "X-Lem-Yath-Forward-Query:")
        (reply-query nil)
        (forward-query nil)
        (headers-p t))
    (values
     (with-output-to-string (stream)
       (let ((start 0)
             (length (length text)))
         (loop
           (let* ((newline (position #\Newline text :start start))
                  (end (or newline length))
                  (line (subseq text start end)))
             (cond
               ((and headers-p (zerop (length line)))
                (setf headers-p nil)
                (write-string line stream)
                (when newline (write-char #\Newline stream)))
               ((and headers-p
                     (zerop (or (search reply-prefix line
                                         :test #'char-equal)
                                -1)))
                (when reply-query
                  (editor-error "Saved draft contains duplicate reply metadata"))
                (setf reply-query
                      (string-trim '(#\Space #\Tab)
                                   (subseq line (length reply-prefix)))))
               ((and headers-p
                     (zerop (or (search forward-prefix line
                                         :test #'char-equal)
                                -1)))
                (when forward-query
                  (editor-error "Saved draft contains duplicate forward metadata"))
                (setf forward-query
                      (string-trim '(#\Space #\Tab)
                                   (subseq line (length forward-prefix)))))
               (t
                (write-string line stream)
                (when newline (write-char #\Newline stream))))
             (unless newline (return))
             (setf start (1+ newline))))))
     (progn
       (when (and reply-query forward-query)
         (editor-error "Saved draft contains conflicting action metadata"))
       (dolist (entry (list (cons "reply" reply-query)
                            (cons "forward" forward-query)))
         (when (and (cdr entry)
                    (not (notmuch-draft-query-valid-p (cdr entry))))
           (editor-error "Saved draft contains invalid ~a metadata"
                         (car entry))))
       reply-query)
     forward-query)))

(defun notmuch-remove-draft-directory (directory)
  "Remove regular attachment snapshots and then private DIRECTORY."
  (when directory
    (dolist (pathname (or (ignore-errors (uiop:directory-files directory)) '()))
      (ignore-errors (delete-file pathname)))
    #+sbcl
    (ignore-errors (sb-posix:rmdir (uiop:native-namestring directory)))))

(defun notmuch-compose-kill-buffer-hook (&optional (buffer (current-buffer)))
  "Cancel completion work and remove resumed attachment files for BUFFER."
  (notmuch-address-cancel-request buffer)
  (let ((directory
          (buffer-value buffer 'notmuch-compose-draft-directory)))
    (setf (buffer-value buffer 'notmuch-compose-draft-directory) nil)
    (notmuch-remove-draft-directory directory)))

(defun notmuch-compose-save-draft-buffer (buffer)
  "Snapshot and index BUFFER, replacing its previously tracked draft safely."
  (unless (eq (buffer-major-mode buffer) 'notmuch-compose-mode)
    (error "Not in a Notmuch composition"))
  (when (buffer-value buffer 'notmuch-compose-sent-message)
    (error "A message already accepted by SMTP cannot be saved as a draft"))
  (let* ((reply-query (buffer-value buffer 'notmuch-compose-reply-query))
         (forward-query (buffer-value buffer 'notmuch-compose-forward-query))
         (arguments
           (cond
             ((and reply-query forward-query)
              (error "A composition cannot be both a reply and a forward"))
             (reply-query (list "--prepare-draft" reply-query))
             (forward-query (list "--prepare-draft-forward" forward-query))
             (t (list "--prepare-draft"))))
         (wire (notmuch-draft-run-helper arguments (buffer-text buffer)))
         (message-id (or (notmuch-draft-message-id wire)
                         (error "Prepared draft has no valid Message-ID")))
         (new-query (notmuch-message-id-query message-id))
         (old-query (buffer-value buffer 'notmuch-compose-draft-query)))
    (notmuch-run-text
     (list "insert" "--create-folder" "--folder=drafts" "+draft")
     :input wire :output-limit *notmuch-output-limit*)
    ;; The newly inserted version is durable before the older one is hidden.
    (setf (buffer-value buffer 'notmuch-compose-draft-query) new-query)
    (buffer-unmark buffer)
    (when (and old-query (not (string= old-query new-query)))
      (unless (notmuch-change-tags old-query '("+deleted"))
        (error "The new draft was saved, but the previous version could not be marked deleted")))
    new-query))

(defun notmuch-compose-save-draft-interactively (buffer)
  "Save BUFFER as a draft, reporting errors without closing it."
  (handler-case
      (progn
        (notmuch-compose-save-draft-buffer buffer)
        (setf (buffer-value buffer 'notmuch-compose-draft-last-error) nil)
        (message "Draft saved in Notmuch; C-c C-p postpones it")
        t)
    (error (condition)
      (setf (buffer-value buffer 'notmuch-compose-draft-last-error)
            (princ-to-string condition))
      (message "Draft was not saved: ~a" condition)
      nil)))

(define-command lem-yath-notmuch-compose-save-draft () ()
  "Save this composition in Notmuch without closing it (`C-x C-s')."
  (notmuch-compose-save-draft-interactively (current-buffer)))

(define-command lem-yath-notmuch-compose-postpone () ()
  "Save this composition in Notmuch and close it (`C-c C-p')."
  (let ((buffer (current-buffer)))
    (when (notmuch-compose-save-draft-interactively buffer)
      (notmuch-close-compose buffer)
      (message "Message postponed; search tag:draft and press e to resume"))))

(define-command lem-yath-notmuch-resume-draft () ()
  "Resume the draft message at point (`e' in a Notmuch show buffer)."
  (let* ((show-buffer (current-buffer))
         (message-id (notmuch-message-id-at-point))
         (message-object (and message-id
                              (notmuch-message-object show-buffer message-id)))
         (tags (and message-object (gethash "tags" message-object))))
    (unless (and message-id
                 (member "draft" tags :test #'string=)
                 (not (member "deleted" tags :test #'string=)))
      (editor-error "The message at point is not a live Notmuch draft"))
    (let* ((query (notmuch-message-id-query message-id))
           (raw (notmuch-run-text
                 (list "show" "--format=raw" query)
                 :output-limit *notmuch-message-output-limit*))
           (directory (notmuch-private-temp-directory))
           (keep-directory-p nil))
      (unwind-protect
           (multiple-value-bind (editable reply-query forward-query)
               (notmuch-draft-strip-metadata
                (notmuch-draft-run-helper
                 (list "--resume-draft" (uiop:native-namestring directory))
                 raw))
             (notmuch-compose-open editable
                                   :reply-query reply-query
                                   :forward-query forward-query
                                   :draft-query query
                                   :draft-directory directory)
             (setf keep-directory-p t)
             (message "Draft resumed; C-x C-s saves and C-c C-p postpones"))
        (unless keep-directory-p
          (notmuch-remove-draft-directory directory))))))

(define-command lem-yath-notmuch-forward-message () ()
  "Forward the current shown message inline (`cf' from Evil-collection)."
  (unless (eq (buffer-major-mode (current-buffer)) 'notmuch-show-mode)
    (editor-error "Forwarding requires a shown Notmuch message"))
  (let* ((message-id (or (notmuch-message-id-at-point)
                         (editor-error "No message at point")))
         (query (notmuch-message-id-query message-id))
         (raw (notmuch-run-text
               (list "show" "--format=raw" query)
               :output-limit *notmuch-message-output-limit*))
         (directory (notmuch-private-temp-directory))
         (keep-directory-p nil))
    (unwind-protect
         (let* ((user-emails (notmuch-user-emails))
                (template
                  (notmuch-draft-run-helper
                   (list "--prepare-forward"
                         (uiop:native-namestring directory))
                   raw)))
           (notmuch-compose-open
            (format nil "From: ~a~%~a"
                    (notmuch-from-header (first user-emails)) template)
            :forward-query query
            :user-emails user-emails
            :draft-directory directory)
           (setf keep-directory-p t)
           (message "Forward prepared inline; edit recipients, then C-c C-c sends"))
      (unless keep-directory-p
        (notmuch-remove-draft-directory directory)))))

(defun notmuch-smtp-submit-program ()
  (or (alexandria:when-let ((configured
                              (uiop:getenv "LEM_YATH_SMTP_SUBMIT_PROGRAM")))
        (and (plusp (length configured))
             (probe-file configured)
             configured))
      (alexandria:when-let ((program
                              (executable-find "lem-yath-smtp-submit")))
        (uiop:native-namestring program))
      (editor-error "lem-yath-smtp-submit is not available")))

(defun notmuch-submit-message (raw-message)
  "Submit RAW-MESSAGE and return the exact normalized transmitted message."
  (unless (and (plusp (length raw-message))
               (<= (length raw-message) *notmuch-message-output-limit*)
               (or (search (format nil "~%~%") raw-message)
                   (search (format nil "~c~c~c~c" #\Return #\Newline
                                   #\Return #\Newline)
                           raw-message)))
    (editor-error "The message is empty, too large, or lacks a header/body separator"))
  (let ((*project-process-timeout* *notmuch-submit-timeout*))
    (multiple-value-bind (output error-output status)
        (run-project-program
         (list (notmuch-smtp-submit-program))
         :directory (or (ignore-errors (buffer-directory (current-buffer)))
                        (uiop:getcwd))
         :input raw-message
         :output-limit *notmuch-message-output-limit*)
      (unless (and (integerp status) (zerop status) (plusp (length output)))
        (editor-error "~a"
                      (notmuch-command-error-text error-output
                                                  "SMTP submission failed")))
      output)))

(defun notmuch-fcc-sent-message (message-text)
  "Insert MESSAGE-TEXT into Notmuch's configured default `sent' folder."
  (notmuch-run-text
   (list "insert" "--create-folder" "--folder=sent")
   :input message-text
   :output-limit *notmuch-output-limit*)
  t)

(defun notmuch-close-compose (buffer)
  (let ((origin (buffer-value buffer 'notmuch-compose-origin)))
    (when (and origin (not (deleted-buffer-p origin)))
      (switch-to-buffer origin nil))
    (buffer-unmark buffer)
    (delete-buffer buffer)))

(defun notmuch-compose-send-buffer (buffer)
  "Submit, FCC, tag, and close the Notmuch composition BUFFER.

Each completed stage is recorded before the next one begins, so retrying a
later failure cannot submit the message twice.  Stage failures are signalled to
the interactive command so it can retain BUFFER and explain the recovery."
  (unless (eq (buffer-major-mode buffer) 'notmuch-compose-mode)
    (error "Not in a Notmuch composition"))
  (unless (buffer-value buffer 'notmuch-compose-sent-message)
    (setf (buffer-value buffer 'notmuch-compose-sent-message)
          (notmuch-submit-message (buffer-text buffer)))
    (buffer-unmark buffer)
    (setf (buffer-read-only-p buffer) t))
  (unless (buffer-value buffer 'notmuch-compose-fcc-done-p)
    (notmuch-fcc-sent-message
     (buffer-value buffer 'notmuch-compose-sent-message))
    (setf (buffer-value buffer 'notmuch-compose-fcc-done-p) t))
  (unless (buffer-value buffer 'notmuch-compose-reply-tag-done-p)
    (alexandria:when-let
        ((query (buffer-value buffer 'notmuch-compose-reply-query)))
      (unless (notmuch-change-tags query '("+replied"))
        (error "tagging the sent reply failed")))
    (setf (buffer-value buffer 'notmuch-compose-reply-tag-done-p) t))
  (unless (buffer-value buffer 'notmuch-compose-forward-tag-done-p)
    (alexandria:when-let
        ((query (buffer-value buffer 'notmuch-compose-forward-query)))
      (unless (notmuch-change-tags query '("+forwarded"))
        (error "tagging the forwarded message failed")))
    (setf (buffer-value buffer 'notmuch-compose-forward-tag-done-p) t))
  (unless (buffer-value buffer 'notmuch-compose-draft-tag-done-p)
    (alexandria:when-let
        ((query (buffer-value buffer 'notmuch-compose-draft-query)))
      (unless (notmuch-change-tags query '("+deleted"))
        (error "marking the sent draft deleted failed")))
    (setf (buffer-value buffer 'notmuch-compose-draft-tag-done-p) t))
  (notmuch-close-compose buffer)
  t)

(define-command lem-yath-notmuch-compose-send () ()
  "Submit, FCC, and finish this composition (`C-c C-c')."
  (let ((buffer (current-buffer)))
    (handler-case
        (when (notmuch-compose-send-buffer buffer)
          (message "Message sent and filed in Notmuch"))
      (error (condition)
        (let* ((description (princ-to-string condition))
               (bounded (subseq description 0 (min 500 (length description)))))
          (if (buffer-value buffer 'notmuch-compose-sent-message)
              (message "Message sent; recovery required: ~a. C-c C-c retries the fixed sent copy without SMTP"
                       bounded)
              (message "Mail was not sent: ~a" bounded)))
        nil))))

(define-command lem-yath-notmuch-compose-cancel () ()
  "Discard an unsent composition, or close a sent recovery buffer (`C-c C-k')."
  (let ((buffer (current-buffer)))
    (unless (eq (buffer-major-mode buffer) 'notmuch-compose-mode)
      (editor-error "Not in a Notmuch composition"))
    (when (or (buffer-value buffer 'notmuch-compose-sent-message)
              (not (buffer-modified-p buffer))
              (prompt-for-y-or-n-p "Discard this unsent mail composition?"))
      (notmuch-close-compose buffer))))

(defun notmuch-render-search (buffer threads query &optional selected-id)
  "Fill BUFFER with one line per thread in THREADS (parsed search JSON).
Stores QUERY and a line-number->thread-id map as buffer-local values, then
makes the buffer read-only and switches it to `notmuch-search-mode'."
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (let ((point (buffer-point buffer))
          (line->id (make-hash-table :test 'eql))
          (thread-ids '())
          (selected-line nil))
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
                      (push id thread-ids)
                      (when (and selected-id (string= selected-id id))
                        (setf selected-line line))
                      (insert-string
                       point
                       (format nil "~13a  ~25a  ~a ~a~%"
                               date authors subject tags)))))
      (setf (buffer-value buffer 'notmuch-line->id) line->id)
      (setf (buffer-value buffer 'notmuch-query) query)
      (setf (buffer-value buffer 'notmuch-threads) threads)
      (setf (buffer-value buffer 'notmuch-thread-ids) (nreverse thread-ids))
      (buffer-start point)
      (when selected-line (move-to-line point selected-line))))
  (change-buffer-mode buffer 'notmuch-search-mode)
  (setf (buffer-read-only-p buffer) t)
  buffer)

(defun notmuch-search (query &optional selected-id)
  "Run a newest-first `notmuch search' for QUERY and render the result list.
Degrades to a message when notmuch is missing or the query fails."
  (unless (notmuch-available-p)
    (message "notmuch not found on PATH")
    (return-from notmuch-search))
  (multiple-value-bind (result success-p)
      (notmuch-run-json
       (list "search" "--format=json"
             (format nil "--limit=~d" *notmuch-search-limit*)
             "--sort=newest-first" query))
    (cond
      ((not success-p)
       (message "notmuch search failed for: ~a" query))
      ((not (listp result))
       (message "Unexpected notmuch search output"))
      (t
       (let ((buffer (make-buffer *notmuch-list-buffer-name*)))
         (notmuch-render-search buffer result query selected-id)
         (switch-to-window (pop-to-buffer buffer))
         (message "~d thread~:p" (length result)))))))

(define-command lem-yath-notmuch () ()
  "Prompt for a notmuch query and show matching threads (M-x notmuch).
Defaults to \"tag:inbox\"; results are newest-first, one thread per line."
  (unless (notmuch-available-p)
    (message "notmuch not found on PATH")
    (return-from lem-yath-notmuch))
  (let ((query (prompt-for-string "notmuch query: "
                                  :initial-value *notmuch-default-query*
                                  :history-symbol 'lem-yath-notmuch)))
    (when (plusp (length query))
      (notmuch-search query))))

(define-command lem-yath-notmuch-refresh () ()
  "Re-run the current query in the *lem-yath-mail* list buffer (g)."
  (let ((buffer (current-buffer)))
    (let ((query (buffer-value buffer 'notmuch-query))
          (selected-id (notmuch-thread-id-at-point)))
      (if query
          (notmuch-search query selected-id)
          (message "No notmuch query to refresh")))))

(defun notmuch-search-tag-current (tag-changes &optional advance-p)
  "Apply TAG-CHANGES to the current thread and optionally advance one row."
  (let* ((buffer (current-buffer))
         (thread-id (notmuch-thread-id-at-point))
         (threads (buffer-value buffer 'notmuch-threads))
         (thread-ids (buffer-value buffer 'notmuch-thread-ids))
         (query (buffer-value buffer 'notmuch-query)))
    (unless thread-id
      (message "No thread on this line")
      (return-from notmuch-search-tag-current nil))
    (when (notmuch-change-tags (notmuch-thread-id-query thread-id) tag-changes)
      (notmuch-update-object-tags (notmuch-thread-object buffer thread-id)
                                  tag-changes)
      (notmuch-render-search buffer threads query
                             (or (and advance-p
                                      (notmuch-next-id thread-ids thread-id))
                                 thread-id))
      t)))

(defun notmuch-search-toggle-current-tag (tag)
  "Toggle TAG on the current search thread and advance like Evil-collection."
  (let* ((thread-id (notmuch-thread-id-at-point))
         (thread (and thread-id
                      (notmuch-thread-object (current-buffer) thread-id)))
         (tags (and thread (gethash "tags" thread)))
         (change (format nil "~c~a"
                         (if (member tag tags :test #'string=) #\- #\+)
                         tag)))
    (if thread
        (notmuch-search-tag-current (list change) t)
        (message "No thread on this line"))))

(define-command lem-yath-notmuch-archive-thread () ()
  "Remove `inbox' from the selected thread and advance (`a')."
  (when (notmuch-search-tag-current '("-inbox") t)
    (message "Thread archived")))

(define-command lem-yath-notmuch-toggle-deleted () ()
  "Toggle `deleted' on the selected thread and advance (`d')."
  (notmuch-search-toggle-current-tag "deleted"))

(define-command lem-yath-notmuch-toggle-unread () ()
  "Toggle `unread' on the selected thread and advance (`!')."
  (notmuch-search-toggle-current-tag "unread"))

(define-command lem-yath-notmuch-toggle-flagged () ()
  "Toggle `flagged' on the selected thread and advance (`=')."
  (notmuch-search-toggle-current-tag "flagged"))

(define-command lem-yath-notmuch-add-tag () ()
  "Prompt for one tag to add to the selected thread (`+')."
  (let ((tag (notmuch-prompt-tag "add")))
    (notmuch-search-tag-current (list (concatenate 'string "+" tag)))))

(define-command lem-yath-notmuch-remove-tag () ()
  "Prompt for one tag to remove from the selected thread (`-')."
  (let ((tag (notmuch-prompt-tag "remove")))
    (notmuch-search-tag-current (list (concatenate 'string "-" tag)))))

;;; --- thread show buffer ----------------------------------------------------

(defun notmuch-thread-id-at-point ()
  "The thread id for the line at point in the *lem-yath-mail* buffer, or NIL."
  (let* ((buffer (current-buffer))
         (map (buffer-value buffer 'notmuch-line->id)))
    (when (hash-table-p map)
      (gethash (line-number-at-point (current-point)) map))))

(defun notmuch-message-id-at-point ()
  "The bare Message-ID for the message at point in a Notmuch show buffer."
  (let ((map (buffer-value (current-buffer) 'notmuch-line->message-id)))
    (when (hash-table-p map)
      (gethash (line-number-at-point (current-point)) map))))

(defun notmuch-thread-object (buffer thread-id)
  "Return THREAD-ID's mutable search result object in BUFFER."
  (find thread-id (buffer-value buffer 'notmuch-threads)
        :test #'string=
        :key (lambda (thread) (notmuch-string (gethash "thread" thread)))))

(defun notmuch-message-object (buffer message-id)
  "Return MESSAGE-ID's mutable show result object in BUFFER."
  (find message-id (buffer-value buffer 'notmuch-messages)
        :test #'string=
        :key (lambda (message) (notmuch-string (gethash "id" message)))))

(defun notmuch-update-object-tags (object tag-changes)
  "Apply TAG-CHANGES to OBJECT's JSON `tags' member in memory."
  (when (hash-table-p object)
    (setf (gethash "tags" object)
          (notmuch-updated-tags (gethash "tags" object) tag-changes))))

(defun notmuch-update-search-thread (buffer thread-id tag-changes)
  "Update THREAD-ID's visible tags in live Notmuch search BUFFER."
  (when (and buffer (not (deleted-buffer-p buffer)))
    (alexandria:when-let ((thread (notmuch-thread-object buffer thread-id)))
      (notmuch-update-object-tags thread tag-changes)
      (notmuch-render-search
       buffer
       (buffer-value buffer 'notmuch-threads)
       (buffer-value buffer 'notmuch-query)
       thread-id))))

(defun notmuch-attachment-at-point ()
  "The PDF attachment descriptor on the current show-buffer line, or NIL."
  (let ((map (buffer-value (current-buffer) 'notmuch-line->attachment)))
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

(defun notmuch-collect-pdf-parts (node acc)
  "Defensively collect application/pdf leaf parts below NODE."
  (handler-case
      (cond
        ((null node) acc)
        ((listp node)
         (dolist (child node acc)
           (setf acc (notmuch-collect-pdf-parts child acc))))
        ((hash-table-p node)
         (let ((content-type (notmuch-string (gethash "content-type" node)))
               (content (gethash "content" node))
               (part-id (gethash "id" node)))
           (cond
             ((and (string-equal content-type "application/pdf")
                   (integerp part-id)
                   (<= 1 part-id 1000000))
              (cons node acc))
             ((listp content)
              (notmuch-collect-pdf-parts content acc))
             ((gethash "body" node)
              (notmuch-collect-pdf-parts (gethash "body" node) acc))
             (t acc))))
        (t acc))
    (error () acc)))

(defun notmuch-attachment-display-name (value)
  "Return one bounded, control-free basename for a MIME filename."
  (let* ((text (document-safe-display-text (notmuch-string value)))
         (slash (position-if (lambda (character)
                               (or (char= character #\/)
                                   (char= character #\\)))
                             text :from-end t))
         (name (string-trim '(#\Space #\Tab #\Newline #\Return)
                            (if slash (subseq text (1+ slash)) text)))
         (name (substitute #\Space #\Newline name)))
    (cond ((zerop (length name)) "attachment.pdf")
          ((> (length name) 256) (subseq name 0 256))
          (t name))))

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

(defun notmuch-render-message (point message attachment-map)
  "Insert MESSAGE headers, text/plain body, and PDF rows at POINT.

ATTACHMENT-MAP records the exact selectable line for every rendered PDF part."
  (let ((headers (gethash "headers" message)))
    (when (hash-table-p headers)
      (dolist (field '("From" "To" "Date" "Subject"))
        (let ((value (gethash field headers)))
          (when value
            (insert-string point (format nil "~a: ~a~%" field
                                         (notmuch-string value))))))))
  (let ((tags (gethash "tags" message)))
    (when (listp tags)
      (insert-string point (format nil "Tags: ~a~%" (notmuch-tags-string tags)))))
  (insert-string point (format nil "~%"))
  (let* ((body (gethash "body" message))
         (parts (nreverse (notmuch-collect-text-parts body '()))))
    (if parts
        (dolist (part parts)
          (insert-string point part)
          (insert-string point (format nil "~%")))
        (insert-string point (format nil "[no text/plain body]~%"))))
  (let ((pdf-parts
          (nreverse (notmuch-collect-pdf-parts (gethash "body" message) '())))
        (message-id (notmuch-string (gethash "id" message))))
    (when pdf-parts
      (insert-string point (format nil "~%PDF attachments:~%"))
      (dolist (part pdf-parts)
        (let* ((line (line-number-at-point point))
               (filename
                 (notmuch-attachment-display-name (gethash "filename" part)))
               (attachment
                 (make-notmuch-attachment
                  :message-id message-id
                  :part-id (gethash "id" part)
                  :filename filename)))
          (setf (gethash line attachment-map) attachment)
          (insert-string point
                         (format nil "  [PDF] ~a  (Return to preview)~%"
                                 filename))))))
  (insert-string point (format nil "~%~a~%~%" (make-string 60 :initial-element #\-))))

(defun notmuch-show (thread-id &optional selected-message-id parent-buffer)
  "Render THREAD-ID, restoring SELECTED-MESSAGE-ID and PARENT-BUFFER.

Real search JSON carries a bare thread ID, so the CLI receives an exact
`thread:' query.  Every rendered message is visible; like Emacs Notmuch's
post-command hook, opening it removes `unread' from those messages once."
  (unless (notmuch-available-p)
    (message "notmuch not found on PATH")
    (return-from notmuch-show))
  (let* ((bare-thread-id (notmuch-bare-thread-id thread-id))
         (parent-buffer
           (or parent-buffer
               (and (eq (buffer-major-mode (current-buffer)) 'notmuch-show-mode)
                    (buffer-value (current-buffer) 'notmuch-parent-buffer)))))
    (multiple-value-bind (tree success-p)
        (notmuch-run-json
         (list "show" "--format=json" "--include-html=false" "--exclude=false"
               (notmuch-thread-id-query bare-thread-id)))
      (unless success-p
        (message "notmuch show failed for ~a" bare-thread-id)
        (return-from notmuch-show))
      (let* ((messages (nreverse (notmuch-collect-messages tree '())))
             (message-ids
               (remove "" (mapcar (lambda (message)
                                     (notmuch-string (gethash "id" message)))
                                   messages)
                       :test #'string=))
             (unread-ids
               (loop :for message :in messages
                     :for message-id := (notmuch-string (gethash "id" message))
                     :when (member "unread" (gethash "tags" message)
                                   :test #'string=)
                       :collect message-id))
             (buffer
               (make-buffer (format nil "*lem-yath-mail: ~a*" bare-thread-id)))
           (line->message-id (make-hash-table :test 'eql))
           (line->attachment (make-hash-table :test 'eql)))
        (when (and unread-ids
                   (notmuch-change-tags (notmuch-message-ids-query unread-ids)
                                        '("-unread")))
          (dolist (message messages)
            (notmuch-update-object-tags message '("-unread")))
          (notmuch-update-search-thread parent-buffer bare-thread-id
                                        '("-unread")))
        (with-buffer-read-only buffer nil
          (erase-buffer buffer)
          (let ((point (buffer-point buffer))
                (selected-line nil))
            (if messages
                (dolist (message messages)
                  (let ((start-line (line-number-at-point point))
                        (message-id (notmuch-string (gethash "id" message))))
                    (when (and selected-message-id
                               (string= selected-message-id message-id))
                      (setf selected-line start-line))
                    (notmuch-render-message point message line->attachment)
                    (when (plusp (length message-id))
                      (loop :for line :from start-line
                            :to (line-number-at-point point)
                            :do (setf (gethash line line->message-id)
                                      message-id)))))
                (insert-string point
                               (format nil "No messages in thread ~a~%"
                                       bare-thread-id)))
            (setf (buffer-value buffer 'notmuch-thread-id) bare-thread-id)
            (setf (buffer-value buffer 'notmuch-parent-buffer) parent-buffer)
            (setf (buffer-value buffer 'notmuch-messages) messages)
            (setf (buffer-value buffer 'notmuch-message-ids) message-ids)
            (setf (buffer-value buffer 'notmuch-line->message-id)
                  line->message-id)
            (setf (buffer-value buffer 'notmuch-line->attachment)
                  line->attachment)
            (buffer-start point)
            (when selected-line (move-to-line point selected-line))))
        (change-buffer-mode buffer 'notmuch-show-mode)
        (setf (buffer-read-only-p buffer) t)
        (switch-to-window (pop-to-buffer buffer))))))

;;; --- PDF attachment preview ----------------------------------------------

(defun notmuch-private-temp-directory ()
  "Create and return a new owner-private attachment directory."
  #+sbcl
  (loop :repeat 64
        :for pathname :=
          (uiop:ensure-directory-pathname
           (merge-pathnames
            (format nil "lem-yath-notmuch-~d-~16,'0x/"
                    (sb-posix:getpid) (random (ash 1 60)))
            (uiop:temporary-directory)))
        :do (let ((created-p nil))
              (handler-case
                  (progn
                    (sb-posix:mkdir (uiop:native-namestring pathname) #o700)
                    (setf created-p t)
                    (let ((stat (sb-posix:lstat
                                 (uiop:native-namestring pathname))))
                      (unless
                          (and (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                               (= (logand (sb-posix:stat-mode stat)
                                          sb-posix:s-ifmt)
                                  sb-posix:s-ifdir)
                               (zerop (logand (sb-posix:stat-mode stat)
                                             #o077)))
                        (error "Unsafe attachment directory")))
                    (return pathname))
                (error ()
                  (when created-p
                    (ignore-errors
                      (sb-posix:rmdir
                       (uiop:native-namestring pathname)))))))
        :finally (editor-error "Could not create a private attachment directory"))
  #-sbcl
  (editor-error "Secure attachment preview requires the supported SBCL runtime"))

(defun notmuch-extract-raw-part (attachment pathname)
  "Extract ATTACHMENT's decoded raw bytes into a new private PATHNAME."
  #+sbcl
  (let ((notmuch (or (executable-find "notmuch")
                     (editor-error "notmuch not found on PATH")))
        (descriptor nil)
        (file-stream nil)
        (process nil)
        (finished-p nil)
        (complete-p nil)
        (*project-process-timeout* *notmuch-process-timeout*))
    (unwind-protect
         (progn
           (setf descriptor
                 (sb-posix:open
                  (uiop:native-namestring pathname)
                  (logior sb-posix:o-creat sb-posix:o-excl
                          sb-posix:o-wronly sb-posix:o-nofollow)
                  #o600))
           (sb-posix:fchmod descriptor #o600)
           (setf file-stream
                 (sb-sys:make-fd-stream
                  descriptor :output t :element-type '(unsigned-byte 8)
                  :buffering :full
                  :name (uiop:native-namestring pathname))
                 descriptor nil)
           (setf process
                 (uiop:launch-program
                  (project-timeout-command
                   (list (uiop:native-namestring notmuch)
                         "show" "--format=raw"
                         (format nil "--part=~d"
                                 (notmuch-attachment-part-id attachment))
                         (notmuch-message-id-query
                          (notmuch-attachment-message-id attachment))))
                  :directory (or (ignore-errors
                                   (buffer-directory (current-buffer)))
                                 (uiop:getcwd))
                  :input nil :output :stream :error-output nil
                  :element-type '(unsigned-byte 8)))
           (let ((octets (make-array 65536 :element-type '(unsigned-byte 8)))
                 (count 0))
             (with-open-stream (stdout (uiop:process-info-output process))
               (loop :for length := (read-sequence octets stdout)
                     :until (zerop length)
                     :do (incf count length)
                         (when (> count *notmuch-attachment-output-limit*)
                           (ignore-errors (uiop:terminate-process process))
                           (editor-error
                            "PDF attachment exceeds the ~d MiB preview limit"
                            (floor *notmuch-attachment-output-limit* 1048576)))
                         (write-sequence octets file-stream :end length))))
           (finish-output file-stream)
           (close file-stream)
           (setf file-stream nil)
           (let ((status (uiop:wait-process process)))
             (setf finished-p t)
             (unless (and (integerp status) (zerop status))
               (editor-error "notmuch could not extract PDF part ~d (exit ~a)"
                             (notmuch-attachment-part-id attachment) status)))
           (unless (with-open-file (stream pathname
                                           :element-type '(unsigned-byte 8))
                     (let ((magic (make-array 5 :element-type '(unsigned-byte 8))))
                       (and (= (read-sequence magic stream) 5)
                            (equalp magic #(37 80 68 70 45)))))
             (editor-error "The selected attachment is not a PDF file"))
           (setf complete-p t)
           pathname)
      (when file-stream (ignore-errors (close file-stream :abort t)))
      (when descriptor (ignore-errors (sb-posix:close descriptor)))
      (when (and process (not finished-p))
        (ignore-errors (uiop:terminate-process process))
        (ignore-errors (uiop:wait-process process)))
      (unless complete-p
        (ignore-errors (delete-file pathname)))))
  #-sbcl
  (declare (ignore attachment pathname))
  #-sbcl
  (editor-error "Secure attachment preview requires the supported SBCL runtime"))

(defun notmuch-remove-temp-attachment (pathname directory)
  (when pathname (ignore-errors (delete-file pathname)))
  #+sbcl
  (when directory
    (ignore-errors (sb-posix:rmdir (uiop:native-namestring directory)))))

(defun notmuch-delete-temp-attachment (&optional (buffer (current-buffer)))
  "Delete the private PDF attachment owned by BUFFER."
  (let ((pathname (buffer-value buffer 'notmuch-temp-attachment))
        (directory (buffer-value buffer 'notmuch-temp-directory)))
    (setf (buffer-value buffer 'notmuch-temp-attachment) nil
          (buffer-value buffer 'notmuch-temp-directory) nil)
    (notmuch-remove-temp-attachment pathname directory)))

(define-command lem-yath-notmuch-open-part () ()
  "Preview the PDF attachment on the current Notmuch show line."
  (alexandria:if-let ((attachment (notmuch-attachment-at-point)))
    (let* ((origin-window (current-window))
           (origin-buffer (current-buffer))
           (origin-pop-state
             (lem-core::window-pop-to-buffer-state origin-window))
           (directory (notmuch-private-temp-directory))
           (pathname (merge-pathnames "attachment.pdf" directory))
           (transferred-p nil))
      (unwind-protect
           (progn
             (notmuch-extract-raw-part attachment pathname)
             (let ((buffer
                     (document-open-buffer pathname :pdf :ephemeral-p t)))
               (setf (buffer-value buffer 'notmuch-temp-attachment) pathname
                     (buffer-value buffer 'notmuch-temp-directory) directory
                     (buffer-value buffer 'document-return-buffer) origin-buffer
                     (buffer-value buffer 'document-return-pop-state)
                     origin-pop-state)
               (add-hook (variable-value 'kill-buffer-hook :buffer buffer)
                         'notmuch-delete-temp-attachment)
               (setf transferred-p t)
               ;; Replace the show buffer in-place.  A nested pop-to split can
               ;; transfer or discard the show's own parent link; preserving
               ;; the same window avoids altering the surrounding tree.
               (switch-to-buffer buffer nil)
               (setf (lem-core::window-pop-to-buffer-state origin-window)
                     origin-pop-state)))
        (unless transferred-p
          (notmuch-remove-temp-attachment pathname directory))))
    (message "No PDF attachment on this line")))

(define-command lem-yath-notmuch-open-thread () ()
  "Open the thread on the current *lem-yath-mail* line in a read-only view (Return)."
  (let ((id (notmuch-thread-id-at-point))
        (parent-buffer (current-buffer)))
    (if id
        (notmuch-show id nil parent-buffer)
        (message "No thread on this line"))))

(define-command lem-yath-notmuch-show-refresh () ()
  "Refresh the currently displayed Notmuch thread (g)."
  (let ((buffer (current-buffer)))
    (alexandria:if-let ((thread-id (buffer-value buffer 'notmuch-thread-id)))
      (notmuch-show thread-id
                    (notmuch-message-id-at-point)
                    (buffer-value buffer 'notmuch-parent-buffer))
      (message "No Notmuch thread to refresh"))))

(defun notmuch-select-search-thread (buffer thread-id)
  "Select THREAD-ID in live search BUFFER without querying Notmuch."
  (when (and buffer (not (deleted-buffer-p buffer)))
    (notmuch-render-search buffer
                           (buffer-value buffer 'notmuch-threads)
                           (buffer-value buffer 'notmuch-query)
                           thread-id)))

(defun notmuch-show-next-thread-id (buffer)
  "Return the parent search row after BUFFER's current thread."
  (let ((parent (buffer-value buffer 'notmuch-parent-buffer))
        (thread-id (buffer-value buffer 'notmuch-thread-id)))
    (and parent
         (notmuch-next-id (buffer-value parent 'notmuch-thread-ids)
                          thread-id))))

(defun notmuch-leave-show (show-next-p)
  "Exit the current show buffer, selecting or opening its next search thread."
  (let* ((show-buffer (current-buffer))
         (parent (buffer-value show-buffer 'notmuch-parent-buffer))
         (thread-id (buffer-value show-buffer 'notmuch-thread-id))
         (next-thread-id (notmuch-show-next-thread-id show-buffer)))
    (when parent
      (notmuch-select-search-thread parent (or next-thread-id thread-id)))
    (quit-active-window)
    (when (and show-next-p next-thread-id parent)
      (notmuch-show next-thread-id nil parent))))

(defun notmuch-show-tag-current (tag-changes &optional advance-p end-action)
  "Apply TAG-CHANGES to the current message.

When ADVANCE-P is true, select the next message.  At the final message,
END-ACTION is `next-thread', `exit', or NIL to remain on that message."
  (let* ((buffer (current-buffer))
         (message-id (notmuch-message-id-at-point))
         (thread-id (buffer-value buffer 'notmuch-thread-id))
         (parent (buffer-value buffer 'notmuch-parent-buffer))
         (message-ids (buffer-value buffer 'notmuch-message-ids))
         (next-message-id (and message-id
                               (notmuch-next-id message-ids message-id))))
    (unless message-id
      (message "No message at point")
      (return-from notmuch-show-tag-current nil))
    (when (notmuch-change-tags (notmuch-message-id-query message-id)
                               tag-changes)
      (notmuch-update-object-tags (notmuch-message-object buffer message-id)
                                  tag-changes)
      (cond
        ((and advance-p next-message-id)
         (notmuch-show thread-id next-message-id parent))
        ((and advance-p (eq end-action 'next-thread))
         (notmuch-leave-show t))
        ((and advance-p (eq end-action 'exit))
         (notmuch-leave-show nil))
        (t
         (notmuch-show thread-id message-id parent)))
      t)))

(defun notmuch-show-toggle-current-tag (tag)
  "Toggle TAG on the current message and advance like Evil-collection."
  (let* ((buffer (current-buffer))
         (message-id (notmuch-message-id-at-point))
         (message (and message-id (notmuch-message-object buffer message-id)))
         (tags (and message (gethash "tags" message)))
         (change (format nil "~c~a"
                         (if (member tag tags :test #'string=) #\- #\+)
                         tag)))
    (if message
        (notmuch-show-tag-current (list change) t)
        (message "No message at point"))))

(defun notmuch-show-archive-thread (show-next-p)
  "Archive the messages rendered in this thread, then exit or show the next."
  (let* ((buffer (current-buffer))
         (thread-id (buffer-value buffer 'notmuch-thread-id))
         (parent (buffer-value buffer 'notmuch-parent-buffer))
         (message-ids (buffer-value buffer 'notmuch-message-ids)))
    (when (and message-ids
               (notmuch-change-tags (notmuch-message-ids-query message-ids)
                                    '("-inbox")))
      (dolist (message (buffer-value buffer 'notmuch-messages))
        (notmuch-update-object-tags message '("-inbox")))
      (notmuch-update-search-thread parent thread-id '("-inbox"))
      (notmuch-leave-show show-next-p)
      t)))

(define-command lem-yath-notmuch-show-archive-message-next-thread () ()
  "Archive this message, then open the next message or next thread (`a')."
  (notmuch-show-tag-current '("-inbox") t 'next-thread))

(define-command lem-yath-notmuch-show-archive-message-next-exit () ()
  "Archive this message, then open the next message or exit (`x')."
  (notmuch-show-tag-current '("-inbox") t 'exit))

(define-command lem-yath-notmuch-show-archive-thread-next () ()
  "Archive all rendered messages and open the next search thread (`A')."
  (notmuch-show-archive-thread t))

(define-command lem-yath-notmuch-show-archive-thread-exit () ()
  "Archive all rendered messages and return to the search list (`X')."
  (notmuch-show-archive-thread nil))

(define-command lem-yath-notmuch-show-toggle-deleted () ()
  "Toggle `deleted' on the current message and advance (`d')."
  (notmuch-show-toggle-current-tag "deleted"))

(define-command lem-yath-notmuch-show-toggle-flagged () ()
  "Toggle `flagged' on the current message and advance (`=')."
  (notmuch-show-toggle-current-tag "flagged"))

(define-command lem-yath-notmuch-show-add-tag () ()
  "Prompt for one tag to add to the current message (`+')."
  (let ((tag (notmuch-prompt-tag "add")))
    (notmuch-show-tag-current (list (concatenate 'string "+" tag)))))

(define-command lem-yath-notmuch-show-remove-tag () ()
  "Prompt for one tag to remove from the current message (`-')."
  (let ((tag (notmuch-prompt-tag "remove")))
    (notmuch-show-tag-current (list (concatenate 'string "-" tag)))))

;;; --- fetch mail ------------------------------------------------------------

(define-command lem-yath-fetchmail () ()
  "Fetch and index new mail: `mbsync -a && notmuch new' (yath/fetchmail).
Streams progress into *lem-yath-fetchmail*."
  (cond
    ((not (executable-find "mbsync"))
     (message "mbsync not found on PATH"))
    ((not (notmuch-available-p))
     (message "notmuch not found on PATH"))
    (t
     (stream-to-buffer (list "sh" "-c" "mbsync -a && notmuch new")
                       *notmuch-fetch-buffer-name*))))
