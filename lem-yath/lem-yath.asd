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
               (:file "direnv")
               (:file "editing")
               (:file "cursor-state")
               (:file "vi")
               (:file "avy")
               (:file "structural")
               (:file "electric-pair")
               (:file "completion")
               (:file "annotations")
               (:file "orderless")
               (:file "auto-completion")
               (:file "actions")
               (:file "snippets")
               (:file "lsp-snippets")
               (:file "ide")
               (:file "editorconfig")
               (:file "formatting")
               (:file "git")
               (:file "project")
               (:file "project-picker")
               (:module "org"
                :serial t
                :components ((:file "parser")
                             (:file "folding")
                             (:file "mode")
                             (:file "commands")
                             (:file "structure")
                             (:file "text-objects")))
               (:file "roam")
               (:file "notes")
               (:file "find-name")
               (:file "tools")
               (:file "llm")
               (:file "theme")
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
               (:file "persistence")
               (:file "vundo")
               (:file "prefix-help")
               (:file "keybindings")))
