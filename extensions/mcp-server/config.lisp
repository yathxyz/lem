(in-package :lem-mcp-server)

(defvar *mcp-server-default-port* 7890
  "Default port for MCP server.")

(defvar *mcp-server-default-hostname* "127.0.0.1"
  "Default hostname for MCP server.
Use \"0.0.0.0\" to listen on all interfaces.")

(defvar *mcp-server-auth-token* (uiop:getenv "LEM_MCP_SERVER_TOKEN")
  "Bearer token required by the MCP HTTP endpoint.
The server refuses to start unless this is a string of at least 32 characters.")

(defvar *mcp-disabled-tools* '("eval_expression" "command_execute")
  "MCP tools hidden from listing and dispatch.
Arbitrary Lisp evaluation and unconstrained command execution are unsafe
defaults for an editor-control endpoint, even when it is loopback-only.")

(defvar *mcp-allow-file-resources* nil
  "Whether resources/read accepts arbitrary file:// paths.
Buffer resources remain available regardless of this setting.")

(defvar *mcp-protocol-version* "2024-11-05"
  "MCP protocol version supported by this server.")

(defvar *mcp-server-name* "lem-mcp-server"
  "Name of this MCP server.")

(defvar *mcp-server-version* "0.1.0"
  "Version of this MCP server.")
