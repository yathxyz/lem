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
   :valid-server-name-p))

(defpackage :lem-daemon/transport
  (:use :cl)
  (:local-nicknames (:protocol :lem-daemon/protocol))
  (:export
   :local-backend
   :local-listener
   :local-connection
   :*local-backend*
   :require-local-backend
   :backend-process-id
   :local-endpoint
   :local-metadata
   :open-local-listener
   :local-listener-endpoint
   :accept-local-connection
   :connect-local
   :local-connection-stream
   :close-local-connection
   :close-local-listener))

(defpackage :lem-daemon
  (:use :cl :lem)
  (:local-nicknames (:protocol :lem-daemon/protocol)
                    (:transport :lem-daemon/transport))
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
  (:local-nicknames (:protocol :lem-daemon/protocol)
                    (:transport :lem-daemon/transport))
  (:export :main :run-client))
