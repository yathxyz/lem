(defpackage :lem-tests/common/color
  (:use :cl :rove)
  (:local-nicknames (:color :lem/common/color)))
(in-package :lem-tests/common/color)

(deftest rgb-hex-matches-format
  (let ((failure nil))
    (block check
      (dotimes (red 256)
        (dotimes (green 256)
          (let* ((blue (logxor red green))
                 (expected (format nil "#~2,'0X~2,'0X~2,'0X" red green blue))
                 (actual (color:color-to-hex-string (color:make-color red green blue))))
            (unless (string= expected actual)
              (setf failure (list red green blue expected actual))
              (return-from check))))))
    (ok (null failure)
        (format nil "65,536 RGB triples cover every channel byte; mismatch: ~s" failure))))

(deftest hex-formatting-preserves-other-components-and-printer-bindings
  (flet ((result (function)
           (handler-case (list :value (funcall function))
             (error (condition) (list :error (type-of condition))))))
    (let ((failure nil))
      (dolist (*print-base* '(2 10 16 36))
        (dolist (*print-case* '(:upcase :downcase :capitalize))
          (dolist (*print-radix* '(nil t))
            (dolist (value '(0 15 16 171 255 -1 256 65535 #x100000000000000000
                            3/2 1.5d0 "RGB" #\R nil :red))
              (dotimes (index 3)
                (let ((channels (list 171 205 239)))
                  (setf (nth index channels) value)
                  (let ((expected (result (lambda ()
                                            (apply #'format nil "#~2,'0X~2,'0X~2,'0X"
                                                   channels))))
                        (actual (result (lambda ()
                                          (color:color-to-hex-string
                                           (apply #'color:make-color channels))))))
                    (unless (equal expected actual)
                      (setf failure (list channels *print-base* *print-case*
                                          *print-radix* expected actual))))))))))
      (ok (null failure) (format nil "printer/fallback mismatch: ~s" failure)))))

(deftest hex-results-are-independent-and-track-mutation
  (let* ((color (color:make-color 0 15 255))
         (first (color:color-to-hex-string color))
         (second (color:color-to-hex-string color)))
    (setf (char first 1) #\X)
    (ok (string= "#000FFF" second) "callers can modify their own result")
    (setf (color:color-red color) 16
          (color:color-green color) 255
          (color:color-blue color) 0)
    (ok (string= "#10FF00" (color:color-to-hex-string color))
        "an in-place color change is visible immediately")
    (ok (string= "#000FFF" second) "older snapshots survive later color changes")))
