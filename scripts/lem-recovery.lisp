;;;; Development entry point; packaged deployments use lem-recover.
(load (merge-pathnames "recovery-source.lisp" *load-truename*))
(load-recovery-system "lem-daemon/recovery-cli")
(lem-daemon/recovery-cli:main)
