#!/usr/bin/env bash
# shellcheck shell=bash
# Subset TOML reader. One parser: strings (basic, literal, multi-line), true and
# false, whole numbers, and one-line arrays of those.
#
# toml_records FILE
#   One JSON line per key, in file order; "line" is its line number:
#     {"section":[...],"key":"...","value":...,"line":N}
#     {"section":[...],"key":"...","raw":"...","line":N}   a value outside the
#       subset, as written (a bare word, 1.5, a nested array)
#     {"section":[...]|null,"error":"...","line":N}        a line it cannot read
#   Root section is []. A quoted path is one component. ~/ is not expanded.
#   A bad line warns nowhere; the caller decides what to say. CRLF line ends
#   and a leading BOM are dropped. Status 1 if FILE is missing.
# toml_get FILE SECTION KEY
#   JSON value. SECTION is the same dotted name as a header (layout,
#   policy."~/Work/a.b"). Status 1 if the file, section, or key is missing.
#   Status 2 for a raw value, which is printed as written.
# toml_value FILE SECTION KEY [DEFAULT]
#   toml_get decoded: strings, numbers, and bools raw; arrays compact JSON; a
#   raw value as written, for the caller's own check to name. Missing prints
#   DEFAULT (empty if omitted) and returns 0, so an optional key does not trip
#   errexit.

_toml_die() {
  printf 'bercail toml: %s\n' "$*" >&2
  return 1
}

