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

# Assert command does NOT exit with code 1 (allows 0 or 2)
assert_not_blocked() {
  local name="$1"
  shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 1 ]; then
    printf "  ${GREEN}✓${RESET} %s (exit %d)\n" "$name" "$rc"
    ((PASSED++)) || true
  else
    printf "  ${RED}✗${RESET} %s (exit 1 = blocked)\n" "$name"
    ((FAILED++)) || true
  fi
}

# Assert command exits with specific code
assert_exit() {
  local name="$1" expected_code="$2"
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$expected_code" ]; then
    printf "  ${GREEN}✓${RESET} %s (exit %d)\n" "$name" "$rc"
    ((PASSED++)) || true
  else
    printf "  ${RED}✗${RESET} %s (expected exit %d, got %d)\n" "$name" "$expected_code" "$rc"
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
assert_contains "version output" "v2.4.0" "$PROJECT_DIR/bin/gate-keeper" version

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
assert_not_blocked "warning-severity failure does not block" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
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
  "$PROJECT_DIR/bin/gate-keeper" add --id=no_console_log --pattern="console.log" --paths="src"
assert_contains "add confirms success" "no_debugger" \
  "$PROJECT_DIR/bin/gate-keeper" add --id=no_debugger --pattern="debugger;" --paths="src" --severity=warning --description="Ban debugger"
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

# --- Test: Drift check — global mode (PASS: both pattern and requires found) ---
echo ""
echo "── Drift: global mode ──"
cd "$FIXTURES_DIR/good-project"
mkdir -p drift_test
echo "func DefineRLSPolicy() {}" > drift_test/define.go
echo "ActivateRLS(db)" > drift_test/activate.go

cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: rls_activation
    pattern: "DefineRLSPolicy"
    paths: "drift_test"
    requires: "ActivateRLS"
    requires_paths: "drift_test"
    severity: critical
    fix_hint: "Call ActivateRLS() in main.go"
YML

assert_pass "drift global: both found = PASS" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Now remove the activation call — should FAIL
rm drift_test/activate.go
assert_fail "drift global: defined but not called = FAIL" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -rf drift_test .gatekeeper.yaml .gate-audit

# --- Test: Drift check — per_file mode ---
echo ""
echo "── Drift: per_file mode ──"
cd "$FIXTURES_DIR/good-project"
mkdir -p drift_pf

# File with both pattern and requires → PASS
echo -e "func HandleRequest() {\n  ParseAccessToken(r)\n}" > drift_pf/handler_a.go

cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: access_token_check
    pattern: "func Handle"
    paths: "drift_pf"
    requires: "ParseAccessToken"
    drift_mode: per_file
    severity: critical
    fix_hint: "Add ParseAccessToken call to handler"
YML

assert_pass "drift per_file: both in same file = PASS" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Add a second file WITHOUT requires → FAIL
echo "func HandleAdmin() { /* no auth */ }" > drift_pf/handler_b.go
assert_fail "drift per_file: missing requires in file = FAIL" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -rf drift_pf .gatekeeper.yaml .gate-audit

# --- Test: Drift check — commented mode ---
echo ""
echo "── Drift: commented mode ──"
cd "$FIXTURES_DIR/good-project"
mkdir -p drift_cm

# Active code → PASS (not drifted)
echo "const auth = useAuth();" > drift_cm/app.tsx

cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: frontend_auth
    pattern: "useAuth"
    paths: "drift_cm"
    drift_mode: commented
    severity: critical
    fix_hint: "Uncomment auth code — it was disabled."
YML

assert_pass "drift commented: active code = PASS" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Comment it out → FAIL
echo "// const auth = useAuth();" > drift_cm/app.tsx
assert_fail "drift commented: only in comments = FAIL" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -rf drift_cm .gatekeeper.yaml .gate-audit

# --- Test: Drift check — pattern not found at all (skip, no drift) ---
echo ""
echo "── Drift: pattern absent ──"
cd "$FIXTURES_DIR/good-project"
mkdir -p drift_skip
echo "nothing here" > drift_skip/clean.go

cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: rls_absent
    pattern: "func EnableRLS"
    paths: "drift_skip"
    requires: "EnableRLS()"
    severity: critical
YML

assert_pass "drift: pattern absent = PASS (nothing to check)" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -rf drift_skip .gatekeeper.yaml .gate-audit

# --- Test: must_match — pattern present = PASS ---
echo ""
echo "── must_match: pattern present ──"
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
  - id: must_have_greet
    must_match: "function greet"
    paths: "src"
    severity: critical
YML
assert_pass "must_match: pattern found = PASS" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: must_match — pattern absent = FAIL ---
echo ""
echo "── must_match: pattern absent ──"
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
  - id: must_have_missing
    must_match: "THIS_PATTERN_DOES_NOT_EXIST"
    paths: "src"
    severity: critical
    fix_hint: "Add the required pattern"
YML
assert_fail "must_match: pattern missing = FAIL" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
assert_contains "must_match: shows fix_hint" "Fix:" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: must_match — warning severity does not block ---
echo ""
echo "── must_match: warning severity ──"
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
  - id: must_have_optional
    must_match: "NONEXISTENT_PATTERN"
    paths: "src"
    severity: warning
YML
assert_not_blocked "must_match: warning severity does not block" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: must_match_count — count validation ---
echo ""
echo "── must_match_count ──"
cd "$FIXTURES_DIR/good-project"
mkdir -p mm_test
echo -e "healthcheck: test1\nhealthcheck: test2\nhealthcheck: test3" > mm_test/compose.yml

cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: enough_healthchecks
    must_match: "healthcheck:"
    must_match_count: 3
    paths: "mm_test"
    severity: critical
YML
assert_pass "must_match_count: 3 found, need 3 = PASS" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Need 5 but only have 3 → FAIL
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: need_more_healthchecks
    must_match: "healthcheck:"
    must_match_count: 5
    paths: "mm_test"
    severity: critical
YML
assert_fail "must_match_count: 3 found, need 5 = FAIL" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -rf mm_test .gatekeeper.yaml .gate-audit

# ═══════════════════════════════════════════
# v2.0 New Feature Tests
# ═══════════════════════════════════════════

# --- Test: Four-level severity (high, info) ---
echo ""
echo "── v2.0: Four-level Severity ──"
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
  - id: high_sev
    pattern: "function greet"
    paths: "src"
    severity: high
YML
assert_fail "high-severity failure blocks" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: info_sev
    pattern: "function greet"
    paths: "src"
    severity: info
YML
assert_pass "info-severity does not block" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: --fail-on threshold ---
echo ""
echo "── v2.0: --fail-on Threshold ──"
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
assert_fail "fail-on=critical blocks on critical" "$PROJECT_DIR/bin/gate-keeper" run --layer=1 --fail-on=critical
assert_not_blocked "fail-on=none never blocks" "$PROJECT_DIR/bin/gate-keeper" run --layer=1 --fail-on=none
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: Exit code semantics ---
echo ""
echo "── v2.0: Exit Code Semantics ──"
cd "$FIXTURES_DIR/good-project"

# All pass → exit 0
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
YML
assert_exit "all pass = exit 0" 0 "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Warning only → exit 2
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: warn_test
    pattern: "function greet"
    paths: "src"
    severity: warning
YML
assert_exit "warning only = exit 2" 2 "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Critical fail → exit 1
cat > .gatekeeper.yaml << 'YML'
version: 1
project: test
namespace: default
layer1:
  shell_syntax: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
custom_checks:
  - id: crit_test
    pattern: "function greet"
    paths: "src"
    severity: critical
YML
assert_exit "critical fail = exit 1" 1 "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: SARIF output ---
echo ""
echo "── v2.0: SARIF Output ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
local_output=$("$PROJECT_DIR/bin/gate-keeper" run --layer=1 --format=sarif 2>&1 || true)
assert_contains "sarif has schema" '\$schema' echo "$local_output"
assert_contains "sarif has gate-keeper tool" 'gate-keeper' echo "$local_output"
assert_contains "sarif has results" 'results' echo "$local_output"
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: JUnit output ---
echo ""
echo "── v2.0: JUnit Output ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
local_output=$("$PROJECT_DIR/bin/gate-keeper" run --layer=1 --format=junit 2>&1 || true)
assert_contains "junit has xml header" '<?xml' echo "$local_output"
assert_contains "junit has testsuites" 'testsuites' echo "$local_output"
assert_contains "junit has testcase" 'testcase' echo "$local_output"
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: HTML output ---
echo ""
echo "── v2.0: HTML Output ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
local_output=$("$PROJECT_DIR/bin/gate-keeper" run --layer=1 --format=html 2>&1 || true)
assert_contains "html has doctype" 'DOCTYPE' echo "$local_output"
assert_contains "html has gate-keeper title" 'Gate Keeper' echo "$local_output"
assert_contains "html has verdict" 'verdict' echo "$local_output"
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: --dry-run ---
echo ""
echo "── v2.0: Dry Run ──"
cd "$FIXTURES_DIR/good-project"
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
assert_contains "dry-run shows DRY RUN" "DRY RUN" "$PROJECT_DIR/bin/gate-keeper" run --layer=1 --dry-run
assert_pass "dry-run exits 0" "$PROJECT_DIR/bin/gate-keeper" run --layer=1 --dry-run
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: --quiet ---
echo ""
echo "── v2.0: Quiet Mode ──"
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
  - id: warn_quiet
    pattern: "function greet"
    paths: "src"
    severity: warning
YML
local_output=$("$PROJECT_DIR/bin/gate-keeper" run --layer=1 --quiet 2>&1 || true)
if echo "$local_output" | grep -qE "✓.*PASS.*ms"; then
  printf "  ${RED}✗${RESET} quiet mode suppresses per-check PASS lines\n"
  ((FAILED++)) || true
else
  printf "  ${GREEN}✓${RESET} quiet mode suppresses per-check PASS lines\n"
  ((PASSED++)) || true
fi
assert_contains "quiet mode shows WARN" "WARN" echo "$local_output"
rm -f .gatekeeper.yaml
rm -rf .gate-audit

# --- Test: Suggest command ---
echo ""
echo "── v2.0: Suggest ──"
cd "$FIXTURES_DIR/good-project"
assert_contains "suggest detects project" "Detected" "$PROJECT_DIR/bin/gate-keeper" suggest
rm -rf .gate-audit

# --- Test: Audit trend ---
echo ""
echo "── v2.0: Audit Trend ──"
cd "$FIXTURES_DIR/good-project"
rm -rf .gate-audit
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
"$PROJECT_DIR/bin/gate-keeper" run --layer=1 >/dev/null 2>&1 || true
sleep 1
"$PROJECT_DIR/bin/gate-keeper" run --layer=1 >/dev/null 2>&1 || true
assert_contains "audit --trend shows trend" "Pass Rate" "$PROJECT_DIR/bin/gate-keeper" audit --trend
rm -rf .gate-audit .gatekeeper.yaml

# --- Test: Audit CSV export ---
echo ""
echo "── v2.0: Audit CSV Export ──"
cd "$FIXTURES_DIR/good-project"
rm -rf .gate-audit
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
"$PROJECT_DIR/bin/gate-keeper" run --layer=1 >/dev/null 2>&1 || true
assert_contains "audit --export=csv has header" "timestamp" "$PROJECT_DIR/bin/gate-keeper" audit --export=csv
rm -rf .gate-audit .gatekeeper.yaml

# --- Test: Audit heatmap ---
echo ""
echo "── v2.0: Audit Heatmap ──"
cd "$FIXTURES_DIR/good-project"
rm -rf .gate-audit
cp "$PROJECT_DIR/templates/minimal.yaml" .gatekeeper.yaml
"$PROJECT_DIR/bin/gate-keeper" run --layer=1 >/dev/null 2>&1 || true
assert_contains "audit --heatmap shows heatmap" "Heatmap" "$PROJECT_DIR/bin/gate-keeper" audit --heatmap
rm -rf .gate-audit .gatekeeper.yaml

# --- Test: Plugin list (empty) ---
echo ""
echo "── v2.0: Plugin System ──"
cd "$FIXTURES_DIR/good-project"
rm -rf .gate-plugins
assert_contains "plugin list shows no plugins" "No plugins" "$PROJECT_DIR/bin/gate-keeper" plugin list
rm -rf .gate-plugins

# --- Test: Docker Compose Checks ---
echo ""
echo "── Docker Compose Checks ──"

# Setup: go to compose fixture
cd "$FIXTURES_DIR/compose-project"

# Create config enabling all DC checks
cat > .gatekeeper.yaml << 'YML'
version: 1
project: compose-test
namespace: default
layer1:
  go_work: false
  shell_syntax: false
  python_packaging: false
  dockerfile_copy: false
  dockerfile_antipatterns: false
  secretref_ban: false
  deprecated_refs: false
  port_chain: false
  namespace_consistency: false
  dc_env_multiline:
    enabled: true
    severity: critical
  dc_env_completeness:
    enabled: true
    severity: critical
  dc_healthcheck_antipatterns:
    enabled: true
    severity: high
  dc_tmpfs_shadow:
    enabled: true
    severity: high
  dc_cap_drop_all:
    enabled: true
    severity: warning
  dc_depends_on_deadlock:
    enabled: true
    severity: warning
  dc_resource_limits:
    enabled: true
    severity: warning
    per_worker_mb: 128
layer2:
  deployment_name_match: false
  image_name_match: false
  secret_key_match: false
layer3:
  healthz: false
  pod_status: false
  load_test: false
YML

# DC-1: .env multi-line detection
assert_pass "DC-1 passes with clean .env" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# DC-1: fails with PEM in .env
cp .env .env.backup
cp fixture-env-bad-pem .env
assert_fail "DC-1 fails with PEM in .env" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
cp .env.backup .env

# DC-2: fails with missing env var
cp docker-compose.yml docker-compose.yml.backup
cp fixture-bad-env.yml docker-compose.yml
assert_fail "DC-2 fails with missing env var" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
cp docker-compose.yml.backup docker-compose.yml

# DC-3: fails on healthcheck anti-patterns
cp fixture-bad-healthcheck.yml docker-compose.yml
assert_fail "DC-3 fails on healthcheck anti-patterns" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
cp docker-compose.yml.backup docker-compose.yml

# DC-5: fails on cap_drop ALL middleware
cp fixture-bad-cap.yml docker-compose.yml
assert_not_blocked "DC-5 cap_drop warns but does not block" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
cp docker-compose.yml.backup docker-compose.yml

# DC-6: fails on circular depends_on
cp fixture-bad-circular.yml docker-compose.yml
assert_not_blocked "DC-6 circular depends warns but does not block" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
cp docker-compose.yml.backup docker-compose.yml

# DC-7: fails on resource limit
cp fixture-bad-resources.yml docker-compose.yml
assert_not_blocked "DC-7 resource limit warns but does not block" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
cp docker-compose.yml.backup docker-compose.yml

# DC checks skip when no compose files
cd "$FIXTURES_DIR/good-project"
cat > .gatekeeper.yaml << 'YML'
version: 1
project: no-compose-test
namespace: default
layer1:
  dc_env_multiline: true
  dc_env_completeness: true
  dc_healthcheck_antipatterns: true
  dc_tmpfs_shadow: true
  dc_cap_drop_all: true
  dc_depends_on_deadlock: true
  dc_resource_limits: true
YML
assert_pass "DC checks skip when no compose files" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml

# DC checks skip when disabled
cd "$FIXTURES_DIR/compose-project"
cat > .gatekeeper.yaml << 'YML'
version: 1
project: disabled-test
namespace: default
layer1:
  dc_env_multiline: false
  dc_env_completeness: false
  dc_healthcheck_antipatterns: false
  dc_tmpfs_shadow: false
  dc_cap_drop_all: false
  dc_depends_on_deadlock: false
  dc_resource_limits: false
YML
assert_pass "DC checks skip when disabled" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Cleanup
rm -f .gatekeeper.yaml .env.backup docker-compose.yml.backup

# --- Test: Next.js Rewrite Completeness (J) ---
echo ""
echo "── Next.js Rewrite Completeness (J) ──"

cd "$FIXTURES_DIR/nextjs-project"

# J: detect uncovered rewrite prefix
cat > .gatekeeper.yaml << 'YML'
version: 1
project: nextjs-test
namespace: default
layer1:
  nextjs_rewrite_completeness:
    enabled: true
    severity: critical
  fastapi_exception_handler: false
  fastapi_endpoint_try_except: false
  api_path_literal_ban: false
  ratelimit_retry_after: false
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML
# /admin/ and /metrics/ are used in api-bad.ts but no rewrite covers them
assert_fail "J: detect uncovered rewrite prefix" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
assert_contains "J: reports missing prefix" "no matching rewrite" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# J: passes when only covered prefixes are used
rm -f src/lib/api-bad.ts
cat > .gatekeeper.yaml << 'YML'
version: 1
project: nextjs-test
namespace: default
layer1:
  nextjs_rewrite_completeness:
    enabled: true
    severity: critical
  fastapi_exception_handler: false
  fastapi_endpoint_try_except: false
  api_path_literal_ban: false
  ratelimit_retry_after: false
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML
assert_pass "J: passes when all prefixes covered" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Restore bad fixture
cat > src/lib/api-bad.ts << 'TS'
import axios from "axios";
export const getAdminUsers = () => axios.get("/admin/users");
export const getMetrics = () => fetch("/metrics/dashboard");
TS

# J: disabled → should pass
cat > .gatekeeper.yaml << 'YML'
version: 1
project: nextjs-test
namespace: default
layer1:
  nextjs_rewrite_completeness: false
  fastapi_exception_handler: false
  fastapi_endpoint_try_except: false
  api_path_literal_ban: false
  ratelimit_retry_after: false
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML
assert_pass "J: skip when disabled" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# J: passes on project without next.config
cd "$FIXTURES_DIR/good-project"
cat > .gatekeeper.yaml << 'YML'
version: 1
project: no-nextjs-test
namespace: default
layer1:
  nextjs_rewrite_completeness: true
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML
assert_pass "J: passes when no next.config exists" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml

# J: no-rewrites but API calls exist → should fail
cd "$FIXTURES_DIR/nextjs-project"
cp next.config.js next.config.js.bak
cat > next.config.js << 'CONF'
module.exports = {};
CONF
cat > .gatekeeper.yaml << 'YML'
version: 1
project: nextjs-test
namespace: default
layer1:
  nextjs_rewrite_completeness:
    enabled: true
    severity: critical
    api_prefix: "/svc/"
  fastapi_exception_handler: false
  fastapi_endpoint_try_except: false
  api_path_literal_ban: false
  ratelimit_retry_after: false
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML
assert_fail "J: fails when no rewrites but API calls exist" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
mv next.config.js.bak next.config.js
rm -f .gatekeeper.yaml

# --- Test: FastAPI / API Resilience Checks (FA-1..FA-4) ---
echo ""
echo "── FastAPI / API Resilience Checks ──"

# FA-1: Global exception handler
cd "$FIXTURES_DIR/fastapi-project"
cat > .gatekeeper.yaml << 'YML'
version: 1
project: fastapi-test
namespace: default
layer1:
  fastapi_exception_handler:
    enabled: true
    severity: critical
  fastapi_endpoint_try_except: false
  api_path_literal_ban: false
  ratelimit_retry_after: false
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML

# The user_service/main.py has FastAPI() but no exception handler → should FAIL
assert_fail "FA-1: detect missing global exception handler" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
assert_contains "FA-1: reports file name" "user_service" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# FA-1 regression: only HTTPException handler (no Exception handler) must also FAIL
# This is the exact pattern that caused the 500 error — generic exceptions fall through.
cat > .gatekeeper.yaml << 'YML'
version: 1
project: fastapi-test
namespace: default
layer1:
  fastapi_exception_handler:
    enabled: true
    severity: critical
    paths: "apps/partial_handler"
  fastapi_endpoint_try_except: false
  api_path_literal_ban: false
  ratelimit_retry_after: false
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML
assert_fail "FA-1: detect HTTPException-only handler (missing Exception)" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
assert_contains "FA-1: reports missing Exception" "Exception" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# FA-2: Endpoint try/except
cat > .gatekeeper.yaml << 'YML'
version: 1
project: fastapi-test
namespace: default
layer1:
  fastapi_exception_handler: false
  fastapi_endpoint_try_except:
    enabled: true
    severity: high
  api_path_literal_ban: false
  ratelimit_retry_after: false
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML
# user_service has POST/DELETE without try/except → should detect (exit 2 for HIGH)
assert_contains "FA-2: detect endpoint without try/except" "missing try/except" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# FA-3: API path literal ban
cat > .gatekeeper.yaml << 'YML'
version: 1
project: fastapi-test
namespace: default
layer1:
  fastapi_exception_handler: false
  fastapi_endpoint_try_except: false
  api_path_literal_ban:
    enabled: true
    severity: warning
    api_prefix: "/api/"
  ratelimit_retry_after: false
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML
assert_contains "FA-3: detect hardcoded API path literals" "Hardcoded API path" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# FA-4: Retry-After header
cat > .gatekeeper.yaml << 'YML'
version: 1
project: fastapi-test
namespace: default
layer1:
  fastapi_exception_handler: false
  fastapi_endpoint_try_except: false
  api_path_literal_ban: false
  ratelimit_retry_after:
    enabled: true
    severity: critical
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML
# user_service/ratelimit.py returns 429 without Retry-After → should FAIL
assert_fail "FA-4: detect 429 without Retry-After" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
assert_contains "FA-4: reports Retry-After" "Retry-After" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Test: all FA checks disabled → should pass
cat > .gatekeeper.yaml << 'YML'
version: 1
project: fastapi-test
namespace: default
layer1:
  fastapi_exception_handler: false
  fastapi_endpoint_try_except: false
  api_path_literal_ban: false
  ratelimit_retry_after: false
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML
assert_pass "FA checks skip when disabled" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Test: FA checks on good project (gateway has handler + retry-after) → should pass
cat > .gatekeeper.yaml << 'YML'
version: 1
project: fastapi-test
namespace: default
layer1:
  fastapi_exception_handler:
    enabled: true
    severity: critical
    paths: "apps/gateway"
  fastapi_endpoint_try_except:
    enabled: true
    severity: high
    paths: "apps/gateway"
  api_path_literal_ban: false
  ratelimit_retry_after:
    enabled: true
    severity: critical
    paths: "apps/gateway"
  env_placeholders: false
  secret_file_refs: false
  python_duplicate_modules: false
  test_isolation: false
YML
assert_pass "FA checks pass on well-structured service" "$PROJECT_DIR/bin/gate-keeper" run --layer=1

# Test: FA checks pass on project with no Python files (edge case)
cd "$FIXTURES_DIR/good-project"
cat > .gatekeeper.yaml << 'YML'
version: 1
project: no-python-test
namespace: default
layer1:
  fastapi_exception_handler: true
  fastapi_endpoint_try_except: true
  api_path_literal_ban: true
  ratelimit_retry_after: true
  env_placeholders: false
  secret_file_refs: false
  dep_lock_compat: false
  python_duplicate_modules: false
  test_isolation: false
YML
assert_pass "FA checks pass when no Python/frontend files exist" "$PROJECT_DIR/bin/gate-keeper" run --layer=1
rm -f .gatekeeper.yaml

cd "$FIXTURES_DIR/fastapi-project"
rm -f .gatekeeper.yaml

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
