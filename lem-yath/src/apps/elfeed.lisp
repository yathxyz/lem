;;;; lem-yath apps/elfeed -- RSS reader (elfeed + elfeed-protocol, Fever API).
;;;;
;;;; The Emacs config drove a Miniflux instance through elfeed-protocol's
;;;; Fever backend (http://rss.wg:8070/fever/, credentials in ~/.authinfo).
;;;; This is a self-contained native port: it speaks the Fever API directly
;;;; with curl, on a background thread, marshalling all UI work back onto the
;;;; editor thread via send-event so the command never hangs the editor.
;;;;
;;;; Fever protocol used here (all GET unless noted):
;;;;   POST api_key=<md5 hex of "user:password">  to <endpoint>?api
;;;;   ?api&unread_item_ids   -> {"unread_item_ids":"1,2,3"}
;;;;   ?api&items&with_ids=.. -> {"items":[{id,feed_id,title,url,html,...}]}
;;;;   ?api&feeds             -> {"feeds":[{id,title,...}]}

(in-package :lem-yath)

;;; --- knobs -----------------------------------------------------------------

(defparameter *elfeed-endpoint* "http://rss.wg:8070/fever/"
  "Fever API endpoint, mirroring elfeed-protocol-feeds :api-url.")

(defparameter *elfeed-machine* "rss.wg"
  "authinfo/netrc machine to look up for Fever credentials.")

(defparameter *elfeed-curl-timeout* 10
  "Seconds passed to curl --max-time for every Fever request.")

(defparameter *elfeed-batch-size* 50
  "Maximum item ids requested per ?api&items&with_ids call.")

(defparameter *elfeed-archive-url* "https://archive.ph/newest/"
  "Prefix for the archive.ph view (ports elfeed-show-archive).")

(defparameter *elfeed-list-buffer-name* "*lem-yath-feeds*")
(defparameter *elfeed-entry-buffer-name* "*lem-yath-feed-entry*")

;;; --- per-buffer state ------------------------------------------------------
;;; The list buffer carries a vector of entry plists indexed by 0-based line,
;;; plus the resolved feed-title table, so the keymap commands can recover the
;;; entry under point. Entry buffers carry just the single entry's plist.

(defvar *elfeed-line-entries-key* 'elfeed-line-entries)
(defvar *elfeed-entry-key* 'elfeed-entry)

;;; --- credential discovery --------------------------------------------------

(defun elfeed-authinfo-files ()
  "Candidate plaintext credential files, in lookup order."
  (remove-if-not
   #'uiop:file-exists-p
   (list (merge-pathnames ".authinfo" (user-homedir-pathname))
         (merge-pathnames ".netrc" (user-homedir-pathname)))))

(defun elfeed-parse-authinfo-line (line machine)
  "If authinfo/netrc LINE is a machine entry for MACHINE, return
(values login password); otherwise NIL. Tokens are whitespace-separated
keyword/value pairs (machine/login/password/port...)."
  (let ((tokens (remove-if (lambda (s) (zerop (length s)))
                           (uiop:split-string (string-trim '(#\Space #\Tab #\Return) line)
                                              :separator '(#\Space #\Tab))))
        (this-machine nil) (login nil) (password nil))
    (loop :for (key value) :on tokens :by #'cddr
          :while value
          :do (cond ((string-equal key "machine") (setf this-machine value))
                    ((or (string-equal key "login") (string-equal key "user"))
                     (setf login value))
                    ((string-equal key "password") (setf password value))))
    (when (and this-machine (string-equal this-machine machine) login password)
      (values login password))))

(defun elfeed-credentials ()
  "Return (values user password) for *elfeed-machine* from authinfo/netrc,
or NIL if no plaintext entry is found."
  (handler-case
      (dolist (file (elfeed-authinfo-files) nil)
        (with-open-file (s file :direction :input :if-does-not-exist nil)
          (when s
            (loop :for line := (read-line s nil)
                  :while line
                  :do (multiple-value-bind (login password)
                          (elfeed-parse-authinfo-line line *elfeed-machine*)
                        (when login
                          (return-from elfeed-credentials
                            (values login password))))))))
    (error () nil)))

(defun elfeed-api-key (user password)
  "Fever api_key: md5 hex of \"user:password\". Computed via the md5sum
binary (no md5 library is in the image)."
  (let ((md5 (executable-find "md5sum")))
    (unless md5
      (return-from elfeed-api-key nil))
    (handler-case
        (let ((out (uiop:run-program
                    (list (namestring md5))
                    :input (make-string-input-stream
                            (format nil "~a:~a" user password))
                    :output :string
                    :ignore-error-status t)))
          ;; md5sum prints "<hex>  -"; take the leading hex token.
          (let ((token (first (uiop:split-string (string-trim '(#\Space #\Newline) out)
                                                 :separator '(#\Space)))))
            (and token (plusp (length token)) token)))
      (error () nil))))

;;; --- Fever HTTP (background thread only) ------------------------------------

(defun elfeed-curl (api-key query)
  "POST api_key to <endpoint>?api&QUERY with curl --max-time and return the
parsed JSON hash-table, or NIL on any failure. Runs on a worker thread."
  (handler-case
      (let* ((url (format nil "~a?api&~a" *elfeed-endpoint* query))
             (body (uiop:run-program
                    (list "curl" "-s" "--max-time"
                          (princ-to-string *elfeed-curl-timeout*)
                          "--data-urlencode" (format nil "api_key=~a" api-key)
                          url)
                    :output :string
                    :ignore-error-status t)))
        (when (and body (plusp (length body)))
          (yason:parse body)))
    (error () nil)))

(defun elfeed-unread-ids (api-key)
  "List of unread item id strings (newest-first as returned by the server)."
  (let ((json (elfeed-curl api-key "unread_item_ids")))
    (when (hash-table-p json)
      (let ((ids (gethash "unread_item_ids" json)))
        (when (stringp ids)
          (remove-if (lambda (s) (zerop (length s)))
                     (uiop:split-string ids :separator '(#\,))))))))

(defun elfeed-feed-titles (api-key)
  "Hash-table mapping feed id (as a number) -> feed title string."
  (let ((table (make-hash-table :test #'eql))
        (json (elfeed-curl api-key "feeds")))
    (when (hash-table-p json)
      (let ((feeds (gethash "feeds" json)))
        (when (listp feeds)
          (dolist (feed feeds)
            (when (hash-table-p feed)
              (let ((id (gethash "id" feed))
                    (title (gethash "title" feed)))
                (when (and (numberp id) (stringp title))
                  (setf (gethash id table) title))))))))
    table))

(defun elfeed-fetch-items (api-key ids)
  "Fetch the items for IDS (a list of id strings) in batches of
*elfeed-batch-size*. Returns a list of item hash-tables, server order."
  (let ((items '()))
    (loop :for rest := ids :then (nthcdr *elfeed-batch-size* rest)
          :while rest
          :for batch := (subseq rest 0 (min *elfeed-batch-size* (length rest)))
          :for json := (elfeed-curl api-key
                                    (format nil "items&with_ids=~{~a~^,~}" batch))
          :do (when (hash-table-p json)
                (let ((batch-items (gethash "items" json)))
                  (when (listp batch-items)
                    (setf items (append items batch-items))))))
    items))

;;; --- rendering helpers ------------------------------------------------------

(defun elfeed-item-date (item)
  "Render an item's created_on_time (Unix seconds) as YYYY-MM-DD, or ?? "
  (let ((unix (gethash "created_on_time" item)))
    (if (numberp unix)
        (multiple-value-bind (sec min hour day month year)
            ;; Unix epoch -> universal time.
            (decode-universal-time (+ (truncate unix) 2208988800) 0)
          (declare (ignore sec min hour))
          (format nil "~4,'0d-~2,'0d-~2,'0d" year month day))
        "??????????")))

(defun elfeed-item->entry (item feed-titles)
  "Build an entry plist (date, feed, title, url, html) from a Fever item."
  (let ((feed-id (gethash "feed_id" item)))
    (list :date (elfeed-item-date item)
          :feed (or (and (numberp feed-id) (gethash feed-id feed-titles)) "")
          :title (or (gethash "title" item) "(untitled)")
          :url (or (gethash "url" item) "")
          :html (or (gethash "html" item) ""))))

;;; --- HTML -> readable text (cl-ppcre) --------------------------------------

(defparameter *elfeed-entities*
  '(("&amp;" . "&") ("&lt;" . "<") ("&gt;" . ">")
    ("&quot;" . "\"") ("&#39;" . "'") ("&apos;" . "'")
    ("&nbsp;" . " ") ("&mdash;" . "--") ("&ndash;" . "-")
    ("&hellip;" . "..."))
  "The few common HTML entities worth decoding for readable plain text.")

(defun elfeed-decode-entities (text)
  (let ((result text))
    (dolist (pair *elfeed-entities* result)
      (setf result (cl-ppcre:regex-replace-all (cl-ppcre:quote-meta-chars (car pair))
                                               result (cdr pair))))))

(defun elfeed-html->text (html)
  "Strip HTML to readable text: drop script/style bodies and all tags,
decode common entities, collapse runs of blank lines."
  (handler-case
      (let ((text html))
        ;; Remove script/style element bodies first.
        (setf text (cl-ppcre:regex-replace-all
                    "(?is)<(script|style)[^>]*>.*?</\\1>" text ""))
        ;; Block-ish tags become newlines so paragraphs survive.
        (setf text (cl-ppcre:regex-replace-all
                    "(?i)<(br|/p|/div|/li|/h[1-6])[^>]*>" text (string #\Newline)))
        ;; Drop every remaining tag.
        (setf text (cl-ppcre:regex-replace-all "(?s)<[^>]*>" text ""))
        (setf text (elfeed-decode-entities text))
        ;; Collapse 3+ newlines into a blank-line separator.
        (setf text (cl-ppcre:regex-replace-all "\\n[ \\t]*\\n[ \\t]*(\\n)+" text
                                               (format nil "~%~%")))
        (string-trim '(#\Space #\Tab #\Newline #\Return) text))
    (error () html)))

;;; --- list buffer (editor thread) -------------------------------------------

(defun elfeed-fill-list (buffer entries feed-titles)
  "Fill BUFFER with ENTRIES (a list of item hash-tables) as a read-only list,
recording the per-line entry plists. Runs on the editor thread."
  (declare (ignore feed-titles))
  (with-buffer-read-only buffer nil
    (erase-buffer buffer)
    (let* ((plists (mapcar (lambda (item)
                             (getf item :%entry))
                           entries))
           (line-vector (make-array (length plists) :initial-contents plists))
           (point (buffer-point buffer)))
      (move-point point (buffer-start-point buffer))
      (loop :for plist :in plists
            :do (insert-string point
                               (format nil "~a  ~25a  ~a~%"
                                       (getf plist :date)
                                       (let ((feed (getf plist :feed)))
                                         (if (> (length feed) 25)
                                             (subseq feed 0 25)
                                             feed))
                                       (getf plist :title))))
      (setf (buffer-value buffer *elfeed-line-entries-key*) line-vector)
      (move-point (buffer-point buffer) (buffer-start-point buffer))))
  (setf (buffer-read-only-p buffer) t))

(defun elfeed-entry-at-point ()
  "The entry plist on the current line of the feeds list, or NIL."
  (let* ((buffer (current-buffer))
         (vector (buffer-value buffer *elfeed-line-entries-key*)))
    (when (and (vectorp vector) (plusp (length vector)))
      (let ((index (1- (line-number-at-point (current-point)))))
        (when (and (>= index 0) (< index (length vector)))
          (aref vector index))))))

;;; --- opening urls externally -----------------------------------------------

(defun elfeed-open-external (url)
  "Open URL with xdg-open in the background. Degrades to a message if the
url is empty or xdg-open is unavailable."
  (cond ((or (null url) (zerop (length url)))
         (message "No URL for this entry"))
        ((not (executable-find "xdg-open"))
         (message "xdg-open not found; cannot open ~a" url))
        (t
         (handler-case
             (progn
               (uiop:launch-program (list "xdg-open" url)
                                    :output nil :error-output nil)
               (message "Opening ~a" url))
           (error (e) (message "Failed to open ~a: ~a" url e))))))

(defun elfeed-current-url ()
  "The URL of the entry under point (feeds list) or of the shown entry."
  (let ((buffer (current-buffer)))
    (or (getf (buffer-value buffer *elfeed-entry-key*) :url)
        (getf (elfeed-entry-at-point) :url))))

;;; --- show entry -------------------------------------------------------------

(defun elfeed-show-entry-plist (plist)
  "Render PLIST into the read-only entry buffer and display it."
  (let ((buffer (make-buffer *elfeed-entry-buffer-name*)))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (change-buffer-mode buffer 'lem-yath-feed-entry-mode)
      (let ((point (buffer-point buffer)))
        (insert-string point
                       (format nil "~a~%~a   ~a~%~a~%~%~a~%"
                               (getf plist :title)
                               (getf plist :feed)
                               (getf plist :date)
                               (getf plist :url)
                               (elfeed-html->text (getf plist :html))))
        (setf (buffer-value buffer *elfeed-entry-key*) plist)
        (move-point (buffer-point buffer) (buffer-start-point buffer))))
    (setf (buffer-read-only-p buffer) t)
    (pop-to-buffer buffer)))

;;; --- modes & keymaps --------------------------------------------------------
;;; Single-letter keys (b/A/g/q) would otherwise be shadowed by vi-mode's
;;; normal-state keymap; mode-specific-keymaps makes these major-mode keymaps
;;; win while a feeds buffer is current (see vi-mode special-binds.lisp).

(define-major-mode lem-yath-feeds-mode nil
    (:name "lem-yath-feeds"
     :keymap *lem-yath-feeds-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(define-major-mode lem-yath-feed-entry-mode nil
    (:name "lem-yath-feed-entry"
     :keymap *lem-yath-feed-entry-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode lem-yath-feeds-mode))
  (list *lem-yath-feeds-mode-keymap*))

(defmethod lem-vi-mode/core:mode-specific-keymaps ((mode lem-yath-feed-entry-mode))
  (list *lem-yath-feed-entry-mode-keymap*))

(define-command lem-yath-elfeed-show-entry () ()
  "Show the entry under point in a readable, read-only buffer."
  (alexandria:if-let ((plist (elfeed-entry-at-point)))
    (elfeed-show-entry-plist plist)
    (message "No entry on this line")))

(define-command lem-yath-elfeed-open-url () ()
  "Open the current entry's URL via xdg-open (elfeed b/visit)."
  (elfeed-open-external (elfeed-current-url)))

(define-command lem-yath-elfeed-archive () ()
  "Open the current entry via archive.ph (ports elfeed-show-archive)."
  (let ((url (elfeed-current-url)))
    (if (and url (plusp (length url)))
        (elfeed-open-external (concatenate 'string *elfeed-archive-url* url))
        (message "No URL for this entry"))))

(define-command lem-yath-elfeed-quit () ()
  "Close the active feeds/entry window (q)."
  (quit-active-window))

(define-key *lem-yath-feeds-mode-keymap* "Return" 'lem-yath-elfeed-show-entry)
(define-key *lem-yath-feeds-mode-keymap* "b" 'lem-yath-elfeed-open-url)
(define-key *lem-yath-feeds-mode-keymap* "A" 'lem-yath-elfeed-archive)
(define-key *lem-yath-feeds-mode-keymap* "q" 'lem-yath-elfeed-quit)
(define-key *lem-yath-feeds-mode-keymap* "g" 'lem-yath-elfeed)
(define-key *lem-yath-feeds-mode-keymap* "n" 'next-line)
(define-key *lem-yath-feeds-mode-keymap* "p" 'previous-line)

(define-key *lem-yath-feed-entry-mode-keymap* "b" 'lem-yath-elfeed-open-url)
(define-key *lem-yath-feed-entry-mode-keymap* "A" 'lem-yath-elfeed-archive)
(define-key *lem-yath-feed-entry-mode-keymap* "q" 'lem-yath-elfeed-quit)

;;; --- the command ------------------------------------------------------------

(defun elfeed-load-async (api-key buffer)
  "Fetch feeds + unread items off the editor thread, then fill BUFFER.
Every step degrades gracefully to a (message ...) on the editor thread."
  (bt2:make-thread
   (lambda ()
     (handler-case
         (let* ((feed-titles (elfeed-feed-titles api-key))
                (ids (elfeed-unread-ids api-key)))
           (cond
             ((null ids)
              (send-event (lambda () (message "No unread feed items (or server unreachable)"))))
             (t
              (let* ((items (elfeed-fetch-items api-key ids))
                     ;; Pre-compute entry plists off-thread; the editor thread
                     ;; just inserts them.
                     (entries (mapcar (lambda (item)
                                        (list :%entry (elfeed-item->entry item feed-titles)))
                                      items)))
                (if (null entries)
                    (send-event (lambda () (message "Fetched no feed items")))
                    (send-event
                     (lambda ()
                       (elfeed-fill-list buffer entries feed-titles)
                       (message "~a unread item~:p" (length entries)))))))))
       (error (e)
         (let ((msg (princ-to-string e)))
           (send-event (lambda () (message "Feeds error: ~a" msg)))))))
   :name "lem-yath/elfeed")
  (values))

(define-command lem-yath-elfeed () ()
  "Open the unread RSS feed list (elfeed) in *lem-yath-feeds*.
Reads rss.wg credentials from ~/.authinfo, derives the Fever api_key, and
fetches unread items on a background thread; returns immediately."
  (multiple-value-bind (user password) (elfeed-credentials)
    (unless user
      (message "No ~~/.authinfo entry for machine ~a" *elfeed-machine*)
      (return-from lem-yath-elfeed))
    (let ((api-key (elfeed-api-key user password)))
      (unless api-key
        (message "Could not compute Fever api_key (md5sum missing?)")
        (return-from lem-yath-elfeed))
      (let ((buffer (make-buffer *elfeed-list-buffer-name*)))
        (change-buffer-mode buffer 'lem-yath-feeds-mode)
        (with-buffer-read-only buffer nil
          (erase-buffer buffer)
          (insert-string (buffer-point buffer) "Fetching unread feeds..."))
        (setf (buffer-read-only-p buffer) t)
        (pop-to-buffer buffer)
        (elfeed-load-async api-key buffer)))))
