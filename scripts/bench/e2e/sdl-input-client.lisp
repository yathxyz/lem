;;;; Instrument only this disposable source-loaded client. The daemon and SDL
;;;; event loop handle the input normally. Python owns the private display/pipes.
(ql:quickload :lem-daemon/sdl-client :silent t)
(assert (equal (truename (uiop:getenv "LEM_SDL_REPO"))
               (truename (asdf:system-source-directory :lem))))
(when (uiop:getenv "LEM_SDL_SOURCE")
  (load (uiop:getenv "LEM_SDL_SOURCE") :verbose nil :print nil))
(defpackage :lem-bench/sdl-input
  (:use :cl)
  (:local-nicknames (:gui :lem-daemon/sdl-client)
                    (:client :lem-daemon/client)))
(in-package :lem-bench/sdl-input)

(defvar *drawing-screen* nil)

(defun renderer-description (renderer)
  (let ((info (sdl2:get-renderer-info renderer)))
    (unwind-protect
         (plus-c:c-let ((data sdl2-ffi:sdl-renderer-info :from info))
           (let ((result (lem-daemon/protocol:make-object
                          "name" (data :name) "flags" (data :flags)
                          "batching_hint" (sdl2-ffi.functions:sdl-get-hint "SDL_RENDER_BATCHING")
                          "video_driver" (sdl2:get-current-video-driver))))
             (when (member (data :name) '("opengl" "opengles" "opengles2") :test #'equal)
               (let ((get-string (sdl2:gl-get-proc-address "glGetString")))
                 (assert (not (cffi:null-pointer-p get-string)))
                 (setf (gethash "gl_renderer" result)
                       (cffi:foreign-funcall-pointer get-string () :uint #x1f01 :string)
                       (gethash "gl_version" result)
                       (cffi:foreign-funcall-pointer get-string () :uint #x1f02 :string))))
             result))
      (sdl2::free-render-info info))))

(defun call-with-native-input (window function)
  (let* ((fd (parse-integer (uiop:getenv "LEM_SDL_INPUT_FD")))
         (input (sb-sys:make-fd-stream fd :input t :element-type '(unsigned-byte 8)
                                        :buffering :none :auto-close t))
         (library (cffi:load-foreign-library (uiop:getenv "LEM_SDL_INPUT_LIBRARY")))
         (push-key (cffi:foreign-symbol-pointer "lem_bench_push_key" :library library))
         ;; CFFI's SBCL backend ignores FOREIGN-SYMBOL-POINTER's :LIBRARY.
         ;; Native dlsym is necessary to distinguish the SDL2/SDL3 ABIs.
         (backend (let ((handle (cffi:foreign-funcall "dlopen" :string "libSDL3.so.0"
                                                              :int 1 :pointer)))
                    (when (cffi:null-pointer-p handle)
                      (error "Cannot load SDL3: ~a" (cffi:foreign-funcall "dlerror" :string)))
                    handle))
         (push-event (cffi:foreign-funcall "dlsym" :pointer backend
                                                   :string "SDL_PushEvent" :pointer))
         (was-init (cffi:foreign-funcall "dlsym" :pointer backend
                                                 :string "SDL_WasInit" :pointer))
         (window-id (sdl2:get-window-id window))
         (lock (bt2:make-lock :name "SDL probe input"))
         (stopping nil) (failure nil) (thread nil))
    (unwind-protect
         (progn
           (assert (and (not (cffi:null-pointer-p push-event))
                        (not (cffi:null-pointer-p was-init))))
           (assert (not (zerop (cffi:foreign-funcall-pointer was-init () :uint32 #x20 :uint32)))
                   () "The native event probe requires an initialized SDL2-compat/SDL3 runtime")
           (setf thread
                 (bt2:make-thread
                  (lambda ()
                    (handler-case
                        (loop
                          (when (bt2:with-lock-held (lock) stopping) (return))
                          ;; The finite wait permits bounded cleanup after a GUI
                          ;; error, even if Python is still waiting for its ack.
                          (when (sb-sys:wait-until-fd-usable fd :input 1 nil)
                            (let ((key (read-byte input nil nil)))
                              (unless key (return))
                              (assert (member key '(120 8)))
                              (unless (= 1 (cffi:foreign-funcall-pointer push-key ()
                                            :uint32 window-id :uint8 key :pointer push-event :int))
                                (error "Native SDL input was rejected: ~a"
                                       (cffi:foreign-funcall "SDL_GetError" :string))))))
                      (error (condition)
                        (setf failure condition)
                        (sdl2:push-event :quit))))
                  :name "SDL probe input"))
           (funcall function))
      (bt2:with-lock-held (lock) (setf stopping t))
      (when thread (bt2:join-thread thread))
      (close input)
      ;; Keep the helper loaded until process exit: queued SDL text events
      ;; reference its static string, including on an early GUI failure.
      (when failure (error failure)))))

(defun run-probe ()
  (let ((output (sb-sys:make-fd-stream
                 (parse-integer (uiop:getenv "LEM_SDL_ACK_FD"))
                 :output t :element-type 'character :buffering :line :auto-close t))
        (original-send (symbol-function 'client::send-input))
        (original-draw (symbol-function 'gui::draw-screen))
        (original-present (symbol-function 'sdl2:render-present))
        (original-loop (symbol-function 'gui::graphical-event-loop))
        (renderer-info nil)
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
                   (let ((reply
                           (lem-daemon/protocol:make-object
                            "sequence" sequence
                            "inserted" (not (null (search "xBENCH_TARGET" line)))
                            "client_send_to_present_ms"
                            (if pending (* 1000d0 (/ (- finished pending)
                                                     (sdl2:get-performance-frequency))) 0)
                            "cpu" (get-internal-run-time)
                            "bytes" (sb-ext:get-bytes-consed)
                            "gc" sb-ext:*gc-run-time*
                            "units" internal-time-units-per-second)))
                     (unless ready (setf (gethash "renderer" reply) renderer-info))
                     (yason:encode reply output))
                   (terpri output)
                   (finish-output output)
                   (setf pending nil ready t)))))
      (unwind-protect
           (progn
             (setf (symbol-function 'gui::graphical-event-loop)
                   (lambda (connection files wait-p window renderer fonts)
                     (setf renderer-info (renderer-description renderer))
                     (flet ((run-loop ()
                              (funcall original-loop connection files wait-p window renderer fonts)))
                       (if (uiop:getenv "LEM_SDL_INPUT_FD")
                           (call-with-native-input window #'run-loop)
                           (run-loop)))))
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
              (symbol-function 'sdl2:render-present) original-present
              (symbol-function 'gui::graphical-event-loop) original-loop)
        (close output)))))

;; Discard compilation debris before opening the graphical client.
(sb-ext:gc :full t)
(run-probe)
