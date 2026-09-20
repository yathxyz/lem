;;;; Run from the repository root inside nix develop:
;;;; SDL_VIDEODRIVER=offscreen sbcl --noinform --no-sysinit --no-userinit \
;;;;   --non-interactive --load .qlot/setup.lisp --load this-file.lisp
;;;; Select a different SDL_VIDEODRIVER explicitly to investigate that display.
;;;; Windows are hidden. Successful renderer creation does not prove GPU use.
(defpackage :lem-bench/sdl-renderer
  (:use :cl))
(in-package :lem-bench/sdl-renderer)
(ql:quickload :sdl2 :silent t)

(defun report-renderer (flags)
  (handler-case
      (sdl2:with-window (window :title "Lem hidden renderer diagnostic"
                               :w 1000 :h 800 :flags '(:hidden))
        (sdl2:with-renderer (renderer window :flags flags)
          (let ((info (sdl2:get-renderer-info renderer)))
            (unwind-protect
                 (progn
                   (format t "~&Requested ~s; actual ~s~%" flags info)
                   (plus-c:c-let ((data sdl2-ffi:sdl-renderer-info :from info))
                     (when (member (data :name) '("opengl" "opengles" "opengles2")
                                   :test #'equal)
                       (let ((get-string (sdl2:gl-get-proc-address "glGetString")))
                         (unless (cffi:null-pointer-p get-string)
                           (format t "GL renderer: ~a~%GL version: ~a~%"
                                   (cffi:foreign-funcall-pointer get-string () :uint #x1f01 :string)
                                   (cffi:foreign-funcall-pointer get-string () :uint #x1f02 :string)))))))
              ;; The bindings allocate the returned info structure.
              (sdl2::free-render-info info)))
          (sdl2:set-render-draw-color renderer 10 20 30 255)
          (sdl2:render-clear renderer)
          (sdl2:render-present renderer)))
    (error (condition)
      (format t "~&Requested ~s failed: ~a~%" flags condition))))

(defun report-host-egl ()
  ;; A newer NixOS host driver may require symbols absent from a pinned
  ;; application's libc. Report the loader error directly: SDL's compatibility
  ;; layer can replace the original failure with an invalid-renderer error.
  (let ((path #p"/run/opengl-driver/lib/libEGL_mesa.so.0"))
    (when (probe-file path)
      (handler-case
          (let ((library (cffi:load-foreign-library path)))
            (unwind-protect (format t "~&Host Mesa EGL library loads: ~a~%" path)
              (cffi:close-foreign-library library)))
        (error (condition)
          (format t "~&Host Mesa EGL library failed to load: ~a~%" condition))))))

(unless (uiop:getenvp "SDL_VIDEODRIVER")
  (setf (uiop:getenv "SDL_VIDEODRIVER") "offscreen"))
(format t "~&Lisp: ~a ~a~%" (lisp-implementation-type) (lisp-implementation-version))
#+linux
(format t "glibc: ~a~%" (cffi:foreign-funcall "gnu_get_libc_version" :string))
(cffi:with-foreign-object (version :uint8 3)
  (cffi:foreign-funcall "SDL_GetVersion" :pointer version :void)
  (format t "SDL API version: ~d.~d.~d~%"
          (cffi:mem-aref version :uint8 0) (cffi:mem-aref version :uint8 1)
          (cffi:mem-aref version :uint8 2)))
(unless (zerop (sdl2:init* '(:video)))
  (error "SDL initialization failed: ~a" (cffi:foreign-funcall "SDL_GetError" :string)))
(unwind-protect
     (progn
       (format t "Video driver: ~a~%" (sdl2:get-current-video-driver))
       (dolist (flags '((:software) (:accelerated)))
         (report-renderer flags)))
  (sdl2:quit*))
(report-host-egl)
