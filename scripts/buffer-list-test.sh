#!/usr/bin/env bash
# Real-ncurses coverage for the configured Ibuffer saved filter groups.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-buffer-list-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-buffer-list.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_BUFFER_LIST_REPORT="$root/report"
export LEM_YATH_BUFFER_LIST_TARGET="$root/buffer-list-zz-target.txt"
export LEM_YATH_BUFFER_LIST_SAVE_TARGET="$root/buffer-list-save-target.txt"
export LEM_YATH_BUFFER_LIST_SORT_A="$root/a-file.txt"
export LEM_YATH_BUFFER_LIST_SORT_B="$root/b-file.txt"
export LEM_YATH_BUFFER_LIST_SORT_C="$root/c-file.txt"
export LEM_YATH_BUFFER_LIST_MARK_UNSAVED_HIT="$root/buffer-list-mark-unsaved-hit.txt"
export LEM_YATH_BUFFER_LIST_MARK_UNSAVED_MISS="$root/buffer-list-mark-unsaved-miss.txt"
export LEM_YATH_BUFFER_LIST_MARK_DISSOCIATED_HIT="$root/buffer-list-mark-dissociated-hit.txt"
export LEM_YATH_BUFFER_LIST_MARK_DISSOCIATED_MISS="$root/buffer-list-mark-dissociated-miss.txt"
export LEM_YATH_BUFFER_LIST_MARK_COMPRESSED_HIT="$root/buffer-list-mark-compressed-hit.GZ"
export LEM_YATH_BUFFER_LIST_MARK_COMPRESSED_MISS="$root/buffer-list-mark-compressed-miss.txt"
export LEM_YATH_BUFFER_LIST_REVERT_CLEAN="$root/buffer-list-mark-revert-clean.txt"
export LEM_YATH_BUFFER_LIST_REVERT_DIRTY="$root/buffer-list-mark-revert-dirty.txt"
export LEM_YATH_BUFFER_LIST_REVERT_MISSING="$root/buffer-list-mark-revert-missing.txt"
export LEM_TUI_WIDTH=180
export LEM_TUI_HEIGHT=60
mkdir -p "$HOME" "$XDG_CACHE_HOME"

source_file="$root/buffer-list-source.txt"
printf 'BUFFER LIST SOURCE\n' >"$source_file"
printf 'BUFFER LIST SELECTED TARGET\n' >"$LEM_YATH_BUFFER_LIST_TARGET"
printf 'SAVE ORIGINAL\n' >"$LEM_YATH_BUFFER_LIST_SAVE_TARGET"
: >"$LEM_YATH_BUFFER_LIST_SORT_A"
: >"$LEM_YATH_BUFFER_LIST_SORT_B"
: >"$LEM_YATH_BUFFER_LIST_SORT_C"
printf 'UNSAVED HIT\n' >"$LEM_YATH_BUFFER_LIST_MARK_UNSAVED_HIT"
printf 'UNSAVED MISS\n' >"$LEM_YATH_BUFFER_LIST_MARK_UNSAVED_MISS"
printf 'DISSOCIATED MISS\n' >"$LEM_YATH_BUFFER_LIST_MARK_DISSOCIATED_MISS"
printf 'COMPRESSED HIT\n' >"$LEM_YATH_BUFFER_LIST_MARK_COMPRESSED_HIT"
printf 'COMPRESSED MISS\n' >"$LEM_YATH_BUFFER_LIST_MARK_COMPRESSED_MISS"
printf 'CLEAN DISK\n' >"$LEM_YATH_BUFFER_LIST_REVERT_CLEAN"
printf 'DIRTY DISK\n' >"$LEM_YATH_BUFFER_LIST_REVERT_DIRTY"
: >"$LEM_YATH_BUFFER_LIST_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-buffer-list-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-28s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-28s %s\n' "$1" "$2"
  tail -20 "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true
  lem_capture "$session" 2>/dev/null || true
}

report_count() {
  grep -c '^STATE ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true
}

