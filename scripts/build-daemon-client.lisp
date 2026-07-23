(ql:quickload '(:lem-ncurses/core :lem-daemon))

(sb-ext:save-lisp-and-die "lemclient"
                          :toplevel #'lem-daemon/client:main
                          :executable t)
