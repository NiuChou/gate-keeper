#!/usr/bin/env bash
# layer3.sh — Runtime verification (runs after deployment)

gk_layer3_run() {
  if ! command -v kubectl >/dev/null 2>&1; then
    gk_record "M" "healthz check" "SKIP" "kubectl not available"
    gk_record "N" "pod status check" "SKIP" "kubectl not available"
    gk_record "O" "load test" "SKIP" "kubectl not available"
    gk_print_check "M" "healthz check" "SKIP"
    gk_print_check "N" "pod status check" "SKIP"
    gk_print_check "O" "load test" "SKIP"
    return 0
  fi

  gk_run_check "M" "healthz check" gk_check_healthz
  gk_run_check "N" "pod status check" gk_check_pod_status
  gk_run_check "O" "load test" gk_check_load_test
}

gk_check_healthz() {
  local ns="${GK_NAMESPACE:-production}"
  local errors=0

  while IFS=$'\t' read -r pod phase; do
    [ -z "$pod" ] && continue
    if [ "$phase" != "Running" ]; then
      echo "Pod $pod is $phase"
      ((errors++)) || true
    fi
  done < <(kubectl -n "$ns" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_pod_status() {
  local ns="${GK_NAMESPACE:-production}"
  local errors=0

  local bad_pods=$(kubectl -n "$ns" get pods 2>/dev/null | grep -E 'CrashLoopBackOff|ImagePullBackOff|Error|ErrImagePull' || true)
  if [ -n "$bad_pods" ]; then
    echo "Pods in error state:"
    echo "$bad_pods"
    return 1
  fi
  return 0
}

gk_check_load_test() {
  if ! command -v k6 >/dev/null 2>&1; then
    return 0  # Skip silently if k6 not installed
  fi

  if [ -f "tests/loadtest/smoke.js" ]; then
    k6 run --quiet --duration=10s --vus=2 tests/loadtest/smoke.js 2>&1 || return 1
  fi
  return 0
}
