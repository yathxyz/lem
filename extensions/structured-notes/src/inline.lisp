(in-package #:lem-structured-notes)

(defun inline-node-equivalent-p (left right)
  (and (inline-node-p left)
       (inline-node-p right)
       (eq (inline-node-kind left) (inline-node-kind right))
       (equal (inline-node-text left) (inline-node-text right))
       (equal (inline-node-destination left)
              (inline-node-destination right))
       (equalp (inline-node-attributes left)
               (inline-node-attributes right))
       (inline-nodes-equivalent-p (inline-node-children left)
                                  (inline-node-children right))))

(defun inline-nodes-equivalent-p (left right)
  (and (= (length left) (length right))
       (every #'inline-node-equivalent-p left right)))

(defun inline-source-span (raw source-id character-base byte-base start end)
  (let ((byte-prefixes (source-byte-prefixes raw)))
    (make-source-span
     :source-id source-id
     :character-start (+ character-base start)
     :character-end (+ character-base end)
     :byte-start (+ byte-base (aref byte-prefixes start))
     :byte-end (+ byte-base (aref byte-prefixes end)))))

(defun inline-node-from-range
    (kind source-format raw line source-id character-base byte-base start end
     &key text destination children)
  (make-inline-node
   :kind kind :source-format source-format :raw (subseq line start end)
   :span (inline-source-span raw source-id character-base byte-base start end)
   :text text :destination destination :children children))

(defun inline-space-p (character)
  (member character '(#\Space #\Tab)))

(defun org-inline-opening-boundary-p (line index)
  (and (< (1+ index) (length line))
       (not (inline-space-p (char line (1+ index))))
       (or (zerop index)
           (inline-space-p (char line (1- index)))
           (member (char line (1- index))
                   '(#\( #\[ #\{ #\' #\")))))

(defun org-inline-closing-boundary-p (line index)
  (and (plusp index)
       (not (inline-space-p (char line (1- index))))
       (or (= (1+ index) (length line))
           (inline-space-p (char line (1+ index)))
           (member (char line (1+ index))
                   '(#\. #\, #\! #\? #\: #\; #\) #\] #\} #\' #\")))))

(defun org-unsupported-inline-character-p (character)
  (member character '(#\= #\_ #\+ #\< #\> #\{ #\} #\\ #\^ #\$)))

(defun plain-org-inline-fragment-p (fragment)
  (and (plusp (length fragment))
       (not (inline-space-p (char fragment 0)))
       (not (inline-space-p (char fragment (1- (length fragment)))))
       (not (find-if (lambda (character)
                       (or (org-unsupported-inline-character-p character)
                           (member character '(#\* #\/ #\~ #\[ #\]))))
                     fragment))))

(defun safe-link-destination-p (destination)
  (and (plusp (length destination))
       (every (lambda (character)
                (or (alphanumericp character)
                    (member character
                            '(#\: #\/ #\? #\# #\@ #\! #\$ #\& #\'
                              #\* #\+ #\, #\; #\= #\% #\. #\_ #\~ #\-))))
              destination)))

(defun parse-org-paragraph-inlines
    (raw &key (source-id "inline") (character-base 0) (byte-base 0))
  "Parse the conservative, source-backed Org inline profile.

Return two values: inline nodes and a success flag. Unsupported or ambiguous
  syntax returns NIL/NIL so callers retain the whole paragraph opaquely."
  (let ((line (source-single-line-text raw)))
    (unless (and line
                 (not (inline-space-p (char line 0)))
                 (not (inline-space-p (char line (1- (length line))))))
      (return-from parse-org-paragraph-inlines (values nil nil)))
    (let ((nodes nil)
          (text-start 0)
          (index 0))
      (labels ((emit-text (end)
                 (when (< text-start end)
                   (push (inline-node-from-range
                          :text :org raw line source-id character-base
                          byte-base text-start end
                          :text (subseq line text-start end))
                         nodes)))
               (fail ()
                 (return-from parse-org-paragraph-inlines (values nil nil)))
               (emit-delimited (kind delimiter end)
                 (emit-text index)
                 (let* ((inner-start (1+ index))
                        (inner (subseq line inner-start end))
                        (child
                          (inline-node-from-range
                           :text :org raw line source-id character-base
                           byte-base inner-start end :text inner)))
                   (push (inline-node-from-range
                          kind :org raw line source-id character-base byte-base
                          index (1+ end) :children (list child))
                         nodes)
                   (setf index (1+ end) text-start index)
                   delimiter)))
        (loop :while (< index (length line))
              :for character := (char line index)
              :do
                 (cond
                   ((org-unsupported-inline-character-p character) (fail))
                   ((and (char= character #\[)
                         (< (1+ index) (length line))
                         (char= (char line (1+ index)) #\[))
                    (let ((close (search "]]" line :start2 (+ index 2))))
                      (unless close (fail))
                      (let* ((inside (subseq line (+ index 2) close))
                             (separator (search "][" inside))
                             (destination
                               (if separator (subseq inside 0 separator)
                                   inside))
                             (label
                               (if separator (subseq inside (+ separator 2))
                                   inside)))
                        (unless (and (safe-link-destination-p destination)
                                     (plain-org-inline-fragment-p label))
                          (fail))
                        (emit-text index)
                        (let* ((label-start
                                 (+ index 2 (if separator (+ separator 2) 0)))
                               (child
                                 (inline-node-from-range
                                  :text :org raw line source-id character-base
                                  byte-base label-start
                                  (+ label-start (length label)) :text label)))
                          (push (inline-node-from-range
                                 :link :org raw line source-id character-base
                                 byte-base index (+ close 2)
                                 :destination destination :children (list child))
                                nodes))
                        (setf index (+ close 2) text-start index))))
                   ((member character '(#\[ #\])) (fail))
                   ((and (member character '(#\* #\/ #\~))
                         (org-inline-opening-boundary-p line index))
                    (let ((end (position character line :start (1+ index))))
                      (unless (and end
                                   (org-inline-closing-boundary-p line end)
                                   (plain-org-inline-fragment-p
                                    (subseq line (1+ index) end)))
                        (fail))
                      (if (char= character #\~)
                          (progn
                            (emit-text index)
                            (let ((inner (subseq line (1+ index) end)))
                              (push (inline-node-from-range
                                     :code :org raw line source-id
                                     character-base byte-base index (1+ end)
                                     :text inner)
                                    nodes))
                            (setf index (1+ end) text-start index))
                          (emit-delimited (if (char= character #\*)
                                              :strong :emphasis)
                                          character end))))
                   (t (incf index))))
        (emit-text (length line))
        (if nodes
            (values (nreverse nodes) t)
            (values nil nil))))))

(defun commonmark-escapable-p (character)
  (or (and (char>= character #\!) (char<= character #\/))
      (and (char>= character #\:) (char<= character #\@))
      (and (char>= character #\[) (char<= character #\`))
      (and (char>= character #\{) (char<= character #\~))))

(defun commonmark-plain-fragment-text (fragment)
  (let ((characters nil)
        (index 0))
    (loop :while (< index (length fragment))
          :for character := (char fragment index)
          :do (cond
                ((char= character #\\)
                 (unless (and (< (1+ index) (length fragment))
                              (commonmark-escapable-p
                               (char fragment (1+ index))))
                   (return-from commonmark-plain-fragment-text
                     (values nil nil)))
                 (push (char fragment (1+ index)) characters)
                 (incf index 2))
                ((member character '(#\* #\_ #\` #\[ #\]))
                 (return-from commonmark-plain-fragment-text
                   (values nil nil)))
                (t (push character characters) (incf index))))
    (let ((text (coerce (nreverse characters) 'string)))
      (if (plusp (length text)) (values text t) (values nil nil)))))

(defun commonmark-block-prefix-p (line)
  (or (zerop (length line))
      (inline-space-p (char line 0))
      (every (lambda (character) (char= character #\=)) line)
      (and (>= (length line) 3)
           (every (lambda (character) (char= character #\-)) line))
      (and (>= (length line) 2)
           (member (char line 0) '(#\# #\> #\- #\+ #\*))
           (inline-space-p (char line 1)))
      (and (>= (length line) 3)
           (or (string= "```" line :end2 3)
               (string= "~~~" line :end2 3)))
      (let ((digits (position-if-not #'digit-char-p line)))
        (and digits (plusp digits) (< (1+ digits) (length line))
             (member (char line digits) '(#\. #\)))
             (inline-space-p (char line (1+ digits)))))))

(defun parse-commonmark-paragraph-inlines
    (raw &key (source-id "inline") (character-base 0) (byte-base 0))
  "Parse the canonical CommonMark inline subset emitted by LSM/1."
  (let ((line (source-single-line-text raw)))
    (unless (and line
                 (not (inline-space-p (char line (1- (length line)))))
                 (not (commonmark-block-prefix-p line)))
      (return-from parse-commonmark-paragraph-inlines (values nil nil)))
    (let ((nodes nil)
          (text-characters nil)
          (text-start nil)
          (index 0))
      (labels ((add-text (character raw-index)
                 (unless text-start (setf text-start raw-index))
                 (push character text-characters))
               (emit-text (end)
                 (when text-start
                   (push (inline-node-from-range
                          :text :commonmark raw line source-id character-base
                          byte-base text-start end
                          :text (coerce (nreverse text-characters) 'string))
                         nodes)
                   (setf text-start nil text-characters nil)))
               (fail ()
                 (return-from parse-commonmark-paragraph-inlines
                   (values nil nil)))
               (plain-child (start end)
                 (multiple-value-bind (text valid-p)
                     (commonmark-plain-fragment-text (subseq line start end))
                   (unless valid-p (fail))
                   (inline-node-from-range
                    :text :commonmark raw line source-id character-base
                    byte-base start end :text text))))
        (loop :while (< index (length line))
              :for character := (char line index)
              :do
                 (cond
                   ((char= character #\\)
                    (unless (and (< (1+ index) (length line))
                                 (commonmark-escapable-p
                                  (char line (1+ index))))
                      (fail))
                    (add-text (char line (1+ index)) index)
                    (incf index 2))
                   ((and (char= character #\*)
                         (< (1+ index) (length line))
                         (char= (char line (1+ index)) #\*))
                    (let ((end (search "**" line :start2 (+ index 2))))
                      (unless end (fail))
                      (emit-text index)
                      (push (inline-node-from-range
                             :strong :commonmark raw line source-id
                             character-base byte-base index (+ end 2)
                             :children (list (plain-child (+ index 2) end)))
                            nodes)
                      (setf index (+ end 2))))
                   ((char= character #\*)
                    (let ((end (position #\* line :start (1+ index))))
                      (unless end (fail))
                      (emit-text index)
                      (push (inline-node-from-range
                             :emphasis :commonmark raw line source-id
                             character-base byte-base index (1+ end)
                             :children (list (plain-child (1+ index) end)))
                            nodes)
                      (setf index (1+ end))))
                   ((char= character #\`)
                    (let ((end (position #\` line :start (1+ index))))
                      (unless (and end (> end (1+ index))) (fail))
                      (emit-text index)
                      (push (inline-node-from-range
                             :code :commonmark raw line source-id
                             character-base byte-base index (1+ end)
                             :text (subseq line (1+ index) end))
                            nodes)
                      (setf index (1+ end))))
                   ((char= character #\[)
                    (let* ((separator (search "](" line :start2 (1+ index)))
                           (end (and separator
                                     (position #\) line
                                               :start (+ separator 2)))))
                      (unless (and separator end) (fail))
                      (let ((destination
                              (subseq line (+ separator 2) end)))
                        (unless (safe-link-destination-p destination) (fail))
                        (emit-text index)
                        (push (inline-node-from-range
                               :link :commonmark raw line source-id
                               character-base byte-base index (1+ end)
                               :destination destination
                               :children
                               (list (plain-child (1+ index) separator)))
                              nodes)
                        (setf index (1+ end)))))
                   ((and (char= character #\!)
                         (< (1+ index) (length line))
                         (char= (char line (1+ index)) #\[))
                    (fail))
                   ((member character
                            '(#\_ #\` #\] #\{ #\} #\$ #\< #\> #\& #\|))
                    (fail))
                   (t (add-text character index) (incf index))))
        (emit-text (length line))
        (if nodes
            (values (nreverse nodes) t)
            (values nil nil))))))

(defun commonmark-escape-text (text)
  (with-output-to-string (stream)
    (loop :for character :across text
          :do (when (member character
                            '(#\\ #\` #\* #\_ #\{ #\} #\[ #\] #\< #\>
                              #\# #\$ #\% #\& #\+ #\- #\! #\|))
                (write-char #\\ stream))
              (write-char character stream))))

(defun inline-container-has-plain-children-p (node)
  (and (inline-node-children node)
       (every (lambda (child)
                (and (eq :text (inline-node-kind child))
                     (null (inline-node-attributes child))))
              (inline-node-children node))))

(defun render-commonmark-inline (node)
  (when (inline-node-attributes node)
    (model-error :unsupported-inline-attributes node
                 "canonical CommonMark rendering does not support inline attributes"))
  (case (inline-node-kind node)
    (:text (commonmark-escape-text (inline-node-text node)))
    (:code
     (let ((text (inline-node-text node)))
       (when (or (find #\` text) (find #\Newline text) (find #\Return text))
         (model-error :unsupported-inline-code text
                      "initial CommonMark profile supports single-backtick code only"))
       (format nil "`~a`" text)))
    ((:emphasis :strong)
     (unless (inline-container-has-plain-children-p node)
       (model-error :unsupported-nested-inline node
                    "initial CommonMark profile supports plain children only"))
     (let ((marker (if (eq :strong (inline-node-kind node)) "**" "*")))
       (format nil "~a~a~a" marker
               (render-commonmark-inlines (inline-node-children node)) marker)))
    (:link
     (unless (and (safe-link-destination-p (inline-node-destination node))
                  (inline-container-has-plain-children-p node))
       (model-error :unsupported-inline-link node
                    "initial CommonMark profile requires a safe destination and plain label"))
     (format nil "[~a](~a)"
             (render-commonmark-inlines (inline-node-children node))
             (inline-node-destination node)))
    (otherwise
     (model-error :unsupported-inline-kind (inline-node-kind node)
                  "inline kind is not in the canonical CommonMark profile"))))

(defun render-commonmark-inlines (nodes)
  (with-output-to-string (stream)
    (dolist (node nodes)
      (write-string (render-commonmark-inline node) stream))))

(defun inline-nodes-canonical-commonmark-p (nodes)
  "Return true when NODES render and reparse as the same inline semantics."
  (let ((rendered (render-commonmark-inlines nodes)))
    (multiple-value-bind (parsed valid-p)
        (parse-commonmark-paragraph-inlines rendered)
      (and valid-p (inline-nodes-equivalent-p nodes parsed)))))

(defun content-node-native-commonmark-paragraph-p (content)
  (and (content-node-p content)
       (eq :paragraph (content-node-kind content))
       (content-node-inlines content)
       (null (content-node-name content))
       (null (content-node-attributes content))
       (multiple-value-bind (parsed valid-p)
           (case (content-node-source-format content)
             (:org (parse-org-paragraph-inlines (content-node-raw content)))
             (:commonmark
              (parse-commonmark-paragraph-inlines (content-node-raw content)))
             (otherwise (values nil nil)))
         (and valid-p
              (inline-nodes-equivalent-p parsed
                                         (content-node-inlines content))))))
