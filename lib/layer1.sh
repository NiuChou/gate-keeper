#!/usr/bin/env bash
# layer1.sh — Static checks (zero external dependencies, runs locally)

gk_layer1_run() {
  gk_maybe_run "A" "go.work validation" "go_work" gk_check_go_work
  gk_maybe_run "B" "Shell script syntax" "shell_syntax" gk_check_shell_syntax
  gk_maybe_run "C" "Python packaging" "python_packaging" gk_check_python_packaging
  gk_maybe_run "D" "Dockerfile COPY paths" "dockerfile_copy" gk_check_dockerfile_copy
  gk_maybe_run "E" "Dockerfile anti-patterns" "dockerfile_antipatterns" gk_check_dockerfile_antipatterns
  gk_maybe_run "F" "secretRef ban" "secretref_ban" gk_check_secretref_ban
  gk_maybe_run "G" "Deprecated component refs" "deprecated_refs" gk_check_deprecated_refs
  gk_maybe_run "H" "Port chain consistency" "port_chain" gk_check_port_chain
  gk_maybe_run "I" "Namespace consistency" "namespace_consistency" gk_check_namespace_consistency
  gk_run_custom_checks
}

# Config-driven run-or-skip wrapper
gk_maybe_run() {
  local id="$1" name="$2" config_key="$3"
  shift 3
  if [ "$(gk_config_enabled "$config_key")" = "true" ]; then
    local severity
    severity=$(gk_config_value "${config_key}.severity" "critical")
    gk_run_check "$id" "$name" "$severity" "$@"
  else
    gk_skip_check "$id" "$name" "disabled"
  fi
}

