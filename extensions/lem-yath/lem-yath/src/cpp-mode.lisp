;;;; Distinct C++ mode for truthful grammar, snippets, and native indices.

(in-package :lem-yath)

(define-major-mode c++-mode lem-c-mode:c-mode
    (:name "C++"
     :description "C++ source editing"
     :keymap *c++-mode-keymap*
     :syntax-table (mode-syntax-table 'lem-c-mode:c-mode)
     :mode-hook *c++-mode-hook*
     :formatter #'lem-c-mode/format:clang-format))

(define-file-type ("cc" "cp" "cpp" "cxx" "c++"
                   "hh" "hpp" "hxx" "h++")
  c++-mode)
