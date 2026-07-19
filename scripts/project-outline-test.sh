#!/usr/bin/env bash
# Directory-local consult-outline behavior in real ncurses Lem.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-project-outline-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-project-outline.XXXXXX")"
export HOME="$root/home"
export WORKDIR="$root/work"
export LEM_YATH_COMPLETION_STATE_FILE="$root/completion-ranking.sexp"
export LEM_YATH_PROJECT_OUTLINE_REPORT="$root/report"
export LEM_YATH_PROJECT_OUTLINE_MAIN="$root/config/main.el"
export LEM_YATH_PROJECT_OUTLINE_EMPTY="$root/config/empty.el"
export LEM_YATH_PROJECT_OUTLINE_OUTSIDE="$root/outside/outside.el"
export LEM_YATH_PROJECT_OUTLINE_MALICIOUS="$root/malicious/malicious.el"
export LEM_YATH_PROJECT_OUTLINE_ORG="$root/native-imenu.org"
export LEM_YATH_PROJECT_OUTLINE_MARKDOWN="$root/native-imenu.md"
export LEM_YATH_PROJECT_OUTLINE_PYTHON="$root/native-imenu.py"
export LEM_YATH_PROJECT_OUTLINE_PYTHON_WIDE="$root/native-imenu-wide.py"
export LEM_YATH_PROJECT_OUTLINE_JAVA="$root/NativeImenu.java"
export LEM_YATH_PROJECT_OUTLINE_C="$root/native-imenu.c"
export LEM_YATH_PROJECT_OUTLINE_CPP="$root/NativeImenu.cpp"
export LEM_YATH_PROJECT_OUTLINE_RUST="$root/native-imenu.rs"
export LEM_YATH_PROJECT_OUTLINE_GO="$root/native-imenu.go"
export LEM_YATH_PROJECT_OUTLINE_GDSCRIPT="$root/native-imenu.gd"
export LEM_YATH_PROJECT_OUTLINE_TYPST="$root/native-imenu.typ"
export LEM_YATH_PROJECT_OUTLINE_READER_MARKER="$root/reader-evaluated"
mkdir -p "$HOME" "$WORKDIR" "$root/config" "$root/outside" "$root/malicious"

session="lem-project-outline-$id"
fixture="$(lem-yath_lisp_string "$here/scripts/project-outline-fixture.lisp")"
init="$(lem-yath_lisp_string "$LEM_YATH_SOURCE/init.lisp")"
marker="$(lem-yath_lisp_string "$LEM_YATH_PROJECT_OUTLINE_READER_MARKER")"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,220p' "$LEM_YATH_PROJECT_OUTLINE_REPORT" 2>/dev/null || true
}

report_count() {
  grep -cE "$1" "$LEM_YATH_PROJECT_OUTLINE_REPORT" 2>/dev/null || true
}

wait_report_count() {
  local pattern=$1 expected=$2 i
  for i in $(seq 1 100); do
    [ "$(report_count "$pattern")" -ge "$expected" ] && return 0
    sleep 0.1
  done
  return 1
}

send_chord() {
  tmux_cmd send-keys -t "$session" "$@"
}

invoke_mx() {
  local command=$1 prompt=${2:-}
  send_chord Escape
  sleep 0.15
  send_chord Escape
  sleep 0.15
  send_chord M-x
  lem_wait_for "$session" 'Command:' 10 >/dev/null || return 1
  tmux_cmd send-keys -t "$session" -l "$command"
  sleep 0.4
  send_chord Enter
  if [ -n "$prompt" ]; then
    lem_wait_for "$session" "$prompt" 10 >/dev/null
  fi
}

printf '%s\n' \
  "((emacs-lisp-mode . ((eval . (local-set-key (kbd \"C-c i\") #'consult-outline))" \
  '                       (outline-regexp . ";;;"))))' \
  >"$root/config/.dir-locals.el"

for line in $(seq 1 80); do
  case "$line" in
    3) printf '%s\n' ';;; Alpha section' ;;
    20) printf '%s\n' ';;;; Nested-looking section' ;;
    40) printf '%s\n' ';;; Second target section' ;;
    55) printf '%s\n' ';; Not an outline heading' ;;
    60) printf '%s\n' ';;; Final section' ;;
    *) printf '(defparameter *outline-line-%d* %d)\n' "$line" "$line" ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_MAIN"

printf '%s\n' '(defparameter *empty-outline-file* t)' \
  >"$LEM_YATH_PROJECT_OUTLINE_EMPTY"
printf '%s\n' ';;; Outside heading sentinel' '(defparameter *outside* t)' \
  >"$LEM_YATH_PROJECT_OUTLINE_OUTSIDE"
printf '%s\n' ';;; Malicious heading sentinel' '(defparameter *malicious* t)' \
  >"$LEM_YATH_PROJECT_OUTLINE_MALICIOUS"
printf '%s\n' \
  "#.(progn (with-open-file (stream #P$marker :direction :output :if-exists :supersede :if-does-not-exist :create) (write-line \"executed\" stream)) '((emacs-lisp-mode . ((eval . (local-set-key (kbd \"C-c i\") #'consult-outline)) (outline-regexp . \";;;\"))))))" \
  >"$root/malicious/.dir-locals.el"

for line in $(seq 1 80); do
  case "$line" in
    3) printf '%s\n' '* TODO [#A] [[id:parent][Parent Heading]] :project:' ;;
    20) printf '%s\n' '** TODO [#B] [[https://example.com][Child Heading]] :tag:' ;;
    30) printf '%s\n' '*** Hidden Depth' ;;
    40) printf '%s\n' '* Leaf Heading' ;;
    60) printf '%s\n' '#+begin_src org' ;;
    61) printf '%s\n' '* Fake Block Heading' ;;
    62) printf '%s\n' '#+end_src' ;;
    80) printf '%s\n' '.' ;;
    *) printf 'Org body line %d\n' "$line" ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_ORG"

for line in $(seq 1 80); do
  case "$line" in
    3) printf '%s\n' 'def top(alpha):' ;;
    4) printf '%s\n' '    """Top-level function."""' ;;
    8) printf '%s\n' '    def nested():' ;;
    9) printf '%s\n' '        return alpha' ;;
    12) printf '%s\n' '    class Inner:' ;;
    13) printf '%s\n' '        def method(self):' ;;
    14) printf '%s\n' '            return alpha' ;;
    18) printf '%s\n' '    return nested()' ;;
    30) printf '%s\n' '@decorate' ;;
    31) printf '%s\n' 'class Outer(Base):' ;;
    35) printf '%s\n' '    @classmethod' ;;
    36) printf '%s\n' '    async def build(cls):' ;;
    37) printf '%s\n' '        return cls()' ;;
    50) printf '%s\n' 'text = """' ;;
    51) printf '%s\n' 'def fake():' ;;
    52) printf '%s\n' 'class Fake:' ;;
    53) printf '%s\n' '"""' ;;
    60) printf '%s\n' 'async def tail():' ;;
    61) printf '%s\n' '    return None' ;;
    70) printf '%s\n' '# def comment_fake():' ;;
    *) printf '\n' ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_PYTHON"

for index in $(seq 1 1005); do
  printf 'def item_%04d(): pass\n' "$index"
done >"$LEM_YATH_PROJECT_OUTLINE_PYTHON_WIDE"

for line in $(seq 1 80); do
  case "$line" in
    1) printf '%s\n' 'package demo;' ;;
    3) printf '%s\n' 'public class Outer {' ;;
    5) printf '%s\n' '  public Outer() {}' ;;
    8) printf '%s\n' '  class Inner {' ;;
    10) printf '%s\n' '    void innerMethod() {}' ;;
    12) printf '%s\n' '  }' ;;
    15) printf '%s\n' '  @Deprecated' ;;
    16) printf '%s\n' '  public static String build() {' ;;
    17) printf '%s\n' '    return "class Fake { void nope() {} }";' ;;
    18) printf '%s\n' '  }' ;;
    19) printf '%s\n' '}' ;;
    25) printf '%s\n' 'interface Worker {' ;;
    27) printf '%s\n' '  void work();' ;;
    28) printf '%s\n' '}' ;;
    35) printf '%s\n' 'record Point(int x, int y) {}' ;;
    42) printf '%s\n' 'enum Shade { RED, BLUE }' ;;
    50) printf '%s\n' '// class CommentFake { void nope() {} }' ;;
    *) printf '\n' ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_JAVA"

