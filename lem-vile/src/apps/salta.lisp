;;;; vile apps/salta -- Supabase/PostgREST client for Salta (port of salta.el).
;;;; Searches properties, views contractor rates/financials, browses payments
;;;; and the revenue/cost/profit "reckoner", over the same REST views and RPCs.
;;;; HTTP is curl (uiop) on a background thread; results are marshalled back
;;;; onto the editor thread with send-event. yason handles JSON.

(in-package :vile)

;;; --- credentials ----------------------------------------------------------

(defvar *salta-base-url* nil
  "Supabase project URL, e.g. \"https://xyz.supabase.co\".
Falls back to $SALTA_SUPABASE_URL then the credentials file.")

(defvar *salta-api-key* nil
  "Supabase service_role key, used as both apikey header and Bearer token.
Falls back to $SALTA_SUPABASE_KEY then the credentials file.")

(defvar *salta-credentials-file*
  (merge-pathnames ".config/salta/credentials.json" (user-homedir-pathname))
  "JSON file {\"url\":..,\"key\":..} consulted after defvars and env vars.")

(defvar *salta-search-limit* 20
  "Maximum number of results for fuzzy property search.")

(defun salta-read-credentials ()
  "Parsed credentials hash-table from `*salta-credentials-file*', or NIL."
  (let ((path (and *salta-credentials-file*
                   (uiop:probe-file* *salta-credentials-file*))))
    (when path
      (handler-case
          (with-open-file (s path)
            (yason:parse s))
        (error () nil)))))

(defun salta-resolve-url ()
  "The Supabase base URL (no trailing slash), or NIL when unset."
  (let ((url (or *salta-base-url*
                 (uiop:getenv "SALTA_SUPABASE_URL")
                 (let ((c (salta-read-credentials)))
                   (and c (gethash "url" c))))))
    (and url (string-right-trim "/" url))))

(defun salta-resolve-key ()
  "The Supabase API key, or NIL when unset."
  (or *salta-api-key*
      (uiop:getenv "SALTA_SUPABASE_KEY")
      (let ((c (salta-read-credentials)))
        (and c (gethash "key" c)))))

;;; --- HTTP transport (curl) ------------------------------------------------

(defun salta-encode-query (params)
  "Encode PARAMS (an alist of string pairs) as a PostgREST query string."
  (with-output-to-string (s)
    (loop :for (k . v) :in params
          :for first := t :then nil
          :do (unless first (write-char #\& s))
              (write-string (quri:url-encode k) s)
              (write-char #\= s)
              (write-string (quri:url-encode v) s))))

(defun salta-build-url (path &optional params)
  "Full request URL from PATH (starting with /) and optional query PARAMS."
  (let ((base (salta-resolve-url)))
    (if params
        (format nil "~a~a?~a" base path (salta-encode-query params))
        (format nil "~a~a" base path))))

(defun salta-request (method path &key body params)
  "Run a PostgREST request with curl and return the parsed JSON, or signal an
error. METHOD is \"GET\" or \"POST\"; BODY is a hash-table encoded as JSON.
This blocks; callers invoke it from a worker thread."
  (let* ((key (salta-resolve-key))
         (url (salta-build-url path params))
         (body-string (when body
                        (with-output-to-string (s) (yason:encode body s))))
         (args (append
                (list "curl" "-s" "--max-time" "15" "-X" method
                      "-H" (format nil "apikey: ~a" key)
                      "-H" (format nil "Authorization: Bearer ~a" key)
                      "-H" "Content-Type: application/json"
                      "-H" "Accept: application/json")
                (when body-string (list "--data-binary" body-string))
                (list url))))
    (multiple-value-bind (out err code)
        (uiop:run-program args :output :string :error-output :string
                               :ignore-error-status t)
      (declare (ignore err))
      (unless (and (integerp code) (zerop code))
        (error "curl failed (exit ~a) for ~a" code path))
      (let ((result (handler-case
                        (if (zerop (length (string-trim '(#\Space #\Newline) out)))
                            nil
                            (yason:parse out))
                      (error (e) (error "bad JSON from ~a: ~a" path e)))))
        ;; PostgREST error shape: a single object with message + code.
        (when (and (hash-table-p result)
                   (gethash "message" result)
                   (gethash "code" result))
          (error "PostgREST error (~a): ~a"
                 (gethash "code" result) (gethash "message" result)))
        result))))

(defun salta-get (view &optional params)
  "GET /rest/v1/VIEW with optional PARAMS alist; returns a list of rows."
  (salta-request "GET" (concatenate 'string "/rest/v1/" view) :params params))

(defun salta-rpc (function-name args)
  "POST /rest/v1/rpc/FUNCTION-NAME with ARGS (an alist) as the JSON body."
  (salta-request "POST" (concatenate 'string "/rest/v1/rpc/" function-name)
                 :body (alexandria:alist-hash-table args :test #'equal)))

;;; --- value helpers --------------------------------------------------------

(defun salta-aget (key row)
  "Value for KEY (a string) in ROW (a hash-table), \"\" for null/missing."
  (let ((v (and (hash-table-p row) (gethash key row))))
    (if (or (null v) (eq v :null)) "" v)))

(defun salta-to-string (val)
  "Display string for a JSON VAL (numbers, booleans, strings, null)."
  (cond ((or (null val) (eq val :null)) "")
        ((eq val t) "Yes")
        ((eq val nil) "")
        ((stringp val) val)
        ((floatp val) (format nil "~,2f" val))
        ((numberp val) (princ-to-string val))
        (t (princ-to-string val))))

(defun salta-number (val)
  "Coerce VAL (number or numeric string) to a double, 0 for null/blank."
  (cond ((null val) 0d0)
        ((eq val :null) 0d0)
        ((numberp val) (coerce val 'double-float))
        ((stringp val)
         (let ((clean (remove #\, val)))
           (if (zerop (length (string-trim " " clean)))
               0d0
               (or (ignore-errors
                     (coerce (read-from-string clean nil 0) 'double-float))
                   0d0))))
        (t 0d0)))

(defun salta-commify (integer)
  "Group INTEGER's digits with commas."
  (let ((s (princ-to-string (abs integer)))
        (parts '()))
    (loop :while (> (length s) 3)
          :do (push (subseq s (- (length s) 3)) parts)
              (setf s (subseq s 0 (- (length s) 3))))
    (push s parts)
    (format nil "~:[~;-~]~{~a~^,~}" (minusp integer) parts)))

(defun salta-money (val)
  "Format VAL as money with comma separators and two decimals."
  (if (or (null val) (eq val :null) (equal val ""))
      ""
      (let* ((num (salta-number val))
             (neg (minusp num))
             (abs-num (abs num))
             (whole (truncate abs-num))
             (frac (round (* 100 (- abs-num whole)))))
        (format nil "~:[~;-~]~a.~2,'0d" neg (salta-commify whole) frac))))

(defun salta-pct (val)
  "Format VAL as a percentage string."
  (if (or (null val) (eq val :null) (equal val ""))
      ""
      (let ((num (salta-number val)))
        (if (= (truncate num) num)
            (format nil "~d%" (truncate num))
            (format nil "~,1f%" num)))))

(defun salta-date (val)
  "First 10 chars (YYYY-MM-DD) of a timestamp string VAL."
  (let ((s (salta-to-string val)))
    (if (>= (length s) 10) (subseq s 0 10) s)))

(defun salta-truncate (s width)
  (if (> (length s) width) (subseq s 0 width) s))

;;; --- list buffer mode -----------------------------------------------------

(define-major-mode salta-list-mode nil
    (:name "salta-list" :keymap *salta-list-mode-keymap*)
  (setf (buffer-read-only-p (current-buffer)) t))

(define-key *salta-list-mode-keymap* "Return" 'salta-list-open)
(define-key *salta-list-mode-keymap* "r" 'salta-list-reckoner)
(define-key *salta-list-mode-keymap* "w" 'salta-list-copy-id)
(define-key *salta-list-mode-keymap* "g" 'salta-list-refresh)
(define-key *salta-list-mode-keymap* "q" 'quit-active-window)

(defun salta-current-row-id ()
  "Application/row id stored for the current cursor line, or NIL.
The parallel id vector lives in the buffer-local :salta-ids."
  (let* ((buffer (current-buffer))
         (ids (buffer-value buffer :salta-ids))
         ;; Header + separator occupy the first two lines; data starts at 3.
         (index (- (line-number-at-point (current-point)) 3)))
    (when (and ids (<= 0 index) (< index (length ids)))
      (aref ids index))))

(define-command salta-list-open () ()
  "Open the property detail for the row at point (Return)."
  (let ((id (salta-current-row-id)))
    (if id (salta-property-detail-id id) (message "No row at point"))))

(define-command salta-list-reckoner () ()
  "Open the reckoner for the row at point (r)."
  (let ((id (salta-current-row-id)))
    (if id (salta-property-reckoner-id id) (message "No row at point"))))

(define-command salta-list-copy-id () ()
  "Copy the row id at point to the kill ring/clipboard (w)."
  (let ((id (salta-current-row-id)))
    (if id
        (progn (copy-to-clipboard-with-killring id)
               (message "Copied: ~a" id))
        (message "No row at point"))))

(define-command salta-list-refresh () ()
  "Re-run the query that produced this buffer (g)."
  (let ((fn (buffer-value (current-buffer) :salta-refresh)))
    (if fn (funcall fn) (message "Nothing to refresh"))))

;;; --- rendering ------------------------------------------------------------

(defun salta-cell (col row)
  "Display string for COLUMN spec (HEADER WIDTH EXTRACTOR) applied to ROW."
  (let ((extractor (third col)))
    (if (functionp extractor)
        (funcall extractor row)
        (salta-to-string (salta-aget extractor row)))))

(defun salta-emit-table (point columns rows indent)
  "Write a header/separator/ROWS aligned table at POINT, prefixed by INDENT."
  (flet ((emit (cells)
           (insert-string point indent)
           (loop :for cell :in cells
                 :for (nil width) :in columns
                 :do (insert-string point
                                    (format nil "~va  " width
                                            (salta-truncate cell width))))
           (insert-character point #\Newline)))
    (emit (mapcar #'first columns))
    (emit (mapcar (lambda (c) (make-string (second c) :initial-element #\-)) columns))
    (dolist (row rows)
      (emit (mapcar (lambda (col) (salta-cell col row)) columns)))))

(defun salta-show-list (name columns rows id-key refresh-fn &optional footer-fn)
  "Create read-only list BUFFER NAME from ROWS and display it.
ID-KEY (key string or function) yields each row's id, stored line-parallel in
the buffer-local :salta-ids vector. REFRESH-FN re-runs the originating query.
FOOTER-FN, if given, is called with a point at end of buffer for extra lines."
  (let ((buffer (make-buffer name))
        (ids (make-array (length rows))))
    (setf (buffer-read-only-p buffer) nil)
    (erase-buffer buffer)
    (loop :for row :in rows :for i :from 0
          :do (setf (aref ids i)
                    (salta-to-string (if (functionp id-key) (funcall id-key row)
                                         (salta-aget id-key row)))))
    (salta-emit-table (buffer-point buffer) columns rows "")
    (when footer-fn (funcall footer-fn (buffer-end-point buffer)))
    (setf (buffer-value buffer :salta-ids) ids)
    (change-buffer-mode buffer 'salta-list-mode)
    (setf (buffer-value buffer :salta-refresh) refresh-fn)
    (move-to-line (buffer-point buffer) 3)
    (pop-to-buffer buffer)
    (redraw-display)))

(defun salta-insert-section (point title fields data)
  "Insert a key/value SECTION titled TITLE for DATA at POINT.
FIELDS is a list of (LABEL EXTRACTOR); EXTRACTOR is a key string or function."
  (insert-string point (format nil "~a~%~a~%" title
                               (make-string (length title) :initial-element #\-)))
  (loop :for (label extractor) :in fields
        :for value := (if (functionp extractor)
                          (funcall extractor data)
                          (salta-to-string (salta-aget extractor data)))
        :do (insert-string point (format nil "  ~22a ~a~%"
                                         (concatenate 'string label ":") value)))
  (insert-character point #\Newline))

(defun salta-insert-detail-table (point title columns rows)
  "Insert a labelled aligned table at POINT inside a detail buffer."
  (insert-string point (format nil "~a~%~a~%" title
                               (make-string (length title) :initial-element #\-)))
  (if (null rows)
      (insert-string point (format nil "  (none)~%~%"))
      (progn (salta-emit-table point columns rows "  ")
             (insert-character point #\Newline))))

(defun salta-show-detail (name fill-fn refresh-fn)
  "Create read-only detail BUFFER NAME, populate it via FILL-FN (called with a
point), and display it. Runs on the editor thread."
  (let ((buffer (make-buffer name)))
    (setf (buffer-read-only-p buffer) nil)
    (erase-buffer buffer)
    (funcall fill-fn (buffer-point buffer))
    (setf (buffer-read-only-p buffer) t)
    (setf (buffer-value buffer :salta-refresh) refresh-fn)
    (move-to-line (buffer-point buffer) 1)
    (pop-to-buffer buffer)
    (redraw-display)))

;;; --- async plumbing -------------------------------------------------------

(defun salta-credentials-ok-p ()
  "T if a URL and key resolve; otherwise message and return NIL."
  (cond ((not (executable-find "curl")) (message "curl not found") nil)
        ((null (salta-resolve-url))
         (message "Set *salta-base-url*, SALTA_SUPABASE_URL, or credentials file")
         nil)
        ((null (salta-resolve-key))
         (message "Set *salta-api-key*, SALTA_SUPABASE_KEY, or credentials file")
         nil)
        (t t)))

(defun salta-async (worker on-success)
  "Run WORKER (returning JSON) on a background thread; on success call
ON-SUCCESS with the result on the editor thread. Errors are reported."
  (when (salta-credentials-ok-p)
    (bt2:make-thread
     (lambda ()
       (handler-case
           (let ((result (funcall worker)))
             (send-event (lambda () (funcall on-success result))))
         (error (e)
           (let ((msg (princ-to-string e)))
             (send-event (lambda () (message "Salta: ~a" msg)))))))
     :name "vile/salta")))

;;; --- commands -------------------------------------------------------------

(define-command vile-salta-find-property () ()
  "Fuzzy-search properties via the fuzzy_search_properties RPC."
  (let ((query (prompt-for-string "Search properties: ")))
    (when (plusp (length (string-trim " " query)))
      (salta-async
       (lambda ()
         (salta-rpc "fuzzy_search_properties"
                    `(("query_text" . ,query)
                      ("result_limit" . ,*salta-search-limit*))))
       (lambda (results)
         (if (null results)
             (message "No properties found for ~s" query)
             (salta-show-list
              "*salta-properties*"
              `(("Code" 14 "application_code")
                ("Name" 22 "applicant_name")
                ("Address" 30 "address_line_1")
                ("Town" 16 "city_town")
                ("County" 12 "county")
                ("Eircode" 9 "eircode")
                ("Status" 12 "application_status")
                ("Sim" 5 ,(lambda (r)
                            (let ((s (salta-aget "similarity" r)))
                              (if (equal s "") "" (format nil "~,2f"
                                                          (salta-number s)))))))
              results "application_id"
              (lambda () (vile-salta-find-property)))))))))

(defun salta-property-detail-id (id)
  "Fetch and render full detail for application ID."
  (salta-async
   (lambda ()
     (let* ((app (first (salta-get "rpt_applications"
                                   `(("application_id" . ,(format nil "eq.~a" id))))))
            (measures (salta-get "rpt_application_measures"
                                 `(("application_id" . ,(format nil "eq.~a" id))
                                   ("order" . "measure_code"))))
            (claims (salta-get "rpt_claim_lines"
                               `(("application_id" . ,(format nil "eq.~a" id))
                                 ("order" . "measure_code"))))
            (payments (salta-get "rpt_payments"
                                 `(("application_id" . ,(format nil "eq.~a" id))
                                   ("order" . "created_at.desc")))))
       (unless app (error "Application ~a not found" id))
       (list app measures claims payments)))
   (lambda (bundle)
     (destructuring-bind (app measures claims payments) bundle
       (let ((code (salta-to-string (salta-aget "application_code" app))))
         (salta-show-detail
          (format nil "*salta: ~a*" code)
          (lambda (point)
            (salta-insert-section
             point "Property"
             `(("Code" "application_code") ("Name" "applicant_name")
               ("Email" "applicant_email")
               ("Address" ,(lambda (d)
                             (format nil "~{~a~^, ~}"
                                     (remove ""
                                             (mapcar (lambda (k)
                                                       (salta-to-string (salta-aget k d)))
                                                     '("address_line_1" "address_line_2"
                                                       "address_line_3" "address_line_4"))
                                             :test #'string=))))
               ("Town" "city_town") ("County" "county") ("Eircode" "eircode")
               ("MPRN" "mprn") ("Lot" "lot_number") ("Status" "application_status")
               ("Drawdown" "drawdown_code") ("Townlink Ref" "townlink_ref")
               ("Project Manager" "project_manager")
               ("Measures" "measure_count") ("Install End" "install_end_date"))
             app)
            (salta-insert-detail-table
             point "Measures"
             '(("Code" 10 "measure_code") ("Details" 30 "measure_details")
               ("Category" 16 "measure_category") ("Unit" 10 "measure_unit")
               ("Survey Qty" 12 "survey_quantity")
               ("Var Qty" 12 "variated_quantity")
               ("Inspect Qty" 12 "inspection_quantity"))
             measures)
            (salta-insert-detail-table
             point "Claim Lines"
             `(("Contractor" 16 "contractor_name") ("Measure" 10 "measure_code")
               ("Details" 24 "measure_details")
               ("Claimed" 10 "claimed_quantity") ("Approved" 10 "approved_quantity")
               ("Rate" 10 ,(lambda (r) (salta-money (salta-aget "rate_amount" r))))
               ("Value" 12 ,(lambda (r) (salta-money (salta-aget "committed_value" r))))
               ("Frozen" 7 ,(lambda (r) (if (eq (gethash "is_frozen" r) t) "Yes" ""))))
             claims)
            (salta-insert-detail-table
             point "Payments"
             `(("Contractor" 16 "contractor_name")
               ("%" 6 ,(lambda (r) (salta-pct (salta-aget "percentage" r))))
               ("Committed" 12 ,(lambda (r) (salta-money (salta-aget "total_committed_value" r))))
               ("Pay Amount" 12 ,(lambda (r) (salta-money (salta-aget "pay_amount" r))))
               ("Run" 14 "payment_run_label")
               ("Date" 12 ,(lambda (r) (salta-date (salta-aget "created_at" r)))))
             payments))
          (lambda () (salta-property-detail-id id))))))))

(define-command vile-salta-property-detail () ()
  "Show full detail for a property (prompts for the application id)."
  (let ((id (or (and (mode-active-p (current-buffer) 'salta-list-mode)
                     (salta-current-row-id))
                (prompt-for-string "Application ID: "))))
    (when (plusp (length id))
      (salta-property-detail-id id))))

(defun salta-property-reckoner-id (id)
  "Fetch get_reckoner_data for ID and render the revenue/cost/profit table."
  (salta-async
   (lambda ()
     (let* ((data (salta-rpc "get_reckoner_data" `(("p_application_id" . ,id))))
            (info (first (salta-get "rpt_applications"
                                    `(("application_id" . ,(format nil "eq.~a" id))
                                      ("select" . "application_code"))))))
       (list data (if info (salta-to-string (salta-aget "application_code" info)) id))))
   (lambda (bundle)
     (destructuring-bind (data code) bundle
       (if (null data)
           (message "No reckoner data for ~a" code)
           (let ((revenue 0d0) (cost 0d0) (profit 0d0))
             (dolist (row data)
               (incf revenue (salta-number (gethash "revenue" row)))
               (incf cost (salta-number (gethash "cost" row)))
               (incf profit (salta-number (gethash "profit" row))))
             (salta-show-list
              (format nil "*salta-reckoner: ~a*" code)
              `(("Code" 10 "measure_code") ("Description" 30 "measure_details")
                ("Qty" 8 "variated_quantity")
                ("SEAI Rate" 12 ,(lambda (r) (salta-money (salta-aget "seai_rate" r))))
                ("TCB Rate" 12 ,(lambda (r) (salta-money (salta-aget "tcb_rate" r))))
                ("Revenue" 12 ,(lambda (r) (salta-money (salta-aget "revenue" r))))
                ("Cost" 12 ,(lambda (r) (salta-money (salta-aget "cost" r))))
                ("Profit" 12 ,(lambda (r) (salta-money (salta-aget "profit" r)))))
              data "measure_code"
              (lambda () (salta-property-reckoner-id id))
              (lambda (point)
                (insert-string point (format nil "~%Totals~%------~%"))
                (insert-string point (format nil "  ~22a ~a~%" "Revenue:" (salta-money revenue)))
                (insert-string point (format nil "  ~22a ~a~%" "Cost:" (salta-money cost)))
                (insert-string point (format nil "  ~22a ~a~%" "Profit:" (salta-money profit)))
                (when (plusp revenue)
                  (insert-string point (format nil "  ~22a ~,1f%~%" "Margin:"
                                                (* 100d0 (/ profit revenue)))))))))))))

(define-command vile-salta-property-reckoner () ()
  "Show the reckoner (revenue/cost/profit) for a property."
  (let ((id (or (and (mode-active-p (current-buffer) 'salta-list-mode)
                     (salta-current-row-id))
                (prompt-for-string "Application ID: "))))
    (when (plusp (length id))
      (salta-property-reckoner-id id))))

;;; --- contractor selection -------------------------------------------------

(defvar *salta-contractor-cache* nil
  "Cached list of (display-label . contractor-id) for completion.")

(defun salta-read-contractor (prompt continuation)
  "Resolve a contractor via completion, then call CONTINUATION with (label . id).
Loads (and caches) the contractor list on a background thread when needed."
  (flet ((choose (cache)
           (let* ((labels (mapcar #'car cache))
                  (choice (prompt-for-string
                           prompt
                           :completion-function (lambda (s) (orderless-filter s labels))
                           :test-function (lambda (s) (member s labels :test #'string=))))
                  (entry (assoc choice cache :test #'string=)))
             (if entry (funcall continuation entry)
                 (message "No contractor selected")))))
    (if *salta-contractor-cache*
        (choose *salta-contractor-cache*)
        (salta-async
         (lambda ()
           (salta-get "contractors"
                      '(("is_active" . "eq.true")
                        ("select" . "contractor_id,contractor_name,contractor_code")
                        ("order" . "contractor_name"))))
         (lambda (rows)
           (setf *salta-contractor-cache*
                 (mapcar (lambda (c)
                           (let ((name (salta-to-string (salta-aget "contractor_name" c)))
                                 (acode (salta-to-string (salta-aget "contractor_code" c)))
                                 (id (salta-to-string (salta-aget "contractor_id" c))))
                             (cons (if (plusp (length acode))
                                       (format nil "~a (~a)" name acode) name)
                                   id)))
                         rows))
           (choose *salta-contractor-cache*))))))

(define-command vile-salta-contractor-rates () ()
  "Show the latest rate card for a contractor."
  (salta-read-contractor
   "Contractor: "
   (lambda (entry)
     (destructuring-bind (name . cid) entry
       (salta-async
        (lambda ()
          (let* ((card (first (salta-get "rate_cards"
                                         `(("contractor_id" . ,(format nil "eq.~a" cid))
                                           ("order" . "created_at.desc")
                                           ("limit" . "1"))))))
            (unless card (error "No rate card for ~a" name))
            (let ((card-id (salta-to-string (salta-aget "rate_card_id" card))))
              (list (salta-to-string (salta-aget "label" card))
                    (salta-get "rates"
                               `(("rate_card_id" . ,(format nil "eq.~a" card-id))
                                 ("order" . "measure_code")))))))
        (lambda (bundle)
          (destructuring-bind (label rates) bundle
            (salta-show-detail
             (format nil "*salta-rates: ~a*" name)
             (lambda (point)
               (insert-string point (format nil "Rate Card: ~a~%~%" label))
               (salta-insert-detail-table
                point "Rates"
                `(("Measure" 12 "measure_code")
                  ("Amount" 12 ,(lambda (r) (salta-money (salta-aget "rate_amount" r))))
                  ("Unit" 14 "rate_unit"))
                rates))
             (lambda () (vile-salta-contractor-rates))))))))))

(define-command vile-salta-contractor-financials () ()
  "Show the financial summary for a contractor."
  (salta-read-contractor
   "Contractor: "
   (lambda (entry)
     (destructuring-bind (name . cid) entry
       (salta-async
        (lambda ()
          (let ((fin (first (salta-get "rpt_contractor_financials"
                                       `(("contractor_id" . ,(format nil "eq.~a" cid)))))))
            (unless fin (error "No financial data for ~a" name))
            fin))
        (lambda (fin)
          (salta-show-detail
           (format nil "*salta-financials: ~a*" name)
           (lambda (point)
             (salta-insert-section
              point "Contractor Financials"
              `(("Name" "contractor_name") ("Code" "contractor_code")
                ("Active" ,(lambda (d) (if (eq (gethash "is_active" d) t) "Yes" "No")))
                ("Submissions" "submission_count")
                ("Claim Items" "claim_item_count")
                ("Applications" "application_count")
                ("Committed" ,(lambda (d) (salta-money (salta-aget "total_committed_value" d))))
                ("Paid" ,(lambda (d) (salta-money (salta-aget "total_paid_amount" d))))
                ("Outstanding" ,(lambda (d) (salta-money (salta-aget "outstanding_amount" d)))))
              fin))
           (lambda () (vile-salta-contractor-financials)))))))))

(defun salta-payments-show (params buffer-name refresh-fn)
  "Fetch rpt_payments with PARAMS and render the list in BUFFER-NAME."
  (salta-async
   (lambda () (salta-get "rpt_payments" params))
   (lambda (data)
     (if (null data)
         (message "No payments found")
         (salta-show-list
          buffer-name
          `(("Contractor" 18 "contractor_name") ("App Code" 14 "application_code")
            ("%" 6 ,(lambda (r) (salta-pct (salta-aget "percentage" r))))
            ("Committed" 12 ,(lambda (r) (salta-money (salta-aget "total_committed_value" r))))
            ("Pay Amt" 12 ,(lambda (r) (salta-money (salta-aget "pay_amount" r))))
            ("Run" 14 "payment_run_label")
            ("Date" 12 ,(lambda (r) (salta-date (salta-aget "created_at" r)))))
          data "pay_commit_id" refresh-fn)))))

(define-command vile-salta-payments () ()
  "Browse recent payment runs. With a contractor filter when chosen."
  (let ((params '(("order" . "created_at.desc") ("limit" . "100"))))
    (if (prompt-for-y-or-n-p "Filter by contractor?")
        (salta-read-contractor
         "Contractor: "
         (lambda (entry)
           (destructuring-bind (name . cid) entry
             (salta-payments-show
              (append params `(("contractor_id" . ,(format nil "eq.~a" cid))))
              (format nil "*salta-payments: ~a*" name)
              (lambda () (vile-salta-payments))))))
        (salta-payments-show params "*salta-payments*"
                             (lambda () (vile-salta-payments))))))

;;; --- bindings (global keymap, mirroring salta.el's C-c s prefix) ----------

(define-key *global-keymap* "C-c s s" 'vile-salta-find-property)
(define-key *global-keymap* "C-c s d" 'vile-salta-property-detail)
(define-key *global-keymap* "C-c s r" 'vile-salta-property-reckoner)
(define-key *global-keymap* "C-c s c" 'vile-salta-contractor-rates)
(define-key *global-keymap* "C-c s f" 'vile-salta-contractor-financials)
(define-key *global-keymap* "C-c s p" 'vile-salta-payments)
