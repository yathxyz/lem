;;;; Stock GNU Org stuck-project evaluation for the configured defaults.

(in-package :lem-yath)

(defparameter *agenda-stuck-project-level* 2)

(defparameter *agenda-stuck-action-keywords*
  '("TODO" "NEXT" "NEXTACTION"))

(defparameter *agenda-stuck-action-scanners*
  (mapcar
   (lambda (keyword)
     (ppcre:create-scanner
      (format nil "^\\*+[ \\t]+~a(?:[ \\t]|$)"
              (ppcre:quote-meta-chars keyword))))
   *agenda-stuck-action-keywords*))

(defun agenda-stuck-project-candidate-p (item)
  "Return whether ITEM matches Org's default +LEVEL=2/-DONE project matcher."
  (and (eql (agenda-item-level item) *agenda-stuck-project-level*)
       (not (equal (agenda-item-keyword item) "DONE"))))

(defun agenda-stuck-project-action-p (tail candidate)
  "Return whether CANDIDATE's subtree in TAIL contains a default next action."
  (loop :for item :in tail
        :for first-p := t :then nil
        :while (and (agenda-restriction-file-equal-p
                     (agenda-item-file candidate) (agenda-item-file item))
                    (or first-p
                        (> (or (agenda-item-level item) 0)
                           *agenda-stuck-project-level*)))
        :thereis
        (some (lambda (scanner)
                (ppcre:scan scanner (or (agenda-item-heading item) "")))
              *agenda-stuck-action-scanners*)))

(defun agenda-stuck-project-items (items)
  "Return source-backed rows matching the configured stock stuck definition."
  (let ((headings (agenda-query-heading-items items)))
    (loop :for tail :on headings
          :for candidate := (first tail)
          :when (and (agenda-stuck-project-candidate-p candidate)
                     (not (agenda-stuck-project-action-p tail candidate)))
            :collect (agenda-query-display-item candidate))))
