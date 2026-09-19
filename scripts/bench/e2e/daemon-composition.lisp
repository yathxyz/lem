;;;; In nix develop, from the repository root:
;;;; sbcl --noinform --no-sysinit --no-userinit --non-interactive
;;;;   --load .qlot/setup.lisp --load scripts/bench/e2e/daemon-composition.lisp
;;;; Optional LEM_OVERLAY_SOURCE loads baseline overlay-text/overlay-cells definitions.
;;;; Each fixture composes 3000 100x40 frames after 100 warmups. Row/full modes
;;;; also render one/all view rows before composition. CPU and Lisp allocation
;;;; include frame allocation; they exclude core redisplay, encoding, transport,
;;;; client rendering and physical display. Run without other builds/benchmarks.
(ql:quickload :lem-daemon :silent t)
(when (uiop:getenv "LEM_OVERLAY_SOURCE") (load (uiop:getenv "LEM_OVERLAY_SOURCE")))
(defpackage :lem-bench/composition (:use :cl) (:local-nicknames (:d :lem-daemon)))
(in-package :lem-bench/composition)
(defun run-benchmark (name text mode)
  "Measure server row rendering and composition, excluding transport and presentation."
  (lem:with-current-buffers ()
    (let ((lem-core::*display-frame-map* (make-hash-table))
          (lem-core::*frames* nil)
          (implementation (make-instance 'd:daemon-implementation :width 100 :height 40)))
      (lem:with-implementation implementation
        (let ((frame (lem:make-frame nil))
              (objects (list (make-instance 'lem-core/display:text-object :string text :attribute nil))))
          (unwind-protect
               (progn
                 (lem:map-frame implementation frame)
                 (lem:setup-frame frame (lem:make-buffer "composition-benchmark"))
                 (let ((view (lem:window-view (lem:current-window))))
                   (dotimes (y 40)
                     (let ((row (d::make-cell-row 100 '("#FF0000" "#000000" 1))))
                       (d::overlay-text row 0 text '("#00FF00" nil 0))
                       (setf (gethash y (d::daemon-view-grid view)) row))))
                 (flet ((compose ()
                          (let ((view (lem:window-view (lem:current-window))))
                            (dotimes (y (ecase mode (:cursor 0) (:row 1) (:full 40)))
                              (lem-if:render-line implementation view 0 y objects 1)))
                          (d::implementation-screen implementation)))
                   (dotimes (i 100) (compose))
                   (sb-ext:gc :full t)
                   (let ((cpu (get-internal-run-time))
                         (bytes (sb-ext:get-bytes-consed)) (checksum 0))
                     (dotimes (i 3000)
                       (incf checksum (length (compose))))
                     (format t "~&COMPOSITION case=~a mode=~a cpu-ms=~,3f bytes=~d checksum=~d~%"
                             name mode
                             (* 1000d0 (/ (- (get-internal-run-time) cpu) internal-time-units-per-second))
                             (- (sb-ext:get-bytes-consed) bytes) checksum))))
            (lem:teardown-frame frame)
            (lem:unmap-frame implementation)))))))
(dolist (mode '(:cursor :row :full))
  (run-benchmark "ascii" "(defun example (x) (+ x 1)) ; ordinary editor text" mode)
  (run-benchmark "unicode"
                 (format nil "漢字 é e~c x~c~c~c mixed text"
                         (code-char #x301) #\Tab #\Newline (code-char #xe001))
                 mode))
