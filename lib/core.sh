#!/usr/bin/env bash
# core.sh — Configuration parsing, audit logging, self-check

GK_CONFIG="${GK_CONFIG:-.gatekeeper.yaml}"
GK_AUDIT_DIR="${GK_AUDIT_DIR:-.gate-audit}"
GK_LAYER="${GK_LAYER:-all}"
GK_FORMAT="${GK_FORMAT:-text}"
GK_CI="${GK_CI:-false}"
GK_PROJECT="unknown"
GK_NAMESPACE="production"

GK_PASSED=0
GK_FAILED=0
GK_SKIPPED=0
GK_CHECKS=()
GK_START_TIME=""

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
  GK_PROJECT=$(grep '^project:' "$GK_CONFIG" | sed 's/project: *//' | tr -d '"' || echo "unknown")
  GK_NAMESPACE=$(grep '^namespace:' "$GK_CONFIG" | sed 's/namespace: *//' | tr -d '"' || echo "default")
}

gk_record() {
  local id="$1" name="$2" status="$3" details="${4:-}" duration_ms="${5:-0}"
  local escaped_details=$(echo "$details" | tr '\n' ' ' | sed 's/"/\\"/g' | cut -c1-200)
  GK_CHECKS+=("{\"id\":\"$id\",\"name\":\"$name\",\"status\":\"$status\",\"details\":\"$escaped_details\",\"duration_ms\":$duration_ms}")
  case "$status" in
    PASS) ((GK_PASSED++)) || true ;;
    FAIL) ((GK_FAILED++)) || true ;;
    *)    ((GK_SKIPPED++)) || true ;;
  esac
}

gk_run_check() {
  local id="$1" name="$2"
  shift 2
  local start_ms=$(date +%s%3N 2>/dev/null || date +%s000)
  local output=""
  local status="PASS"

  if output=$("$@" 2>&1); then
    status="PASS"
  else
    status="FAIL"
  fi

  local end_ms=$(date +%s%3N 2>/dev/null || date +%s000)
  local duration=$(( end_ms - start_ms ))

  gk_record "$id" "$name" "$status" "$output" "$duration"
  gk_print_check "$id" "$name" "$status" "$duration"
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

gk_run() {
  gk_parse_run_args "$@"
  gk_load_config || exit 1
  GK_START_TIME=$(date +%s%3N 2>/dev/null || date +%s000)

  gk_print_header

  if [ "$GK_LAYER" = "1" ] || [ "$GK_LAYER" = "all" ]; then
    gk_print_layer_header 1 "Static Checks"
    gk_layer1_run
  fi

  if [ "$GK_LAYER" = "2" ] || [ "$GK_LAYER" = "all" ]; then
    if [ $GK_FAILED -gt 0 ]; then
      gk_print_blocked "Layer 1 failed, skipping Layer 2"
    else
      gk_print_layer_header 2 "Cluster Validation"
      gk_layer2_run
    fi
  fi

  if [ "$GK_LAYER" = "3" ] || [ "$GK_LAYER" = "all" ]; then
    if [ $GK_FAILED -gt 0 ]; then
      gk_print_blocked "Previous layer failed, skipping Layer 3"
    else
      gk_print_layer_header 3 "Runtime Verification"
      gk_layer3_run
    fi
  fi

  local audit_file=$(gk_write_audit)
  local end_time=$(date +%s%3N 2>/dev/null || date +%s000)
  local total_ms=$(( end_time - ${GK_START_TIME:-0} ))

  gk_print_summary "$total_ms" "$audit_file"

  [ $GK_FAILED -eq 0 ] && return 0 || return 1
}

gk_init() {
  local template="minimal"
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
    case "$arg" in --type=*) template="${arg#*=}" ;; esac
  done

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
  ls -t "$GK_AUDIT_DIR"/*.json 2>/dev/null | head -n "$count" | while read -r f; do
    local verdict=$(grep '"verdict"' "$f" | sed 's/.*: *"//' | sed 's/".*//')
    local passed=$(grep '"passed"' "$f" | sed 's/.*: *//' | sed 's/,.*//')
    local failed=$(grep '"failed"' "$f" | sed 's/.*: *//' | sed 's/,.*//')
    local ts=$(basename "$f" .json)
    printf "  %s  %-8s (passed: %s, failed: %s)\n" "$ts" "$verdict" "$passed" "$failed"
  done
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
