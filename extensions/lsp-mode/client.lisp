(defpackage :lem-lsp-mode/client
  (:use :cl)
  (:import-from :jsonrpc)
  (:import-from :lem-lsp-mode/lem-stdio-transport
                :lem-stdio-transport)
  (:export :dispose
           :alive-p
           :tcp-client
           :stdio-client)
  #+sbcl
  (:lock t))
(in-package :lem-lsp-mode/client)

(defgeneric dispose (client))
(defgeneric alive-p (client))

(defclass tcp-client (lem-language-client/client:client)
  ((port
    :initarg :port
    :reader tcp-client-port)
   (process
    :initform nil
    :initarg :process
    :reader tcp-client-process)))

(defmethod lem-language-client/client:jsonrpc-connect ((client tcp-client))
  (jsonrpc:client-connect (lem-language-client/client:client-connection client)
                          :mode :tcp
                          :port (tcp-client-port client)))

(defmethod dispose ((client tcp-client))
  (when (tcp-client-process client)
    (lem-process:delete-process (tcp-client-process client))))

(defmethod alive-p ((client tcp-client))
  (or (null (tcp-client-process client))
      (lem-process:process-alive-p (tcp-client-process client))))

(defclass stdio-client (lem-language-client/client:client)
  ((process :initarg :process
            :reader stdio-client-process)))

(defmethod lem-language-client/client:jsonrpc-connect ((client stdio-client))
  (jsonrpc/client:client-connect-using-class (lem-language-client/client:client-connection client)
                                             'lem-stdio-transport
                                             :process (stdio-client-process client)))

(defmethod dispose ((client stdio-client))
  (let ((process (stdio-client-process client)))
    (when (ignore-errors (uiop:process-alive-p process))
      (ignore-errors (uiop:terminate-process process :urgent t)))
    (ignore-errors (uiop:wait-process process))
    (dolist (stream (list (uiop:process-info-input process)
                          (uiop:process-info-output process)
                          (uiop:process-info-error-output process)))
      (when (streamp stream)
        (ignore-errors (close stream))))))

(defmethod alive-p ((client stdio-client))
  (ignore-errors
    (uiop:process-alive-p (stdio-client-process client))))
