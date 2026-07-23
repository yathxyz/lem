(in-package :lem-yath)

(setf *agenda-now-function*
      (lambda () (encode-universal-time 0 0 12 21 7 2026 0)))

(defun agenda-query-test-log (control &rest arguments)
  (with-open-file
      (stream (or (uiop:getenv "LEM_YATH_AGENDA_QUERY_REPORT")
                  (error "Agenda query report path is unset"))
              :direction :output :if-exists :append
              :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(define-command lem-yath-test-agenda-query-state () ()
  (let ((rows '())
        (state (agenda-view-state)))
    (with-point ((point (buffer-start-point (current-buffer))))
      (loop
        (when (agenda-source-row-p point)
          (push (line-string point) rows))
        (unless (line-offset point 1) (return))))
    (let ((query (agenda-view-state-query state)))
      (agenda-query-test-log
       "STATE command=~a query=~s rows=~d entries=~s"
       (agenda-view-state-command state)
       (typecase query
         (agenda-tags-query (agenda-tags-query-raw query))
         (agenda-search-query (agenda-search-query-raw query))
         (t nil))
       (length rows)
       (nreverse rows)))))

(define-key *lem-yath-agenda-mode-keymap* "C-c z q"
  'lem-yath-test-agenda-query-state)

(defun agenda-query-test-names (items)
  (mapcar
   (lambda (item)
     (multiple-value-bind (level title tags)
         (roam-org-heading-fields (agenda-item-heading item))
       (declare (ignore level tags))
       title))
   items))

(define-command lem-yath-test-agenda-query-edges () ()
  (let ((items (buffer-value (current-buffer) 'lem-yath-agenda-cached-items)))
    (dolist (spec '(;; Expected names were pinned with Org 9.8.5.
                    (:tags "parent|blue-parent")
                    (:tags "{^bl}")
                    (:tags "OWNER={Ada.*}")
                    (:tags "MISSING=0")
                    (:tags "MISSING=*0")
                    (:tags "LEVEL>=2")
                    (:tags "TODO=\"DONE\"")
                    (:tags "blue/-DONE")
                    (:tags "blue/TODO|DONE")
                    (:search ":+uni")
                    (:search ":+unique")
                    (:search "+{uni..e} -ordinary")
                    (:search "+\"unique beta\"")
                    (:search "!completed body")
                    (:search "UNIQUE BETA")))
      (let* ((kind (first spec))
             (raw (second spec))
             (query
               (if (eq kind :tags)
                   (agenda-compile-tags-query raw)
                   (agenda-compile-search-query raw)))
             (matches (agenda-query-matching-items items query)))
        (agenda-query-test-log
         "EDGE kind=~a query=~s rows=~d names=~s"
         kind raw (length matches) (agenda-query-test-names matches))))))

(define-key *lem-yath-agenda-mode-keymap* "C-c z e"
  'lem-yath-test-agenda-query-edges)
