#!/usr/bin/env bash
# output.sh — Terminal output formatting

if [ "${GK_CI:-false}" = "true" ] || [ ! -t 1 ]; then
  RED="" GREEN="" YELLOW="" BLUE="" BOLD="" RESET=""
else
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  RESET='\033[0m'
fi

gk_print_header() {
  echo ""
  echo "============================================"
  echo "  Gate Keeper v${VERSION} · ${GK_PROJECT:-unknown}"
  echo "============================================"
  echo ""
}

gk_print_layer_header() {
  local layer="$1" name="$2"
  echo ""
  echo -e "${BOLD}── Layer $layer: $name ──${RESET}"
  echo ""
}

gk_print_check() {
  local id="$1" name="$2" status="$3" duration="${4:-0}"
  # --quiet: suppress PASS and INFO output
  if [ "${GK_QUIET:-false}" = true ] && { [ "$status" = "PASS" ] || [ "$status" = "INFO" ]; }; then
    return 0
  fi
  case "$status" in
    PASS) printf "  ${GREEN}✓${RESET} [%s] %-35s ${GREEN}PASS${RESET}  (%sms)\n" "$id" "$name" "$duration" ;;
    FAIL) printf "  ${RED}✗${RESET} [%s] %-35s ${RED}FAIL${RESET}  (%sms)\n" "$id" "$name" "$duration" ;;
    HIGH) printf "  ${RED}!${RESET} [%s] %-35s ${RED}HIGH${RESET}  (%sms)\n" "$id" "$name" "$duration" ;;
    WARN) printf "  ${YELLOW}⚠${RESET} [%s] %-35s ${YELLOW}WARN${RESET}  (%sms)\n" "$id" "$name" "$duration" ;;
    INFO) printf "  ${BLUE}ℹ${RESET} [%s] %-35s ${BLUE}INFO${RESET}  (%sms)\n" "$id" "$name" "$duration" ;;
    *)    printf "  ${YELLOW}⊘${RESET} [%s] %-35s ${YELLOW}SKIP${RESET}\n" "$id" "$name" ;;
  esac
}

gk_print_blocked() {
  echo -e "  ${YELLOW}⚠ $1${RESET}"
  echo ""
}

gk_print_summary() {
  local total_ms="$1" audit_file="$2"
  local total=$((GK_PASSED + GK_FAILED + GK_HIGHS + GK_SKIPPED + GK_WARNINGS + GK_INFOS))
  echo ""
  echo "============================================"
  if [ $GK_FAILED -gt 0 ] || [ $GK_HIGHS -gt 0 ]; then
    local fail_detail="${GK_FAILED} critical"
    [ $GK_HIGHS -gt 0 ] && fail_detail="${fail_detail}, ${GK_HIGHS} high"
    echo -e "  ${RED}${BOLD}BLOCKED${RESET}: ${fail_detail}, ${GK_PASSED} passed (${total_ms}ms)"
  elif [ $GK_WARNINGS -gt 0 ]; then
    echo -e "  ${GREEN}${BOLD}PASSED${RESET}: ${GK_PASSED}/${total} checks, ${GK_WARNINGS} warning(s) (${total_ms}ms)"
  else
    echo -e "  ${GREEN}${BOLD}PASSED${RESET}: ${GK_PASSED}/${total} checks (${total_ms}ms)"
  fi
  [ "$GK_FAIL_ON" != "critical" ] && echo "  Fail-on: $GK_FAIL_ON"
  echo "  Audit: $audit_file"
  echo "============================================"
  echo ""
}

gk_warn() { echo -e "${YELLOW}⚠ $1${RESET}" >&2; }
gk_error() { echo -e "${RED}✗ $1${RESET}" >&2; }
