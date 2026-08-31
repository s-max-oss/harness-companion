#!/bin/bash
# F-CONV-07: prove the real executor selects and emits the correct typed files.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INIT="$ROOT/scripts/harness-init.sh"
FIXTURE="$ROOT/tests/init/fixtures/type-command-whitelist.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
EXEC_TRACE="$TMP/executed-commands.log"
SHADOW_TRACE="$TMP/shadow-tool-hits.log"
SHADOW_BIN="$TMP/shadow-bin"
mkdir -p "$SHADOW_BIN"
: > "$EXEC_TRACE"
: > "$SHADOW_TRACE"

for tool in npm npm.cmd npx npx.cmd tsc pip pip3 pytest python python3 cargo rustc go make shellcheck curl wget ruby bundle gradle gradlew mvn dotnet; do
  printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "$HARNESS_EXEC_TRACE"\nexit 97\n' "$tool" > "$SHADOW_BIN/$tool"
  chmod +x "$SHADOW_BIN/$tool"
done

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1${2:+ — $2}"; }

check() {
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

brief() {
  local path="$1" dtype="$2"
  jq -n --arg dtype "$dtype" '{
    schema_version: 1,
    detected_type: $dtype,
    goal: "Verify deterministic typed output",
    success_criteria: ["Generated files match the selected project type"],
    cadence: "stable",
    deadline: null,
    stack: $dtype,
    test_framework: "unspecified",
    secrets_handling: "unspecified",
    external_network: "ask",
    prohibitions: [],
    operation_preferences: {
      commit: "ask", push: "ask", merge: "ask", release: "ask",
      install_packages: "ask", external_mutation: "ask",
      destructive_ops: false
    },
    defaults_applied: [],
    conflicts_resolved: [],
    provenance: {},
    type_evidence: null
  }' > "$path"
}

contains_marker() {
  local marker="$1"
  shift
  grep -qE -- "(^|[^[:alnum:]_])${marker}([^[:alnum:]_]|$)" "$@" 2>/dev/null
}

if ! jq -e '
  .schema_version == 2
  and (.types | type == "array" and length == 7)
  and ([.types[].detected_type] | sort == (["docs","electron","go","node","python","rust","shell"] | sort))
  and all(.types[];
    (.detected_type | type == "string")
    and (.project_type | IN("node","python","rust","go","docs","generic"))
    and (.files | type == "object" and (keys | sort) == ([".harness/config.json","AGENTS.md","CLAUDE.md","checklist.sh","init.sh"] | sort))
    and all(.files[]; type == "string" and test("^[0-9a-f]{64}$"))
    and (.required | type == "array")
    and (.forbidden | type == "array"))
' "$FIXTURE" >/dev/null; then
  fail "type-command whitelist fixture is valid"
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi
pass "type-command whitelist fixture is valid"

