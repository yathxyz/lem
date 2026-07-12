;;;; Native terminal rendering of the current Emacs Modus Vivendi Tinted
;;;; theme.  Keep this separate from UI behavior so palette drift is easy to
;;;; audit against Emacs' built-in modus-themes.el.

(in-package :lem-yath)

(defparameter *lem-yath-color-theme* "modus-vivendi-tinted")

(lem-core:define-color-theme "modus-vivendi-tinted" ()
  (:display-background-mode :dark)
  (:foreground "#ffffff")
  (:background "#0d0e1c")
  (:inactive-window-background "#2b3045")

  ;; A compact Base16 projection of Modus Vivendi Tinted's palette.  Extensions
  ;; which use Base16 attributes inherit the same visual vocabulary as the
  ;; explicit semantic faces below.
  (:base00 "#0d0e1c")
  (:base01 "#1d2235")
  (:base02 "#4a4f69")
  (:base03 "#989898")
  (:base04 "#c6daff")
  (:base05 "#ffffff")
  (:base06 "#d2b580")
  (:base07 "#ffffff")
  (:base08 "#ff5f59")
  (:base09 "#fec43f")
  (:base0A "#d0bc00")
  (:base0B "#44bc44")
  (:base0C "#00d3d0")
  (:base0D "#2fafff")
  (:base0E "#feacd0")
  (:base0F "#ef8386")

  (lem-core:region :foreground "#ffffff" :background "#555a66")
  (lem-core:modeline :foreground "#ffffff" :background "#484d67")
  (lem-core:modeline-inactive :foreground "#969696" :background "#292d48")
  (lem-core:truncate-attribute :foreground "#d0bc00")
  (lem-core::special-char-attribute :foreground "#ff5f59")
  (lem-core:compiler-note-attribute :underline "#ff5f5f")

  ;; font-lock mappings from modus-themes-vivendi-tinted-palette.
  (lem-core:syntax-warning-attribute :foreground "#d0bc00" :bold t)
  (lem-core:syntax-string-attribute :foreground "#2fafff")
  (lem-core:syntax-comment-attribute :foreground "#ef8386")
  (lem-core:syntax-keyword-attribute :foreground "#79a8ff" :bold t)
  (lem-core:syntax-constant-attribute :foreground "#b6a0ff")
  (lem-core:syntax-function-name-attribute :foreground "#f78fe7")
  (lem-core:syntax-variable-attribute :foreground "#4ae2f0")
  (lem-core:syntax-type-attribute :foreground "#11c777" :bold t)
  (lem-core:syntax-builtin-attribute :foreground "#feacd0" :bold t)

  (lem-core::modeline-name-attribute :foreground "#ffffff" :bold t)
  (lem-core::inactive-modeline-name-attribute :foreground "#969696" :bold t)
  (lem-core::modeline-major-mode-attribute :foreground "#c6daff")
  (lem-core::inactive-modeline-major-mode-attribute :foreground "#969696")
  (lem-core::modeline-minor-modes-attribute :foreground "#ffffff")
  (lem-core::inactive-modeline-minor-modes-attribute :foreground "#969696")
  (lem-core::modeline-position-attribute :foreground "#ffffff" :background "#484d67")
  (lem-core::inactive-modeline-position-attribute :foreground "#969696" :background "#292d48")
  (lem-core::modeline-posline-attribute :foreground "#ffffff" :background "#484d67")
  (lem-core::inactive-modeline-posline-attribute :foreground "#969696" :background "#292d48")

  (lem/line-numbers:line-numbers-attribute
   :foreground "#989898" :background "#1d2235")
  (lem/line-numbers:active-line-number-attribute
   :foreground "#ffffff" :background "#4a4f69" :bold t)
  (lem/show-paren:showparen-attribute
   :foreground "#ffffff" :background "#4f7f9f")
  (lem/isearch:isearch-highlight-attribute
   :foreground "#ffffff" :background "#2266ae")
  (lem/isearch:isearch-highlight-active-attribute
   :foreground "#ffffff" :background "#7a6100")
  (lem/prompt-window:prompt-attribute :foreground "#4ae2f0" :bold t)
  (lem/link::link-attribute :foreground "#79a8ff" :underline t)

  ;; rainbow-delimiters' first six Modus depths.  Lem's Lisp renderer exposes
  ;; six attributes and cycles after them; the remaining Emacs depths stay a
  ;; documented limitation rather than receiving invented colors.
  (lem-lisp-mode/paren-coloring:paren-color-1 :foreground "#ffffff")
  (lem-lisp-mode/paren-coloring:paren-color-2 :foreground "#ff66ff")
  (lem-lisp-mode/paren-coloring:paren-color-3 :foreground "#00eff0")
  (lem-lisp-mode/paren-coloring:paren-color-4 :foreground "#ff6b55")
  (lem-lisp-mode/paren-coloring:paren-color-5 :foreground "#efef00")
  (lem-lisp-mode/paren-coloring:paren-color-6 :foreground "#b6a0ff")

  (lem-core:document-header1-attribute :foreground "#ffffff" :bold t)
  (lem-core:document-header2-attribute :foreground "#d2b580" :bold t)
  (lem-core:document-header3-attribute :foreground "#82b0ec" :bold t)
  (lem-core:document-header4-attribute :foreground "#feacd0" :bold t)
  (lem-core:document-header5-attribute :foreground "#88ca9f" :bold t)
  (lem-core:document-header6-attribute :foreground "#ef8386" :bold t)
  (lem-core:document-bold-attribute :bold t)
  (lem-core:document-italic-attribute :foreground "#c6daff")
  (lem-core:document-underline-attribute :underline t)
  (lem-core:document-link-attribute :foreground "#79a8ff" :underline t)
  (lem-core:document-list-attribute :foreground "#fec43f")
  (lem-core:document-code-block-attribute
   :foreground "#6ae4b9" :background "#1d2235")
  (lem-core:document-inline-code-attribute :foreground "#6ae4b9")
  (lem-core:document-blockquote-attribute :foreground "#989898")
  (lem-core:document-table-attribute :foreground "#c6daff")
  (lem-core:document-task-list-attribute :foreground "#44bc44")
  (lem-core:document-metadata-attribute :foreground "#989898"))

(defun load-lem-yath-color-theme ()
  "Apply the same explicit theme selected by the current Emacs config."
  (load-theme *lem-yath-color-theme* nil))

;; Upstream's persisted theme loads at weight 0.  Keep one lower-weight hook so
;; startup always reapplies this profile afterwards.  Also load immediately for
;; post-init configuration reloads; Lem marks itself "in the editor" before it
;; reads the startup init file, so that flag alone cannot distinguish the two.
(remove-hook *after-init-hook* 'load-lem-yath-color-theme)
(add-hook *after-init-hook* 'load-lem-yath-color-theme -100)
(when lem-core::*in-the-editor*
  (load-lem-yath-color-theme))
