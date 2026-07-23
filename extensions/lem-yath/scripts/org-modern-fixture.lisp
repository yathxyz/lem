(in-package :lem-yath)

(defvar *org-modern-test-report*
  (or (uiop:getenv "LEM_YATH_ORG_MODERN_REPORT")
      (error "LEM_YATH_ORG_MODERN_REPORT is unset")))
(defvar *org-modern-test-source*
  (or (uiop:getenv "LEM_YATH_ORG_MODERN_SOURCE")
      (merge-pathnames "src/org/modern.lisp"
                       (asdf:system-source-directory "lem-yath"))))
(defvar *org-modern-test-transformer-source*
  (merge-pathnames "src/indent-guides.lisp"
                   (asdf:system-source-directory "lem-yath")))
(defvar *org-modern-test-original* nil)

(defun org-modern-test-log (control &rest arguments)
  (with-open-file (stream *org-modern-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defun org-modern-test-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across string
          :do (if (char= character #\Space)
                  (write-char #\. stream)
                  (write-char character stream)))))

(defun org-modern-test-find-line (needle)
  (with-point ((point (buffer-start-point (current-buffer))))
    (unless (search-forward-regexp point (cl-ppcre:quote-meta-chars needle))
      (error "Org modern test line not found: ~s" needle))
    (line-start point)
    (copy-point point :temporary)))

(defun org-modern-test-logical-line (point &optional overlays)
  (let* ((buffer (point-buffer point))
         (active-modes (lem-core::get-active-modes-class-instance buffer))
         (lem-core::*active-modes* active-modes))
    (lem-core::create-logical-line point overlays active-modes
                                   (current-window))))

(defun org-modern-test-reverse-at-p (logical-line index)
  (loop :for (start end attribute)
          :in (lem-core::logical-line-attributes logical-line)
        :thereis (and (<= start index) (< index end)
                      (let ((resolved
                              (lem-core:ensure-attribute attribute nil)))
                        (and resolved
                             (lem-core::attribute-reverse resolved))))))

(defun org-modern-test-record-line (label needle &optional reverse-needle)
  (with-point ((point (org-modern-test-find-line needle)))
    (let* ((source (line-string point))
           (logical-line (org-modern-test-logical-line point))
           (display (lem-core::logical-line-string logical-line))
           (source-cells (lem/common/character:string-width source))
           (display-cells (lem/common/character:string-width display))
           (reverse-index (and reverse-needle (search reverse-needle source))))
      (org-modern-test-log
       "LINE label=~a display=~a source=~a cells=~d/~d same=~a reverse=~a"
       label (org-modern-test-encode display) (org-modern-test-encode source)
       source-cells display-cells
       (if (= source-cells display-cells) "yes" "no")
       (if (and reverse-index
                (org-modern-test-reverse-at-p logical-line reverse-index))
           "yes" "no")))))

(defun org-modern-test-record-baseline ()
  (org-modern-test-record-line "keyword" "#+title:")
  (org-modern-test-record-line "heading" "* TODO" "TODO")
  (org-modern-test-record-line "child" "** NEXT")
  (org-modern-test-record-line "inline" "Body <")
  (org-modern-test-record-line "list-open" "- [ ] open")
  (org-modern-test-record-line "list-done" "+ [X] done")
  (org-modern-test-record-line "list-partial" "* [-] partial")
  (org-modern-test-record-line "table" "| name |")
  (org-modern-test-record-line "table-rule" "|------+-------|")
  (org-modern-test-record-line "rule" "---------")
  (org-modern-test-record-line "block-begin" "#+begin_src")
  (org-modern-test-record-line "block-body-list" "source decoy")
  (org-modern-test-record-line "block-body-table" "| source |")
  (org-modern-test-record-line "block-end" "#+end_src")
  (org-modern-test-record-line "filetags" "#+filetags:" ":alpha:")
  (org-modern-test-log
   "SOURCE modified=~a bytes=~a"
   (if (buffer-modified-p (current-buffer)) "yes" "no")
   (if (string= *org-modern-test-original* (buffer-text (current-buffer)))
       "same" "changed")))

(defun org-modern-test-hook-count ()
  (count 'org-modern-enable *org-mode-hook* :test #'eq
         :key (lambda (entry) (if (consp entry) (car entry) entry))))

(defun org-modern-test-glyph-widths ()
  (let ((glyphs "▶▷⯈▹▿▽⯆∙◦–☑□⊟│─┼▏↪⛯"))
    (values
     (every (lambda (character)
              (= 1 (lem/common/character:string-width (string character))))
            glyphs)
     (map 'list (lambda (character)
                  (lem/common/character:string-width (string character)))
          glyphs))))

(define-command lem-yath-test-org-modern-fold () ()
  (with-point ((heading (org-modern-test-find-line "* TODO")))
    (org-clear-folds (current-buffer))
    (org-fold-subtree heading)
    (org-modern-test-record-line "folded" "* TODO")
    (org-modern-test-log
     "FOLD folds=~d next-hidden=~a modified=~a bytes=~a"
     (length (org-buffer-folds (current-buffer)))
     (with-point ((next heading))
       (line-offset next 1)
       (if (org-line-hidden-p next) "yes" "no"))
     (if (buffer-modified-p (current-buffer)) "yes" "no")
     (if (string= *org-modern-test-original* (buffer-text (current-buffer)))
         "same" "changed"))
    (move-point (current-point) heading)
    (redraw-display :force t)))

(define-command lem-yath-test-org-modern-toggle () ()
  (org-clear-folds (current-buffer))
  (org-modern-mode nil)
  (org-modern-test-record-line "disabled" "* TODO")
  (org-modern-mode t)
  (org-modern-test-record-line "reenabled" "* TODO")
  (org-modern-test-log
   "TOGGLE enabled=~a modified=~a bytes=~a"
   (if (mode-active-p (current-buffer) 'org-modern-mode) "yes" "no")
   (if (buffer-modified-p (current-buffer)) "yes" "no")
   (if (string= *org-modern-test-original* (buffer-text (current-buffer)))
       "same" "changed")))

(define-command lem-yath-test-org-modern-cursor () ()
  (org-clear-folds (current-buffer))
  (with-point ((line (org-modern-test-find-line "- [ ] open")))
    (move-point (current-point) line)
    (character-offset (current-point) 3)
    (let* ((logical-line
             (org-modern-test-logical-line
              line (lem-core::get-window-overlays (current-window))))
           (display (lem-core::logical-line-string logical-line))
           (source (line-string line))
           (cursor-index
             (loop :for (start end attribute)
                     :in (lem-core::logical-line-attributes logical-line)
                   :when (and (< start end)
                              (lem-core::cursor-attribute-p attribute))
                     :return start)))
      (org-modern-test-log
       "CURSOR column=~d index=~a source-cells=~d display-cells=~d display=~a modified=~a"
       (point-charpos (current-point)) (or cursor-index "none")
       (lem/common/character:string-width source)
       (lem/common/character:string-width display)
       (org-modern-test-encode display)
       (if (buffer-modified-p (current-buffer)) "yes" "no")))))

(define-command lem-yath-test-org-modern-reload () ()
  (loop :repeat 2 :do
    (load *org-modern-test-source*)
    (load *org-modern-test-transformer-source*))
  (org-modern-mode t)
  (org-modern-test-record-line "reloaded" "* TODO")
  (org-modern-test-log
   "RELOAD hook=~d transformer=~a enabled=~a modified=~a bytes=~a"
   (org-modern-test-hook-count)
   (if (eq (variable-value
            'lem-core::display-line-transform-function :global)
           'transform-lem-yath-display-line)
       "yes" "no")
   (if (mode-active-p (current-buffer) 'org-modern-mode) "yes" "no")
   (if (buffer-modified-p (current-buffer)) "yes" "no")
   (if (string= *org-modern-test-original* (buffer-text (current-buffer)))
       "same" "changed")))

(setf *org-modern-test-original* (buffer-text (current-buffer)))
(multiple-value-bind (one-cell-p widths) (org-modern-test-glyph-widths)
  (org-modern-test-log
   "MODE org=~a modern=~a transformer=~a hook=~d glyphs-one-cell=~a widths=~{~d~^,~}"
   (if (mode-active-p (current-buffer) 'org-mode) "yes" "no")
   (if (mode-active-p (current-buffer) 'org-modern-mode) "yes" "no")
   (if (eq (variable-value
            'lem-core::display-line-transform-function :global)
           'transform-lem-yath-display-line)
       "yes" "no")
   (org-modern-test-hook-count)
   (if one-cell-p "yes" "no") widths))
(org-modern-test-record-baseline)
(org-modern-test-log "READY")
(redraw-display :force t)

(define-key *global-keymap* "F2" 'lem-yath-test-org-modern-fold)
(define-key *global-keymap* "F3" 'lem-yath-test-org-modern-toggle)
(define-key *global-keymap* "F4" 'lem-yath-test-org-modern-cursor)
(define-key *global-keymap* "F5" 'lem-yath-test-org-modern-reload)
