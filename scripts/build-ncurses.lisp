;; SPEC-VK VK-4: LEM_PARANOID=1 pushes :lem-paranoid so the image defaults the
;; kernel-backed edit engine to :paranoid (per-edit certified wf-buffer checks).
;; The daily-driver build (scripts/daily-driver-update.sh) sets it until soak.
(when (uiop:getenvp "LEM_PARANOID")
  (push :lem-paranoid *features*))

(ql:quickload :lem-ncurses)

(lem:init-at-build-time)

(sb-ext:save-lisp-and-die "lem"
                          :toplevel #'lem:main
                          :executable t)