for line in $(seq 1 90); do
  case "$line" in
    3) printf '%s\n' 'enum Shade { RED, BLUE };' ;;
    8) printf '%s\n' 'struct Outer {' ;;
    10) printf '%s\n' '  int field;' ;;
    12) printf '%s\n' '  struct Nested { int nested; } nested_value;' ;;
    14) printf '%s\n' '};' ;;
    20) printf '%s\n' 'union Value { int integer; float real; };' ;;
    27) printf '%s\n' 'static int global_count = 1;' ;;
    28) printf '%s\n' 'const char *label = "ok";' ;;
    29) printf '%s\n' 'int first, second;' ;;
    32) printf '%s\n' 'int declared(int x);' ;;
    35) printf '%s\n' 'int (*callback)(int);' ;;
    42) printf '%s\n' 'static int helper(int value) {' ;;
    44) printf '%s\n' '  int local = value;' ;;
    46) printf '%s\n' '  enum LocalShade { LOCAL_RED };' ;;
    48) printf '%s\n' '  struct LocalRecord { int hidden; };' ;;
    50) printf '%s\n' '  return local;' ;;
    51) printf '%s\n' '}' ;;
    60) printf '%s\n' '__attribute__((deprecated)) int attributed(void) {' ;;
    61) printf '%s\n' '  return 0;' ;;
    62) printf '%s\n' '}' ;;
    70) printf '%s\n' '// struct CommentFake { int nope; };' ;;
    72) printf '%s\n' 'const char *decoy = "int fake_function(void) {}";' ;;
    *) printf '\n' ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_C"

for line in $(seq 1 100); do
  case "$line" in
    3) printf '%s\n' 'enum class Shade { Red, Blue };' ;;
    8) printf '%s\n' 'union Value { int integer; double real; };' ;;
    14) printf '%s\n' 'class Outer {' ;;
    15) printf '%s\n' 'public:' ;;
    17) printf '%s\n' '  Outer() {}' ;;
    20) printf '%s\n' '  void method() {}' ;;
    23) printf '%s\n' '  class Inner {' ;;
    24) printf '%s\n' '  public:' ;;
    26) printf '%s\n' '    int inner() { return 1; }' ;;
    28) printf '%s\n' '  };' ;;
    30) printf '%s\n' '  int qualified();' ;;
    32) printf '%s\n' '};' ;;
    37) printf '%s\n' 'struct Record { int value; };' ;;
    42) printf '%s\n' 'int global_count = 1;' ;;
    43) printf '%s\n' 'const char *label = "cpp";' ;;
    46) printf '%s\n' 'int declared(int value);' ;;
    49) printf '%s\n' 'namespace demo {' ;;
    51) printf '%s\n' 'int scoped = 2;' ;;
    54) printf '%s\n' 'int helper() { return scoped; }' ;;
    57) printf '%s\n' 'class NamespaceClass {};' ;;
    59) printf '%s\n' '}' ;;
    64) printf '%s\n' 'int Outer::qualified() { return 3; }' ;;
    70) printf '%s\n' 'int free_function() {' ;;
    71) printf '%s\n' '  int local = 0;' ;;
    72) printf '%s\n' '  class LocalClass {};' ;;
    73) printf '%s\n' '  return local;' ;;
    74) printf '%s\n' '}' ;;
    82) printf '%s\n' '// class CommentFake { void nope() {} };' ;;
    84) printf '%s\n' 'const char *decoy_cpp = "class StringFake {};";' ;;
    *) printf '\n' ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_CPP"

for line in $(seq 1 90); do
  case "$line" in
    1) printf '%s\n' 'mod outer {' ;;
    3) printf '%s\n' '    pub fn module_fn() {}' ;;
    5) printf '%s\n' '    mod inner {}' ;;
    7) printf '%s\n' '}' ;;
    12) printf '%s\n' 'enum Shade { Red }' ;;
    18) printf '%s\n' 'impl<T> Display for Wrapper<T> {' ;;
    20) printf '%s\n' '    fn trait_method(&self) {}' ;;
    22) printf '%s\n' '}' ;;
    28) printf '%s\n' 'impl Wrapper<i32> {' ;;
    30) printf '%s\n' '    fn inherent(&self) {}' ;;
    32) printf '%s\n' '}' ;;
    38) printf '%s\n' 'type Alias = Wrapper<i32>;' ;;
    44) printf '%s\n' 'struct Wrapper<T> { value: T }' ;;
    52) printf '%s\n' 'fn top() {' ;;
    54) printf '%s\n' '    fn nested() {}' ;;
    56) printf '%s\n' '    nested();' ;;
    58) printf '%s\n' '}' ;;
    64) printf '%s\n' 'const DECOY: &str = "fn fake() {}";' ;;
    68) printf '%s\n' '// fn comment_fake() {}' ;;
    *) printf '\n' ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_RUST"

for line in $(seq 1 90); do
  case "$line" in
    1) printf '%s\n' 'package demo' ;;
    3) printf '%s\n' 'func Top() {}' ;;
    8) printf '%s\n' 'func (receiver *Record) Work() {}' ;;
    14) printf '%s\n' 'type Record struct { Value int }' ;;
    20) printf '%s\n' 'type Worker interface { Work() }' ;;
    26) printf '%s\n' 'type Count int' ;;
    32) printf '%s\n' 'type Alias = string' ;;
    38) printf '%s\n' 'type (' ;;
    39) printf '%s\n' '    GroupStruct struct{}' ;;
    40) printf '%s\n' '    GroupInterface interface{}' ;;
    41) printf '%s\n' '    GroupType int' ;;
    42) printf '%s\n' '    GroupAlias = string' ;;
    43) printf '%s\n' ')' ;;
    50) printf '%s\n' 'func Container() {' ;;
    52) printf '%s\n' '    type Local int' ;;
    54) printf '%s\n' '}' ;;
    64) printf '%s\n' 'const DECOY = "type Fake struct{}"' ;;
    68) printf '%s\n' '// func commentFake() {}' ;;
    *) printf '\n' ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_GO"

for line in $(seq 1 100); do
  case "$line" in
    1) printf '%s\n' 'var top_value = 1' ;;
    3) printf '%s\n' 'export var exported_value = 2' ;;
    5) printf '%s\n' 'onready var ready_value = $Node' ;;
    8) printf '%s\n' 'func leaf():' ;;
    9) printf '%s\n' '    pass' ;;
    14) printf '%s\n' 'class Actor:' ;;
    16) printf '%s\n' '    var health = 100' ;;
    18) printf '%s\n' '    export var speed = 5' ;;
    20) printf '%s\n' '    onready var child = $Child' ;;
    23) printf '%s\n' '    func tick(delta):' ;;
    24) printf '%s\n' '        var delta_copy = delta' ;;
    25) printf '%s\n' '        pass' ;;
    28) printf '%s\n' '    class Inner:' ;;
    29) printf '%s\n' '        var enabled = true' ;;
    33) printf '%s\n' 'var after_class = 4' ;;
    42) printf '%s\n' 'var decoy = "func fake(): var hidden = 0"' ;;
    46) printf '%s\n' '# class CommentFake: var hidden = 0' ;;
    *) printf '\n' ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_GDSCRIPT"

for line in $(seq 1 80); do
  case "$line" in
    1) printf '%s\n' '#let plain = 1' ;;
    3) printf '%s\n' '#let add(left, right) = left + right' ;;
    5) printf '%s\n' '#let value = add(1, 2)' ;;
    8) printf '%s\n' '= Introduction' ;;
    12) printf '%s\n' '== Details *with markup*' ;;
    20) printf '%s\n' '#let outer(x) = {' ;;
    22) printf '%s\n' '  let inner(y) = y * 2' ;;
    24) printf '%s\n' '  inner(x)' ;;
    25) printf '%s\n' '}' ;;
    30) printf '%s\n' '=== Final' ;;
    40) printf '%s\n' '#let decoy = "= Fake heading; let nope(x) = x"' ;;
    45) printf '%s\n' '// #let comment_fake(x) = x' ;;
    46) printf '%s\n' '// == Comment heading' ;;
    *) printf '\n' ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_TYPST"

for line in $(seq 1 80); do
  case "$line" in
    1) printf '%s\n' '---' ;;
    2) printf '%s\n' 'title: Native Imenu' ;;
    3) printf '%s\n' '# Fake YAML' ;;
    4) printf '%s\n' '---' ;;
    6) printf '%s\n' 'Guide Home' ;;
    7) printf '%s\n' '==========' ;;
    20) printf '%s\n' '## Install Steps' ;;
    30) printf '%s\n' '### Deep Topic' ;;
    40) printf '%s\n' '# Sibling #' ;;
    50) printf '%s\n' '```md' ;;
    51) printf '%s\n' '# Fake Code' ;;
    52) printf '%s\n' '```' ;;
    60) printf '%s\n' '<!--' ;;
    61) printf '%s\n' '[^hidden]: Hidden comment footnote' ;;
    62) printf '%s\n' '-->' ;;
    65) printf '%s\n' '[^note]: Visible footnote' ;;
    70) printf '%s\n' '[^note]: Duplicate footnote' ;;
    80) printf '%s\n' '.' ;;
    *) printf 'Markdown body line %d\n' "$line" ;;
  esac
done >"$LEM_YATH_PROJECT_OUTLINE_MARKDOWN"
: >"$LEM_YATH_PROJECT_OUTLINE_REPORT"

lem_start "$session" \
  -q \
  --eval "(progn (load #P$init) (load #P$fixture))" \
  "$LEM_YATH_PROJECT_OUTLINE_MAIN"
if ! lem_wait_for "$session" 'Alpha section' 30 >/dev/null ||
   ! wait_report_count '^READY$' 1; then
  fail startup 'the configured Emacs Lisp fixture did not open'
  exit 1
fi

