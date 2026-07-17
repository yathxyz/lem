(defpackage :lem/daily-driver-defaults
  (:use :cl :lem)
  (:documentation
   "Fork-owned personal defaults for the daily-driver patchset. This layer only
flips defaults; it defines no new mechanism. Keeping it separate keeps the
behavioral diff isolated from the upstream mechanism diff so both rebase
cleanly. See SPEC.md, constraint 3.")
  #+sbcl
  (:lock t))
(in-package :lem/daily-driver-defaults)

;;; DS-7: encoding detection scheme.
;;;
;;; Upstream detects with inquisitor's :JP scheme (UTF-8, then Shift_JIS /
;;; EUC-JP). Every scheme tries UTF-8 first, so UTF-8 files are unaffected; the
;;; scheme only decides which legacy encoding is attempted for non-UTF-8 files.
;;; For a Western daily driver, :TR (UTF-8, then ISO-8859-9 / CP1254) is the
;;; closest inquisitor equivalent to "UTF-8 first, Latin fallback": Latin-1 text
;;; decodes cleanly instead of misdetecting as Japanese, and anything the
;;; detected encoding still cannot decode falls back to latin-1 losslessly via
;;; FIND-FILE-BUFFER.
(setf (variable-value 'lem-core:detect-encoding-scheme :global) :tr)

;;; DS-4: back up each file's pre-save content to <file>~ once per session,
;;; independent of auto-save-mode. Upstream keeps this off.
(setf lem/backup-on-save:*backup-on-save* t)
(add-hook (variable-value 'before-save-hook :global t)
          'lem/backup-on-save:backup-on-save)
