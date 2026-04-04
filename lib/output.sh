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
  case "$status" in
    PASS) printf "  ${GREEN}✓${RESET} [%s] %-35s ${GREEN}PASS${RESET}  (%sms)\n" "$id" "$name" "$duration" ;;
    FAIL) printf "  ${RED}✗${RESET} [%s] %-35s ${RED}FAIL${RESET}  (%sms)\n" "$id" "$name" "$duration" ;;
    *)    printf "  ${YELLOW}⊘${RESET} [%s] %-35s ${YELLOW}SKIP${RESET}\n" "$id" "$name" ;;
  esac
}

gk_print_blocked() {
  echo -e "  ${YELLOW}⚠ $1${RESET}"
  echo ""
}

gk_print_summary() {
  local total_ms="$1" audit_file="$2"
  local total=$((GK_PASSED + GK_FAILED + GK_SKIPPED))
  echo ""
  echo "============================================"
  if [ $GK_FAILED -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}PASSED${RESET}: ${GK_PASSED}/${total} checks (${total_ms}ms)"
  else
    echo -e "  ${RED}${BOLD}BLOCKED${RESET}: ${GK_FAILED} failed, ${GK_PASSED} passed (${total_ms}ms)"
  fi
  echo "  Audit: $audit_file"
  echo "============================================"
  echo ""
}

gk_warn() { echo -e "${YELLOW}⚠ $1${RESET}" >&2; }
gk_error() { echo -e "${RED}✗ $1${RESET}" >&2; }
