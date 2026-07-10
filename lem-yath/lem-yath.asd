;;;; lem-yath -> Lem: a faithful port of the "lem-yath" Emacs configuration to Lem.
;;;; All lem-* systems referenced by the sources are already present in the
;;;; nix-built lem-ncurses image, so this system intentionally declares no
;;;; dependencies on them.

(defsystem "lem-yath"
  :description "Port of yanni's Emacs (lem-yath) configuration to Lem."
  :author "yanni <yathxyz@gmail.com>"
  :license "MIT"
  :serial t
  :pathname "src/"
  :components ((:file "package")
               (:file "base")
               (:file "editing")
               (:file "vi")
               (:file "completion")
               (:file "ide")
               (:file "git")
               (:file "notes")
               (:file "tools")
               (:file "llm")
               (:file "ui")
               (:module "apps"
                :components ((:file "agenda")
                             (:file "citar")
                             (:file "devdocs")
                             (:file "elfeed")
                             (:file "notmuch")
                             (:file "pg")
                             (:file "salta")
                             (:file "timemachine")
                             (:file "llm-cli")))
               (:file "keybindings")))
