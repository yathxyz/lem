(in-package :lem-yath)

(setf *agenda-now-function*
      (lambda () (encode-universal-time 0 0 12 17 7 2026 0)))

(defun agenda-filter-test-report-path ()
  (or (uiop:getenv "LEM_YATH_AGENDA_FILTER_REPORT")
      (error "LEM_YATH_AGENDA_FILTER_REPORT is unset")))

(defun agenda-filter-test-log (format-control &rest arguments)
  (with-open-file (stream (agenda-filter-test-report-path)
                          :direction :output
                          :if-does-not-exist :create
                          :if-exists :append)
    (apply #'format stream format-control arguments)
    (terpri stream)
    (finish-output stream)))

(defun agenda-filter-test-log-source-metadata ()
  (let ((source (merge-pathnames "filter.org" (uiop:ensure-directory-pathname
                                                 (uiop:getenv "WORKDIR")))))
    (with-open-file (stream source :direction :input :external-format :utf-8)
      (let* ((lines (loop :for line := (read-line stream nil nil)
                          :while line :collect line))
             (table (agenda-build-filter-metadata lines source)))
        (dolist (line '(3 8 13 18 19))
          (let ((metadata (gethash line table)))
            (agenda-filter-test-log
             "SOURCE line=~d cat=~s tags=~s effort=~s top=~s"
             line
             (agenda-item-metadata-category metadata)
             (agenda-item-metadata-tags metadata)
             (agenda-item-metadata-effort metadata)
             (agenda-item-metadata-top-headline metadata))))))))

(agenda-filter-test-log-source-metadata)

(agenda-filter-test-log
 "DURATION units=~f mixed=~f"
 (agenda-filter-duration-minutes "1h 30min")
 (agenda-filter-duration-minutes "1h 0:30"))

(multiple-value-bind (categories tags efforts regexps ignored)
    (agenda-filter-general-parse "+Shared" '("Shared") '("Shared") nil)
  (agenda-filter-test-log
   "GENERAL-PARSE categories=~d tags=~d efforts=~d regexps=~d ignored=~d"
   (length categories) (length tags) (length efforts) (length regexps)
   (length ignored)))

(defun agenda-filter-test-command-name (keys)
  (let ((command (find-keybind (lem-core::parse-keyspec keys))))
    (if (symbolp command) (symbol-name command) (princ-to-string command))))

(defun agenda-filter-test-entry-lines ()
  (let ((lines '()))
    (with-point ((point (buffer-start-point (current-buffer))))
      (loop
        (when (text-property-at point :agenda-file)
          (push (line-string point) lines))
        (unless (line-offset point 1) (return))))
    (nreverse lines)))

(defun agenda-filter-test-log-state (label)
  (let ((lines (agenda-filter-test-entry-lines))
        (point (current-point)))
    (agenda-filter-test-log
     "STATE ~a rows=~d header=~s point=~s cat=~s tags=~s effort=~s top=~s entries=~s"
     label
     (length lines)
     (line-string (buffer-start-point (current-buffer)))
     (line-string point)
     (text-property-at point :agenda-category)
     (text-property-at point :agenda-tags)
     (text-property-at point :agenda-effort)
     (text-property-at point :agenda-top-headline)
     lines)))

(defun agenda-filter-test-goto (text)
  (with-point ((point (buffer-start-point (current-buffer))))
    (loop
      (when (search text (line-string point))
        (move-point (current-point) point)
        (return-from agenda-filter-test-goto))
      (unless (line-offset point 1)
        (error "Agenda filter test row is missing: ~a" text)))))

(defmacro define-agenda-filter-test-goto (name text)
  `(define-command ,name () () (agenda-filter-test-goto ,text)))

(define-agenda-filter-test-goto lem-yath-test-filter-alpha-child
  "Alpha child filter sentinel")
(define-agenda-filter-test-goto lem-yath-test-filter-beta-child
  "Beta child filter sentinel")
(define-agenda-filter-test-goto lem-yath-test-filter-file
  "File fallback filter sentinel")

(defmacro define-agenda-filter-test-log-command (name label)
  `(define-command ,name () () (agenda-filter-test-log-state ,label)))

(define-agenda-filter-test-log-command lem-yath-test-filter-log-initial
  "initial")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-category
  "category")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-category-clear
  "category-clear")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-category-negative
  "category-negative")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-top
  "top")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-top-refresh
  "top-refresh")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-tag
  "tag")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-tag-stack
  "tag-stack")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-regexp
  "regexp")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-regexp-clear
  "regexp-clear")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-effort
  "effort")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-effort-clear
  "effort-clear")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-limit
  "limit")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-limit-refresh
  "limit-refresh")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-base-category
  "base-category")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-base-clear
  "base-clear")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-general
  "general")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-general-negated
  "general-negated")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-general-stack
  "general-stack")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-general-shortcut
  "general-shortcut")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-general-category
  "general-category")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-general-category-or
  "general-category-or")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-general-ignored
  "general-ignored")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-general-invalid
  "general-invalid")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-general-refresh
  "general-refresh")
