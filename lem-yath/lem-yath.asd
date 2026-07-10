;;;; lem-yath -> Lem: a faithful port of the "lem-yath" Emacs configuration to Lem.
;;;; The nix-built Lem image already contains the editor systems referenced by
;;;; these sources.  Do not list them as ASDF dependencies: doing so makes ASDF
;;;; try to rebuild bundled extensions inside the immutable Nix store.

(defsystem "lem-yath"
  :description "Port of yanni's Emacs (lem-yath) configuration to Lem."
  :author "yanni <yathxyz@gmail.com>"
  :license "MIT"
  :serial t
  :pathname "src/"
  :components ((:file "package")
               (:file "base")
               (:file "workspace")
               (:file "editing")
               (:file "vi")
               (:file "structural")
               (:file "completion")
               (:file "auto-completion")
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
