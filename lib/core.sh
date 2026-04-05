#!/usr/bin/env bash
# core.sh — Configuration parsing, audit logging, self-check

GK_CONFIG="${GK_CONFIG:-.gatekeeper.yaml}"
GK_AUDIT_DIR="${GK_AUDIT_DIR:-.gate-audit}"
GK_LAYER="${GK_LAYER:-all}"
GK_FORMAT="${GK_FORMAT:-text}"
GK_CI="${GK_CI:-false}"
GK_PROJECT="unknown"
GK_NAMESPACE="production"
GK_SECRET_NAME="perseworks-secret"

GK_PASSED=0
GK_FAILED=0
GK_SKIPPED=0
GK_WARNINGS=0
GK_CHECKS=()
GK_START_TIME=""

# Cross-platform millisecond timestamp
gk_now_ms() {
  if command -v gdate >/dev/null 2>&1; then
    gdate +%s%3N
  else
    echo "$(date +%s)000"
  fi
}

gk_parse_run_args() {
  for arg in "$@"; do
    case "$arg" in
      --layer=*)   GK_LAYER="${arg#*=}" ;;
      --config=*)  GK_CONFIG="${arg#*=}" ;;
      --format=*)  GK_FORMAT="${arg#*=}" ;;
      --ci)        GK_CI=true; GK_FORMAT=json ;;
    esac
  done
}

gk_load_config() {
  if [ ! -f "$GK_CONFIG" ]; then
    gk_warn "No config file found at $GK_CONFIG"
    gk_warn "Run 'gate-keeper init' to generate one"
    return 1
  fi
  GK_PROJECT=$(grep '^project:' "$GK_CONFIG" 2>/dev/null | sed 's/project: *//' | tr -d '"') || GK_PROJECT="unknown"
  GK_NAMESPACE=$(grep '^namespace:' "$GK_CONFIG" 2>/dev/null | sed 's/namespace: *//' | tr -d '"') || GK_NAMESPACE="default"
  # Read secret name from config
  GK_SECRET_NAME=$(grep 'secret_name:' "$GK_CONFIG" 2>/dev/null | sed 's/.*secret_name: *//' | tr -d '"') || GK_SECRET_NAME="perseworks-secret"
  return 0
}

# C-1 Fix: Read config to check if a check is enabled
gk_config_enabled() {
  local key="$1" default="${2:-true}"
  if [ ! -f "$GK_CONFIG" ]; then
    echo "$default"
    return
  fi
  if grep -q "^\s*${key}:\s*false" "$GK_CONFIG" 2>/dev/null; then
    echo "false"
  else
    echo "$default"
  fi
}

# Read a nested YAML value from the config file.
# Usage: gk_config_value "section.key" "default_value"
# Handles two-level nesting: section:\n  key: value
gk_config_value() {
  local dotpath="$1" default="${2:-}"
  if [ ! -f "$GK_CONFIG" ]; then
    echo "$default"
    return
  fi
  local section="${dotpath%%.*}"
  local key="${dotpath#*.}"
  # Use awk: find section header (any indent), then find key at greater indent
  local value
  value=$(awk -v section="${section}" -v key="${key}" '
    {
      # Detect section header: any indentation followed by section:
      if ($0 ~ ("[[:space:]]*" section ":")) {
        in_section=1
        # Record the indent of the section line
        match($0, /^[[:space:]]*/); sect_indent=RLENGTH
        next
      }
      # If in section: check if we have left it (same or lesser indent, non-blank, non-comment)
      if (in_section && /^[^ \t#]/ ) { in_section=0 }
      if (in_section && /^[[:space:]]/ ) {
        match($0, /^[[:space:]]*/); cur_indent=RLENGTH
        if (cur_indent <= sect_indent && /[^ \t]/) { in_section=0 }
      }
    }
    in_section && $0 ~ ("[[:space:]]+" key ":") {
      val = $0
      sub(/^[[:space:]]*[^:]*:[[:space:]]*/, "", val)
      gsub(/"/, "", val)
      print val
      exit
    }
  ' "$GK_CONFIG" 2>/dev/null)
  if [ -n "$value" ]; then
    echo "$value"
  else
    echo "$default"
  fi
}

# H-5 Fix: Escape all JSON string fields
gk_json_escape() {
  echo "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-200
}

gk_record() {
  local id="$1" name="$2" status="$3" details="${4:-}" duration_ms="${5:-0}" severity="${6:-critical}"
  local eid=$(gk_json_escape "$id")
  local ename=$(gk_json_escape "$name")
  local edetails=$(gk_json_escape "$details")
  GK_CHECKS+=("{\"id\":\"$eid\",\"name\":\"$ename\",\"status\":\"$status\",\"details\":\"$edetails\",\"duration_ms\":$duration_ms,\"severity\":\"$severity\"}")
  case "$status" in
    PASS) ((GK_PASSED++)) || true ;;
    FAIL) ((GK_FAILED++)) || true ;;
    WARN) ((GK_WARNINGS++)) || true ;;
    *)    ((GK_SKIPPED++)) || true ;;
  esac
}