if grep -q '^JUMP-CONFIG delay=30 stages=4 colors=#ff0000,#b90019,#71001a,#350717$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass jump-config 'the production delay, iteration count, and TTY fade match Pulsar'
else
  fail jump-config 'the configured Pulsar timing or Modus fade palette differed'
fi

send_chord C-c z r
wait_report_count '^STATE file=main ' 1 || true
activation="$(grep '^STATE file=main ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
if grep -q 'minor=yes regexp=";;;" normal=LEM-YATH-CONSULT-OUTLINE emacs=LEM-YATH-CONSULT-OUTLINE insert=LEM-YATH-LLM-SEND visual=LEM-YATH-LLM-SEND' <<<"$activation"; then
  pass activation 'the exact dir-local scope preserves normal/Emacs versus Insert/Visual precedence'
else
  fail activation 'mode activation or C-c i state precedence differed'
  exit 1
fi

send_chord C-c z c
wait_report_count '^CANDIDATES count=4$' 1 || true
candidates_ok=1
grep -q '^CANDIDATE line=3 label=";;; Alpha section"$' "$LEM_YATH_PROJECT_OUTLINE_REPORT" || candidates_ok=0
grep -q '^CANDIDATE line=20 label=";;;; Nested-looking section"$' "$LEM_YATH_PROJECT_OUTLINE_REPORT" || candidates_ok=0
grep -q '^CANDIDATE line=40 label=";;; Second target section"$' "$LEM_YATH_PROJECT_OUTLINE_REPORT" || candidates_ok=0
grep -q '^CANDIDATE line=60 label=";;; Final section"$' "$LEM_YATH_PROJECT_OUTLINE_REPORT" || candidates_ok=0
if [ "$candidates_ok" = 1 ]; then
  pass candidates 'literal ;;; headings include longer prefixes and retain source order'
else
  fail candidates 'candidate collection differed from Consult outline-regexp behavior'
fi

send_chord C-c z b
send_chord C-c z r
wait_report_count '^STATE file=main line=80 ' 1 || true
origin="$(grep '^STATE file=main line=80 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' <<<"$origin")"

send_chord C-c i
if lem_wait_for "$session" 'Go to heading:' 10 >/dev/null; then
  sleep 0.4
  screen="$(lem_capture "$session")"
  alpha_row="$(grep -n -m1 '3 ;;; Alpha section' <<<"$screen" | cut -d: -f1)"
  nested_row="$(grep -n -m1 '20 ;;;; Nested-looking section' <<<"$screen" | cut -d: -f1)"
  second_row="$(grep -n -m1 '40 ;;; Second target section' <<<"$screen" | cut -d: -f1)"
  final_row="$(grep -n -m1 '60 ;;; Final section' <<<"$screen" | cut -d: -f1)"
  if [ -n "$alpha_row" ] && [ -n "$nested_row" ] &&
     [ -n "$second_row" ] && [ -n "$final_row" ] &&
     [ "$alpha_row" -lt "$nested_row" ] &&
     [ "$nested_row" -lt "$second_row" ] &&
     [ "$second_row" -lt "$final_row" ]; then
    pass presentation 'line-numbered candidates are visibly source ordered'
  else
    fail presentation 'the visible candidate order or line annotations differed'
  fi

  send_chord -l 'Second'
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=main line=40 column=4 ' 1 || true
  preview="$(grep '^STATE file=main line=40 column=4 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  preview_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' <<<"$preview")"
  if grep -q 'preview=";;; Second target section" input="Second"' <<<"$preview" &&
     grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' <<<"$preview" &&
     [ -n "$origin_view" ] && [ -n "$preview_view" ] &&
     [ "$origin_view" != "$preview_view" ]; then
    pass preview 'filter focus moves to the literal match and recenters the source window'
  else
    fail preview 'focus preview did not move, place, or recenter as Consult does'
  fi

  send_chord C-g
  sleep 0.4
  send_chord C-c z r
  wait_report_count '^STATE file=main line=80 ' 2 || true
  restored="$(grep '^STATE file=main line=80 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  restored_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' <<<"$restored")"
  if [ "$restored_view" = "$origin_view" ] &&
     grep -q 'preview=NIL input=NIL pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$restored"; then
    pass cancel 'C-g restores exact source point and viewport'
  else
    fail cancel 'prompt cancellation leaked its preview point or viewport'
  fi
else
  fail presentation 'C-c i did not open the outline prompt'
fi

send_chord C-c i
if lem_wait_for "$session" 'Go to heading:' 10 >/dev/null; then
  send_chord -l 'Second'
  sleep 0.4
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=main line=40 column=4 ' 2 || true
  final="$(grep '^STATE file=main line=40 column=4 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  if grep -q 'pulse=yes pulse-stage=[0-3] pulse-line=40 pulse-attribute=LEM-YATH-JUMP-PULSE-[1-4]-ATTRIBUTE pulse-overlays=1' \
       <<<"$final"; then
    pass jump-pulse 'accepted outline navigation recenters and pulses only its destination line'
  else
    fail jump-pulse "accepted outline navigation lacked live Pulsar feedback: $final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=main line=80 ' 3 || true
  if grep -q 'preview=NIL input=NIL' <<<"$final" &&
     [ "$(grep -c '^STATE file=main line=80 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT")" -ge 3 ]; then
    pass final-jump 'one Return commits the match-position jump and C-o returns to origin'
  else
    fail final-jump 'final selection or Vi jumplist behavior differed'
  fi

  sleep 0.8
  send_chord C-c z r
  wait_report_count '^STATE file=main line=80 ' 4 || true
  expired="$(grep '^STATE file=main line=80 ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  if grep -q 'pulse=no pulse-stage=none pulse-line=none pulse-attribute=none pulse-overlays=0' \
       <<<"$expired"; then
    pass jump-expiry 'the fourth fade removes its timer and overlay cleanly'
  else
    fail jump-expiry "jump feedback leaked after its configured fade: $expired"
  fi
else
  fail final-jump 'the second outline prompt did not open'
fi

# Generic M-x Imenu is deliberately a separate path from Consult outline:
# pinned Lisp definitions, no live preview or pulse, recenter on acceptance,
# and one Vi jumplist entry.
if invoke_mx imenu 'Index item:'; then
  if grep -Fq 'Variables' <<<"$(lem_capture "$session")"; then
    pass imenu-group 'M-x Imenu opens the pinned Variables submenu'
  else
    fail imenu-group 'the top-level Lisp Imenu Variables group was not visible'
  fi
  tmux_cmd send-keys -t "$session" -l Variables
  send_chord Enter
  sleep 0.4
  tmux_cmd send-keys -t "$session" -l 'outline-line-41'
  sleep 0.5
  if grep -Fq '*outline-line-41*' <<<"$(lem_capture "$session")"; then
    pass imenu-presentation 'the successive prompt exposes the selected group'
  else
    fail imenu-presentation 'the filtered Lisp Imenu candidate was not visible'
  fi
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=main line=41 column=14 ' 1 || true
  imenu_final="$(grep '^STATE file=main line=41 column=14 ' \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  imenu_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' \
    <<<"$imenu_final")"
  if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$imenu_final" &&
     [ -n "$origin_view" ] && [ -n "$imenu_view" ] &&
     [ "$origin_view" != "$imenu_view" ]; then
    pass imenu-jump 'Lisp Imenu lands on the name, recenters, and does not pulse'
  else
    fail imenu-jump "the accepted Lisp Imenu destination differed: $imenu_final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=main line=80 ' 5 || true
  if [ "$(grep -c '^STATE file=main line=80 ' \
          "$LEM_YATH_PROJECT_OUTLINE_REPORT")" -ge 5 ]; then
    pass imenu-jumplist 'C-o returns from generic Imenu to the exact origin'
  else
    fail imenu-jumplist 'generic Imenu did not record one Vi jump'
  fi
else
  fail imenu-command 'M-x imenu did not open the Index item prompt'
fi

# GNU Org's native index is limited to depth two, normalizes heading labels,
# reveals folded context, and retains Imenu's recenter-only jump feedback.
send_chord C-c z 5
lem_wait_for "$session" 'Parent Heading' 10 >/dev/null || true
send_chord C-c z i
wait_report_count '^IMENU-INDEX file=org count=3$' 1 || true
org_index_ok=1
grep -q '^IMENU-PATH file=org path="Parent Heading"$' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" || org_index_ok=0
grep -q '^IMENU-PATH file=org path="Parent Heading/Child Heading"$' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" || org_index_ok=0
grep -q '^IMENU-PATH file=org path="Leaf Heading"$' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" || org_index_ok=0
if [ "$org_index_ok" = 1 ] &&
   [ "$(report_count '^IMENU-PATH file=org ')" -eq 3 ]; then
  pass imenu-org-index 'Org Imenu keeps normalized level-one/two headings only'
else
  fail imenu-org-index 'Org heading depth, normalization, or block exclusion differed'
fi

send_chord C-c z f
sleep 0.3
send_chord C-c z r
wait_report_count '^STATE file=org line=80 ' 1 || true
org_origin="$(grep '^STATE file=org line=80 ' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
org_origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' \
  <<<"$org_origin")"
