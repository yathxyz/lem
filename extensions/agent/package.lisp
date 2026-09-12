(defpackage :lem-agent
  (:use :cl)
  (:local-nicknames (:store :lem-daemon/recovery-store))
  (:export :make-manager :register-provider :register-tool :create-session
           :restore-sessions :find-session :manager-sessions :close-manager
           :session-id :session-ready :session-snapshot
           :subscribe-session :unsubscribe-session
           :submit-message :resume-session :resolve-decision :interrupt-session :close-session
           :receipt-id :await-request
           :operation-session-id :operation-turn-id :operation-generation
           :operation-root :operation-live-p :check-operation
           :register-cancellation :operation-cancelled
           :json-object :json-copy))
