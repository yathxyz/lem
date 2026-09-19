;;;; Instrument only this disposable source-loaded client. The daemon and SDL
;;;; event loop are unmodified. Python owns the private display and ack pipe.
(ql:quickload :lem-daemon/sdl-client :silent t)
(assert (equal (truename (uiop:getenv "LEM_SDL_REPO"))
               (truename (asdf:system-source-directory :lem))))
(defpackage :lem-bench/sdl-input
  (:use :cl)
  (:local-nicknames (:gui :lem-daemon/sdl-client)
                    (:client :lem-daemon/client)))
(in-package :lem-bench/sdl-input)

(defvar *drawing-screen* nil)

(defun run-probe ()
  (let ((output (sb-sys:make-fd-stream
                 (parse-integer (uiop:getenv "LEM_SDL_ACK_FD"))
                 :output t :element-type 'character :buffering :line :auto-close t))
        (original-send (symbol-function 'client::send-input))
        (original-draw (symbol-function 'gui::draw-screen))
        (original-present (symbol-function 'sdl2:render-present))
        (sequence 0) (pending nil) (ready nil))
    (labels ((report-frame (screen finished)
               (let ((line (loop :for row :across (gui::graphical-screen-rows screen)
                                 :for text := (lem-daemon::cell-row-string row)
                                 :when (search "BENCH_TARGET" text) :return text)))
                 (when (and line
                            (or (not ready)
                                (and pending
                                     (eq (oddp sequence)
                                         (not (null (search "xBENCH_TARGET" line)))))))
                   (yason:encode
                    (lem-daemon/protocol:make-object
                     "sequence" sequence
                     "inserted" (not (null (search "xBENCH_TARGET" line)))
                     "client_send_to_present_ms"
                     (if pending (* 1000d0 (/ (- finished pending)
                                              (sdl2:get-performance-frequency))) 0)
                     "cpu" (get-internal-run-time)
                     "bytes" (sb-ext:get-bytes-consed)
                     "gc" sb-ext:*gc-run-time*
                     "units" internal-time-units-per-second)
                    output)
                   (terpri output)
                   (finish-output output)
                   (setf pending nil ready t)))))
      (unwind-protect
           (progn
             (setf (symbol-function 'client::send-input)
                   (lambda (connection event)
                     (when (lem:key-p event)
                       (assert (and ready (not pending)))
                       (assert (string-equal (lem:key-sym event)
                                             (if (evenp sequence) "x" "Backspace")))
                       (setf pending (sdl2:get-performance-counter))
                       (incf sequence))
                     (funcall original-send connection event)))
             (setf (symbol-function 'gui::draw-screen)
                   (lambda (&rest arguments)
                     (let ((*drawing-screen* (first arguments)))
                       (apply original-draw arguments))))
             (setf (symbol-function 'sdl2:render-present)
                   (lambda (renderer)
                     (funcall original-present renderer)
                     (when *drawing-screen*
                       (report-frame *drawing-screen* (sdl2:get-performance-counter)))))
             (assert (zerop (gui:run-graphical
                            (client::connect-client "sdl-input-bench")
                            (list (uiop:getenv "LEM_SDL_DOCUMENT")) nil)))
             (assert (not pending)))
        (setf (symbol-function 'client::send-input) original-send
              (symbol-function 'gui::draw-screen) original-draw
              (symbol-function 'sdl2:render-present) original-present)
        (close output)))))

;; Discard compilation debris before opening the graphical client.
(sb-ext:gc :full t)
(run-probe)
