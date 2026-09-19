;;;; Run from the repo root after loading .qlot/setup.lisp:
;;;; SDL_VIDEODRIVER=dummy nix develop --command sbcl --noinform
;;;;   --no-sysinit --no-userinit --non-interactive --load .qlot/setup.lisp
;;;;   --load scripts/bench/e2e/sdl-presentation.lisp
;;;; Optional LEM_SDL_SOURCE loads an older sdl-client.lisp for A/B measurement.
;;;; LEM_SDL_UPDATE_MODE selects cursor (default), row, or full updates.
;;;; LEM_SDL_PIXELS captures a frame before presentation; readback adds timing
;;;; overhead, so use it for pixel comparisons rather than performance runs.
;;;; Measures local socket write -> SDL_RenderPresent return, not monitor latency.
(if (uiop:getenv "LEM_SDL_SOURCE")
    (progn
      (ql:quickload '(:lem-daemon :lem-sdl2/client-support) :silent t)
      (load (uiop:getenv "LEM_SDL_SOURCE")))
    (ql:quickload :lem-daemon/sdl-client :silent t))

(defpackage :lem-bench/sdl-presentation
  (:use :cl)
  (:local-nicknames (:gui :lem-daemon/sdl-client)
                    (:protocol :lem-daemon/protocol)
                    (:transport :lem-daemon/transport)))
(in-package :lem-bench/sdl-presentation)

(defun save-pixels (renderer path)
  "Save a software-rendered frame for byte-for-byte A/B comparison."
  (cffi:with-foreign-objects ((width :int) (height :int))
    (assert (zerop (cffi:foreign-funcall "SDL_GetRendererOutputSize"
                                       :pointer (autowrap:ptr renderer)
                                       :pointer width :pointer height :int)))
    (let* ((pitch (* 4 (cffi:mem-ref width :int)))
           (size (* pitch (cffi:mem-ref height :int)))
           (bytes (make-array size :element-type '(unsigned-byte 8))))
      (cffi:with-foreign-object (pixels :uint8 size)
        (assert (zerop (cffi:foreign-funcall "SDL_RenderReadPixels"
                                           :pointer (autowrap:ptr renderer)
                                           :pointer (cffi:null-pointer)
                                           :uint32 sdl2:+pixelformat-argb8888+
                                           :pointer pixels :int pitch :int)))
        (dotimes (i size) (setf (aref bytes i) (cffi:mem-aref pixels :uint8 i))))
      (with-open-file (stream path :direction :output :if-exists :supersede
                                  :element-type '(unsigned-byte 8))
        (write-sequence bytes stream)))))


(defun benchmark-row (width counter &optional index)
  "Styled fixture row; COUNTER changes visible text in row/full update modes."
  (let ((row (protocol:make-object
              "text" (subseq (concatenate 'string
                                          (if counter
                                              (format nil "(defun example (x) (+ x 1)) ; ~3,'0d 漢 é" counter)
                                              "(defun example (x) (+ x 1)) ; 漢 é")
                                          (make-string width :initial-element #\Space))
                              0 (- width 1))
              "runs" #(#(0 "(defun" "#FF0000" "#0000FF" 1)
                       #(7 "example" "#00FF00" "#000000" 4)
                       #(15 "x" "#FFFF00" "#000000" 2)))))
    (when index (setf (gethash "row" row) index))
    row))

(defun expected-frame-p (screen x)
  ;; Window events may repaint an older screen while a socket update is in
  ;; flight. Only acknowledge a frame carrying that update's cursor position.
  (let ((cursor (gui::graphical-screen-cursor screen)))
    (and cursor (eql x (protocol:field cursor "x")))))

(defun run-benchmark ()
  "Exercise the real graphical client with an isolated local socket peer."
  (let* ((mode (or (uiop:getenv "LEM_SDL_UPDATE_MODE") "cursor"))
         (old-runtime (uiop:getenv "XDG_RUNTIME_DIR"))
         (root (merge-pathnames (format nil "lem-sdl-bench-~d/" (sb-posix:getpid))
                               (uiop:temporary-directory)))
         (backend (transport:require-local-backend))
         (listener nil) (local nil) (peer nil) (producer nil)
         (presented (bt2:make-semaphore :count 0))
         (original-draw (symbol-function 'gui::draw-screen))
         (original-present (symbol-function 'sdl2:render-present))
         (drawing-screen nil) (sent-x nil)
         (sent-at nil) (samples '()) (producer-error nil))
    (assert (member mode '("cursor" "row" "full") :test #'equal))
    (unwind-protect
         (progn
           (setf (uiop:getenv "XDG_RUNTIME_DIR") (namestring root)
                 listener (transport:open-local-listener backend "bench" 1)
                 local (transport:connect-local backend "bench")
                 peer (transport:accept-local-connection listener))
           (setf (symbol-function 'gui::draw-screen)
                 (lambda (&rest arguments)
                   (setf drawing-screen (first arguments))
                   (unwind-protect (apply original-draw arguments)
                     (setf drawing-screen nil))
                   (when (and sent-at (expected-frame-p (first arguments) sent-x))
                     (push (* 1000d0 (/ (- (get-internal-real-time) sent-at)
                                       internal-time-units-per-second)) samples)
                     (setf sent-at nil)
                     (bt2:signal-semaphore presented))))
           (when (uiop:getenv "LEM_SDL_PIXELS")
             (setf (symbol-function 'sdl2:render-present)
                   (lambda (renderer)
                     (when (and sent-at drawing-screen (= 1 (length samples))
                                (expected-frame-p drawing-screen sent-x))
                       (save-pixels renderer (uiop:getenv "LEM_SDL_PIXELS")))
                     (funcall original-present renderer))))
           (setf producer
                 (bt2:make-thread
                  (lambda ()
                    (handler-case
                        (let* ((stream (transport:local-connection-stream peer))
                               (attach (protocol:read-message stream))
                               (width (protocol:field attach "width"))
                               (height (protocol:field attach "height")))
                          (dotimes (i 121)
                            ;; Vary arrival phase relative to the old 10 ms poll.
                            (sleep (/ (1+ (mod (* i 7) 9)) 1000d0))
                            (let ((message
                                    (protocol:make-object
                                     "type" "screen" "full" (or (zerop i) (equal mode "full"))
                                     "foreground" "#FFFFFF" "background" "#000000"
                                     "cursor" (protocol:make-object "x" (mod i width) "y" 0
                                                                    "shape" "box" "color" "#FFFFFF"))))
                              (cond ((or (zerop i) (equal mode "full"))
                                     (setf (gethash "rows" message)
                                           (make-array height :initial-element
                                                       (benchmark-row width (unless (equal mode "cursor") i)))))
                                    ((equal mode "row")
                                     (setf (gethash "changes" message) (vector (benchmark-row width i 0))))
                                    (t (setf (gethash "changes" message) #())))
                              (setf sent-x (mod i width) sent-at (get-internal-real-time))
                              (protocol:write-message message stream)
                              (unless (bt2:wait-on-semaphore presented :timeout 5)
                                (error "Screen update did not wake the SDL client"))))
                          (protocol:write-message (protocol:make-object "type" "close") stream))
                      (error (condition)
                        (setf producer-error condition)
                        (sdl2:push-event :quit))))
                  :name "SDL benchmark peer"))
           (let ((connection (make-instance 'lem-daemon/client::client-connection
                                           :transport local
                                           :stream (transport:local-connection-stream local))))
             (sdl2:with-init (:video)
               (gui::call-with-graphical-window connection nil nil)))
           (bt2:join-thread producer)
           (setf producer nil)
           (when producer-error (error producer-error))
           ;; The first frame includes glyph/resource warmup.
           (let* ((ordered (sort (cdr (nreverse samples)) #'<))
                  (n (length ordered)))
             (assert (= 120 n))
             (format t "~&SDL socket-to-present ms: n=~d median=~,3f p95=~,3f max=~,3f~%"
                     n (nth (floor n 2) ordered) (nth (floor (* n .95)) ordered)
                     (car (last ordered)))))
      (setf (symbol-function 'gui::draw-screen) original-draw
            (symbol-function 'sdl2:render-present) original-present)
      (when producer (bt2:join-thread producer))
      (when local (transport:close-local-connection local))
      (when peer (transport:close-local-connection peer))
      (when listener (transport:close-local-listener listener))
      (setf (uiop:getenv "XDG_RUNTIME_DIR") old-runtime)
      (when (uiop:directory-exists-p root)
        (uiop:delete-directory-tree root :validate t)))))

(run-benchmark)
