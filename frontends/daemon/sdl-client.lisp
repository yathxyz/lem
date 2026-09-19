(defpackage :lem-daemon/sdl-client
  (:use :cl)
  (:local-nicknames (:client :lem-daemon/client)
                    (:protocol :lem-daemon/protocol)
                    (:font :lem-sdl2/font)
                    (:keyboard :lem-sdl2/keyboard))
  (:export :run-graphical))
(in-package :lem-daemon/sdl-client)

(defstruct graphical-screen
  rows (foreground "#FFFFFF") (background "#000000") cursor mouse-enabled)

(defun decode-row (data)
  (let* ((text (protocol:field data "text"))
         (row (lem-daemon::make-cell-row (lem:string-width text))))
    (lem-daemon::overlay-text row 0 text)
    (loop :for run :in (coerce (protocol:field data "runs") 'list)
          :do (destructuring-bind (column text foreground background flags)
                  (coerce run 'list)
                (check-type flags (integer 0 7))
                (lem-daemon::overlay-text row column text
                                         (list foreground background flags))))
    row))

(defun update-screen (screen message)
  (when (eq t (protocol:field message "full"))
    (setf (graphical-screen-rows screen)
          (map 'vector #'decode-row (protocol:field message "rows"))))
  (loop :for change :in (coerce (protocol:field message "changes") 'list)
        :for index := (protocol:field change "row")
        :do (unless (and (integerp index)
                         (<= 0 index (1- (length (graphical-screen-rows screen)))))
              (error "Invalid graphical screen row: ~s" index))
            (setf (aref (graphical-screen-rows screen) index) (decode-row change)))
  (setf (graphical-screen-foreground screen) (protocol:field message "foreground")
        (graphical-screen-background screen) (protocol:field message "background")
        (graphical-screen-cursor screen) (protocol:field message "cursor")
        (graphical-screen-mouse-enabled screen) (eq t (protocol:field message "mouse"))))

(defun set-color (renderer color)
  (let ((color (lem:parse-color color)))
    (sdl2:set-render-draw-color renderer (lem:color-red color)
                                (lem:color-green color) (lem:color-blue color) 255)))

(defun fill-rectangle (renderer color x y width height)
  (set-color renderer color)
  (sdl2:with-rects ((rectangle x y width height))
    (sdl2:render-fill-rect renderer rectangle)))

(defun glyph-font (fonts text bold)
  (let* ((character (char text 0))
         (type (lem-core::char-type character))
         (latin (if bold (font:font-latin-bold-font fonts)
                    (font:font-latin-normal-font fonts))))
    (case type
      (:icon (or (lem-sdl2/icon-font:icon-font character (font:default-font-size))
                 (font:font-emoji-font fonts)))
      (:emoji (font:font-emoji-font fonts))
      (:braille (font:font-braille-font fonts))
      ((:latin :zero-width :control) latin)
      (otherwise
       (if (and (<= (char-code character) #xFFFF)
                (plusp (cffi:foreign-funcall "TTF_GlyphIsProvided"
                                             :pointer (autowrap:ptr latin)
                                             :unsigned-short (char-code character) :int)))
           latin
           (if bold (font:font-cjk-bold-font fonts) (font:font-cjk-normal-font fonts)))))))

(defun clear-glyphs (cache)
  (maphash (lambda (key texture) (declare (ignore key)) (sdl2:destroy-texture texture)) cache)
  (clrhash cache))

(defun draw-glyph (renderer cache fonts text foreground bold x y width height)
  (unless (every (lambda (c) (char= c #\Space)) text)
    (let* ((key (list text foreground bold))
           (texture
             (or (gethash key cache)
                 (let* ((color (lem:parse-color foreground))
                        (surface
                          (cffi:with-foreign-string (string text)
                            (sdl2-ttf:render-utf8-blended
                             (glyph-font fonts text bold) string
                             (lem:color-red color) (lem:color-green color)
                             (lem:color-blue color) 255))))
                   (trivial-garbage:cancel-finalization surface)
                   (unwind-protect
                        (setf (gethash key cache)
                              (sdl2:create-texture-from-surface renderer surface))
                     (sdl2:free-surface surface))))))
      (sdl2:with-rects ((rectangle x y width height))
        (sdl2:render-copy renderer texture :dest-rect rectangle)))))

(defun draw-screen-rows (screen renderer fonts cache &optional dirty)
  "Paint all rows, or only DIRTY rows after clearing their previous pixels."
  (let ((cw (font:font-char-width fonts)) (ch (font:font-char-height fonts))
        (cursor (graphical-screen-cursor screen)))
    (loop :for row :across (graphical-screen-rows screen)
          :for y :from 0
          :when (or (null dirty) (= 1 (aref dirty y)))
            :do (when dirty
                  (fill-rectangle renderer (graphical-screen-background screen)
                                  0 (* y ch) (nth-value 0 (sdl2:get-renderer-output-size renderer)) ch))
                (loop :for text :across (lem-daemon::cell-row-cells row)
                    :for face :across (lem-daemon::cell-row-faces row)
                    :for x :from 0
                    :when (stringp text)
                      :do (let* ((flags (or (third face) 0))
                                 (fg (or (first face) (graphical-screen-foreground screen)))
                                 (bg (or (second face) (graphical-screen-background screen)))
                                 (width (* cw (lem:string-width text)))
                                 (cursor-p (and cursor (= x (protocol:field cursor "x"))
                                                (= y (protocol:field cursor "y")))))
                            (when (logtest 4 flags) (rotatef fg bg))
                            (when (and cursor-p (equal "box" (protocol:field cursor "shape")))
                              (setf fg (graphical-screen-background screen)
                                    bg (protocol:field cursor "color")))
                            ;; RENDER-CLEAR already painted the default background.
                            ;; Resolve inverse video and the box cursor first.
                            (unless (equal bg (graphical-screen-background screen))
                              (fill-rectangle renderer bg (* x cw) (* y ch) width ch))
                            (draw-glyph renderer cache fonts text fg (logtest 1 flags)
                                        (* x cw) (* y ch) width ch)
                            (when (logtest 2 flags)
                              (fill-rectangle renderer fg (* x cw) (+ (* y ch) ch -2) width 1))
                            (when cursor-p
                              (cond
                                ((equal "bar" (protocol:field cursor "shape"))
                                 (fill-rectangle renderer (protocol:field cursor "color")
                                                 (* x cw) (* y ch) 2 ch))
                                ((equal "underline" (protocol:field cursor "shape"))
                                 (fill-rectangle renderer (protocol:field cursor "color")
                                                 (* x cw) (+ (* y ch) ch -2) width 2)))))))))

;; UPDATE-SCREEN replaces decoded rows rather than mutating them. Retain their
;; identities with a private render target; the window backbuffer is still
;; cleared and completely repainted on every presentation.
(defstruct frame-cache
  texture rows foreground background cursor fonts width height
  cell-width cell-height attempted-p valid-p)

(defun clear-frame-cache (frame)
  (when (frame-cache-texture frame)
    (sdl2:destroy-texture (frame-cache-texture frame)))
  (setf (frame-cache-texture frame) nil
        (frame-cache-rows frame) nil
        (frame-cache-attempted-p frame) nil
        (frame-cache-valid-p frame) nil))

(defun draw-screen (screen renderer fonts cache &optional frame)
  (when (> (hash-table-count cache) 2048) (clear-glyphs cache))
  (multiple-value-bind (width height) (sdl2:get-renderer-output-size renderer)
    (when (and frame (or (/= width (or (frame-cache-width frame) 0))
                        (/= height (or (frame-cache-height frame) 0))))
      (clear-frame-cache frame)
      (setf (frame-cache-width frame) width (frame-cache-height frame) height))
    (when (and frame (not (frame-cache-attempted-p frame)))
      (setf (frame-cache-attempted-p frame) t)
      (when (plusp (cffi:foreign-funcall "SDL_RenderTargetSupported"
                                       :pointer (autowrap:ptr renderer) :int))
        ;; Unsupported or unavailable target storage keeps the complete repaint
        ;; path. Retry only after resize/reset, not on every typed character.
        (handler-case
            (setf (frame-cache-texture frame)
                  (sdl2:create-texture renderer :argb8888 :target width height))
          (sdl2::sdl-error () nil))))
    (let* ((texture (and frame (frame-cache-texture frame)))
           (rows (graphical-screen-rows screen))
           (cursor (graphical-screen-cursor screen))
           (description (when cursor
                          (mapcar (lambda (key) (protocol:field cursor key))
                                  '("x" "y" "shape" "color"))))
           (full (or (null texture) (null (frame-cache-rows frame))
                     (/= (length rows) (length (frame-cache-rows frame)))
                     (not (eq fonts (frame-cache-fonts frame)))
                     (not (eql (font:font-char-width fonts) (frame-cache-cell-width frame)))
                     (not (eql (font:font-char-height fonts) (frame-cache-cell-height frame)))
                     (not (equal (graphical-screen-foreground screen) (frame-cache-foreground frame)))
                     (not (equal (graphical-screen-background screen) (frame-cache-background frame)))))
           (dirty (unless full (make-array (length rows) :element-type 'bit :initial-element 0)))
           (use-target nil))
      (unless full
        (loop :for row :across rows :for old :across (frame-cache-rows frame) :for y :from 0
              :unless (eq row old) :do (setf (aref dirty y) 1))
        (unless (equal description (frame-cache-cursor frame))
          (dolist (cursor (list description (frame-cache-cursor frame)))
            (when (and cursor (<= 0 (second cursor)) (< (second cursor) (length rows)))
              (setf (aref dirty (second cursor)) 1)))))
      ;; A mostly changed screen costs less to paint directly than to rebuild
      ;; and copy a target. Keep the last presented row snapshot, but mark the
      ;; texture stale so the next sparse update rebuilds it once before reuse.
      (setf use-target
            (and texture
                 (not (and (frame-cache-rows frame)
                           (or full (>= (* 2 (count 1 dirty)) (length rows)))))))
      (when (and use-target (not (frame-cache-valid-p frame)))
        (setf full t dirty nil))
      (when frame (setf (frame-cache-valid-p frame) nil))
      (unwind-protect
           (progn
             (when use-target (sdl2:set-render-target renderer texture))
             (when (or full (not use-target))
               (set-color renderer (graphical-screen-background screen))
               (sdl2:render-clear renderer))
             (draw-screen-rows screen renderer fonts cache (and use-target dirty)))
        (when use-target (sdl2:set-render-target renderer (cffi:null-pointer))))
      (when texture
        (setf (frame-cache-rows frame) (copy-seq rows)
              (frame-cache-cursor frame) description
              (frame-cache-fonts frame) fonts
              (frame-cache-cell-width frame) (font:font-char-width fonts)
              (frame-cache-cell-height frame) (font:font-char-height fonts)
              (frame-cache-foreground frame) (graphical-screen-foreground screen)
              (frame-cache-background frame) (graphical-screen-background screen)
              (frame-cache-valid-p frame) use-target))
      (when use-target
        (set-color renderer (graphical-screen-background screen))
        (sdl2:render-clear renderer)
        (sdl2:render-copy renderer texture))
      (sdl2:render-present renderer))))

(defstruct incoming
  (lock (bt2:make-lock :name "lemclient/sdl-incoming"))
  messages (count 0) stopping-p reader-started-p notify)

(define-condition stop-screen-reader (condition) ())

(defun enqueue-screen-message (incoming message)
  "Queue a screen message or reader error and wake the UI on an empty queue.
Notify outside the lock so the consumer can immediately drain the queue."
  (let ((notify
          (bt2:with-lock-held ((incoming-lock incoming))
            (unless (incoming-stopping-p incoming)
              (when (and (>= (incoming-count incoming) 256)
                         (not (typep message 'error)))
                (error "Graphical client cannot keep up with daemon output"))
              (prog1 (and (null (incoming-messages incoming))
                          (incoming-notify incoming))
                (push message (incoming-messages incoming))
                (incf (incoming-count incoming)))))))
    (when notify (funcall notify))))

(defun read-screens (connection incoming)
  (handler-case
      (unwind-protect
           (handler-case
               (progn
                 (bt2:with-lock-held ((incoming-lock incoming))
                   (when (incoming-stopping-p incoming) (return-from read-screens))
                   ;; Publish readiness only after the stop handler is installed.
                   (setf (incoming-reader-started-p incoming) t))
                 (loop :for message := (protocol:read-message (client::client-stream connection))
                       :do (unless message (error "Daemon disconnected before closing this client"))
                           (enqueue-screen-message incoming message)
                       :until (equal "close" (protocol:field message "type"))))
             (error (condition)
               (enqueue-screen-message incoming condition)))
        (bt2:with-lock-held ((incoming-lock incoming))
          (setf (incoming-reader-started-p incoming) nil)))
    (stop-screen-reader () nil)))

(defun stop-screen-reader (incoming reader)
  (let ((started-p
          (bt2:with-lock-held ((incoming-lock incoming))
            (setf (incoming-stopping-p incoming) t)
            (incoming-reader-started-p incoming))))
    (when reader
      ;; Closing an FD stream in another thread does not reliably wake an
      ;; already-blocked read. Cancel that read through its installed handler,
      ;; then close the stream after the reader has released it.
      (when (and started-p (bt2:thread-alive-p reader))
        (ignore-errors
          (bt2:interrupt-thread
           reader (lambda ()
                    (when (incoming-reader-started-p incoming)
                      (signal 'stop-screen-reader))))))
      (bt2:join-thread reader))))

(defun take-messages (incoming)
  (bt2:with-lock-held ((incoming-lock incoming))
    (prog1 (nreverse (incoming-messages incoming))
      (setf (incoming-messages incoming) nil (incoming-count incoming) 0))))

(defun grid-size (window fonts)
  (multiple-value-bind (width height) (sdl2:get-window-size window)
    (values (max 20 (min 1000 (floor width (font:font-char-width fonts))))
            (max 5 (min 1000 (floor height (font:font-char-height fonts)))))))

(defun send-mouse (connection screen fonts kind x y &key (button 0) (clicks 1) (dx 0) (dy 0))
  (let ((column (floor x (font:font-char-width fonts)))
        (row (floor y (font:font-char-height fonts))))
    (when (and (graphical-screen-mouse-enabled screen)
               (<= 0 column 999) (<= 0 row 999) (<= 0 button 4))
      (client::send-input
       connection
       (list :mouse (protocol:make-object "kind" kind "x" column "y" row
                                          "button" button "clicks" (min 3 (max 1 clicks))
                                          "dx" dx "dy" dy))))))

(defun clipboard-text ()
  (let ((pointer (cffi:foreign-funcall "SDL_GetClipboardText" :pointer)))
    (when (cffi:null-pointer-p pointer) (error "SDL could not read the clipboard"))
    (unwind-protect (cffi:foreign-string-to-lisp pointer :encoding :utf-8)
      (cffi:foreign-funcall "SDL_free" :pointer pointer :void))))

(defun graphical-event-loop (connection files wait-p window renderer fonts)
  (let* ((entries (client::build-file-entries files))
         (edit-id nil)
         (screen (make-graphical-screen))
         ;; This client owns its SDL loop. A payload-free user event wakes it
         ;; for network output, including disconnects, without periodic polling.
         (incoming (make-incoming
                    :notify (lambda ()
                              (sdl2:with-sdl-event (event :lemclient-screen-ready)
                                ;; No Lisp payload: avoid sharing cl-sdl2's
                                ;; user-data hash table with the reader thread.
                                (setf (event :user :code) -1)
                                (sdl2:push-event event)))))
         (cache (make-hash-table :test 'equal))
         (frame (make-frame-cache))
         (reader nil)
         (dirty nil)
         (width 0) (height 0)
         (keyboard::*modifier* (keyboard::make-modifier))
         (keyboard:*key-event-handler*
           (lambda (key)
             (if (lem:match-key key :ctrl t :sym "V")
                 (client::send-input connection (list :paste (clipboard-text)))
                 (client::send-input connection key)))))
    (labels ((reset-renderer ()
               (clear-frame-cache frame)
               (clear-glyphs cache)
               (when (graphical-screen-rows screen)
                 (draw-screen screen renderer fonts cache frame)))
             (resize (type)
               (multiple-value-bind (w h) (grid-size window fonts)
                 (unless (and (= w width) (= h height))
                   (setf width w height h)
                   (client::request connection type "width" w "height" h)))))
      (unwind-protect
           (progn
             (sdl2:register-user-event-type :lemclient-screen-ready)
             (resize "attach")
             (when files
               (let ((id (client::request connection "visit" "wait"
                                          (if wait-p "wait" "nowait") "files" entries)))
                 (when wait-p (setf edit-id id))))
             (setf reader (bt2:make-thread (lambda () (read-screens connection incoming))
                                          :name "lemclient/sdl-reader"))
             (sdl2:start-text-input)
             (sdl2:with-event-loop (:method :wait)
               (:quit () (return-from graphical-event-loop (client::frame-close-status edit-id)))
               (:textinput (:text text)
                (keyboard:handle-text-input (lem-sdl2/platform:get-platform) text))
               (:textediting (:text text)
                (keyboard:handle-textediting (lem-sdl2/platform:get-platform) text))
               (:keydown (:keysym keysym)
                (keyboard:handle-key-down (lem-sdl2/platform:get-platform)
                                          (keyboard:keysym-to-key-event keysym)))
               (:keyup (:keysym keysym)
                (keyboard:handle-key-up (lem-sdl2/platform:get-platform)
                                        (keyboard:keysym-to-key-event keysym)))
               (:mousebuttondown (:timestamp timestamp :button button :x x :y y :clicks clicks)
                (multiple-value-bind (button x y clicks)
                    (lem-sdl2/mouse:corrected-mouse-button-fields
                     sdl2-ffi:+sdl-mousebuttondown+ timestamp button x y clicks)
                  (send-mouse connection screen fonts "down" x y :button button :clicks clicks)))
               (:mousebuttonup (:timestamp timestamp :button button :x x :y y)
                (multiple-value-bind (button x y clicks)
                    (lem-sdl2/mouse:corrected-mouse-button-fields
                     sdl2-ffi:+sdl-mousebuttonup+ timestamp button x y 1)
                  (declare (ignore clicks))
                  (send-mouse connection screen fonts "up" x y :button button)))
               (:mousemotion (:x x :y y :state state)
                (send-mouse connection screen fonts "move" x y
                            :button (if (logtest 1 state) 1 0)))
               (:mousewheel (:x dx :y dy :direction direction)
                (multiple-value-bind (x y) (sdl2:mouse-state)
                  (let ((sign (if (= direction 1) -1 1)))
                    (send-mouse connection screen fonts "wheel" x y
                                :dx (* sign dx) :dy (* sign dy)))))
               (:dropfile (:file file)
                (client::request connection "visit" "wait" "nowait"
                                 "files" (client::build-file-entries (list file))))
               (:render-targets-reset () (reset-renderer))
               (:render-device-reset () (reset-renderer))
               (:windowevent (:event event)
                (when (= event sdl2-ffi:+sdl-windowevent-close+)
                  (return-from graphical-event-loop (client::frame-close-status edit-id)))
                (when (member event (list sdl2-ffi:+sdl-windowevent-resized+
                                         sdl2-ffi:+sdl-windowevent-size-changed+))
                  (resize "resize"))
                (when (graphical-screen-rows screen)
                  (draw-screen screen renderer fonts cache frame)))
               (:lemclient-screen-ready ()
                (dolist (message (take-messages incoming))
                  (when (typep message 'error) (error message))
                  (cond
                    ((equal "screen" (protocol:field message "type"))
                     (update-screen screen message) (setf dirty t))
                    (t
                     (let ((status (client::frame-message-exit-status message edit-id)))
                       (when status (return-from graphical-event-loop status))))))
                (when (and dirty (graphical-screen-rows screen))
                  (draw-screen screen renderer fonts cache frame)
                  (setf dirty nil)))))
        (stop-screen-reader incoming reader)
        (ignore-errors (client::request connection "detach"))
        (client::close-client connection)
        (sdl2:stop-text-input)
        (clear-frame-cache frame)
        (clear-glyphs cache)))
    0))

(defun call-with-graphical-window (connection files wait-p)
  (when (uiop:getenvp "LEM_CLIENT_RESOURCES")
    (setf lem-sdl2/resource::*resource-directory*
          (uiop:ensure-directory-pathname (uiop:getenv "LEM_CLIENT_RESOURCES"))))
    (sdl2-ttf:init)
    (unwind-protect
         (let ((fonts (font:open-font)))
           (unwind-protect
                (progn
                  (lem-sdl2/mouse:install-mouse-button-layout-workaround)
                  (sdl2:with-window (window :title "Lem client"
                                           :w (* 100 (font:font-char-width fonts))
                                           :h (* 40 (font:font-char-height fonts))
                                           :flags '(:shown :resizable))
                    (sdl2:with-renderer (renderer window :flags '(:software))
                      (graphical-event-loop connection files wait-p window renderer fonts))))
             (lem-sdl2/icon-font:clear-icon-font-cache)
             (font:close-font fonts)))
      (sdl2-ttf:quit)))

(defun run-graphical (connection files wait-p)
  "Render a remote frame; never start an editor thread in this process."
  ;; A Linux client has one UI thread. Keep initialization, input, rendering,
  ;; teardown and CLI error handling on it, including display-open failures.
  (let ((sdl2::*main-thread* (bt2:current-thread))
        (sdl2::*event-loop* nil))
    (unless (zerop (sdl2:init* '(:video)))
      (error "Cannot initialize graphical display: ~a"
             (cffi:foreign-funcall "SDL_GetError" :string)))
    (unwind-protect (call-with-graphical-window connection files wait-p)
      (sdl2:quit*))))
