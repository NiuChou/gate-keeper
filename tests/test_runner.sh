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
assert_contains "version output" "v1.2.0" "$PROJECT_DIR/bin/gate-keeper" version

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

# --- Test: Init template detection ---
echo ""
echo "── Init Template Detection ──"
cd "$FIXTURES_DIR/good-project"
rm -f .gatekeeper.yaml
for tmpl in minimal k8s-go k8s-python nextjs monorepo; do
  assert_pass "init --type=$tmpl" "$PROJECT_DIR/bin/gate-keeper" init --type=$tmpl --force
done
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

# --- Test: Severity — warning does not block ---
echo ""
echo "── Severity: warning failure does not block ──"
cd "$FIXTURES_DIR/bad-project"
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: production
layer1:
  secretref_ban:
    enabled: true
    severity: warning
  namespace_consistency: false
  port_chain: false
  deprecated_refs: false
YML
assert_pass "warning-severity failure exits 0" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml

# --- Test: Severity — critical blocks ---
echo ""
echo "── Severity: critical failure blocks ──"
cd "$FIXTURES_DIR/bad-project"
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: production
layer1:
  secretref_ban:
    enabled: true
    severity: critical
  namespace_consistency: false
  port_chain: false
  deprecated_refs: false
YML
assert_fail "critical-severity failure exits 1" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml

# --- Test: exclude_pattern ---
echo ""
echo "── exclude_pattern ──"
cd "$FIXTURES_DIR/bad-project"
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: production
layer1:
  secretref_ban:
    enabled: true
    severity: critical
    exclude_pattern: "secretRef"
  namespace_consistency: false
  port_chain: false
  deprecated_refs: false
YML
assert_pass "exclude_pattern suppresses secretRef match" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml

# --- Test: add command ---
echo ""
echo "── Add Command ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
sed -i.bak 's/my-project/test-project/' .gatekeeper.yaml && rm -f .gatekeeper.yaml.bak

assert_pass "add creates custom check" \
  "$PROJECT_DIR/bin/gate-keeper" add --id=no_console_log --pattern="console.log" --paths="."
assert_contains "add confirms success" "no_debugger" \
  "$PROJECT_DIR/bin/gate-keeper" add --id=no_debugger --pattern="debugger;" --paths="." --severity=warning --description="Ban debugger"
assert_fail "add rejects duplicate id" \
  "$PROJECT_DIR/bin/gate-keeper" add --id=no_console_log --pattern="console.log" --paths="."
assert_fail "add requires --id" \
  "$PROJECT_DIR/bin/gate-keeper" add --pattern="console.log"
assert_fail "add requires --pattern" \
  "$PROJECT_DIR/bin/gate-keeper" add --id=some_check
assert_fail "add fails without config" bash -c \
  "GK_CONFIG=.no_such_file.yaml $PROJECT_DIR/bin/gate-keeper add --id=x --pattern=y"

# Verify run executes custom checks (no_console_log pattern not present in project → should PASS)
assert_pass "run executes custom checks (pass case)" \
  "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml

# Test custom check FAIL: add a pattern that matches an existing file
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
sed -i.bak 's/my-project/test-project/' .gatekeeper.yaml && rm -f .gatekeeper.yaml.bak
# Add a check that will find "project:" in .gatekeeper.yaml itself (severity=critical to block)
"$PROJECT_DIR/bin/gate-keeper" add --id=find_project_key --pattern="^project:" --paths=".gatekeeper.yaml" --severity=critical >/dev/null 2>&1 || true
assert_fail "run fails when custom check matches" \
  "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml .gate-audit 2>/dev/null || true
rm -rf .gate-audit

# --- Test: Custom Checks (pattern and command modes) ---
echo ""
echo "── Custom Checks ──"
cd "$FIXTURES_DIR/good-project"

# Test pattern mode: pattern absent → check passes
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: no_console_log
    description: "Ban console.log"
    pattern: "console.log"
    paths: "src"
YML
assert_pass "custom pattern check passes when pattern absent" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Test pattern mode: pattern present → check fails
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: find_greet
    description: "Detect greet function"
    pattern: "function greet"
    paths: "src"
YML
assert_fail "custom pattern check fails when pattern found" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Test command mode: passing command → check passes
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: true_cmd
    description: "Command that always succeeds"
    command: "true"
YML
assert_pass "custom command check passes on exit 0" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Test command mode: failing command → check fails
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: false_cmd
    description: "Command that always fails"
    command: "false"
YML
assert_fail "custom command check fails on exit 1" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Test no custom_checks section → no effect
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
YML
assert_pass "no custom_checks section has no effect" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

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

# --- Test: Doctor with config ---
echo ""
echo "── Doctor (with config) ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
assert_contains "doctor finds config" "OK" "$PROJECT_DIR/bin/gate-keeper" doctor
rm -f .gatekeeper.yaml

# --- Test: Layer 2 (no kubectl) ---
echo ""
echo "── Layer 2: No kubectl ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/k8s-go.yaml" .gatekeeper.yaml
sed -i.bak 's/my-project/test-project/' .gatekeeper.yaml && rm -f .gatekeeper.yaml.bak
assert_contains "layer 2 skips without kubectl" "SKIP" "$PROJECT_DIR/bin/gate-keeper" run --layer=2
rm -f .gatekeeper.yaml