while IFS= read -r row; do
  dtype="$(printf '%s' "$row" | jq -r '.detected_type')"
  expected_project_type="$(printf '%s' "$row" | jq -r '.project_type')"
  target="$TMP/$dtype"
  brief_path="$TMP/$dtype-brief.json"
  mkdir -p "$target"
  brief "$brief_path" "$dtype"

  if output="$(HARNESS_EXEC_TRACE="$SHADOW_TRACE" PATH="$SHADOW_BIN:$PATH" \
      PS4='TRACE|${BASH_SOURCE}:${LINENO}|' BASH_XTRACEFD=9 \
      bash -x "$INIT" "$target" --brief "$brief_path" --non-interactive --host=claude --full \
      9>>"$EXEC_TRACE" 2>&1)"; then
    pass "$dtype executor completes"
  else
    fail "$dtype executor completes" "$(printf '%s' "$output" | tail -n 1)"
    continue
  fi

  check "$dtype canonical Brief keeps detected type" \
    test "$(jq -r '.detected_type' "$target/.harness/PROJECT_BRIEF.json")" = "$dtype"
  check "$dtype config maps to supported project_type" \
    test "$(jq -r '.project_type' "$target/.harness/config.json")" = "$expected_project_type"
  check "$dtype config is the mapped config template" \
    cmp -s "$target/.harness/config.json" "$ROOT/templates/.harness/config.json.$expected_project_type.example"

  # The fixture is the independent, exhaustive white-list: an unexpected byte
  # in any type-sensitive generated file (including a foreign command) changes
  # its SHA and fails. Template comparisons below separately verify selection.
  while IFS=$'\t' read -r file expected_sha; do
    expected_sha="${expected_sha//$'\r'/}"
    # Normalize only line endings so the allow-list represents tracked text
    # bytes and remains stable across core.autocrlf hosts.
    actual_sha="$(sed 's/\r$//' "$target/$file" | sha256sum | awk '{print $1}')"
    check "$dtype allowlisted SHA for $file" test "$actual_sha" = "$expected_sha"
  done < <(printf '%s' "$row" | jq -r '.files | to_entries[] | [.key,.value] | @tsv')

  for file in init.sh AGENTS.md CLAUDE.md; do
    check "$dtype generated $file matches typed template" \
      cmp -s "$target/$file" "$ROOT/templates/by-type/$dtype/$file"
    check "$dtype snapshot records typed source for $file" \
      test "$(jq -r --arg file "$file" '.templates[$file].source' "$target/.harness/.template-snapshot.json")" = "by-type/$dtype/$file"
  done
  check "$dtype generated checklist.sh matches common fallback" \
    cmp -s "$target/checklist.sh" "$ROOT/templates/common/checklist.sh"
  check "$dtype snapshot records common source for checklist.sh" \
    test "$(jq -r '.templates["checklist.sh"].source' "$target/.harness/.template-snapshot.json")" = "common/checklist.sh"

  while IFS= read -r marker; do
    marker="${marker//$'\r'/}"
    if contains_marker "$marker" "$target/init.sh" "$target/AGENTS.md" "$target/CLAUDE.md" "$target/checklist.sh"; then
      pass "$dtype generated files contain required tool $marker"
    else
      fail "$dtype generated files contain required tool $marker"
    fi
  done < <(printf '%s' "$row" | jq -r '.required[]')

  while IFS= read -r marker; do
    marker="${marker//$'\r'/}"
    if contains_marker "$marker" "$target/init.sh" "$target/AGENTS.md" "$target/CLAUDE.md" "$target/checklist.sh"; then
      fail "$dtype generated files exclude foreign tool $marker"
    else
      pass "$dtype generated files exclude foreign tool $marker"
    fi
  done < <(printf '%s' "$row" | jq -r '.forbidden[]')
done < <(jq -c '.types[]' "$FIXTURE")

if [ -s "$SHADOW_TRACE" ]; then
  fail "executor never runs a PATH-resolved project tool" "executed: $(tr '\n' ' ' < "$SHADOW_TRACE")"
else
  pass "executor never runs a PATH-resolved project tool"
fi
if grep -Eq '^T*TRACE\|' "$EXEC_TRACE"; then
  pass "executor records every Bash command through xtrace"
else
  fail "executor records every Bash command through xtrace"
fi
# Reduce every traced shell command to executable basenames. Assignment
# prefixes are skipped; execution wrappers are recorded and scanning continues
# to their payload. This catches `FOO=1 /abs/npm`, `env npm`, `command npm`, and
# Windows .cmd/.exe spellings without treating ordinary arguments as commands.
TRACE_HEADS="$TMP/trace-heads.log"
TRACE_PARSER="$TMP/trace-heads.awk"
cat > "$TRACE_PARSER" <<'AWK'
# POSIX-awk shell lexer for the command portion of Bash xtrace records. Tests
# intentionally cannot depend on Python/Node. This recognizes the quoting and
# escaping Bash emits in xtrace, then follows only execution-wrapper payloads.
function clear_array(array, key) {
  for (key in array) delete array[key]
}

