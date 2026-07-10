;;;; The SPC leader map -- the muscle-memory core of the Emacs config
;;;; (general.el definitions from init-evil.el), bound via vi-mode's
;;;; Leader mechanism. Loaded last so every command already exists.
;;;; All leader chords are centralized here so normal and visual states stay
;;;; in sync.

(in-package :lem-yath)

(defmacro define-leader-keys (keymap &body bindings)
  `(progn
     ,@(loop :for (keys command) :in bindings
             :collect `(define-key ,keymap ,(concatenate 'string "Leader " keys)
                         ,command))))

(defmacro define-evil-leader-keys (&body bindings)
  "Define BINDINGS in both normal and visual states, like general.el."
  `(progn
     (defparameter *evil-leader-bindings*
       ',(loop :for (keys command-form) :in bindings
               :collect (list keys
                              (if (and (consp command-form)
                                       (eq (first command-form) 'quote))
                                  (second command-form)
                                  command-form))))
     (define-leader-keys lem-vi-mode:*normal-keymap* ,@bindings)
     (define-leader-keys lem-vi-mode:*visual-keymap* ,@bindings)))

(define-evil-leader-keys
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
  ("g t" 'lem-yath-git-timemachine)               ; SPC g t

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
  ("m I" 'lem-yath-org-id-get-create)              ; SPC m I
  ("m a" 'lem-yath-agenda)                        ; SPC m a
  ("o" 'lem-yath-capture)                         ; SPC o

  ;; compile / eval
  ("c c" 'lem-yath-compile)                       ; SPC c c
  ("m e e" 'lem-lisp-mode:lisp-eval-last-expression) ; SPC m e e

  ;; help (helpful)
  ("h k" 'apropos-command)                    ; SPC h k (helpful-callable)
  ("h v" 'lem-yath-describe-variable)         ; SPC h v (helpful-variable)
  ("h K" 'describe-key)                       ; SPC h K (helpful-key)
  ("h d" 'lem-yath-devdocs-lookup)            ; SPC h d
  ("h b" 'describe-bindings)

  ;; citations / display
  ("y o" 'lem-yath-citar-open)                 ; SPC y o
  ("y a" 'lem-yath-toggle-auto-fill)           ; SPC y a
  ("y v" 'toggle-line-wrap)                    ; SPC y v (visual-line-mode)
  ("y w" 'lem-yath-fill-paragraph)             ; SPC y w

  ;; navigation (avy / isearch)
  ("l" 'goto-line)                            ; SPC l (avy-goto-line)
  ("a" 'lem-yath-snipe-forward)                   ; SPC a (avy-goto-char)
  ("s" 'lem/isearch:isearch-forward-symbol)   ; SPC s (avy-goto-symbol-1)
  ("v" 'lem-yath-expand-region))              ; SPC v (expreg-expand)

(defun leader-binding-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap
                (lem-core::parse-keyspec
                 (concatenate 'string "Leader " keys)))))
    (lem-core::prefix-suffix prefix)))

(defun evil-leader-bindings-ok-p ()
  "Whether every declared leader binding matches in normal and visual states."
  (every (lambda (binding)
           (destructuring-bind (keys command) binding
             (and (eq command
                      (leader-binding-command lem-vi-mode:*normal-keymap* keys))
                  (eq command
                      (leader-binding-command lem-vi-mode:*visual-keymap* keys)))))
         *evil-leader-bindings*))

;;; --- non-leader bindings ----------------------------------------------------

;; insert state: C-c i sends to the LLM (gptel-send from insert state)
(define-key lem-vi-mode:*insert-keymap* "C-c i" 'lem-yath-llm-send)
(define-key lem-vi-mode:*insert-keymap* "C-u" 'lem-yath-delete-back-to-indentation)
(define-key lem-vi-mode:*insert-keymap* "M-Backspace"
  'lem-yath-structural-kill-last-word)
(define-key lem-vi-mode:*insert-keymap* "C-w"
  'lem-yath-structural-kill-last-word)

;; The Emacs config unbinds Evil's C-n/C-p overrides so they retain ordinary
;; line movement (and completion keymaps can take precedence when active).
(define-key lem-vi-mode:*normal-keymap* "C-n" 'next-line)
(define-key lem-vi-mode:*normal-keymap* "C-p" 'previous-line)
(define-key lem-vi-mode:*insert-keymap* "C-n" 'next-line)
(define-key lem-vi-mode:*insert-keymap* "C-p" 'previous-line)

;; normal state: C-c c opens Claude Code (claude-code-transient)
(define-key lem-vi-mode:*normal-keymap* "C-c c" 'lem-claude-code::claude-code)

;; globals from the `use-package emacs` block
(define-key *global-keymap* "M-o" 'next-window)        ; other-window
(define-key *global-keymap* "M-j" 'lem-yath-duplicate-line) ; duplicate-dwim
(define-key *global-keymap* "M-s g" 'lem/grep:grep)    ; M-s g grep

;; keybindings.lisp is the system's last component; reaching here means the
;; whole port loaded.
(setf *boot-ok* t)
