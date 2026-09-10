(defsystem "lem-daemon"
  :description "Persistent local Lem daemon and native clients"
  :depends-on ("lem/core" "yason")
  :serial t
  :components ((:file "package")
               (:file "protocol")
               (:file "transport")
               (:file "transport-unix")
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

(defsystem "lem-daemon/recovery-store"
  :description "Private durable text records, usable without an editor or user init"
  :depends-on ("yason" "ironclad" "babel")
  :serial t
  :components ((:file "recovery/store")))

(defsystem "lem-daemon/recovery"
  :description "Opt-in durable recovery of modified file and scratch buffers"
  :depends-on ("lem/core" "lem-daemon/recovery-store")
  :serial t
  :components ((:file "recovery/editor")))

(defsystem "lem-daemon/recovery-tests"
  :depends-on ("lem-daemon/recovery" "rove" "lem-daemon")
  :serial t
  :components ((:file "tests/recovery"))
  :perform (test-op (op c)
             (declare (ignore op))
             (symbol-call :rove :run c)))