gk_check_go_work() {
  for ws in $(find . -name 'go.work' -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null); do
    local dir=$(dirname "$ws")
    while IFS= read -r use_path; do
      [ -z "$use_path" ] && continue
      use_path=$(echo "$use_path" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
      [[ "$use_path" != ./* ]] && continue
      local full_path="$dir/$use_path"
      if [ ! -d "$full_path" ]; then
        echo "$ws: '$use_path' not found"
        return 1
      fi
      if [ ! -f "$full_path/go.mod" ]; then
        echo "$ws: '$use_path' has no go.mod"
        return 1
      fi
    done < <(grep '^\s*\./' "$ws" 2>/dev/null)
  done
  return 0
}

gk_check_shell_syntax() {
  local errors=0
  while IFS= read -r sh; do
    if ! bash -n "$sh" 2>/dev/null; then
      echo "Syntax error: $sh"
      ((errors++)) || true
    fi
  done < <(find . -name '*.sh' -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_python_packaging() {
  local errors=0
  while IFS= read -r pp; do
    local dir=$(dirname "$pp")
    if [ -f "$dir/setup.py" ] && grep -q 'build-backend' "$pp" 2>/dev/null; then
      echo "Redundant setup.py + pyproject.toml in $dir"
      ((errors++)) || true
    fi
  done < <(find . -name 'pyproject.toml' -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_dockerfile_copy() {
  local errors=0
  while IFS= read -r df; do
    local dir=$(dirname "$df")
    while IFS= read -r line; do
      local src=$(echo "$line" | sed 's/^COPY\s*//' | awk '{print $1}')
      [[ "$src" == --from=* ]] && continue
      [[ "$src" == *'$'* || "$src" == *'{'* || "$src" == *'*'* ]] && continue
      if [ ! -e "$dir/$src" ] && [ ! -e "./$src" ]; then
        echo "$df: COPY source '$src' not found"
        ((errors++)) || true
      fi
    done < <(grep '^COPY ' "$df" 2>/dev/null)
  done < <(find . -name 'Dockerfile*' -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_dockerfile_antipatterns() {
  local errors=0
  while IFS= read -r df; do
    if grep -n 'pip install.*-e \.' "$df" 2>/dev/null | grep -qv '#'; then
      echo "$df: editable install (-e .) in production Dockerfile"
      ((errors++)) || true
    fi
  done < <(find . -name 'Dockerfile*' -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_secretref_ban() {
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0
  local exclude_pattern
  exclude_pattern=$(gk_config_value "secretref_ban.exclude_pattern" "secretKeyRef")
  local found=$(grep -rn 'secretRef' "$k8s_dir" --include='*.yaml' 2>/dev/null | grep -v "$exclude_pattern" | grep -v '#' || true)
  if [ -n "$found" ]; then
    echo "secretRef found (use ${exclude_pattern} instead):"
    echo "$found"
    return 1
  fi
  return 0
}

gk_check_deprecated_refs() {
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0
  local patterns="federation-config federation-secrets"
  local custom=$(grep -A10 'deprecated_refs:' "$GK_CONFIG" 2>/dev/null | grep '^\s*-\s*"' | sed 's/.*"\(.*\)".*/\1/' || true)
  [ -n "$custom" ] && patterns="$custom"
  local errors=0
  for pattern in $patterns; do
    local found=$(grep -rn "$pattern" "$k8s_dir" --include='*.yaml' 2>/dev/null | grep -v '#' || true)
    if [ -n "$found" ]; then
      echo "Deprecated '$pattern': $found"
      ((errors++)) || true
    fi
  done
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_port_chain() {
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0
  local errors=0
  while IFS= read -r f; do
    local container_port=$(grep 'containerPort:' "$f" 2>/dev/null | head -1 | awk '{print $2}')
    [ -z "$container_port" ] && continue
    local liveness_port=$(awk '/livenessProbe:/{p=1} p && /port:/{print $2; p=0}' "$f" 2>/dev/null | head -1)
    if [ -n "$liveness_port" ] && [ "$liveness_port" != "$container_port" ]; then
      echo "$f: containerPort=$container_port livenessProbe=$liveness_port"
      ((errors++)) || true
    fi
    local readiness_port=$(awk '/readinessProbe:/{p=1} p && /port:/{print $2; p=0}' "$f" 2>/dev/null | head -1)
    if [ -n "$readiness_port" ] && [ "$readiness_port" != "$container_port" ]; then
      echo "$f: containerPort=$container_port readinessProbe=$readiness_port"
      ((errors++)) || true
    fi
  done < <(find "$k8s_dir" -name '*.yaml' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_namespace_consistency() {
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0
  local config_expect
  config_expect=$(gk_config_value "namespace_consistency.expect" "")
  local expected="${config_expect:-${GK_NAMESPACE:-production}}"
  local errors=0
  while IFS= read -r f; do
    while IFS= read -r line; do
      local ns=$(echo "$line" | awk '{print $NF}')
      if [ "$ns" != "$expected" ]; then
        echo "$f: namespace '$ns' (expected: $expected)"
        ((errors++)) || true
      fi
    done < <(awk '/^metadata:/{m=1} m && /namespace:/{print; m=0}' "$f" 2>/dev/null)
  done < <(find "$k8s_dir" -name '*.yaml' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_find_k8s_dir() {
  for d in deploy/k8s k8s kubernetes .k8s; do
    [ -d "$d" ] && echo "$d" && return
  done
}

# Run user-defined custom checks from custom_checks section of .gatekeeper.yaml
# Supports both inline (layer1.custom_checks) and top-level (custom_checks) sections
gk_run_custom_checks() {
  [ ! -f "$GK_CONFIG" ] && return 0

  # Parse custom_checks items from config using awk
  # Supports both "  custom_checks:" (layer1 sub-section) and "custom_checks:" (top-level)
  # Output format per item: id|pattern|paths|severity|command|exclude
  local items
  items=$(awk '
    /^  custom_checks:/ { in_cc=1; next }
    /^custom_checks:/ { in_cc=1; next }
    in_cc && /^[a-zA-Z]/ { in_cc=0 }
    in_cc && /^[[:space:]]*- id:/ {
      if (id != "") print id "|" pat "|" pths "|" sev "|" cmd "|" excl
      id=$NF; pat=""; pths="."; sev="critical"; cmd=""; excl=""
    }
    in_cc && /^[[:space:]]*pattern:/ { gsub(/^[[:space:]]*pattern:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); pat=$0 }
    in_cc && /^[[:space:]]*paths:/ { gsub(/^[[:space:]]*paths:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); gsub(/[\[\]]/,""); gsub(/,/," "); pths=$0 }
    in_cc && /^[[:space:]]*severity:/ { sev=$NF }
    in_cc && /^[[:space:]]*command:/ { gsub(/^[[:space:]]*command:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); cmd=$0 }
    in_cc && /^[[:space:]]*exclude_pattern:/ { gsub(/^[[:space:]]*exclude_pattern:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); excl=$0 }
    END { if (id != "") print id "|" pat "|" pths "|" sev "|" cmd "|" excl }
  ' "$GK_CONFIG" 2>/dev/null)

  [ -z "$items" ] && return 0

  local idx=0
  while IFS='|' read -r check_id check_pattern check_paths check_severity check_command check_exclude; do
    [ -z "$check_id" ] && continue
    idx=$((idx + 1))
    local label="custom-${idx}"
    local name="Custom: ${check_id}"

    if [ -n "$check_command" ]; then
      gk_run_check "$label" "$name" "$check_severity" bash -c "$check_command"
    elif [ -n "$check_pattern" ]; then
      gk_run_check "$label" "$name" "$check_severity" \
        _gk_pattern_check "$check_pattern" "$check_paths" "$check_exclude"
    fi
  done <<< "$items"
}

# Execute a grep-based pattern check; exits non-zero if pattern found
_gk_pattern_check() {
  local pattern="$1" paths="${2:-.}" exclude="$3"
  local errors=0

  for p in $paths; do
    local found=""
    if [ -n "$exclude" ]; then
      found=$(grep -rn "$pattern" $p 2>/dev/null | grep -v "$exclude" | grep -v '#' || true)
    else
      found=$(grep -rn "$pattern" $p 2>/dev/null | grep -v '#' || true)
    fi
    if [ -n "$found" ]; then
      echo "Pattern '$pattern' found:"
      echo "$found" | head -5
      ((errors++)) || true
    fi
  done

  [ $errors -eq 0 ] || return 1
  return 0
}
