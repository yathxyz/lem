(in-package :lem-yath)

(defun org-test-report-path ()
  (or (uiop:getenv "LEM_YATH_ORG_REPORT")
      (error "LEM_YATH_ORG_REPORT is unset")))

(defun org-test-log (format-control &rest arguments)
  (with-open-file (stream (org-test-report-path)
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :append)
    (apply #'format stream format-control arguments)
    (terpri stream)
    (finish-output stream)))

(defun org-test-find (text &key line-start-p)
  (let ((point (current-point)))
    (buffer-start point)
    (unless (search-forward-regexp point (cl-ppcre:quote-meta-chars text))
      (error "Org test text not found: ~s" text))
    (when line-start-p
      (line-start point))
    point))

(defun org-test-attribute-name (text)
  (with-point ((point (org-test-find text)))
    (character-offset point (- (length text)))
    (let ((attribute (text-property-at point :attribute)))
      (cond ((symbolp attribute) (symbol-name attribute))
            (attribute (princ-to-string attribute))
            (t "NONE")))))

(defun org-test-binding (keys)
  (let ((command (find-keybind (lem-core::parse-keyspec keys))))
    (if (symbolp command) (symbol-name command) (princ-to-string command))))

(define-command lem-yath-test-org-static-report () ()
  (lem-core::syntax-scan-buffer (current-buffer))
  (org-test-log
   "STATIC mode=~a programming=~a heading=~a todo=~a drawer=~a timestamp=~a table=~a link=~a source=~a"
   (symbol-name (buffer-major-mode (current-buffer)))
   (if (programming-buffer-p (current-buffer)) "yes" "no")
   (org-test-attribute-name "Parent")
   (org-test-attribute-name "TODO")
   (org-test-attribute-name ":PROPERTIES:")
   (org-test-attribute-name "2026-07-12")
   (org-test-attribute-name "alpha")
   (org-test-attribute-name "target.org")
   (org-test-attribute-name "print('hello')"))
  (let ((tab (org-test-binding "Tab"))
        (zero (org-test-binding "0"))
        (end (org-test-binding "$"))
        (insert-line (org-test-binding "I"))
        (append-line (org-test-binding "A"))
        (little-t (org-test-binding "t"))
        (big-t (org-test-binding "T"))
        (return (org-test-binding "Return"))
        (control-return (org-test-binding "C-Return"))
        (control-shift-return (org-test-binding "C-Shift-Return"))
        (meta-o (org-test-binding "M-o")))
    (org-test-log
     (concatenate
      'string
      "KEYS tab-org=~a zero-org=~a end-org=~a I-org=~a A-org=~a "
      "t-todo=~a T-todo=~a return-org=~a "
      "c-return-org=~a cs-return-org=~a m-o-other=~a")
     (if (member tab '("LEM-YATH-ORG-CYCLE" "LEM-YATH-SNIPPET-TAB")
                 :test #'string=)
         "yes" "no")
     (if (string= zero "LEM-YATH-ZERO") "yes" "no")
     (if (string= end "LEM-YATH-END-OF-LINE") "yes" "no")
     (if (string= insert-line "LEM-YATH-ORG-INSERT-LINE") "yes" "no")
     (if (string= append-line "LEM-YATH-APPEND-LINE") "yes" "no")
     (if (string= little-t "LEM-YATH-ORG-TODO") "yes" "no")
     (if (string= big-t "LEM-YATH-ORG-TODO") "yes" "no")
     (if (member return '("LEM-YATH-ORG-CYCLE" "LEM-YATH-ORG-META-RETURN")
                 :test #'string=)
         "yes" "no")
     (if (string= control-return "LEM-YATH-ORG-INSERT-HEADING")
         "yes" "no")
     (if (string= control-shift-return "LEM-YATH-ORG-INSERT-TODO-HEADING")
         "yes" "no")
     (if (member meta-o '("OTHER-WINDOW" "NEXT-WINDOW") :test #'string=)
         "yes" "no"))))

(define-command lem-yath-test-org-point-report () ()
  (org-test-log "POINT line=~d column=~d text=~s hidden=~a modified=~a folds=~d"
                (line-number-at-point (current-point))
                (point-charpos (current-point))
                (line-string (current-point))
                (if (org-line-hidden-p (current-point)) "yes" "no")
                (if (buffer-modified-p (current-buffer)) "yes" "no")
                (length (org-buffer-folds (current-buffer)))))

(defun org-test-location-copy (text)
  (with-point ((point (buffer-start-point (current-buffer))))
    (when (search-forward-regexp point (cl-ppcre:quote-meta-chars text))
      (line-start point)
      (copy-point point :temporary))))

(defun org-test-location-line (point)
  (if point (line-number-at-point point) 0))

(defun org-test-location-indent (point)
  (if point (org-line-indentation point) -1))

(defun org-test-location-heading-level (point)
  (if point (or (org-heading-level-at point) 0) 0))

(defun org-test-location-text (point)
  (if point (line-string point) "MISSING"))

(define-command lem-yath-test-org-context-report () ()
  "Report exact structural state without moving the real point."
  (let* ((text (points-to-string (buffer-start-point (current-buffer))
                                 (buffer-end-point (current-buffer))))
         (point-text (line-string (current-point)))
         (point-column (point-charpos (current-point)))
         (parent (org-test-location-copy "TODO Parent"))
         (child (org-test-location-copy "NEXT Child"))
         (grand (org-test-location-copy "Grandchild"))
         (sibling (org-test-location-copy "* Sibling"))
         (prose-one (org-test-location-copy "Parent body sentinel"))
         (prose-two (org-test-location-copy "Parent second prose line"))
         (first (org-test-location-copy "- [ ] first"))
         (first-child (org-test-location-copy "nested child sentinel"))
         (second (org-test-location-copy "- [X] second"))
         (second-child (org-test-location-copy "second nested sentinel"))
         (header (org-test-location-copy "| name"))
         (alpha (org-test-location-copy "alpha"))
         (omega (org-test-location-copy "omega"))
         (table-rows
           (if header
               (multiple-value-bind (start end) (org-table-bounds header)
                 (length (org-table-row-lines start end)))
               0))
         (table-columns
           (if header (length (org-table-cells (line-string header))) 0)))
    (org-test-log
     (concatenate
      'string
      "CONTEXT hash=~x levels=~d,~d,~d headings=~d,~d,~d,~d prose=~d,~d "
      "lists=~d/~d,~d/~d,~d/~d,~d/~d table=~d/~d "
      "header=~s alpha=~s/~d omega=~s/~d point=~s/~d modified=~a")
     (sxhash text)
     (org-test-location-heading-level parent)
     (org-test-location-heading-level child)
     (org-test-location-heading-level grand)
     (org-test-location-line parent)
     (org-test-location-line child)
     (org-test-location-line grand)
     (org-test-location-line sibling)
     (org-test-location-line prose-one)
     (org-test-location-line prose-two)
     (org-test-location-line first)
     (org-test-location-indent first)
     (org-test-location-line first-child)
     (org-test-location-indent first-child)
     (org-test-location-line second)
     (org-test-location-indent second)
     (org-test-location-line second-child)
     (org-test-location-indent second-child)
     table-rows table-columns
     (org-test-location-text header)
     (org-test-location-text alpha) (org-test-location-line alpha)
     (org-test-location-text omega) (org-test-location-line omega)
     point-text point-column
     (if (buffer-modified-p (current-buffer)) "yes" "no"))))

(defun org-test-table-snapshot (needle)
  (alexandria:when-let ((point (org-test-location-copy needle)))
    (multiple-value-bind (start end) (org-table-bounds point)
      (values (org-table-row-lines start end)
              (mapcar #'line-string (org-table-formula-points point))))))

(defun org-test-first-following-formula (needle)
  (alexandria:when-let ((point (org-test-location-copy needle)))
    (multiple-value-bind (start end) (org-table-bounds point)
      (declare (ignore start))
      (with-point ((line end))
        (loop :while (line-offset line 1)
              :for text := (line-string line)
              :unless (cl-ppcre:scan "^\\s*$" text)
                :do (return
                      (and (cl-ppcre:scan "(?i)^\\s*#\\+TBLFM:" text)
                           text)))))))

(define-command lem-yath-test-org-formula-report () ()
  "Report immediate and blank-separated formula-table state exactly."
  (multiple-value-bind (rows formulas)
      (org-test-table-snapshot "| formula")
    (multiple-value-bind (spaced-rows spaced-formulas)
        (org-test-table-snapshot "| spaced formula")
      (let ((spaced-raw
              (org-test-first-following-formula "| spaced formula")))
        (org-test-log
         (concatenate
          'string
          "FORMULA rows=~s formulas=~s spaced=~s spaced-formulas=~s "
          "spaced-raw=~s")
         rows formulas spaced-rows spaced-formulas
         (or spaced-raw "MISSING"))))))

(defmacro define-org-test-goto-command (name text &optional line-start-p)
  `(define-command ,name () ()
     (move-point (current-point)
                 (org-test-find ,text :line-start-p ,line-start-p))))

(define-org-test-goto-command lem-yath-test-org-goto-parent "* TODO Parent" t)
(define-org-test-goto-command lem-yath-test-org-goto-parent-body
  "Parent body sentinel" t)
(define-org-test-goto-command lem-yath-test-org-goto-indented-prose
  "indented prose sentinel" t)
(define-org-test-goto-command lem-yath-test-org-goto-grand-body
  "Grand body sentinel" t)
(define-org-test-goto-command lem-yath-test-org-goto-list "- [ ] first" t)
(define-org-test-goto-command lem-yath-test-org-goto-second-list "- [X] second" t)
(define-org-test-goto-command lem-yath-test-org-goto-table "alpha" t)
(define-org-test-goto-command lem-yath-test-org-goto-table-hline-second
  "+-------" nil)
(define-org-test-goto-command lem-yath-test-org-goto-indented-table
  "| nested" nil)
(define-org-test-goto-command lem-yath-test-org-goto-hline-only
  "|---+-----|" t)
(define-org-test-goto-command lem-yath-test-org-goto-link "target.org" nil)
(define-org-test-goto-command lem-yath-test-org-goto-sibling "* Sibling" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-child-b
  "- child-b" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-star-child
  "* star child" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-tab-child
  "- tab child" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-wide-child
  "- wide child" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-body-item
  "- body item" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-ordered
  "1. ordered one" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-separate
  "- separate a" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-source-list
  "- source list lookalike" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-source-indented-list
  "- indented source list lookalike" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-source-table
  "| source | table |" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-mismatched-list
  "- mismatched source list" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-mismatched-table
  "| mismatched | source |" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-source-owner
  "Source owner" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-source-fake-heading
  "* source fake heading" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-source-real-child
  "Source real child" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-source-fake-after-begin
  "* source fake after unmatched begin" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-real-after-literal-begin
  "Real after literal begin" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-formula
  "| formula | middle | result |" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-formula-first
  "| 1       | 2" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-formula-second
  "| 4       | 5" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-formula-middle
  "middle" nil)
(define-org-test-goto-command lem-yath-test-org-goto-edge-range-column
  "range result" nil)
(define-org-test-goto-command lem-yath-test-org-goto-edge-range-row
  "range row second" nil)
(define-org-test-goto-command lem-yath-test-org-goto-edge-spaced-formula
  "| spaced formula | result |" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-sparse-data
  "| -     |" nil)
(define-org-test-goto-command lem-yath-test-org-goto-edge-clock "CLOCK:" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-one-column
  "| only |" t)
(define-org-test-goto-command lem-yath-test-org-goto-edge-one-row
  "| disposable |" t)

(define-command lem-yath-test-org-open-edge () ()
  (find-file (merge-pathnames "edge.org" (workdir))))

(defun org-test-hook-count (function hooks)
  (count function hooks :key #'car :test #'eq))

(define-command lem-yath-test-org-reload-report () ()
  (handler-case
      (let ((source (asdf:system-source-directory "lem-yath")))
        (dotimes (_ 2)
          (declare (ignore _))
          (dolist (relative '("src/org/parser.lisp"
                              "src/org/folding.lisp"
                              "src/org/mode.lisp"
                              "src/org/commands.lisp"
                              "src/org/structure.lisp"
                              "src/org/text-objects.lisp"))
            (load (merge-pathnames relative source))))
        (org-test-log
         (concatenate
          'string
          "RELOAD post=~d change=~d kill=~d association=~d folds=~d "
          "tab=~a")
         (org-test-hook-count 'org-reveal-point-after-command
                              *post-command-hook*)
         (org-test-hook-count
          'org-clear-folds-after-change
          (variable-value 'after-change-functions
                          :buffer (current-buffer)))
         (org-test-hook-count
          'org-mode-kill-buffer-cleanup
          (variable-value 'kill-buffer-hook :buffer (current-buffer)))
         (count '("org" . org-mode)
                lem-core::*file-type-relationals*
                :test #'equal)
         (length (org-buffer-folds (current-buffer)))
         (if (member (org-test-binding "Tab")
                     '("LEM-YATH-ORG-CYCLE" "LEM-YATH-SNIPPET-TAB")
                     :test #'string=)
             "yes" "no")))
    (error (condition)
      (org-test-log "RELOAD error=~a" condition))))

(define-command lem-yath-test-org-eof-heading-report () ()
  (let* ((fixture (current-buffer))
         (path (merge-pathnames "eof.org" (workdir))))
    (find-file path)
    (buffer-start (current-point))
    (org-insert-heading-after-subtree)
    (insert-string (current-point) "After")
    (let ((contents (points-to-string (buffer-start-point (current-buffer))
                                      (buffer-end-point (current-buffer)))))
      (org-test-log "EOF text=~s"
                    (substitute #\| #\Newline contents)))
    (save-buffer (current-buffer))
    (kill-buffer (current-buffer))
    (switch-to-buffer fixture)))

(define-command lem-yath-test-org-kill-cleanup-report () ()
  (let* ((victim (current-buffer))
         (other-path (merge-pathnames "other.org" (workdir))))
    (find-file other-path)
    (let ((survivor (current-buffer)))
      (buffer-start (current-point))
      (org-fold-subtree (current-point))
      (kill-buffer victim)
      (org-test-log
       "KILL current=~a survivor-folds=~d victim-live=~a"
       (if (eq (current-buffer) survivor) "yes" "no")
       (length (org-buffer-folds survivor))
       (if (member victim (buffer-list)) "yes" "no")))))

(define-command lem-yath-test-org-return-fixture () ()
  (find-file (merge-pathnames "fixture.org" (workdir))))
