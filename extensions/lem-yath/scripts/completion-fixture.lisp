(in-package :lem-yath)

(define-command lem-yath-test-report-prompt-focus () ()
  (alexandria:when-let* ((context lem/completion-mode::*completion-context*)
                         (popup
                          (lem/completion-mode::context-popup-menu context))
                         (item (lem/popup-menu:get-focus-item popup)))
    (with-open-file (stream (uiop:getenv "LEM_YATH_COMPLETION_REPORT")
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :create)
      (let ((input (lem/prompt-window::get-input-string)))
        (format stream "FOCUS=~a INPUT-LENGTH=~d INPUT=~a~%"
                (lem/completion-mode:completion-item-label item)
                (length input)
                input)))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "F5" 'lem-yath-test-report-prompt-focus)
(pushnew 'lem-yath-test-report-prompt-focus
         *auto-completion-continue-commands*)

(define-command lem-yath-test-report-marginalia-layout () ()
  "Report the rendered popup rows and terminal-cell detail columns."
  (alexandria:when-let* ((context lem/completion-mode::*completion-context*)
                         (popup
                           (lem/completion-mode::context-popup-menu context)))
    (let* ((text
             (buffer-text (lem/popup-menu::popup-menu-buffer popup)))
           (lines (ppcre:split "\\n" text))
           (columns
             (loop :for line :in lines
                   :for marker := (search "ABC" line)
                   :when marker
                     :collect
                     (lem/common/character:string-width
                      line :end marker))))
      (with-open-file (stream (uiop:getenv "LEM_YATH_COMPLETION_REPORT")
                              :direction :output
                              :if-exists :append
                              :if-does-not-exist :create)
        (format stream "LAYOUT width=~d columns=~{~d~^,~} rows=~a~%"
                (display-width)
                columns
                (completion-path-display-string text))))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "F9" 'lem-yath-test-report-marginalia-layout)
(pushnew 'lem-yath-test-report-marginalia-layout
         *auto-completion-continue-commands*)

(define-command lem-yath-test-marginalia-command () ()
  "Zyzzyva-annotation-only-token proves command documentation is display-only."
  (message "Marginalia command fixture invoked"))

(define-key *global-keymap* "F6" 'lem-yath-test-marginalia-command)

(define-command lem-yath-test-marginalia-layout-prompt () ()
  "Open a prompt with wide labels and directionally truncated fields."
  (prompt-for-string
   "Layout: "
   :completion-function
   (lambda (input)
     (completion-annotated-prompt-choices
      (prescient-filter
       input
       '(("layout-short" . "layout-short")
         ("界界界界界界界界界界" . "界界界界界界界界界界"))
       :key #'car :rank-p nil)
      (lambda (ignored)
        (declare (ignore ignored))
        (completion-join-annotation-fields
         (completion-field
          "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" :truncate 0.5)
         (completion-field
          "/prefix/that/should/disappear/useful-tail.txt"
          :truncate -0.5)))))))

(defun lem-yath-test-marginalia-layout-oracle ()
  "Check the pinned cell-width, padding, and truncation contract."
  (flet ((same (expected actual name)
           (unless (equal expected actual)
             (error "~a: expected ~s, got ~s" name expected actual))))
    (let ((*completion-annotation-window-width-override* 24))
      (same "abcde…"
            (completion-format-annotation-field
             (completion-field "abcdefghijkl" :truncate 0.5))
            "right truncation")
      (same "…hijkl"
            (completion-format-annotation-field
             (completion-field "abcdefghijkl" :truncate -0.5))
            "left truncation")
      (same "あい…"
            (completion-truncate-display-width "あいうえ" 5)
            "wide-character truncation")
      (same "x   "
            (completion-format-annotation-field
             (completion-field "x" :width 4))
            "left field padding")
      (same "   x"
            (completion-format-annotation-field
             (completion-field "x" :width -4))
            "right field padding"))
    (same 20
          (lem/completion-mode::compute-label-width
           (list (lem/completion-mode:make-completion-item
                  :label "short")))
          "minimum alignment column")
    (same 30
          (lem/completion-mode::compute-label-width
           (list (lem/completion-mode:make-completion-item
                  :label "界界界界界界界界界界")))
          "wide label rounded alignment")))

(lem-core:define-color-theme "lem-yath-marginalia-child"
    ("modus-vivendi-tinted")
  (:foreground "#eeeeee"))

(define-command lem-yath-test-report-theme () ()
  (with-open-file (stream (uiop:getenv "LEM_YATH_COMPLETION_REPORT")
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (format stream "THEME=~a~%" (current-theme))))

(define-command lem-yath-test-restore-theme () ()
  ;; Persist only an upstream theme: Lem restores its saved theme before the
  ;; test's --eval form has loaded lem-yath's custom definitions.
  (load-theme "lem-default" t))

(define-key *global-keymap* "F7" 'lem-yath-test-report-theme)
(define-key *global-keymap* "F8" 'lem-yath-test-restore-theme)

(define-command lem-yath-test-vertico-shared-prefix-prompt () ()
  "Open a prompt whose initial candidates share a nonempty prefix."
  (prompt-for-string
   "Shared prefix: "
   :completion-function
   (lambda (input)
     (declare (ignore input))
     '("common-alpha" "common-beta"))))

(define-command lem-yath-test-vertico-singleton-prompt () ()
  "Open a prompt whose initial completion batch contains one candidate."
  (prompt-for-string
   "Singleton: "
   :completion-function
   (lambda (input)
     (declare (ignore input))
     '("singleton-value"))))

(define-command lem-yath-test-prescient-character-fold-prompt () ()
  "Open a controlled prompt using the configured Prescient matcher."
  (let ((choice
          (prompt-for-string
           "Character fold: "
           :completion-function
           (lambda (input)
             (prescient-filter
              input
              '("CAFÉ-TARGET" "cafe-plain-decoy")
              :rank-p nil)))))
    (with-open-file (stream (uiop:getenv "LEM_YATH_COMPLETION_REPORT")
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :create)
      (format stream "CHARACTER-FOLD=~a~%" choice))))

(defun lem-yath-test-prescient-character-fold-oracle ()
  "Check the pinned Prescient character-fold contract without prompt timing."
  (flet ((same (expected query candidates name)
           (let ((actual
                   (prescient-filter query candidates :rank-p nil)))
             (unless (equal expected actual)
               (error "~a: expected ~s, got ~s" name expected actual)))))
    (same '("CAFÉ-TARGET" "cafe-plain")
          "cafe" '("CAFÉ-TARGET" "cafe-plain" "other")
          "diacritic folding")
    (same '("résumé" "resume")
          "resume" '("résumé" "resume")
          "ASCII query direction")
    (same '("résumé")
          "résumé" '("resume" "résumé")
          "accented query direction")
    (same '("ŕésumé" "résumé")
          "résumé" '("ŕésumé" "résumé" "resume" "rḗsumé")
          "mixed directional folding")
    (same '("CAFÉ")
          "CAFE" '("CAFÉ" "café" "Cafe")
          "smart case")
    (same '("①" "1")
          "1" '("①" "1")
          "compatibility folding")
    (same '("ﬂé" "flé")
          "flé" '("ﬂé" "flé" "fle")
          "mixed compatibility folding")
    (same '("flower")
          "f" '("ﬂower" "flower")
          "compatibility unit boundary")
    (same '("quote”" "quote\"")
          "quote\"" '("quote”" "quote\"")
          "double-quote folding")
    (same '("quote’" "quote'")
          "quote'" '("quote’" "quote'")
          "single-quote folding")
    (same '("quote‘" "quote`")
          "quote`" '("quote‘" "quote`")
          "backtick folding")
    (same '("ae") "ae" '("æ" "ae") "no invented ae expansion")
    (same '("ss") "ss" '("ß" "ss") "no invented ss expansion")))

(defun lem-yath-test-prescient-method-match-p
    (method query candidate &key (case-folding :smart)
                              (character-folding-p t))
  "Evaluate one pinned Prescient METHOD without requiring a live prompt."
  (let ((case-sensitive-p
          (prescient-case-sensitive-p query case-folding)))
    (loop :for component :in (prescient-split-query query)
          :for component-index :from 0
          :always
            (funcall
             (prescient-method-matcher
              method component component-index case-sensitive-p
              character-folding-p)
             candidate))))

(defun lem-yath-test-prescient-method-oracle ()
  "Check the pinned filter-method corpus captured from Prescient.el."
  (flet ((check (expected method query candidate name &rest settings)
           (let ((actual
                   (apply #'lem-yath-test-prescient-method-match-p
                          method query candidate settings)))
             (unless (eql expected (not (null actual)))
               (error "~a: expected ~s for ~s/~s, got ~s"
                      name expected query candidate actual)))))
    (check t :literal "cafe" "café" "literal character folding")
    (check nil :literal "café" "cafe" "literal folding direction")
    (check nil :literal-prefix "pha" "alpha" "literal interior prefix")
    (check t :literal-prefix "pha" "phantom" "literal candidate prefix")
    (check t :literal-prefix "al be" "alpha beta" "later word prefix")
    (check t :initialism "fa" "find-file-at-point" "initialism")
    (check nil :initialism "fp" "find-file-at-point"
           "nonadjacent initialism")
    (check t :fuzzy "ayc" "axbyc" "fuzzy subsequence")
    (check t :prefix "str-r" "string-repeat" "partial word prefix")
    (check t :prefix "re" "repertoire" "single word prefix")
    (check nil :prefix "ring-r" "string-repeat" "interior word prefix")
    (check t :anchored "FiFiAt" "find-file-at-point"
           "capital anchors")
    (check t :anchored "fi-fi-at" "find-file-at-point"
           "symbol anchors")
    (check t :anchored "FFA" "find-file-at-point"
           "abbreviated capital anchors")
    (check t :regexp "^needle$" "needle" "regular expression")
    (check t :literal "alpha" "Alpha" "smart case folding")
    (check nil :literal "Alpha" "alpha" "smart case sensitivity")
    (check nil :literal "cafe" "café" "disabled character folding"
           :character-folding-p nil)
    (check nil :literal "alpha" "Alpha" "disabled case folding"
           :case-folding nil)))

(defun lem-yath-test-grouped-prompt-item (label group)
  "Return a grouped completion item spanning the live prompt input."
  (with-point ((start (lem/prompt-window::current-prompt-start-point))
               (end (lem/prompt-window::current-prompt-start-point)))
    (lem/completion-mode:make-completion-item
     :label label
     :insert-text label
     :group group
     :start start
     :end (line-end end))))

(define-command lem-yath-test-vertico-grouped-prompt () ()
  "Open a prompt with two non-selectable completion group headings."
  (prompt-for-string
   "Grouped: "
   :completion-function
   (lambda (input)
     (declare (ignore input))
     (list
      (lem-yath-test-grouped-prompt-item "group-alpha" "First Group")
      (lem-yath-test-grouped-prompt-item "group-beta" "First Group")
      (lem-yath-test-grouped-prompt-item "group-gamma" "Second Group")
      (lem-yath-test-grouped-prompt-item "group-delta" "Second Group")))))

(lem-yath-test-prescient-character-fold-oracle)
(lem-yath-test-prescient-method-oracle)
(lem-yath-test-marginalia-layout-oracle)
