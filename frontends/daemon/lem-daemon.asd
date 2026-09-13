(defsystem "lem-daemon"
  :description "Persistent local Lem daemon and native clients"
  :depends-on ("lem/core" "yason")
  :serial t
  :components ((:file "package")
               (:file "protocol")
               (:file "transport")
               (:file "transport-unix")
               (:file "faces")
               (:file "implementation")
               (:file "server")
               (:file "client")))

(defsystem "lem-daemon/sdl-client"
  :description "Native graphical attachment to an existing Lem daemon"
  :depends-on ("lem-daemon" "lem-sdl2/client-support")
  :components ((:file "sdl-client")))

(defsystem "lem-daemon/tests"
  :depends-on ("lem-daemon" "rove")
  :serial t
  :components ((:module "tests"
                :serial t
                :components ((:file "protocol")
                             (:file "client")
                             (:file "mouse-session")
                             #+sbcl (:file "integration")
                             #+sbcl (:file "backpressure"))))
  :perform (test-op (op c)
             (declare (ignore op))
             (symbol-call :rove :run c)))

(defsystem "lem-daemon/sdl-client/tests"
  :depends-on ("lem-daemon/sdl-client" "rove")
  :components ((:module "tests" :components ((:file "sdl-client"))))
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

(defsystem "lem-daemon/recovery-cli"
  :description "Standalone recovery inspector without editor initialization"
  :depends-on ("lem-daemon/recovery-store" "lem-toolkit/jobs")
  :components ((:module "recovery" :components ((:file "cli")))))
