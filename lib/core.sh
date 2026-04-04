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

# H-5 Fix: Escape all JSON string fields
gk_json_escape() {
  echo "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-200
}

gk_record() {
  local id="$1" name="$2" status="$3" details="${4:-}" duration_ms="${5:-0}"
  local eid=$(gk_json_escape "$id")
  local ename=$(gk_json_escape "$name")
  local edetails=$(gk_json_escape "$details")
  GK_CHECKS+=("{\"id\":\"$eid\",\"name\":\"$ename\",\"status\":\"$status\",\"details\":\"$edetails\",\"duration_ms\":$duration_ms}")
  case "$status" in
    PASS) ((GK_PASSED++)) || true ;;
    FAIL) ((GK_FAILED++)) || true ;;
    *)    ((GK_SKIPPED++)) || true ;;
  esac
}

gk_run_check() {
  local id="$1" name="$2"
  shift 2
  local start_ms=$(gk_now_ms)
  local output=""
  local status="PASS"

  if output=$("$@" 2>&1); then
    status="PASS"
  else
    status="FAIL"
  fi

  local end_ms=$(gk_now_ms)
  local duration=$(( end_ms - start_ms ))

  gk_record "$id" "$name" "$status" "$output" "$duration"
  gk_print_check "$id" "$name" "$status" "$duration"
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
  "verdict": "$([ $GK_FAILED -eq 0 ] && echo 'PASSED' || echo 'BLOCKED')"
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

  local audit_file=$(gk_write_audit)
  local end_time=$(gk_now_ms)
  local total_ms=$(( end_time - ${GK_START_TIME:-0} ))

  gk_print_summary "$total_ms" "$audit_file"

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

  local template_dir="${SCRIPT_DIR}/../templates"
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
  for arg in "$@"; do
    case "$arg" in --last=*) count="${arg#*=}" ;; esac
  done

  if [ ! -d "$GK_AUDIT_DIR" ]; then
    echo "No audit logs found at $GK_AUDIT_DIR"
    return 0
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

  echo ""
  [ $issues -eq 0 ] && echo "  All good!" || echo "  $issues issue(s) found"
}
