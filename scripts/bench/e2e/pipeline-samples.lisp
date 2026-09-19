(defpackage :lem-bench/pipeline-samples
  (:use :cl)
  (:export :start :stop))
(in-package :lem-bench/pipeline-samples)

;; Optional diagnostic loaded only into a private benchmark editor. Access to
;; the internal recorder is needed to chain its existing histogram sink.
(defvar *stop-capture* nil)

(defun stop ()
  "Stop the active capture and write its stage samples, if one is active."
  (when *stop-capture*
    (funcall *stop-capture*)))

(defun start (pathname &key (capacity 8192))
  "Capture up to CAPACITY pipeline samples to a new CSV at PATHNAME on exit.
Keep the existing metrics sink active. Capture performs no file I/O and uses
preallocated arrays; overflow and recorder replacement are reported in the CSV.
Durations retain the pipeline clock's resolution and exclude physical present."
  (check-type capacity (and fixnum (integer 1 *)))
  (when *stop-capture* (error "A pipeline sample capture is already active"))
  (when (probe-file pathname) (error "Sample output already exists: ~A" pathname))
  (let ((previous lem-core::*pipeline-recorder*)
        (stages (make-array capacity :element-type '(unsigned-byte 8)))
        (durations (make-array capacity :element-type 'fixnum))
        (count 0)
        (dropped 0)
        (recorder nil))
    (declare (fixnum count))
    (unless previous (error "Pipeline metrics must be enabled before capture"))
    (setf recorder
          (lambda (stage duration name)
            (funcall previous stage duration name)
            (let ((index (position stage #(:queue-wait :command :redisplay :keystroke))))
              (when index
                (if (< count capacity)
                    (setf (aref stages count) index
                          (aref durations count) duration
                          count (1+ count))
                    (incf dropped))))))
    (setf *stop-capture*
          (lambda ()
            (let ((replaced (not (eq recorder lem-core::*pipeline-recorder*))))
              (unless replaced (lem-core:set-pipeline-recorder previous))
              (setf *stop-capture* nil)
              (lem:remove-hook lem:*exit-editor-hook* #'stop)
              (with-open-file (out pathname :direction :output
                                            :if-exists :error :if-does-not-exist :create)
                (format out "# capacity,~D~%# recorded,~D~%# dropped,~D~%"
                        capacity count dropped)
                (format out "# recorder-replaced,~(~A~)~%stage,us~%" replaced)
                (dotimes (i count)
                  (format out "~(~A~),~D~%"
                          (aref #(:queue-wait :command :redisplay :keystroke)
                                (aref stages i))
                          (aref durations i)))))))
    (lem:add-hook lem:*exit-editor-hook* #'stop)
    (lem-core:set-pipeline-recorder recorder))
  pathname)
