(defpackage #:lem-structured-notes/lem-adapter
  (:use #:cl #:lem-structured-notes)
  (:local-nicknames (#:proposals #:lem-buffer-proposals))
  (:export #:notes-adapter-error #:notes-adapter-error-code
           #:configure-lem-notes-workspaces #:lem-current-notes-workspaces
           #:lem-notes-workspace-context-workspace #:lem-notes-workspace-context-public-workspace
           #:lem-capture-notes-source #:lem-notes-source-base
           #:lem-current-lsm-snapshot #:lem-current-lsm-node
           #:lem-stage-notes-document-plan #:lem-apply-notes-document-plan
           #:lem-stage-lsm-edit-plan #:lem-apply-lsm-edit-plan
           #:lem-assign-current-lsm-node-id #:lem-set-current-lsm-task-state
           #:lem-open-lsm-daily-note #:lem-append-lsm-journal-entry #:lem-capture-lsm-note
           #:structured-notes-lsm-open-today #:structured-notes-lsm-journal-entry
           #:structured-notes-lsm-capture #:structured-notes-lsm-assign-id))
