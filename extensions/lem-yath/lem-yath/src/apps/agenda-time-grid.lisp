;;;; Stock GNU Org terminal time-grid presentation.

(in-package :lem-yath)

(defparameter *agenda-time-grid-times*
  '(800 1000 1200 1400 1600 1800 2000))

(defparameter *agenda-time-grid-after-time* "......")
(defparameter *agenda-time-grid-line* "----------------")
(defparameter *agenda-current-time-line*
  "now - - - - - - - - - - - - - - - - - - - - - - - - -")

(defun agenda-time-grid-format-time (value)
  (format nil "~2,'0d:~2,'0d" (floor value 100) (mod value 100)))

(defun agenda-time-grid-decoration (kind time date text)
  (make-agenda-section-decoration
   :text (format nil "~a ~a" (agenda-time-grid-format-time time) text)
   :properties (list :agenda-grid-kind kind
                     :agenda-grid-time time
                     :agenda-display-date date)))

(defun agenda-time-grid-line-decoration (time date)
  (agenda-time-grid-decoration
   :line time date
   (format nil "~a ~a"
           *agenda-time-grid-after-time* *agenda-time-grid-line*)))

(defun agenda-time-grid-current-decoration (now date)
  (multiple-value-bind (second minute hour) (decode-universal-time now)
    (declare (ignore second))
    (let ((time (+ (* hour 100) minute)))
      (cons time
            (agenda-time-grid-decoration
             :now time date *agenda-current-time-line*)))))

(defun agenda-time-grid-daily-view-p (buffer key)
  (and (eq key :date)
       (fboundp 'agenda-view-state)
       (eq (agenda-view-state-span (agenda-view-state buffer)) :day)))

(defun agenda-time-grid-visible-p (buffer key date items now)
  "Return true when stock Org would show a required-timed grid."
  (and date
       (some #'agenda-item-time items)
       (or (string= date (today-iso now))
           (agenda-time-grid-daily-view-p buffer key))))

(defun agenda-time-grid-layout (buffer key date items now)
  "Interleave stock time-grid decorations with source-backed ITEMS."
  (if (not (agenda-time-grid-visible-p buffer key date items now))
      items
      (let ((timed '())
            (untimed '())
            (decorations
              (mapcar
               (lambda (time)
                 (cons time (agenda-time-grid-line-decoration time date)))
               *agenda-time-grid-times*)))
        (dolist (item items)
          (if (agenda-item-time item)
              (push (cons (agenda-item-time-value item) item) timed)
              (push item untimed)))
        (when (string= date (today-iso now))
          (push (agenda-time-grid-current-decoration now date) decorations))
        (append
         (mapcar #'cdr
                 (stable-sort
                  (append decorations (nreverse timed))
                  #'< :key #'car))
         (nreverse untimed)))))

(setf *agenda-section-layout-function* 'agenda-time-grid-layout)
