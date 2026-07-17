(defsystem "lem-verified-kernel"
  :description "Loader for the Lem verified kernel: dual-loads the ACL2-certified
books under verified/ into the running image through verified/shim.lisp (SPEC-VK
Constraint 2 -- the certified sources ARE the executed sources)."
  :pathname "verified"
  :components ((:file "shim-loader")))
