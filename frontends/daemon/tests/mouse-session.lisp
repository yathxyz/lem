(defpackage :lem-daemon/tests/mouse-session
  (:use :cl :rove)
  (:local-nicknames (:core :lem-core)))
(in-package :lem-daemon/tests/mouse-session)

(defclass recording-daemon-implementation (lem-daemon:daemon-implementation)
  ((rendered-lines :initform nil :accessor rendered-lines)))

(defmethod lem-if:render-line :before
    ((implementation recording-daemon-implementation) view x y objects height)
  (declare (ignore view x objects height))
  (push y (rendered-lines implementation)))

(defun call-with-fresh-tabs (function)
  (let ((lem/frame-multiplexer::*virtual-frame-map* (make-hash-table))
        (lem/frame-multiplexer::*recent-list* nil))
    (assert (not (lem/frame-multiplexer::enabled-frame-multiplexer-p)))
    (unwind-protect (call-with-two-frames function)
      (lem/frame-multiplexer::disable-frame-multiplexer))))

(defun call-with-two-frames (function &key
                                      (implementation-class 'lem-daemon:daemon-implementation))
  (lem:with-current-buffers ()
    (let ((core::*display-frame-map* (make-hash-table))
          (core::*frames* nil)
          (implementations (loop :repeat 2
                                 :collect (make-instance implementation-class))))
      (unwind-protect
           (progn
             (loop :for implementation :in implementations
                   :for index :from 0
                   :do (lem:with-implementation implementation
                         (let ((frame (lem:make-frame nil))
                               (buffer (lem:make-buffer (format nil "mouse-frame-~d" index))))
                           (lem:map-frame implementation frame)
                           (lem:setup-frame frame buffer)
                           (setf (lem:current-buffer) buffer)
                           (lem:insert-string (lem:buffer-point buffer) "some text")
                           (lem:buffer-start (lem:buffer-point buffer)))))
             (apply function implementations))
        (dolist (implementation implementations)
          (lem:with-implementation implementation
            (alexandria:when-let ((frame (lem:get-frame implementation)))
              (lem:teardown-frame frame)
              (lem:unmap-frame implementation))))))))

(defun select-frame (implementation)
  (setf core::*implementation* implementation
        (lem:current-buffer) (lem:window-buffer (lem:current-window))))

(defun mouse-event (class x y &optional (button :button-1))
  (apply #'make-instance class :x x :y y :pixel-x x :pixel-y y :button button
         (when (eq class 'core::mouse-button-down) (list :clicks 1))))

(deftest separator-drag-is-owned-by-frame
  (call-with-two-frames
   (lambda (first second)
     (let ((core::*implementation* first))
       (select-frame first)
       (lem:split-window-horizontally (lem:current-window))
       (let* ((frame (lem:current-frame))
              (right (car (sort (copy-list (lem:window-list)) #'> :key #'lem:window-x)))
              (separator-x (1- (lem:window-x right)))
              (width (lem:window-width right)))
         (core::handle-mouse-event (mouse-event 'core::mouse-button-down separator-x 0))
         (let ((separator (core::frame-dragged-separator frame)))
           (ok separator "a separator press starts a drag in its frame")
           (select-frame second)
           (core::handle-mouse-event (mouse-event 'core::mouse-button-down 0 0))
           (core::handle-mouse-event (mouse-event 'core::mouse-motion 10 0))
           (ok (= width (lem:window-width right))
               "dragging in another frame does not resize the first frame")
           (core::handle-mouse-event (mouse-event 'core::mouse-button-up 10 0))
           (ok (eq separator (core::frame-dragged-separator frame))
               "another frame's release does not cancel the first drag")
           (select-frame first)
           (core::handle-mouse-event (mouse-event 'core::mouse-motion (+ separator-x 3) 0))
           (ok (/= width (lem:window-width right))
               "the original frame can continue its own drag")
           (core::handle-mouse-event (mouse-event 'core::mouse-button-up (+ separator-x 3) 0))
           (ok (null (core::frame-dragged-separator frame))
               "the owner's release ends its drag")
           (core::handle-mouse-event
            (mouse-event 'core::mouse-button-down (1- (lem:window-x right)) 0))
           (ok (core::frame-dragged-separator frame))
           (lem:teardown-frame frame)
           (lem:unmap-frame first)
           (ok (null (core::frame-dragged-separator frame))
               "teardown releases a drag left behind by a disconnected client")
           (select-frame second)
           (let ((width (lem:window-width (lem:current-window))))
             (core::handle-mouse-event (mouse-event 'core::mouse-motion 15 0))
             (core::handle-mouse-event (mouse-event 'core::mouse-button-up 15 0))
             (ok (= width (lem:window-width (lem:current-window)))
                 "the remaining frame accepts mouse input after the owner disappears"))))))))

(deftest hover-and-last-event-are-owned-by-frame
  (call-with-two-frames
   (lambda (first second)
     (let ((core::*implementation* first)
           (entered nil) (left nil))
       (select-frame first)
       (let* ((first-frame (lem:current-frame))
              (first-window (lem:current-window))
              (point (lem:current-point))
              (event (mouse-event 'core::mouse-motion 0 0 nil))
              (overlay (lem:with-point ((end point))
                         (lem:character-offset end 1)
                         (lem:make-overlay point end (lem:make-attribute :underline t)))))
         (lem:overlay-put overlay :hover-callback
                          (lambda (window point) (declare (ignore point)) (push window entered)))
         (lem:overlay-put overlay :unhover-callback
                          (lambda (window point) (declare (ignore point)) (push window left)))
         (core::set-last-mouse-event event)
         (core::handle-mouse-event event)
         (ok (equal entered (list first-window)) "the owner enters its hover overlay")
         (select-frame second)
         (ok (null (core::last-mouse-event)) "another frame starts with no last mouse event")
         (core::handle-mouse-event (mouse-event 'core::mouse-motion 0 0 nil))
         (ok (null left) "another frame's motion does not leave the owner's overlay")
         (ok (eq overlay (core::frame-hover-overlay first-frame)))
         (select-frame first)
         (ok (eq event (core::last-mouse-event)) "frame switching preserves the owner's event")
         (core::handle-mouse-event (mouse-event 'core::mouse-motion 3 0 nil))
         (ok (equal left (list first-window)) "the owner's motion leaves its own overlay")
         (core::handle-mouse-event event)
         (lem:teardown-frame first-frame)
         (lem:unmap-frame first)
         (ok (and (null (core::frame-hover-overlay first-frame))
                  (null (core::frame-last-mouse-event first-frame)))
             "teardown releases hover and last-event references"))))))

(deftest disabling-tabs-uses-the-header-owner
  (call-with-fresh-tabs
   (lambda (first second)
     (let (header owner-frame)
       (lem:with-implementation first
         (lem/frame-multiplexer::enable-frame-multiplexer)
         (setf owner-frame (lem:current-frame)
               header (gethash first lem/frame-multiplexer::*virtual-frame-map*)))
       (lem:with-implementation second
         (let ((window (lem:current-window))
               (buffer (lem:window-buffer (lem:current-window))))
           (setf (lem:current-buffer) buffer)
           (lem:character-offset (lem:current-point) 2)
           (let ((position (lem:position-at-point (lem:current-point))))
             (lem/frame-multiplexer::disable-frame-multiplexer)
             (ok (core::window-deleted-p header) "the exact owner's tab header was freed")
             (ok (not (find header (core::frame-header-windows owner-frame))))
             (ok (and (eq second (lem:implementation))
                      (eq window (lem:current-window)) (eq buffer (lem:current-buffer))
                      (= position (lem:position-at-point (lem:current-point))))
                 "another frame keeps its implementation, window, buffer and point")
             (ok (zerop (hash-table-count lem/frame-multiplexer::*virtual-frame-map*))))))))))

(deftest disabling-tabs-does-not-rebind-a-retired-owner
  (call-with-fresh-tabs
   (lambda (first second)
     (lem:with-implementation first
       (lem/frame-multiplexer::enable-frame-multiplexer)
       (lem:teardown-frame (lem:current-frame))
       (lem:unmap-frame first))
     (lem:with-implementation second
       (let ((peer-header (make-instance 'lem:header-window
                                        :buffer (lem:make-buffer "peer-tab-header" :temporary t))))
         (lem/frame-multiplexer::disable-frame-multiplexer)
         (ok (not (core::window-deleted-p peer-header))
             "a missing tab owner cannot delete the surviving frame's header")
         (ok (find peer-header (core::frame-header-windows (lem:current-frame))))
         (ok (zerop (hash-table-count lem/frame-multiplexer::*virtual-frame-map*)))
         (lem:delete-window peer-header))))))

(deftest after-redraw-force-is-scoped-to-the-completed-frame
  (call-with-two-frames
   (lambda (first second)
     (let ((core::*implementation* first)
           (lem:*after-redraw-display-force* :outside)
           (nested nil)
           (seen nil))
       (select-frame first)
       ;; Start with a valid peer cache, then suppress the requested force.
       (let ((lem:*after-redraw-display-hook* nil))
         (lem-daemon::call-with-client-implementation
          second (lambda () (lem:redraw-display :force t))))
       (setf (slot-value second 'core::no-force-needed) t)
       (let ((lem:*after-redraw-display-hook*
               (list (cons (lambda ()
                             (push lem:*after-redraw-display-force* seen)
                             (unless nested
                               (setf nested t)
                               (lem-daemon::call-with-client-implementation
                                second (lambda () (lem:redraw-display :force t)))
                               (push lem:*after-redraw-display-force* seen)))
                           0))))
         (lem:redraw-display :force t))
       (ok (equal '(t nil t) (reverse seen))
           "nested peer redraws preserve the outer hook's force value")
       (ok (eq :outside lem:*after-redraw-display-force*))
       (let ((lem:*after-redraw-display-hook*
               (list (cons (lambda () (error "after-redraw fixture")) 0))))
         (ok (handler-case (progn (lem:redraw-display :force t) nil)
               (error () t))))
       (ok (eq :outside lem:*after-redraw-display-force*)
           "a failing hook also unwinds its force binding")))))

(deftest peer-redraws-reuse-rows-and-preserve-explicit-invalidation
  (call-with-two-frames
   (lambda (first second)
     (let ((core::*implementation* first)
           (lem-daemon::*daemon-root-implementation* first)
           (lem-daemon::*daemon-running-p* t)
           (lem-daemon::*daemon-connections*
             (loop :for implementation :in (list first second)
                   :collect (let ((connection
                                    (make-instance 'lem-daemon::daemon-connection
                                                   :transport nil :stream nil)))
                              (setf (lem-daemon::connection-implementation connection)
                                    implementation)
                              connection)))
           (lem:*after-redraw-display-hook*
             (list (cons 'lem-daemon::redraw-daemon-sessions-after-display 0))))
       (select-frame first)
       (let ((buffer (lem:current-buffer)))
         (lem:erase-buffer buffer)
         (dotimes (i 10)
           (lem:insert-string (lem:current-point) (format nil "Line ~d 漢 é~%" i)))
         (setf (lem:variable-value 'lem:line-wrap :buffer buffer) nil)
         (lem:buffer-start (lem:current-point))
         (lem-daemon::activate-implementation second)
         (lem:switch-to-buffer buffer)
         (setf (lem-daemon::daemon-implementation-width second) 53)
         (core::adjust-all-window-size)
         (lem:buffer-start (lem:current-point))
         (lem-daemon::activate-implementation first)
         (lem:redraw-display :force t)
         (setf (rendered-lines second) nil)
         (lem:redraw-display)
         (ok (null (rendered-lines second)) "an unchanged peer reuses its text rows")
         (lem:insert-character (lem:current-point) #\x)
         (setf (rendered-lines second) nil)
         (lem:redraw-display)
         (ok (and (rendered-lines second) (< (length (rendered-lines second)) 5))
             "a shared edit redraws only affected peer rows")
         (let ((incremental (multiple-value-list (lem-daemon::implementation-screen second)))
               (position (lem:position-at-point (lem:current-point))))
           (let ((lem:*after-redraw-display-hook* nil))
             (lem-daemon::call-with-client-implementation
              second (lambda () (lem:redraw-display :force t))))
           (ok (equalp incremental
                       (multiple-value-list (lem-daemon::implementation-screen second)))
               "incremental Unicode cells, faces and cursor match forced rendering")
           (ok (and (eq first (lem:implementation))
                    (= position (lem:position-at-point (lem:current-point))))
               "peer rendering restores the active frame and point"))
         (let ((attribute (lem:make-attribute :foreground "red")))
           (lem:with-point ((start (lem:buffer-start-point buffer))
                            (end (lem:buffer-start-point buffer)))
             (lem:line-offset start 2)
             (lem:move-point end start)
             (lem:line-end end)
             (lem:make-overlay start end attribute))
           (lem:redraw-display :force t)
           (let ((before (lem-daemon::implementation-screen second)))
             (lem:set-attribute attribute :foreground "blue")
             (core::need-to-redraw (lem:current-window))
             (lem:redraw-display)
             (let ((incremental (lem-daemon::implementation-screen second)))
               (ng (equalp before incremental)
                   "a dirty source window propagates shared attribute changes")
               (let ((lem:*after-redraw-display-hook* nil))
                 (lem-daemon::call-with-client-implementation
                  second (lambda () (lem:redraw-display :force t))))
               (ok (equalp incremental (lem-daemon::implementation-screen second))
                   "peer attribute recoloring matches a full repaint"))))
         (setf (rendered-lines second) nil)
         (lem:redraw-display :force t)
         (ok (>= (length (rendered-lines second)) 10)
             "an explicit forced redraw invalidates every peer's rows")
         (let ((lem:*after-redraw-display-hook* nil))
           (lem-daemon::call-with-client-implementation
            second (lambda () (core::need-to-redraw (lem:current-window)))))
         (setf (rendered-lines second) nil)
         (lem:redraw-display)
         (ok (>= (length (rendered-lines second)) 10)
             "a peer's local invalidation still forces its own repaint"))))
   :implementation-class 'recording-daemon-implementation))
