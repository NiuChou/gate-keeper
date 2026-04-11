#!/usr/bin/env bash
# layer1.sh — Static checks (zero external dependencies, runs locally)

gk_layer1_run() {
  # Parallel mode: collect enabled checks as specs and dispatch to parallel engine
  if [ "${GK_PARALLEL:-0}" != "0" ] && type gk_parallel_run_checks >/dev/null 2>&1; then
    local -a specs=()
    local -a check_defs=(
      "A|go.work validation|go_work|gk_check_go_work"
      "B|Shell script syntax|shell_syntax|gk_check_shell_syntax"
      "C|Python packaging|python_packaging|gk_check_python_packaging"
      "D|Dockerfile COPY paths|dockerfile_copy|gk_check_dockerfile_copy"
      "E|Dockerfile anti-patterns|dockerfile_antipatterns|gk_check_dockerfile_antipatterns"
      "F|secretRef ban|secretref_ban|gk_check_secretref_ban"
      "G|Deprecated component refs|deprecated_refs|gk_check_deprecated_refs"
      "H|Port chain consistency|port_chain|gk_check_port_chain"
      "I|Namespace consistency|namespace_consistency|gk_check_namespace_consistency"
      "DC-1|.env multi-line value detection|dc_env_multiline|gk_check_dc_env_multiline"
      "DC-2|Compose env var completeness|dc_env_completeness|gk_check_dc_env_completeness"
      "DC-3|Healthcheck anti-patterns|dc_healthcheck_antipatterns|gk_check_dc_healthcheck_antipatterns"
      "DC-4|tmpfs vs Dockerfile mkdir conflict|dc_tmpfs_shadow|gk_check_dc_tmpfs_shadow"
      "DC-5|cap_drop ALL on middleware|dc_cap_drop_all|gk_check_dc_cap_drop_all"
      "DC-6|depends_on deadlock detection|dc_depends_on_deadlock|gk_check_dc_depends_on_deadlock"
      "DC-7|Resource limit sanity|dc_resource_limits|gk_check_dc_resource_limits"
    )
    for def in "${check_defs[@]}"; do
      local id="${def%%|*}"; local rest="${def#*|}"
      local cname="${rest%%|*}"; rest="${rest#*|}"
      local key="${rest%%|*}"; local fn="${rest#*|}"
      if [ "$(gk_config_enabled "$key")" = "true" ]; then
        local sev
        sev=$(gk_config_value "${key}.severity" "critical")
        specs+=("${id}|${cname}|${sev}|${fn}")
      else
        gk_skip_check "$id" "$cname" "disabled"
      fi
    done
    if [ ${#specs[@]} -gt 0 ]; then
      gk_parallel_run_checks "${specs[@]}" || true
    fi
    gk_run_custom_checks
    return
  fi

  # Sequential mode (default)
  gk_maybe_run "A" "go.work validation" "go_work" gk_check_go_work
  gk_maybe_run "B" "Shell script syntax" "shell_syntax" gk_check_shell_syntax
  gk_maybe_run "C" "Python packaging" "python_packaging" gk_check_python_packaging
  gk_maybe_run "D" "Dockerfile COPY paths" "dockerfile_copy" gk_check_dockerfile_copy
  gk_maybe_run "E" "Dockerfile anti-patterns" "dockerfile_antipatterns" gk_check_dockerfile_antipatterns
  gk_maybe_run "F" "secretRef ban" "secretref_ban" gk_check_secretref_ban
  gk_maybe_run "G" "Deprecated component refs" "deprecated_refs" gk_check_deprecated_refs
  gk_maybe_run "H" "Port chain consistency" "port_chain" gk_check_port_chain
  gk_maybe_run "I" "Namespace consistency" "namespace_consistency" gk_check_namespace_consistency
  # Docker Compose checks
  gk_maybe_run "DC-1" ".env multi-line value detection" "dc_env_multiline" gk_check_dc_env_multiline
  gk_maybe_run "DC-2" "Compose env var completeness" "dc_env_completeness" gk_check_dc_env_completeness
  gk_maybe_run "DC-3" "Healthcheck anti-patterns" "dc_healthcheck_antipatterns" gk_check_dc_healthcheck_antipatterns
  gk_maybe_run "DC-4" "tmpfs vs Dockerfile mkdir conflict" "dc_tmpfs_shadow" gk_check_dc_tmpfs_shadow
  gk_maybe_run "DC-5" "cap_drop ALL on middleware" "dc_cap_drop_all" gk_check_dc_cap_drop_all
  gk_maybe_run "DC-6" "depends_on deadlock detection" "dc_depends_on_deadlock" gk_check_dc_depends_on_deadlock
  gk_maybe_run "DC-7" "Resource limit sanity" "dc_resource_limits" gk_check_dc_resource_limits
  gk_run_custom_checks
}

# Build grep exclude arguments shared across all check types
# Populates the caller's grep_args array variable
_gk_build_grep_excludes() {
  local extra_exclude_dirs="${1:-}"
  grep_args=()
  local default_excludes="node_modules .next dist build vendor .git __pycache__ .venv"
  for d in $default_excludes; do
    grep_args+=(--exclude-dir="$d")
  done
  if [ -n "$extra_exclude_dirs" ]; then
    for d in ${extra_exclude_dirs//,/ }; do
      grep_args+=(--exclude-dir="$d")
    done
  fi
  if [ -f ".gatekeeperignore" ]; then
    while IFS= read -r line; do
      line="${line%%#*}"; line="${line%/}"; line=$(echo "$line" | tr -d '[:space:]')
      [ -z "$line" ] && continue
      if [[ "$line" == *.* ]] && [[ "$line" != */* ]]; then
        grep_args+=(--exclude="$line")
      else
        grep_args+=(--exclude-dir="$line")
      fi
    done < ".gatekeeperignore"
  fi
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
    # Extract containerPort value using sed for precision
    local container_port=$(sed -n 's/^[[:space:]]*containerPort:[[:space:]]*//p' "$f" 2>/dev/null | head -1 | tr -d '[:space:]')
    [ -z "$container_port" ] && continue

    # Extract container port name (e.g. "name: http" under the ports block)
    local container_port_name=$(awk '
      /containerPort:/{found=1; next}
      found && /name:/{print $2; exit}
      found && /^[[:space:]]*[a-zA-Z]/ && !/name:/{exit}
    ' "$f" 2>/dev/null | tr -d '[:space:]')

    # Check liveness probe port
    local liveness_port=$(awk '/livenessProbe:/{p=1} p && /port:/{
      val=$2; gsub(/[[:space:]]/,"",val); print val; p=0
    }' "$f" 2>/dev/null | head -1)
    if [ -n "$liveness_port" ]; then
      # Named port: match against container port name
      if [[ "$liveness_port" =~ ^[a-zA-Z] ]]; then
        if [ -n "$container_port_name" ] && [ "$liveness_port" != "$container_port_name" ]; then
          echo "$f: containerPort name=$container_port_name livenessProbe port=$liveness_port"
          ((errors++)) || true
        fi
      elif [ "$liveness_port" != "$container_port" ]; then
        echo "$f: containerPort=$container_port livenessProbe=$liveness_port"
        ((errors++)) || true
      fi
    fi

    # Check readiness probe port
    local readiness_port=$(awk '/readinessProbe:/{p=1} p && /port:/{
      val=$2; gsub(/[[:space:]]/,"",val); print val; p=0
    }' "$f" 2>/dev/null | head -1)
    if [ -n "$readiness_port" ]; then
      if [[ "$readiness_port" =~ ^[a-zA-Z] ]]; then
        if [ -n "$container_port_name" ] && [ "$readiness_port" != "$container_port_name" ]; then
          echo "$f: containerPort name=$container_port_name readinessProbe port=$readiness_port"
          ((errors++)) || true
        fi
      elif [ "$readiness_port" != "$container_port" ]; then
        echo "$f: containerPort=$container_port readinessProbe=$readiness_port"
        ((errors++)) || true
      fi
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

gk_find_compose_files() {
  find . -maxdepth 2 \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
    -o -name 'compose*.yml' -o -name 'compose*.yaml' \) \
    -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null
}

gk_check_dc_env_multiline() {
  local compose_files
  compose_files=$(gk_find_compose_files)
  [ -z "$compose_files" ] && return 0
  local errors=0
  for env_file in .env .env.*; do
    [ -f "$env_file" ] || continue
    if grep -qE 'BEGIN (CERTIFICATE|PRIVATE KEY|RSA|EC|PUBLIC KEY)' "$env_file" 2>/dev/null; then
      echo "$env_file: contains PEM/certificate content (multi-line values not supported in Docker Compose .env)"
      echo "  Fix: Use _FILE suffix pattern with volume mounts instead of storing multi-line keys in .env"
      ((errors++)) || true
    fi
  done
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_dc_env_completeness() {
  local compose_files
  compose_files=$(gk_find_compose_files)
  [ -z "$compose_files" ] && return 0
  [ -f ".env" ] || return 0
  local errors=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    while IFS= read -r var_ref; do
      local var_name="${var_ref#\$\{}"
      var_name="${var_name%\}}"
      # Skip vars with defaults (${VAR:-default} or ${VAR-default})
      echo "$var_ref" | grep -qE '\$\{[^}]*:-|\$\{[^}]*-' && continue
      if ! grep -qE "^${var_name}=" ".env" 2>/dev/null; then
        echo "$f: variable '\${${var_name}}' not found in .env"
        ((errors++)) || true
      fi
    done < <(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$f" 2>/dev/null || true)
  done <<< "$compose_files"
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_dc_healthcheck_antipatterns() {
  local compose_files
  compose_files=$(gk_find_compose_files)
  [ -z "$compose_files" ] && return 0
  local errors=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # Anti-pattern 1: TLS healthcheck on localhost
    if grep -n 'https://localhost\|https://127\.0\.0\.1' "$f" 2>/dev/null | grep -qi 'healthcheck\|test\|curl\|wget'; then
      echo "$f: healthcheck uses HTTPS on localhost (TLS SNI will fail)"
      echo "  Fix: Use TCP probe (nc -z 127.0.0.1 PORT) or plain HTTP"
      ((errors++)) || true
    fi
    # Anti-pattern 2: pgrep -x with long process names
    local pgrep_matches
    pgrep_matches=$(grep -oE 'pgrep -x [a-zA-Z0-9_-]+' "$f" 2>/dev/null || true)
    if [ -n "$pgrep_matches" ]; then
      while IFS= read -r match; do
        local procname="${match#pgrep -x }"
        if [ ${#procname} -gt 15 ]; then
          echo "$f: pgrep -x '$procname' (${#procname} chars > 15 char Linux limit)"
          echo "  Fix: Use 'pgrep -f $procname' instead (-f matches full cmdline)"
          ((errors++)) || true
        fi
      done <<< "$pgrep_matches"
    fi
  done <<< "$compose_files"
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_dc_tmpfs_shadow() {
  local compose_files
  compose_files=$(gk_find_compose_files)
  [ -z "$compose_files" ] && return 0
  local errors=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local dir
    dir=$(dirname "$f")
    local tmpfs_paths
    tmpfs_paths=$(awk '/tmpfs:/{in_t=1; next} in_t && /^[[:space:]]*-[[:space:]]*\//{gsub(/^[[:space:]]*-[[:space:]]*/,""); print; next} in_t && /^[[:space:]]*[a-zA-Z]/{in_t=0}' "$f" 2>/dev/null || true)
    [ -z "$tmpfs_paths" ] && continue
    while IFS= read -r df; do
      [ -f "$df" ] || continue
      local mkdir_paths
      mkdir_paths=$(grep -oE 'mkdir -p [^ ]+' "$df" 2>/dev/null | awk '{print $3}' || true)
      [ -z "$mkdir_paths" ] && continue
      while IFS= read -r tpath; do
        while IFS= read -r mpath; do
          if [ "$tpath" = "$mpath" ]; then
            echo "$f: tmpfs mount '$tpath' shadows Dockerfile mkdir in $df"
            ((errors++)) || true
          fi
        done <<< "$mkdir_paths"
      done <<< "$tmpfs_paths"
    done < <(find "$dir" -maxdepth 2 -name 'Dockerfile*' 2>/dev/null)
  done <<< "$compose_files"
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_dc_cap_drop_all() {
  local compose_files
  compose_files=$(gk_find_compose_files)
  [ -z "$compose_files" ] && return 0
  local errors=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local result
    result=$(awk '
      /^[[:space:]]+[a-zA-Z0-9_-]+:/ && !/image:|command:|volumes:|ports:|environment:|depends_on:|networks:|healthcheck:|cap_drop:|cap_add:/ {
        svc=$1; gsub(/:$/,"",svc); img=""; cap_drop_all=0
      }
      /image:/ { img=$2 }
      /cap_drop:/ { in_cap=1; next }
      in_cap && /- ALL/ { cap_drop_all=1; in_cap=0 }
      in_cap && /^[[:space:]]*[a-zA-Z]/ { in_cap=0 }
      cap_drop_all && img ~ /postgres|redis|mysql|mongo|mariadb/ {
        print FILENAME ": service uses cap_drop ALL on " img " (may break DB operations)"
        cap_drop_all=0
      }
    ' "$f" 2>/dev/null || true)
    if [ -n "$result" ]; then
      echo "$result"
      ((errors++)) || true
    fi
  done <<< "$compose_files"
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_dc_depends_on_deadlock() {
  local compose_files
  compose_files=$(gk_find_compose_files)
  [ -z "$compose_files" ] && return 0
  local errors=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # Extract depends_on relationships: "svc dep" pairs
    local deps
    deps=$(awk '
      /^[[:space:]]{2}[a-zA-Z0-9_-]+:/ && !/image:|command:|volumes:|ports:|environment:|networks:|healthcheck:|cap_drop:|depends_on:/ {
        svc=$1; gsub(/:$/,"",svc)
      }
      /depends_on:/ { in_dep=1; next }
      in_dep && /^[[:space:]]*-[[:space:]]*[a-zA-Z]/ { dep=$2; print svc " " dep }
      in_dep && /^[[:space:]]{4}[a-zA-Z]/ { dep=$1; gsub(/:$/,"",dep); print svc " " dep }
      in_dep && /^[[:space:]]{2}[a-zA-Z]/ { in_dep=0 }
    ' "$f" 2>/dev/null || true)
    [ -z "$deps" ] && continue
    # Check for cycles: for each service, walk deps up to depth 20
    local services
    services=$(echo "$deps" | awk '{print $1}' | sort -u)
    while IFS= read -r start; do
      local visited="$start"
      local current="$start"
      local depth=0
      local cycle=false
      while [ $depth -lt 20 ]; do
        local next
        next=$(echo "$deps" | awk -v s="$current" '$1==s{print $2; exit}')
        [ -z "$next" ] && break
        if echo "$visited" | grep -qw "$next"; then
          echo "$f: circular depends_on detected: $visited -> $next"
          cycle=true
          break
        fi
        visited="$visited -> $next"
        current="$next"
        ((depth++)) || true
      done
      if [ "$cycle" = true ]; then
        ((errors++)) || true
        break
      fi
    done <<< "$services"
  done <<< "$compose_files"
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_dc_resource_limits() {
  local compose_files
  compose_files=$(gk_find_compose_files)
  [ -z "$compose_files" ] && return 0
  local per_worker_mb
  per_worker_mb=$(gk_config_value "dc_resource_limits.per_worker_mb" "128")
  local errors=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local result
    result=$(awk -v pwmb="$per_worker_mb" '
      /^[[:space:]]{2}[a-zA-Z0-9_-]+:/ && !/image:|command:|volumes:|ports:|environment:|networks:|healthcheck:|cap_drop:|depends_on:|mem_limit:|memory:/ {
        svc=$1; gsub(/:$/,"",svc); workers=0; mem_mb=0
      }
      /--workers[[:space:]]/ { match($0, /--workers[[:space:]]+([0-9]+)/, a); if (a[1]>0) workers=a[1]+0 }
      /mem_limit:|memory:/ {
        val=$2
        if (val ~ /[gG]$/) { sub(/[gG]$/,"",val); mem_mb=val*1024 }
        else if (val ~ /[mM]$/) { sub(/[mM]$/,"",val); mem_mb=val+0 }
        else mem_mb=val/1024/1024
      }
      workers>0 && mem_mb>0 {
        need=workers*pwmb*1.5
        if (mem_mb < need) {
          printf "%s: service %s has %d workers but only %dMB limit (need >= %dMB at %dMB/worker)\n", FILENAME, svc, workers, mem_mb, need, pwmb
        }
        workers=0; mem_mb=0
      }
    ' "$f" 2>/dev/null || true)
    if [ -n "$result" ]; then
      echo "$result"
      ((errors++)) || true
    fi
  done <<< "$compose_files"
  [ $errors -eq 0 ] || return 1
  return 0
}

# Run user-defined custom checks from custom_checks section of .gatekeeper.yaml
# Supports both inline (layer1.custom_checks) and top-level (custom_checks) sections
gk_run_custom_checks() {
  [ ! -f "$GK_CONFIG" ] && return 0

  # Parse custom_checks items from config using awk
  # Supports both "  custom_checks:" (layer1 sub-section) and "custom_checks:" (top-level)
  # Output format per item: fields separated by ASCII Unit Separator (0x1f)
  # Fields: id, pattern, paths, severity, command, exclude, exclude_dirs, fix_hint,
  #         drift_requires, drift_requires_paths, drift_mode, must_match, must_match_count
  local SEP=$'\x1f'
  local items
  items=$(awk -v sep="$SEP" '
    /^  custom_checks:/ { in_cc=1; next }
    /^custom_checks:/ { in_cc=1; next }
    in_cc && /^[a-zA-Z]/ { in_cc=0 }
    in_cc && /^[[:space:]]*- id:/ {
      if (id != "") print id sep pat sep pths sep sev sep cmd sep excl sep exdirs sep hint sep dreq sep dreqp sep dmode sep mmatch sep mmcount
      id=$NF; pat=""; pths="."; sev="critical"; cmd=""; excl=""; exdirs=""; hint=""; dreq=""; dreqp=""; dmode=""; mmatch=""; mmcount=""; ctags=""
    }
    in_cc && /^[[:space:]]*pattern:/ { gsub(/^[[:space:]]*pattern:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); pat=$0 }
    in_cc && /^[[:space:]]*paths:/ { gsub(/^[[:space:]]*paths:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); gsub(/[\[\]]/,""); gsub(/,/," "); pths=$0 }
    in_cc && /^[[:space:]]*severity:/ { sev=$NF }
    in_cc && /^[[:space:]]*command:/ { gsub(/^[[:space:]]*command:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); cmd=$0 }
    in_cc && /^[[:space:]]*exclude_pattern:/ { gsub(/^[[:space:]]*exclude_pattern:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); excl=$0 }
    in_cc && /^[[:space:]]*exclude_dirs:/ { gsub(/^[[:space:]]*exclude_dirs:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); exdirs=$0 }
    in_cc && /^[[:space:]]*fix_hint:/ { gsub(/^[[:space:]]*fix_hint:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); hint=$0 }
    in_cc && /^[[:space:]]*requires:/ { gsub(/^[[:space:]]*requires:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); dreq=$0 }
    in_cc && /^[[:space:]]*requires_paths:/ { gsub(/^[[:space:]]*requires_paths:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); gsub(/[\[\]]/,""); gsub(/,/," "); dreqp=$0 }
    in_cc && /^[[:space:]]*drift_mode:/ { gsub(/^[[:space:]]*drift_mode:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); dmode=$0 }
    in_cc && /^[[:space:]]*must_match:/ { gsub(/^[[:space:]]*must_match:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); mmatch=$0 }
    in_cc && /^[[:space:]]*must_match_count:/ { gsub(/^[[:space:]]*must_match_count:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); mmcount=$0 }
    in_cc && /^[[:space:]]*tags:/ { gsub(/^[[:space:]]*tags:[[:space:]]*/,""); gsub(/^"/,""); gsub(/"$/,""); ctags=$0 }
    END { if (id != "") print id sep pat sep pths sep sev sep cmd sep excl sep exdirs sep hint sep dreq sep dreqp sep dmode sep mmatch sep mmcount sep ctags }
  ' "$GK_CONFIG" 2>/dev/null)

  [ -z "$items" ] && return 0

  local idx=0
  while IFS="$SEP" read -r check_id check_pattern check_paths check_severity check_command check_exclude check_exclude_dirs check_fix_hint check_requires check_requires_paths check_drift_mode check_must_match check_must_match_count check_tags; do
    [ -z "$check_id" ] && continue
    idx=$((idx + 1))
    local label="custom-${idx}"
    local name="Custom: ${check_id}"

    # Tag filtering: skip if --tags is set and check tags don't match
    if [ -n "${GK_TAGS:-}" ] && [ -n "$check_tags" ]; then
      if type _gk_tags_match >/dev/null 2>&1 && ! _gk_tags_match "$check_tags"; then
        gk_skip_check "$label" "$name" "tag-filtered"
        continue
      fi
    elif [ -n "${GK_TAGS:-}" ] && [ -z "$check_tags" ]; then
      # Check has no tags but filter is active — skip
      gk_skip_check "$label" "$name" "tag-filtered"
      continue
    fi

    if [ -n "$check_command" ]; then
      gk_run_check "$label" "$name" "$check_severity" bash -c "$check_command"
    elif [ -n "$check_must_match" ]; then
      # must_match: pattern must be found (reverse semantics)
      local min_count="${check_must_match_count:-1}"
      gk_run_check "$label" "$name" "$check_severity" \
        _gk_must_match_check "$check_must_match" "$check_paths" "$check_exclude_dirs" "$check_fix_hint" "$min_count"
    elif [ -n "$check_drift_mode" ] && [ -n "$check_pattern" ]; then
      # Drift check: commented mode, or requires-based drift
      gk_run_check "$label" "$name" "$check_severity" \
        _gk_drift_check "$check_pattern" "$check_paths" "$check_requires" "$check_requires_paths" "$check_drift_mode" "$check_exclude_dirs" "$check_fix_hint"
    elif [ -n "$check_requires" ] && [ -n "$check_pattern" ]; then
      # Drift check (implicit global mode): if pattern found, requires must also be found
      gk_run_check "$label" "$name" "$check_severity" \
        _gk_drift_check "$check_pattern" "$check_paths" "$check_requires" "$check_requires_paths" "global" "$check_exclude_dirs" "$check_fix_hint"
    elif [ -n "$check_pattern" ]; then
      gk_run_check "$label" "$name" "$check_severity" \
        _gk_pattern_check "$check_pattern" "$check_paths" "$check_exclude" "$check_exclude_dirs" "$check_fix_hint"
    fi
  done <<< "$items"
}

# Drift check: if pattern A is found, pattern B (requires) must also be found.
# Detects "defined but not activated" security drift.
#
# drift_mode controls the matching scope:
#   "global"   (default) — A found anywhere + B found anywhere = PASS
#   "per_file" — for EACH file where A is found, B must also be found in that file
#   "commented" — pattern found inside comments (// or #) = FAIL (disabled code detection)
#
# Args: pattern, paths, requires, requires_paths, drift_mode, exclude_dirs, fix_hint
_gk_drift_check() {
  local pattern="$1"
  local paths="${2:-.}"
  local requires="$3"
  local requires_paths="${4:-$paths}"
  local drift_mode="${5:-global}"
  local exclude_dirs="${6:-}"
  local fix_hint="${7:-}"

  local -a grep_args=()
  _gk_build_grep_excludes "$exclude_dirs"

  case "$drift_mode" in
    commented)
      # Check if the pattern exists ONLY inside comments (disabled code)
      # grep -rn output format: "file:line:content" — we check the content portion
      local errors=0
      for p in $paths; do
        local all_matches=$(grep -rn "${grep_args[@]}" "$pattern" $p 2>/dev/null || true)
        [ -z "$all_matches" ] && continue

        # Extract code portion (after file:line:) and check for comment markers
        local commented_count=0
        local active_count=0
        while IFS= read -r match_line; do
          # Extract the code content after "file:linenum:"
          local code_part=$(echo "$match_line" | sed 's/^[^:]*:[0-9]*://')
          local trimmed=$(echo "$code_part" | sed 's/^[[:space:]]*//')
          if [[ "$trimmed" == //* ]] || [[ "$trimmed" == \#* ]] || [[ "$trimmed" == /\** ]] || [[ "$trimmed" == \** ]]; then
            ((commented_count++)) || true
          else
            ((active_count++)) || true
          fi
        done <<< "$all_matches"

        if [ $commented_count -gt 0 ] && [ $active_count -eq 0 ]; then
          echo "Drift: '$pattern' found only in comments (disabled):"
          echo "$all_matches" | head -5
          if [ -n "$fix_hint" ]; then
            echo "  Fix: $fix_hint"
          fi
          ((errors++)) || true
        fi
      done
      [ $errors -eq 0 ] || return 1
      return 0
      ;;

    per_file)
      # For each file containing pattern, requires must also be in that file
      local errors=0
      for p in $paths; do
        local files_with_pattern=$(grep -rl "${grep_args[@]}" "$pattern" $p 2>/dev/null || true)
        [ -z "$files_with_pattern" ] && continue
        while IFS= read -r f; do
          [ -z "$f" ] && continue
          if ! grep -q "$requires" "$f" 2>/dev/null; then
            echo "Drift: '$pattern' found in $f but '$requires' missing"
            ((errors++)) || true
          fi
        done <<< "$files_with_pattern"
      done
      if [ $errors -gt 0 ] && [ -n "$fix_hint" ]; then
        echo "  Fix: $fix_hint"
      fi
      [ $errors -eq 0 ] || return 1
      return 0
      ;;

    global|*)
      # Pattern found anywhere → requires must also be found somewhere
      local pattern_found=false
      for p in $paths; do
        if grep -rq "${grep_args[@]}" "$pattern" $p 2>/dev/null; then
          pattern_found=true
          break
        fi
      done

      if [ "$pattern_found" = false ]; then
        return 0  # Pattern not found, nothing to check
      fi

      # Pattern exists — now check requires
      for p in $requires_paths; do
        if grep -rq "${grep_args[@]}" "$requires" $p 2>/dev/null; then
          return 0  # Both found, no drift
        fi
      done

      # Drift detected: pattern exists but requires is missing
      echo "Drift: '$pattern' found but '$requires' not found"
      local source_file=$(grep -rl "${grep_args[@]}" "$pattern" $paths 2>/dev/null | head -1)
      [ -n "$source_file" ] && echo "  Source: $source_file"
      if [ -n "$fix_hint" ]; then
        echo "  Fix: $fix_hint"
      fi
      return 1
      ;;
  esac
}

# Reverse pattern check: exits non-zero if pattern NOT found (must_match semantics)
# Args: pattern, paths, exclude_dirs, fix_hint, min_count
_gk_must_match_check() {
  local pattern="$1" paths="${2:-.}" exclude_dirs="${3:-}" fix_hint="${4:-}" min_count="${5:-1}"

  local -a grep_args=()
  _gk_build_grep_excludes "$exclude_dirs"

  local errors=0
  for p in $paths; do
    local count
    count=$(grep -rc "${grep_args[@]}" "$pattern" $p 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')
    if [ "$count" -lt "$min_count" ]; then
      if [ "$min_count" -eq 1 ]; then
        echo "Required pattern '$pattern' NOT found in $p"
      else
        echo "Required pattern '$pattern' found $count time(s) in $p (need >= $min_count)"
      fi
      if [ -n "$fix_hint" ]; then
        echo "  Fix: $fix_hint"
      fi
      ((errors++)) || true
    fi
  done
  [ $errors -eq 0 ] || return 1
  return 0
}

# Execute a grep-based pattern check; exits non-zero if pattern found
# Args: pattern, paths, exclude_pattern, exclude_dirs, fix_hint
_gk_pattern_check() {
  local pattern="$1" paths="${2:-.}" exclude="${3:-}" exclude_dirs="${4:-}" fix_hint="${5:-}"
  local errors=0

  local -a grep_args=()
  _gk_build_grep_excludes "$exclude_dirs"

  for p in $paths; do
    local found=""
    if [ -n "$exclude" ]; then
      found=$(grep -rn "${grep_args[@]}" "$pattern" $p 2>/dev/null | grep -v "$exclude" | grep -v '#' || true)
    else
      found=$(grep -rn "${grep_args[@]}" "$pattern" $p 2>/dev/null | grep -v '#' || true)
    fi
    if [ -n "$found" ]; then
      echo "Pattern '$pattern' found:"
      echo "$found" | head -5
      if [ -n "$fix_hint" ]; then
        echo "  Fix: $fix_hint"
      fi
      ((errors++)) || true
    fi
  done

  [ $errors -eq 0 ] || return 1
  return 0
}
