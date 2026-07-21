;;;; Date-aware Org capture from the agenda's effective Evil-Org bindings.

(in-package :lem-yath)

(defun agenda-capture-date-at-point (&optional (point (current-point)))
  "Return the displayed agenda date at POINT, if the row has one."
  (or (text-property-at point :agenda-view-date)
      (text-property-at point :agenda-display-date)
      (text-property-at point :agenda-date)))

(defun agenda-capture-time-at-point (&optional (point (current-point)))
  "Return POINT's agenda hour and minute, or NIL when it has no valid time."
  (alexandria:when-let ((value (text-property-at point :agenda-time)))
    (multiple-value-bind (match registers)
        (ppcre:scan-to-strings "(?:^|[^0-9])([01]?[0-9]|2[0-3]):([0-5][0-9])"
                               value)
      (declare (ignore match))
      (when registers
        (values (parse-integer (aref registers 0))
                (parse-integer (aref registers 1)))))))

(defun agenda-capture-default-time (point with-time)
  "Return Org's capture default time for the agenda date at POINT.

WITH-TIME is true only for Org's numeric prefix 1.  Dated rows otherwise use
midnight; rows without a displayed date retain the actual current time."
  (let ((now (funcall *org-capture-time-function*))
        (date (agenda-capture-date-at-point point)))
    (if (null date)
        now
        (multiple-value-bind (year month day) (agenda-date-components date)
          (multiple-value-bind (second current-minute current-hour)
              (decode-universal-time now)
            (declare (ignore second))
            (multiple-value-bind (event-hour event-minute)
                (and with-time (agenda-capture-time-at-point point))
              (encode-universal-time
               0
               (if with-time (or event-minute current-minute) 0)
               (if with-time (or event-hour current-hour) 0)
               day month year)))))))

(defun agenda-capture-annotation-at-point (&optional (point (current-point)))
  "Return the configured source annotation for POINT's agenda row."
  (let ((file (or (text-property-at point :agenda-file)
                  (text-property-at point :agenda-diary-file)))
        (line (text-property-at point :agenda-line)))
    (when (and file (integerp line) (plusp line))
      (org-capture-file-annotation file line))))

(define-command lem-yath-agenda-capture (argument) (:universal-nil)
  "Start configured Org capture with the agenda cursor's displayed date."
  (unless (eq (buffer-major-mode (current-buffer)) 'lem-yath-agenda-mode)
    (editor-error "Agenda capture is only available in an agenda buffer."))
  (let* ((point (current-point))
         (with-time (eql argument 1)))
    (org-capture-start
     ""
     (agenda-capture-annotation-at-point point)
     (agenda-capture-default-time point with-time))))

(define-key *lem-yath-agenda-vi-keymap* "C" 'lem-yath-agenda-capture)
(define-key *lem-yath-agenda-mode-keymap* "k" 'lem-yath-agenda-capture)
