(defsystem "lem-verified-kernel"
  :description "Loader for the Lem verified kernel: dual-loads the ACL2-certified
books under verified/ into the running image through verified/shim.lisp (SPEC-VK
Constraint 2 -- the certified sources ARE the executed sources)."
  :pathname "verified"
  ;; The loader reads these sources indirectly. Track them so a fresh image
  ;; recompiles cached callers, including inlined calls, after source changes.
  :serial t
  :components ((:static-file "shim.lisp")
               (:static-file "input-decode.lisp")
               (:static-file "eastasian-data.lisp")
               (:static-file "width.lisp")
               (:static-file "layout.lisp")
               (:static-file "buffer-model.lisp")
               (:static-file "buffer-edit.lisp")
               (:file "shim-loader")))