function shell_split(text, out,    i, ch, quote, escaped, token, started, count) {
  clear_array(out)
  quote = ""
  escaped = 0
  token = ""
  started = 0
  count = 0
  for (i = 1; i <= length(text); i++) {
    ch = substr(text, i, 1)
    if (escaped) {
      token = token ch
      started = 1
      escaped = 0
    } else if (quote == "'") {
      if (ch == "'") quote = ""
      else token = token ch
      started = 1
    } else if (quote == "\"") {
      if (ch == "\"") quote = ""
      else if (ch == "\\") escaped = 1
      else token = token ch
      started = 1
    } else if (ch == "\\") {
      escaped = 1
      started = 1
    } else if (ch == "'" || ch == "\"") {
      # Bash may render ANSI-C strings as $'...'. The payloads relevant to
      # executable detection need no escape decoding, but '$' is not literal.
      if (ch == "'" && token == "$") token = ""
      quote = ch
      started = 1
    } else if (ch ~ /[[:space:]]/) {
      if (started) {
        out[++count] = token
        token = ""
        started = 0
      }
    } else {
      token = token ch
      started = 1
    }
  }
  if (escaped || quote != "") {
    print "FATAL: unparseable xtrace command: " text > "/dev/stderr"
    exit 2
  }
  if (started) out[++count] = token
  return count
}

function executable_basename(token,    parts, count, name) {
  gsub(/\\/, "/", token)
  count = split(token, parts, "/")
  name = tolower(parts[count])
  sub(/\.exe$/, "", name)
  return name
}

function splice_split(pos, removed, payload,    split_tokens, split_count, delta, i) {
  split_count = shell_split(payload, split_tokens)
  delta = split_count - removed
  if (delta > 0) {
    for (i = token_count; i >= pos + removed; i--) tokens[i + delta] = tokens[i]
  } else if (delta < 0) {
    for (i = pos + removed; i <= token_count; i++) tokens[i + delta] = tokens[i]
    for (i = token_count + delta + 1; i <= token_count; i++) delete tokens[i]
  }
  for (i = 1; i <= split_count; i++) tokens[pos + i - 1] = split_tokens[i]
  token_count += delta
}