if grep -q 'folds=1 hidden=no reader-marker=no$' <<<"$org_origin"; then
  pass imenu-org-fold-setup 'the destination starts inside a folded Org subtree'
else
  fail imenu-org-fold-setup "the Org fold precondition differed: $org_origin"
fi

if invoke_mx imenu 'Index item:'; then
  org_top="$(lem_capture "$session")"
  if grep -Fq 'Parent.Heading' <<<"$org_top" &&
     grep -Fq 'Leaf.Heading' <<<"$org_top"; then
    pass imenu-org-presentation 'Org top-level headings use Imenu space replacement'
  else
    fail imenu-org-presentation 'the normalized Org root prompt differed'
  fi
  tmux_cmd send-keys -t "$session" -l Parent
  send_chord Enter
  sleep 0.4
  if grep -Fq 'Child.Heading' <<<"$(lem_capture "$session")"; then
    pass imenu-org-hierarchy 'the Org parent opens its level-two submenu'
  else
    fail imenu-org-hierarchy 'the Org child prompt was not visible'
  fi
  tmux_cmd send-keys -t "$session" -l Child
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=org line=20 column=0 ' 1 || true
  org_final="$(grep '^STATE file=org line=20 column=0 ' \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  org_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' \
    <<<"$org_final")"
  if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0 folds=0 hidden=no' \
       <<<"$org_final" &&
     [ -n "$org_origin_view" ] && [ -n "$org_view" ] &&
     [ "$org_origin_view" != "$org_view" ]; then
    pass imenu-org-jump 'Org Imenu reveals, recenters, and does not pulse'
  else
    fail imenu-org-jump "the accepted Org destination differed: $org_final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=org line=80 ' 2 || true
  if [ "$(report_count '^STATE file=org line=80 ')" -ge 2 ]; then
    pass imenu-org-jumplist 'C-o returns from Org Imenu to the exact origin'
  else
    fail imenu-org-jumplist 'Org Imenu did not record one Vi jump'
  fi
else
  fail imenu-org-command 'M-x imenu did not open in the Org fixture'
fi

# markdown-mode's pinned defaults use a nested ATX/Setext outline, literal `.'
# self entries, fenced/YAML exclusion, and one deduplicated Footnotes submenu.
send_chord C-c z 6
lem_wait_for "$session" 'Guide Home' 10 >/dev/null || true
send_chord C-c z i
wait_report_count '^IMENU-INDEX file=markdown count=8$' 1 || true
markdown_index_ok=1
for path in \
  'Guide Home' \
  'Guide Home/.' \
  'Guide Home/Install Steps' \
  'Guide Home/Install Steps/.' \
  'Guide Home/Install Steps/Deep Topic' \
  'Sibling' \
  'Footnotes' \
  'Footnotes/^note'; do
  grep -Fqx "IMENU-PATH file=markdown path=\"$path\"" \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" || markdown_index_ok=0
done
if [ "$markdown_index_ok" = 1 ] &&
   [ "$(report_count '^IMENU-PATH file=markdown ')" -eq 8 ]; then
  pass imenu-markdown-index 'Markdown Imenu matches nested headings and footnotes'
else
  fail imenu-markdown-index 'Markdown hierarchy, exclusion, or footnote deduplication differed'
fi

send_chord C-c z b
send_chord C-c z r
wait_report_count '^STATE file=markdown line=80 ' 1 || true
markdown_origin="$(grep '^STATE file=markdown line=80 ' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
markdown_origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' \
  <<<"$markdown_origin")"

if invoke_mx imenu 'Index item:'; then
  markdown_top="$(lem_capture "$session")"
  if grep -Fq 'Guide.Home' <<<"$markdown_top" &&
     grep -Fq 'Sibling' <<<"$markdown_top" &&
     grep -Fq 'Footnotes' <<<"$markdown_top"; then
    pass imenu-markdown-presentation 'Markdown roots and Footnotes are visible'
  else
    fail imenu-markdown-presentation 'the Markdown root prompt differed'
  fi
  tmux_cmd send-keys -t "$session" -l Guide
  send_chord Enter
  sleep 0.4
  markdown_guide="$(lem_capture "$session")"
  if grep -Fq 'Install.Steps' <<<"$markdown_guide" &&
     grep -Fq '[Markdown H1] line 6' <<<"$markdown_guide"; then
    pass imenu-markdown-self 'a parent heading retains its literal self entry'
  else
    fail imenu-markdown-self 'the Markdown self/child prompt differed'
  fi
  tmux_cmd send-keys -t "$session" -l Install
  send_chord Enter
  sleep 0.4
  if grep -Fq 'Deep.Topic' <<<"$(lem_capture "$session")"; then
    pass imenu-markdown-hierarchy 'successive prompts preserve Markdown depth'
  else
    fail imenu-markdown-hierarchy 'the nested Markdown child was not visible'
  fi
  tmux_cmd send-keys -t "$session" -l Deep
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=markdown line=30 column=0 ' 1 || true
  markdown_final="$(grep '^STATE file=markdown line=30 column=0 ' \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  markdown_view="$(sed -n 's/^.* view=\([^ ]*\) minor=.*$/\1/p' \
    <<<"$markdown_final")"
  if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$markdown_final" &&
     [ -n "$markdown_origin_view" ] && [ -n "$markdown_view" ] &&
     [ "$markdown_origin_view" != "$markdown_view" ]; then
    pass imenu-markdown-jump 'Markdown Imenu lands exactly and recenters without pulse'
  else
    fail imenu-markdown-jump "the accepted Markdown destination differed: $markdown_final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=markdown line=80 ' 2 || true
  if [ "$(report_count '^STATE file=markdown line=80 ')" -ge 2 ]; then
    pass imenu-markdown-jumplist 'C-o returns from Markdown Imenu to its origin'
  else
    fail imenu-markdown-jumplist 'Markdown Imenu did not record one Vi jump'
  fi
else
  fail imenu-markdown-command 'M-x imenu did not open in the Markdown fixture'
fi

send_chord C-c z b
if invoke_mx imenu 'Index item:'; then
  tmux_cmd send-keys -t "$session" -l Footnotes
  send_chord Enter
  sleep 0.4
  if grep -Fq '^note' <<<"$(lem_capture "$session")"; then
    tmux_cmd send-keys -t "$session" -l '^note'
    send_chord Enter
    sleep 0.5
    send_chord C-c z r
    wait_report_count '^STATE file=markdown line=65 column=0 ' 1 || true
    markdown_footnote="$(grep '^STATE file=markdown line=65 column=0 ' \
      "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
    if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
         <<<"$markdown_footnote"; then
      pass imenu-markdown-footnote 'Footnotes jump to the first unique definition'
    else
      fail imenu-markdown-footnote 'the Markdown footnote destination differed'
    fi
  else
    fail imenu-markdown-footnote 'the Footnotes submenu was empty'
    send_chord C-g
  fi
else
  fail imenu-markdown-footnote 'M-x imenu did not reopen for Footnotes'
fi

# python-ts-mode uses a sparse tree of nested function/class definitions.
# Parent nodes retain the pinned self-jump labels, async forms share the def
# label, decorators do not move the target, and string/comment decoys vanish.
send_chord C-c z 7
lem_wait_for "$session" 'def top' 10 >/dev/null || true
send_chord C-c z i
wait_report_count '^IMENU-INDEX file=python count=10$' 1 || true
python_index_ok=1
for path in \
  'top (def)...' \
  'top (def).../*function definition*' \
  'top (def).../nested (def)' \
  'top (def).../Inner (class)...' \
  'top (def).../Inner (class).../*class definition*' \
  'top (def).../Inner (class).../method (def)' \
  'Outer (class)...' \
  'Outer (class).../*class definition*' \
  'Outer (class).../build (def)' \
  'tail (def)'; do
  grep -Fqx "IMENU-PATH file=python path=\"$path\"" \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" || python_index_ok=0
done
if [ "$python_index_ok" = 1 ] &&
   [ "$(report_count '^IMENU-PATH file=python ')" -eq 10 ]; then
  pass imenu-python-index 'Python Imenu matches nested def/class and decoy semantics'
else
  fail imenu-python-index 'Python hierarchy, labels, async forms, or exclusions differed'
fi

send_chord C-c z b
send_chord C-c z r
wait_report_count '^STATE file=python line=80 column=0 ' 1 || true
python_origin="$(grep '^STATE file=python line=80 column=0 ' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
python_origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
  <<<"$python_origin")"