_toml_awk() {
  # $1 mode (records|get), $2 file, $3 section arg, $4 key
  awk -v mode="$1" -v file="$2" -v section_arg="${3-}" -v want_key="${4-}" '
    function jstr(s,   out, i, c) {
      gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s)
      gsub(/\r/, "\\r", s); gsub(/\n/, "\\n", s)
      if (s !~ /[\001-\037]/) return "\"" s "\""
      out = ""
      for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); out = out (c in ctl ? ctl[c] : c) }
      return "\"" out "\""
    }
    function unesc(s,   out, i, c, n) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c != "\\") { out = out c; continue }
        n = substr(s, ++i, 1)
        if (n == "n") out = out "\n"
        else if (n == "t") out = out "\t"
        else if (n == "r") out = out "\r"
        else if (n == "\"" || n == "\\") out = out n
        else if (n == "\n") { while (substr(s, i + 1, 1) ~ /[ \t\n]/) i++ }
        else out = out "\\" n
      }
      return out
    }
    function bad(why) {
      if (mode == "records")
        print "{\"section\":" (skip ? "null" : section_json) ",\"error\":" jstr(why) ",\"line\":" NR "}"
    }
    function read_str(s, i, q,   n, c, out) {
      n = length(s); i++
      out = ""
      while (i <= n) {
        c = substr(s, i, 1)
        if (q == "\047") {
          if (c == "\047") { parsed = out; ni = i + 1; return 1 }
          out = out c; i++; continue
        }
        if (c == "\\") {
          if (i >= n) return 0
          i++; c = substr(s, i, 1)
          if (c == "n") out = out "\n"
          else if (c == "t") out = out "\t"
          else if (c == "r") out = out "\r"
          else if (c == "\"" || c == "\\") out = out c
          else out = out "\\" c
          i++; continue
        }
        if (c == "\"") { parsed = out; ni = i + 1; return 1 }
        out = out c; i++
      }
      return 0
    }
    function parse_name(s,   i, n, c, comp, parts) {
      n = length(s); i = 1; parts = ""
      while (1) {
        while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
        if (i > n || substr(s, i, 1) == "]") break
        c = substr(s, i, 1)
        if (c == "\"" || c == "\047") {
          if (!read_str(s, i, c)) return 0
          comp = parsed; i = ni
        } else if (c ~ /[A-Za-z0-9_-]/) {
          comp = ""
          while (i <= n && substr(s, i, 1) ~ /[A-Za-z0-9_-]/) {
            comp = comp substr(s, i, 1); i++
          }
        } else return 0
        parts = parts (parts == "" ? "" : ",") jstr(comp)
        while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
        if (i <= n && substr(s, i, 1) == ".") { i++; continue }
        break
      }
      name_json = "[" parts "]"; name_end = i
      return 1
    }
    function section_ok(s,   i, n) {
      if (!parse_name(s)) return 0
      i = name_end; n = length(s)
      while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
      return i > n
    }
    function rest_ok(s) { return s ~ /^[ \t]*(#.*)?$/ }
    function emit(key, val, kind) {
      if (skip) return
      if (kind == "") kind = "value"
      if (mode == "records")
        print "{\"section\":" section_json ",\"key\":" jstr(key) ",\"" kind "\":" (kind == "raw" ? jstr(val) : val) ",\"line\":" NR "}"
      else if (section_json == want_section && key == want_key) {
        found = 1; got = val; got_kind = kind
      }
    }
    function emit_raw(key, s) { sub(/[ \t]+$/, "", s); emit(key, s, "raw") }
    function read_array(s,   i, n, c, parts, elem, tok) {
      n = length(s); i = 2; parts = ""
      while (1) {
        while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
        if (i <= n && substr(s, i, 1) == "]") { i++; break }
        if (i > n) return 0
        c = substr(s, i, 1)
        if (c == "[") return 0
        if (c == "\"" || c == "\047") {
          if (!read_str(s, i, c)) return 0
          elem = jstr(parsed); i = ni
        } else {
          tok = ""
          while (i <= n && substr(s, i, 1) !~ /[,\] \t]/) {
            tok = tok substr(s, i, 1); i++
          }
          if (tok == "true" || tok == "false" || tok ~ /^-?(0|[1-9][0-9]*)$/) elem = tok
          else return 0
        }
        parts = parts (parts == "" ? "" : ",") elem
        while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
        if (i <= n && substr(s, i, 1) == ",") {
          i++
          while (i <= n && substr(s, i, 1) ~ /[ \t]/) i++
          if (i <= n && substr(s, i, 1) == "]") return 0
          continue
        }
        if (i <= n && substr(s, i, 1) == "]") { i++; break }
        return 0
      }
      if (!rest_ok(substr(s, i))) return 0
      arr_json = "[" parts "]"
      return 1
    }
    BEGIN {
      for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = sprintf("\\u%04x", i)
      section_json = "[]"; skip = 0; found = 0
      if (mode == "get") {
        if (!section_ok(section_arg)) exit 1
        want_section = name_json
      }
    }
    { sub(/\r$/, "") }
    NR == 1 { sub(/^\357\273\277/, "") }
    ml != "" {
      i = index($0, ml)
      if (!i) { buf = buf $0 "\n"; next }
      buf = buf substr($0, 1, i - 1)
      if (!mlskip) emit(mlkey, jstr(ml == "\047\047\047" ? buf : unesc(buf)))
      ml = ""; mlskip = 0
      next
    }
    /^[ \t]*(#|$)/ { next }
    /^[ \t]*\[/ {
      h = $0
      sub(/^[ \t]*\[/, "", h)
      if (!parse_name(h) || substr(h, name_end, 1) != "]" || !rest_ok(substr(h, name_end + 1))) {
        skip = 1; bad("malformed table"); next
      }
      section_json = name_json; skip = 0
      next
    }
    {
      s = $0
      sub(/^[ \t]*/, "", s)
      if (substr(s, 1, 1) == "\"" || substr(s, 1, 1) == "\047") {
        if (!read_str(s, 1, substr(s, 1, 1))) { bad("malformed key"); next }
        key = parsed; s = substr(s, ni)
      } else if (match(s, /^[A-Za-z0-9_-]+/)) {
        key = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
      } else { bad("not a key = value line"); next }
      sub(/^[ \t]*/, "", s)
      if (substr(s, 1, 1) != "=") { bad("not a key = value line"); next }
      s = substr(s, 2); sub(/^[ \t]*/, "", s)
      q3 = substr(s, 1, 3)
      if (q3 == "\"\"\"" || q3 == "\047\047\047") {
        v = substr(s, 4)
        i = index(v, q3)
        if (i) {
          body = substr(v, 1, i - 1)
          if (!rest_ok(substr(v, i + 3))) { bad("malformed value"); next }
          if (!skip) emit(key, jstr(q3 == "\047\047\047" ? body : unesc(body)))
          next
        }
        ml = q3; mlkey = key; mlskip = skip
        buf = (v == "" ? "" : v "\n")
        next
      }
      c = substr(s, 1, 1)
      if (c == "\"" || c == "\047") {
        if (!read_str(s, 1, c) || !rest_ok(substr(s, ni))) emit_raw(key, s)
        else emit(key, jstr(parsed))
      } else if (c == "[") {
        if (!read_array(s)) emit_raw(key, s)
        else emit(key, arr_json)
      } else {
        sub(/[ \t]*(#.*)?$/, "", s)
        if (s == "true" || s == "false" || s ~ /^-?(0|[1-9][0-9]*)$/) emit(key, s)
        else emit_raw(key, s)
      }
    }
    END {
      if (ml != "") bad("multi-line string for " mlkey " never closes")
      if (mode == "get") {
        if (!found) exit 1
        print got
        if (got_kind == "raw") exit 2
      }
    }
  ' "$2"
}

toml_records() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || _toml_die "no such file: ${file:-}" || return 1
  _toml_awk records "$file"
}

toml_get() {
  local file="$1" section="$2" key="$3"
  [[ -n "$file" && -f "$file" ]] || _toml_die "no such file: ${file:-}" || return 1
  [[ $# -eq 3 ]] || _toml_die "usage: toml_get FILE SECTION KEY" || return 1
  _toml_awk get "$file" "$section" "$key"
}

# Decode one value. Arrays stay compact JSON so a caller can hand them to jq.
# Anything else is the raw scalar. Missing is DEFAULT, not an error.
toml_value() {
  local file="$1" section="$2" key="$3" default="${4-}" json status=0
  json="$(toml_get "$file" "$section" "$key" 2>/dev/null)" || status=$?
  case "$status" in
    0) printf '%s' "$json" | jq -j 'if type == "array" then tojson else . end' ;;
    2) printf '%s' "$json" ;;
    *) printf '%s' "$default" ;;
  esac
}
