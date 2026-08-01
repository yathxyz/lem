(defpackage :lem-sdl2/mouse
  (:use :cl)
  (:export :cursor-shown-p
           :show-cursor
           :hide-cursor
           :install-mouse-button-layout-workaround
           :corrected-mouse-button-fields))
(in-package :lem-sdl2/mouse)

(defvar *cursor-shown* t)

(defun cursor-shown-p ()
  *cursor-shown*)

(defun show-cursor ()
  (setf *cursor-shown* t)
  (sdl2:show-cursor))

(defun hide-cursor ()
  (setf *cursor-shown* nil)
  (sdl2:hide-cursor))

;; Deployed Windows images carry cl-sdl2 autowrap metadata that widens
;; SDL2's Uint8 fields to 4-byte slots: SDL_MouseButtonEvent is believed to
;; span 40 bytes (real ABI: 28), placing state/clicks/x/y at offsets
;; 20/24/32/36 instead of 17/18/20/24.  The button and timestamp wrappers
;; happen to keep their true offsets, but state and clicks read single bytes
;; out of the real x/y, and x/y read stale bytes past the event payload, so
;; every click lands at a garbage position.  Unlike the keysym case there is
;; no wrapper pointing into the event to correct, so when the believed size
;; disagrees with the ABI an SDL event watch captures each mouse button
;; event's fields from the raw event bytes as SDL enqueues it, and the event
;; loop swaps its corrupted values for the captured ones, matched by
;; timestamp and button.  The watch and the event loop both run on the
;; thread that pumps events, so the pending list needs no locking.
(defvar *mouse-button-layout-inflated-p*
  (/= 28 (autowrap:sizeof 'sdl2-ffi:sdl-mouse-button-event)))

(defvar *pending-raw-mouse-button-events* '())

(defstruct (raw-mouse-button-event (:type list))
  type
  timestamp
  button
  clicks
  x
  y)

(cffi:defcallback capture-raw-mouse-button-event :int
    ((userdata :pointer) (event :pointer))
  (declare (ignore userdata))
  (let ((type (cffi:mem-ref event :unsigned-int 0)))
    (when (or (= type sdl2-ffi:+sdl-mousebuttondown+)
              (= type sdl2-ffi:+sdl-mousebuttonup+))
      (setf *pending-raw-mouse-button-events*
            (nconc *pending-raw-mouse-button-events*
                   (list (make-raw-mouse-button-event
                          :type type
                          :timestamp (cffi:mem-ref event :unsigned-int 4)
                          :button (cffi:mem-ref event :unsigned-char 16)
                          :clicks (cffi:mem-ref event :unsigned-char 18)
                          :x (cffi:mem-ref event :int 20)
                          :y (cffi:mem-ref event :int 24)))))
      ;; A captured event the loop never consumes (e.g. dropped from a full
      ;; queue) must not pile up forever.
      (when (> (length *pending-raw-mouse-button-events*) 64)
        (pop *pending-raw-mouse-button-events*))))
  0)

(defvar *mouse-button-layout-workaround-installed-p* nil)

(defun install-mouse-button-layout-workaround ()
  (when (and *mouse-button-layout-inflated-p*
             (not *mouse-button-layout-workaround-installed-p*))
    (setf *mouse-button-layout-workaround-installed-p* t)
    (cffi:foreign-funcall "SDL_AddEventWatch"
                          :pointer (cffi:callback capture-raw-mouse-button-event)
                          :pointer (cffi:null-pointer)
                          :void)))

(defun pop-raw-mouse-button-event (type timestamp button)
  (let ((tail (member-if (lambda (entry)
                           (and (= (raw-mouse-button-event-type entry) type)
                                (= (raw-mouse-button-event-timestamp entry) timestamp)
                                (= (raw-mouse-button-event-button entry) button)))
                         *pending-raw-mouse-button-events*)))
    (when tail
      ;; Entries in front of the match belong to events that were captured
      ;; but never reached the loop; they are stale, drop them too.
      (setf *pending-raw-mouse-button-events* (cdr tail))
      (car tail))))

(defun corrected-mouse-button-fields (type timestamp button x y clicks)
  "Return the real (values button x y clicks) for a mouse button event whose
fields were read through this image's believed SDL_MouseButtonEvent layout."
  (if (not *mouse-button-layout-inflated-p*)
      (values button x y clicks)
      (let ((entry (pop-raw-mouse-button-event type timestamp button)))
        (if entry
            (values (raw-mouse-button-event-button entry)
                    (raw-mouse-button-event-x entry)
                    (raw-mouse-button-event-y entry)
                    (raw-mouse-button-event-clicks entry))
            ;; No captured event (the watch missed it, e.g. installed after
            ;; the event was queued): the button byte is trustworthy, take
            ;; the position from the live cursor.
            (multiple-value-bind (x y) (sdl2:mouse-state)
              (values button x y 1))))))
