(ql:quickload '(:lem-ncurses/core :lem-daemon/sdl-client))

(sb-ext:save-lisp-and-die "lemclient"
                          :toplevel #'lem-daemon/client:main
                          :executable t)
