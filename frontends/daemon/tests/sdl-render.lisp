(defpackage :lem-daemon/tests/sdl-render
  (:use :cl :rove)
  (:local-nicknames (:gui :lem-daemon/sdl-client)
                    (:protocol :lem-daemon/protocol)))
(in-package :lem-daemon/tests/sdl-render)

;; Exercise internal rendering with a real software renderer, capturing pixels
;; BEFORE presentation: SDL does not preserve the window backbuffer afterward.
(defun read-pixels (renderer)
  (multiple-value-bind (width height) (sdl2:get-renderer-output-size renderer)
    (let* ((pitch (* width 4)) (size (* pitch height))
           (bytes (make-array size :element-type '(unsigned-byte 8))))
      (cffi:with-foreign-object (pixels :uint8 size)
        (assert (zerop (cffi:foreign-funcall "SDL_RenderReadPixels"
                                           :pointer (autowrap:ptr renderer)
                                           :pointer (cffi:null-pointer)
                                           :uint32 sdl2:+pixelformat-argb8888+
                                           :pointer pixels :int pitch :int)))
        (dotimes (i size) (setf (aref bytes i) (cffi:mem-aref pixels :uint8 i))))
      bytes)))

(defun cursor (x y shape &optional (color "#FFFFFF"))
  (protocol:make-object "x" x "y" y "shape" shape "color" color))

(defun screen-message (&key full (height 10) cursor changes
                            (foreground "#FFFFFF") (background "#000000"))
  (let ((message (protocol:make-object "full" full "foreground" foreground
                                      "background" background "cursor" cursor
                                      "changes" (or changes #()))))
    (when full
      (setf (gethash "rows" message)
            (make-array height :initial-element
                        (protocol:make-object
                         "text" "(defun example (x) (+ x 1)) ; 漢 é       "
                         "runs" #(#(0 "(defun" "#FF0000" "#0000FF" 1)
                                  #(7 "example" "#00FF00" "#000000" 4)
                                  #(15 "x" "#FFFF00" "#000000" 2))))))
    message))

(defun exercise-renderer (window renderer fonts)
  (let ((screen (gui::make-graphical-screen)) (frame (gui::make-frame-cache))
        (reference-cache (make-hash-table :test 'equal))
        (candidate-cache (make-hash-table :test 'equal))
        (original-present (symbol-function 'sdl2:render-present))
        (original-glyph (symbol-function 'gui::draw-glyph))
        (original-create (symbol-function 'sdl2:create-texture))
        (pixels nil) (glyphs 0) (attempts 0))
    (unwind-protect
         (progn
           (setf (symbol-function 'sdl2:render-present)
                 (lambda (renderer)
                   (assert (cffi:null-pointer-p
                            (cffi:foreign-funcall "SDL_GetRenderTarget"
                                                 :pointer (autowrap:ptr renderer) :pointer)))
                   (setf pixels (read-pixels renderer))
                   (funcall original-present renderer))
                 (symbol-function 'gui::draw-glyph)
                 (lambda (&rest arguments) (incf glyphs) (apply original-glyph arguments)))
           (flet ((check-frame (label message &key unchanged)
                    (gui::update-screen screen message)
                    ;; NIL frame cache always performs the full reference repaint.
                    (gui::draw-screen screen renderer fonts reference-cache)
                    (let ((expected pixels))
                      (setf glyphs 0)
                      (gui::draw-screen screen renderer fonts candidate-cache frame)
                      (ok (equalp expected pixels) label)
                      (when unchanged
                        (ok (zerop glyphs) "an unchanged frame performs no glyph draws")))))
             (sdl2:set-window-size window 420 240)
             (check-frame "initial styled Unicode frame" (screen-message :full t :cursor (cursor 0 0 "box")))
             (ok (gui::frame-cache-texture frame) "the software renderer exercises the retained target")
             (check-frame "unchanged frame" (screen-message :cursor (cursor 0 0 "box")) :unchanged t)
             (check-frame "cursor moves to another row" (screen-message :cursor (cursor 4 2 "box")))
             (check-frame "cursor becomes a bar" (screen-message :cursor (cursor 5 3 "bar" "#FF00FF")))
             (check-frame "cursor becomes an underline" (screen-message :cursor (cursor 1 4 "underline")))
             (check-frame "cursor disappears" (screen-message))
             (check-frame "box cursor over emoji beside wide and combining glyphs"
                          (screen-message :cursor (cursor 3 2 "box") :changes
                                          (vector (protocol:make-object "row" 2 "text" "漢é😀⠿" "runs" #()))))
             (check-frame "underline cursor spans a wide glyph"
                          (screen-message :cursor (cursor 3 2 "underline")))
             (check-frame "shorter row clears old glyphs and faces"
                          (screen-message :changes
                                          (vector (protocol:make-object "row" 2 "text" "short" "runs" #()))))
             (check-frame "an empty row clears its entire previous contents"
                          (screen-message :changes
                                          (vector (protocol:make-object "row" 2 "text" "" "runs" #()))))
             (check-frame "theme foreground and background invalidate unchanged rows"
                          (screen-message :foreground "#00FFFF" :background "#202040"))
             (check-frame "fewer rows clear the removed bottom rows" (screen-message :full t :height 5))
             (check-frame "rows beyond the window are clipped" (screen-message :full t :height 15))
             (ok (not (gui::frame-cache-valid-p frame)) "dense updates use direct repaint")
             (check-frame "sparse update after a dense frame rebuilds the stale target"
                          (screen-message :cursor (cursor 2 2 "box")))
             (ok (gui::frame-cache-valid-p frame))
             (check-frame "rebuilt target is reusable"
                          (screen-message :cursor (cursor 2 2 "box")) :unchanged t)
             (sdl2:set-window-size window 600 340)
             (check-frame "window growth reallocates the target" (screen-message))
             (sdl2:set-window-size window 360 180)
             (check-frame "window shrink reallocates the target" (screen-message))
             (gui::clear-frame-cache frame)
             (gui::clear-glyphs candidate-cache)
             (check-frame "renderer reset rebuilds cached pixels" (screen-message))
             (gui::clear-frame-cache frame)
             (setf (symbol-function 'sdl2:create-texture)
                   (lambda (&rest arguments)
                     (declare (ignore arguments))
                     (incf attempts)
                     (error 'sdl2::sdl-error :string "injected target allocation failure")))
             (check-frame "target allocation failure uses full repaint" (screen-message))
             (check-frame "fallback remains correct on the next update" (screen-message :cursor (cursor 2 1 "box")))
             (ok (= 1 attempts) "failed target allocation is not retried on each frame")
             (ok (null (gui::frame-cache-texture frame)))))
      (setf (symbol-function 'sdl2:render-present) original-present
            (symbol-function 'gui::draw-glyph) original-glyph
            (symbol-function 'sdl2:create-texture) original-create)
      (gui::clear-frame-cache frame)
      (gui::clear-glyphs reference-cache)
      (gui::clear-glyphs candidate-cache))))

(deftest retained-frame-matches-full-repaint
  (unless (member (uiop:getenv "SDL_VIDEODRIVER") '("dummy" "x11") :test #'equal)
    (error "Use SDL_VIDEODRIVER=dummy, or x11 with a private Xvfb display"))
  (let ((original (symbol-function 'gui::graphical-event-loop)))
    (unwind-protect
         (progn
           (setf (symbol-function 'gui::graphical-event-loop)
                 (lambda (connection files wait-p window renderer fonts)
                   (declare (ignore connection files wait-p))
                   (exercise-renderer window renderer fonts)))
           ;; Use the production single-thread entry point so assertion state
           ;; and SDL initialization/rendering/teardown stay on this test thread.
           (gui:run-graphical nil nil nil))
      (setf (symbol-function 'gui::graphical-event-loop) original))))
