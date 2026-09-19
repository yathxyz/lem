(defpackage :lem-tests/display-cache
  (:use :cl :rove :lem-core))
(in-package :lem-tests/display-cache)

;; These display constructors are internal; exercise their output directly to
;; cover character-run boundaries and ownership without a frontend renderer.
(defun reference-character-runs (string)
  (let ((runs '()))
    (loop :for char :across string
          :for type := (lem-core::char-type char)
          :do (if (and runs (not (eq type :control)) (eq type (caar runs)))
                  (setf (cdar runs) (concatenate 'string (cdar runs) (string char)))
                  (push (cons type (string char)) runs)))
    (nreverse runs)))

(deftest drawing-character-runs
  (let* ((attribute (make-attribute :foreground "red"))
         (pieces (list "a" "漢" "⠁" "😀" "📁" (icon-string "lock")
                       (string #\Tab) (string #\Newline) (string (code-char #x200b))))
         (cases (append (list "" "plain text" "漢字" "é")
                        (loop :for a :in pieces
                              :append (loop :for b :in pieces
                                            :append (loop :for c :in pieces
                                                          :collect (concatenate 'string a b c))))))
         (correct t))
    (dolist (string cases)
      (let* ((runs (reference-character-runs string))
             (objects (lem-core::create-drawing-object
                       (lem-core::make-string-with-attribute-item
                        :string string :attribute attribute)))
             (expected (if (zerop (length string))
                           (list (make-instance 'lem-core::void-object))
                           (loop :for (type . text) :in runs
                                 :collect (lem-core::make-object-with-type text attribute type))))
             (ends (lem-core::create-drawing-object
                    (lem-core::make-line-end-item :text string :attribute attribute :offset 7))))
        (unless (and (= (length objects) (length expected))
                     (every (lambda (actual expected)
                              (and (eq (class-of actual) (class-of expected))
                                   (or (typep actual 'lem-core::void-object)
                                       (lem-core::drawing-object-equal actual expected))))
                            objects expected)
                     (= (length ends) (length runs))
                     (every (lambda (object run)
                              (and (typep object 'lem-core::line-end-object)
                                   (equal (lem-core::text-object-string object) (cdr run))
                                   (eq (lem-core::text-object-type object) (car run))
                                   (eq (lem-core::text-object-attribute object) attribute)
                                   (= 7 (lem-core::line-end-object-offset object))))
                            ends runs))
          (setf correct nil))))
    (ok (and correct (= (length cases) 733))
        "733 text/line-ending cases preserve classes, strings, styles and order")
    (let* ((source (copy-seq "left漢字right"))
           (first (lem-core::create-text-drawing-objects source attribute))
           (second (lem-core::create-text-drawing-objects source attribute)))
      (fill source #\x)
      (ok (equal '("left" "漢字" "right")
                 (mapcar #'lem-core::text-object-string first)))
      (setf (char (lem-core::text-object-string (first first)) 0) #\L)
      (ok (equal '("left" "漢字" "right")
                 (mapcar #'lem-core::text-object-string second))
          "output strings are independent of source and other draws"))
    (let* ((image (make-attribute :plist '(:image :test-image :width 8 :height 16)))
           (objects (lem-core::create-text-drawing-objects "a漢😀" image)))
      (ok (= 1 (length objects)))
      (let ((object (first objects)))
        (ok (typep object 'lem-core::image-object))
        (ok (eq :test-image (lem-core::image-object-image object)))
        (ok (= 8 (lem-core::image-object-width object)))
        (ok (= 16 (lem-core::image-object-height object))))
      (ok (typep (first (lem-core::create-text-drawing-objects "" image))
                 'lem-core::void-object)
          "empty text keeps its precedence over image attributes"))))

(deftest modeline-drawing-remains-live
  (with-current-buffers ()
    (lem-fake-interface:with-fake-interface ()
      (let* ((window (current-window))
             (attribute (make-attribute :foreground "red"))
             (text (copy-seq "first"))
             (alignment :left)
             (calls 0)
             (lem-core::*modeline-status-list* nil))
        (setf (lem-core::window-modeline-format window)
              (list (lambda (window)
                      (declare (ignore window))
                      (incf calls)
                      (values text attribute alignment))
                    '(" R" nil :right)))
        (multiple-value-bind (left right)
            (lem-core::make-modeline-objects window (make-attribute))
          (ok (= 1 calls))
          (ok (equal '("first") (mapcar #'lem-core::text-object-string left)))
          (ok (equal '(" R") (mapcar #'lem-core::text-object-string right)))
          (fill text #\x)
          (setf alignment :right)
          (set-attribute-background attribute "blue")
          (multiple-value-bind (next-left next-right)
              (lem-core::make-modeline-objects window (make-attribute))
            (ok (= 2 calls) "modeline functions still run each time")
            (ok (null next-left))
            (ok (equal '("xxxxx" " R") (mapcar #'lem-core::text-object-string next-right)))
            (ok (equal (attribute-background attribute) (attribute-background
                               (lem-core::text-object-attribute (first next-right))))))
          (ok (equal "first" (lem-core::text-object-string (first left)))
              "previously returned drawing text remains a snapshot"))))))

(deftest image-drawing-cache-identity-and-adjacency
  ;; Exercise the real object comparison/reduction used by the drawing cache.
  ;; Image handles stand in for backend surfaces; no renderer is needed here.
  (flet ((image-object (image width height)
           (make-instance 'lem-core/display:image-object
                          :image image :width width :height height :attribute nil)))
    (let ((original (image-object :first 8 16)))
      (ok (lem-core::drawing-object-equal original (image-object :first 8 16)))
      (dolist (other (list (image-object :second 8 16)
                          (image-object :first 9 16)
                          (image-object :first 8 17)))
        (ng (lem-core::drawing-object-equal original other)))
      ;; Even two identical images occupy separate spans in a row.
      (dolist (other (list (image-object :first 8 16)
                          (image-object :second 8 16)))
        (ok (equal (list original other)
                   (lem-core::reduce-objects (list original other))))))))


(deftest test-mix-hashes
  ;; 1. The Commutativity Check (Does order matter?)
  (ok (not (= (lem-core::mix-hashes 1 2 3)
              (lem-core::mix-hashes 3 2 1))))
  
  ;; 2. The Cancellation Check (Do duplicate values erase each other?)
  (ok (not (= (lem-core::mix-hashes 42 42)
              (lem-core::mix-hashes 0))))
  
  ;; 3. Type Safety Check (Does it always evaluate to a raw machine integer?)
  (ok (typep (lem-core::mix-hashes "string" 100 'some-symbol '(:keyword 5))
             'integer)))

(deftest test-compute-line-fingerprint
  (let* ((line-base (lem-core::make-logical-line :string "foo"
                                                 :attributes nil
                                                 :end-of-line-cursor-attribute nil
                                                 :extend-to-end nil
                                                 :line-end-overlay nil))
         (line-a (lem-core::copy-logical-line line-base))
         (line-b (lem-core::copy-logical-line line-base))
         (line-c (lem-core::copy-logical-line line-base)))
    
    ;; Set up line-a and line-b to be deep, structural twins
    (setf (lem-core::logical-line-attributes line-a) 
          '((0 1 color) (0 2 color) (0 3 color) (0 4 color) (0 5 color) (0 6 no-highlight)))
    (setf (lem-core::logical-line-attributes line-b) 
          '((0 1 color) (0 2 color) (0 3 color) (0 4 color) (0 5 color) (0 6 no-highlight)))
    
    ;; Set up line-c to diverge past the 5th element (Old sxhash shallow-hash limit)
    (setf (lem-core::logical-line-attributes line-c) 
          '((0 1 color) (0 2 color) (0 3 color) (0 4 color) (0 5 color) (0 6 paredit-highlight)))
    
    ;; 1. Identity Check: Twin lines under twin scroll values must yield twin hashes
    (ok (= (lem-core::compute-line-fingerprint line-a 10 5 0)
           (lem-core::compute-line-fingerprint line-b 10 5 0)))
    
    ;; 2. Shallow Hash Fix Check: Verifies deep changes (like Paredit) are caught
    (ok (not (= (lem-core::compute-line-fingerprint line-a 10 5 0)
                (lem-core::compute-line-fingerprint line-c 10 5 0))))
    
    ;; 3. Parameter Commutativity Check: Swapping scroll-start and layout widths shifts the hash
    (ok (not (= (lem-core::compute-line-fingerprint line-a 10 5 0)
                (lem-core::compute-line-fingerprint line-a 5 10 0))))
    
    ;; 4. Parameter Cancellation Check: Matching coordinate variables don't zero out
    (ok (not (= (lem-core::compute-line-fingerprint line-a 15 15 0)
                (lem-core::compute-line-fingerprint line-a 30 30 0))))

    ;; Both margins affect the available layout width independently.
    (ok (not (= (lem-core::compute-line-fingerprint line-a 0 5 0)
                (lem-core::compute-line-fingerprint line-a 0 5 3))))))

(deftest gutter-fingerprint-uses-content
  (let ((line-a (lem-core::make-logical-line
                 :string "body"
                 :left-content (lem/buffer/line:make-content :string "12")))
        (line-b (lem-core::make-logical-line
                 :string "body"
                 :left-content (lem/buffer/line:make-content :string "12"))))
    (ok (= (lem-core::compute-line-fingerprint line-a 0 2 0)
           (lem-core::compute-line-fingerprint line-b 0 2 0))
        "fresh equal gutter records still allow cache hits")
    (setf (lem/buffer/line:content-string (lem-core::logical-line-left-content line-b)) "13")
    (ng (= (lem-core::compute-line-fingerprint line-a 0 2 0)
           (lem-core::compute-line-fingerprint line-b 0 2 0)))))

(deftest test-evict-line-fingerprints-from
  ;; When the tail of a window is blanked by clear-to-end-of-window (e.g. after
  ;; deleting a large region), the fingerprint entries for those rows must be
  ;; dropped.  Otherwise undoing the deletion restores content whose fingerprint
  ;; matches the stale entry, the render is skipped, and the row stays blank on
  ;; persistent-texture frontends (SDL2).  `evict-line-fingerprints-from` is an
  ;; unexported display-layer internal, accessed here for a white-box unit test.
  (let ((cache (make-hash-table :test 'eql)))
    (setf (gethash 0 cache) (cons 111 10))
    (setf (gethash 10 cache) (cons 222 10))
    (setf (gethash 20 cache) (cons 333 10))
    ;; `lem-core::` reaches an unexported internal on purpose: this helper
    ;; has no public equivalent and is exercised directly as a white-box test.
    (lem-core::evict-line-fingerprints-from cache 10)
    ;; Rows at or below the cleared y are gone; rows above are kept.
    (ok (nth-value 1 (gethash 0 cache)))
    (ng (nth-value 1 (gethash 10 cache)))
    (ng (nth-value 1 (gethash 20 cache)))
    (ok (= 1 (hash-table-count cache)))))

(deftest test-remove-drawing-cache-entries-from
  ;; The drawing-object cache (keyed by screen y) has the same stale-tail
  ;; hazard as the fingerprint cache: rows blanked by clear-to-end-of-window
  ;; must be dropped so a later frame whose restored objects match a stale
  ;; entry does not pass validate-cache-p and skip the render (SDL2 invisible
  ;; text after undoing a large deletion).  `remove-drawing-cache-entries-from`
  ;; is an unexported display-layer internal, accessed here for a white-box
  ;; unit test over the (y height objects) entry list.
  (let ((entries (list (list 0 10 nil) (list 10 10 nil) (list 20 10 nil))))
    ;; `lem-core::` reaches an unexported internal on purpose: this helper
    ;; has no public equivalent and is exercised directly as a white-box test.
    ;; Only the row above the cleared y survives.
    (ok (equal (lem-core::remove-drawing-cache-entries-from entries 10)
               (list (list 0 10 nil))))
    ;; A y past all entries removes nothing.
    (ok (= 3 (length (lem-core::remove-drawing-cache-entries-from entries 30))))
    ;; A y of 0 removes everything.
    (ok (null (lem-core::remove-drawing-cache-entries-from entries 0)))))

(deftest test-fingerprint-detects-attribute-mutation
  ;; An attribute mutated in place (e.g. recoloring the shared `cursor`
  ;; attribute via SET-ATTRIBUTE, as vi-mode/skk-mode do) keeps the same
  ;; object identity while its content changes.  Because SXHASH on a
  ;; standard-object is identity-based in SBCL, the fingerprint would not
  ;; change and the line would be skipped on redraw, leaving stale pixels on
  ;; persistent textures (SDL2 ghosting).  The fingerprint must change.

  ;; `make-logical-line` and `compute-line-fingerprint` are unexported
  ;; lem-core internals: this is a white-box unit test of the display
  ;; layer's fingerprint cache, so internal access is necessary to build a
  ;; logical-line and hash it directly.  `make-attribute`/`set-attribute`
  ;; are exported and used through the package's :use of :lem-core.

  ;; Mutation referenced through the attributes list.
  (let* ((attribute (make-attribute :foreground "#FF0000"))
         (line (lem-core::make-logical-line
                :string "foo"
                :attributes (list (list 0 3 attribute))
                :end-of-line-cursor-attribute nil
                :extend-to-end nil
                :line-end-overlay nil))
         (before (lem-core::compute-line-fingerprint line 0 0 0)))
    (set-attribute attribute :background "#00FF00")
    (ok (not (= before (lem-core::compute-line-fingerprint line 0 0 0)))))

  ;; Mutation referenced through the end-of-line cursor attribute.
  (let* ((cursor (make-attribute :background "#FFFFFF"))
         (line (lem-core::make-logical-line
                :string "foo"
                :attributes nil
                :end-of-line-cursor-attribute cursor
                :extend-to-end nil
                :line-end-overlay nil))
         (before (lem-core::compute-line-fingerprint line 0 0 0)))
    (set-attribute cursor :background "#000000")
    (ok (not (= before (lem-core::compute-line-fingerprint line 0 0 0))))))
