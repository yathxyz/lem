;;;; big-file.lisp -- T2 workload: open a 10 MB file, page end-to-end (PF-5).
;;;;
;;;; Opens the committed `mixed-10m' corpus (~10 MB, ~244 000 lines of mixed
;;;; prose/code with some unicode) through the real file-open path
;;;; `lem:find-file-buffer' -- NOT the interactive `find-file' command, whose
;;;; large-file guard would prompt headless -- then pages through it end to end
;;;; with `next-page' until end-of-buffer, forcing a full redisplay per page,
;;;; and finally jumps to the bottom and back to the top.  This is the
;;;; page-through-a-huge-file session (SPEC-PERF PF-5 big-file row): it stresses
;;;; scroll/window-view relocation and full-frame redisplay over a very large
;;;; buffer, and every command used is frozen public API (an API-stability
;;;; canary).
;;;;
;;;; Replayability: the session is read-only (paging + cursor jumps, no edits),
;;;; and RUN resets the cursor to buffer start at entry, so every execution
;;;; renders the identical sequence of frames.  `next-page' signals
;;;; `lem:end-of-buffer' when it cannot advance; catching it is the end-to-end
;;;; termination.

(in-package :cl-user)

(defun bench-t2-big-file-setup ()
  "Open the 10 MB corpus once and return its buffer."
  (lem:find-file-buffer (namestring (bench-ensure-corpus :mixed-10m))))

(defun bench-t2-big-file-run (buffer)
  (lem:switch-to-buffer buffer)
  (lem:move-to-beginning-of-buffer)
  (bench-t2-render)
  ;; Page through end to end.
  (handler-case
      (loop
        (lem:next-page)
        (bench-t2-render))
    (lem:end-of-buffer () nil))
  ;; Jump to the bottom, then back to the top.
  (lem:move-to-end-of-buffer)
  (bench-t2-render)
  (lem:move-to-beginning-of-buffer)
  (bench-t2-render))

(register-t2-workload
 :name "big-file"
 :setup #'bench-t2-big-file-setup
 :run #'bench-t2-big-file-run)
