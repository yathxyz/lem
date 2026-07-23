;;;; Native document-mode providers for generic Imenu.
;;;;
;;;; These are fallbacks only.  `imenu-candidates' continues to give a ready
;;;; Eglot document-symbol provider complete precedence, just as Emacs does.

(in-package :lem-yath)

;;; --- shared nested outline construction ---------------------------------

(defun imenu-outline-self-candidate (candidate)
  (make-imenu-candidate
   :label "."
   :detail (imenu-candidate-detail candidate)
   :point (copy-point (imenu-candidate-point candidate))))

(defun imenu-outline-add-child (parent child)
  ;; markdown-mode exposes a literal `.' entry for selecting a heading that
  ;; also owns a submenu.  Synthetic gap nodes have no position or self item.
  (when (and (imenu-candidate-point parent)
             (null (imenu-candidate-children parent)))
    (setf (imenu-candidate-children parent)
          (list (imenu-outline-self-candidate parent))))
  (setf (imenu-candidate-children parent)
        (nconc (imenu-candidate-children parent) (list child))))

(defun imenu-nested-outline-candidates (leveled-candidates)
  "Nest (LEVEL . CANDIDATE) pairs using markdown-mode's gap semantics."
  (let ((root (make-imenu-candidate :label "root"))
        (stack '()))
    (setf stack (list (cons 0 root)))
    (dolist (entry leveled-candidates)
      (let ((level (car entry))
            (candidate (cdr entry)))
        (loop :while (>= (caar stack) level)
              :do (pop stack))
        (loop :while (< (caar stack) (1- level))
              :for gap-level := (1+ (caar stack))
              :for gap := (make-imenu-candidate :label "-")
              :do (imenu-outline-add-child (cdar stack) gap)
                  (push (cons gap-level gap) stack))
        (imenu-outline-add-child (cdar stack) candidate)
        (push (cons level candidate) stack)))
    (imenu-candidate-children root)))

;;; --- GNU Org -------------------------------------------------------------

(defun imenu-org-link-display-format (title)
  "Replace ordinary bracket links in TITLE with their Org display text."
  (with-output-to-string (stream)
    (let ((offset 0))
      (ppcre:do-scans
          (start end register-starts register-ends
           "\\[\\[([^]\\n]+)\\](?:\\[([^]\\n]*)\\])?\\]" title)
        (write-string title stream :start offset :end start)
        (let ((description-start (aref register-starts 1)))
          (if description-start
              (write-string title stream
                            :start description-start
                            :end (aref register-ends 1))
              (write-string title stream
                            :start (aref register-starts 0)
                            :end (aref register-ends 0))))
        (setf offset end))
      (write-string title stream :start offset))))

(defun imenu-org-tag-string-p (string)
  (and (> (length string) 2)
       (char= (char string 0) #\:)
       (char= (char string (1- (length string))) #\:)
       (loop :with start := 1
             :for end := (position #\: string :start start)
             :while end
             :always (and (> end start)
                          (loop :for index :from start :below end
                                :for character := (char string index)
                                :always (or (alphanumericp character)
                                            (member character
                                                    '(#\_ #\@ #\# #\%)))))
             :do (setf start (1+ end))
             :finally (return (= start (length string))))))

(defun imenu-org-trailing-tags-start (body)
  (let* ((trimmed (string-right-trim '(#\Space #\Tab) body))
         (separator
           (position-if (lambda (character)
                          (member character '(#\Space #\Tab)))
                        trimmed :from-end t))
         (candidate (subseq trimmed (if separator (1+ separator) 0))))
    (and (imenu-org-tag-string-p candidate)
         (or separator 0))))

(defun imenu-org-heading-label (line level)
  "Return Org's no-tags/no-TODO/no-priority/no-COMMENT Imenu label."
  (let* ((body (string-left-trim
                '(#\Space #\Tab) (subseq line (1+ level))))
         (tags-start (imenu-org-trailing-tags-start body)))
    (when tags-start
      (setf body (string-right-trim '(#\Space #\Tab)
                                    (subseq body 0 tags-start))))
    (let ((todo-seen-p nil)
          (priority-seen-p nil)
          (comment-seen-p nil))
      (loop
        (let* ((end (or (position-if
                         (lambda (character)
                           (member character '(#\Space #\Tab)))
                         body)
                        (length body)))
               (token (subseq body 0 end))
               (rest (string-left-trim '(#\Space #\Tab)
                                       (subseq body end))))
          (cond
            ((and (not todo-seen-p)
                  (member token *org-todo-keywords* :test #'string=))
             (setf todo-seen-p t body rest))
            ((and (not priority-seen-p)
                  (= 4 (length token))
                  (char= (char token 0) #\[)
                  (char= (char token 1) #\#)
                  (alphanumericp (char token 2))
                  (char= (char token 3) #\]))
             (setf priority-seen-p t body rest))
            ((and (not comment-seen-p) (string= token "COMMENT"))
             (setf comment-seen-p t body rest))
            (t (return)))))
      (let ((label (imenu-org-link-display-format
                    (string-trim '(#\Space #\Tab) body))))
        (and (plusp (length label)) label)))))

(defun imenu-org-candidate (point label)
  (make-imenu-candidate
   :label label
   :detail (format nil "[Org heading] line ~d"
                   (line-number-at-point point))
   :point (copy-point point)))

(defun imenu-org-candidates (buffer)
  ;; The configured `org-imenu-depth' is its untouched default, 2.  Org's
  ;; completion path makes a level-one item with children a submenu; unlike
  ;; markdown-mode, it does not add a visible `.' self entry.
  (let ((roots '())
        (current-root nil))
    (with-current-buffer buffer
      (with-point ((point (buffer-start-point buffer)))
        (loop
          (alexandria:when-let* ((level (org-heading-level-at point))
                                 (label (and (<= level 2)
                                             (imenu-org-heading-label
                                              (line-string point) level))))
            (let ((candidate (imenu-org-candidate point label)))
              (case level
                (1
                 (setf roots (nconc roots (list candidate))
                       current-root candidate))
                (2
                 (if current-root
                     (setf (imenu-candidate-children current-root)
                           (nconc (imenu-candidate-children current-root)
                                  (list candidate)))
                     (delete-point (imenu-candidate-point candidate)))))))
          (unless (line-offset point 1) (return)))))
    roots))

;;; --- markdown-mode -------------------------------------------------------

(defun imenu-markdown-fence-run (line)
  "Return fence character and run length for a Markdown fence line."
  (let* ((trimmed (string-left-trim '(#\Space #\Tab) line))
         (character (and (plusp (length trimmed)) (char trimmed 0))))
    (when (member character '(#\` #\~))
      (let ((length (or (position-if
                         (lambda (candidate)
                           (char/= candidate character))
                         trimmed)
                        (length trimmed))))
        (when (>= length 3)
          (values character length (subseq trimmed length)))))))

(defun imenu-markdown-line-excluded-p
    (line line-number fence-character fence-length yaml-p)
  "Return exclusion state and the updated fenced/YAML parser state."
  (cond
    (yaml-p
     (values t fence-character fence-length
             (not (and (> line-number 1) (string= line "---")))))
    ((and (= line-number 1) (string= line "---"))
     (values t fence-character fence-length t))
    (fence-character
     (multiple-value-bind (character length rest)
         (imenu-markdown-fence-run line)
       (if (and character
                (char= character fence-character)
                (>= length fence-length)
                (zerop (length (string-trim '(#\Space #\Tab) rest))))
           (values t nil 0 nil)
           (values t fence-character fence-length nil))))
    (t
     (multiple-value-bind (character length rest)
         (imenu-markdown-fence-run line)
       (declare (ignore rest))
       (if character
           (values t character length nil)
           (values nil nil 0 nil))))))

(defun imenu-markdown-setext-level (line)
  (when (plusp (length line))
    (let ((character (char line 0)))
      (when (and (member character '(#\= #\-))
                 (every (lambda (candidate)
                          (char= candidate character))
                        line))
        (if (char= character #\=) 1 2)))))

(defun imenu-markdown-setext-title-p (line)
  (and (plusp (length line))
       (not (member (char line 0)
                    '(#\Return #\Newline #\Tab #\Space #\-)))))

(defun imenu-markdown-atx-fields (line)
  (let ((hashes (position-if (lambda (character) (char/= character #\#))
                             line)))
    (when (and hashes
               (plusp hashes)
               (< hashes (length line))
               (member (char line hashes) '(#\Space #\Tab)))
      (let* ((body-start
               (or (position-if-not
                    (lambda (character)
                      (member character '(#\Space #\Tab)))
                    line :start hashes)
                   (length line)))
             (body (subseq line body-start)))
        (multiple-value-bind (match groups)
            (ppcre:scan-to-strings "^(.*?)(?:[ \\t]+#+)?$" body)
          (declare (ignore match))
          (values hashes (if groups (aref groups 0) body)))))))

(defun imenu-markdown-heading-candidate (point label kind)
  (make-imenu-candidate
   :label label
   :detail (format nil "[Markdown ~a] line ~d"
                   kind (line-number-at-point point))
   :point (copy-point point)))

(defun imenu-markdown-comment-state-after-line (line state)
  (loop :with offset := 0
        :while (< offset (length line))
        :for open := (search "<!--" line :start2 offset)
        :for close := (search "-->" line :start2 offset)
        :do (cond
              (state
               (if close
                   (setf state nil offset (+ close 3))
                   (return state)))
              (open
               (setf state t offset (+ open 4)))
              (t (return state)))
        :finally (return state)))

(defun imenu-markdown-footnote-label (line)
  (let ((index 0)
        (length (length line)))
    (loop :while (and (< index length)
                      (< index 4)
                      (char= (char line index) #\Space))
          :do (incf index))
    (unless (and (<= index 3)
                 (< (+ index 3) length)
                 (char= (char line index) #\[)
                 (char= (char line (1+ index)) #\^))
      (return-from imenu-markdown-footnote-label nil))
    (let ((label-start (1+ index))
          (cursor (+ index 2)))
      (loop :while (and (< cursor length)
                        (let ((character (char line cursor)))
                          (or (alphanumericp character)
                              (char= character #\-))))
            :do (incf cursor))
      (unless (and (< (1+ cursor) length)
                   (char= (char line cursor) #\])
                   (char= (char line (1+ cursor)) #\:)
                   (or (= (+ cursor 2) length)
                       (member (char line (+ cursor 2))
                               '(#\Space #\Tab))))
        (return-from imenu-markdown-footnote-label nil))
      (subseq line label-start cursor))))

(defun imenu-markdown-scan (buffer)
  (let ((headings '())
        (footnotes '())
        (footnote-seen (make-hash-table :test #'equal))
        (minimum-level 9999)
        (fence-character nil)
        (fence-length 0)
        (yaml-p nil)
        (comment-p nil))
    (with-current-buffer buffer
      (with-point ((point (buffer-start-point buffer)))
        (loop :for line-number :from 1
              :for line := (line-string point)
              :for next-line := (with-point ((next point))
                                  (and (line-offset next 1)
                                       (line-string next)))
              :do
                 (multiple-value-bind
                     (excluded-p next-fence-character next-fence-length
                      next-yaml-p)
                     (imenu-markdown-line-excluded-p
                      line line-number fence-character fence-length yaml-p)
                   (let ((line-commented-p comment-p))
                     (setf comment-p
                           (imenu-markdown-comment-state-after-line
                            line comment-p))
                     (unless excluded-p
                       (let ((setext-level
                               (and next-line
                                    (imenu-markdown-setext-title-p line)
                                    (imenu-markdown-setext-level next-line))))
                         (if setext-level
                             (progn
                               (setf minimum-level
                                     (min minimum-level setext-level))
                               (push
                                (cons
                                 (- setext-level (1- minimum-level))
                                 (imenu-markdown-heading-candidate
                                  point line
                                  (if (= setext-level 1) "H1" "H2")))
                                headings))
                             (multiple-value-bind (level label)
                                 (imenu-markdown-atx-fields line)
                               (when level
                                 (setf minimum-level
                                       (min minimum-level level))
                                 (push
                                  (cons
                                   (- level (1- minimum-level))
                                   (imenu-markdown-heading-candidate
                                    point label (format nil "H~d" level)))
                                  headings)))))
                       (alexandria:when-let
                           ((label (and (not line-commented-p)
                                        (imenu-markdown-footnote-label line))))
                         (unless (gethash label footnote-seen)
                           (setf (gethash label footnote-seen) t)
                           (push
                            (make-imenu-candidate
                             :label label
                             :detail (format nil "[Markdown footnote] line ~d"
                                             line-number)
                             :point (copy-point point))
                            footnotes))))
                     (setf fence-character next-fence-character
                           fence-length next-fence-length
                           yaml-p next-yaml-p)))
              :while (line-offset point 1))))
    (values (nreverse headings) (nreverse footnotes))))

(defun imenu-markdown-candidates (buffer)
  (multiple-value-bind (headings footnotes)
      (imenu-markdown-scan buffer)
    (nconc
     (imenu-nested-outline-candidates headings)
     (when footnotes
       (list (make-imenu-candidate
              :label "Footnotes"
              :children footnotes))))))

;;; --- shared tree-sitter index support -----------------------------------

(defparameter *imenu-tree-sitter-depth* 1000
  "Maximum syntax-tree depth searched by native tree-sitter Imenu providers.")

(defvar *imenu-tree-sitter-created-points* nil)

(defmacro with-imenu-tree-sitter-candidate-points (&body body)
  "Release partially constructed candidate points if BODY exits abnormally."
  (let ((completed-p (gensym "COMPLETED-P")))
    `(let ((*imenu-tree-sitter-created-points* nil)
           (,completed-p nil))
       (unwind-protect
            (prog1 (progn ,@body)
              (setf ,completed-p t))
         ;; Successful points are owned by the returned candidate tree.  On
         ;; partial traversal there is no tree for `imenu' to release.
         (unless ,completed-p
           (dolist (point *imenu-tree-sitter-created-points*)
             (ignore-errors (delete-point point))))))))

(defun imenu-tree-sitter-current-tree (buffer)
  "Return BUFFER's tree-sitter tree, reparsing it when its tick is stale."
  (alexandria:when-let
      ((parser (buffer-value buffer 'lem-yath-tree-sitter-parser)))
    (let ((tick (buffer-modified-tick buffer)))
      (if (and (lem-tree-sitter:treesitter-parser-tree parser)
               (eql tick
                    (lem-tree-sitter::treesitter-parser-cached-tick parser)))
          (lem-tree-sitter:treesitter-parser-tree parser)
          (reparse-lem-yath-tree-sitter-buffer
           parser (buffer-text buffer) tick)))))

(defun imenu-python-definition-type (node)
  (let ((type (tree-sitter:node-type node)))
    (cond
      ((string= type "function_definition") "def")
      ((string= type "class_definition") "class")
      (t nil))))

(defun imenu-tree-sitter-definition-name (buffer node)
  "Return NODE's first named identifier, releasing every child handle."
  (loop :for index :below (tree-sitter:node-named-child-count node)
        :for child := (tree-sitter:node-named-child node index)
        :when child
          :do (unwind-protect
                   (when (string= (tree-sitter:node-type child) "identifier")
                     (return (tree-sitter-node-text buffer child)))
                (delete-tree-sitter-node child))))

(defun imenu-tree-sitter-direct-child-text (buffer node types)
  "Return the text of NODE's first direct named child in TYPES."
  (loop :for index :below (tree-sitter:node-named-child-count node)
        :for child := (tree-sitter:node-named-child node index)
        :when child
          :do (unwind-protect
                   (when (member (tree-sitter:node-type child) types
                                 :test #'string=)
                     (return (tree-sitter-node-text buffer child)))
                (delete-tree-sitter-node child))))

(defun imenu-tree-sitter-first-subtree-text
    (buffer node node-type &optional (max-depth *imenu-tree-sitter-depth*))
  "Return the first NODE-TYPE text below NODE within MAX-DEPTH."
  (labels ((walk (current depth)
             (if (string= (tree-sitter:node-type current) node-type)
                 (tree-sitter-node-text buffer current)
                 (when (< depth max-depth)
                   (loop :for index
                           :below (tree-sitter:node-named-child-count current)
                         :for child :=
                           (tree-sitter:node-named-child current index)
                         :when child
                           :do (let ((result
                                      (unwind-protect
                                           (walk child (1+ depth))
                                        (delete-tree-sitter-node child))))
                                 (when result (return result))))))))
    (walk node 0)))

(defun imenu-tree-sitter-subtree-type-p (node node-type max-depth)
  "Whether NODE-TYPE occurs below NODE within MAX-DEPTH."
  (labels ((walk (current depth)
             (or (string= (tree-sitter:node-type current) node-type)
                 (and (< depth max-depth)
                      (loop :for index
                              :below (tree-sitter:node-named-child-count current)
                            :for child :=
                              (tree-sitter:node-named-child current index)
                            :when child
                              :do (let ((result
                                         (unwind-protect
                                              (walk child (1+ depth))
                                           (delete-tree-sitter-node child))))
                                    (when result (return result))))))))
    (walk node 0)))

(defun imenu-tree-sitter-node-point (buffer node)
  (let ((point (expand-region-byte-to-point
                buffer (tree-sitter:node-start-byte node))))
    (push point *imenu-tree-sitter-created-points*)
    point))

;;; --- python-ts-mode ------------------------------------------------------

(defun imenu-python-leaf-candidate (buffer node type name)
  (let ((point (imenu-tree-sitter-node-point buffer node)))
    (make-imenu-candidate
     :label (format nil "~a (~a)" name type)
     :detail (format nil "[Python ~a] line ~d"
                     type (line-number-at-point point))
     :point point)))

(defun imenu-python-parent-candidate
    (buffer node type name children)
  (let* ((point (imenu-tree-sitter-node-point buffer node))
         (line (line-number-at-point point))
         (jump
           (make-imenu-candidate
            :label (if (string= type "class")
                       "*class definition*"
                       "*function definition*")
            :detail (format nil "[Python ~a] line ~d" type line)
            :point point)))
    (make-imenu-candidate
     :label (format nil "~a (~a)..." name type)
     :detail (format nil "[Python ~a] line ~d" type line)
     :children (cons jump children))))

(defun imenu-python-walk-node (buffer node depth)
  "Return NODE's sparse Python definition forest at syntax DEPTH.

Every tree-sitter node returned by the C binding owns a foreign node buffer;
this function consumes NODE and every named-child handle it obtains."
  (unwind-protect
       (let* ((type (imenu-python-definition-type node))
              (name (and type
                         (or (imenu-tree-sitter-definition-name buffer node)
                             "Anonymous")))
              (definition-p (and type name))
              (children nil))
         ;; This mirrors the explicit DEPTH argument to the pinned
         ;; `treesit-induce-sparse-tree'.  It limits ancestry, not the number
         ;; of definitions, so wide modules retain every sibling.
         (when (< depth *imenu-tree-sitter-depth*)
           (dotimes (index (tree-sitter:node-named-child-count node))
             (let ((child (tree-sitter:node-named-child node index)))
               (when child
                 (setf children
                       (nconc children
                              (imenu-python-walk-node
                               buffer child (1+ depth))))))))
         (if definition-p
             (list
              (if children
                  (imenu-python-parent-candidate
                   buffer node type name children)
                  (imenu-python-leaf-candidate
                   buffer node type name)))
             children))
    (delete-tree-sitter-node node)))

(defun imenu-python-candidates (buffer)
  "Match pinned python-ts-mode's nested tree-sitter Imenu index."
  (handler-case
      (with-imenu-tree-sitter-candidate-points
        (alexandria:when-let ((tree (imenu-tree-sitter-current-tree buffer)))
          (imenu-python-walk-node
           buffer (tree-sitter:tree-root-node tree) 0)))
    (error (condition)
      (log:warn "Python Imenu indexing failed for ~a: ~a"
                (buffer-name buffer) condition)
      nil)))

;;; --- java-ts-mode --------------------------------------------------------

(defparameter *imenu-java-settings*
  '(("Class" . "class_declaration")
    ("Interface" . "interface_declaration")
    ;; This apparently surprising mapping is exact in pinned Emacs 31.
    ("Enum" . "record_declaration")
    ("Method" . "method_declaration")))

(defun imenu-java-entry-candidate (buffer node category name children)
  (let* ((point (imenu-tree-sitter-node-point buffer node))
         (detail (format nil "[Java ~a] line ~d"
                         category (line-number-at-point point))))
    (if children
        (make-imenu-candidate
         :label name
         :detail detail
         :children
         (cons (make-imenu-candidate
                :label " "
                :detail detail
                :point point)
               children))
        (make-imenu-candidate
         :label name
         :detail detail
         :point point))))

(defun imenu-java-walk-category (buffer node category node-type depth)
  "Return NODE's sparse Java forest for CATEGORY and consume NODE."
  (unwind-protect
       (let ((matching-p (string= (tree-sitter:node-type node) node-type))
             (children nil))
         (when (< depth *imenu-tree-sitter-depth*)
           (dotimes (index (tree-sitter:node-named-child-count node))
             (let ((child (tree-sitter:node-named-child node index)))
               (when child
                 (setf children
                       (nconc children
                              (imenu-java-walk-category
                               buffer child category node-type
                               (1+ depth))))))))
         (if matching-p
             (list
              (imenu-java-entry-candidate
               buffer node category
               (or (imenu-tree-sitter-definition-name buffer node)
                   "Anonymous")
               children))
             children))
    (delete-tree-sitter-node node)))

(defun imenu-java-candidates (buffer)
  "Match pinned java-ts-mode's categorized tree-sitter Imenu index."
  (handler-case
      (with-imenu-tree-sitter-candidate-points
        (alexandria:when-let ((tree (imenu-tree-sitter-current-tree buffer)))
          (loop :for (category . node-type) :in *imenu-java-settings*
                :for children :=
                  (imenu-java-walk-category
                   buffer (tree-sitter:tree-root-node tree)
                   category node-type 0)
                :when children
                  :collect (make-imenu-candidate
                            :label category
                            :children children))))
    (error (condition)
      (log:warn "Java Imenu indexing failed for ~a: ~a"
                (buffer-name buffer) condition)
      nil)))

;;; --- c-ts-mode ----------------------------------------------------------

(defparameter *imenu-c-settings*
  '(("Enum" . "enum_specifier")
    ("Struct" . "struct_specifier")
    ("Union" . "union_specifier")
    ("Variable" . "declaration")
    ("Function" . "function_definition")))

(defparameter *imenu-c-nontop-level-ancestors*
  '("function_definition" "type_definition" "struct_specifier"
    "enum_specifier" "union_specifier" "declaration"))

(defparameter *imenu-c-declarator-types*
  '("identifier" "field_identifier" "attributed_declarator"
    "parenthesized_declarator" "pointer_declarator"
    "reference_declarator" "function_declarator" "array_declarator"
    "init_declarator" "qualified_identifier"
    "structured_binding_declarator" "template_function"
    "template_method" "operator_name" "destructor_name"))

(defun imenu-c-first-named-child-of-types (node types)
  "Return NODE's first direct named child whose type is in TYPES."
  (loop :for index :below (tree-sitter:node-named-child-count node)
        :for child := (tree-sitter:node-named-child node index)
        :when child
          :do (if (member (tree-sitter:node-type child) types :test #'string=)
                  (return child)
                  (delete-tree-sitter-node child))))

(defun imenu-c-declarator-child (node)
  ;; In tree-sitter-c, a declaration's type is a primitive_type or
  ;; type_identifier; every concrete declarator is one of these direct named
  ;; children.  This is the grammar-level equivalent of its `declarator'
  ;; field, without relying on tree-sitter-cl's broken cursor ABI wrapper.
  (imenu-c-first-named-child-of-types node *imenu-c-declarator-types*))

(defun imenu-c-top-level-p (node)
  "Match pinned c-ts-mode's ancestor-based top-level predicate for NODE."
  (let ((parent (tree-sitter:node-parent node)))
    (loop :while parent
          :do (let ((next-parent nil))
                (unwind-protect
                     (progn
                       (when (member (tree-sitter:node-type parent)
                                     *imenu-c-nontop-level-ancestors*
                                     :test #'string=)
                         (return-from imenu-c-top-level-p nil))
                       (setf next-parent (tree-sitter:node-parent parent)))
                  (delete-tree-sitter-node parent))
                (setf parent next-parent)))
    t))

(defun imenu-c-valid-p (node category)
  "Return whether NODE is a pinned c-ts-mode Imenu entry for CATEGORY."
  (cond
    ((member category '("Enum" "Struct" "Union") :test #'string=)
     (imenu-c-top-level-p node))
    ((string= category "Variable")
     (let ((declarator (imenu-c-declarator-child node)))
       (unwind-protect
            (and declarator
                 (not (string= (tree-sitter:node-type declarator)
                               "function_declarator"))
                 (imenu-c-top-level-p node))
         (when declarator
           (delete-tree-sitter-node declarator)))))
    (t t)))

(defun imenu-c-declarator-name (buffer node &optional qualified-p)
  "Return pinned c-ts-mode's identifier for declarator NODE."
  (let ((type (tree-sitter:node-type node)))
    (cond
      ((member type '("attributed_declarator" "parenthesized_declarator")
               :test #'string=)
       (let ((child (tree-sitter:node-named-child node 0)))
         (when child
           (unwind-protect
                (imenu-c-declarator-name buffer child qualified-p)
             (delete-tree-sitter-node child)))))
      ((member type '("pointer_declarator" "reference_declarator")
               :test #'string=)
       (let ((child (tree-sitter:node-child
                     node (1- (tree-sitter:node-child-count node)))))
         (when child
           (unwind-protect
                (imenu-c-declarator-name buffer child qualified-p)
             (delete-tree-sitter-node child)))))
      ((member type '("function_declarator" "array_declarator"
                      "init_declarator")
               :test #'string=)
       (let ((child (imenu-c-declarator-child node)))
         (when child
           (unwind-protect
                (imenu-c-declarator-name buffer child qualified-p)
             (delete-tree-sitter-node child)))))
      ((and qualified-p (string= type "qualified_identifier"))
       (tree-sitter-node-text buffer node))
      ((member type '("identifier" "field_identifier") :test #'string=)
       (tree-sitter-node-text buffer node)))))

(defun imenu-c-node-name (buffer node)
  (let* ((type (tree-sitter:node-type node))
         (declarator-p
           (member type '("function_definition" "declaration")
                   :test #'string=))
         (child
           (if declarator-p
               (imenu-c-declarator-child node)
               (imenu-c-first-named-child-of-types
                node '("type_identifier")))))
    (when child
      (unwind-protect
           (if declarator-p
               (imenu-c-declarator-name buffer child t)
               (tree-sitter-node-text buffer child))
        (delete-tree-sitter-node child)))))

(defun imenu-c-entry-candidate
    (buffer node language category name children)
  (let* ((point (imenu-tree-sitter-node-point buffer node))
         (detail (format nil "[~a ~a] line ~d"
                         language category (line-number-at-point point))))
    (if children
        (make-imenu-candidate
         :label name
         :detail detail
         :children
         (cons (make-imenu-candidate
                :label " "
                :detail detail
                :point point)
               children))
        (make-imenu-candidate
         :label name
         :detail detail
         :point point))))

(defun imenu-c-walk-category
    (buffer node language category node-types valid-function depth)
  "Return NODE's sparse C-family forest for CATEGORY and consume NODE."
  (unwind-protect
       (let ((matching-p
               (if (listp node-types)
                   (member (tree-sitter:node-type node) node-types
                           :test #'string=)
                   (string= (tree-sitter:node-type node) node-types)))
             (children nil))
         (when (< depth *imenu-tree-sitter-depth*)
           (dotimes (index (tree-sitter:node-named-child-count node))
             (let ((child (tree-sitter:node-named-child node index)))
               (when child
                 (setf children
                       (nconc children
                              (imenu-c-walk-category
                               buffer child language category node-types
                               valid-function (1+ depth))))))))
         (if (and matching-p (funcall valid-function node category))
             (list
              (imenu-c-entry-candidate
               buffer node language category
               (or (imenu-c-node-name buffer node) "Anonymous")
               children))
             children))
    (delete-tree-sitter-node node)))

(defun imenu-c-candidates (buffer)
  "Match pinned c-ts-mode's categorized tree-sitter Imenu index."
  (handler-case
      (with-imenu-tree-sitter-candidate-points
        (alexandria:when-let ((tree (imenu-tree-sitter-current-tree buffer)))
          (loop :for (category . node-type) :in *imenu-c-settings*
                :for children :=
                  (imenu-c-walk-category
                   buffer (tree-sitter:tree-root-node tree)
                   "C" category node-type #'imenu-c-valid-p 0)
                :when children
                  :collect (make-imenu-candidate
                            :label category
                            :children children))))
    (error (condition)
      (log:warn "C Imenu indexing failed for ~a: ~a"
                (buffer-name buffer) condition)
      nil)))

;;; --- c++-ts-mode --------------------------------------------------------

(defparameter *imenu-c++-settings*
  '(("Enum" . "enum_specifier")
    ("Struct" . "struct_specifier")
    ("Union" . "union_specifier")
    ("Variable" . "declaration")
    ("Function" . "function_definition")
    ("Class" . ("class_specifier" "function_definition"))))

(defun imenu-c++-function-in-class-p (node)
  (let ((parent (tree-sitter:node-parent node)))
    (loop :while parent
          :do (let ((next-parent nil))
                (unwind-protect
                     (progn
                       (when (string= (tree-sitter:node-type parent)
                                      "class_specifier")
                         (return-from imenu-c++-function-in-class-p t))
                       (setf next-parent (tree-sitter:node-parent parent)))
                  (delete-tree-sitter-node parent))
                (setf parent next-parent)))
    nil))

(defun imenu-c++-valid-p (node category)
  (if (string= category "Class")
      (or (string= (tree-sitter:node-type node) "class_specifier")
          (and (string= (tree-sitter:node-type node) "function_definition")
               (imenu-c++-function-in-class-p node)))
      (imenu-c-valid-p node category)))

(defun imenu-c++-candidates (buffer)
  "Match pinned c++-ts-mode's categorized tree-sitter Imenu index."
  (handler-case
      (with-imenu-tree-sitter-candidate-points
        (alexandria:when-let ((tree (imenu-tree-sitter-current-tree buffer)))
          (loop :for (category . node-types) :in *imenu-c++-settings*
                :for children :=
                  (imenu-c-walk-category
                   buffer (tree-sitter:tree-root-node tree)
                   "C++" category node-types #'imenu-c++-valid-p 0)
                :when children
                  :collect (make-imenu-candidate
                            :label category
                            :children children))))
    (error (condition)
      (log:warn "C++ Imenu indexing failed for ~a: ~a"
                (buffer-name buffer) condition)
      nil)))

;;; --- rust-ts-mode -------------------------------------------------------

(defparameter *imenu-rust-settings*
  '(("Module" . "mod_item")
    ("Enum" . "enum_item")
    ("Impl" . "impl_item")
    ("Type" . "type_item")
    ("Struct" . "struct_item")
    ("Fn" . "function_item")))

(defun imenu-rust-impl-name (buffer node)
  "Return pinned rust-ts-mode's trait/type label for an impl NODE."
  (let ((types nil))
    (dotimes (index (tree-sitter:node-named-child-count node))
      (let ((child (tree-sitter:node-named-child node index)))
        (when child
          (unwind-protect
               (unless (member (tree-sitter:node-type child)
                               '("attribute_item" "inner_attribute_item"
                                 "type_parameters" "where_clause"
                                 "declaration_list")
                               :test #'string=)
                 (setf types
                       (nconc types
                              (list (tree-sitter-node-text buffer child)))))
            (delete-tree-sitter-node child)))))
    (case (length types)
      (0 nil)
      (1 (first types))
      (otherwise (format nil "~a for ~a" (first types) (second types))))))

(defun imenu-rust-node-name (buffer node)
  (let ((type (tree-sitter:node-type node)))
    (cond
      ((string= type "impl_item")
       (imenu-rust-impl-name buffer node))
      ((member type '("enum_item" "struct_item" "type_item")
               :test #'string=)
       (imenu-tree-sitter-direct-child-text
        buffer node '("type_identifier")))
      ((member type '("mod_item" "function_item") :test #'string=)
       (imenu-tree-sitter-direct-child-text buffer node '("identifier"))))))

(defun imenu-rust-entry-candidate (buffer node category name children)
  (let* ((point (imenu-tree-sitter-node-point buffer node))
         (detail (format nil "[Rust ~a] line ~d"
                         category (line-number-at-point point))))
    (if children
        (make-imenu-candidate
         :label name
         :detail detail
         :children
         (cons (make-imenu-candidate
                :label " "
                :detail detail
                :point point)
               children))
        (make-imenu-candidate :label name :detail detail :point point))))

(defun imenu-rust-walk-category (buffer node category node-type depth)
  "Return NODE's sparse Rust forest for CATEGORY and consume NODE."
  (unwind-protect
       (let ((matching-p (string= (tree-sitter:node-type node) node-type))
             (children nil))
         (when (< depth *imenu-tree-sitter-depth*)
           (dotimes (index (tree-sitter:node-named-child-count node))
             (let ((child (tree-sitter:node-named-child node index)))
               (when child
                 (setf children
                       (nconc children
                              (imenu-rust-walk-category
                               buffer child category node-type
                               (1+ depth))))))))
         (if matching-p
             (list
              (imenu-rust-entry-candidate
               buffer node category
               (or (imenu-rust-node-name buffer node) "Anonymous")
               children))
             children))
    (delete-tree-sitter-node node)))

(defun imenu-rust-candidates (buffer)
  "Match pinned rust-ts-mode's categorized tree-sitter Imenu index."
  (handler-case
      (with-imenu-tree-sitter-candidate-points
        (alexandria:when-let ((tree (imenu-tree-sitter-current-tree buffer)))
          (loop :for (category . node-type) :in *imenu-rust-settings*
                :for children :=
                  (imenu-rust-walk-category
                   buffer (tree-sitter:tree-root-node tree)
                   category node-type 0)
                :when children
                  :collect (make-imenu-candidate
                            :label category
                            :children children))))
    (error (condition)
      (log:warn "Rust Imenu indexing failed for ~a: ~a"
                (buffer-name buffer) condition)
      nil)))

;;; --- go-ts-mode ---------------------------------------------------------

(defparameter *imenu-go-settings*
  '(("Function" . "function_declaration")
    ("Method" . "method_declaration")
    ("Struct" . "type_declaration")
    ("Interface" . "type_declaration")
    ("Type" . "type_declaration")
    ("Alias" . "type_declaration")))

(defun imenu-go-type-declaration-name (buffer node)
  ;; Pinned go-ts-mode deliberately asks only the first named child for its
  ;; name.  A grouped type declaration therefore uses its first spec's name in
  ;; every category whose predicate matches anywhere in that declaration.
  (let ((spec (tree-sitter:node-named-child node 0)))
    (when spec
      (unwind-protect
           (imenu-tree-sitter-direct-child-text
            buffer spec '("type_identifier"))
        (delete-tree-sitter-node spec)))))

(defun imenu-go-method-receiver-name (buffer node)
  (loop :for index :below (tree-sitter:node-named-child-count node)
        :for child := (tree-sitter:node-named-child node index)
        :when child
          :do (unwind-protect
                   (when (string= (tree-sitter:node-type child)
                                  "parameter_list")
                     (return
                       (imenu-tree-sitter-first-subtree-text
                        buffer child "type_identifier")))
                (delete-tree-sitter-node child))))

(defun imenu-go-node-name (buffer node)
  (let ((type (tree-sitter:node-type node)))
    (cond
      ((string= type "function_declaration")
       (imenu-tree-sitter-direct-child-text buffer node '("identifier")))
      ((string= type "method_declaration")
       (let ((receiver (imenu-go-method-receiver-name buffer node))
             (method
               (imenu-tree-sitter-direct-child-text
                buffer node '("field_identifier"))))
         (and receiver method (format nil "(~a).~a" receiver method))))
      ((string= type "type_declaration")
       (imenu-go-type-declaration-name buffer node)))))

(defun imenu-go-valid-p (node category)
  (flet ((contains-p (type depth)
           (imenu-tree-sitter-subtree-type-p node type depth)))
    (cond
      ((string= category "Struct")
       (contains-p "struct_type" 2))
      ((string= category "Interface")
       (contains-p "interface_type" 2))
      ((string= category "Alias")
       (contains-p "type_alias" 1))
      ((string= category "Type")
       (not (or (contains-p "interface_type" 2)
                (contains-p "struct_type" 2)
                (contains-p "type_alias" 1))))
      (t t))))

(defun imenu-go-entry-candidate (buffer node category name children)
  (let* ((point (imenu-tree-sitter-node-point buffer node))
         (detail (format nil "[Go ~a] line ~d"
                         category (line-number-at-point point))))
    (if children
        (make-imenu-candidate
         :label name
         :detail detail
         :children
         (cons (make-imenu-candidate
                :label " "
                :detail detail
                :point point)
               children))
        (make-imenu-candidate :label name :detail detail :point point))))

(defun imenu-go-walk-category (buffer node category node-type depth)
  "Return NODE's sparse Go forest for CATEGORY and consume NODE."
  (unwind-protect
       (let ((matching-p (string= (tree-sitter:node-type node) node-type))
             (children nil))
         (when (< depth *imenu-tree-sitter-depth*)
           (dotimes (index (tree-sitter:node-named-child-count node))
             (let ((child (tree-sitter:node-named-child node index)))
               (when child
                 (setf children
                       (nconc children
                              (imenu-go-walk-category
                               buffer child category node-type
                               (1+ depth))))))))
         (if (and matching-p (imenu-go-valid-p node category))
             (list
              (imenu-go-entry-candidate
               buffer node category
               (or (imenu-go-node-name buffer node) "Anonymous")
               children))
             children))
    (delete-tree-sitter-node node)))

(defun imenu-go-candidates (buffer)
  "Match pinned go-ts-mode's categorized tree-sitter Imenu index."
  (handler-case
      (with-imenu-tree-sitter-candidate-points
        (alexandria:when-let ((tree (imenu-tree-sitter-current-tree buffer)))
          (loop :for (category . node-type) :in *imenu-go-settings*
                :for children :=
                  (imenu-go-walk-category
                   buffer (tree-sitter:tree-root-node tree)
                   category node-type 0)
                :when children
                  :collect (make-imenu-candidate
                            :label category
                            :children children))))
    (error (condition)
      (log:warn "Go Imenu indexing failed for ~a: ~a"
                (buffer-name buffer) condition)
      nil)))

;;; --- gdscript-ts-mode ---------------------------------------------------

(defun imenu-gdscript-definition-type (node)
  (let ((type (tree-sitter:node-type node)))
    (cond
      ((string= type "function_definition") "def")
      ((string= type "export_variable_statement") "e-var")
      ((string= type "onready_variable_statement") "o-var")
      ((string= type "variable_statement") "var")
      ((string= type "class_definition") "class")
      (t nil))))

(defun imenu-gdscript-leaf-candidate (buffer node type name)
  (let ((point (imenu-tree-sitter-node-point buffer node)))
    (make-imenu-candidate
     :label (format nil "~a (~a)" name type)
     :detail (format nil "[GDScript ~a] line ~d"
                     type (line-number-at-point point))
     :point point)))

(defun imenu-gdscript-parent-candidate
    (buffer node type name children)
  (let* ((point (imenu-tree-sitter-node-point buffer node))
         (detail (format nil "[GDScript ~a] line ~d"
                         type (line-number-at-point point))))
    (make-imenu-candidate
     :label (format nil "~a (~a)..." name type)
     :detail detail
     :children
     (cons (make-imenu-candidate
            :label (if (string= type "class")
                       "*class definition*"
                       "*function definition*")
            :detail detail
            :point point)
           children))))

(defun imenu-gdscript-walk-node (buffer node depth)
  "Return NODE's sparse GDScript definition forest and consume NODE."
  (unwind-protect
       (let* ((type (imenu-gdscript-definition-type node))
              (name (and type
                         (or (imenu-tree-sitter-first-subtree-text
                              buffer node "name")
                             "Anonymous")))
              (children nil))
         (when (< depth *imenu-tree-sitter-depth*)
           (dotimes (index (tree-sitter:node-named-child-count node))
             (let ((child (tree-sitter:node-named-child node index)))
               (when child
                 (setf children
                       (nconc children
                              (imenu-gdscript-walk-node
                               buffer child (1+ depth))))))))
         (if type
             (list
              (if children
                  (imenu-gdscript-parent-candidate
                   buffer node type name children)
                  (imenu-gdscript-leaf-candidate
                   buffer node type name)))
             children))
    (delete-tree-sitter-node node)))

(defun imenu-gdscript-candidates (buffer)
  "Match pinned gdscript-ts-mode's nested tree-sitter Imenu index."
  (handler-case
      (with-imenu-tree-sitter-candidate-points
        (alexandria:when-let ((tree (imenu-tree-sitter-current-tree buffer)))
          (imenu-gdscript-walk-node
           buffer (tree-sitter:tree-root-node tree) 0)))
    (error (condition)
      (log:warn "GDScript Imenu indexing failed for ~a: ~a"
                (buffer-name buffer) condition)
      nil)))

;;; --- typst-ts-mode ------------------------------------------------------

(defun imenu-typst-same-node-range-p (left right)
  (and (string= (tree-sitter:node-type left)
                (tree-sitter:node-type right))
       (= (tree-sitter:node-start-byte left)
          (tree-sitter:node-start-byte right))
       (= (tree-sitter:node-end-byte left)
          (tree-sitter:node-end-byte right))))

(defun imenu-typst-function-identifier-p (node)
  "Match typst-ts-mode's identifier-in-function-pattern predicate."
  (and
   (string= (tree-sitter:node-type node) "ident")
   (let ((parent (tree-sitter:node-parent node)))
     (when parent
       (unwind-protect
            (and
             (string= (tree-sitter:node-type parent) "call")
             (let ((grandparent (tree-sitter:node-parent parent)))
               (when grandparent
                 (unwind-protect
                      (and
                       (string= (tree-sitter:node-type grandparent) "let")
                       (let ((pattern
                               (tree-sitter:node-named-child grandparent 0)))
                         (when pattern
                           (unwind-protect
                                (imenu-typst-same-node-range-p
                                 parent pattern)
                             (delete-tree-sitter-node pattern)))))
                   (delete-tree-sitter-node grandparent)))))
         (delete-tree-sitter-node parent))))))

(defun imenu-typst-entry-candidate
    (buffer node category children)
  (let* ((name (tree-sitter-node-text buffer node))
         (point (imenu-tree-sitter-node-point buffer node))
         (detail (format nil "[Typst ~a] line ~d"
                         category (line-number-at-point point))))
    (if children
        (make-imenu-candidate
         :label name
         :detail detail
         :children
         (cons (make-imenu-candidate
                :label " "
                :detail detail
                :point point)
               children))
        (make-imenu-candidate :label name :detail detail :point point))))

(defun imenu-typst-walk-category
    (buffer node category predicate depth)
  "Return NODE's sparse Typst forest for CATEGORY and consume NODE."
  (unwind-protect
       (let ((matching-p (funcall predicate node))
             (children nil))
         (when (< depth *imenu-tree-sitter-depth*)
           (dotimes (index (tree-sitter:node-named-child-count node))
             (let ((child (tree-sitter:node-named-child node index)))
               (when child
                 (setf children
                       (nconc children
                              (imenu-typst-walk-category
                               buffer child category predicate
                               (1+ depth))))))))
         (if matching-p
             (list (imenu-typst-entry-candidate
                    buffer node category children))
             children))
    (delete-tree-sitter-node node)))

(defun imenu-typst-candidates (buffer)
  "Match pinned typst-ts-mode's two tree-sitter Imenu groups."
  (handler-case
      (with-imenu-tree-sitter-candidate-points
        (alexandria:when-let ((tree (imenu-tree-sitter-current-tree buffer)))
          (loop :for (category predicate) :in
                  `(("Functions" ,#'imenu-typst-function-identifier-p)
                    ("Headings" ,(lambda (node)
                                    (string= (tree-sitter:node-type node)
                                             "heading"))))
                :for children :=
                  (imenu-typst-walk-category
                   buffer (tree-sitter:tree-root-node tree)
                   category predicate 0)
                :when children
                  :collect (make-imenu-candidate
                            :label category
                            :children children))))
    (error (condition)
      (log:warn "Typst Imenu indexing failed for ~a: ~a"
                (buffer-name buffer) condition)
      nil)))

;;; --- terraform-mode -----------------------------------------------------

(defparameter *imenu-terraform-type-only-pattern*
  "(?m)^\\s*(backend|provider|provisioner)\\s+([^=]\\S+?)(?:\\s+|\\{)")

(defparameter *imenu-terraform-name-only-pattern*
  "(?m)^\\s*(module|output|variable)\\s+(\\S+?)(?:\\s+|\\{)")

(defparameter *imenu-terraform-type-and-name-pattern*
  "(?m)^\\s*(data|ephemeral|resource)\\s+(\"\\S+?\")\\s+(\\S+?)(?:\\s+|\\{)")

(defparameter *imenu-terraform-group-order*
  '("ephemeral" "data" "resource" "output" "module" "variable"
    "provisioner" "backend" "provider"))

(defun imenu-terraform-unquoted (string)
  (remove #\" string))

(defun imenu-terraform-match-string
    (source register-starts register-ends index)
  (subseq source (aref register-starts index) (aref register-ends index)))

(defun imenu-terraform-match-candidate
    (buffer source register-starts register-ends key-index label offset-index)
  (let* ((key (imenu-terraform-match-string
               source register-starts register-ends key-index))
         (point (copy-point (buffer-start-point buffer)))
         (offset (aref register-starts offset-index)))
    (character-offset point offset)
    (values
     key
     (make-imenu-candidate
      :label label
      :detail (format nil "[Terraform ~a] line ~d"
                      key (line-number-at-point point))
      :point point))))

(defun imenu-terraform-scan-pattern
    (buffer source table pattern label-function offset-index)
  (ppcre:do-scans
      (start end register-starts register-ends pattern source)
    (declare (ignore start end))
    (let ((label (funcall label-function source
                          register-starts register-ends)))
      (multiple-value-bind (key candidate)
          (imenu-terraform-match-candidate
           buffer source register-starts register-ends 0 label offset-index)
        ;; terraform--generate-imenu uses `push', so matches within each
        ;; category are deliberately reversed from source order.
        (push candidate (gethash key table))))))

(defun imenu-terraform-candidates (buffer)
  "Match pinned terraform-mode's regexp-generated Imenu index."
  (handler-case
      (let ((source (buffer-text buffer))
            (table (make-hash-table :test #'equal)))
        (imenu-terraform-scan-pattern
         buffer source table *imenu-terraform-type-only-pattern*
         (lambda (text starts ends)
           (imenu-terraform-unquoted
            (imenu-terraform-match-string text starts ends 1)))
         1)
        (imenu-terraform-scan-pattern
         buffer source table *imenu-terraform-name-only-pattern*
         (lambda (text starts ends)
           (imenu-terraform-unquoted
            (imenu-terraform-match-string text starts ends 1)))
         1)
        (imenu-terraform-scan-pattern
         buffer source table *imenu-terraform-type-and-name-pattern*
         (lambda (text starts ends)
           (format nil "~a/~a"
                   (imenu-terraform-unquoted
                    (imenu-terraform-match-string text starts ends 1))
                   (imenu-terraform-unquoted
                    (imenu-terraform-match-string text starts ends 2))))
         1)
        (loop :for key :in *imenu-terraform-group-order*
              :for children := (gethash key table)
              :when children
                :collect (make-imenu-candidate
                          :label key
                          :children children)))
    (error (condition)
      (log:warn "Terraform Imenu indexing failed for ~a: ~a"
                (buffer-name buffer) condition)
      nil)))

;;; --- just-mode ----------------------------------------------------------

(defparameter *imenu-just-groups*
  '(("task" "(?m)^(?:alias +)?@?([A-Z_a-z][0-9A-Z_a-z-]*).*:[^=]")
    ("variable" "(?m)^(?:export +)?([A-Z_a-z][0-9A-Z_a-z-]*) *:=")
    ("setting" "(?m)^set +([A-Z_a-z][0-9A-Z_a-z-]*)(?:$| |:=)")))

(defun imenu-generic-excluded-offsets
    (source comment-character quote-characters)
  "Mark SOURCE offsets inside a line comment or quoted string."
  (let ((excluded (make-array (1+ (length source))
                              :element-type 'bit :initial-element 0))
        (quote nil)
        (comment-p nil)
        (escaped-p nil))
    (loop :for offset :below (length source)
          :for character := (char source offset)
          :do (setf (aref excluded offset)
                    (if (or quote comment-p) 1 0))
              (cond
                (comment-p
                 (when (char= character #\Newline)
                   (setf comment-p nil)))
                (escaped-p (setf escaped-p nil))
                (quote
                 (cond
                   ((char= character #\\) (setf escaped-p t))
                   ((char= character quote) (setf quote nil))))
                ((char= character #\\) (setf escaped-p t))
                ((char= character comment-character) (setf comment-p t))
                ((member character quote-characters)
                 (setf quote character))))
    (setf (aref excluded (length source))
          (if (or quote comment-p) 1 0))
    excluded))

(defun imenu-just-group-candidates
    (buffer source excluded-offsets category pattern)
  (let ((candidates nil))
    (ppcre:do-scans
        (start end register-starts register-ends pattern source)
      (declare (ignore end))
      ;; GNU Imenu's generic scanner ignores matches whose start is inside a
      ;; comment or string.  A comment cannot satisfy these line-anchored
      ;; patterns, so only multiline string state needs an explicit filter.
      (unless (plusp (aref excluded-offsets start))
        (let ((point (copy-point (buffer-start-point buffer))))
          (character-offset point start)
          (push
           (make-imenu-candidate
            :label (subseq source
                           (aref register-starts 0)
                           (aref register-ends 0))
            :detail (format nil "[Just ~a] line ~d"
                            category (line-number-at-point point))
            :point point)
           candidates))))
    (nreverse candidates)))

(defun imenu-just-candidates (buffer)
  "Match pinned just-mode's generic Imenu expressions and syntax filtering."
  (handler-case
      (let* ((source (buffer-text buffer))
             (excluded-offsets
               (imenu-generic-excluded-offsets
                source #\# '(#\" #\' #\`))))
        ;; `imenu--generic-function' pushes each submenu while traversing the
        ;; expression, hence the package's setting/variable/task declaration
        ;; appears as task/variable/setting.  It then sorts children by their
        ;; line-start positions, preserving source order within each group.
        (loop :for (category pattern) :in *imenu-just-groups*
              :for children :=
                (imenu-just-group-candidates
                 buffer source excluded-offsets category pattern)
              :when children
                :collect (make-imenu-candidate
                          :label category
                          :children children)))
    (error (condition)
      (log:warn "Just Imenu indexing failed for ~a: ~a"
                (buffer-name buffer) condition)
      nil)))

;;; --- nasm-mode ----------------------------------------------------------

(defparameter *imenu-nasm-patterns*
  '("(?m)^[ \\t]*([A-Za-z_?][A-Za-z0-9_$#@~?]*)[ \\t]*:"
    "(?im)(?<![A-Za-z0-9_$#@~.?%])%(?:define|macro)(?![A-Za-z0-9_$#@~.?%])\\s+([A-Za-z0-9_$#@~.?]+)"))

(defun imenu-nasm-candidates (buffer)
  "Match pinned nasm-mode's flat label and define/macro generic index."
  (handler-case
      (let* ((source (buffer-text buffer))
             (excluded-offsets
               (imenu-generic-excluded-offsets
                source #\; '(#\" #\' #\`)))
             (entries nil)
             (seen (make-hash-table :test #'equal)))
        (dolist (pattern *imenu-nasm-patterns*)
          (ppcre:do-scans
              (start end register-starts register-ends pattern source)
            (declare (ignore end))
            (unless (plusp (aref excluded-offsets start))
              (let* ((label (subseq source
                                    (aref register-starts 0)
                                    (aref register-ends 0)))
                     (key (cons label start)))
                (unless (gethash key seen)
                  (setf (gethash key seen) t)
                  (let ((point (copy-point (buffer-start-point buffer))))
                    (character-offset point start)
                    (line-start point)
                    (push
                     (list
                      start
                      (make-imenu-candidate
                       :label label
                       :detail (format nil "[NASM symbol] line ~d"
                                       (line-number-at-point point))
                       :point point))
                     entries)))))))
        ;; Both generic expressions share a nil menu title.  GNU Imenu merges
        ;; them into one flat index and sorts the combined entries by position.
        (mapcar #'second
                (sort entries #'< :key #'first)))
    (error (condition)
      (log:warn "NASM Imenu indexing failed for ~a: ~a"
                (buffer-name buffer) condition)
      nil)))

(register-imenu-native-provider 'org-mode 'imenu-org-candidates)
(register-imenu-native-provider
 'lem-markdown-mode:markdown-mode 'imenu-markdown-candidates)
(register-imenu-native-provider
 'lem-python-mode:python-mode 'imenu-python-candidates)
(register-imenu-native-provider
 'lem-java-mode:java-mode 'imenu-java-candidates)
(register-imenu-native-provider 'lem-c-mode:c-mode 'imenu-c-candidates)
(register-imenu-native-provider 'c++-mode 'imenu-c++-candidates)
(register-imenu-native-provider
 'lem-rust-mode:rust-mode 'imenu-rust-candidates)
(register-imenu-native-provider 'lem-go-mode:go-mode 'imenu-go-candidates)
(register-imenu-native-provider 'gdscript-mode 'imenu-gdscript-candidates)
(register-imenu-native-provider 'typst-mode 'imenu-typst-candidates)
(register-imenu-native-provider
 'lem-terraform-mode:terraform-mode 'imenu-terraform-candidates)
(register-imenu-native-provider 'just-mode 'imenu-just-candidates)
(register-imenu-native-provider 'nasm-mode 'imenu-nasm-candidates)