report_state() {
  local before attempts=0
  before=$(report_count)
  lem_keys "$session" F5
  while ((attempts < 40)); do
    if (( $(report_count) > before )); then return 0; fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

latest_state() {
  grep '^STATE ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
}

report_ui() {
  local before attempts=0
  before=$(grep -c '^UI ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F8
  while ((attempts < 40)); do
    if (( $(grep -c '^UI ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^UI ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_nav() {
  local before attempts=0
  before=$(grep -c '^NAV ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F11
  while ((attempts < 40)); do
    if (( $(grep -c '^NAV ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^NAV ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_filter() {
  local before attempts=0
  before=$(grep -c '^FILTER ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F12
  while ((attempts < 40)); do
    if (( $(grep -c '^FILTER ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^FILTER ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_copy() {
  local before attempts=0
  before=$(grep -c '^COPY ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F9
  while ((attempts < 40)); do
    if (( $(grep -c '^COPY ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^COPY ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_window() {
  local before attempts=0
  before=$(grep -c '^WINDOW ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F4
  while ((attempts < 40)); do
    if (( $(grep -c '^WINDOW ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^WINDOW ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_operations() {
  local before attempts=0
  before=$(grep -c '^OPS ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F3
  while ((attempts < 40)); do
    if (( $(grep -c '^OPS ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^OPS ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_picker_bindings() {
  local before attempts=0
  before=$(grep -c '^PICKER-BINDINGS ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F2
  while ((attempts < 40)); do
    if (( $(grep -c '^PICKER-BINDINGS ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^PICKER-BINDINGS ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_revert() {
  local before attempts=0
  before=$(grep -c '^REVERT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F1
  while ((attempts < 40)); do
    if (( $(grep -c '^REVERT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^REVERT ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_diff() {
  local before attempts=0
  before=$(grep -c '^DIFF ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F10
  while ((attempts < 40)); do
    if (( $(grep -c '^DIFF ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^DIFF ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_occur() {
  local before attempts=0
  before=$(grep -c '^OCCUR ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F8
  while ((attempts < 40)); do
    if (( $(grep -c '^OCCUR ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^OCCUR ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_occur_global() {
  local before attempts=0
  before=$(grep -c '^OCCUR ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F3
  while ((attempts < 40)); do
    if (( $(grep -c '^OCCUR ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^OCCUR ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_occur_bounds() {
  local before attempts=0
  before=$(grep -c '^OCCUR-BOUNDS ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F4
  while ((attempts < 40)); do
    if (( $(grep -c '^OCCUR-BOUNDS ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^OCCUR-BOUNDS ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_occur_source_zero() {
  local before attempts=0
  before=$(grep -c '^OCCUR-SOURCE-ZERO ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F9
  while ((attempts < 40)); do
    if (( $(grep -c '^OCCUR-SOURCE-ZERO ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^OCCUR-SOURCE-ZERO ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_multi_isearch() {
  local before attempts=0
  before=$(grep -c '^M-ISEARCH ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F5
  while ((attempts < 40)); do
    if (( $(grep -c '^M-ISEARCH ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^M-ISEARCH ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_multi_isearch_lifecycle() {
  local before attempts=0
  before=$(grep -c '^M-ISEARCH-LIFECYCLE ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F12
  while ((attempts < 40)); do
    if (( $(grep -c '^M-ISEARCH-LIFECYCLE ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^M-ISEARCH-LIFECYCLE ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_query_state() {
  local before attempts=0
  before=$(grep -c '^QUERY ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F5
  while ((attempts < 40)); do
    if (( $(grep -c '^QUERY ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^QUERY ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_current() {
  local before attempts=0
  before=$(grep -c '^CURRENT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F6
  while ((attempts < 40)); do
    if (( $(grep -c '^CURRENT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^CURRENT ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_occur_bindings() {
  local before attempts=0
  before=$(grep -c '^OCCUR-BINDINGS ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F1
  while ((attempts < 40)); do
    if (( $(grep -c '^OCCUR-BINDINGS ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^OCCUR-BINDINGS ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

visit_occur_source() {
  local before attempts=0
  before=$(grep -c '^OCCUR-VISIT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" Enter
  while ((attempts < 40)); do
    if (( $(grep -c '^OCCUR-VISIT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^OCCUR-VISIT ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

select_occur_buffer() {
  # O leaves the floating picker selected over its ordinary source window.
  # Close it, then let the fixture select the existing displayed result.  A
  # fixed M-o count is not deterministic after earlier source previews have
  # left more than two ordinary windows in the layout.
  lem_keys "$session" q F2
}

check_star_mark() {
  local label=$1 query=$2 suffix=$3 expected=$4 nav
  lem_keys "$session" s / U
  lem_keys "$session" s n
  tmux_cmd send-keys -t "$session" -l "$query"
  lem_keys "$session" Enter '*' "$suffix"
  nav=$(report_nav || true)
  if [[ "$nav" == *"marks=$expected:>" ]]; then
    pass "$label" "* $suffix marked only the matching visible buffer"
  else
    fail "$label" "* $suffix produced unexpected marks: $nav"
  fi
}

prepare_view_marks() {
  local name
  lem_keys "$session" C-x C-b
  lem_keys "$session" s n
  tmux_cmd send-keys -t "$session" -l 'buffer-list-view-'
  lem_keys "$session" Enter m m d
  view_nav=$(report_nav || true)
  view_deleted=''
  for name in buffer-list-view-alpha buffer-list-view-beta buffer-list-view-delete; do
    if [[ "$view_nav" == *"$name:D"* ]]; then
      view_deleted=$name
    fi
  done
}

fixture="$(lem-yath_lisp_string "$here/scripts/buffer-list-fixture.lisp")"
lem_start "$session" "$source_file" --eval "(load #P$fixture)"

if lem_wait_for "$session" 'BUFFER LIST SOURCE' 60 >/dev/null &&
   grep -q '^READY$' "$LEM_YATH_BUFFER_LIST_REPORT"; then
  pass boot "configured Lem loaded the grouped-buffer fixture"
else
  fail boot "the fixture did not become ready"
fi

expected_classify='classify=org,tramp,emacs,ediff,dired,terminal,help,org,Default'
expected_order='order=org,tramp,emacs,ediff,dired,terminal,help,Default'
if report_state &&
   [[ $(latest_state) == *"$expected_classify"* ]] &&
   [[ $(latest_state) == *"$expected_order"* ]]; then
  pass group-semantics "all seven groups use configured first-match order"
else
  fail group-semantics "classification or group order diverged"
fi

if [[ $(latest_state) == *'subset=org,Default'* ]] &&
   [[ $(latest_state) == *'binding=LEM-YATH-LIST-BUFFERS definitions=7'* ]]; then
  pass hidden-empty-binding "empty groups are omitted and C-x C-b owns the grouped command"
else
  fail hidden-empty-binding "empty-group or binding behavior diverged"
fi

if grep -Fq 'COLUMNS status=[*% ] name=[buffer-list-nam...] name-width=18 size=[        1] mode=[Long Fixture ...] mode-width=16 file=[] wide=[12345678901234....] wide-width=18' \
     "$LEM_YATH_BUFFER_LIST_REPORT"; then
  pass stock-columns "status, fixed widths, right alignment, and cell-safe elision match Ibuffer"
else
  fail stock-columns "the stock Ibuffer column contract diverged"
fi

lem_keys "$session" C-x C-b
if lem_wait_for "$session" 'Buffer[[:space:]]+Size[[:space:]]+Mode[[:space:]]+File' 15 >/dev/null; then
  screen=$(lem_capture "$session")
  missing=0
  for group in org tramp emacs ediff dired terminal help Default; do
    if ! grep -Fq "[ ${group} ]" <<<"$screen"; then
      missing=1
    fi
  done
  if ((missing == 0)) &&
     grep -Eq 'buffer-list-zz-\.\.\.[[:space:]]+[0-9]+[[:space:]]+Fundamental' <<<"$screen" &&
     grep -Eq 'buffer-list-nam\.\.\.[[:space:]]+1[[:space:]]+Long Fixture \.\.\.' <<<"$screen" &&
     grep -Fq 'ctl\nname' <<<"$screen" &&
     grep -Fq '*Org Src direct...' <<<"$screen"; then
    pass grouped-ui "the chooser displays grouped stock Ibuffer columns and escaped rows"
  else
    fail grouped-ui "the grouped chooser omitted headings, columns, or fixture rows"
  fi
else
  fail grouped-ui "C-x C-b did not open the grouped multi-column chooser"
fi

# Heading rows are presentation/control rows, never buffer-operation targets.
lem_keys "$session" x
lem_keys "$session" S
lem_keys "$session" U
sleep 0.3
screen=$(lem_capture "$session")
if grep -Fq '[ org ]' <<<"$screen" &&
   grep -Fq '*Org Src buffer...' <<<"$screen" &&
   ! grep -Eq '[>D][[:space:]]+\[ org \]' <<<"$screen"; then
  pass heading-safety "kill, save, and mark cannot target a group heading"
else
  fail heading-safety "a buffer action mutated or marked a group heading"
fi

# The first row is the first nonempty group heading.  Return follows Ibuffer:
# hide its rows, retain an ellipsis heading, and expand it again in place.
lem_keys "$session" Enter
sleep 0.4
screen=$(lem_capture "$session")
if grep -Fq '[ org ... ]' <<<"$screen" &&
   ! grep -Fq '*Org Src buffer...' <<<"$screen" &&
   grep -Fq '[ tramp ]' <<<"$screen"; then
  pass grouped-collapse "Return collapsed only the focused Ibuffer group"
else
  fail grouped-collapse "the focused heading did not collapse safely"
fi

lem_keys "$session" Enter
sleep 0.4
screen=$(lem_capture "$session")
if grep -Fq '[ org ]' <<<"$screen" &&
   grep -Fq '*Org Src buffer...' <<<"$screen" &&
   ! grep -Fq '[ org ... ]' <<<"$screen"; then
  pass grouped-expand "Return restored the collapsed group in place"
else
  fail grouped-expand "the focused heading did not expand safely"
fi

lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'zz-target'
sleep 0.6
screen=$(lem_capture "$session")
if grep -Fq 'buffer-list-zz-...' <<<"$screen" &&
   [[ $(grep -c 'buffer-list-source\.txt' <<<"$screen") -eq 1 ]] &&
   ! grep -Eq '\[ (org|Default) (\.\.\. )?\]' <<<"$screen"; then
  pass grouped-filter "live filtering presents matching buffers without heading traps"
else
  fail grouped-filter "filtering retained headings or unrelated rows"
fi

# Accept the name filter, then use modal Return to visit the focused row.
lem_keys "$session" Enter
lem_keys "$session" Enter
if lem_wait_for "$session" 'BUFFER LIST SELECTED TARGET' 15 >/dev/null; then
  before=$(grep -c '^CURRENT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F6
  attempts=0
  while ((attempts < 40)) &&
        (( $(grep -c '^CURRENT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) <= before )); do
    sleep 0.25
    attempts=$((attempts + 1))
  done
  if grep -q '^CURRENT name=buffer-list-zz-target\.txt file=buffer-list-zz-target\.txt group=Default text=BUFFER LIST SELECTED TARGET\\n$' "$LEM_YATH_BUFFER_LIST_REPORT"; then
    pass grouped-select "Return opens the exact focused buffer"
  else
    fail grouped-select "the selected buffer identity was not preserved"
  fi
else
  fail grouped-select "Return did not open the filtered target"
fi

lem_keys "$session" F10
if report_state &&
   [[ $(latest_state) == *"$expected_classify"* ]] &&
   [[ $(latest_state) == *"$expected_order"* ]] &&
   [[ $(latest_state) == *'binding=LEM-YATH-LIST-BUFFERS definitions=7'* ]]; then
  pass reload "source reload preserves definitions, grouping, and binding"
else
  fail reload "reload changed the effective grouped-buffer contract"
fi

lem_keys "$session" C-x C-b
if lem_wait_for "$session" 'Buffer[[:space:]]+Size[[:space:]]+Mode[[:space:]]+File' 15 >/dev/null; then
  lem_keys "$session" o a
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=alphabetic reverse=no format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-alpha,buffer-list-sort-middle,buffer-list-sort-zeta' ]]; then
    pass sort-alphabetic "o a sorts names inside each configured group"
  else
    fail sort-alphabetic "unexpected alphabetic state: $ui"
  fi

  lem_keys "$session" o i
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=alphabetic reverse=yes format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-zeta,buffer-list-sort-middle,buffer-list-sort-alpha' ]]; then
    pass sort-invert "o i reverses the current Ibuffer ordering"
  else
    fail sort-invert "unexpected reversed state: $ui"
  fi

  lem_keys "$session" o i
  lem_keys "$session" o s
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=size reverse=no format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-zeta,buffer-list-sort-middle,buffer-list-sort-alpha' ]]; then
    pass sort-size "o s sorts by live buffer size"
  else
    fail sort-size "unexpected size state: $ui"
  fi

  lem_keys "$session" o f
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=filename reverse=no format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-middle,buffer-list-sort-zeta,buffer-list-sort-alpha' ]]; then
    pass sort-filename "o f sorts by visiting filename"
  else
    fail sort-filename "unexpected filename state: $ui"
  fi

  lem_keys "$session" o m
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=major-mode reverse=no format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-middle,buffer-list-sort-zeta,buffer-list-sort-alpha' ]]; then
    pass sort-major-mode "o m sorts by major-mode symbol"
  else
    fail sort-major-mode "unexpected major-mode state: $ui"
  fi

  lem_keys "$session" ,
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=mode-name reverse=no format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-zeta,buffer-list-sort-alpha,buffer-list-sort-middle' ]]; then
    pass sort-cycle "comma advances through pinned Ibuffer sort modes"
  else
    fail sort-cycle "unexpected cycled state: $ui"
  fi

  lem_keys "$session" o v
  ui=$(report_ui || true)
  if [[ "$ui" == UI\ sort=recency\ reverse=no\ format=0* ]]; then
    pass sort-recency "o v restores the chooser's captured recency order"
  else
    fail sort-recency "unexpected recency state: $ui"
  fi

  lem_keys "$session" '`'
  ui=$(report_ui || true)
  screen=$(lem_capture "$session")
  if [[ "$ui" == UI\ sort=recency\ reverse=no\ format=1\ columns=Buffer,File* ]] &&
     grep -Eq 'Buffer[[:space:]]+File' <<<"$screen" &&
     ! grep -Eq 'Buffer[[:space:]]+Size[[:space:]]+Mode[[:space:]]+File' <<<"$screen"; then
    pass alternate-format "backtick switches to Ibuffer's compact name/file view"
  else
    fail alternate-format "compact format did not render: $ui"
  fi

  lem_keys "$session" '`'
  ui=$(report_ui || true)
  screen=$(lem_capture "$session")
  if [[ "$ui" == UI\ sort=recency\ reverse=no\ format=0* ]] &&
     grep -Eq 'Buffer[[:space:]]+Size[[:space:]]+Mode[[:space:]]+File' <<<"$screen"; then
    pass primary-format "a second backtick restores the stock detailed view"
  else
    fail primary-format "primary format did not return: $ui"
  fi

  lem_keys "$session" Tab
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:tramp marks=' ]]; then
    pass group-next-tab "Tab moved to the next configured filter group"
  else
    fail group-next-tab "unexpected Tab destination: $nav"
  fi

  lem_keys "$session" BTab
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:org marks=' ]]; then
    pass group-previous-tab "backtab returned to the previous filter group"
  else
    fail group-previous-tab "unexpected backtab destination: $nav"
  fi

  lem_keys "$session" ']' ']'
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:tramp marks=' ]]; then
    pass group-next-bracket "]] moved to the next filter group"
  else
    fail group-next-bracket "unexpected ]] destination: $nav"
  fi

  lem_keys "$session" '[' '['
  lem_keys "$session" C-j
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:tramp marks=' ]]; then
    pass group-next-control "C-j moved to the next filter group"
  else
    fail group-next-control "unexpected C-j destination: $nav"
  fi

  lem_keys "$session" C-k
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:org marks=' ]]; then
    pass group-previous-control "C-k returned to the previous filter group"
  else
    fail group-previous-control "unexpected C-k destination: $nav"
  fi

  lem_keys "$session" Enter M-j
  if lem_wait_for "$session" 'Jump to filter group:' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l 'help'
    lem_keys "$session" Enter
    nav=$(report_nav || true)
    screen=$(lem_capture "$session")
    if [[ "$nav" == 'NAV focus=heading:help marks=' ]] &&
       grep -Fq '[ org ... ]' <<<"$screen"; then
      pass group-jump "M-j completed over visible headings without changing collapsed state"
    else
      fail group-jump "M-j changed group state or focused the wrong heading: $nav"
    fi
  else
    fail group-jump "M-j did not open exact filter-group completion"
  fi

  lem_keys "$session" M-j
  if lem_wait_for "$session" 'Jump to filter group:' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l 'org'
    lem_keys "$session" Enter
    nav=$(report_nav || true)
    if [[ "$nav" == 'NAV focus=heading:org marks=' ]]; then
      pass group-jump-return "M-j returned to the collapsed org heading"
    else
      fail group-jump-return "M-j returned to an unexpected row: $nav"
    fi
  else
    fail group-jump-return "the second M-j prompt did not open"
  fi
  lem_keys "$session" Enter

  lem_keys "$session" g j
  nav=$(report_nav || true)
  if [[ "$nav" == NAV\ focus=buffer:\*Org\ Src* ]]; then
    pass modal-row-motion "gj moved one row without invoking global screen motion"
  else
    fail modal-row-motion "unexpected gj destination: $nav"
  fi

  lem_keys "$session" g k
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:org marks=' ]]; then
    pass modal-row-return "gk returned to the group heading"
  else
    fail modal-row-return "unexpected gk destination: $nav"
  fi

  lem_keys "$session" Enter J
  if lem_wait_for "$session" 'Jump to buffer:' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l '*Org Src buffer-list*'
    lem_keys "$session" Enter
    nav=$(report_nav || true)
    if [[ "$nav" == 'NAV focus=buffer:*Org Src buffer-list* marks=' ]]; then
      pass jump-collapsed-group "J completed over the snapshot, expanded org, and focused the exact buffer"
    else
      fail jump-collapsed-group "J did not reveal the collapsed target: $nav"
    fi
  else
    fail jump-prompt "J did not open the pinned buffer completion prompt"
  fi

  lem_keys "$session" s n
  tmux_cmd send-keys -t "$session" -l 'sort-'
  lem_keys "$session" Enter J
  if lem_wait_for "$session" 'Jump to buffer:' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l '*Org Src buffer-list*'
    lem_keys "$session" Enter
    if lem_wait_for "$session" 'No buffer with name \*Org Src buffer-list\*' 10 >/dev/null; then
      filter=$(report_filter || true)
      if [[ "$filter" == FILTER\ stack=name=sort-* ]] &&
         [[ "$filter" != *'Org Src buffer-list'* ]]; then
        pass jump-filter-boundary "J offered the snapshot target but did not bypass the active Ibuffer filter"
      else
        fail jump-filter-boundary "J disturbed the active filter after refusing its target: $filter"
      fi
    else
      fail jump-filter-boundary "J bypassed the active Ibuffer filter or did not report the refusal"
    fi
  else
    fail jump-filter-prompt "J did not prompt while a filter was active"
  fi

  lem_keys "$session" s / M-g
  if lem_wait_for "$session" 'Jump to buffer:' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l 'buffer-list-zz-target.txt'
    lem_keys "$session" Enter
    nav=$(report_nav || true)
    if [[ "$nav" == 'NAV focus=buffer:buffer-list-zz-target.txt marks=' ]]; then
      pass jump-meta-binding "M-g used the same exact buffer-jump workflow"
    else
      fail jump-meta-binding "M-g selected an unexpected row: $nav"
    fi
  else
    fail jump-meta-binding "M-g did not open the buffer-jump prompt"
  fi
else
  fail sorting-ui "could not reopen the grouped chooser for sorting"
fi
lem_keys "$session" q

lem_keys "$session" C-x C-b
lem_keys "$session" s i
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=modified* ]] &&
   [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
   [[ "$filter" == *'buffer-list-save-target.txt'* ]] &&
   [[ "$filter" != *'buffer-list-zz-target.txt'* ]]; then
  pass filter-modified "s i retained only modified buffers"
else
  fail filter-modified "unexpected modified filter state: $filter"
fi

lem_keys "$session" s v
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=visiting-file,+modified* ]] &&
   [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
   [[ "$filter" != *'buffer-list-name-that-is-long'* ]]; then
  pass filter-visiting-file "s v composed visiting-file with the modified filter"
else
  fail filter-visiting-file "unexpected visiting-file filter state: $filter"
fi

lem_keys "$session" s '!'
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=not\(visiting-file\),+modified* ]] &&
   [[ "$filter" == *'buffer-list-name-that-is-long'* ]] &&
   [[ "$filter" != *'buffer-list-sort-zeta'* ]]; then
  pass filter-negate "s ! negated only the top filter"
else
  fail filter-negate "unexpected negated filter state: $filter"
fi

lem_keys "$session" s '!'
lem_keys "$session" s p
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=modified* ]] &&
   [[ "$filter" == *'buffer-list-name-that-is-long'* ]] &&
   [[ "$filter" != *'buffer-list-zz-target.txt'* ]]; then
  pass filter-pop "s p removed only the top filter"
else
  fail filter-pop "unexpected popped filter state: $filter"
fi

lem_keys "$session" s /
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=\ visible=* ]] &&
   [[ "$filter" == *'buffer-list-zz-target.txt'* ]]; then
  pass filter-disable "s / disabled the complete filter stack"
else
  fail filter-disable "unexpected disabled filter state: $filter"
fi

lem_keys "$session" s Enter
if lem_wait_for "$session" 'Filter by major mode' 10 >/dev/null; then
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l \
    'LEM-YATH::BUFFER-LIST-TEST-DERIVED-CHILD-MODE,LEM-YATH::BUFFER-LIST-TEST-DERIVED-PARENT-MODE'
  sleep 0.4
  lem_keys "$session" Enter
  filter=$(report_filter || true)
  if [[ "$filter" == FILTER\ stack=mode-is=LEM-YATH::BUFFER-LIST-TEST-DERIVED-CHILD-MODE,LEM-YATH::BUFFER-LIST-TEST-DERIVED-PARENT-MODE* ]] &&
     [[ "$filter" == *'buffer-list-op-alpha'* ]] &&
     [[ "$filter" == *'buffer-list-op-beta'* ]]; then
    pass filter-exact-mode "s RET accepted multiple exact registered major modes"
  else
    fail filter-exact-mode "unexpected exact-mode filter state: $filter"
  fi
else
  fail filter-exact-mode "s RET did not open the major-mode completion prompt"
fi
lem_keys "$session" s p

lem_keys "$session" J
if lem_wait_for "$session" 'Jump to buffer:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'buffer-list-op-alpha'
  sleep 0.3
  lem_keys "$session" Enter
  sleep 0.3
  lem_keys "$session" s Enter
  if lem_wait_for "$session" 'Filter by major mode.*default LEM-YATH::BUFFER-LIST-TEST-DERIVED-CHILD-MODE' 10 >/dev/null; then
    lem_keys "$session" Enter
    filter=$(report_filter || true)
    if [[ "$filter" == FILTER\ stack=mode-is=LEM-YATH::BUFFER-LIST-TEST-DERIVED-CHILD-MODE* ]] &&
       [[ "$filter" == *'buffer-list-op-alpha'* ]] &&
       [[ "$filter" != *'buffer-list-op-beta'* ]]; then
      pass filter-mode-default "empty s RET accepted the focused buffer's displayed mode default"
    else
      fail filter-mode-default "unexpected default-mode filter state: $filter"
    fi
  else
    fail filter-mode-default "s RET did not display the focused buffer's mode default"
  fi
else
  fail filter-mode-default "could not focus the exact-mode default fixture"
fi
lem_keys "$session" s p

lem_keys "$session" s M
if lem_wait_for "$session" 'Filter by derived mode' 10 >/dev/null; then
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l \
    'LEM-YATH::BUFFER-LIST-TEST-DERIVED-PARENT-MODE'
  sleep 0.4
  lem_keys "$session" Enter
  filter=$(report_filter || true)
  if [[ "$filter" == FILTER\ stack=derived-mode=LEM-YATH::BUFFER-LIST-TEST-DERIVED-PARENT-MODE* ]] &&
     [[ "$filter" == *'buffer-list-op-alpha'* ]] &&
     [[ "$filter" == *'buffer-list-op-beta'* ]]; then
    pass filter-derived-mode "s M matched both a parent mode and its derived child"
  else
    fail filter-derived-mode "unexpected derived-mode filter state: $filter"
  fi
else
  fail filter-derived-mode "s M did not open the derived-mode completion prompt"
fi
lem_keys "$session" s p

lem_keys "$session" s '*'
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=starred-name* ]] &&
   [[ "$filter" == *'*buffer-list-mark-special-hit*'* ]] &&
   [[ "$filter" != *'buffer-list-mark-special-miss'* ]]; then
  pass filter-starred-name "s * retained only GNU-style starred buffer names"
else
  fail filter-starred-name "unexpected starred-name filter state: $filter"
fi
lem_keys "$session" s p

lem_keys "$session" s '<'
if lem_wait_for "$session" 'Filter by size less than:' 10 >/dev/null; then
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l '15'
  sleep 0.2
  lem_keys "$session" Enter
  filter=$(report_filter || true)
  if [[ "$filter" == FILTER\ stack=size\<15* ]] &&
     [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
     [[ "$filter" != *'buffer-list-sort-middle'* ]] &&
     [[ "$filter" != *'buffer-list-sort-alpha'* ]]; then
    pass filter-size-lt "s < used GNU Ibuffer's strict character-size boundary"
  else
    fail filter-size-lt "unexpected size-lt filter state: $filter"
  fi
else
  fail filter-size-lt "s < did not prompt for a size"
fi
lem_keys "$session" s p

lem_keys "$session" s '>'
if lem_wait_for "$session" 'Filter by size greater than:' 10 >/dev/null; then
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l '25'
  sleep 0.2
  lem_keys "$session" Enter
  filter=$(report_filter || true)
  if [[ "$filter" == FILTER\ stack=size\>25* ]] &&
     [[ "$filter" == *'buffer-list-sort-alpha'* ]] &&
     [[ "$filter" != *'buffer-list-sort-middle'* ]] &&
     [[ "$filter" != *'buffer-list-sort-zeta'* ]]; then
    pass filter-size-gt "s > used GNU Ibuffer's strict character-size boundary"
  else
    fail filter-size-gt "unexpected size-gt filter state: $filter"
  fi
else
  fail filter-size-gt "s > did not prompt for a size"
fi
lem_keys "$session" s p

lem_keys "$session" s c
if lem_wait_for "$session" 'Filter by content \(regexp\):' 10 >/dev/null; then
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l 'FILTER NEEDLE'
  sleep 0.2
  lem_keys "$session" Enter
  filter=$(report_filter || true)
  if [[ "$filter" == FILTER\ stack=content=FILTER\ NEEDLE* ]] &&
     [[ "$filter" == *'buffer-list-op-alpha'* ]] &&
     [[ "$filter" != *'buffer-list-op-beta'* ]]; then
    pass filter-content "s c matched buffer content case-insensitively"
  else
    fail filter-content "unexpected content filter state: $filter"
  fi
else
  fail filter-content "s c did not prompt for a content regexp"
fi
lem_keys "$session" s p

lem_keys "$session" s c
if lem_wait_for "$session" 'Filter by content \(regexp\):' 10 >/dev/null; then
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l '['
  sleep 0.2
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'Invalid Ibuffer content regexp' 10 >/dev/null; then
    filter=$(report_filter || true)
    if [[ "$filter" == FILTER\ stack=\ visible=* ]] &&
       [[ "$filter" == *'buffer-list-op-alpha'* ]]; then
      pass filter-content-invalid "an invalid content regexp left the filter stack unchanged"
    else
      fail filter-content-invalid "invalid content regexp changed state: $filter"
    fi
  else
    fail filter-content-invalid "invalid content regexp was not rejected"
  fi
else
  fail filter-content-invalid "s c did not reopen the content regexp prompt"
fi

lem_keys "$session" s m
tmux_cmd send-keys -t "$session" -l 'buffer-list-test-sort-m-mode'
sleep 0.3
lem_keys "$session" Enter
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=mode=buffer-list-test-sort-m-mode* ]] &&
   [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
   [[ "$filter" != *'buffer-list-sort-alpha'* ]]; then
  pass filter-mode "s m committed a case-insensitive used-mode filter"
else
  fail filter-mode "unexpected mode filter state: $filter"
fi
lem_keys "$session" s p

lem_keys "$session" s f
tmux_cmd send-keys -t "$session" -l 'b-file\.txt$'
sleep 0.3
lem_keys "$session" Enter
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=filename=* ]] &&
   [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
   [[ "$filter" != *'buffer-list-sort-alpha'* ]]; then
  pass filter-filename "s f committed a full-filename regexp filter"
else
  fail filter-filename "unexpected filename filter state: $filter"
fi
lem_keys "$session" s p

lem_keys "$session" s b
tmux_cmd send-keys -t "$session" -l 'b-file.txt'
sleep 0.3
lem_keys "$session" Enter
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=basename=b-file.txt* ]] &&
   [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
   [[ "$filter" != *'buffer-list-sort-alpha'* ]]; then
  pass filter-basename "s b committed a basename regexp filter"
else
  fail filter-basename "unexpected basename filter state: $filter"
fi
lem_keys "$session" s p

lem_keys "$session" s .
tmux_cmd send-keys -t "$session" -l 'txt'
sleep 0.3
lem_keys "$session" Enter
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=extension=txt* ]] &&
   [[ "$filter" == *'buffer-list-zz-target.txt'* ]] &&
   [[ "$filter" != *'buffer-list-name-that-is-long'* ]]; then
  pass filter-extension "s . committed an extension regexp filter"
else
  fail filter-extension "unexpected extension filter state: $filter"
fi
lem_keys "$session" s /
lem_keys "$session" q

lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'sort-'
if lem_wait_for "$session" 'sort-[[:space:]]' 15 >/dev/null; then
  lem_keys "$session" Enter
  filter=$(report_filter || true)
  if [[ "$filter" == FILTER\ stack=name=sort-* ]]; then
    pass filter-name-stack "accepted s n became a poppable name filter"
  else
    fail filter-name-stack "accepted s n was not on the filter stack: $filter"
  fi
  lem_keys "$session" m
  lem_keys "$session" d
  nav=$(report_nav || true)
  screen=$(lem_capture "$session")
  if [[ "$nav" == *'buffer-list-sort-zeta:>,buffer-list-sort-middle:D'* ]] &&
     grep -Eq '>[[:space:]]+.*buffer-list-sor' <<<"$screen" &&
     grep -Eq 'D[[:space:]]+.*buffer-list-sor' <<<"$screen"; then
    pass modal-marks "m and d rendered distinct Evil-Collection > and D marks"
  else
    fail modal-marks "ordinary/deletion marks diverged: $nav"
  fi

  lem_keys "$session" U
  nav=$(report_nav || true)
  if [[ "$nav" == *'marks=' ]]; then
    pass modal-unmark-all "U cleared ordinary and deletion marks"
  else
    fail modal-unmark-all "U retained marks: $nav"
  fi

  lem_keys "$session" g k
  lem_keys "$session" g k
  lem_keys "$session" m
  lem_keys "$session" g k
  lem_keys "$session" u
  nav=$(report_nav || true)
  if [[ "$nav" == *'marks=' ]]; then
    pass modal-unmark-forward "u cleared the current ordinary mark and advanced"
  else
    fail modal-unmark-forward "u retained the current ordinary mark: $nav"
  fi

  lem_keys "$session" t
  nav=$(report_nav || true)
  if [[ "$nav" == *'buffer-list-sort-zeta:>,buffer-list-sort-middle:>,buffer-list-sort-alpha:>'* ]]; then
    pass modal-toggle-marks "t marked every visible buffer"
  else
    fail modal-toggle-marks "t did not toggle all visible rows: $nav"
  fi

  lem_keys "$session" '~'
  nav=$(report_nav || true)
  if [[ "$nav" == *'marks=' ]]; then
    pass modal-toggle-clear "~ inverted the marked set back to empty"
  else
    fail modal-toggle-clear "~ retained marks: $nav"
  fi

  lem_keys "$session" s n
  tmux_cmd send-keys -t "$session" -l 'sort-'
  lem_wait_for "$session" 'sort-[[:space:]]' 15 >/dev/null ||
    fail modal-filter-cancel "s n did not re-enter literal filter input"
  lem_keys "$session" Escape
  sleep 0.3
  filter=$(report_filter || true)
  if [[ "$filter" == FILTER\ stack=name=sort-* ]] &&
     [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
     [[ "$filter" != *'buffer-list-zz-target.txt'* ]]; then
    pass modal-filter-cancel "Escape cancelled pending input without erasing the accepted stack"
  else
    fail modal-filter-cancel "Escape changed the accepted filter stack: $filter"
  fi
  lem_keys "$session" s /
else
  fail modal-marks "could not narrow to modal mark fixtures"
  lem_keys "$session" Escape
fi
lem_keys "$session" q

lem_keys "$session" C-x C-b
check_star_mark mark-modified mark-modified m buffer-list-mark-modified-hit
check_star_mark mark-unsaved mark-unsaved u buffer-list-mark-unsaved-hit.txt
check_star_mark mark-special mark-special '*' '*buffer-list-mark-special-hit*'
check_star_mark mark-read-only mark-read-only r buffer-list-mark-read-only-hit
check_star_mark mark-dired mark-dired / buffer-list-mark-dired-hit
check_star_mark mark-dissociated mark-dissociated e buffer-list-mark-dissociated-hit
check_star_mark mark-help Help h '*Help*'
check_star_mark mark-compressed mark-compressed z buffer-list-mark-compressed-hit.GZ
lem_keys "$session" s / U q

lem_keys "$session" C-x C-b F6
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'mark-revert-dirty'
lem_keys "$session" Enter
nav=$(report_nav || true)
lem_keys "$session" =
if lem_wait_for "$session" 'Buffer: buffer-list-mark-revert-dirty\.txt' 15 >/dev/null; then
  diff=$(report_diff || true)
  if [[ "$nav" == *'marks=' ]] &&
     [[ "$diff" == *'live=yes current=*Ibuffer Diff* mode=BUFFER-LIST-DIFF-MODE readonly=yes modified=no'* ]] &&
     [[ "$diff" == *'\n-DIRTY DISK\n+DIRTY LOCAL\n'* ]]; then
    pass diff-current "= diffed the unmarked current buffer without manufacturing a mark"
  else
    fail diff-current "the current-buffer unified diff diverged: $nav / $diff"
  fi
else
  fail diff-current "= did not open the dirty current buffer's diff"
fi
lem_keys "$session" q

lem_keys "$session" C-x C-b F6
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'mark-revert-dirty'
lem_keys "$session" Enter m s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-zz-target.txt'
lem_keys "$session" Enter m s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-op-alpha'
lem_keys "$session" Enter m s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'mark-revert-missing'
lem_keys "$session" Enter d s / =
if lem_wait_for "$session" 'Buffer: buffer-list-zz-target\.txt' 15 >/dev/null; then
  diff=$(report_diff || true)
  if [[ "$diff" == *'Buffer: buffer-list-mark-revert-dirty.txt'* ]] &&
     [[ "$diff" == *'Buffer: buffer-list-zz-target.txt\nNo differences.\n'* ]] &&
     [[ "$diff" != *'buffer-list-op-alpha'* ]] &&
     [[ "$diff" != *'buffer-list-mark-revert-missing'* ]]; then
    pass diff-marked "= diffed ordinary file marks, ignored a non-file buffer, and excluded D"
  else
    fail diff-marked "the marked multi-buffer diff selected the wrong buffers: $diff"
  fi
else
  fail diff-marked "= did not open the marked multi-buffer diff"
fi
lem_keys "$session" q

lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'mark-revert-missing'
lem_keys "$session" Enter =
if lem_wait_for "$session" 'File does not exist:.*buffer-list-mark-revert-missing\.txt' 15 >/dev/null; then
  diff=$(report_diff || true)
  nav=$(report_nav || true)
  if [[ "$diff" == *'Buffer: buffer-list-mark-revert-dirty.txt'* ]] &&
     [[ "$diff" == *'Buffer: buffer-list-zz-target.txt'* ]] &&
     [[ "$diff" != *'buffer-list-mark-revert-missing'* ]] &&
     [[ "$nav" == *'marks=' ]]; then
    pass diff-missing-file "a missing current file failed before replacing the prior diff or adding a mark"
  else
    fail diff-missing-file "missing-file diff handling changed state: $diff / $nav"
  fi
else
  fail diff-missing-file "= did not report the missing associated file"
fi
lem_keys "$session" q

lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'mark-revert-clean'
lem_keys "$session" Enter V
if lem_wait_for "$session" 'Really revert buffer buffer-list-mark-revert-clean\.txt' 10 >/dev/null; then
  lem_keys "$session" n
  revert=$(report_revert || true)
  nav=$(report_nav || true)
  if [[ "$revert" == *'clean=CLEAN LOCAL\n:clean'* ]] &&
     [[ "$nav" == *'marks=buffer-list-mark-revert-clean.txt:>'* ]]; then
    pass revert-clean-refusal "V prompted for a clean current row and retained its implicit mark"
  else
    fail revert-clean-refusal "declining clean revert changed state: $revert / $nav"
  fi
else
  fail revert-clean-prompt "V did not show the pinned one-buffer confirmation"
fi

lem_keys "$session" V
if lem_wait_for "$session" 'Really revert buffer buffer-list-mark-revert-clean\.txt' 10 >/dev/null; then
  lem_keys "$session" y
  revert=$(report_revert || true)
  if [[ "$revert" == *'clean=CLEAN DISK\n:clean'* ]]; then
    pass revert-clean-accept "accepting V reloaded clean buffer content from disk"
  else
    fail revert-clean-accept "clean revert produced unexpected state: $revert"
  fi
else
  fail revert-clean-accept "the accepted clean revert did not prompt"
fi

lem_keys "$session" F6 s / U
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'mark-revert-dirty'
lem_keys "$session" Enter V
if lem_wait_for "$session" 'Really revert buffer buffer-list-mark-revert-dirty\.txt' 10 >/dev/null; then
  lem_keys "$session" n
  revert=$(report_revert || true)
  if [[ "$revert" == *'dirty=DIRTY LOCAL\n:modified'* ]]; then
    pass revert-dirty-refusal "declining V preserved dirty buffer text"
  else
    fail revert-dirty-refusal "declining dirty revert changed state: $revert"
  fi
else
  fail revert-dirty-prompt "V did not confirm dirty-buffer discard"
fi

lem_keys "$session" V
if lem_wait_for "$session" 'Really revert buffer buffer-list-mark-revert-dirty\.txt' 10 >/dev/null; then
  lem_keys "$session" y
  revert=$(report_revert || true)
  if [[ "$revert" == *'dirty=DIRTY DISK\n:clean'* ]]; then
    pass revert-dirty-accept "accepting V discarded dirty text and reset modified state"
  else
    fail revert-dirty-accept "dirty revert produced unexpected state: $revert"
  fi
else
  fail revert-dirty-accept "the accepted dirty revert did not prompt"
fi

lem_keys "$session" F6 s / U
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'mark-revert-clean'
lem_keys "$session" Enter m s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'mark-revert-missing'
lem_keys "$session" Enter m s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'mark-revert-dirty'
lem_keys "$session" Enter d s / V
if lem_wait_for "$session" 'Really revert 2 buffers' 10 >/dev/null; then
  lem_keys "$session" y
  revert=$(report_revert || true)
  nav=$(report_nav || true)
  if [[ "$revert" == *'clean=CLEAN DISK\n:clean'* ]] &&
     [[ "$revert" == *'dirty=DIRTY LOCAL\n:modified'* ]] &&
     [[ "$revert" == *'missing=MISSING LOCAL\n:modified'* ]] &&
     [[ "$nav" == *'buffer-list-mark-revert-clean.txt:>'* ]] &&
     [[ "$nav" == *'buffer-list-mark-revert-dirty.txt:D'* ]] &&
     [[ "$nav" == *'buffer-list-mark-revert-missing.txt:>'* ]]; then
    pass revert-mixed "V continued after a missing file and excluded the deletion-marked buffer"
  else
    fail revert-mixed "mixed revert changed the wrong buffers or marks: $revert / $nav"
  fi
else
  fail revert-mixed "V did not confirm exactly the two ordinary-marked buffers"
fi
lem_keys "$session" U q

lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'save-target'
if lem_wait_for "$session" 'buffer-list-save-target\.txt' 15 >/dev/null; then
  lem_keys "$session" Enter
  lem_keys "$session" m
  lem_keys "$session" S
  sleep 0.5
  if cmp -s "$LEM_YATH_BUFFER_LIST_SAVE_TARGET" <(printf 'SAVE ORIGINAL\nSAVE LOCAL\n'); then
    pass marked-save "m plus S saved the marked grouped entry"
  else
    fail marked-save "the marked file buffer was not saved exactly"
    od -An -tx1 "$LEM_YATH_BUFFER_LIST_SAVE_TARGET" 2>/dev/null || true
  fi
else
  fail marked-save "the save fixture did not survive grouped filtering"
fi
lem_keys "$session" Enter
lem_wait_for "$session" 'SAVE LOCAL' 15 >/dev/null ||
  fail marked-save-select "Return did not close the chooser on the saved buffer"

lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'kill-target'
sleep 0.6
screen=$(lem_capture "$session")
if (( $(grep -Fc 'buffer-list-kil...' <<<"$screen") >= 2 )); then
  lem_keys "$session" Enter
  lem_keys "$session" d
  lem_keys "$session" d
  lem_keys "$session" x
  sleep 0.5
  before=$(grep -c '^LIFECYCLE ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F7
  attempts=0
  while ((attempts < 40)) &&
        (( $(grep -c '^LIFECYCLE ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) <= before )); do
    sleep 0.25
    attempts=$((attempts + 1))
  done
  if grep -q '^LIFECYCLE save-modified=no kill-a=dead kill-b=dead$' "$LEM_YATH_BUFFER_LIST_REPORT"; then
    pass marked-kill "d plus x removed both deletion-marked entries and the stale filter snapshot"
  else
    fail marked-kill "marked entry deletion did not cleanly update the chooser snapshot"
  fi
else
  fail marked-kill "the kill fixtures did not survive grouped filtering"
fi

lem_keys "$session" s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-op-'
lem_keys "$session" Enter m m
lem_keys "$session" '}'
nav=$(report_nav || true)
if [[ "$nav" == NAV\ focus=buffer:buffer-list-op-beta* ]]; then
  pass marked-next "} cycled forward to the next ordinary mark"
else
  fail marked-next "} selected an unexpected row: $nav"
fi

lem_keys "$session" '{'
nav=$(report_nav || true)
if [[ "$nav" == NAV\ focus=buffer:buffer-list-op-alpha* ]]; then
  pass marked-previous "{ cycled backward to the previous ordinary mark"
else
  fail marked-previous "{ selected an unexpected row: $nav"
fi

picker_bindings=$(report_picker_bindings || true)
if [[ "$picker_bindings" == *'backspace=LEM-YATH-BUFFER-LIST-UNMARK-BACKWARD'* ]]; then
  pass backward-binding "the picker resolves Backspace to backward unmark"
else
  fail backward-binding "the active Backspace binding diverged: $picker_bindings"
fi

if [[ "$picker_bindings" == *'group-jump=LEM-YATH-BUFFER-LIST-JUMP-TO-GROUP'* ]] &&
   [[ "$picker_bindings" == *'other-noselect=LEM-YATH-BUFFER-LIST-VISIT-OTHER-WINDOW-NOSELECT'* ]] &&
   [[ "$picker_bindings" == *'one-window=LEM-YATH-BUFFER-LIST-VISIT-ONE-WINDOW'* ]] &&
   [[ "$picker_bindings" == *'view=LEM-YATH-BUFFER-LIST-VIEW view-g=LEM-YATH-BUFFER-LIST-VIEW view-horizontal=LEM-YATH-BUFFER-LIST-VIEW-HORIZONTALLY'* ]] &&
   [[ "$picker_bindings" == *'occur=LEM-YATH-BUFFER-LIST-OCCUR occur-meta=LEM-YATH-BUFFER-LIST-OCCUR isearch=LEM-YATH-BUFFER-LIST-MULTI-ISEARCH isearch-regexp=LEM-YATH-BUFFER-LIST-MULTI-ISEARCH-REGEXP query=LEM-YATH-BUFFER-LIST-QUERY-REPLACE query-regexp=LEM-YATH-BUFFER-LIST-QUERY-REPLACE-REGEXP'* ]]; then
  pass visit-view-bindings "M-j, visits, views, Occur, multi-isearch, and query-replace resolve in the picker map"
else
  fail visit-view-bindings "one or more visit/view bindings diverged: $picker_bindings"
fi

lem_keys "$session" BSpace
nav=$(report_nav || true)
if [[ "$nav" == *'focus=buffer:buffer-list-op-beta'* ]] &&
   [[ "$nav" == *'marks=buffer-list-op-alpha:>'* ]] &&
   [[ "$nav" != *'buffer-list-op-beta:>'* ]]; then
  pass unmark-backward "Backspace moved backward before clearing that row"
else
  fail unmark-backward "Backspace diverged from Ibuffer: $nav"
fi

lem_keys "$session" d '}' M T R
ops=$(report_operations || true)
nav=$(report_nav || true)
if [[ "$ops" == OPS\ alpha=buffer-list-op-alpha\<2\>:modified:readonly\ beta=buffer-list-op-beta:clean:writable* ]]; then
  if [[ "$nav" == *'buffer-list-op-beta:D'* ]]; then
    pass marked-state-operations "M, T, and R ignored D and changed only the ordinary mark"
  else
    fail marked-state-operations "the deletion mark was not retained: $nav"
  fi
else
  fail marked-state-operations "marked state operations diverged: $ops"
fi

lem_keys "$session" R
ops=$(report_operations || true)
if [[ "$ops" == OPS\ alpha=buffer-list-op-alpha:modified:readonly\ beta=buffer-list-op-beta:clean:writable* ]]; then
  pass repeated-unique-rename "repeated R removed the synthetic Emacs <2> suffix"
else
  fail repeated-unique-rename "repeated R diverged from rename-uniquely: $ops"
fi

lem_keys "$session" R U
lem_keys "$session" g k X
ops=$(report_operations || true)
nav=$(report_nav || true)
if [[ "$ops" == *'relative=buffer-list-op-alpha<2>,buffer-list-op-beta tail=buffer-list-op-beta' ]] &&
   [[ "$nav" == *'focus=buffer:buffer-list-op-alpha<2>'* ]]; then
  pass bury-buffer "X buried the current buffer and retained the original row"
else
  fail bury-buffer "X produced an unexpected order or focus: $ops / $nav"
fi

lem_keys "$session" s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'sort-'
lem_keys "$session" Enter m d
lem_keys "$session" s /
lem_keys "$session" F4
sleep 0.3
if grep -q '^LATE created=yes$' "$LEM_YATH_BUFFER_LIST_REPORT"; then
  lem_keys "$session" g R
  redisplayed=$(report_filter || true)
  if [[ "$redisplayed" != *'buffer-list-late-buffer'* ]]; then
    pass redisplay-snapshot "gR recomputed the existing snapshot without adding buffers"
  else
    fail redisplay-snapshot "gR unexpectedly rebuilt the buffer snapshot: $redisplayed"
  fi

  lem_keys "$session" g r
  updated=$(report_filter || true)
  nav=$(report_nav || true)
  if [[ "$updated" == *'buffer-list-late-buffer'* ]] &&
     [[ "$nav" == *'buffer-list-sort-zeta:>,buffer-list-sort-middle:D'* ]]; then
    pass update-snapshot "gr added a late buffer and preserved both mark classes"
  else
    fail update-snapshot "gr did not rebuild safely: $updated / $nav"
  fi

  lem_keys "$session" s n
  tmux_cmd send-keys -t "$session" -l 'late-buffer'
  lem_keys "$session" Enter
  lem_keys "$session" g r
  filtered_update=$(report_filter || true)
  if [[ "$filtered_update" == FILTER\ stack=name=late-buffer* ]] &&
     [[ "$filtered_update" == *'buffer-list-late-buffer'* ]]; then
    pass update-filter "gr retained and reapplied the active filter stack"
  else
    fail update-filter "gr changed the active filter stack: $filtered_update"
  fi
  lem_keys "$session" s /
else
  fail update-snapshot "the late-buffer fixture command did not run"
fi

lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'sort-zeta'
lem_keys "$session" Enter
lem_keys "$session" y b
copied=$(report_copy || true)
if [[ "$copied" == 'COPY value=buffer-list-sort-zeta' ]]; then
  pass copy-buffer-name "yb copied the exact focused buffer name"
else
  fail copy-buffer-name "yb copied an unexpected value: $copied"
fi

lem_keys "$session" s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'zz-target'
lem_keys "$session" Enter
lem_keys "$session" y f
copied=$(report_copy || true)
if [[ "$copied" == "COPY value=$LEM_YATH_BUFFER_LIST_TARGET" ]]; then
  pass copy-file-name "yf copied the exact focused visiting filename"
else
  fail copy-file-name "yf copied an unexpected value: $copied"
fi

lem_keys "$session" q C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-view-alpha'
lem_keys "$session" Enter C-o
picker_state=$(report_picker_bindings || true)
if [[ "$picker_state" == *'current-popup=yes ordinary-count=2'* ]] &&
   [[ "$picker_state" == *'ordinary-buffers='*'buffer-list-view-alpha'* ]]; then
  pass visit-other-noselect "C-o displayed the target in an ordinary window while retaining picker focus"
else
  fail visit-other-noselect "C-o changed focus or produced an unexpected layout: $picker_state"
fi

lem_keys "$session" q C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-view-beta'
lem_keys "$session" Enter g o
window=$(report_window || true)
if [[ "$window" == WINDOW\ count=2\ current=buffer-list-view-beta\ buffers=* ]] &&
   [[ "$window" == *'buffer-list-view-beta'* ]]; then
  pass visit-other-window "go selected the focused buffer in the other ordinary window"
else
  fail visit-other-window "go produced an unexpected window layout: $window"
fi

lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-view-alpha'
lem_keys "$session" Enter M-o
window=$(report_window || true)
if [[ "$window" == 'WINDOW count=1 current=buffer-list-view-alpha buffers=buffer-list-view-alpha axis=single'* ]]; then
  pass visit-one-window "M-o selected the focused buffer and removed every other ordinary window"
else
  fail visit-one-window "M-o produced an unexpected one-window layout: $window"
fi

prepare_view_marks
if [[ $(grep -o ':>' <<<"$view_nav" | wc -l) -eq 2 ]] &&
   [[ -n "$view_deleted" ]]; then
  lem_keys "$session" A
  window=$(report_window || true)
  if [[ "$window" == WINDOW\ count=2* ]] &&
     [[ "$window" == *' axis=stacked '* ]] &&
     [[ "$window" == *'buffer-list-view-'* ]] &&
     [[ "$window" != *"$view_deleted"* ]]; then
    pass view-stacked-A "A stacked the two ordinary marks and excluded the deletion mark"
  else
    fail view-stacked-A "A produced an unexpected marked-buffer layout: $window / $view_nav"
  fi
else
  fail view-stacked-A "the A fixture did not establish two ordinary marks and one deletion mark: $view_nav"
  lem_keys "$session" q
fi

prepare_view_marks
if [[ $(grep -o ':>' <<<"$view_nav" | wc -l) -eq 2 ]] &&
   [[ -n "$view_deleted" ]]; then
  lem_keys "$session" g v
  window=$(report_window || true)
  if [[ "$window" == WINDOW\ count=2* ]] &&
     [[ "$window" == *' axis=stacked '* ]] &&
     [[ "$window" != *"$view_deleted"* ]]; then
    pass view-stacked-gv "gv uses the same marked-buffer stacked view as A"
  else
    fail view-stacked-gv "gv produced an unexpected marked-buffer layout: $window / $view_nav"
  fi
else
  fail view-stacked-gv "the gv fixture did not establish its expected marks: $view_nav"
  lem_keys "$session" q
fi

prepare_view_marks
if [[ $(grep -o ':>' <<<"$view_nav" | wc -l) -eq 2 ]] &&
   [[ -n "$view_deleted" ]]; then
  lem_keys "$session" g V
  window=$(report_window || true)
  if [[ "$window" == WINDOW\ count=2* ]] &&
     [[ "$window" == *' axis=side-by-side '* ]] &&
     [[ "$window" != *"$view_deleted"* ]]; then
    pass view-side-by-side "gV displayed ordinary marks side by side and excluded D"
  else
    fail view-side-by-side "gV produced an unexpected marked-buffer layout: $window / $view_nav"
  fi
else
  fail view-side-by-side "the gV fixture did not establish its expected marks: $view_nav"
  lem_keys "$session" q
fi

lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-view-alpha'
lem_keys "$session" Enter g v
window=$(report_window || true)
if [[ "$window" == 'WINDOW count=1 current=buffer-list-view-alpha buffers=buffer-list-view-alpha axis=single'* ]]; then
  pass view-current-fallback "unmarked gv viewed only the current row in one ordinary window"
else
  fail view-current-fallback "unmarked gv did not use the current-row fallback: $window"
fi

# Unlike define-ibuffer-op bulk actions, GNU ibuffer-do-isearch consumes only
# explicit ordinary marks.  With none, refuse without dismissing the chooser.
lem_keys "$session" C-x C-b
lem_keys "$session" M-s a C-s
if lem_wait_for "$session" 'No ordinarily marked buffers for Ibuffer multi-isearch' 10 >/dev/null; then
  picker_state=$(report_picker_bindings || true)
  if [[ "$picker_state" == *'current-popup=yes ordinary-count='* ]]; then
    pass multi-isearch-no-marks "literal multi-isearch refused an empty marked set without dismissing Ibuffer"
  else
    fail multi-isearch-no-marks "the no-mark refusal changed chooser focus: $picker_state"
  fi
else
  fail multi-isearch-no-marks "literal multi-isearch did not refuse an empty marked set"
fi

# Establish deterministic display order, two ordinary marks, and one deletion
# mark.  Input pauses failing in the first source; C-s then crosses to the next.
lem_keys "$session" o a
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-alpha'
lem_keys "$session" Enter m
lem_keys "$session" s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-beta'
lem_keys "$session" Enter m
lem_keys "$session" s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-delete'
lem_keys "$session" Enter d
lem_keys "$session" s /
lem_keys "$session" M-s a C-s
tmux_cmd send-keys -t "$session" -l 'beta lower'
initial_multi=$(report_multi_isearch || true)
if [[ "$initial_multi" == *'active=yes native=yes current=buffer-list-occur-alpha line=1 column=0 regexp=no string=beta lower'* ]] &&
   [[ "$initial_multi" == *'next=LEM-YATH-BUFFER-LIST-MULTI-ISEARCH-NEXT previous=LEM-YATH-BUFFER-LIST-MULTI-ISEARCH-PREVIOUS abort=LEM-YATH-BUFFER-LIST-MULTI-ISEARCH-ABORT'* ]] &&
   [[ "$initial_multi" == *'sources=buffer-list-occur-alpha,buffer-list-occur-beta'* ]] &&
   [[ "$initial_multi" != *'sources='*'buffer-list-occur-delete'* ]]; then
  pass multi-isearch-initial "literal input paused in the first display-order ordinary mark and excluded D"
else
  fail multi-isearch-initial "the initial multi-isearch state diverged: $initial_multi"
fi

lem_keys "$session" C-s
literal_cross=$(report_multi_isearch || true)
if [[ "$literal_cross" == *'active=yes native=yes current=buffer-list-occur-beta line=1 column=16 regexp=no string=beta lower'* ]] &&
   [[ "$literal_cross" == *'buffer-list-occur-alpha:native/multi,buffer-list-occur-beta:native/multi'* ]]; then
  pass multi-isearch-cross "C-s continued the live search into the next marked buffer at the exact match end"
else
  fail multi-isearch-cross "C-s did not cross buffers cleanly: $literal_cross"
fi

lem_keys "$session" C-r
literal_previous=$(report_multi_isearch || true)
lem_keys "$session" C-s BSpace
literal_edited=$(report_multi_isearch || true)
tmux_cmd send-keys -t "$session" -l 'r'
literal_restored=$(report_multi_isearch || true)
if [[ "$literal_previous" == *'current=buffer-list-occur-beta line=1 column=16 regexp=no string=beta lower'* ]] &&
   [[ "$literal_edited" == *'current=buffer-list-occur-beta line=1 column=16 regexp=no string=beta lowe'* ]] &&
   [[ "$literal_restored" == *'current=buffer-list-occur-beta line=1 column=16 regexp=no string=beta lower'* ]]; then
  pass multi-isearch-edit "C-r and pattern edits retained valid cross-buffer point ownership"
else
  fail multi-isearch-edit "backward or edited cross-buffer search diverged: $literal_previous / $literal_edited / $literal_restored"
fi

lem_keys "$session" Enter
literal_lifecycle=$(report_multi_isearch_lifecycle || true)
if [[ "$literal_lifecycle" == *'active=no current=buffer-list-occur-beta line=1 column=16 alpha=no-native/no-multi beta=no-native/no-multi literal-top=beta lower'* ]]; then
  pass multi-isearch-finish "Return retained the match, recorded literal history, and removed every transient mode"
else
  fail multi-isearch-finish "literal finish leaked state or lost history: $literal_lifecycle"
fi

# The Evil-Collection regexp chord uses the same marked order.  C-g from a
# later source must restore the first source's initial point and clear modes
# without recording the aborted regexp in persistent history.
lem_keys "$session" C-x C-b o a
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-alpha'
lem_keys "$session" Enter m
lem_keys "$session" s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-beta'
lem_keys "$session" Enter m
lem_keys "$session" s /
lem_keys "$session" M-s a C-M-s
tmux_cmd send-keys -t "$session" -l 'NEEDLE beta (upper|missing)'
regexp_initial=$(report_multi_isearch || true)
lem_keys "$session" C-s
regexp_cross=$(report_multi_isearch || true)
if [[ "$regexp_initial" == *'current=buffer-list-occur-alpha line=1 column=0 regexp=yes string=NEEDLE beta (upper|missing)'* ]] &&
   [[ "$regexp_cross" == *'current=buffer-list-occur-beta line=3 column=16 regexp=yes string=NEEDLE beta (upper|missing)'* ]]; then
  pass multi-isearch-regexp "the regexp chord paused, then continued across marked buffers"
else
  fail multi-isearch-regexp "regexp multi-isearch state diverged: $regexp_initial / $regexp_cross"
fi
lem_keys "$session" C-g
regexp_lifecycle=$(report_multi_isearch_lifecycle || true)
if [[ "$regexp_lifecycle" == *'active=no current=buffer-list-occur-alpha line=1 column=0 alpha=no-native/no-multi beta=no-native/no-multi'* ]] &&
   [[ "$regexp_lifecycle" == *'regexp-recorded=no'* ]]; then
  pass multi-isearch-abort "C-g restored the first source and cleared the aborted regexp session"
else
  fail multi-isearch-abort "regexp abort leaked state or retained the later buffer: $regexp_lifecycle"
fi

# GNU Ibuffer Q/I use ordinary marks in display order, implicitly mark the
# current row when needed, and run a fresh query from each buffer's beginning.
# The picker must disappear while a target is being queried and return with its
# marks/focus intact afterward.
lem_keys "$session" F11
attempts=0
while ((attempts < 40)) &&
      ! grep -q '^QUERY-PREPARED$' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null; do
  sleep 0.25
  attempts=$((attempts + 1))
done
if grep -q '^QUERY-PREPARED$' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null; then
  pass query-fixture "isolated query-replace buffers were created after layout-sensitive cases"
else
  fail query-fixture "query-replace fixture buffers were not created"
fi
lem_keys "$session" C-x C-b o a
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-alpha'
lem_keys "$session" Enter U Q
if lem_wait_for "$session" 'Query replace:' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'foo'
  lem_keys "$session" Enter
  tmux_cmd send-keys -t "$session" -l 'unchanged'
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'Replace "foo" with "unchanged"' 10 >/dev/null; then
    lem_keys "$session" q
    if lem_wait_for "$session" 'Query replace finished; 0 replacements in 1 buffer' 10 >/dev/null; then
      implicit_nav=$(report_nav || true)
      if [[ "$implicit_nav" == *'buffer-list-query-alpha:>'* ]]; then
        pass query-current-fallback "unmarked Q implicitly marked and queried only the current row"
      else
        fail query-current-fallback "Q did not retain the implicit current-row mark: $implicit_nav"
      fi
    else
      fail query-current-fallback "q did not finish the implicit current-row query"
    fi
  else
    fail query-current-fallback "the implicit current-row query did not reach its first match"
  fi
else
  fail query-current-fallback "Q did not open its literal search prompt"
fi

# Select two ordinary buffers and one D row.  y/n/! applies within the first
# buffer; the fresh prompt in beta proves ! did not leak across buffers.  Dot
# replaces beta's current match and exits that per-buffer query.
lem_keys "$session" U
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-alpha'
lem_keys "$session" Enter m
lem_keys "$session" s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-beta'
lem_keys "$session" Enter m
lem_keys "$session" s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-delete'
lem_keys "$session" Enter d
lem_keys "$session" s / Q
if lem_wait_for "$session" 'Query replace' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'foo'
  lem_keys "$session" Enter
  tmux_cmd send-keys -t "$session" -l 'qux'
  lem_keys "$session" Enter
  if lem_wait_for "$session" 'foo alpha one' 10 >/dev/null &&
     lem_wait_for "$session" 'Replace "foo" with "qux"' 10 >/dev/null; then
    pass query-visible-first "Q hid Ibuffer and displayed the first marked target at its match"
  else
    fail query-visible-first "Q did not visibly query the first display-order mark"
  fi
  lem_keys "$session" y n '!'
  if lem_wait_for "$session" 'foo beta one' 10 >/dev/null &&
     lem_wait_for "$session" 'Replace "foo" with "qux"' 10 >/dev/null; then
    pass query-per-buffer-bang "! replaced the first buffer's remainder and prompted afresh in beta"
  else
    fail query-per-buffer-bang "! leaked across buffers or beta was not displayed"
  fi
  lem_keys "$session" .
else
  fail query-visible-first "marked Q did not open its literal search prompt"
fi

if lem_wait_for "$session" 'Query replace finished; 3 replacements in 2 buffers' 10 >/dev/null; then
  query_literal=$(report_query_state || true)
  query_nav=$(report_nav || true)
  if [[ "$query_literal" == *'alpha=modified:writable:qux alpha one\nFOO alpha two\nqux alpha three\n'* ]] &&
     [[ "$query_literal" == *'beta=modified:writable:qux beta one\nbar 42\nBAR 99\n'* ]] &&
     [[ "$query_literal" == *'delete=clean:writable:foo forbidden deletion\nbar 77\n'* ]] &&
     [[ "$query_nav" == *'buffer-list-query-alpha:>'* ]] &&
     [[ "$query_nav" == *'buffer-list-query-beta:>'* ]] &&
     [[ "$query_nav" == *'buffer-list-query-delete:D'* ]]; then
    pass query-literal-result "literal Q honored y/n/!, case-folding, D exclusion, marks, and picker restoration"
  else
    fail query-literal-result "literal Q state diverged: $query_literal / $query_nav"
  fi
else
  fail query-literal-result "literal Q did not finish with the expected replacement count"
fi

# Each target receives an explicit undo boundary even though the outer command
# returns to Ibuffer.  One physical Normal u in each target restores all edits
# made there by the single Q invocation.
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-alpha'
lem_keys "$session" Enter Enter u
alpha_undo=$(report_current || true)
lem_keys "$session" C-x C-b s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-beta'
lem_keys "$session" Enter Enter u
beta_undo=$(report_current || true)
if [[ "$alpha_undo" == *'name=buffer-list-query-alpha'*'text=foo alpha one\nFOO alpha two\nfoo alpha three\n'* ]] &&
   [[ "$beta_undo" == *'name=buffer-list-query-beta'*'text=foo beta one\nbar 42\nBAR 99\n'* ]]; then
  pass query-undo "one Normal undo per target restored every replacement from Q"
else
  fail query-undo "query-replace edits were not one undo unit per buffer: $alpha_undo / $beta_undo"
fi

# A read-only source is rejected before prompts or mutations, so a later
# selected target cannot cause an earlier writable buffer to be changed first.
lem_keys "$session" C-x C-b U o a
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-alpha'
lem_keys "$session" Enter m
lem_keys "$session" s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-read-only'
lem_keys "$session" Enter m
lem_keys "$session" s / Q
if lem_wait_for "$session" 'Ibuffer query-replace source is read-only: buffer-list-query-read-only' 10 >/dev/null; then
  query_readonly=$(report_query_state || true)
  if [[ "$query_readonly" == *'alpha=clean:writable:foo alpha one\nFOO alpha two\nfoo alpha three\n'* ]] &&
     [[ "$query_readonly" == *'readonly=clean:readonly:foo read only\n'* ]]; then
    pass query-read-only-preflight "Q rejected the complete marked set before changing its writable member"
  else
    fail query-read-only-preflight "read-only preflight allowed a partial mutation: $query_readonly"
  fi
else
  fail query-read-only-preflight "Q did not fail closed on a read-only marked buffer"
fi

# Invalid and empty-matching regexps fail while Ibuffer is still present.  A
# valid regexp is case-insensitive like ibuffer-case-fold-search; q exits only
# beta's per-buffer query after the first accepted match.
lem_keys "$session" U
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-beta'
lem_keys "$session" Enter I
if lem_wait_for "$session" 'Query replace regexp' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '*'
  lem_keys "$session" Enter
  tmux_cmd send-keys -t "$session" -l 'invalid'
  lem_keys "$session" Enter
fi
if lem_wait_for "$session" 'Invalid Ibuffer query-replace regexp' 10 >/dev/null; then
  pass query-invalid-regexp "I refused an invalid regexp without dismissing Ibuffer"
else
  fail query-invalid-regexp "I did not reject an invalid regexp"
fi

lem_keys "$session" I
if lem_wait_for "$session" 'Query replace regexp' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '^'
  lem_keys "$session" Enter
  tmux_cmd send-keys -t "$session" -l 'prefix'
  lem_keys "$session" Enter
fi
if lem_wait_for "$session" 'Ibuffer query-replace refuses a regexp with empty matches' 10 >/dev/null; then
  pass query-empty-regexp "I refused an empty-matching regexp before entering its query loop"
else
  fail query-empty-regexp "I did not fail closed on an empty-matching regexp"
fi

lem_keys "$session" I
if lem_wait_for "$session" 'Query replace regexp' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'bar [0-9]+'
  lem_keys "$session" Enter
  tmux_cmd send-keys -t "$session" -l 'num'
  lem_keys "$session" Enter
fi
if lem_wait_for "$session" 'bar 42' 10 >/dev/null &&
   lem_wait_for "$session" 'Replace "bar.*with "num"' 10 >/dev/null; then
  lem_keys "$session" y
  if lem_wait_for "$session" 'BAR 99' 10 >/dev/null; then
    lem_keys "$session" q
  fi
fi
if lem_wait_for "$session" 'Query replace finished; 1 replacement in 1 buffer' 10 >/dev/null; then
  query_regexp=$(report_query_state || true)
  if [[ "$query_regexp" == *'beta=modified:writable:foo beta one\nnum\nBAR 99\n'* ]]; then
    pass query-regexp-result "lowercase I matched case-insensitively and q retained the later match"
  else
    fail query-regexp-result "regexp query result diverged: $query_regexp"
  fi
else
  fail query-regexp-result "valid I did not complete its y/q lifecycle"
fi

# Restore beta for the existing Occur and reload cases that follow.
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-beta'
lem_keys "$session" Enter Enter u
beta_regexp_undo=$(report_current || true)
if [[ "$beta_regexp_undo" == *'text=foo beta one\nbar 42\nBAR 99\n'* ]]; then
  pass query-regexp-undo "one undo restored the regexp query replacement"
else
  fail query-regexp-undo "regexp query replacement was not one undo unit: $beta_regexp_undo"
fi

# GNU regexp replacement expands the whole match, groups, the per-command
# replacement count, and a quoted backslash.  Lisp evaluation and per-match
# replacement editing are deliberately rejected before the picker is hidden.
lem_keys "$session" C-x C-b U o a
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-expand'
lem_keys "$session" Enter I
if lem_wait_for "$session" 'Query replace regexp' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '([a-z]+)-([a-z]+)'
  lem_keys "$session" Enter
  tmux_cmd send-keys -t "$session" -l '\,x'
  lem_keys "$session" Enter
fi
if lem_wait_for "$session" 'Unsupported Ibuffer regexp replacement directive' 10 >/dev/null; then
  unsupported_replacement=$(report_query_state || true)
  if [[ "$unsupported_replacement" == *'expand=clean:writable:foo-one\nFOO-TWO\nFoo-Three\n'* ]]; then
    pass query-replacement-preflight "I rejected an evaluated replacement before mutation or picker teardown"
  else
    fail query-replacement-preflight "unsupported replacement changed its target: $unsupported_replacement"
  fi
else
  fail query-replacement-preflight "I did not reject an unsupported evaluated replacement"
fi

lem_keys "$session" I
if lem_wait_for "$session" 'Query replace regexp' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l '([a-z]+)-([a-z]+)'
  lem_keys "$session" Enter
  tmux_cmd send-keys -t "$session" -l '\2-\1-\&-\#-\\-tail'
  lem_keys "$session" Enter
fi
if lem_wait_for "$session" 'foo-one' 10 >/dev/null &&
   lem_wait_for "$session" 'Replace' 10 >/dev/null; then
  lem_keys "$session" '!'
fi
if lem_wait_for "$session" 'Query replace finished; 3 replacements in 1 buffer' 10 >/dev/null; then
  expanded_replacement=$(report_query_state || true)
  if [[ "$expanded_replacement" == *'expand=modified:writable:one-foo-foo-one-0-\\-tail\nTWO-FOO-FOO-TWO-1-\\-TAIL\nThree-Foo-Foo-Three-2-\\-Tail\n'* ]]; then
    pass query-regexp-expansion "I expanded groups, whole matches, counts, quoting, and GNU case patterns"
  else
    fail query-regexp-expansion "regexp replacement expansion diverged: $expanded_replacement"
  fi
else
  fail query-regexp-expansion "expanded regexp query did not replace all three case patterns"
fi
lem_keys "$session" Enter u
expand_undo=$(report_current || true)
if [[ "$expand_undo" == *'text=foo-one\nFOO-TWO\nFoo-Three\n'* ]]; then
  pass query-regexp-expansion-undo "one undo restored the expanded regexp replacements"
else
  fail query-regexp-expansion-undo "expanded regexp replacements escaped their undo unit: $expand_undo"
fi

# An uppercase search disables case folding and replacement case transfer,
# matching GNU search-upper-case behavior in the pinned configuration.
lem_keys "$session" C-x C-b U o a
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-expand'
lem_keys "$session" Enter I
if lem_wait_for "$session" 'Query replace regexp' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'FOO-([A-Z]+)'
  lem_keys "$session" Enter
  tmux_cmd send-keys -t "$session" -l 'exact-\1'
  lem_keys "$session" Enter
fi
if lem_wait_for "$session" 'FOO-TWO' 10 >/dev/null; then
  lem_keys "$session" y
fi
if lem_wait_for "$session" 'Query replace finished; 1 replacement in 1 buffer' 10 >/dev/null; then
  smartcase_replacement=$(report_query_state || true)
  if [[ "$smartcase_replacement" == *'expand=modified:writable:foo-one\nexact-TWO\nFoo-Three\n'* ]]; then
    pass query-regexp-smartcase "uppercase I matched case-sensitively and retained exact replacement case"
  else
    fail query-regexp-smartcase "uppercase regexp smart-case diverged: $smartcase_replacement"
  fi
else
  fail query-regexp-smartcase "uppercase I did not finish after its sole exact-case match"
fi
lem_keys "$session" Enter u
smartcase_undo=$(report_current || true)
if [[ "$smartcase_undo" == *'text=foo-one\nFOO-TWO\nFoo-Three\n'* ]]; then
  pass query-regexp-smartcase-undo "one undo restored the smart-case regexp replacement"
else
  fail query-regexp-smartcase-undo "smart-case regexp replacement escaped its undo unit: $smartcase_undo"
fi

# Literal Q uses the same case-pattern transfer for lowercase searches.
lem_keys "$session" C-x C-b U o a
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-expand'
lem_keys "$session" Enter Q
if lem_wait_for "$session" 'Query replace' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'foo'
  lem_keys "$session" Enter
  tmux_cmd send-keys -t "$session" -l 'bar'
  lem_keys "$session" Enter
fi
if lem_wait_for "$session" 'foo-one' 10 >/dev/null; then
  lem_keys "$session" '!'
fi
if lem_wait_for "$session" 'Query replace finished; 3 replacements in 1 buffer' 10 >/dev/null; then
  literal_case_replacement=$(report_query_state || true)
  if [[ "$literal_case_replacement" == *'expand=modified:writable:bar-one\nBAR-TWO\nBar-Three\n'* ]]; then
    pass query-literal-case-transfer "lowercase Q preserved lower, all-caps, and initial-cap patterns"
  else
    fail query-literal-case-transfer "literal case transfer diverged: $literal_case_replacement"
  fi
else
  fail query-literal-case-transfer "literal case-transfer query did not replace all matches"
fi
lem_keys "$session" Enter u
literal_case_undo=$(report_current || true)
if [[ "$literal_case_undo" == *'text=foo-one\nFOO-TWO\nFoo-Three\n'* ]]; then
  pass query-literal-case-transfer-undo "one undo restored literal case-transfer replacements"
else
  fail query-literal-case-transfer-undo "literal case-transfer replacement escaped its undo unit: $literal_case_undo"
fi

lem_keys "$session" C-x C-b U o a
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-query-expand'
lem_keys "$session" Enter Q
if lem_wait_for "$session" 'Query replace' 10 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l 'FOO'
  lem_keys "$session" Enter
  tmux_cmd send-keys -t "$session" -l 'exact'
  lem_keys "$session" Enter
fi
if lem_wait_for "$session" 'FOO-TWO' 10 >/dev/null; then
  lem_keys "$session" y
fi
if lem_wait_for "$session" 'Query replace finished; 1 replacement in 1 buffer' 10 >/dev/null; then
  literal_smartcase=$(report_query_state || true)
  if [[ "$literal_smartcase" == *'expand=modified:writable:foo-one\nexact-TWO\nFoo-Three\n'* ]]; then
    pass query-literal-smartcase "uppercase Q matched case-sensitively without transferring case"
  else
    fail query-literal-smartcase "uppercase literal smart-case diverged: $literal_smartcase"
  fi
else
  fail query-literal-smartcase "uppercase Q did not finish after its sole exact-case match"
fi
lem_keys "$session" Enter u
literal_smartcase_undo=$(report_current || true)
if [[ "$literal_smartcase_undo" == *'text=foo-one\nFOO-TWO\nFoo-Three\n'* ]]; then
  pass query-literal-smartcase-undo "one undo restored the uppercase literal replacement"
else
  fail query-literal-smartcase-undo "uppercase literal replacement escaped its undo unit: $literal_smartcase_undo"
fi

# Restore the pre-query source-buffer context expected by the Occur window
# ownership cases below.
lem_keys "$session" C-x C-b s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-alpha'
lem_keys "$session" Enter Enter

# GNU Ibuffer's O searches ordinary marks in reverse display order, excludes D,
# displays *Occur* without selecting it, and retains the chooser and its marks.
lem_keys "$session" C-x C-b o a o i
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-alpha'
lem_keys "$session" Enter m
lem_keys "$session" s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-beta'
lem_keys "$session" Enter m
lem_keys "$session" s /
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-delete'
lem_keys "$session" Enter d
lem_keys "$session" s /
occur_nav=$(report_nav || true)
ordinary_order=$(sed -n 's/.*marks=//p' <<<"$occur_nav" | tr ',' '\n' |
  sed -n 's/:>$//p')
expected_sources=$(tac <<<"$ordinary_order" | paste -sd, -)
lem_keys "$session" M-1 O
tmux_cmd send-keys -t "$session" -l 'needle'
lem_keys "$session" Enter
if lem_wait_for "$session" 'Searched 2 buffers; 6 matches for "needle"' 15 >/dev/null; then
  picker_state=$(report_picker_bindings || true)
  retained_nav=$(report_nav || true)
  if [[ "$picker_state" == *'current-popup=yes ordinary-count=2'* ]] &&
     [[ "$picker_state" == *'ordinary-buffers='*'*Occur*'* ]] &&
     [[ "$retained_nav" == *'buffer-list-occur-alpha:>'* ]] &&
     [[ "$retained_nav" == *'buffer-list-occur-beta:>'* ]] &&
     [[ "$retained_nav" == *'buffer-list-occur-delete:D'* ]]; then
    pass occur-display-noselect "O displayed *Occur* while retaining picker focus and both mark classes"
  else
    fail occur-display-noselect "O changed focus, windows, or marks: $picker_state / $retained_nav"
  fi
else
  fail occur-display-noselect "O did not report the exact marked-buffer match count"
fi

select_occur_buffer
if lem_wait_for "$session" '6 matches in 5 lines total for "needle"' 15 >/dev/null; then
  occur=$(report_occur || true)
  if [[ "$occur" == *'current=*Occur* mode=BUFFER-LIST-OCCUR-MODE readonly=yes modified=no'* ]] &&
     [[ "$occur" == *"sources=$expected_sources"* ]] &&
     [[ "$occur" == *'6 matches in 5 lines total for "needle":\n'* ]] &&
     [[ "$occur" == *'4 matches in 3 lines in buffer: buffer-list-occur-alpha\n'* ]] &&
     [[ "$occur" == *'2 matches in buffer: buffer-list-occur-beta\n'* ]] &&
     [[ "$occur" == *'-------\n'* ]] &&
     [[ "$occur" == *'control\\t\\x9B;\\x202E;needle'* ]] &&
     [[ "$occur" != *'buffer-list-occur-delete'* ]] &&
     [[ "$occur" != *'forbidden deletion'* ]]; then
    pass occur-render "smart-case matches, reverse source order, context merging, escaping, and D exclusion match GNU Occur"
  else
    fail occur-render "the persistent Occur rendering diverged: $occur"
  fi
else
  fail occur-render "the marked multi-buffer Occur result was not selectable"
fi

occur_bindings=$(report_occur_bindings || true)
if [[ "$occur_bindings" == *'return=LEM-YATH-BUFFER-LIST-OCCUR-VISIT control-return=LEM-YATH-BUFFER-LIST-OCCUR-VISIT'* ]] &&
   [[ "$occur_bindings" == *'shift-return=LEM-YATH-BUFFER-LIST-OCCUR-VISIT meta-return=LEM-YATH-BUFFER-LIST-OCCUR-DISPLAY other=LEM-YATH-BUFFER-LIST-OCCUR-VISIT'* ]] &&
   [[ "$occur_bindings" == *'next=LEM-YATH-BUFFER-LIST-OCCUR-NEXT previous=LEM-YATH-BUFFER-LIST-OCCUR-PREVIOUS control-next=LEM-YATH-BUFFER-LIST-OCCUR-NEXT control-previous=LEM-YATH-BUFFER-LIST-OCCUR-PREVIOUS quit=QUIT-ACTIVE-WINDOW'* ]]; then
  pass occur-bindings "the effective Evil-Collection Occur navigation chords resolve locally"
else
  fail occur-bindings "one or more Occur mode bindings diverged: $occur_bindings"
fi

lem_keys "$session" g j
first_occur=$(report_occur || true)
if [[ "$first_occur" == *'current=*Occur*'* ]] &&
   [[ "$first_occur" == *'row-source=buffer-list-occur-alpha row-line=2 target-count=1'* ]] &&
   [[ "$first_occur" == *'windows='*'buffer-list-occur-alpha'* ]]; then
  pass occur-next-noselect "gj moved to and displayed the first source without leaving Occur"
else
  fail occur-next-noselect "gj selected or targeted the wrong occurrence: $first_occur"
fi

lem_keys "$session" M-Enter
displayed_occur=$(report_occur || true)
if [[ "$displayed_occur" == *'current=*Occur*'* ]] &&
   [[ "$displayed_occur" == *'row-source=buffer-list-occur-alpha row-line=2'* ]] &&
   [[ "$displayed_occur" == *'windows='*'buffer-list-occur-alpha'* ]]; then
  pass occur-meta-display "M-Return displayed the current source while retaining Occur focus"
else
  fail occur-meta-display "M-Return changed selection or source: $displayed_occur"
fi

lem_keys "$session" g j
second_occur=$(report_occur || true)
if [[ "$second_occur" == *'row-source=buffer-list-occur-alpha row-line=5 target-count=2'* ]]; then
  pass occur-grouped-line "gj treated two matches on one source line as one navigable Occur row"
else
  fail occur-grouped-line "same-line matches were not grouped: $second_occur"
fi

source=$(visit_occur_source || true)
if [[ "$source" == 'OCCUR-VISIT current=buffer-list-occur-alpha line=5 column=0' ]]; then
  pass occur-visit "Return selected the exact first match point in the source buffer"
else
  fail occur-visit "Return visited the wrong source position: $source"
fi

# An uppercase regexp is case-sensitive under Emacs smart-case rules.  With no
# ordinary marks, O must manufacture and retain the current row's > mark.
lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-alpha'
lem_keys "$session" Enter O C-a C-k
tmux_cmd send-keys -t "$session" -l 'Needle'
lem_keys "$session" Enter
if lem_wait_for "$session" 'Searched 1 buffer; 1 match for "Needle"' 15 >/dev/null; then
  implicit_nav=$(report_nav || true)
  if [[ "$implicit_nav" == *'marks=buffer-list-occur-alpha:>'* ]]; then
    pass occur-current-fallback "unmarked O searched and visibly marked only the current row"
  else
    fail occur-current-fallback "O did not retain GNU's implicit ordinary mark: $implicit_nav"
  fi
else
  fail occur-current-fallback "the smart-case single-buffer Occur did not complete"
fi

select_occur_buffer
upper_occur=$(report_occur || true)
if [[ "$upper_occur" == *'1 match for "Needle" in buffer: buffer-list-occur-alpha\n'* ]] &&
   [[ "$upper_occur" == *'      2:Needle alpha mixed\n'* ]] &&
   [[ "$upper_occur" != *'needle alpha and needle again'* ]] &&
   [[ "$upper_occur" != *'NEEDLE beta upper'* ]]; then
  pass occur-smart-case "uppercase input matched case-sensitively"
else
  fail occur-smart-case "uppercase smart-case rendering diverged: $upper_occur"
fi

# CL-PPCRE's user-facing syntax supports a newline escape, and multi-line
# matches should render every covered line while remaining one navigation item.
lem_keys "$session" Enter C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-alpha'
lem_keys "$session" Enter O C-a C-k
tmux_cmd send-keys -t "$session" -l 'multi start\nfinish token'
lem_keys "$session" Enter
if lem_wait_for "$session" 'Searched 1 buffer; 1 match' 15 >/dev/null; then
  select_occur_buffer
  multiline=$(report_occur || true)
  lem_keys "$session" g j
  multiline_first=$(report_occur || true)
  lem_keys "$session" g j
  if lem_wait_for "$session" 'No more matches' 10 >/dev/null; then
    multiline_after=$(report_occur || true)
    if [[ "$multiline" == *'      7:multi start\n       :finish token\n'* ]] &&
       [[ "$multiline_first" == *'row-source=buffer-list-occur-alpha row-line=7 target-count=1'* ]] &&
       [[ "$multiline_after" == *'row-source=buffer-list-occur-alpha row-line=7 target-count=1'* ]]; then
      pass occur-multiline "multi-line output retained one source target and next-error skipped its continuation row"
    else
      fail occur-multiline "multi-line rendering or navigation diverged: $multiline / $multiline_first / $multiline_after"
    fi
  else
    fail occur-multiline "gj treated a multi-line continuation as another occurrence"
  fi
else
  fail occur-multiline "the multi-line regexp did not produce an Occur result"
fi

# Occur source positions are live points, as GNU Occur markers are.  An edit
# before a match must move its destination without requiring a rerender.
lem_keys "$session" F7
shifted_occur=$(report_occur || true)
if [[ "$shifted_occur" == *'row-source=buffer-list-occur-alpha row-line=8 target-count=1'* ]]; then
  pass occur-live-point "an insertion before the source match advanced the retained Occur target"
else
  fail occur-live-point "the Occur target did not track a source edit: $shifted_occur"
fi

# A malformed replacement search must not destroy the last useful result.
lem_keys "$session" Enter C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-alpha'
lem_keys "$session" Enter O C-a C-k
tmux_cmd send-keys -t "$session" -l '['
lem_keys "$session" Enter
invalid_occur_nav=$(report_nav || true)
select_occur_buffer
invalid_occur=$(report_occur || true)
if [[ "$invalid_occur_nav" == *'marks=buffer-list-occur-alpha:>'* ]] &&
   [[ "$invalid_occur" == *'1 match for "multi start\\\\nfinish token"'* ]] &&
   [[ "$invalid_occur" == *'row-source=buffer-list-occur-alpha row-line=8 target-count=1'* ]]; then
  pass occur-invalid-preserves "an invalid regexp retained the previous result and implicit ordinary mark"
else
  fail occur-invalid-preserves "an invalid regexp damaged Occur state: $invalid_occur_nav / $invalid_occur"
fi

occur_bounds=$(report_occur_bounds || true)
if [[ "$occur_bounds" == 'OCCUR-BOUNDS per=yes total=yes preserved=yes' ]]; then
  pass occur-resource-bounds "per-buffer and aggregate limits refused before replacing the prior result"
else
  fail occur-resource-bounds "one or more Occur resource bounds failed: $occur_bounds"
fi

# A successful zero-match search removes the owned stale result, matching GNU
# Occur rather than leaving misleading navigation behind.
lem_keys "$session" q C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-alpha'
lem_keys "$session" Enter M-s a C-o C-a C-k
tmux_cmd send-keys -t "$session" -l 'definitely-no-occurrence'
lem_keys "$session" Enter
if lem_wait_for "$session" 'no matches for "definitely-no-occurrence"' 15 >/dev/null; then
  lem_keys "$session" q
  no_match_occur=$(report_occur_global || true)
  if [[ "$no_match_occur" == *'live=no '* ]]; then
    pass occur-no-match-cleanup "a zero-match search killed the owned stale Occur result"
  else
    fail occur-no-match-cleanup "the stale Occur buffer survived a zero-match search: $no_match_occur"
  fi
else
  fail occur-no-match-cleanup "the zero-match search did not complete"
fi

# If the existing owned result is itself a source, a zero-match search must
# rename and retain that source rather than mistaking it for stale output.
lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-alpha'
lem_keys "$session" Enter O C-a C-k
tmux_cmd send-keys -t "$session" -l 'Needle'
lem_keys "$session" Enter
if lem_wait_for "$session" 'Searched 1 buffer; 1 match for "Needle"' 15 >/dev/null; then
  select_occur_buffer
  source_zero=$(report_occur_source_zero || true)
  if [[ "$source_zero" == 'OCCUR-SOURCE-ZERO source-live=yes canonical-live=no renamed=yes' ]]; then
    pass occur-source-zero-match "a zero-match search retained and uniquely renamed its owned source"
  else
    fail occur-source-zero-match "the owned source was lost or retained the output name: $source_zero"
  fi
else
  fail occur-source-zero-match "the source-safety fixture result was not created"
fi

# Recreate one result, kill its source, and prove navigation fails closed while
# retaining the persistent result buffer for inspection.
lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'buffer-list-occur-alpha'
lem_keys "$session" Enter O C-a C-k
tmux_cmd send-keys -t "$session" -l 'Needle'
lem_keys "$session" Enter
if lem_wait_for "$session" 'Searched 1 buffer; 1 match for "Needle"' 15 >/dev/null; then
  select_occur_buffer
  lem_keys "$session" g j F6 Enter
  if lem_wait_for "$session" 'Buffer for this occurrence was killed' 15 >/dev/null; then
    stale_occur=$(report_occur || true)
    if [[ "$stale_occur" == *'current=*Occur*'* ]] &&
       [[ "$stale_occur" == *'row-line=-1 target-count=1'* ]]; then
      pass occur-killed-source "navigation refused a killed source without leaving the Occur result"
    else
      fail occur-killed-source "killed-source refusal left unexpected state: $stale_occur"
    fi
  else
    fail occur-killed-source "Return did not reject the killed Occur source"
  fi
else
  fail occur-killed-source "the stale-source fixture result was not created"
fi

if ((failed)); then
  printf '\nBUFFER LIST TEST FAILED\n'
  exit 1
fi

printf '\nBUFFER LIST TEST PASSED\n'
