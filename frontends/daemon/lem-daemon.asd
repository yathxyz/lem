(defsystem "lem-daemon"
  :description "Persistent local Lem daemon and native clients"
  :depends-on ("lem/core" "yason")
  :serial t
  :components ((:file "package")
               (:file "protocol")
               (:file "implementation")
               (:file "server")
               (:file "client")))

(defsystem "lem-daemon/tests"
  :depends-on ("lem-daemon" "rove")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "protocol")
                             #+sbcl (:file "integration"))))
  :perform (test-op (op c)
             (declare (ignore op))
             (symbol-call :rove :run c)))