gk_run_check() {
  local id="$1" name="$2" severity="${3:-critical}"
  shift 3
  local start_ms=$(gk_now_ms)
  local output=""
  local status="PASS"

  if output=$("$@" 2>&1); then
    status="PASS"
  else
    if [ "$severity" = "warning" ]; then
      status="WARN"
    else
      status="FAIL"
    fi
  fi

  local end_ms=$(gk_now_ms)
  local duration=$(( end_ms - start_ms ))

  gk_record "$id" "$name" "$status" "$output" "$duration" "$severity"
  gk_print_check "$id" "$name" "$status" "$duration"

  # Print details on failure/warning (includes fix_hint if present)
  if [ "$status" = "FAIL" ] || [ "$status" = "WARN" ]; then
    if [ -n "$output" ]; then
      echo "$output" | head -8 | sed 's/^/    /'
    fi
  fi
}

# Skip a check with SKIP status
gk_skip_check() {
  local id="$1" name="$2" reason="${3:-disabled}"
  gk_record "$id" "$name" "SKIP" "$reason" 0
  gk_print_check "$id" "$name" "SKIP"
}

gk_write_audit() {
  mkdir -p "$GK_AUDIT_DIR"
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  local safe_ts=$(echo "$timestamp" | tr ':' '-')
  local filename="${GK_AUDIT_DIR}/${safe_ts}-${git_sha}.json"

  local checks_json=""
  if [ ${#GK_CHECKS[@]} -gt 0 ]; then
    checks_json=$(printf '%s,' "${GK_CHECKS[@]}" | sed 's/,$//')
  fi

  local verdict
  if [ $GK_FAILED -gt 0 ]; then
    verdict="BLOCKED"
  elif [ $GK_WARNINGS -gt 0 ]; then
    verdict="WARNED"
  else
    verdict="PASSED"
  fi

  cat > "$filename" <<EOF
{
  "timestamp": "$timestamp",
  "git_sha": "$git_sha",
  "project": "$GK_PROJECT",
  "layer": "$GK_LAYER",
  "checks": [$checks_json],
  "passed": $GK_PASSED,
  "failed": $GK_FAILED,
  "skipped": $GK_SKIPPED,
  "warnings": $GK_WARNINGS,
  "verdict": "$verdict"
}
EOF
  echo "$filename"
}

# H-4 Fix: --layer=N means run layers 1..N (cumulative), not just layer N
gk_run() {
  gk_parse_run_args "$@"
  gk_load_config || exit 1
  GK_START_TIME=$(gk_now_ms)

  gk_print_header

  local run_l1=false run_l2=false run_l3=false
  case "$GK_LAYER" in
    1)   run_l1=true ;;
    2)   run_l1=true; run_l2=true ;;
    3)   run_l1=true; run_l2=true; run_l3=true ;;
    all) run_l1=true; run_l2=true; run_l3=true ;;
  esac

  if [ "$run_l1" = true ]; then
    gk_print_layer_header 1 "Static Checks"
    gk_layer1_run
  fi

  if [ "$run_l2" = true ]; then
    if [ $GK_FAILED -gt 0 ]; then
      gk_print_blocked "Layer 1 failed, skipping Layer 2"
    else
      gk_print_layer_header 2 "Cluster Validation"
      gk_layer2_run
    fi
  fi

  if [ "$run_l3" = true ]; then
    if [ $GK_FAILED -gt 0 ]; then
      gk_print_blocked "Previous layer failed, skipping Layer 3"
    else
      gk_print_layer_header 3 "Runtime Verification"
      gk_layer3_run
    fi
  fi

  # Supervision: integrity check (runs always if hash file exists)
  local hash_file="${GK_HASH_FILE:-.gate-keeper.sha256}"
  if [ -f "$hash_file" ]; then
    gk_run_check "S-1" "Integrity: gate-keeper files" "critical" gk_check_integrity
  fi

  # Supervision: annotate deployments with run-id on success
  if [ $GK_FAILED -eq 0 ]; then
    local timestamp
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    local git_sha
    git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    local run_id="${timestamp}-${git_sha}"
    gk_annotate_deployments "$run_id"
  fi

  local audit_file=$(gk_write_audit)
  local end_time=$(gk_now_ms)
  local total_ms=$(( end_time - ${GK_START_TIME:-0} ))

  gk_print_summary "$total_ms" "$audit_file"

  # Only critical failures block the pipeline
  [ $GK_FAILED -eq 0 ] && return 0 || return 1
}