if invoke_mx imenu 'Index item:'; then
  python_top="$(lem_capture "$session")"
  if grep -Fq 'top.(def)...' <<<"$python_top" &&
     grep -Fq 'Outer.(class)...' <<<"$python_top" &&
     grep -Fq 'tail.(def)' <<<"$python_top"; then
    pass imenu-python-presentation 'Python roots use the pinned typed labels'
  else
    fail imenu-python-presentation 'the Python root prompt differed'
  fi
  tmux_cmd send-keys -t "$session" -l Outer
  send_chord Enter
  sleep 0.4
  python_outer="$(lem_capture "$session")"
  if grep -Fq '*class.definition*' <<<"$python_outer" &&
     grep -Fq 'build.(def)' <<<"$python_outer"; then
    pass imenu-python-hierarchy 'a Python parent exposes its self jump and child'
  else
    fail imenu-python-hierarchy 'the Python class submenu differed'
  fi
  tmux_cmd send-keys -t "$session" -l build
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=python line=36 column=4 ' 1 || true
  python_final="$(grep '^STATE file=python line=36 column=4 ' \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  python_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
    <<<"$python_final")"
  if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$python_final" &&
     [ -n "$python_origin_view" ] && [ -n "$python_view" ] &&
     [ "$python_origin_view" != "$python_view" ]; then
    pass imenu-python-jump 'Python Imenu lands on async def and recenters without pulse'
  else
    fail imenu-python-jump "the Python Imenu destination differed: $python_final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=python line=80 column=0 ' 2 || true
  if [ "$(report_count '^STATE file=python line=80 column=0 ')" -ge 2 ]; then
    pass imenu-python-jumplist 'C-o returns from Python Imenu to its exact origin'
  else
    fail imenu-python-jumplist 'Python Imenu did not record one Vi jump'
  fi
else
  fail imenu-python-command 'M-x imenu did not open in the Python fixture'
fi

# The pinned treesit sparse-tree argument is a depth bound, not an item cap.
send_chord C-c z 8
lem_wait_for "$session" 'item_0001' 10 >/dev/null || true
send_chord C-c z w
wait_report_count '^IMENU-WIDE file=python-wide count=1005$' 1 || true
if grep -q '^IMENU-WIDE file=python-wide count=1005$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-python-wide 'Python Imenu retains more than 1,000 sibling definitions'
else
  fail imenu-python-wide 'the sparse-tree depth bound was treated as an item cap'
fi

# Pinned java-ts-mode groups sparse trees by declaration kind.  Its "Enum"
# setting intentionally indexes records; constructors and actual enums vanish.
send_chord C-c z 9
lem_wait_for "$session" 'public class Outer' 10 >/dev/null || true
send_chord C-c z i
wait_report_count '^IMENU-INDEX file=java count=12$' 1 || true
java_index_ok=1
for path in \
  'Class' \
  'Class/Outer' \
  'Class/Outer/ ' \
  'Class/Outer/Inner' \
  'Interface' \
  'Interface/Worker' \
  'Enum' \
  'Enum/Point' \
  'Method' \
  'Method/innerMethod' \
  'Method/build' \
  'Method/work'; do
  grep -Fqx "IMENU-PATH file=java path=\"$path\"" \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" || java_index_ok=0
done
java_root_order="$(sed -n \
  's/^IMENU-PATH file=java path="\([^/"]*\)"$/\1/p' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | paste -sd, -)"
if [ "$java_index_ok" = 1 ] &&
   [ "$(report_count '^IMENU-PATH file=java ')" -eq 12 ] &&
   [ "$java_root_order" = 'Class,Interface,Enum,Method' ] &&
   ! grep -Eq '^IMENU-PATH file=java .*Shade|CommentFake|nope' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-java-index 'Java Imenu matches pinned categories, hierarchy, and exclusions'
else
  fail imenu-java-index 'Java categories, names, records, or exclusions differed'
fi

send_chord C-c z b
if invoke_mx imenu 'Index item:'; then
  java_top="$(lem_capture "$session")"
  if grep -Fq 'Class' <<<"$java_top" &&
     grep -Fq 'Interface' <<<"$java_top" &&
     grep -Fq 'Enum' <<<"$java_top" &&
     grep -Fq 'Method' <<<"$java_top"; then
    pass imenu-java-presentation 'Java roots use the pinned category order'
  else
    fail imenu-java-presentation 'the Java category prompt differed'
  fi
  tmux_cmd send-keys -t "$session" -l Class
  send_chord Enter
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l Outer
  send_chord Enter
  sleep 0.4
  if grep -Fq 'Inner' <<<"$(lem_capture "$session")"; then
    pass imenu-java-hierarchy 'a Java class exposes its self jump and nested class'
  else
    fail imenu-java-hierarchy 'the Java class hierarchy prompt differed'
  fi
  send_chord C-g
else
  fail imenu-java-command 'M-x imenu did not open in the Java fixture'
fi

send_chord C-c z b
send_chord C-c z r
wait_report_count '^STATE file=java line=80 column=0 ' 1 || true
java_origin="$(grep '^STATE file=java line=80 column=0 ' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
java_origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
  <<<"$java_origin")"

if invoke_mx imenu 'Index item:'; then
  tmux_cmd send-keys -t "$session" -l Method
  send_chord Enter
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l build
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=java line=15 column=2 ' 1 || true
  java_final="$(grep '^STATE file=java line=15 column=2 ' \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  java_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
    <<<"$java_final")"
  if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$java_final" &&
     [ -n "$java_origin_view" ] && [ -n "$java_view" ] &&
     [ "$java_origin_view" != "$java_view" ]; then
    pass imenu-java-jump 'Java Imenu lands on the annotated method node without pulse'
  else
    fail imenu-java-jump "the Java Imenu destination differed: $java_final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=java line=80 column=0 ' 2 || true
  if [ "$(report_count '^STATE file=java line=80 column=0 ')" -ge 2 ]; then
    pass imenu-java-jumplist 'C-o returns from Java Imenu to its exact origin'
  else
    fail imenu-java-jumplist 'Java Imenu did not record one Vi jump'
  fi
else
  fail imenu-java-command 'M-x imenu did not reopen for a method jump'
fi

# Pinned c-ts-mode groups only top-level enum/struct/union declarations,
# ordinary declarations that are not direct function prototypes, and function
# definitions.  The multi-declarator declaration contributes its first name.
send_chord C-c z 0
lem_wait_for "$session" 'enum Shade' 10 >/dev/null || true
send_chord C-c z i
wait_report_count '^IMENU-INDEX file=c count=14$' 1 || true
c_index_ok=1
for path in \
  'Enum' \
  'Enum/Shade' \
  'Struct' \
  'Struct/Outer' \
  'Union' \
  'Union/Value' \
  'Variable' \
  'Variable/global_count' \
  'Variable/label' \
  'Variable/first' \
  'Variable/decoy' \
  'Function' \
  'Function/helper' \
  'Function/attributed'; do
  grep -Fqx "IMENU-PATH file=c path=\"$path\"" \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" || c_index_ok=0
done
c_root_order="$(sed -n \
  's/^IMENU-PATH file=c path="\([^/"]*\)"$/\1/p' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | paste -sd, -)"
if [ "$c_index_ok" = 1 ] &&
   [ "$(report_count '^IMENU-PATH file=c ')" -eq 14 ] &&
   [ "$c_root_order" = 'Enum,Struct,Union,Variable,Function' ] &&
   ! grep -Eq '^IMENU-PATH file=c .*Nested|Local|declared|callback|CommentFake|fake_function|second' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-c-index 'C Imenu matches pinned categories, declarators, and exclusions'
else
  fail imenu-c-index 'C categories, names, prototypes, or top-level predicates differed'
fi

send_chord C-c z b
if invoke_mx imenu 'Index item:'; then
  c_top="$(lem_capture "$session")"
  if grep -Fq 'Enum' <<<"$c_top" &&
     grep -Fq 'Struct' <<<"$c_top" &&
     grep -Fq 'Union' <<<"$c_top" &&
     grep -Fq 'Variable' <<<"$c_top" &&
     grep -Fq 'Function' <<<"$c_top"; then
    pass imenu-c-presentation 'C roots use the pinned category order'
  else
    fail imenu-c-presentation 'the C category prompt differed'
  fi
  send_chord C-g
else
  fail imenu-c-command 'M-x imenu did not open in the C fixture'
fi

send_chord C-c z b
send_chord C-c z r
wait_report_count '^STATE file=c line=90 column=0 ' 1 || true
c_origin="$(grep '^STATE file=c line=90 column=0 ' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
c_origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
  <<<"$c_origin")"

if invoke_mx imenu 'Index item:'; then
  tmux_cmd send-keys -t "$session" -l Function
  send_chord Enter
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l attributed
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=c line=60 column=0 ' 1 || true
  c_final="$(grep '^STATE file=c line=60 column=0 ' \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  c_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
    <<<"$c_final")"
  if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$c_final" &&
     [ -n "$c_origin_view" ] && [ -n "$c_view" ] &&
     [ "$c_origin_view" != "$c_view" ]; then
    pass imenu-c-jump 'C Imenu lands on the attributed function node without pulse'
  else
    fail imenu-c-jump "the C Imenu destination differed: $c_final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=c line=90 column=0 ' 2 || true
  if [ "$(report_count '^STATE file=c line=90 column=0 ')" -ge 2 ]; then
    pass imenu-c-jumplist 'C-o returns from C Imenu to its exact origin'
  else
    fail imenu-c-jumplist 'C Imenu did not record one Vi jump'
  fi
else
  fail imenu-c-command 'M-x imenu did not reopen for a function jump'
fi

