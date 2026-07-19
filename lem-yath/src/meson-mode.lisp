;;;; Pinned meson-mode parity: exact completion tables, syntax, idle
;;;; signatures, and structure-aware two-column indentation.

(in-package :lem-yath)

(defparameter *meson-keywords*
  '("true" "false" "if" "else" "elif" "endif" "and" "or" "not"
    "foreach" "endforeach" "in" "continue" "break"))

(defparameter *meson-builtin-variables*
  '("meson" "build_machine" "host_machine" "target_machine"))

(defparameter *meson-builtin-functions*
  '(("add_global_arguments" . "void add_global_arguments(arg1, arg2, ...)")
    ("add_global_link_arguments" . "void add_global_link_arguments(*arg1*, *arg2*, ...)")
    ("add_languages" . "bool add_languages(*langs*)")
    ("add_project_arguments" . "void add_project_arguments(arg1, arg2, ...)")
    ("add_project_link_arguments" . "void add_project_link_arguments(*arg1*, *arg2*, ...)")
    ("add_test_setup" . "void add_test_setup(*name*, ...)")
    ("alias_target")
    ("assert" . "void assert(*condition*, *message*)")
    ("benchmark" . "void benchmark(name, executable, ...)")
    ("both_libraries" . "buildtarget = both_libraries(library_name, list_of_sources, ...)")
    ("build_target")
    ("configuration_data" . "configuration_data_object = configuration_data(...)")
    ("configure_file" . "generated_file = configure_file(...)")
    ("custom_target" . "customtarget custom_target(*name*, ...)")
    ("declare_dependency" . "dependency_object declare_dependency(...)")
    ("dependency" . "dependency_object dependency(*dependency_name*, ...)")
    ("disabler")
    ("environment" . "environment_object environment(...)")
    ("error" . "void error(message)")
    ("executable" . "buildtarget executable(*exe_name*, *sources*, ...)")
    ("files" . "file_array files(list_of_filenames)")
    ("find_library")
    ("find_program" . "program find_program(program_name1, program_name2, ...)")
    ("generator" . "generator_object generator(*executable*, ...)")
    ("get_option" . "value get_option(option_name)")
    ("get_variable" . "value get_variable(variable_name, fallback)")
    ("gettext")
    ("import" . "module_object import(module_name)")
    ("include_directories" . "include_object include_directories(directory_names, ...)")
    ("install_data" . "void install_data(list_of_files, ...)")
    ("install_headers" . "void install_headers(list_of_headers, ...)")
    ("install_man" . "void install_man(list_of_manpages, ...)")
    ("install_subdir" . "void install_subdir(subdir_name, install_dir : ..., exclude_files : ..., exclude_directories : ..., strip_directory : ...)")
    ("install_emptydir" . "void install_emptydir(list_of_dirs, ...)")
    ("install_symlink" . "void install_symlink(link_name, ...)")
    ("is_disabler" . "bool is_disabler(var)")
    ("is_variable" . "bool is_variable(varname)")
    ("jar")
    ("join_paths" . "string join_paths(string1, string2, ...)")
    ("library" . "buildtarget library(library_name, list_of_sources, ...)")
    ("message" . "void message(text)")
    ("option")
    ("project" . "void project(project_name, list_of_languages, ...)")
    ("run_command" . "runresult run_command(command, list_of_args, ...)")
    ("run_target")
    ("set_variable" . "void set_variable(variable_name, value)")
    ("shared_library" . "buildtarget shared_library(library_name, list_of_sources, ...)")
    ("shared_module" . "buildtarget shared_module(module_name, list_of_sources, ...)")
    ("static_library" . "buildtarget static_library(library_name, list_of_sources, ...)")
    ("subdir" . "void subdir(dir_name, ...)")
    ("subdir_done" . "subdir_done()")
    ("subproject" . "subproject_object subproject(subproject_name, ...)")
    ("summary" . "void summary(key, value)")
    ("test" . "void test(name, executable, ...)")
    ("vcs_tag" . "customtarget vcs_tag(...)")
    ("warning" . "void warning(text)")))

