;;;; Completion: Vertico + Prescient + Marginalia prompt behavior.
;;;;
;;;; The live Emacs configuration uses Prescient inside Vertico minibuffers:
;;;; directional character-folded literal, regexp, or initialism matching for
;;;; every space-separated component, followed by persistent recency/frequency
;;;; sorting.  Orderless
;;;; remains the global completion style outside Vertico and is handled by the
;;;; in-buffer completion work separately.  File prompts deliberately retain
;;;; Lem's path-aware completion and receive ranking only.

(in-package :lem-yath)

(defun completion-label (item)
  (handler-case (lem/completion-mode:completion-item-label item)
    (error () (princ-to-string item))))

(defparameter *completion-history-limit* 100)
(defparameter *completion-frequency-decay* 0.997d0)
(defparameter *completion-frequency-threshold* 0.05d0)

(defvar *completion-history* (make-hash-table :test 'equal))
(defvar *completion-frequency* (make-hash-table :test 'equal))
(defvar *completion-ranking-loaded-p* nil)
(defvar *completion-ranking-dirty-p* nil)
(defvar *completion-current-category* nil)

(defparameter *prescient-default-filter-methods*
  '(:literal :regexp :initialism))
(defparameter *prescient-default-case-folding* :smart)
(defparameter *prescient-default-character-folding-p* t)

(defstruct (completion-prescient-state
             (:constructor make-completion-prescient-state
                 (&key
                    (methods (copy-list *prescient-default-filter-methods*))
                    (case-folding *prescient-default-case-folding*)
                    (character-folding-p
                     *prescient-default-character-folding-p*))))
  "Prompt-local equivalents of Prescient's three toggle variables."
  methods
  case-folding
  character-folding-p)

(defparameter +completion-prescient-state-key+
  'lem-yath-prescient-filter-state)

(defun completion-ranking-pathname ()
  "Persistent Prescient-compatible usage data for prompt candidates."
  (or (alexandria:when-let ((override
                             (uiop:getenv "LEM_YATH_COMPLETION_STATE_FILE")))
        (unless (zerop (length override))
          (pathname override)))
      (merge-pathnames
       "lem-yath/completion-ranking.sexp"
       (uiop:ensure-directory-pathname
        (or (uiop:getenv "XDG_STATE_HOME")
            (merge-pathnames ".local/state/" (user-homedir-pathname)))))))

(defun completion-load-ranking ()
  (unless *completion-ranking-loaded-p*
    (setf *completion-ranking-loaded-p* t)
    (alexandria:when-let ((path (uiop:probe-file*
                                (completion-ranking-pathname))))
      (handler-case
          (with-open-file (stream path :direction :input)
            (let ((*read-eval* nil)
                  (state (read stream nil nil)))
              (when (and (listp state) (eql 1 (getf state :version)))
                (dolist (entry (getf state :history))
                  (when (and (listp entry)
                             (= 2 (length entry))
                             (stringp (first entry))
                             (integerp (second entry)))
                    (setf (gethash (first entry) *completion-history*)
                          (second entry))))
                (dolist (entry (getf state :frequency))
                  (when (and (listp entry)
                             (= 2 (length entry))
                             (stringp (first entry))
                             (numberp (second entry)))
                    (setf (gethash (first entry) *completion-frequency*)
                          (coerce (second entry) 'double-float)))))))
        (error ()
          (clrhash *completion-history*)
          (clrhash *completion-frequency*))))))

(defun completion-hash-entries (table)
  (sort (loop :for key :being :each :hash-key :of table
                :using (hash-value value)
              :collect (list key value))
        #'string-lessp :key #'first))

(defun completion-save-ranking ()
  (when *completion-ranking-dirty-p*
    (handler-case
        (let ((path (completion-ranking-pathname)))
          (ensure-directories-exist path)
          (with-open-file (stream path
                                  :direction :output
                                  :if-exists :supersede
                                  :if-does-not-exist :create)
            (let ((*print-readably* t))
              (print (list :version 1
                           :history (completion-hash-entries
                                     *completion-history*)
                           :frequency (completion-hash-entries
                                       *completion-frequency*))
                     stream)))
          (setf *completion-ranking-dirty-p* nil))
      (error (condition)
        ;; Completion ranking must never prevent a clean editor shutdown.
        (message "Could not save completion ranking: ~a" condition)))))

(defun completion-record-candidate (candidate)
  "Remember CANDIDATE using Prescient's recency and decayed frequency model."
  (completion-load-ranking)
  (unless (or (null candidate) (zerop (length candidate)))
    (let ((old-position (gethash candidate *completion-history*
                                 *completion-history-limit*)))
      (maphash
       (lambda (other position)
         (cond
           ((< position old-position)
            (setf (gethash other *completion-history*) (1+ position)))
           ((>= position (1- *completion-history-limit*))
            (remhash other *completion-history*))))
       *completion-history*)
      (setf (gethash candidate *completion-history*) 0))
    (incf (gethash candidate *completion-frequency* 0d0))
    (maphash
     (lambda (other frequency)
       (let ((decayed (* frequency *completion-frequency-decay*)))
         (if (< decayed *completion-frequency-threshold*)
             (remhash other *completion-frequency*)
             (setf (gethash other *completion-frequency*) decayed))))
     *completion-frequency*)
    (setf *completion-ranking-dirty-p* t)))

(defun completion-candidate-before-p (left right key)
  (let* ((left-label (funcall key left))
         (right-label (funcall key right))
         (left-position (gethash left-label *completion-history*
                                 *completion-history-limit*))
         (right-position (gethash right-label *completion-history*
                                  *completion-history-limit*))
         (left-frequency (gethash left-label *completion-frequency* 0d0))
         (right-frequency (gethash right-label *completion-frequency* 0d0)))
    (or (< left-position right-position)
        (and (= left-position right-position)
             (or (> left-frequency right-frequency)
                 (and (= left-frequency right-frequency)
                      (< (length left-label) (length right-label))))))))

(defun completion-sort-candidates (candidates &key (key #'identity))
  (completion-load-ranking)
  (stable-sort (copy-list candidates)
               (lambda (left right)
                 (completion-candidate-before-p left right key))))

(defun prescient-split-query (query)
  "Split QUERY like Prescient: one space separates; doubled spaces are literal."
  (let* ((query (or query ""))
         (length (length query)))
    (cond
      ((every (lambda (character) (char= character #\Space)) query)
       (if (<= length 1)
           nil
           (list (make-string (1- length) :initial-element #\Space))))
      (t
       (let* ((start (if (and (plusp length)
                              (char= (char query 0) #\Space))
                         1 0))
              (end (if (and (< start length)
                            (char= (char query (1- length)) #\Space))
                       (1- length) length))
              (components '())
              (current (make-string-output-stream))
              (index start))
         (labels ((finish-component ()
                    (let ((component (get-output-stream-string current)))
                      (unless (zerop (length component))
                        (push component components)))
                    (setf current (make-string-output-stream))))
           (loop :while (< index end)
                 :for character := (char query index)
                 :do (if (char/= character #\Space)
                         (progn
                           (write-char character current)
                           (incf index))
                         (let ((run-start index))
                           (loop :while (and (< index end)
                                             (char= (char query index) #\Space))
                                 :do (incf index))
                           (let ((count (- index run-start)))
                             (if (= count 1)
                                 (finish-component)
                                 (loop :repeat (1- count)
                                       :do (write-char #\Space current)))))))
           (finish-component)
           (nreverse components)))))))

(defun prescient-case-sensitive-p
    (query &optional (case-folding *prescient-default-case-folding*))
  (case case-folding
    (:smart (not (null (some #'upper-case-p query))))
    ((nil) t)
    (otherwise nil)))

(defun completion-character-test (case-sensitive-p)
  (if case-sensitive-p #'char= #'char-equal))

(defun completion-literal-matcher (component case-sensitive-p)
  (let ((test (completion-character-test case-sensitive-p)))
    (lambda (candidate)
      (not (null (search component candidate :test test))))))

(defun completion-character-fold-string (text)
  "Return TEXT compatibility-decomposed without Unicode combining marks."
  (handler-case
      (sb-unicode:normalize-string
       text :nfkd
       (lambda (character)
         (not (member (sb-unicode:general-category character)
                      '(:mn :mc :me)))))
    (error () text)))

(defun completion-canonical-string (text)
  "Return TEXT in canonical decomposed form."
  (handler-case (sb-unicode:normalize-string text :nfd)
    (error () text)))

(defparameter *completion-character-fold-punctuation*
  '((#\" . "\"«»“”„‟❝❞❠⹂〝〞〟＂🙶🙷🙸")
    (#\' . "'‘’‚‛‹›❛❜❟❮❯＇")
    (#\` . "``‘‛‹❛❮｀")))

(defun completion-combining-mark-p (character)
  (member (sb-unicode:general-category character) '(:mn :mc :me)))

(defun completion-canonical-clusters (text)
  "Return canonical base-plus-combining-mark clusters for TEXT."
  (let ((clusters '())
        (current nil))
    (labels ((finish-cluster ()
               (when current
                 (push (coerce (nreverse current) 'string) clusters)
                 (setf current nil))))
      (loop :for character :across (completion-canonical-string text)
            :do (if (and current
                         (completion-combining-mark-p character))
                    (push character current)
                    (progn
                      (finish-cluster)
                      (push character current))))
      (finish-cluster)
      (nreverse clusters))))

(defstruct (completion-fold-form
             (:constructor make-completion-fold-form
                 (text unit-map canonicals ranges boundaries)))
  text
  unit-map
  canonicals
  ranges
  boundaries)

(defun completion-build-fold-form (text)
  "Build a compatibility-folded string retaining source-cluster identity."
  (let* ((clusters (completion-canonical-clusters text))
         (folded-units
           (mapcar (lambda (cluster)
                     (let ((folded
                             (completion-character-fold-string cluster)))
                       ;; A standalone combining mark must remain matchable.
                       (if (zerop (length folded)) cluster folded)))
                   clusters))
         (folded-length (reduce #'+ folded-units
                                :key #'length :initial-value 0))
         (folded (make-string folded-length))
         (unit-map (make-array folded-length :element-type 'fixnum))
         (canonicals (coerce clusters 'vector))
         (ranges (make-array (length clusters)))
         (boundaries
           (make-array (1+ folded-length)
                       :element-type 'bit :initial-element 0))
         (offset 0))
    (setf (sbit boundaries 0) 1)
    (loop :for unit :in folded-units
          :for unit-index :from 0
          :for end := (+ offset (length unit))
          :do (replace folded unit :start1 offset)
              (loop :for index :from offset :below end
                    :do (setf (aref unit-map index) unit-index))
              (setf (aref ranges unit-index) (cons offset end)
                    (sbit boundaries end) 1
                    offset end))
    (make-completion-fold-form
     folded unit-map canonicals ranges boundaries)))

(defun completion-fold-character-match-p
    (query-character candidate-character case-sensitive-p)
  (or (funcall (completion-character-test case-sensitive-p)
               query-character candidate-character)
      (alexandria:when-let
          ((equivalents
             (cdr (assoc query-character
                         *completion-character-fold-punctuation*))))
        (find candidate-character equivalents :test #'char=))))

(defun completion-fold-string-equal-p
    (left right case-sensitive-p)
  (and (= (length left) (length right))
       (loop :for left-character :across left
             :for right-character :across right
             :always (funcall (completion-character-test case-sensitive-p)
                              left-character right-character))))

(defun completion-fold-protected-unit-p (canonical)
  "Whether CANONICAL came from an explicitly non-ASCII query cluster."
  (or (/= 1 (length canonical))
      (> (char-code (char canonical 0)) 127)))

(defun completion-fold-protected-units-match-p
    (query candidate candidate-start case-sensitive-p)
  (loop
    :with query-ranges := (completion-fold-form-ranges query)
    :with query-canonicals := (completion-fold-form-canonicals query)
    :with candidate-map := (completion-fold-form-unit-map candidate)
    :with candidate-canonicals :=
      (completion-fold-form-canonicals candidate)
    :for query-unit-index :from 0 :below (length query-canonicals)
    :for canonical := (aref query-canonicals query-unit-index)
    :when (completion-fold-protected-unit-p canonical)
      :unless
        (let* ((query-range (aref query-ranges query-unit-index))
               (candidate-range-start
                 (+ candidate-start (car query-range)))
               (candidate-range-end
                 (+ candidate-start (cdr query-range)))
               (candidate-unit-index
                 (aref candidate-map candidate-range-start)))
          (and (loop :for index :from candidate-range-start
                     :below candidate-range-end
                     :always (= candidate-unit-index
                                (aref candidate-map index)))
               (completion-fold-string-equal-p
                canonical
                (aref candidate-canonicals candidate-unit-index)
                case-sensitive-p)))
        :do (return nil)
    :finally (return t)))

(defun completion-fold-form-match-p
    (query candidate case-sensitive-p &optional start-predicate)
  "Search CANDIDATE for QUERY without splitting compatibility characters."
  (let* ((query-text (completion-fold-form-text query))
         (candidate-text (completion-fold-form-text candidate))
         (query-length (length query-text))
         (candidate-length (length candidate-text))
         (boundaries (completion-fold-form-boundaries candidate)))
    (loop :for start :from 0 :to (- candidate-length query-length)
          :for end := (+ start query-length)
          :when (and (= 1 (sbit boundaries start))
                     (= 1 (sbit boundaries end))
                     (or (null start-predicate)
                         (funcall start-predicate candidate-text start))
                     (loop :for query-index :from 0 :below query-length
                           :always
                             (completion-fold-character-match-p
                              (char query-text query-index)
                              (char candidate-text (+ start query-index))
                              case-sensitive-p))
                     (completion-fold-protected-units-match-p
                      query candidate start case-sensitive-p))
            :do (return t)
          :finally (return nil))))

(defun completion-character-fold-matcher (component case-sensitive-p)
  "Match COMPONENT literally using pinned directional character folding.

An ASCII component can match diacritic, compatibility, and configured quote
variants.  A non-ASCII component is not silently simplified."
  (let ((literal (completion-literal-matcher component case-sensitive-p))
        (query (completion-build-fold-form component))
        (cache (make-hash-table :test 'equal)))
    (lambda (candidate)
      (or (funcall literal candidate)
          (multiple-value-bind (form present-p) (gethash candidate cache)
            (unless present-p
              (setf form (completion-build-fold-form candidate)
                    (gethash candidate cache) form))
            (completion-fold-form-match-p
             query form case-sensitive-p))))))

(defun completion-word-character-p (character)
  (and character
       (or (alphanumericp character)
           (char= character #\_))))

(defun completion-word-boundary-p (text index)
  "Whether INDEX is an Emacs-style word boundary within TEXT."
  (and (< index (length text))
       (not (eql (completion-word-character-p
                  (and (plusp index) (char text (1- index))))
                 (completion-word-character-p (char text index))))))

(defun completion-character-fold-prefix-matcher
    (component case-sensitive-p first-component-p character-folding-p)
  "Match COMPONENT at the candidate or word prefix used by literal-prefix."
  (let ((start-predicate
          (if first-component-p
              (lambda (text index)
                (declare (ignore text))
                (zerop index))
              #'completion-word-boundary-p)))
    (if character-folding-p
        (let ((query (completion-build-fold-form component))
              (cache (make-hash-table :test 'equal)))
          (lambda (candidate)
            (multiple-value-bind (form present-p) (gethash candidate cache)
              (unless present-p
                (setf form (completion-build-fold-form candidate)
                      (gethash candidate cache) form))
              (completion-fold-form-match-p
               query form case-sensitive-p start-predicate))))
        (let ((test (completion-character-test case-sensitive-p)))
          (lambda (candidate)
            (loop :with start := 0
                  :for position := (search component candidate
                                           :start2 start :test test)
                  :while position
                  :when (funcall start-predicate candidate position)
                    :do (return t)
                  :do (setf start (1+ position))
                  :finally (return nil)))))))

(defun completion-fuzzy-match-p (component candidate case-sensitive-p)
  "Whether COMPONENT is a character subsequence of CANDIDATE."
  (let ((test (completion-character-test case-sensitive-p))
        (candidate-index 0))
    (loop :for query-character :across component
          :do (setf candidate-index
                     (or (position query-character candidate
                                   :start candidate-index :test test)
                         (return-from completion-fuzzy-match-p nil)))
              (incf candidate-index)
          :finally (return t))))

(defun completion-word-run-end (text start word-p)
  (loop :for index :from start :below (length text)
        :while (eql word-p
                    (not (null
                          (completion-word-character-p (char text index)))))
        :finally (return index)))

(defun completion-prefix-match-at-p
    (query candidate query-index candidate-index case-sensitive-p)
  "Match Prescient's prefix QUERY at CANDIDATE-INDEX."
  (let ((test (completion-character-test case-sensitive-p)))
    (loop :while (< query-index (length query))
          :for word-p := (not (null
                               (completion-word-character-p
                                (char query query-index))))
          :for query-end := (completion-word-run-end
                             query query-index word-p)
          :for run-length := (- query-end query-index)
          :do (when (> (+ candidate-index run-length)
                       (length candidate))
                (return-from completion-prefix-match-at-p nil))
              (unless (loop :for offset :from 0 :below run-length
                            :always
                              (and (eql word-p
                                        (not (null
                                              (completion-word-character-p
                                               (char candidate
                                                     (+ candidate-index
                                                        offset))))))
                                   (funcall test
                                            (char query (+ query-index offset))
                                            (char candidate
                                                  (+ candidate-index offset)))))
                (return-from completion-prefix-match-at-p nil))
              (incf candidate-index run-length)
              (setf query-index query-end)
              (when (and word-p (< query-index (length query)))
                (loop :while (and (< candidate-index (length candidate))
                                  (completion-word-character-p
                                   (char candidate candidate-index)))
                      :do (incf candidate-index)))
          :finally (return t))))

(defun completion-prefix-match-p (query candidate case-sensitive-p)
  "Whether QUERY matches Prescient's word-prefix method in CANDIDATE."
  (when (plusp (length query))
    (let ((query-starts-with-word-p
            (completion-word-character-p (char query 0))))
      (loop :for index :from 0 :below (length candidate)
            :when (and (if query-starts-with-word-p
                           (completion-word-boundary-p candidate index)
                           t)
                       (completion-prefix-match-at-p
                        query candidate 0 index case-sensitive-p))
              :do (return t)
            :finally (return nil)))))

(defun completion-anchored-query-segments (query)
  "Split QUERY at capitals and symbols like Prescient's anchored method."
  (let ((segments '())
        (index 0))
    (loop :while (< index (length query))
          :for start := index
          :for character := (char query index)
          :do (cond
                ((upper-case-p character)
                 (incf index)
                 (loop :while (and (< index (length query))
                                   (lower-case-p (char query index)))
                       :do (incf index)))
                ((lower-case-p character)
                 (incf index)
                 (loop :while (and (< index (length query))
                                   (lower-case-p (char query index)))
                       :do (incf index)))
                ((not (completion-word-character-p character))
                 (incf index)
                 (loop :while (and (< index (length query))
                                   (lower-case-p (char query index)))
                       :do (incf index)))
                (t
                 (incf index)
                 (loop :while (and (< index (length query))
                                   (completion-word-character-p
                                    (char query index))
                                   (not (upper-case-p (char query index))))
                       :do (incf index))))
              (push (string-downcase (subseq query start index)) segments))
    (nreverse segments)))

(defun completion-string-match-at-p
    (needle haystack index case-sensitive-p)
  (and (<= (+ index (length needle)) (length haystack))
       (loop :for needle-character :across needle
             :for haystack-index :from index
             :always (funcall (completion-character-test case-sensitive-p)
                              needle-character
                              (char haystack haystack-index)))))

(defun completion-anchored-match-p (query candidate case-sensitive-p)
  "Whether QUERY matches Prescient's capital/symbol anchored method."
  (let ((cursor 0))
    (loop :for segment :in (completion-anchored-query-segments query)
          :for first-segment-p := t :then nil
          :do
      (let ((position
              (loop :for index :from cursor :below (length candidate)
                    :when (and (not first-segment-p)
                               (char= (char candidate index) #\/))
                      :do (return nil)
                    :when (and (completion-word-boundary-p candidate index)
                               (completion-string-match-at-p
                                segment candidate index case-sensitive-p))
                      :do (return index)
                    :finally (return nil))))
        (unless position
          (return-from completion-anchored-match-p nil))
        (setf cursor (+ position (length segment))))
          :finally (return t))))

(defun prescient-regexp-scanner (component case-sensitive-p)
  "Compile COMPONENT once for a candidate batch, or return NIL if invalid."
  (handler-case
      (ppcre:create-scanner
       component :case-insensitive-mode (not case-sensitive-p))
    (error () nil)))

(defun prescient-initials (label)
  (coerce
   (loop :for index :from 0 :below (length label)
         :for character := (char label index)
         :when (and (alphanumericp character)
                    (or (zerop index)
                        (not (alphanumericp (char label (1- index))))))
           :collect character)
   'string))

(defun prescient-initialism-match-p (component label case-sensitive-p)
  (search component (prescient-initials label)
          :test (if case-sensitive-p #'char= #'char-equal)))

(defun prescient-method-matcher
    (method component component-index case-sensitive-p character-folding-p)
  "Compile one Prescient METHOD for COMPONENT."
  (case method
    (:literal
     (if character-folding-p
         (completion-character-fold-matcher component case-sensitive-p)
         (completion-literal-matcher component case-sensitive-p)))
    (:literal-prefix
     (completion-character-fold-prefix-matcher
      component case-sensitive-p (zerop component-index)
      character-folding-p))
    (:regexp
     (alexandria:when-let
         ((scanner (prescient-regexp-scanner component case-sensitive-p)))
       (lambda (candidate) (not (null (ppcre:scan scanner candidate))))))
    (:initialism
     (lambda (candidate)
       (prescient-initialism-match-p component candidate case-sensitive-p)))
    (:fuzzy
     (lambda (candidate)
       (completion-fuzzy-match-p component candidate case-sensitive-p)))
    (:prefix
     (lambda (candidate)
       (completion-prefix-match-p component candidate case-sensitive-p)))
    (:anchored
     (lambda (candidate)
       (completion-anchored-match-p component candidate case-sensitive-p)))))

(defun prescient-component-matcher
    (component component-index case-sensitive-p methods character-folding-p)
  "Compile active Prescient METHODS for one query COMPONENT."
  (let ((matchers
          (remove nil
                  (mapcar (lambda (method)
                            (prescient-method-matcher
                             method component component-index case-sensitive-p
                             character-folding-p))
                          methods))))
    (lambda (label)
      (some (lambda (matcher) (funcall matcher label)) matchers))))

(defun completion-prompt-prescient-state (&optional create-p)
  "Return the active prompt's Prescient state, optionally creating it."
  (alexandria:when-let ((prompt
                         (lem/prompt-window:current-prompt-window)))
    (let ((buffer (window-buffer prompt)))
      (when (eq buffer (current-buffer))
        (or (buffer-value buffer +completion-prescient-state-key+)
            (when create-p
              (setf (buffer-value buffer +completion-prescient-state-key+)
                    (make-completion-prescient-state))))))))

(defun completion-prescient-settings ()
  "Return active prompt settings or the configured global defaults."
  (let ((state (completion-prompt-prescient-state)))
    (values (if state
                (completion-prescient-state-methods state)
                *prescient-default-filter-methods*)
            (if state
                (completion-prescient-state-case-folding state)
                *prescient-default-case-folding*)
            (if state
                (completion-prescient-state-character-folding-p state)
                *prescient-default-character-folding-p*))))

(defun prescient-filter (input candidates
                         &key (key #'identity) (category :generic)
                           (rank-p t))
  "Filter and rank CANDIDATES like the active Vertico-Prescient setup.

By default, every query component may match as a character-folded literal,
regexp, or initialism; prompt-local M-s controls can change that method set.
All components must match.  Character folding is directional and uppercase
input makes smart matching case-sensitive.  When RANK-P is false, preserve the
provider's source-defined order."
  (setf *completion-current-category* category)
  (multiple-value-bind (methods case-folding character-folding-p)
      (completion-prescient-settings)
    (let* ((components (prescient-split-query input))
           (case-sensitive-p
             (prescient-case-sensitive-p (or input "") case-folding))
           (matchers
             (loop :for component :in components
                   :for component-index :from 0
                   :collect (prescient-component-matcher
                             component component-index case-sensitive-p
                             methods character-folding-p)))
           (filtered
             (if (null matchers)
                 candidates
                 (remove-if-not
                  (lambda (candidate)
                    (let ((label (funcall key candidate)))
                      (every (lambda (matcher)
                               (funcall matcher label))
                             matchers)))
                  candidates))))
      (if rank-p
          (completion-sort-candidates filtered :key key)
          filtered))))

(defvar *default-command-completion* *prompt-command-completion-function*)
(defvar *default-buffer-completion* *prompt-buffer-completion-function*)
(defvar *default-file-completion* *prompt-file-completion-function*)

(setf *prompt-command-completion-function*
      (lambda (input &rest args)
        (prescient-filter input
                          (apply *default-command-completion* "" args)
                          :key #'completion-label
                          :category :command)))

(setf *prompt-buffer-completion-function*
      (lambda (input &rest args)
        (prescient-filter input
                          (apply *default-buffer-completion* "" args)
                          :key #'completion-label
                          :category :buffer)))

(setf *prompt-file-completion-function*
      (lambda (input directory &rest args)
        (setf *completion-current-category* :file)
        (completion-sort-candidates
         (apply *default-file-completion* input directory args)
         :key #'completion-label)))

(defun completion-file-history-label (input)
  (let* ((trailing-slash-p
           (and (plusp (length input))
                (char= (char input (1- (length input))) #\/)))
         (components (remove-if
                      (lambda (component) (zerop (length component)))
                      (uiop:split-string input :separator "/")))
         (last (car (last components))))
    (when last
      (if trailing-slash-p
          (concatenate 'string last "/")
          last))))

(defun completion-record-current-prompt ()
  (alexandria:when-let ((prompt
                         (lem/prompt-window:current-prompt-window)))
    (let* ((input (lem/prompt-window::get-input-string))
           (test (lem/prompt-window::prompt-window-existing-test-function
                  prompt)))
      (when (and (plusp (length input))
                 (or (null test) (funcall test input)))
        (completion-record-candidate
         (if (eq *completion-current-category* :file)
             (completion-file-history-label input)
             input))))))

(define-command lem-yath-prompt-execute () ()
  "Execute the current prompt and remember valid completion choices."
  (completion-record-current-prompt)
  (lem/prompt-window::prompt-execute))

(define-key lem/prompt-window::*prompt-mode-keymap*
  "Return" 'lem-yath-prompt-execute)

(define-command lem-yath-prompt-beginning-of-line () ()
  "Move to the line beginning without crossing the prompt's editable field."
  (let ((point (current-point))
        (input-start (lem/prompt-window::current-prompt-start-point)))
    (line-start point)
    (when (point< point input-start)
      (move-point point input-start))))

(define-command lem-yath-prompt-kill-line (argument) (:universal-nil)
  "Kill to the end of the prompt line and refresh visible completion."
  (unless (end-buffer-p (current-point))
    (call-command 'kill-line argument)
    (lem/completion-mode:completion-refresh)))

(defun completion-clamp-point-to-prompt-input ()
  (let ((point (current-point))
        (input-start (lem/prompt-window::current-prompt-start-point)))
    (when (point< point input-start)
      (move-point point input-start))))

(define-command lem-yath-prompt-backward-char (&optional (argument 1))
    (:universal)
  "Move backward without crossing the prompt's editable field."
  (character-offset (current-point) (- argument))
  (completion-clamp-point-to-prompt-input))

(define-command lem-yath-prompt-previous-word (&optional (argument 1))
    (:universal)
  "Move backward by words without crossing the prompt's editable field."
  (call-command 'previous-word argument)
  (completion-clamp-point-to-prompt-input))

(define-command lem-yath-prompt-backward-delete-word (&optional (argument 1))
    (:universal)
  "Kill words backward without deleting the protected prompt label."
  (let ((point (current-point))
        (input-start (lem/prompt-window::current-prompt-start-point)))
    (with-point ((origin point :left-inserting))
      (call-command 'previous-word argument)
      (when (point< point input-start)
        (move-point point input-start))
      (cond
        ((point< point origin)
         (lem/common/killring:with-killring-context (:before-inserting t)
           (kill-region point origin)))
        ((point< origin point)
         (kill-region origin point)
         (move-point point origin))))
    (lem/completion-mode:completion-refresh)))

(define-command lem-yath-prompt-delete-next-char (argument) (:universal-nil)
  "Delete forward and refresh visible prompt completion."
  (call-command 'delete-next-char argument)
  (lem/completion-mode:completion-refresh))

(define-command lem-yath-prompt-delete-word (&optional (argument 1))
    (:universal)
  "Kill forward by words and refresh visible prompt completion."
  (when (minusp argument)
    (editor-error "Prompt M-d does not delete before the editable field"))
  (call-command 'delete-word argument)
  (lem/completion-mode:completion-refresh))

(defparameter +completion-prompt-last-command-key+
  'lem-yath-completion-prompt-last-command)
(defparameter +completion-prompt-yank-range-key+
  'lem-yath-completion-prompt-yank-range)

(defun completion-release-prompt-yank-range (&optional (buffer (current-buffer)))
  "Release BUFFER's tracked prompt-yank points."
  (alexandria:when-let ((range (buffer-value
                                buffer +completion-prompt-yank-range-key+)))
    (delete-point (car range))
    (delete-point (cdr range))
    (setf (buffer-value buffer +completion-prompt-yank-range-key+) nil)))

(defun completion-record-prompt-yank-from (buffer start)
  "Own START through BUFFER's point as its latest prompt yank."
  (completion-release-prompt-yank-range buffer)
  (setf (buffer-value buffer +completion-prompt-yank-range-key+)
        (cons start (copy-point (buffer-point buffer) :left-inserting))))

(define-command lem-yath-prompt-yank (argument) (:universal-nil)
  "Yank into the prompt and refresh visible completion."
  (completion-clamp-point-to-prompt-input)
  (let ((buffer (current-buffer))
        (start (copy-point (current-point) :right-inserting))
        (recorded-p nil))
    (unwind-protect
         (progn
           (let ((lem/buffer/internal:*inhibit-read-only* t))
             (call-command 'yank argument))
           (completion-record-prompt-yank-from buffer start)
           (setf recorded-p t))
      (unless recorded-p
        (delete-point start))))
  (completion-refresh-or-open-prompt))

(define-command lem-yath-prompt-yank-pop (&optional (argument 1))
    (:universal)
  "Replace the preceding prompt yank from the kill ring and refresh."
  (let* ((buffer (current-buffer))
         (point (buffer-point buffer))
         (range (buffer-value buffer
                             +completion-prompt-yank-range-key+)))
    (if (and range
             (member
              (buffer-value buffer
                            +completion-prompt-last-command-key+)
              '(lem-core/commands/edit:yank
                lem-core/commands/edit:yank-pop
                lem-yath-prompt-yank
                lem-yath-completion-prompt-yank-pop)))
        (let ((start (car range))
              (end (cdr range)))
          (delete-between-points start end)
          (move-point point start)
          (completion-release-prompt-yank-range buffer)
          (lem/common/killring:rotate-killring (current-killring))
          (let ((new-start (copy-point point :right-inserting))
                (recorded-p nil))
            (unwind-protect
                 (progn
                   (let ((lem/buffer/internal:*inhibit-read-only* t))
                     (lem-core/commands/edit::yank-1 argument))
                   (completion-record-prompt-yank-from buffer new-start)
                   (setf recorded-p t))
              (unless recorded-p
                (delete-point new-start)))))
        (message "Previous command was not a prompt yank")))
  (completion-refresh-or-open-prompt))

(define-command lem-yath-prompt-transpose-characters () ()
  "Transpose input characters without touching the prompt label."
  (let* ((point (current-point))
         (input-start (lem/prompt-window::current-prompt-start-point))
         (input-offset (- (position-at-point point)
                          (position-at-point input-start))))
    (when (if (end-line-p point)
              (> input-offset 1)
              (plusp input-offset))
      (call-command 'transpose-characters nil)
      (lem/completion-mode:completion-refresh))))

(dolist (keymap (list lem/prompt-window::*prompt-mode-keymap*
                      lem/completion-mode::*completion-mode-keymap*))
  (define-key keymap "C-a" 'lem-yath-prompt-beginning-of-line)
  (define-key keymap "Home" 'lem-yath-prompt-beginning-of-line)
  (define-key keymap "C-e" 'move-to-end-of-line)
  (define-key keymap "End" 'move-to-end-of-line)
  (define-key keymap "C-b" 'lem-yath-prompt-backward-char)
  (define-key keymap "Left" 'lem-yath-prompt-backward-char)
  (define-key keymap "C-f" 'forward-char)
  (define-key keymap "Right" 'forward-char)
  (define-key keymap "M-b" 'lem-yath-prompt-previous-word)
  (define-key keymap "C-Left" 'lem-yath-prompt-previous-word)
  (define-key keymap "M-f" 'forward-word)
  (define-key keymap "C-Right" 'forward-word)
  (define-key keymap "C-k" 'lem-yath-prompt-kill-line)
  (define-key keymap "C-d" 'lem-yath-prompt-delete-next-char)
  (define-key keymap "Delete" 'lem-yath-prompt-delete-next-char)
  (define-key keymap "M-d" 'lem-yath-prompt-delete-word)
  (define-key keymap "C-Delete" 'lem-yath-prompt-delete-word)
  (define-key keymap "C-y" 'lem-yath-prompt-yank)
  (define-key keymap "C-t" 'lem-yath-prompt-transpose-characters))

(defun completion-prompt-active-p ()
  (alexandria:when-let ((prompt
                         (lem/prompt-window:current-prompt-window)))
    (eq (current-buffer) (window-buffer prompt))))

(defun completion-refresh-or-open-prompt ()
  "Refresh prompt completion, reopening it after a zero-result edit."
  (when (completion-prompt-active-p)
    (if lem/completion-mode::*completion-context*
        (lem/completion-mode:completion-refresh)
        (lem/prompt-window::open-prompt-completion))))

(defun completion-record-prompt-command ()
  "Record the most recently completed prompt command for yank-pop continuity."
  (when (completion-prompt-active-p)
    (setf (buffer-value (current-buffer)
                        +completion-prompt-last-command-key+)
          (command-name (this-command)))))

(remove-hook *post-command-hook* 'completion-record-prompt-command)
(add-hook *post-command-hook* 'completion-record-prompt-command
          most-negative-fixnum)

(defun completion-prompt-region-or-error ()
  "Return the active prompt region after enforcing its editable boundary."
  (let* ((point (current-point))
         (mark (cursor-mark point))
         (mark-point (and (mark-active-p mark) (mark-point mark)))
         (input-start (lem/prompt-window::current-prompt-start-point)))
    (unless (and mark-point
                 (eq (point-buffer point) (point-buffer mark-point))
                 (not (point< point input-start))
                 (not (point< mark-point input-start)))
      (editor-error "No protected prompt region"))
    (values point mark-point)))

(define-command lem-yath-prompt-set-mark (argument) (:universal-nil)
  "Set the prompt mark without exposing the cross-buffer mark ring."
  (when argument
    (editor-error "Prompt mark-ring traversal is unavailable"))
  ;; SET-CURSOR-MARK runs the Vi buffer-mark hook and changes a prompt to
  ;; Visual state.  Own the minibuffer-style mark directly so C-w returns to
  ;; the prompt's editing state instead of Vi Normal state.
  (mark-set-point (cursor-mark (current-point)) (current-point))
  (message "Mark set"))

(define-command lem-yath-prompt-exchange-point-mark () ()
  "Exchange point and mark inside the prompt's editable field."
  (multiple-value-bind (point mark-point)
      (completion-prompt-region-or-error)
    (with-point ((old-point point :temporary))
      (move-point point mark-point)
      (mark-set-point (cursor-mark point) old-point))))

(define-command lem-yath-prompt-kill-region () ()
  "Kill an active prompt region and refresh visible completion."
  (completion-prompt-region-or-error)
  (call-command 'kill-region nil)
  (completion-refresh-or-open-prompt))

(define-command lem-yath-prompt-copy-region () ()
  "Copy an active prompt region and retain visible completion."
  (completion-prompt-region-or-error)
  (call-command 'copy-region nil)
  (completion-refresh-or-open-prompt))

(defun completion-replay-key-after-completion ()
  "Close ordinary completion and replay its current physical key."
  (let ((keys (last-read-key-sequence)))
    (lem/completion-mode:completion-end)
    (unread-key-sequence keys)))

(define-command lem-yath-completion-prompt-set-mark (argument)
    (:universal-nil)
  (if (completion-prompt-active-p)
      (call-command 'lem-yath-prompt-set-mark argument)
      (completion-replay-key-after-completion)))

(define-command lem-yath-completion-prompt-exchange-point-mark () ()
  (if (completion-prompt-active-p)
      (call-command 'lem-yath-prompt-exchange-point-mark nil)
      (completion-replay-key-after-completion)))

(define-command lem-yath-completion-prompt-kill-region () ()
  (if (completion-prompt-active-p)
      (call-command 'lem-yath-prompt-kill-region nil)
      (completion-replay-key-after-completion)))

(define-command lem-yath-completion-prompt-copy-region () ()
  (if (completion-prompt-active-p)
      (call-command 'lem-yath-prompt-copy-region nil)
      (completion-replay-key-after-completion)))

(define-command lem-yath-completion-prompt-yank-pop
    (&optional (argument 1))
    (:universal)
  (if (completion-prompt-active-p)
      (call-command 'lem-yath-prompt-yank-pop argument)
      (completion-replay-key-after-completion)))

(dolist (keymap (list lem/prompt-window::*prompt-mode-keymap*
                      lem/completion-mode::*completion-mode-keymap*))
  (define-key keymap "C-Space" 'lem-yath-completion-prompt-set-mark)
  (define-key keymap "C-@" 'lem-yath-completion-prompt-set-mark)
  (define-key keymap "C-x C-x"
    'lem-yath-completion-prompt-exchange-point-mark)
  (define-key keymap "C-w" 'lem-yath-completion-prompt-kill-region)
  (define-key keymap "M-w" 'lem-yath-completion-prompt-copy-region)
  (define-key keymap "M-y" 'lem-yath-completion-prompt-yank-pop))

(defun completion-reset-prompt-undo-history ()
  "Keep prompt construction outside the user's editable undo history."
  (when (completion-prompt-active-p)
    (let ((buffer (current-buffer)))
      (buffer-disable-undo buffer)
      (buffer-enable-undo buffer)
      ;; Prompt marks deliberately bypass Vi's state-changing mark hooks.
      (mark-cancel (cursor-mark (buffer-point buffer)))
      (completion-release-prompt-yank-range buffer)
      (setf (buffer-value buffer +completion-prompt-last-command-key+) nil))))

(remove-hook *prompt-after-activate-hook*
             'completion-reset-prompt-undo-history)
(add-hook *prompt-after-activate-hook*
          'completion-reset-prompt-undo-history
          most-negative-fixnum)

(define-command lem-yath-prompt-undo (&optional (argument 1))
    (:universal)
  "Undo editable prompt input without entering the protected label."
  (unless (plusp argument)
    (editor-error "Prompt undo count must be positive"))
  (dotimes (_ argument)
    (unless (buffer-undo (current-point))
      (editor-error "No prompt edit to undo")))
  (completion-refresh-or-open-prompt))

(define-command lem-yath-completion-prompt-undo
    (&optional (argument 1))
    (:universal)
  "Undo a prompt, or replay the key after leaving ordinary completion."
  (if (completion-prompt-active-p)
      (call-command 'lem-yath-prompt-undo argument)
      (completion-replay-key-after-completion)))

(dolist (keymap (list lem/prompt-window::*prompt-mode-keymap*
                      lem/completion-mode::*completion-mode-keymap*))
  (define-key keymap "C-/" 'lem-yath-completion-prompt-undo)
  (define-key keymap "C-_" 'lem-yath-completion-prompt-undo)
  (define-key keymap "C-x u" 'lem-yath-completion-prompt-undo))

(define-command lem-yath-completion-backward-delete-word
    (&optional (argument 1))
    (:universal)
  "Delete words through the active prompt or in-buffer completion context."
  (if (completion-prompt-active-p)
      (call-command 'lem-yath-prompt-backward-delete-word argument)
      (call-command 'lem/completion-mode::completion-backward-delete-word
                    argument)))

(dolist (keymap (list lem/prompt-window::*prompt-mode-keymap*
                      lem/completion-mode::*completion-mode-keymap*))
  (define-key keymap "M-Backspace"
    'lem-yath-completion-backward-delete-word)
  (define-key keymap "C-Backspace"
    'lem-yath-completion-backward-delete-word)
  (define-key keymap "C-M-h" 'lem-yath-completion-backward-delete-word))

(define-key lem/completion-mode::*completion-mode-keymap*
  'backward-delete-word 'lem-yath-completion-backward-delete-word)

(defun completion-prescient-state-or-error ()
  (or (completion-prompt-prescient-state t)
      (editor-error "Prescient toggles are only available in prompts")))

(defun completion-prescient-methods-description (methods)
  (format nil "~{~a~^ ~}"
          (mapcar (lambda (method)
                    (string-downcase (symbol-name method)))
                  methods)))

(defun completion-refresh-prescient-prompt ()
  "Refresh or reopen the current prompt completion after a toggle."
  (if lem/completion-mode::*completion-context*
      (lem/completion-mode:completion-refresh)
      (lem/prompt-window::open-prompt-completion)))

(defun completion-toggle-prescient-method (method exclusive-p)
  "Toggle METHOD prompt-locally, or make it exclusive when EXCLUSIVE-P."
  (let* ((state (completion-prescient-state-or-error))
         (methods (completion-prescient-state-methods state)))
    (cond
      (exclusive-p
       (setf (completion-prescient-state-methods state) (list method)))
      ((equal methods (list method))
       (editor-error "Cannot toggle off the only active Prescient method: ~a"
                     (string-downcase (symbol-name method))))
      ((member method methods)
       (setf (completion-prescient-state-methods state)
             (remove method methods)))
      (t
       (push method (completion-prescient-state-methods state))))
    (message "Prescient filter is now ~a"
             (completion-prescient-methods-description
              (completion-prescient-state-methods state)))
    (completion-refresh-prescient-prompt)))

(define-command lem-yath-prescient-toggle-anchored (argument)
    (:universal-nil)
  (completion-toggle-prescient-method :anchored (not (null argument))))

(define-command lem-yath-prescient-toggle-fuzzy (argument)
    (:universal-nil)
  (completion-toggle-prescient-method :fuzzy (not (null argument))))

(define-command lem-yath-prescient-toggle-initialism (argument)
    (:universal-nil)
  (completion-toggle-prescient-method :initialism (not (null argument))))

(define-command lem-yath-prescient-toggle-literal (argument)
    (:universal-nil)
  (completion-toggle-prescient-method :literal (not (null argument))))

(define-command lem-yath-prescient-toggle-literal-prefix (argument)
    (:universal-nil)
  (completion-toggle-prescient-method :literal-prefix (not (null argument))))

(define-command lem-yath-prescient-toggle-prefix (argument)
    (:universal-nil)
  (completion-toggle-prescient-method :prefix (not (null argument))))

(define-command lem-yath-prescient-toggle-regexp (argument)
    (:universal-nil)
  (completion-toggle-prescient-method :regexp (not (null argument))))

(define-command lem-yath-prescient-toggle-character-folding () ()
  (let ((state (completion-prescient-state-or-error)))
    (setf (completion-prescient-state-character-folding-p state)
          (not (completion-prescient-state-character-folding-p state)))
    (message "Character folding toggled ~:[off~;on~]"
             (completion-prescient-state-character-folding-p state))
    (completion-refresh-prescient-prompt)))

(define-command lem-yath-prescient-toggle-case-folding () ()
  (let ((state (completion-prescient-state-or-error)))
    (setf (completion-prescient-state-case-folding state)
          (if (completion-prescient-state-case-folding state)
              nil
              *prescient-default-case-folding*))
    (message "~:[Case folding toggled off~;Smart case folding toggled on~]"
             (completion-prescient-state-case-folding state))
    (completion-refresh-prescient-prompt)))

(defun completion-bind-prescient-toggle-map (keymap)
  (define-key keymap "M-s a" 'lem-yath-prescient-toggle-anchored)
  (define-key keymap "M-s f" 'lem-yath-prescient-toggle-fuzzy)
  (define-key keymap "M-s i" 'lem-yath-prescient-toggle-initialism)
  (define-key keymap "M-s l" 'lem-yath-prescient-toggle-literal)
  (define-key keymap "M-s P" 'lem-yath-prescient-toggle-literal-prefix)
  (define-key keymap "M-s p" 'lem-yath-prescient-toggle-prefix)
  (define-key keymap "M-s r" 'lem-yath-prescient-toggle-regexp)
  (define-key keymap "M-s '" 'lem-yath-prescient-toggle-character-folding)
  (define-key keymap "M-s c" 'lem-yath-prescient-toggle-case-folding))

(completion-bind-prescient-toggle-map
 lem/prompt-window::*prompt-mode-keymap*)
(completion-bind-prescient-toggle-map
 lem/completion-mode::*completion-mode-keymap*)

;; Completion mode's fallback self-insert consumes C-u before prompt or global
;; keymaps see it.  Dispatch it explicitly so Prescient's documented
;; C-u M-s KEY exclusive form reaches Lem's universal-argument reader.  Outside
;; a prompt, close the popup and replay C-u so ordinary Evil editing retains its
;; configured delete-to-indentation behavior.
(define-command lem-yath-completion-control-u () ()
  (if (completion-prompt-active-p)
      (call-command 'lem/universal-argument:universal-argument nil)
      (progn
        (lem/completion-mode:completion-end)
        (unread-key-sequence (last-read-key-sequence)))))

(define-key lem/prompt-window::*prompt-mode-keymap*
  "C-u" 'lem/universal-argument:universal-argument)
(define-key lem/completion-mode::*completion-mode-keymap*
  "C-u" 'lem-yath-completion-control-u)

(defun completion-prompt-context ()
  "Return the current, fully presented prompt completion context."
  (alexandria:when-let* ((prompt
                          (lem/prompt-window:current-prompt-window))
                         (context
                          lem/completion-mode::*completion-context*)
                         (popup
                          (lem/completion-mode::context-popup-menu context)))
    (when (and (eq (current-buffer) (window-buffer prompt))
               (eq (lem/completion-mode::context-buffer context)
                   (current-buffer))
               (= (lem/completion-mode::context-presented-generation context)
                  (lem/completion-mode::context-generation context)))
      context)))

(defun completion-focused-item ()
  (alexandria:when-let* ((context (completion-prompt-context))
                         (popup
                          (lem/completion-mode::context-popup-menu context)))
    (lem/popup-menu:get-focus-item popup)))

(define-command lem-yath-completion-return () ()
  "Accept the focused prompt candidate and submit it with one Return."
  (cond
    ((completion-prompt-active-p)
     (let ((prompt (lem/prompt-window:current-prompt-window)))
       (alexandria:if-let ((context (completion-prompt-context)))
         (let ((popup (lem/completion-mode::context-popup-menu context)))
           (lem:popup-menu-select popup)
           ;; Acceptance normally closes CONTEXT.  Do not submit stale input
           ;; if a callback refused selection or opened a replacement.
           (when (and (eq prompt
                          (lem/prompt-window:current-prompt-window))
                      (null lem/completion-mode::*completion-context*))
             (lem-yath-prompt-execute)))
         (lem-yath-prompt-execute))))
    ((and (fboundp 'auto-completion-session-owned-p)
          (funcall 'auto-completion-session-owned-p))
     (funcall 'auto-completion-return))
    (t
     (lem/completion-mode::completion-select))))

(define-command lem-yath-completion-tab () ()
  "Insert the focused prompt candidate without closing the prompt."
  (cond
    ((completion-prompt-active-p)
     (alexandria:when-let ((item (completion-focused-item)))
       (lem/completion-mode::completion-insert (current-point) item)
       (lem/completion-mode:completion-refresh)))
    ((and (fboundp 'auto-completion-session-owned-p)
          (funcall 'auto-completion-session-owned-p))
     (funcall 'auto-completion-tab))
    (t
     (lem/completion-mode::completion-narrowing-down-or-next-line))))

(defun completion-prompt-history (command)
  "Run prompt history COMMAND and reopen automatic completion."
  (lem/completion-mode:completion-end)
  (funcall command)
  (lem/prompt-window::open-prompt-completion))

(define-command lem-yath-completion-previous-history () ()
  "Use M-p for prompt history and retain candidate movement elsewhere."
  (if (completion-prompt-active-p)
      (completion-prompt-history
       #'lem/prompt-window::prompt-previous-history)
      (lem/completion-mode::completion-previous-line)))

(define-command lem-yath-completion-next-history () ()
  "Use M-n for prompt history and retain candidate movement elsewhere."
  (if (completion-prompt-active-p)
      (completion-prompt-history
       #'lem/prompt-window::prompt-next-history)
      (lem/completion-mode::completion-next-line)))

(define-key lem/completion-mode::*completion-mode-keymap*
  "Return" 'lem-yath-completion-return)
(define-key lem/completion-mode::*completion-mode-keymap*
  "Tab" 'lem-yath-completion-tab)
(define-key lem/completion-mode::*completion-mode-keymap*
  "M-p" 'lem-yath-completion-previous-history)
(define-key lem/completion-mode::*completion-mode-keymap*
  "M-n" 'lem-yath-completion-next-history)
(define-key lem/prompt-window::*prompt-mode-keymap*
  "M-p" 'lem-yath-completion-previous-history)
(define-key lem/prompt-window::*prompt-mode-keymap*
  "M-n" 'lem-yath-completion-next-history)

(defun completion-reset-current-category ()
  (setf *completion-current-category* nil))

(add-hook *prompt-activate-hook* 'completion-reset-current-category)
(add-hook *exit-editor-hook* 'completion-save-ranking)

;; vertico-like: show the candidate list immediately, not only on TAB.
(setf *automatic-tab-completion* t)

;; Lem binds Space in the completion popup to insert-space-and-cancel,
;; which kills multi-token Prescient input ("roam fi" closes the popup at
;; the space). In a prompt, Space must insert and re-filter instead; in
;; ordinary buffers the stock cancel behavior is right (a space ends the
;; symbol being completed).
(define-command lem-yath-completion-space () ()
  "Insert a space; in a prompt, keep filtering the completion popup."
  (insert-character (current-point) #\Space)
  (let ((prompt (lem/prompt-window:current-prompt-window)))
    (cond
      ((and prompt (eq (current-buffer) (window-buffer prompt)))
       (lem/completion-mode:completion-refresh))
      ((lem/completion-mode:completion-local-filtering-p)
       (lem/completion-mode:completion-refresh))
      (t
       (lem/completion-mode:completion-end)))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "Space" 'lem-yath-completion-space)

;;; Vertico-style zero-result recovery ---------------------------------------

(defparameter *prompt-completion-edit-commands*
  '(lem/completion-mode::completion-self-insert
    lem/completion-mode::completion-delete-previous-char
    lem/completion-mode::completion-backward-delete-word
    lem-yath-completion-space)
  "Completion commands that can end a prompt context after editing its input.")

(defun prompt-completion-edit-command-p (command)
  "Whether COMMAND may have edited the current prompt input.

Ordinary prompt edits carry Lem's EDITABLE-ADVICE marker.  Completion-mode's
fallback editing commands do not, so name those explicitly."
  (and command
       (or (typep command 'lem:editable-advice)
           (member (command-name command)
                   *prompt-completion-edit-commands*))))

(defun reopen-empty-prompt-completion-after-command ()
  "Reopen automatic prompt completion after a zero-result edit.

Lem ends a synchronous completion context when its provider returns no items.
Keep that ordinary lifecycle for non-prompt completion, but let the next prompt
edit query the provider again like Vertico.  This covers both deleting back
into a valid query and regexp input that becomes valid after another character."
  (when (and (completion-prompt-active-p)
             (null lem/completion-mode::*completion-context*)
             (prompt-completion-edit-command-p (this-command)))
    (lem/prompt-window::open-prompt-completion)))

(remove-hook *post-command-hook*
             'reopen-empty-prompt-completion-after-command)
(add-hook *post-command-hook*
          'reopen-empty-prompt-completion-after-command)
