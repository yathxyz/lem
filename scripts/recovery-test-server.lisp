;;;; Isolated source daemon for the external crash test. Never loads user init.
(load (merge-pathnames "recovery-source.lisp" *load-truename*))
(load-recovery-system "lem/core")
(load-recovery-system "lem-daemon")
(load-recovery-system "lem-daemon/recovery")
(lem:main (list "--daemon=recovery-test" "-q" "--eval"
                "(lem-daemon/recovery:enable :server-name \"recovery-test\" :interval 0.1)"))