send_chord C-c z p
lem_wait_for "$session" 'enum class Shade' 10 >/dev/null || true
send_chord C-c z m
wait_report_count '^MODE file=cpp major=C++-MODE tree=cpp$' 1 || true
if grep -q '^MODE file=cpp major=C++-MODE tree=cpp$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-cpp-routing 'C++ suffixes select the distinct mode and C++ grammar'
else
  fail imenu-cpp-routing 'the C++ fixture reused C mode or the C grammar'
fi

send_chord C-c z i
wait_report_count '^IMENU-INDEX file=cpp count=28$' 1 || true
cpp_index_ok=1
for path in \
  'Enum' \
  'Enum/Shade' \
  'Struct' \
  'Struct/Record' \
  'Union' \
  'Union/Value' \
  'Variable' \
  'Variable/global_count' \
  'Variable/label' \
  'Variable/scoped' \
  'Variable/decoy_cpp' \
  'Function' \
  'Function/Outer' \
  'Function/method' \
  'Function/inner' \
  'Function/helper' \
  'Function/Outer::qualified' \
  'Function/free_function' \
  'Class' \
  'Class/Outer' \
  'Class/Outer/ ' \
  'Class/Outer/Outer' \
  'Class/Outer/method' \
  'Class/Outer/Inner' \
  'Class/Outer/Inner/ ' \
  'Class/Outer/Inner/inner' \
  'Class/NamespaceClass' \
  'Class/LocalClass'; do
  grep -Fqx "IMENU-PATH file=cpp path=\"$path\"" \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" || cpp_index_ok=0
done
cpp_root_order="$(sed -n \
  's/^IMENU-PATH file=cpp path="\([^/"]*\)"$/\1/p' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | paste -sd, -)"
if [ "$cpp_index_ok" = 1 ] &&
   [ "$(report_count '^IMENU-PATH file=cpp ')" -eq 28 ] &&
   [ "$cpp_root_order" = 'Enum,Struct,Union,Variable,Function,Class' ] &&
   ! grep -Eq '^IMENU-PATH file=cpp .*(declared|/local"|CommentFake|StringFake|nope)' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-cpp-index 'C++ Imenu matches pinned categories, hierarchy, and exclusions'
else
  fail imenu-cpp-index 'C++ categories, qualified names, or predicates differed'
fi

send_chord C-c z b
if invoke_mx imenu 'Index item:'; then
  cpp_top="$(lem_capture "$session")"
  if grep -Fq 'Enum' <<<"$cpp_top" &&
     grep -Fq 'Struct' <<<"$cpp_top" &&
     grep -Fq 'Union' <<<"$cpp_top" &&
     grep -Fq 'Variable' <<<"$cpp_top" &&
     grep -Fq 'Function' <<<"$cpp_top" &&
     grep -Fq 'Class' <<<"$cpp_top"; then
    pass imenu-cpp-presentation 'C++ roots expose every pinned category'
  else
    fail imenu-cpp-presentation 'the C++ category prompt differed'
  fi
  tmux_cmd send-keys -t "$session" -l Class
  send_chord Enter
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l Outer
  send_chord Enter
  sleep 0.4
  cpp_class="$(lem_capture "$session")"
  if grep -Fq 'Inner' <<<"$cpp_class" &&
     grep -Fq 'method' <<<"$cpp_class"; then
    pass imenu-cpp-hierarchy 'a C++ class opens its self/member hierarchy'
  else
    fail imenu-cpp-hierarchy 'the C++ class hierarchy prompt differed'
  fi
  send_chord C-g
else
  fail imenu-cpp-command 'M-x imenu did not open in the C++ fixture'
fi

send_chord C-c z b
send_chord C-c z r
wait_report_count '^STATE file=cpp line=100 column=0 ' 1 || true
cpp_origin="$(grep '^STATE file=cpp line=100 column=0 ' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
cpp_origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
  <<<"$cpp_origin")"

if invoke_mx imenu 'Index item:'; then
  tmux_cmd send-keys -t "$session" -l Function
  send_chord Enter
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l 'Outer::qualified'
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=cpp line=64 column=0 ' 1 || true
  cpp_final="$(grep '^STATE file=cpp line=64 column=0 ' \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  cpp_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
    <<<"$cpp_final")"
  if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$cpp_final" &&
     [ -n "$cpp_origin_view" ] && [ -n "$cpp_view" ] &&
     [ "$cpp_origin_view" != "$cpp_view" ]; then
    pass imenu-cpp-jump 'C++ Imenu lands on a qualified definition without pulse'
  else
    fail imenu-cpp-jump "the C++ Imenu destination differed: $cpp_final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=cpp line=100 column=0 ' 2 || true
  if [ "$(report_count '^STATE file=cpp line=100 column=0 ')" -ge 2 ]; then
    pass imenu-cpp-jumplist 'C-o returns from C++ Imenu to its exact origin'
  else
    fail imenu-cpp-jumplist 'C++ Imenu did not record one Vi jump'
  fi
else
  fail imenu-cpp-command 'M-x imenu did not reopen for a qualified jump'
fi

# rust-ts-mode exposes six ordered sparse-tree categories.  Matching parents
# retain a literal-space self entry, impl labels preserve trait/type text, and
# functions nest only below matching function ancestors.
send_chord C-c z u
lem_wait_for "$session" 'mod outer' 10 >/dev/null || true
send_chord C-c z m
wait_report_count '^MODE file=rust major=RUST-MODE tree=rust$' 1 || true
if grep -q '^MODE file=rust major=RUST-MODE tree=rust$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-rust-routing 'Rust suffixes select the configured mode and grammar'
else
  fail imenu-rust-routing 'the Rust fixture did not activate Rust tree-sitter'
fi
send_chord C-c z v
wait_report_count '^PROVIDER file=rust native=IMENU-RUST-CANDIDATES lsp=none$' 1 || true
if grep -q '^PROVIDER file=rust native=IMENU-RUST-CANDIDATES lsp=none$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-rust-provider 'the fallback uses native Rust symbols without LSP'
else
  fail imenu-rust-provider 'an LSP workspace or different provider owned Rust Imenu'
fi

send_chord C-c z i
wait_report_count '^IMENU-INDEX file=rust count=20$' 1 || true
rust_index_ok=1
for path in \
  'Module' \
  'Module/outer' \
  'Module/outer/ ' \
  'Module/outer/inner' \
  'Enum' \
  'Enum/Shade' \
  'Impl' \
  'Impl/Display for Wrapper<T>' \
  'Impl/Wrapper<i32>' \
  'Type' \
  'Type/Alias' \
  'Struct' \
  'Struct/Wrapper' \
  'Fn' \
  'Fn/module_fn' \
  'Fn/trait_method' \
  'Fn/inherent' \
  'Fn/top' \
  'Fn/top/ ' \
  'Fn/top/nested'; do
  grep -Fqx "IMENU-PATH file=rust path=\"$path\"" \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" || rust_index_ok=0
done
rust_root_order="$(sed -n \
  's/^IMENU-PATH file=rust path="\([^/"]*\)"$/\1/p' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | paste -sd, -)"
if [ "$rust_index_ok" = 1 ] &&
   [ "$(report_count '^IMENU-PATH file=rust ')" -eq 20 ] &&
   [ "$rust_root_order" = 'Module,Enum,Impl,Type,Struct,Fn' ] &&
   ! grep -Eq '^IMENU-PATH file=rust .*(fake|comment_fake)' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-rust-index 'Rust Imenu matches pinned categories, names, and hierarchy'
else
  fail imenu-rust-index 'Rust categories, impl labels, hierarchy, or exclusions differed'
fi

send_chord C-c z b
if invoke_mx imenu 'Index item:'; then
  rust_top="$(lem_capture "$session")"
  if grep -Fq 'Module' <<<"$rust_top" &&
     grep -Fq 'Enum' <<<"$rust_top" &&
     grep -Fq 'Impl' <<<"$rust_top" &&
     grep -Fq 'Type' <<<"$rust_top" &&
     grep -Fq 'Struct' <<<"$rust_top" &&
     grep -Fq 'Fn' <<<"$rust_top"; then
    pass imenu-rust-presentation 'Rust roots expose every pinned category'
  else
    fail imenu-rust-presentation 'the Rust category prompt differed'
  fi
  tmux_cmd send-keys -t "$session" -l Module
  send_chord Enter
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l outer
  send_chord Enter
  sleep 0.4
  rust_module="$(lem_capture "$session")"
  if grep -Fq 'inner' <<<"$rust_module"; then
    pass imenu-rust-hierarchy 'a Rust module opens its self/nested-module hierarchy'
  else
    fail imenu-rust-hierarchy 'the Rust module hierarchy prompt differed'
  fi
  send_chord C-g
else
  fail imenu-rust-command 'M-x imenu did not open in the Rust fixture'
fi

send_chord C-c z b
send_chord C-c z r
wait_report_count '^STATE file=rust line=90 column=0 ' 1 || true
rust_origin="$(grep '^STATE file=rust line=90 column=0 ' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
rust_origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
  <<<"$rust_origin")"

if invoke_mx imenu 'Index item:'; then
  tmux_cmd send-keys -t "$session" -l Fn
  send_chord Enter
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l top
  send_chord Enter
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l nested
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=rust line=54 column=4 ' 1 || true
  rust_final="$(grep '^STATE file=rust line=54 column=4 ' \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  rust_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
    <<<"$rust_final")"
  if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$rust_final" &&
     [ -n "$rust_origin_view" ] && [ -n "$rust_view" ] &&
     [ "$rust_origin_view" != "$rust_view" ]; then
    pass imenu-rust-jump 'Rust Imenu lands on a nested function without pulse'
  else
    fail imenu-rust-jump "the Rust Imenu destination differed: $rust_final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=rust line=90 column=0 ' 2 || true
  if [ "$(report_count '^STATE file=rust line=90 column=0 ')" -ge 2 ]; then
    pass imenu-rust-jumplist 'C-o returns from Rust Imenu to its exact origin'
  else
    fail imenu-rust-jumplist 'Rust Imenu did not record one Vi jump'
  fi