# --- Test: Layer 3 (no kubectl) ---
echo ""
echo "── Layer 3: No kubectl ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/k8s-go.yaml" .gatekeeper.yaml
sed -i.bak 's/my-project/test-project/' .gatekeeper.yaml && rm -f .gatekeeper.yaml.bak
assert_contains "layer 3 skips without kubectl" "SKIP" "$PROJECT_DIR/bin/gate-keeper" run --layer=all
rm -f .gatekeeper.yaml

# --- Test: JSON output ---
echo ""
echo "── JSON Output ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
rm -rf .gate-audit
"$PROJECT_DIR/bin/gate-keeper" run --layer=1 --format=json >/dev/null 2>&1 || true
assert_contains "json audit has timestamp" "timestamp" cat .gate-audit/*.json
assert_contains "json audit has checks array" "checks" cat .gate-audit/*.json
assert_contains "json audit has git_sha" "git_sha" cat .gate-audit/*.json
rm -rf .gate-audit .gatekeeper.yaml

# --- Test: CI mode ---
echo ""
echo "── CI Mode ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
rm -rf .gate-audit
assert_pass "ci mode runs" "$PROJECT_DIR/bin/gate-keeper" run --layer=1 --ci
rm -rf .gate-audit .gatekeeper.yaml

# --- Test: Supervision (stamp / integrity) ---
echo ""
echo "── Supervision: Stamp & Integrity ──"
cd "$FIXTURES_DIR/good-project"
rm -f .gate-keeper.sha256

# stamp generates hash file
assert_pass "stamp generates hash file" "$PROJECT_DIR/bin/gate-keeper" stamp
assert_pass "hash file created" test -f .gate-keeper.sha256

# integrity verification passes on unmodified files
assert_pass "stamp --verify passes on clean files" "$PROJECT_DIR/bin/gate-keeper" stamp --verify

# tamper: append a byte to one of the lib files, then verify fails
TMPBAK=$(cat "$PROJECT_DIR/lib/supervision.sh")
echo "# tamper" >> "$PROJECT_DIR/lib/supervision.sh"
assert_fail "stamp --verify fails after tampering" "$PROJECT_DIR/bin/gate-keeper" stamp --verify
# restore
echo "$TMPBAK" > "$PROJECT_DIR/lib/supervision.sh"

rm -f .gate-keeper.sha256

# --- Test: Docker Compose template ---
echo ""
echo "── Docker Compose Template ──"
cd "$FIXTURES_DIR/good-project"
rm -f .gatekeeper.yaml
assert_pass "init --type=docker-compose" "$PROJECT_DIR/bin/gate-keeper" init --type=docker-compose --force
assert_pass "docker-compose config created" test -f .gatekeeper.yaml
assert_contains "docker-compose has compose_healthcheck" "compose_healthcheck" cat .gatekeeper.yaml
rm -f .gatekeeper.yaml

# --- Test: .gatekeeperignore support ---
echo ""
echo "── .gatekeeperignore ──"
cd "$FIXTURES_DIR/good-project"

# Create a file that would normally match, inside a dir we want to ignore
mkdir -p ignored_dir
echo "password = 'secret123'" > ignored_dir/bad_code.py

cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: no_secrets
    pattern: "password.*=.*secret"
    paths: "ignored_dir"
    severity: critical
YML

# Without .gatekeeperignore it should fail
assert_fail "pattern check finds match without ignore" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# With .gatekeeperignore it should pass
echo "ignored_dir" > .gatekeeperignore
assert_pass "pattern check passes with .gatekeeperignore" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -rf ignored_dir .gatekeeperignore .gatekeeper.yaml .gate-audit

# --- Test: exclude_dirs in custom check ---
echo ""
echo "── exclude_dirs ──"
cd "$FIXTURES_DIR/good-project"
mkdir -p dist_dir src_dir
echo "password = 'secret123'" > dist_dir/bundle.js
echo "clean code here" > src_dir/app.py

cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: no_secrets
    pattern: "password.*=.*secret"
    paths: "dist_dir src_dir"
    exclude_dirs: "dist_dir"
    severity: critical
YML

assert_pass "exclude_dirs filters out directory" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -rf dist_dir src_dir .gatekeeper.yaml .gate-audit

# --- Test: fix_hint in custom check ---
echo ""
echo "── fix_hint ──"
cd "$FIXTURES_DIR/good-project"
mkdir -p hint_test
echo "console.log('debug');" > hint_test/app.js

cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: no_console
    pattern: "console.log"
    paths: "hint_test"
    severity: warning
    fix_hint: "Remove console.log before production."
YML

assert_contains "fix_hint appears in output" "Fix:" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -rf hint_test .gatekeeper.yaml .gate-audit

# --- Test: Custom check with pipe in command (separator bug fix) ---
echo ""
echo "── Pipe in command (separator fix) ──"
cd "$FIXTURES_DIR/good-project"

cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: pipe_test
    description: "Command with pipe should work"
    command: "echo hello | grep hello"
    severity: critical
YML

assert_pass "command with pipe works" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: Audit --diff ---
echo ""
echo "── Audit Diff ──"
cd "$FIXTURES_DIR/good-project"
rm -rf .gate-audit

# Run twice with different configs to produce different results
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: always_fail
    command: "false"
    severity: critical
YML
"$PROJECT_DIR/bin/gate-keeper" run --layer=1 >/dev/null 2>&1 || true
sleep 1

cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: always_pass
    command: "true"
    severity: critical
YML
"$PROJECT_DIR/bin/gate-keeper" run --layer=1 >/dev/null 2>&1 || true

assert_contains "audit --diff shows changes" "Diff:" "$PROJECT_DIR/bin/gate-keeper" audit --diff
rm -rf .gate-audit .gatekeeper.yaml

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
