#!/usr/bin/env bash
# Gate Keeper test runner
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
PASSED=0
FAILED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
RESET='\033[0m'

assert_pass() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf "  ${GREEN}✓${RESET} %s\n" "$name"
    ((PASSED++)) || true
  else
    printf "  ${RED}✗${RESET} %s\n" "$name"
    ((FAILED++)) || true
  fi
}

assert_fail() {
  local name="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    printf "  ${GREEN}✓${RESET} %s (expected fail)\n" "$name"
    ((PASSED++)) || true
  else
    printf "  ${RED}✗${RESET} %s (expected fail but passed)\n" "$name"
    ((FAILED++)) || true
  fi
}

assert_contains() {
  local name="$1" expected="$2"
  shift 2
  local output=$("$@" 2>&1 || true)
  if echo "$output" | grep -q "$expected"; then
    printf "  ${GREEN}✓${RESET} %s\n" "$name"
    ((PASSED++)) || true
  else
    printf "  ${RED}✗${RESET} %s (expected '%s')\n" "$name" "$expected"
    ((FAILED++)) || true
  fi
}

echo ""
echo "============================================"
echo "  Gate Keeper Test Suite"
echo "============================================"
echo ""

# --- Test: CLI basics ---
echo "── CLI Basics ──"
assert_pass "version command" "$PROJECT_DIR/bin/gate-keeper" version
assert_pass "help command" "$PROJECT_DIR/bin/gate-keeper" help
assert_contains "version output" "v1.0.0" "$PROJECT_DIR/bin/gate-keeper" version

# --- Test: Init ---
echo ""
echo "── Init ──"
cd "$FIXTURES_DIR/good-project"
rm -f .gatekeeper.yaml
assert_pass "init generates config" "$PROJECT_DIR/bin/gate-keeper" init --type=minimal
assert_pass "config file created" test -f .gatekeeper.yaml
assert_fail "init refuses overwrite" "$PROJECT_DIR/bin/gate-keeper" init
assert_pass "init --force overwrites" "$PROJECT_DIR/bin/gate-keeper" init --force --type=minimal
rm -f .gatekeeper.yaml

# --- Test: Layer 1 checks ---
echo ""
echo "── Layer 1: Good Project ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
sed -i.bak 's/my-project/test-project/' .gatekeeper.yaml && rm -f .gatekeeper.yaml.bak
assert_pass "layer 1 passes on good project" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

echo ""
echo "── Layer 1: Bad Project ──"
cd "$FIXTURES_DIR/bad-project"
cp "$PROJECT_DIR/templates/k8s-go.yaml" .gatekeeper.yaml
sed -i.bak 's/my-project/bad-project/' .gatekeeper.yaml && rm -f .gatekeeper.yaml.bak
assert_fail "layer 1 fails on secretRef" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# --- Test: Config-driven disable ---
echo ""
echo "── Config-driven Check Disable ──"
cd "$FIXTURES_DIR/bad-project"
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: production
layer1:
  secretref_ban: false
  namespace_consistency: false
  port_chain: false
  deprecated_refs: false
YML
assert_pass "disabled checks are skipped" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml

# --- Test: Audit log ---
echo ""
echo "── Audit Log ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
rm -rf .gate-audit
"$PROJECT_DIR/bin/gate-keeper" run --layer=1 >/dev/null 2>&1 || true
assert_pass "audit dir created" test -d .gate-audit
assert_pass "audit log exists" ls .gate-audit/*.json >/dev/null 2>&1
assert_contains "audit log has verdict" "PASSED" cat .gate-audit/*.json
rm -rf .gate-audit .gatekeeper.yaml

# --- Test: Doctor ---
echo ""
echo "── Doctor ──"
cd "$FIXTURES_DIR/good-project"
assert_contains "doctor finds no config" "Config not found" "$PROJECT_DIR/bin/gate-keeper" doctor

# --- Summary ---
echo ""
echo "============================================"
TOTAL=$((PASSED + FAILED))
if [ $FAILED -eq 0 ]; then
  printf "  ${GREEN}ALL PASSED${RESET}: %d/%d\n" "$PASSED" "$TOTAL"
else
  printf "  ${RED}FAILED${RESET}: %d failed, %d passed\n" "$FAILED" "$PASSED"
fi
echo "============================================"
echo ""

[ $FAILED -eq 0 ] || exit 1