else
  fail imenu-rust-command 'M-x imenu did not reopen for a nested function jump'
fi

# go-ts-mode uses six ordered categories.  Its predicates classify an entire
# parenthesized type declaration, while its name function deliberately keeps
# the first spec's name for every matching category.
send_chord C-c z g
lem_wait_for "$session" 'package demo' 10 >/dev/null || true
send_chord C-c z m
wait_report_count '^MODE file=go major=GO-MODE tree=go$' 1 || true
if grep -q '^MODE file=go major=GO-MODE tree=go$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-go-routing 'Go suffixes select the configured mode and grammar'
else
  fail imenu-go-routing 'the Go fixture did not activate Go tree-sitter'
fi
send_chord C-c z v
wait_report_count '^PROVIDER file=go native=IMENU-GO-CANDIDATES lsp=none$' 1 || true
if grep -q '^PROVIDER file=go native=IMENU-GO-CANDIDATES lsp=none$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-go-provider 'the fallback uses native Go symbols without LSP'
else
  fail imenu-go-provider 'an LSP workspace or different provider owned Go Imenu'
fi

send_chord C-c z i
wait_report_count '^IMENU-INDEX file=go count=17$' 1 || true
go_index_ok=1
for path in \
  'Function' \
  'Function/Top' \
  'Function/Container' \
  'Method' \
  'Method/(Record).Work' \
  'Struct' \
  'Struct/Record' \
  'Struct/GroupStruct' \
  'Interface' \
  'Interface/Worker' \
  'Interface/GroupStruct' \
  'Type' \
  'Type/Count' \
  'Type/Local' \
  'Alias' \
  'Alias/Alias' \
  'Alias/GroupStruct'; do
  grep -Fqx "IMENU-PATH file=go path=\"$path\"" \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" || go_index_ok=0
done
go_root_order="$(sed -n \
  's/^IMENU-PATH file=go path="\([^/"]*\)"$/\1/p' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | paste -sd, -)"
if [ "$go_index_ok" = 1 ] &&
   [ "$(report_count '^IMENU-PATH file=go ')" -eq 17 ] &&
   [ "$go_root_order" = 'Function,Method,Struct,Interface,Type,Alias' ] &&
   ! grep -Eq '^IMENU-PATH file=go .*(DECOY|Fake|commentFake)' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-go-index 'Go Imenu matches pinned categories, predicates, and names'
else
  fail imenu-go-index 'Go categories, grouped types, receiver names, or exclusions differed'
fi

send_chord C-c z b
send_chord C-c z r
wait_report_count '^STATE file=go line=90 column=0 ' 1 || true
go_origin="$(grep '^STATE file=go line=90 column=0 ' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
go_origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
  <<<"$go_origin")"

if invoke_mx imenu 'Index item:'; then
  go_top="$(lem_capture "$session")"
  if grep -Fq 'Function' <<<"$go_top" &&
     grep -Fq 'Method' <<<"$go_top" &&
     grep -Fq 'Struct' <<<"$go_top" &&
     grep -Fq 'Interface' <<<"$go_top" &&
     grep -Fq 'Type' <<<"$go_top" &&
     grep -Fq 'Alias' <<<"$go_top"; then
    pass imenu-go-presentation 'Go roots expose every pinned category'
  else
    fail imenu-go-presentation 'the Go category prompt differed'
  fi
  tmux_cmd send-keys -t "$session" -l Method
  send_chord Enter
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l '(Record).Work'
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=go line=8 column=0 ' 1 || true
  go_final="$(grep '^STATE file=go line=8 column=0 ' \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  go_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
    <<<"$go_final")"
  if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$go_final" &&
     [ -n "$go_origin_view" ] && [ -n "$go_view" ] &&
     [ "$go_origin_view" != "$go_view" ]; then
    pass imenu-go-jump 'Go Imenu lands on a receiver-qualified method without pulse'
  else
    fail imenu-go-jump "the Go Imenu destination differed: $go_final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=go line=90 column=0 ' 2 || true
  if [ "$(report_count '^STATE file=go line=90 column=0 ')" -ge 2 ]; then
    pass imenu-go-jumplist 'C-o returns from Go Imenu to its exact origin'
  else
    fail imenu-go-jumplist 'Go Imenu did not record one Vi jump'
  fi
else
  fail imenu-go-command 'M-x imenu did not open in the Go fixture'
fi

# gdscript-ts-mode uses one source-ordered sparse tree across ordinary,
# exported, and onready variables plus functions and classes.  Every parent
# retains the package's typed label and dedicated definition self-jump.
send_chord C-c z d
lem_wait_for "$session" 'var top_value' 10 >/dev/null || true
send_chord C-c z m
wait_report_count '^MODE file=gdscript major=GDSCRIPT-MODE tree=gdscript$' 1 || true
if grep -q '^MODE file=gdscript major=GDSCRIPT-MODE tree=gdscript$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-gdscript-routing 'GDScript suffixes select the configured mode and grammar'
else
  fail imenu-gdscript-routing 'the GDScript fixture did not activate tree-sitter'
fi
send_chord C-c z v
wait_report_count '^PROVIDER file=gdscript native=IMENU-GDSCRIPT-CANDIDATES lsp=none$' 1 || true
if grep -q '^PROVIDER file=gdscript native=IMENU-GDSCRIPT-CANDIDATES lsp=none$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-gdscript-provider 'the fallback uses native GDScript symbols without LSP'
else
  fail imenu-gdscript-provider 'an LSP workspace or different provider owned GDScript Imenu'
fi

send_chord C-c z i
wait_report_count '^IMENU-INDEX file=gdscript count=17$' 1 || true
gdscript_index_ok=1
for path in \
  'top_value (var)' \
  'exported_value (e-var)' \
  'ready_value (o-var)' \
  'leaf (def)' \
  'Actor (class)...' \
  'Actor (class).../*class definition*' \
  'Actor (class).../health (var)' \
  'Actor (class).../speed (e-var)' \
  'Actor (class).../child (o-var)' \
  'Actor (class).../tick (def)...' \
  'Actor (class).../tick (def).../*function definition*' \
  'Actor (class).../tick (def).../delta_copy (var)' \
  'Actor (class).../Inner (class)...' \
  'Actor (class).../Inner (class).../*class definition*' \
  'Actor (class).../Inner (class).../enabled (var)' \
  'after_class (var)' \
  'decoy (var)'; do
  grep -Fqx "IMENU-PATH file=gdscript path=\"$path\"" \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" || gdscript_index_ok=0
