#!/usr/bin/env bash
# Isolated tests for deploy/lib/env.sh (no systemd, no real deploy/env/*.env).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/../lib/env.sh"

# shellcheck source=../lib/env.sh
. "${LIB}"

FAILS=0
PASSES=0

pass() {
  PASSES=$((PASSES + 1))
  printf 'ok - %s\n' "$*"
}

fail() {
  FAILS=$((FAILS + 1))
  printf 'not ok - %s\n' "$*" >&2
}

assert_eq() {
  local label="$1"
  local got="$2"
  local want="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$label"
  else
    fail "$label (got $(printf %q "$got"), want $(printf %q "$want"))"
  fi
}

assert_file_match() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if grep -Eq -- "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label (pattern ${pattern} not in ${file})"
  fi
}

assert_file_not_match() {
  local label="$1"
  local file="$2"
  local pattern="$3"
  if grep -Eq -- "$pattern" "$file"; then
    fail "$label (pattern ${pattern} unexpectedly in ${file})"
  else
    pass "$label"
  fi
}

assignment_value() {
  local file="$1"
  local key="$2"
  local raw
  raw="$(grep "^${key}=" "$file" | head -n1 | cut -d= -f2-)"
  if [[ "$raw" == \"*\" ]]; then
    raw="${raw#\"}"
    raw="${raw%\"}"
    raw="${raw//\\\"/\"}"
    raw="${raw//\\\\/\\}"
  fi
  printf '%s' "$raw"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/env-merge-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

EXAMPLE="${WORK}/app.env.example"
DEST="${WORK}/app.env"

# --- quote_systemd_env_value ---
assert_eq "quote simple" "$(quote_systemd_env_value 'hello')" '"hello"'
assert_eq "quote spaces" "$(quote_systemd_env_value 'a b')" '"a b"'
assert_eq "quote amp" "$(quote_systemd_env_value 'a&b')" '"a&b"'
assert_eq "quote quotes and backslash" "$(quote_systemd_env_value 'a b"c\d&e')" '"a b\"c\\d&e"'
assert_eq "quote empty" "$(quote_systemd_env_value '')" '""'

if (quote_systemd_env_value $'a\nb' >/dev/null 2>&1); then
  fail "quote rejects newline"
else
  pass "quote rejects newline"
fi
if (quote_systemd_env_value $'a\rb' >/dev/null 2>&1); then
  fail "quote rejects carriage return"
else
  pass "quote rejects carriage return"
fi

# --- declared_env_key ---
assert_eq "parse assignment" "$(declared_env_key 'FOO_BAR=1')" "FOO_BAR"
assert_eq "parse commented assignment" "$(declared_env_key '# OPTIONAL_KEY=/tmp/x')" "OPTIONAL_KEY"
assert_eq "parse hashed assignment" "$(declared_env_key '#KEY=1')" "KEY"
if declared_env_key '# Shared settings' >/dev/null; then
  fail "ignore prose comment"
else
  pass "ignore prose comment"
fi

# --- first create from example ---
cat > "$EXAMPLE" <<'EOF'
# header
KEEP_ME=from-example
EXISTING=example-value
# OPTIONAL_PATH=/example/optional
AGENT_HEALTH_HOST=127.0.0.1
EOF

unset KEEP_ME EXISTING OPTIONAL_PATH AGENT_HEALTH_HOST NEW_KEY || true
merge_env_file "$DEST" "$EXAMPLE"
assert_file_match "created dest copies assignment" "$DEST" '^KEEP_ME=from-example$'
assert_file_match "created dest copies comment key" "$DEST" '^# OPTIONAL_PATH=/example/optional$'

# --- keep existing, fill missing keys ---
cat > "$DEST" <<'EOF'
# user header
EXISTING=user-value
EOF
cat > "$EXAMPLE" <<'EOF'
EXISTING=example-value
KEEP_ME=from-example
# OPTIONAL_PATH=/example/optional
NEW_REQUIRED=example-new
EOF

unset KEEP_ME EXISTING OPTIONAL_PATH NEW_REQUIRED || true
merge_env_file "$DEST" "$EXAMPLE"
assert_eq "keep existing assignment" "$(assignment_value "$DEST" EXISTING)" "user-value"
assert_file_match "append missing assignment" "$DEST" '^KEEP_ME=from-example$'
assert_file_match "append missing commented key" "$DEST" '^# OPTIONAL_PATH=/example/optional$'
assert_file_match "append newly required key" "$DEST" '^NEW_REQUIRED=example-new$'
assert_file_match "preserve user comment" "$DEST" '^# user header$'

# --- explicit env overrides, including empty ---
cat > "$DEST" <<'EOF'
EXISTING=user-value
KEEP_ME=from-example
EOF
cat > "$EXAMPLE" <<'EOF'
EXISTING=example-value
KEEP_ME=from-example
# OPTIONAL_PATH=/example/optional
EMPTY_ME=not-empty
EOF

EXISTING=from-env
EMPTY_ME=
OPTIONAL_PATH='/tmp/overridden path'
unset KEEP_ME || true
merge_env_file "$DEST" "$EXAMPLE"

assert_eq "env override replaces existing" "$(assignment_value "$DEST" EXISTING)" "from-env"
assert_eq "unset env does not override" "$(assignment_value "$DEST" KEEP_ME)" "from-example"
assert_eq "empty env overrides" "$(assignment_value "$DEST" EMPTY_ME)" ""
assert_file_match "empty override is quoted" "$DEST" '^EMPTY_ME=""$'
assert_eq "commented key env override" "$(assignment_value "$DEST" OPTIONAL_PATH)" "/tmp/overridden path"
assert_file_match "commented key remains documented" "$DEST" '^# OPTIONAL_PATH=/example/optional$'

# --- special characters persisted ---
cat > "$DEST" <<'EOF'
SPECIAL=old
EOF
cat > "$EXAMPLE" <<'EOF'
SPECIAL=example
EOF
SPECIAL='a b"c\d&e'
merge_env_file "$DEST" "$EXAMPLE"
assert_file_match "special chars quoted" "$DEST" '^SPECIAL="a b\\"c\\\\d&e"$'
assert_eq "special chars round-trip" "$(assignment_value "$DEST" SPECIAL)" 'a b"c\d&e'
unset SPECIAL

# --- same key in two dest files ---
EX_A="${WORK}/a.env.example"
EX_B="${WORK}/b.env.example"
DEST_A="${WORK}/a.env"
DEST_B="${WORK}/b.env"
cat > "$EX_A" <<'EOF'
AGENT_HEALTH_HOST=127.0.0.1
ONLY_A=a
EOF
cat > "$EX_B" <<'EOF'
AGENT_HEALTH_HOST=127.0.0.1
ONLY_B=b
EOF
printf '%s\n' 'AGENT_HEALTH_HOST=old-a' > "$DEST_A"
printf '%s\n' 'AGENT_HEALTH_HOST=old-b' > "$DEST_B"
AGENT_HEALTH_HOST=0.0.0.0
ONLY_A=kept-if-unset
unset ONLY_B || true
# ONLY_A is set so it will override DEST_A; unset before merge for "keep" on ONLY_A? 
# Re-run with ONLY_A unset to verify per-file mapping.
unset ONLY_A
merge_env_file "$DEST_A" "$EX_A"
merge_env_file "$DEST_B" "$EX_B"
assert_eq "shared key overridden in file A" "$(assignment_value "$DEST_A" AGENT_HEALTH_HOST)" "0.0.0.0"
assert_eq "shared key overridden in file B" "$(assignment_value "$DEST_B" AGENT_HEALTH_HOST)" "0.0.0.0"
assert_eq "file-specific key kept when unset" "$(assignment_value "$DEST_A" ONLY_A)" "a"
assert_eq "file-specific key filled from example B" "$(assignment_value "$DEST_B" ONLY_B)" "b"
unset AGENT_HEALTH_HOST

# --- REPORT_API_URL does not force UPSTREAM_API_URL ---
COMMON_EX="${WORK}/common.env.example"
COMMON_DEST="${WORK}/common.env"
cat > "$COMMON_EX" <<'EOF'
REPORT_API_URL=http://localhost:8080
# UPSTREAM_API_URL=http://localhost:8080
AGENT_PSK=replace-with-agent-psk
EOF
printf '%s\n' 'REPORT_API_URL=http://old.example' > "$COMMON_DEST"
REPORT_API_URL='http://new.example'
unset UPSTREAM_API_URL AGENT_PSK || true
merge_env_file "$COMMON_DEST" "$COMMON_EX"
assert_eq "report url overridden" "$(assignment_value "$COMMON_DEST" REPORT_API_URL)" "http://new.example"
assert_file_not_match "upstream url not force-synced" "$COMMON_DEST" '^UPSTREAM_API_URL='
assert_file_match "upstream url stays commented from example" "$COMMON_DEST" '^# UPSTREAM_API_URL='
unset REPORT_API_URL

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%d passed, %d failed\n' "$PASSES" "$FAILS" >&2
  exit 1
fi
printf '\n%d passed\n' "$PASSES"
