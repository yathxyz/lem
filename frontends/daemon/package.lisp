(defpackage :lem-daemon/protocol
  (:use :cl)
  (:export
   :+protocol-version+
   :+maximum-message-bytes+
   :+maximum-files+
   :protocol-error
   :protocol-error-message
   :make-object
   :field
   :encode-message
   :decode-message
   :write-message
   :read-message
   :valid-server-name-p
   :runtime-directory
   :endpoint-pathname
   :metadata-pathname))

(defpackage :lem-daemon
  (:use :cl :lem)
  (:local-nicknames (:protocol :lem-daemon/protocol))
  (:export
   :daemon-implementation
   :invoke-daemon
   :daemon-running-p
   :daemon-endpoint
   :stop-daemon
   :daemon-edit-done
   :daemon-edit-save-and-done
   :daemon-edit-abort))

(defpackage :lem-daemon/client
  (:use :cl)
  (:local-nicknames (:protocol :lem-daemon/protocol))
  (:export :main :run-client))