# L-5 Fix: Overwrite protection for init
gk_init() {
  local template="minimal"
  local force=false

  if [ -f "go.work" ] && [ -d "deploy/k8s" ]; then
    template="k8s-go"
  elif [ -f "pyproject.toml" ] && [ -d "deploy/k8s" ]; then
    template="k8s-python"
  elif ls next.config.* 1>/dev/null 2>&1; then
    template="nextjs"
  elif [ -f "pnpm-workspace.yaml" ]; then
    template="monorepo"
  elif ls docker-compose*.yml docker-compose*.yaml 1>/dev/null 2>&1; then
    template="docker-compose"
  fi

  for arg in "$@"; do
    case "$arg" in
      --type=*)  template="${arg#*=}" ;;
      --force)   force=true ;;
    esac
  done

  if [ -f ".gatekeeper.yaml" ] && [ "$force" != true ]; then
    echo ".gatekeeper.yaml already exists. Use --force to overwrite."
    exit 1
  fi

  local template_dir="${TEMPLATE_DIR:-${SCRIPT_DIR}/../templates}"
  if [ -f "${template_dir}/${template}.yaml" ]; then
    cp "${template_dir}/${template}.yaml" .gatekeeper.yaml
    echo "Generated .gatekeeper.yaml from template: $template"
    echo "Edit it to customize checks for your project."
  else
    echo "Template not found: $template"
    echo "Available: $(ls "${template_dir}/" 2>/dev/null | sed 's/.yaml//g' | tr '\n' ' ')"
    exit 1
  fi
}