(define-agenda-filter-test-log-command lem-yath-test-filter-log-general-autoexclude
  "general-autoexclude")

(define-command lem-yath-test-filter-log-normal-keys () ()
  (agenda-filter-test-log
   "KEYS normal sc=~a sr=~a se=~a st=~a s^=~a ss=~a S=~a slash=~a"
   (agenda-filter-test-command-name "s c")
   (agenda-filter-test-command-name "s r")
   (agenda-filter-test-command-name "s e")
   (agenda-filter-test-command-name "s t")
   (agenda-filter-test-command-name "s ^")
   (agenda-filter-test-command-name "s s")
   (agenda-filter-test-command-name "S")
   (agenda-filter-test-command-name "/")))

(define-command lem-yath-test-filter-log-base-keys () ()
  (agenda-filter-test-log
   "KEYS emacs backslash=~a underscore=~a equals=~a slash=~a bar=~a tilde=~a less=~a caret=~a"
   (agenda-filter-test-command-name "\\")
   (agenda-filter-test-command-name "_")
   (agenda-filter-test-command-name "=")
   (agenda-filter-test-command-name "/")
   (agenda-filter-test-command-name "|")
   (agenda-filter-test-command-name "~")
   (agenda-filter-test-command-name "<")
   (agenda-filter-test-command-name "^"))
  (handler-case
      (agenda-filter-test-log
       "GENERAL-COMPLETIONS plus=~s root=~s effort=~s quoted-exact=~s"
       (agenda-filter-general-completions (current-buffer) "+")
       (agenda-filter-general-completions (current-buffer) "+Roo")
       (agenda-filter-general-completions (current-buffer) "<1")
       (agenda-filter-general-completions
        (current-buffer) "+\"File-Cat\""))
    (error (condition)
      (agenda-filter-test-log "GENERAL-COMPLETIONS error=~s" condition))))

(let ((keymap *lem-yath-agenda-mode-keymap*))
  (define-key keymap "C-c z a" 'lem-yath-test-filter-alpha-child)
  (define-key keymap "C-c z b" 'lem-yath-test-filter-beta-child)
  (define-key keymap "C-c z f" 'lem-yath-test-filter-file)
  (define-key keymap "C-c z 0" 'lem-yath-test-filter-log-initial)
  (define-key keymap "C-c z 1" 'lem-yath-test-filter-log-category)
  (define-key keymap "C-c z 2" 'lem-yath-test-filter-log-category-clear)
  (define-key keymap "C-c z 3" 'lem-yath-test-filter-log-category-negative)
  (define-key keymap "C-c z 4" 'lem-yath-test-filter-log-top)
  (define-key keymap "C-c z 5" 'lem-yath-test-filter-log-top-refresh)
  (define-key keymap "C-c z 6" 'lem-yath-test-filter-log-tag)
  (define-key keymap "C-c z 7" 'lem-yath-test-filter-log-tag-stack)
  (define-key keymap "C-c z 8" 'lem-yath-test-filter-log-regexp)
  (define-key keymap "C-c z 9" 'lem-yath-test-filter-log-regexp-clear)
  (define-key keymap "C-c z e" 'lem-yath-test-filter-log-effort)
  (define-key keymap "C-c z E" 'lem-yath-test-filter-log-effort-clear)
  (define-key keymap "C-c z l" 'lem-yath-test-filter-log-limit)
  (define-key keymap "C-c z L" 'lem-yath-test-filter-log-limit-refresh)
  (define-key keymap "C-c z c" 'lem-yath-test-filter-log-base-category)
  (define-key keymap "C-c z C" 'lem-yath-test-filter-log-base-clear)
  (define-key keymap "C-c z n" 'lem-yath-test-filter-log-normal-keys)
  (define-key keymap "C-c z m" 'lem-yath-test-filter-log-base-keys)
  (define-key keymap "C-c z g" 'lem-yath-test-filter-log-general)
  (define-key keymap "C-c z h" 'lem-yath-test-filter-log-general-negated)
  (define-key keymap "C-c z i" 'lem-yath-test-filter-log-general-stack)
  (define-key keymap "C-c z j" 'lem-yath-test-filter-log-general-shortcut)
  (define-key keymap "C-c z k" 'lem-yath-test-filter-log-general-category)
  (define-key keymap "C-c z o" 'lem-yath-test-filter-log-general-category-or)
  (define-key keymap "C-c z p" 'lem-yath-test-filter-log-general-ignored)
  (define-key keymap "C-c z q" 'lem-yath-test-filter-log-general-invalid)
  (define-key keymap "C-c z r" 'lem-yath-test-filter-log-general-refresh)
  (define-key keymap "C-c z s" 'lem-yath-test-filter-log-general-autoexclude))
