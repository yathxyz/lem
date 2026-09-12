(load (merge-pathnames "recovery-source.lisp" *load-truename*))
(load-recovery-system "lem/core")
(load-recovery-system "lem-daemon")
(load-recovery-system "lem-toolkit/jobs-ui")
(lem:add-hook lem:*exit-editor-hook*
              (lambda () (lem-toolkit/jobs:close-job-manager)))
(lem:main (list "--daemon=recovery-test" "-q" "--eval"
                "(setf lem-toolkit/jobs:*default-manager* (lem-toolkit/jobs:open-job-manager :name \"jobs-test\"))"))