(defparameter *meson-object-methods*
  '("returncode" "compiled" "stdout" "stderr"
    "returncode" "stdout" "stderr"
    "set" "append" "prepend"
    "set" "set10" "set_quoted" "has" "get"
    "found" "type_name" "version" "get_pkgconfig_variable"
    "found" "version" "found" "found" "process"
    "system" "cpu_family" "cpu" "endian"
    "system" "cpu" "cpu_family" "endian"
    "extract_objects" "extract_all_objects" "get_id" "outdir"
    "full_path" "private_dir_include" "full_path" "get_variable"
    "compiles" "links" "get_id" "compute_int" "sizeof" "has_header"
    "has_header_symbol" "run" "has_function" "has_member" "has_members"
    "has_type" "alignment" "version" "cmd_array" "find_library"
    "has_argument" "has_multi_arguments" "first_supported_argument"
    "unittest_args" "symbols_have_underscore_prefix"
    "strip" "format" "to_upper" "to_lower" "underscorify" "split"
    "startswith" "endswith" "contains" "to_int" "join"
    "version_compare" "is_even" "is_odd" "to_string" "to_int"
    "length" "contains" "get"))

(defparameter *meson-meson-methods*
  '("get_compiler" "is_cross_build" "has_exe_wrapper" "is_unity"
    "is_subproject" "current_source_dir" "current_build_dir" "source_root"
    "build_root" "add_install_script" "add_postconf_script"
    "add_dist_script" "install_dependency_manifest" "override_find_program"
    "project_version" "project_license" "version" "project_name"
    "get_cross_property" "backend"))

