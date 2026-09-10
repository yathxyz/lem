;;;; Native editor-client routing for the configured Lem environment.

(in-package :lem-yath)

(defun configure-daemon-server ()
  "Start a local listener and route child Git editors to this Lem session."
  #+(and sbcl linux)
  (progn
    (lem-daemon:start-server)
    (lem-daemon:configure-editor-environment :force-git-editor t)))

(defun stop-configured-daemon-server ()
  "Release the local listener when this editor exits."
  #+(and sbcl linux)
  (lem-daemon:stop-server))

(add-hook *exit-editor-hook* 'stop-configured-daemon-server)
(initialize-editor-feature 'configure-daemon-server)
