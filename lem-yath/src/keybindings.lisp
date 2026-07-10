;;;; The SPC leader map -- the muscle-memory core of the Emacs config
;;;; (general.el definitions from init-evil.el), bound via vi-mode's
;;;; Leader mechanism. Loaded last so every command already exists.
;;;; App modules (apps/*.lisp) bind their own leader chords next to their
;;;; commands; everything else is centralized here.

(in-package :lem-yath)

(defmacro define-leader-keys (keymap &body bindings)
  `(progn
     ,@(loop :for (keys command) :in bindings
             :collect `(define-key ,keymap ,(concatenate 'string "Leader " keys)
                         ,command))))

;;; --- normal state -----------------------------------------------------------

(define-leader-keys lem-vi-mode:*normal-keymap*
  ;; files / buffers
  ("f f" 'find-file)                          ; SPC f f
  ("<" 'select-buffer)                        ; SPC <
  ("Space" 'lem-yath-project-buffers)             ; SPC SPC (consult-project-buffer)
  ("b k" 'lem-yath-kill-current-buffer)           ; SPC b k
  ("b f" 'lem-yath-format-buffer)                 ; SPC b f (apheleia)
  ("b m" 'lem-bookmark::bookmark-set)         ; SPC b m
  ("Return" 'lem-bookmark::bookmark-jump)     ; SPC RET

  ;; project (project.el / consult)
  ("p f" 'project-find-file)                  ; SPC p f
  ("p g" 'lem/grep:project-grep)              ; SPC p g
  ("p p" 'project-switch)                     ; SPC p p
  ("p s" 'lem-lsp-mode::lsp-document-symbol)  ; SPC p s (consult-eglot-symbols)

  ;; git (magit / majutsu dispatch)
  ("g g" 'lem-yath-vcs-status)                    ; SPC g g
  ("g G" 'lem-yath-legit-status)                  ; SPC g G
  ("g J" 'lem-yath-jj-log)                        ; SPC g J

  ;; LLM (gptel)
  ("g j" 'lem-yath-llm-send)                      ; SPC g j (gptel-send)
  ("g l" 'lem-yath-llm-ask)                       ; SPC g l (preset/handoff menu)
  ("g L" 'lem-yath-llm-set-model)                 ; SPC g L (gptel-menu)

  ;; notes (org-roam / org-journal / org-capture)
  ("n r f" 'lem-yath-roam-find)                   ; SPC n r f
  ("n r i" 'lem-yath-roam-insert)                 ; SPC n r i
  ("n r a" 'lem-yath-roam-random)                 ; SPC n r a
  ("n r d t" 'lem-yath-dailies-today)             ; SPC n r d t
  ("n r d d" 'lem-yath-dailies-date)              ; SPC n r d d
  ("n j j" 'lem-yath-journal-new-entry)           ; SPC n j j
  ("o" 'lem-yath-capture)                         ; SPC o

  ;; compile / eval
  ("c c" 'lem-yath-compile)                       ; SPC c c
  ("m e e" 'lem-lisp-mode:lisp-eval-last-expression) ; SPC m e e

  ;; help (helpful)
  ("h k" 'apropos-command)                    ; SPC h k (helpful-callable)
  ("h K" 'describe-key)                       ; SPC h K (helpful-key)
  ("h b" 'describe-bindings)

  ;; navigation (avy / isearch)
  ("l" 'goto-line)                            ; SPC l (avy-goto-line)
  ("a" 'lem-yath-snipe-forward)                   ; SPC a (avy-goto-char)
  ("s" 'lem/isearch:isearch-forward-symbol))  ; SPC s (avy-goto-symbol-1)

;;; --- visual state: the subset that operates on a selection ------------------

(define-leader-keys lem-vi-mode:*visual-keymap*
  ("g j" 'lem-yath-llm-send)
  ("g l" 'lem-yath-llm-ask)
  ("g g" 'lem-yath-vcs-status))

;;; --- non-leader bindings ----------------------------------------------------

;; insert state: C-c i sends to the LLM (gptel-send from insert state)
(define-key lem-vi-mode:*insert-keymap* "C-c i" 'lem-yath-llm-send)

;; normal state: C-c c opens Claude Code (claude-code-transient)
(define-key lem-vi-mode:*normal-keymap* "C-c c" 'lem-claude-code::claude-code)

;; globals from the `use-package emacs` block
(define-key *global-keymap* "M-o" 'next-window)        ; other-window
(define-key *global-keymap* "M-j" 'lem-yath-duplicate-line) ; duplicate-dwim
(define-key *global-keymap* "M-s g" 'lem/grep:grep)    ; M-s g grep

;; keybindings.lisp is the system's last component; reaching here means the
;; whole port loaded.
(setf *boot-ok* t)
