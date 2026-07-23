;;;; The single package holding the whole port.  Commands are interned by
;;;; define-command; exports cover boot/snippet entry points and the minimal
;;;; typed-target registration surface intended for action extensions.

(defpackage :lem-yath
  (:use :cl :lem)
  (:export #:write-boot-report
           #:boot-ok-p
           #:snippet-active-session-p
           #:snippet-current-field-number
           #:snippet-reload
           #:snippet-root-directories
           #:expand-lsp-snippet
           #:action-target
           #:action-origin
           #:action-origin-window
           #:action-origin-buffer
           #:action-origin-point
           #:action-target-origin
           #:action-target-summary
           #:cleanup-action-target-payload
           #:region-action-target
           #:region-action-target-text
           #:file-action-target
           #:file-action-target-pathname
           #:url-action-target
           #:url-action-target-url
           #:identifier-action-target
           #:identifier-action-target-text
           #:identifier-action-target-point
           #:location-action-target
           #:location-action-target-point
           #:location-action-target-line
           #:buffer-action-target
           #:buffer-action-target-buffer
           #:completion-action-target
           #:completion-action-target-context
           #:completion-action-target-item
           #:completion-action-target-generation
           #:completion-action-target-text
           #:register-action-target-provider
           #:register-action))
