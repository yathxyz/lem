(defsystem "lem-ncurses/core"
  :depends-on ("cffi"
               "cl-charms"
               "cl-setlocale"
               "lem/core"
               "lem-verified-kernel")
  :serial t
  :components (#+pdcurses(:file "cl-charms-pdcurseswin32")
               (:file "config")
               (:file "term")
               (:file "clipboard")
               (:file "style")
               (:file "key")
               (:file "attribute")
               (:file "drawing-object")
               (:file "view")
               (:file "render")
               (:file "mouse")
               (:file "input")
               (:file "emergency-save")
               (:file "mainloop")
               (:file "ncurses")))

(defsystem "lem-ncurses"
  :depends-on ("lem-ncurses/core"
               "lem/extensions"
               "lem-daemon"))

(defsystem "lem-ncurses/tests"
  :depends-on ("lem-ncurses" "rove")
  :components ((:module "tests"
                :components ((:file "csi-decode")
                             (:file "bracketed-paste")
                             (:file "truecolor"))))
  :perform (test-op (op c) (symbol-call :rove '#:run c)))