done
gdscript_root_order="$(sed -n \
  's/^IMENU-PATH file=gdscript path="\([^/"]*\)"$/\1/p' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | paste -sd, -)"
if [ "$gdscript_index_ok" = 1 ] &&
   [ "$(report_count '^IMENU-PATH file=gdscript ')" -eq 17 ] &&
   [ "$gdscript_root_order" = 'top_value (var),exported_value (e-var),ready_value (o-var),leaf (def),Actor (class)...,after_class (var),decoy (var)' ] &&
   ! grep -Eq '^IMENU-PATH file=gdscript .*(fake|hidden|CommentFake)' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-gdscript-index 'GDScript Imenu matches pinned types, nesting, labels, and exclusions'
else
  fail imenu-gdscript-index 'GDScript sparse-tree structure or naming differed'
fi

send_chord C-c z b
send_chord C-c z r
wait_report_count '^STATE file=gdscript line=100 column=0 ' 1 || true
gdscript_origin="$(grep '^STATE file=gdscript line=100 column=0 ' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
gdscript_origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
  <<<"$gdscript_origin")"

if invoke_mx imenu 'Index item:'; then
  gdscript_top="$(lem_capture "$session")"
  if grep -Fq 'top_value.(var)' <<<"$gdscript_top" &&
     grep -Fq 'Actor.(class)...' <<<"$gdscript_top" &&
     grep -Fq 'after_class.(var)' <<<"$gdscript_top"; then
    pass imenu-gdscript-presentation 'GDScript roots expose typed source-order labels'
  else
    fail imenu-gdscript-presentation 'the GDScript root prompt differed'
  fi
  tmux_cmd send-keys -t "$session" -l Actor
  send_chord Enter
  sleep 0.3
  gdscript_actor="$(lem_capture "$session")"
  if grep -Fq '*class.definition*' <<<"$gdscript_actor" &&
     grep -Fq 'tick.(def)...' <<<"$gdscript_actor" &&
     grep -Fq 'Inner.(class)...' <<<"$gdscript_actor"; then
    pass imenu-gdscript-hierarchy 'a class exposes its self jump and nested definitions'
  else
    fail imenu-gdscript-hierarchy 'the GDScript class submenu differed'
  fi
  tmux_cmd send-keys -t "$session" -l tick
  send_chord Enter
  sleep 0.3
  if grep -Fq 'delta_copy.(var)' <<<"$(lem_capture "$session")"; then
    tmux_cmd send-keys -t "$session" -l delta_copy
    send_chord Enter
    sleep 0.5
    send_chord C-c z r
    wait_report_count '^STATE file=gdscript line=24 column=8 ' 1 || true
    gdscript_final="$(grep '^STATE file=gdscript line=24 column=8 ' \
      "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
    gdscript_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
      <<<"$gdscript_final")"
    if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
         <<<"$gdscript_final" &&
       [ -n "$gdscript_origin_view" ] && [ -n "$gdscript_view" ] &&
       [ "$gdscript_origin_view" != "$gdscript_view" ]; then
      pass imenu-gdscript-jump 'GDScript Imenu lands on a nested variable without pulse'
    else
      fail imenu-gdscript-jump "the GDScript Imenu destination differed: $gdscript_final"
    fi
    send_chord C-o
    sleep 0.3
    send_chord C-c z r
    wait_report_count '^STATE file=gdscript line=100 column=0 ' 2 || true
    if [ "$(report_count '^STATE file=gdscript line=100 column=0 ')" -ge 2 ]; then
      pass imenu-gdscript-jumplist 'C-o returns from GDScript Imenu to its exact origin'
    else
      fail imenu-gdscript-jumplist 'GDScript Imenu did not record one Vi jump'
    fi
  else
    fail imenu-gdscript-jump 'the nested function submenu omitted its local variable'
    send_chord C-g
  fi
else
  fail imenu-gdscript-command 'M-x imenu did not open in the GDScript fixture'
fi

# typst-ts-mode exposes two ordered treesit-simple-imenu groups.  Function
# entries are only identifiers in a let-pattern call; calls used as values do
# not qualify.  Heading labels and positions use the complete heading node.
send_chord C-c z t
lem_wait_for "$session" '#let plain' 10 >/dev/null || true
send_chord C-c z m
wait_report_count '^MODE file=typst major=TYPST-MODE tree=typst$' 1 || true
if grep -q '^MODE file=typst major=TYPST-MODE tree=typst$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-typst-routing 'Typst suffixes select the configured mode and grammar'
else
  fail imenu-typst-routing 'the Typst fixture did not activate tree-sitter'
fi
send_chord C-c z v
wait_report_count '^PROVIDER file=typst native=IMENU-TYPST-CANDIDATES lsp=none$' 1 || true
if grep -q '^PROVIDER file=typst native=IMENU-TYPST-CANDIDATES lsp=none$' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-typst-provider 'Typst Imenu uses the configured native provider'
else
  fail imenu-typst-provider 'Typst Imenu selected an unexpected provider'
fi

send_chord C-c z i
wait_report_count '^IMENU-INDEX file=typst count=8$' 1 || true
typst_index_ok=1
for path in \
  'Functions' \
  'Functions/add' \
  'Functions/outer' \
  'Functions/inner' \
  'Headings' \
  'Headings/= Introduction' \
  'Headings/== Details *with markup*' \
  'Headings/=== Final'; do
  grep -Fqx "IMENU-PATH file=typst path=\"$path\"" \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" || typst_index_ok=0
done
typst_root_order="$(sed -n \
  's/^IMENU-PATH file=typst path="\([^/\"]*\)"$/\1/p' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | paste -sd, -)"
if [ "$typst_index_ok" = 1 ] &&
   [ "$(report_count '^IMENU-PATH file=typst ')" -eq 8 ] &&
   [ "$typst_root_order" = 'Functions,Headings' ] &&
   ! grep -Eq '^IMENU-PATH file=typst .*(plain|value|Fake|nope|comment_fake|Comment)' \
     "$LEM_YATH_PROJECT_OUTLINE_REPORT"; then
  pass imenu-typst-index 'Typst Imenu matches pinned groups, predicates, labels, and exclusions'
else
  fail imenu-typst-index 'Typst function-pattern or heading semantics differed'
fi

send_chord C-c z b
send_chord C-c z r
wait_report_count '^STATE file=typst line=80 column=0 ' 1 || true
typst_origin="$(grep '^STATE file=typst line=80 column=0 ' \
  "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
typst_origin_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
  <<<"$typst_origin")"

if invoke_mx imenu 'Index item:'; then
  typst_top="$(lem_capture "$session")"
  if grep -Fq 'Functions' <<<"$typst_top" &&
     grep -Fq 'Headings' <<<"$typst_top"; then
    pass imenu-typst-presentation 'Typst presents the pinned ordered groups'
  else
    fail imenu-typst-presentation 'the Typst root prompt differed'
  fi
  tmux_cmd send-keys -t "$session" -l Functions
  send_chord Enter
  sleep 0.3
  typst_functions="$(lem_capture "$session")"
  if grep -Fq 'add' <<<"$typst_functions" &&
     grep -Fq 'outer' <<<"$typst_functions" &&
     grep -Fq 'inner' <<<"$typst_functions" &&
     ! grep -Fq 'plain' <<<"$typst_functions"; then
    pass imenu-typst-functions 'only function-pattern identifiers enter the submenu'
  else
    fail imenu-typst-functions 'the Typst Functions submenu differed'
  fi
  tmux_cmd send-keys -t "$session" -l inner
  send_chord Enter
  sleep 0.5
  send_chord C-c z r
  wait_report_count '^STATE file=typst line=22 column=6 ' 1 || true
  typst_final="$(grep '^STATE file=typst line=22 column=6 ' \
    "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
  typst_view="$(sed -n 's/^.* view=\([^ ]*\) minor.*$/\1/p' \
    <<<"$typst_final")"
  if grep -q 'pulse=no pulse-stage=none .*pulse-overlays=0' \
       <<<"$typst_final" &&
     [ -n "$typst_origin_view" ] && [ -n "$typst_view" ] &&
     [ "$typst_origin_view" != "$typst_view" ]; then
    pass imenu-typst-jump 'Typst Imenu lands on the nested function name without pulse'
  else
    fail imenu-typst-jump "the Typst Imenu destination differed: $typst_final"
  fi
  send_chord C-o
  sleep 0.3
  send_chord C-c z r
  wait_report_count '^STATE file=typst line=80 column=0 ' 2 || true
  if [ "$(report_count '^STATE file=typst line=80 column=0 ')" -ge 2 ]; then
    pass imenu-typst-jumplist 'C-o returns from Typst Imenu to its exact origin'
  else
    fail imenu-typst-jumplist 'Typst Imenu did not record one Vi jump'
  fi
else
  fail imenu-typst-command 'M-x imenu did not open in the Typst fixture'
fi

send_chord C-c z 2
lem_wait_for "$session" 'Outside heading sentinel' 10 >/dev/null || true
send_chord C-c z r
wait_report_count '^STATE file=outside ' 1 || true
outside="$(grep '^STATE file=outside ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
if grep -q 'minor=no regexp=NIL normal=UNDEFINED-KEY .*insert=LEM-YATH-LLM-SEND visual=LEM-YATH-LLM-SEND' <<<"$outside"; then
  pass outside-scope 'the same major mode outside the declared tree does not steal C-c i'
else
  fail outside-scope 'the directory-local binding escaped its source tree'
fi

send_chord C-c z 3
lem_wait_for "$session" 'Malicious heading sentinel' 10 >/dev/null || true
send_chord C-c z r
wait_report_count '^STATE file=malicious ' 1 || true
malicious="$(grep '^STATE file=malicious ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
if grep -q 'minor=no regexp=NIL .*reader-marker=no$' <<<"$malicious" &&
   [ ! -e "$LEM_YATH_PROJECT_OUTLINE_READER_MARKER" ]; then
  pass reader-safety 'read-time evaluation is rejected before activation or side effects'
else
  fail reader-safety 'directory-local data was executed or accepted unsafely'
fi

send_chord C-c z 4
lem_wait_for "$session" 'empty-outline-file' 10 >/dev/null || true
send_chord C-c z r
wait_report_count '^STATE file=empty ' 1 || true
empty="$(grep '^STATE file=empty ' "$LEM_YATH_PROJECT_OUTLINE_REPORT" | tail -1)"
send_chord C-c i
if grep -q 'minor=yes regexp=";;;" normal=LEM-YATH-CONSULT-OUTLINE' <<<"$empty" &&
   lem_wait_for "$session" 'No headings' 10 >/dev/null &&
   ! grep -q 'Go to heading:' <<<"$(lem_capture "$session")"; then
  pass empty 'a declared file with no headings fails before opening a prompt'
else
  fail empty 'the empty outline path did not fail closed'
fi

if [ "$failed" = 0 ]; then
  printf 'All project outline checks passed.\n'
else
  exit 1
fi
