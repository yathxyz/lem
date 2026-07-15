; GDScript highlights for tree-sitter-gdscript 6.x.

(comment) @comment

[
  (string)
  (string_name)
  (node_path)
  (get_node)
] @string

[
  (integer)
  (float)
] @number

[
  (true)
  (false)
  (null)
] @constant

(identifier) @variable
(name) @variable

(type
  (identifier) @type)

(function_definition
  (name) @function)

(constructor_definition
  "_init" @function)

(class_definition
  (name) @type)

(class_name_statement
  (name) @type)

(const_statement
  (name) @constant)

(signal_statement
  (name) @function)

(annotation
  (identifier) @attribute)

(parameters
  (identifier) @variable.parameter)

(typed_parameter
  (identifier) @variable.parameter)

(default_parameter
  (identifier) @variable.parameter)

(typed_default_parameter
  (identifier) @variable.parameter)

(call
  (identifier) @function.call)

[
  "if"
  "elif"
  "else"
  "match"
  "when"
  "for"
  "while"
  "break"
  "continue"
  "and"
  "as"
  "in"
  "is"
  "not"
  "or"
  "pass"
  "class_name"
  "extends"
  "signal"
  "var"
  "onready"
  "setget"
  "remote"
  "master"
  "puppet"
  "remotesync"
  "mastersync"
  "export"
  "enum"
  "class"
  "func"
  "return"
  "await"
] @keyword

[
  (static_keyword)
  (breakpoint_statement)
  (tool_statement)
] @keyword

[
  "~"
  "-"
  "*"
  "**"
  "/"
  "%"
  "+"
  "<<"
  ">>"
  "&"
  "^"
  "|"
  "<"
  ">"
  "=="
  "!="
  ">="
  "<="
  "!"
  "&&"
  "||"
  "="
  "+="
  "-="
  "*="
  "/="
  "%="
  "->"
] @operator
