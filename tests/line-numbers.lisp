(defpackage :lem-tests/line-numbers
  (:use :cl :rove :lem-core))
(in-package :lem-tests/line-numbers)

(deftest exact-decimal-width
  ;; Exercise the private arithmetic helper without allocating huge buffers.
  (loop :for exponent :from 1 :to 25
        :for power := (expt 10 exponent)
        :do (dolist (count (list (1- power) power (1+ power)))
              (ok (= (length (format nil "~D" count))
                     (lem/line-numbers::line-number-width count)))))
  (ok (= 1 (lem/line-numbers::line-number-width 1))))

(deftest live-buffer-width-and-custom-formats
  (let ((buffer (make-buffer "line-number-formats" :temporary t)))
    (unwind-protect
         (progn
           (setf (variable-value 'lem/line-numbers:line-number-format :buffer buffer) nil)
           (ok (string= " 1 " (lem/line-numbers:format-line-number buffer 1)))
           (insert-string (buffer-point buffer) (make-string 98 :initial-element #\Newline))
           (ok (string= "  1 " (lem/line-numbers:format-line-number buffer 1)))
           (insert-character (buffer-point buffer) #\Newline)
           (ok (string= "   1 " (lem/line-numbers:format-line-number buffer 1)))
           (delete-character (buffer-start-point buffer) 1)
           (ok (string= "  1 " (lem/line-numbers:format-line-number buffer 1)))
           (dolist (control (list "[~4,'0D]" "~A:" "" (formatter "<~D>")))
             (setf (variable-value 'lem/line-numbers:line-number-format :buffer buffer)
                   control)
             (ok (string= (format nil control 17)
                          (lem/line-numbers:format-line-number buffer 17))))
           (setf (variable-value 'lem/line-numbers:line-number-format :buffer buffer) nil)
           (ok (string= " -> " (lem/line-numbers:format-line-number buffer "->")))
           (dolist (base '(2 8 10 16 36))
             (ok (let ((*print-base* base) (*print-radix* t))
                   (string= " 17 " (lem/line-numbers:format-line-number buffer 17)))))
           (ok (= 99 (line-number-at-point (buffer-end-point buffer)))))
      (delete-buffer buffer))))

(deftest relative-number-and-active-attribute
  (let ((buffer (make-buffer "relative-line-numbers" :temporary t))
        (lem/line-numbers:*relative-line* t))
    (unwind-protect
         (progn
           (setf (buffer-filename buffer) "/tmp/line-number-fixture.lisp")
           (insert-string (buffer-point buffer) (format nil "one~%two~%three"))
           (move-to-line (buffer-point buffer) 2)
           (setf (variable-value 'lem/line-numbers:line-number-format :buffer buffer) nil
                 (variable-value 'lem/line-numbers:custom-current-line :buffer buffer) "->")
           (with-point ((point (buffer-start-point buffer)))
             (loop :for expected :in '(" 1 " " -> " " 1 ")
                   :for active :in '(nil t nil)
                   :do (let ((content
                               (compute-left-display-area-content
                                (ensure-mode-object 'lem/line-numbers::line-numbers-mode)
                                buffer point)))
                         (ok (string= expected (lem/buffer/line:content-string content)))
                         (ok (equal (list (list 0 (length expected)
                                               (if active
                                                   'lem/line-numbers:active-line-number-attribute
                                                   'lem/line-numbers:line-numbers-attribute)))
                                    (lem/buffer/line:content-attributes content))))
                       (line-offset point 1))))
      (delete-buffer buffer))))