(defparameter *meson-machine-methods*
  '("system" "cpu_family" "cpu" "endian"))

(defparameter *meson-pch-keywords* '("c_pch" "cpp_pch"))

(defparameter *meson-language-argument-keywords*
  '("c_args" "cpp_args" "cuda_args" "d_args" "d_import_dirs"
    "d_unittest" "d_module_versions" "d_debug" "fortran_args" "java_args"
    "objc_args" "objcpp_args" "rust_args" "vala_args" "cs_args"))

(defparameter *meson-vala-keywords* '("vala_header" "vala_gir" "vala_vapi"))
(defparameter *meson-rust-keywords* '("rust_crate_type"))
(defparameter *meson-csharp-keywords* '("resources" "cs_args"))

(defparameter *meson-build-target-keywords*
  '("build_by_default" "build_rpath" "dependencies" "extra_files" "gui_app"
    "link_with" "link_whole" "link_args" "link_depends"
    "implicit_include_directories" "include_directories" "install"
    "install_rpath" "install_dir" "install_mode" "name_prefix" "name_suffix"
    "native" "objects" "override_options" "sources"
    "gnu_symbol_visibility"))

(defparameter *meson-known-build-target-keywords*
  (append *meson-build-target-keywords*
          *meson-language-argument-keywords*
          *meson-pch-keywords*
          *meson-vala-keywords*
          *meson-rust-keywords*
          *meson-csharp-keywords*))

(defparameter *meson-known-executable-keywords*
  (append *meson-known-build-target-keywords*
          '("implib" "export_dynamic" "link_language" "pie")))

(defparameter *meson-known-shared-library-keywords*
  (append *meson-known-build-target-keywords*
          '("version" "soversion" "vs_module_defs" "darwin_versions")))

(defparameter *meson-known-shared-module-keywords*
  (append *meson-known-build-target-keywords* '("vs_module_defs")))

(defparameter *meson-known-static-library-keywords*
  (append *meson-known-build-target-keywords* '("pic")))

(defparameter *meson-known-jar-keywords*
  (append *meson-known-executable-keywords* '("main_class")))

(defparameter *meson-known-library-keywords*
  (union *meson-known-shared-library-keywords*
         *meson-known-static-library-keywords*
         :test #'string=))

(defparameter *meson-base-test-keywords*
  '("args" "depends" "env" "should_fail" "timeout" "workdir" "suite"
    "priority" "protocol"))

(defparameter *meson-keyword-arguments*
  `(("add_global_arguments" . ("language" "native"))
    ("add_global_link_arguments" . ("language" "native"))
    ("add_languages" . ("required"))
    ("add_project_link_arguments" . ("language" "native"))
    ("add_project_arguments" . ("language" "native"))
    ("add_test_setup" . ("exe_wrapper" "gdb" "timeout_multiplier" "env" "is_default"))
    ("benchmark" . ,*meson-base-test-keywords*)
    ("build_target" . ,*meson-known-build-target-keywords*)
    ("configure_file" . ("input" "output" "configuration" "command" "copy"
                           "depfile" "install_dir" "install_mode" "capture"
                           "install" "format" "output_format" "encoding"))
    ("custom_target" . ("input" "output" "command" "install" "install_dir"
                         "install_mode" "build_always" "capture" "depends"
                         "depend_files" "depfile" "build_by_default"
                         "build_always_stale" "console"))
    ("dependency" . ("default_options" "embed" "fallback" "language" "main"
                       "method" "modules" "cmake_module_path" "optional_modules"
                       "native" "not_found_message" "required" "static"
                       "version" "private_headers" "cmake_args" "include_type"))
    ("declare_dependency" . ("include_directories" "link_with" "sources"
                              "dependencies" "compile_args" "link_args"
                              "link_whole" "version" "variables"))
    ("executable" . ,*meson-known-executable-keywords*)
    ("find_program" . ("required" "native" "version" "dirs"))
    ("generator" . ("arguments" "output" "depends" "depfile" "capture"
                    "preserve_path_from"))
    ("include_directories" . ("is_system"))
    ("install_data" . ("install_dir" "install_mode" "rename" "sources"))
    ("install_headers" . ("install_dir" "install_mode" "subdir"))
    ("install_man" . ("install_dir" "install_mode"))
    ("install_subdir" . ("exclude_files" "exclude_directories" "install_dir"
                          "install_mode" "strip_directory"))
    ("install_emptydir" . ("install_mode" "install_tag"))
    ("install_symlink" . ("install_dir" "install_tag" "pointing_to"))
    ("jar" . ,*meson-known-jar-keywords*)
    ("project" . ("version" "meson_version" "default_options" "license"
                    "subproject_dir"))
    ("run_command" . ("check" "capture" "env"))
    ("run_target" . ("command" "depends"))
    ("shared_library" . ,*meson-known-shared-library-keywords*)
    ("shared_module" . ,*meson-known-shared-module-keywords*)
    ("static_library" . ,*meson-known-static-library-keywords*)
    ("both_libraries" . ,*meson-known-library-keywords*)
    ("library" . ,*meson-known-library-keywords*)
    ("subdir" . ("if_found"))
    ("subproject" . ("version" "default_options" "required"))
    ("test" . (,@*meson-base-test-keywords* "is_parallel"))
    ("vcs_tag" . ("input" "output" "fallback" "command" "replace_string"))))

(defun meson-builtin-function-names ()
  (mapcar #'car *meson-builtin-functions*))

(defun meson-regexp-alternation (strings)
  (format nil "(?:~{~a~^|~})"
          (mapcar #'ppcre:quote-meta-chars
                  (sort (copy-list strings) #'> :key #'length))))

(defun make-meson-tmlanguage ()
  (make-tmlanguage
   :patterns
   (make-tm-patterns
    (lem/language-mode-tools:make-tm-line-comment-region "#")
    (lem/language-mode-tools:make-tm-string-region "'''")
    (lem/language-mode-tools:make-tm-string-region "'")
    (make-tm-match (language-mode-token-pattern *meson-keywords*)
                   :name 'syntax-keyword-attribute)
    (make-tm-match
     (format nil "(?:^|[^.A-Za-z0-9_])(~a)\\b(?=[ \\t]*(?:\\(|$))"
             (meson-regexp-alternation (meson-builtin-function-names)))
     :captures (vector nil (make-tm-name 'syntax-builtin-attribute)))
    (make-tm-match
     (language-mode-token-pattern *meson-builtin-variables*)
     :name 'syntax-variable-attribute)
    (make-tm-match
     "\\b([_A-Za-z][_A-Za-z0-9]*)[ \\t]*=(?:[^=]|$)"
     :captures (vector nil (make-tm-name 'syntax-variable-attribute))))))

(set-syntax-parser *meson-syntax-table* (make-meson-tmlanguage))

(defun meson-point-code-p (point)
  (not (in-string-or-comment-p point)))

(defun meson-enclosing-opener (point)
  "Return the nearest unmatched syntactic opener before POINT."
  (with-point ((scan point))
    (loop :with depth := 0
          :while (character-offset scan -1)
          :for character := (character-at scan)
          :when (meson-point-code-p scan)
            :do (cond
                  ((find character ")]}")
                   (incf depth))
                  ((find character "([{")
                   (if (plusp depth)
                       (decf depth)
                       (return (copy-point scan :temporary))))))))

(defun meson-call-name-before-opener (opener)
  (when (and opener (eql (character-at opener) #\())
    (with-point ((end opener)
                 (start opener))
      (skip-whitespace-backward start t)
      (move-point end start)
      (skip-chars-backward start #'syntax-symbol-char-p)
      (let ((name (points-to-string start end)))
        (and (assoc name *meson-builtin-functions* :test #'string=)
             name)))))

(defun meson-function-at-point (&optional (point (current-point)))
  "Return the pinned builtin call surrounding or under POINT."
  (or (alexandria:when-let ((symbol (symbol-string-at-point point)))
        (and (assoc symbol *meson-builtin-functions* :test #'string=)
             symbol))
      (with-point ((scan point))
        (loop :for opener := (meson-enclosing-opener scan)
              :while opener
              :for function := (meson-call-name-before-opener opener)
              :when function :return function
              :do (move-point scan opener)))))

(defun meson-function-documentation (name)
  (cdr (assoc name *meson-builtin-functions* :test #'string=)))

(defun meson-receiver-before-dot (start)
  (with-point ((end start)
               (receiver-start start))
    (unless (eql (character-at end -1) #\.)
      (return-from meson-receiver-before-dot nil))
    (character-offset end -1)
    (move-point receiver-start end)
    (skip-chars-backward receiver-start #'syntax-symbol-char-p)
    (points-to-string receiver-start end)))

(defun meson-completion-candidates (start)
  (let ((receiver (meson-receiver-before-dot start)))
    (cond
      ((string= receiver "meson")
       (values *meson-meson-methods* :method))
      ((member receiver '("build_machine" "host_machine" "target_machine")
               :test #'string=)
       (values *meson-machine-methods* :method))
      (receiver
       (values *meson-object-methods* :method))
      (t
       (let* ((opener (meson-enclosing-opener start))
              (function (meson-call-name-before-opener opener))
              (keywords
                (and function
                     (cdr (assoc function *meson-keyword-arguments*
                                 :test #'string=)))))
         (if (and opener (eql (character-at opener) #\() function)
             (values
              (append keywords
                      *meson-builtin-variables*
                      (meson-builtin-function-names))
              :argument)
             (values
              (append *meson-keywords*
                      *meson-builtin-variables*
                      (meson-builtin-function-names))
              :global)))))))

(defun meson-completion-detail (name context)
  (cond
    ((eq context :method) "Meson method")
    ((and (eq context :argument)
          (find name (mapcan #'copy-list
                             (mapcar #'cdr *meson-keyword-arguments*))
                :test #'string=))
     "Meson keyword argument")
    ((member name *meson-keywords* :test #'string=) "Meson keyword")
    ((member name *meson-builtin-variables* :test #'string=)
     "Meson builtin variable")
    (t "Meson builtin function")))

(defun meson-completion-focus-action (documentation)
  (when documentation
    (lambda (context)
      (show-message
       (lem/markdown-buffer:markdown-buffer documentation)
       :style '(:gravity :vertically-adjacent-window
                :offset-y -1 :offset-x 1)
       :source-window
       (lem/popup-menu::popup-menu-window
        (lem/completion-mode::context-popup-menu context))))))

(defun meson-completion-items (point)
  "Return pinned meson-mode CAPF candidates at POINT."
  (when (meson-point-code-p point)
    (multiple-value-bind (start end prefix)
        (auto-completion-symbol-bounds point)
      (declare (ignore prefix))
      (multiple-value-bind (names context)
          (meson-completion-candidates start)
        (mapcar
         (lambda (name)
           (let ((documentation (meson-function-documentation name)))
             (lem/completion-mode:make-completion-item
              :label name
              :filter-text name
              :insert-text name
              :detail (meson-completion-detail name context)
              :start start
              :end end
              :focus-action
              (meson-completion-focus-action documentation))))
         names)))))

(define-editor-variable meson-last-eldoc nil)
(define-editor-variable meson-eldoc-window nil)

(defun meson-clear-eldoc ()
  (let ((window (variable-value 'meson-eldoc-window)))
    (when (and window
               (eq window (frame-message-window (current-frame))))
      (clear-message))
    (setf (variable-value 'meson-last-eldoc) nil
          (variable-value 'meson-eldoc-window) nil)))

(defun meson-eldoc-idle-function ()
  "Show the pinned builtin signature while point remains in a Meson call."
  (unless (or (lem/prompt-window:current-prompt-window)
              (and lem/completion-mode::*completion-context*
                   (lem/completion-mode::context-popup-menu
                    lem/completion-mode::*completion-context*)))
    (let* ((function (meson-function-at-point))
           (documentation
             (and function (meson-function-documentation function)))
           (last (variable-value 'meson-last-eldoc))
           (window (variable-value 'meson-eldoc-window)))
      (unless (and (equal documentation last)
                   window
                   (eq window (frame-message-window (current-frame))))
        (meson-clear-eldoc)
        (when documentation
          (setf (variable-value 'meson-last-eldoc) documentation
                (variable-value 'meson-eldoc-window)
                (show-message documentation :timeout nil)))))))

(defun meson-line-leading-token (point)
  (with-point ((scan point))
    (back-to-indentation scan)
    (when (and (meson-point-code-p scan)
               (not (eql (character-at scan) #\#)))
      (with-point ((end scan))
        (loop :while (let ((character (character-at end)))
                       (and character
                            (or (alphanumericp character)
                                (eql character #\_))))
              :do (character-offset end 1))
        (string-downcase (points-to-string scan end))))))

(defun meson-block-depth-before-line (point)
  (with-point ((scan (buffer-start-point (point-buffer point)))
               (limit point))
    (line-start limit)
    (loop :with depth := 0
          :while (point< scan limit)
          :for token := (meson-line-leading-token scan)
          :do (cond
                ((member token '("if" "foreach") :test #'string=)
                 (incf depth))
                ((member token '("endif" "endforeach") :test #'string=)
                 (setf depth (max 0 (1- depth)))))
          :unless (line-offset scan 1) :return depth
          :finally (return depth))))

(defun meson-line-indentation (point)
  (with-point ((scan point))
    (back-to-indentation scan)
    (point-column scan)))

(defun meson-line-code-text (point)
  (with-point ((start point)
               (scan point)
               (end point))
    (line-start start)
    (move-point scan start)
    (line-end end)
    (loop :while (point< scan end)
          :when (and (eql (character-at scan) #\#)
                     (not (in-string-p scan)))
            :do (move-point end scan)
                (loop-finish)
          :do (character-offset scan 1))
    (string-right-trim '(#\Space #\Tab) (points-to-string start end))))

(defun meson-previous-code-line (point)
  (with-point ((scan point))
    (loop :while (line-offset scan -1)
          :for text := (meson-line-code-text scan)
          :unless (zerop (length
                          (string-trim '(#\Space #\Tab) text)))
            :return (values scan text)
          :finally (return (values nil nil)))))

(defun meson-continuation-line-p (text)
  (and text
       (ppcre:scan
        "(?:\\+=|==|!=|<=|>=|[=+*/%<>:,\\-]|\\b(?:and|or|in)|\\\\)$"
        text)))

(defun meson-current-line-closing-delimiter-p (point)
  (with-point ((scan point))
    (back-to-indentation scan)
    (find (character-at scan) ")]}" :test #'eql)))

(defun meson-calc-indent (point)
  "Approximate pinned SMIE from the same block, delimiter, and operator rules."
  (with-point ((line point))
    (line-start line)
    (with-point ((content line))
      (back-to-indentation content)
      (if (in-string-p content)
          (multiple-value-bind (indent previous)
              (language-previous-nonblank-line line)
            (declare (ignore previous))
            indent)
          (let* ((token (meson-line-leading-token line))
                 (depth (meson-block-depth-before-line line))
                 (block-indent
                   (* 2 (if (member token
                                    '("endif" "endforeach" "else" "elif")
                                    :test #'string=)
                            (max 0 (1- depth))
                            depth)))
                 (opener (meson-enclosing-opener content)))
            (cond
              ((and opener (meson-current-line-closing-delimiter-p line))
               (meson-line-indentation opener))
              (opener
               (+ (meson-line-indentation opener) 2))
              (t
               (multiple-value-bind (previous previous-text)
                   (meson-previous-code-line line)
                 (declare (ignore previous))
                 (if (meson-continuation-line-p previous-text)
                     (+ block-indent 2)
                     block-indent)))))))))

(defun configure-meson-mode-parity ()
  (setf (variable-value 'lem/language-mode:completion-spec)
        (lem/completion-mode:make-completion-spec #'meson-completion-items)
        (variable-value 'lem/language-mode:idle-function)
        'meson-eldoc-idle-function))

(remove-hook *meson-mode-hook* 'configure-meson-mode-parity)
(add-hook *meson-mode-hook* 'configure-meson-mode-parity)