function emit_heads(command,    i, token, head, payload) {
  token_count = shell_split(command, tokens)
  i = 1
  while (i <= token_count) {
    while (i <= token_count && tokens[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) i++
    if (i > token_count) return
    head = executable_basename(tokens[i])
    print head
    i++

    if (head == "env") {
      while (i <= token_count) {
        token = tokens[i]
        if (token ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
        if (token == "--") { i++; break }
        if (token == "--help" || token == "--version") return
        if (token == "-S" || token == "--split-string") {
          if (i + 1 > token_count) return
          payload = tokens[i + 1]
          splice_split(i, 2, payload)
          continue
        }
        if (token ~ /^--split-string=/) {
          payload = token
          sub(/^--split-string=/, "", payload)
          splice_split(i, 1, payload)
          continue
        }
        if (token ~ /^-S./) {
          payload = substr(token, 3)
          splice_split(i, 1, payload)
          continue
        }
        if (token == "-u" || token == "--unset" || token == "-C" ||
            token == "--chdir" || token == "--argv0") {
          if (i + 1 > token_count) return
          i += 2
          continue
        }
        if (token ~ /^--(unset|chdir|argv0)=/ || token ~ /^-/) { i++; continue }
        break
      }
      continue
    }

    if (head == "command") {
      while (i <= token_count) {
        token = tokens[i]
        if (token == "--") { i++; break }
        if (token == "-v" || token == "-V") return
        if (token ~ /^-/) { i++; continue }
        break
      }
      continue
    }

    if (head == "exec") {
      while (i <= token_count) {
        token = tokens[i]
        if (token == "--") { i++; break }
        if (token == "-a" || token == "--argv0") {
          if (i + 1 > token_count) return
          i += 2
          continue
        }
        if (token ~ /^--argv0=/ || token == "-c" || token == "-l") { i++; continue }
        if (token ~ /^-/) return
        break
      }
      continue
    }

    if (head == "builtin") {
      while (i <= token_count && tokens[i] ~ /^-/) {
        if (tokens[i] == "--help") return
        i++
      }
      continue
    }

    if (head == "nohup") {
      if (i <= token_count && tokens[i] == "--") i++
      else if (i <= token_count && tokens[i] ~ /^-/) return
      continue
    }
    return
  }
}

function flush_record() {
  if (have_record) emit_heads(record)
  record = ""
  have_record = 0
}

{
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^T*TRACE\|[^|]*\|/) {
    flush_record()
    sub(/^T*TRACE\|[^|]*\|/, "", line)
    record = line
    have_record = 1
  } else if (have_record) {
    # Quoted assignments can span physical xtrace lines.
    record = record "\n" line
  }
}

END { flush_record() }
AWK

extract_trace_heads() {
  awk -f "$TRACE_PARSER" "$1"
}
extract_trace_heads "$EXEC_TRACE" > "$TRACE_HEADS"
PROHIBITED_HEADS='^(npm(\.cmd)?|npx(\.cmd)?|tsc|pip3?|pytest|python3?|cargo|rustc|go|make|shellcheck|curl|wget|ruby|bundle|gradle(w)?|mvn|dotnet)$'

# Parser regressions must fail independently of the product path: prove all
# wrapper/assignment/absolute forms reduce to a prohibited executable basename.
SYNTHETIC_TRACE="$TMP/synthetic-trace.log"
cat > "$SYNTHETIC_TRACE" <<'EOF'
TRACE|fixture:1|FOO=1 /opt/tools/npm --version
TRACE|fixture:2|env -u FOO BAR=2 npm test
TRACE|fixture:3|command C:/tools/npm.cmd run check
TRACE|fixture:4|exec -a alias /opt/tools/npm test
TRACE|fixture:5|builtin command npm test
TRACE|fixture:6|nohup '/opt/tools with spaces/npm' test
TRACE|fixture:7|env -S '/opt/tools/npm test'
TRACE|fixture:8|env '--split-string=/opt/tools/npm test'
EOF
SYNTHETIC_HEADS="$TMP/synthetic-heads.log"
extract_trace_heads "$SYNTHETIC_TRACE" > "$SYNTHETIC_HEADS"
EXPECTED_SYNTHETIC_HEADS=$'npm\nenv\nnpm\ncommand\nnpm.cmd\nexec\nnpm\nbuiltin\ncommand\nnpm\nnohup\nnpm\nenv\nnpm\nenv\nnpm'
if [ "$(<"$SYNTHETIC_HEADS")" = "$EXPECTED_SYNTHETIC_HEADS" ]; then
  pass "xtrace parser catches assignments, wrapper options, split strings, and quoted absolute project-tool forms"
else
  fail "xtrace parser catches assignments, wrapper options, split strings, and quoted absolute project-tool forms" "$(tr '\n' ' ' < "$SYNTHETIC_HEADS")"
fi
SYNTHETIC_NON_EXEC_TRACE="$TMP/synthetic-non-exec-trace.log"
printf '%s\n' 'TRACE|fixture:9|nohup --help npm' > "$SYNTHETIC_NON_EXEC_TRACE"
SYNTHETIC_NON_EXEC_HEADS="$TMP/synthetic-non-exec-heads.log"
extract_trace_heads "$SYNTHETIC_NON_EXEC_TRACE" > "$SYNTHETIC_NON_EXEC_HEADS"
if [ "$(<"$SYNTHETIC_NON_EXEC_HEADS")" = "nohup" ]; then
  pass "xtrace parser does not treat nohup terminal-option arguments as an executed payload"
else
  fail "xtrace parser does not treat nohup terminal-option arguments as an executed payload" "$(tr '\n' ' ' < "$SYNTHETIC_NON_EXEC_HEADS")"
fi
if grep -Ei "$PROHIBITED_HEADS" "$TRACE_HEADS" >/dev/null; then
  fail "xtrace contains no project-tool execution" "$(grep -Ei "$PROHIBITED_HEADS" "$TRACE_HEADS" | head -3)"
else
  pass "xtrace contains no project-tool execution"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
