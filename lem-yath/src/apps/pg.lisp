;;;; lem-yath apps/pg -- pgmacs -> a psql-backed lite PostgreSQL client.
;;;;
;;;; pgmacs was declared in the Emacs config with NO custom config and NO
;;;; keybindings (M-x entry only), so this port adds no keybindings either.
;;;; Queries run through the psql CLI in CSV mode; results are rendered as an
;;;; aligned, read-only table. Connection info is session-only and defaults to
;;;; relying on the standard PG* environment variables.

(in-package :lem-yath)

(defvar *pg-conninfo* ""
  "psql connection string (e.g. \"postgresql://user@host/db\").
Empty means rely on the standard PG* environment variables.")

(defvar *pg-buffer-name* "*lem-yath-pg*")

(defvar *pg-last-query* nil
  "The last SQL string run, so the result buffer's \"g\" can re-run it.")

;;; --- CSV parsing -----------------------------------------------------------

(defun pg-parse-csv (text)
  "Parse RFC-4180-style CSV TEXT into a list of rows (each a list of strings).
Handles quoted fields containing commas, newlines and escaped (doubled)
quotes. A trailing newline does not produce a spurious empty row."
  (let ((rows '())
        (row '())
        (field (make-string-output-stream))
        (in-quotes nil)
        (field-started nil)
        (len (length text))
        (i 0))
    (labels ((end-field ()
               (push (get-output-stream-string field) row)
               (setf field-started nil))
             (end-row ()
               (end-field)
               (push (nreverse row) rows)
               (setf row '())))
      (loop :while (< i len)
            :for ch := (char text i)
            :do (cond
                  (in-quotes
                   (cond
                     ((char= ch #\")
                      (if (and (< (1+ i) len) (char= (char text (1+ i)) #\"))
                          (progn (write-char #\" field) (incf i))
                          (setf in-quotes nil)))
                     (t (write-char ch field))))
                  ((char= ch #\")
                   (setf in-quotes t field-started t))
                  ((char= ch #\,)
                   (end-field) (setf field-started t))
                  ((char= ch #\Newline)
                   (end-row))
                  ((char= ch #\Return)
                   nil) ; tolerate CRLF: drop bare CR
                  (t (write-char ch field) (setf field-started t)))
                (incf i))
      ;; Flush a final field/row unless the text ended exactly on a newline
      ;; with nothing buffered.
      (when (or field-started row in-quotes)
        (end-row)))
    (nreverse rows)))

;;; --- table rendering -------------------------------------------------------

(defun pg-column-widths (rows)
  "Compute the display width of each column across ROWS."
  (let ((widths '()))
    (dolist (row rows)
      (loop :for cell :in row
            :for idx :from 0
            :for w := (length cell)
            :do (if (< idx (length widths))
                    (setf (nth idx widths) (max (nth idx widths) w))
                    (setf widths (append widths (list w))))))
    widths))

(defun pg-pad (string width)
  (let ((s (or string "")))
    (concatenate 'string s
                 (make-string (max 0 (- width (length s)))
                              :initial-element #\Space))))

(defun pg-render-table (rows)
  "Render ROWS (header first) as an aligned table string.
Returns NIL when ROWS is empty."
  (when rows
    (let* ((widths (pg-column-widths rows))
           (header (first rows))
           (body (rest rows)))
      (with-output-to-string (s)
        ;; header
        (loop :for cell :in header
              :for idx :from 0
              :for first := t :then nil
              :do (unless first (write-string " | " s))
                  (write-string (pg-pad cell (nth idx widths)) s))
        (write-char #\Newline s)
        ;; separator
        (loop :for w :in widths
              :for first := t :then nil
              :do (unless first (write-string "-+-" s))
                  (write-string (make-string w :initial-element #\-) s))
        (write-char #\Newline s)
        ;; body
        (dolist (row body)
          (loop :for idx :from 0 :below (length widths)
                :for first := t :then nil
                :do (unless first (write-string " | " s))
                    (write-string (pg-pad (nth idx row) (nth idx widths)) s))
          (write-char #\Newline s))))))

;;; --- result buffer + mode --------------------------------------------------

(define-major-mode lem-yath-pg-mode ()
    (:name "lem-yath-pg"
     :keymap *lem-yath-pg-mode-keymap*
     :description "Read-only view of psql query results.
\"q\" quits the window, \"g\" re-runs the last query.")
  (setf (buffer-read-only-p (current-buffer)) t))

(defun pg-show (content)
  "Display CONTENT in the read-only result buffer under lem-yath-pg-mode."
  (let ((buffer (make-buffer *pg-buffer-name*)))
    (change-buffer-mode buffer 'lem-yath-pg-mode)
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (insert-string (buffer-end-point buffer) content))
    (move-point (buffer-point buffer) (buffer-start-point buffer))
    (pop-to-buffer buffer)
    buffer))

;;; --- psql invocation -------------------------------------------------------

(defun pg-psql-command (sql)
  "Build the psql argv list for SQL, inserting the conninfo only when set."
  (append (list "psql")
          (when (plusp (length *pg-conninfo*)) (list *pg-conninfo*))
          (list "-X" "--csv" "-v" "ON_ERROR_STOP=1" "-c" sql)))

(defun pg-run (sql)
  "Run SQL via psql; on success render the CSV table, else report stderr.
Degrades gracefully when psql is missing. SQL is remembered for re-runs."
  (unless (executable-find "psql")
    (message "psql not found on PATH")
    (return-from pg-run))
  (setf *pg-last-query* sql)
  (handler-case
      (multiple-value-bind (output error-output status)
          (uiop:run-program (pg-psql-command sql)
                            :output :string
                            :error-output :string
                            :ignore-error-status t)
        (if (and (integerp status) (zerop status))
            (let* ((rows (pg-parse-csv output))
                   (table (pg-render-table rows)))
              (pg-show (or table
                           (format nil "(no rows)~%"))))
            (let ((msg (string-trim '(#\Newline #\Space #\Return)
                                    (or error-output ""))))
              (if (plusp (length msg))
                  (progn
                    (pg-show (format nil "psql error (exit ~a):~%~%~a~%"
                                     status msg))
                    (message "psql failed: ~a"
                             (first (uiop:split-string msg
                                                       :separator (string #\Newline)))))
                  (message "psql failed (exit ~a)" status)))))
    (error (e)
      (message "psql invocation failed: ~a" e))))

;;; --- commands --------------------------------------------------------------

(define-command lem-yath-pg-set-connection () ()
  "Set the psql connection string for this session (pgmacs connect).
Empty input clears it, falling back to the PG* environment variables."
  (let ((conninfo (prompt-for-string "Conninfo (postgresql://user@host/db): "
                                     :initial-value *pg-conninfo*
                                     :history-symbol 'lem-yath-pg-conninfo)))
    (setf *pg-conninfo* (or conninfo ""))
    (if (plusp (length *pg-conninfo*))
        (message "psql connection set")
        (message "psql connection cleared (using PG* environment)"))))

(define-command lem-yath-pg-query () ()
  "Prompt for SQL and show the result as an aligned table (pgmacs query)."
  (let ((sql (prompt-for-string "SQL: " :history-symbol 'lem-yath-pg)))
    (when (plusp (length (string-trim '(#\Space #\Tab #\Newline) (or sql ""))))
      (pg-run sql))))

(define-command lem-yath-pg-tables () ()
  "List the tables in the connected database (pgmacs table list).
Queries information_schema for a stable, CSV-friendly result."
  (pg-run
   (concatenate 'string
                "SELECT table_schema, table_name, table_type "
                "FROM information_schema.tables "
                "WHERE table_schema NOT IN ('pg_catalog', 'information_schema') "
                "ORDER BY table_schema, table_name")))

(define-command lem-yath-pg-refresh () ()
  "Re-run the last query (bound to \"g\" in the result buffer)."
  (if *pg-last-query*
      (pg-run *pg-last-query*)
      (message "No previous pg query")))

;;; --- result-buffer keys (no global/leader bindings; pgmacs had none) -------

(define-key *lem-yath-pg-mode-keymap* "q" 'quit-active-window)
(define-key *lem-yath-pg-mode-keymap* "g" 'lem-yath-pg-refresh)
