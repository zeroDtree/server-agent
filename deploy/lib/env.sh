# Env-file merge helpers for deploy/install.sh.
# Source this file; it defines functions only.

if [[ "$(type -t log 2>/dev/null || true)" != function ]]; then
  log() { printf '==> %s\n' "$*"; }
fi
if [[ "$(type -t die 2>/dev/null || true)" != function ]]; then
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
fi

# Print KEY when LINE is an assignment or a commented assignment declaration.
# Matches: KEY=..., # KEY=..., #KEY=...
declared_env_key() {
  local line="$1"
  if [[ "$line" =~ ^[[:space:]]*#?[[:space:]]*([A-Z][A-Z0-9_]*)= ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

is_safe_env_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Z][A-Z0-9_]*$ ]]
}

# True when the named variable is set in this process (including empty).
is_env_set() {
  local name="$1"
  is_safe_env_name "$name" || die "Invalid environment variable name: ${name}"
  eval "test \"\${${name}+x}\" = x"
}

env_value() {
  local name="$1"
  is_safe_env_name "$name" || die "Invalid environment variable name: ${name}"
  eval "printf '%s' \"\${${name}}\""
}

env_file_has_assignment() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] && grep -q "^${key}=" "$file"
}

env_file_has_declaration() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] && grep -Eq "^[[:space:]]*#?[[:space:]]*${key}=" "$file"
}

# Double-quote a value for systemd EnvironmentFile. Rejects CR/LF.
quote_systemd_env_value() {
  local value="$1"
  case "$value" in
    *$'\n'*|*$'\r'*)
      die "Environment value contains a newline or carriage return"
      ;;
  esac
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

# Write KEY="quoted" to FILE, replacing any existing KEY= assignment.
set_env_assignment() {
  local file="$1"
  local key="$2"
  local value="$3"
  local quoted line tmp

  is_safe_env_name "$key" || die "Invalid environment variable name: ${key}"
  quoted="$(quote_systemd_env_value "$value")"
  line="${key}=${quoted}"
  tmp="$(mktemp "${file}.XXXXXX")"

  if env_file_has_assignment "$file" "$key"; then
    KEY="$key" LINE="$line" awk '
      $0 ~ "^" ENVIRON["KEY"] "=" {
        if (!found) { print ENVIRON["LINE"]; found=1 }
        next
      }
      { print }
    ' "$file" > "$tmp"
  else
    if [[ -f "$file" ]]; then
      cat "$file" > "$tmp"
    else
      : > "$tmp"
    fi
    printf '%s\n' "$line" >> "$tmp"
  fi
  mv "$tmp" "$file"
}

# Write KEY -> last example line into OUT_DIR/KEY; unique keys in first-seen order to ORDER_FILE.
collect_example_declarations() {
  local example="$1"
  local out_dir="$2"
  local order_file="$3"
  local line key

  [[ -f "$example" ]] || die "Missing env example: ${example}"
  : > "$order_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    key="$(declared_env_key "$line")" || continue
    if [[ ! -f "${out_dir}/${key}" ]]; then
      printf '%s\n' "$key" >> "$order_file"
    fi
    printf '%s\n' "$line" > "${out_dir}/${key}"
  done < "$example"
}

append_missing_example_keys() {
  local dest="$1"
  local example="$2"
  local tmp_dir order_file key line added

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/env-decl.XXXXXX")"
  order_file="${tmp_dir}/order"
  collect_example_declarations "$example" "$tmp_dir" "$order_file"

  added=0
  while IFS= read -r key || [[ -n "$key" ]]; do
    [[ -n "$key" ]] || continue
    if env_file_has_declaration "$dest" "$key"; then
      continue
    fi
    line="$(cat "${tmp_dir}/${key}")"
    printf '%s\n' "$line" >> "$dest"
    added=$((added + 1))
  done < "$order_file"

  rm -rf "$tmp_dir"
  if [[ "$added" -gt 0 ]]; then
    log "Merged ${added} missing key(s) into ${dest}"
  fi
}

apply_declared_env_overrides() {
  local dest="$1"
  local example="$2"
  local tmp_dir order_file key applied

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/env-ov.XXXXXX")"
  order_file="${tmp_dir}/order"
  collect_example_declarations "$example" "$tmp_dir" "$order_file"

  applied=""
  while IFS= read -r key || [[ -n "$key" ]]; do
    [[ -n "$key" ]] || continue
    if is_env_set "$key"; then
      set_env_assignment "$dest" "$key" "$(env_value "$key")"
      if [[ -n "$applied" ]]; then
        applied="${applied} ${key}"
      else
        applied="$key"
      fi
    fi
  done < "$order_file"

  rm -rf "$tmp_dir"
  if [[ -n "$applied" ]]; then
    log "Applied environment overrides in ${dest}: ${applied}"
  fi
}

# Create DEST from EXAMPLE if missing; otherwise keep assignments and fill gaps.
# Then persist any process environment values for keys declared in EXAMPLE.
merge_env_file() {
  local dest="$1"
  local example="$2"

  [[ -f "$example" ]] || die "Missing env example: ${example}"
  mkdir -p "$(dirname "$dest")"

  if [[ ! -f "$dest" ]]; then
    cp "$example" "$dest"
    log "Created ${dest} from $(basename "$example")"
  else
    append_missing_example_keys "$dest" "$example"
  fi
  chmod 600 "$dest"
  apply_declared_env_overrides "$dest" "$example"
}
