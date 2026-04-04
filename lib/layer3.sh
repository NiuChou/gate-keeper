#!/usr/bin/env bash
# layer3.sh — Runtime verification (runs after deployment)

gk_layer3_run() {
  if ! command -v kubectl >/dev/null 2>&1; then
    gk_skip_check "M" "healthz check" "kubectl not available"
    gk_skip_check "N" "pod status check" "kubectl not available"
    gk_skip_check "O" "load test" "kubectl not available"
    return 0
  fi

  gk_maybe_run "M" "healthz check" "healthz" gk_check_healthz
  gk_maybe_run "N" "pod status check" "pod_status" gk_check_pod_status
  gk_maybe_run "O" "load test" "load_test" gk_check_load_test
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
    echo "k6 not installed"
    return 0
  fi
  if [ -f "tests/loadtest/smoke.js" ]; then
    k6 run --quiet --duration=10s --vus=2 tests/loadtest/smoke.js 2>&1 || return 1
  fi
  return 0
}