# L-4 Fix: Use process substitution instead of pipe
gk_audit() {
  local count=5
  local diff_mode=false
  for arg in "$@"; do
    case "$arg" in
      --last=*) count="${arg#*=}" ;;
      --diff)   diff_mode=true ;;
    esac
  done

  if [ ! -d "$GK_AUDIT_DIR" ]; then
    echo "No audit logs found at $GK_AUDIT_DIR"
    return 0
  fi

  if [ "$diff_mode" = true ]; then
    gk_audit_diff
    return $?
  fi

  echo "Last $count audit logs:"
  echo ""
  while read -r f; do
    [ -z "$f" ] && continue
    local verdict=$(grep '"verdict"' "$f" | sed 's/.*: *"//' | sed 's/".*//')
    local passed=$(grep '"passed"' "$f" | sed 's/.*: *//' | sed 's/,.*//')
    local failed=$(grep '"failed"' "$f" | sed 's/.*: *//' | sed 's/,.*//')
    local ts=$(basename "$f" .json)
    printf "  %s  %-8s (passed: %s, failed: %s)\n" "$ts" "$verdict" "$passed" "$failed"
  done < <(ls -t "$GK_AUDIT_DIR"/*.json 2>/dev/null | head -n "$count")
}

# Compare the two most recent audit logs
gk_audit_diff() {
  local files=()
  while read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(ls -t "$GK_AUDIT_DIR"/*.json 2>/dev/null | head -n 2)

  if [ ${#files[@]} -lt 2 ]; then
    echo "Need at least 2 audit logs for diff. Found: ${#files[@]}"
    return 1
  fi

  local newer="${files[0]}"
  local older="${files[1]}"
  local ts_new=$(basename "$newer" .json)
  local ts_old=$(basename "$older" .json)

  echo "Diff: $ts_old → $ts_new"
  echo ""

  # Extract check statuses from both files using awk
  # Format: id:status per line
  local old_checks new_checks
  old_checks=$(awk -F'"' '/"id"/{id=$4} /"status"/{st=$4; print id":"st}' "$older")
  new_checks=$(awk -F'"' '/"id"/{id=$4} /"status"/{st=$4; print id":"st}' "$newer")

  local has_changes=false

  # Find changes
  while IFS=: read -r new_id new_status; do
    [ -z "$new_id" ] && continue
    local old_status=""
    old_status=$(echo "$old_checks" | grep "^${new_id}:" | head -1 | cut -d: -f2)
    if [ -z "$old_status" ]; then
      printf "  [%s] %-30s (new) → %s\n" "$new_id" "" "$new_status"
      has_changes=true
    elif [ "$old_status" != "$new_status" ]; then
      local arrow="→"
      local indicator=""
      if [ "$new_status" = "PASS" ] && [ "$old_status" = "FAIL" ]; then
        indicator=" ✅"
      elif [ "$new_status" = "FAIL" ] && [ "$old_status" = "PASS" ]; then
        indicator=" ❌"
      fi
      printf "  [%s] %s %s %s%s\n" "$new_id" "$old_status" "$arrow" "$new_status" "$indicator"
      has_changes=true
    fi
  done <<< "$new_checks"

  if [ "$has_changes" = false ]; then
    echo "  No changes between runs."
  fi
}

gk_add() {
  local id="" pattern="" paths="." severity="warning" description=""

  for arg in "$@"; do
    case "$arg" in
      --id=*)          id="${arg#*=}" ;;
      --pattern=*)     pattern="${arg#*=}" ;;
      --paths=*)       paths="${arg#*=}" ;;
      --severity=*)    severity="${arg#*=}" ;;
      --description=*) description="${arg#*=}" ;;
    esac
  done

  if [ -z "$id" ]; then
    echo "Error: --id is required"
    echo "Usage: gate-keeper add --id=ID --pattern=PATTERN [--paths=GLOB] [--severity=critical|warning] [--description=TEXT]"
    exit 1
  fi

  if [ -z "$pattern" ]; then
    echo "Error: --pattern is required"
    echo "Usage: gate-keeper add --id=ID --pattern=PATTERN [--paths=GLOB] [--severity=critical|warning] [--description=TEXT]"
    exit 1
  fi

  if [ ! -f "$GK_CONFIG" ]; then
    echo "Error: $GK_CONFIG not found. Run 'gate-keeper init' first."
    exit 1
  fi

  # Check if id already exists in config
  if grep -q "^\s*- id: ${id}$" "$GK_CONFIG" 2>/dev/null; then
    echo "Error: custom check '${id}' already exists in $GK_CONFIG"
    exit 1
  fi

  # Validate severity
  case "$severity" in
    critical|warning) ;;
    *)
      echo "Error: --severity must be 'critical' or 'warning'"
      exit 1
      ;;
  esac

  local tmp_file="${GK_CONFIG}.gk_tmp"

  # Build description line (may be empty)
  local desc_line=""
  [ -n "$description" ] && desc_line="      description: \"${description}\""

  if grep -q "^  custom_checks:" "$GK_CONFIG" 2>/dev/null; then
    # custom_checks section exists — append new item at end of the block
    awk -v id="$id" -v pat="$pattern" -v pths="$paths" -v sev="$severity" -v desc="$desc_line" '
      /^  custom_checks:/ { in_cc=1 }
      in_cc && /^[a-zA-Z]/ { in_cc=0 }
      in_cc && /^    - id:/ { last_item=NR }
      { lines[NR]=$0 }
      END {
        insert_after=last_item
        # advance past all sub-key lines of the last item
        while (insert_after+1 <= NR && lines[insert_after+1] ~ /^      /) insert_after++
        for (i=1; i<=NR; i++) {
          print lines[i]
          if (i==insert_after) {
            print "    - id: " id
            print "      pattern: \"" pat "\""
            print "      paths: \"" pths "\""
            print "      severity: " sev
            if (desc != "") print desc
          }
        }
      }
    ' "$GK_CONFIG" > "$tmp_file"
  else
    # No custom_checks section yet — append it inside layer1 block before next top-level key
    awk -v id="$id" -v pat="$pattern" -v pths="$paths" -v sev="$severity" -v desc="$desc_line" '
      /^layer1:/ { in_l1=1 }
      in_l1 && /^[a-zA-Z]/ && !/^layer1:/ {
        if (!inserted) {
          print "  custom_checks:"
          print "    - id: " id
          print "      pattern: \"" pat "\""
          print "      paths: \"" pths "\""
          print "      severity: " sev
          if (desc != "") print desc
          inserted=1
        }
        in_l1=0
      }
      { print }
      END {
        if (in_l1 && !inserted) {
          print "  custom_checks:"
          print "    - id: " id
          print "      pattern: \"" pat "\""
          print "      paths: \"" pths "\""
          print "      severity: " sev
          if (desc != "") print desc
        }
      }
    ' "$GK_CONFIG" > "$tmp_file"
  fi

  mv "$tmp_file" "$GK_CONFIG"
  echo "Added custom check '${id}' to ${GK_CONFIG}"
}

gk_doctor() {
  echo "Gate Keeper Doctor"
  echo ""
  local issues=0

  if [ -f "$GK_CONFIG" ]; then
    echo "  [OK] Config: $GK_CONFIG"
  else
    echo "  [!!] Config not found: $GK_CONFIG"
    ((issues++)) || true
  fi

  if [ -d "$GK_AUDIT_DIR" ]; then
    local log_count=$(ls "$GK_AUDIT_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
    echo "  [OK] Audit dir: $GK_AUDIT_DIR ($log_count logs)"
  else
    echo "  [--] Audit dir not yet created"
  fi

  for cmd in grep sed awk bash; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "  [OK] $cmd"
    else
      echo "  [!!] $cmd not found"
      ((issues++)) || true
    fi
  done

  if command -v kubectl >/dev/null 2>&1; then
    echo "  [OK] kubectl (Layer 2+3 enabled)"
  else
    echo "  [--] kubectl not available (Layer 2+3 will skip)"
  fi

  local hash_file="${GK_HASH_FILE:-.gate-keeper.sha256}"
  if [ -f "$hash_file" ]; then
    if gk_check_integrity >/dev/null 2>&1; then
      echo "  [OK] Integrity hash: $hash_file (verified)"
    else
      echo "  [!!] Integrity hash: $hash_file (VIOLATION — files modified)"
      ((issues++)) || true
    fi
  else
    echo "  [--] Integrity hash not found (run 'gate-keeper stamp' to enable tamper detection)"
  fi

  echo ""
  [ $issues -eq 0 ] && echo "  All good!" || echo "  $issues issue(s) found"
}
