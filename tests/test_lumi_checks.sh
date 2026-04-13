#!/usr/bin/env bash
# test_lumi_checks.sh — Tests for LUMI-inspired checks (ENV-1, SEC-1, DEP-1, PY-1, TEST-1, CI Health, Pre-commit)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASSED=0
FAILED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
RESET='\033[0m'

assert_pass() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf "  ${GREEN}✓${RESET} %s\n" "$name"
    ((PASSED++)) || true
  else
    printf "  ${RED}✗${RESET} %s\n" "$name"
    ((FAILED++)) || true
  fi
}

assert_fail() {
  local name="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    printf "  ${GREEN}✓${RESET} %s (expected fail)\n" "$name"
    ((PASSED++)) || true
  else
    printf "  ${RED}✗${RESET} %s (expected fail but passed)\n" "$name"
    ((FAILED++)) || true
  fi
}

assert_contains() {
  local name="$1" expected="$2"; shift 2
  local output=$("$@" 2>&1 || true)
  if echo "$output" | grep -q "$expected"; then
    printf "  ${GREEN}✓${RESET} %s\n" "$name"
    ((PASSED++)) || true
  else
    printf "  ${RED}✗${RESET} %s (expected '%s')\n" "$name" "$expected"
    ((FAILED++)) || true
  fi
}

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

echo ""
echo "============================================"
echo "  LUMI Checks Test Suite"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# Source the gate-keeper libs
# ---------------------------------------------------------------------------
source "$PROJECT_DIR/lib/output.sh"
source "$PROJECT_DIR/lib/core.sh"
source "$PROJECT_DIR/lib/layer1.sh"
source "$PROJECT_DIR/lib/checks_env.sh"
source "$PROJECT_DIR/lib/checks_quality.sh"
source "$PROJECT_DIR/lib/audit_ext.sh"
source "$PROJECT_DIR/lib/precommit.sh"

# ---------------------------------------------------------------------------
# ENV-1: Environment placeholder detection
# ---------------------------------------------------------------------------
echo "── ENV-1: Environment placeholder detection ──"

# Scaffold a minimal project directory for env tests
ENV_DIR="$TEST_TMPDIR/env-test"
mkdir -p "$ENV_DIR"

# Test: .env with CHANGEME placeholder → should fail
printf 'DB_PASSWORD=CHANGEME\n' > "$ENV_DIR/.env"

_run_env_placeholder_fail() {
  (cd "$ENV_DIR" && gk_check_env_placeholders)
}
assert_fail "placeholder CHANGEME triggers failure" _run_env_placeholder_fail

# Test: clean .env with real value → should pass
printf 'DB_PASSWORD=actual_value\n' > "$ENV_DIR/.env"

_run_env_placeholder_pass() {
  (cd "$ENV_DIR" && gk_check_env_placeholders)
}
assert_pass "real value passes env placeholder check" _run_env_placeholder_pass

# Test: empty value in production .env → should fail
printf 'API_KEY=\n' > "$ENV_DIR/.env.production"
rm -f "$ENV_DIR/.env"

_run_env_empty_prod_fail() {
  (cd "$ENV_DIR" && gk_check_env_placeholders)
}
assert_fail "empty value in .env.production triggers failure" _run_env_empty_prod_fail

# Test: empty value in plain .env → should pass (intentional falsy)
rm -f "$ENV_DIR/.env.production"
printf 'OPTIONAL_FEATURE=\n' > "$ENV_DIR/.env"

_run_env_empty_dev_pass() {
  (cd "$ENV_DIR" && gk_check_env_placeholders)
}
assert_pass "empty value in .env is allowed (intentional falsy)" _run_env_empty_dev_pass

# ---------------------------------------------------------------------------
# SEC-1: Secret file reference integrity
# ---------------------------------------------------------------------------
echo ""
echo "── SEC-1: Secret file reference integrity ──"

SEC_DIR="$TEST_TMPDIR/sec-test"
mkdir -p "$SEC_DIR"

# Test: docker-compose with pem volume, no .gitignore, no setup script → fail
cat > "$SEC_DIR/docker-compose.yml" <<'YAML'
version: "3.9"
services:
  app:
    image: myapp:latest
    volumes:
      - "./jwt_private.pem:/app/jwt_private.pem"
YAML

_run_sec_no_gitignore() {
  (cd "$SEC_DIR" && gk_check_secret_file_refs)
}
assert_fail "missing .gitignore and setup script triggers failure" _run_sec_no_gitignore

# Test: add .gitignore entry and a setup script that references pem → should pass
printf 'jwt_private.pem\n' > "$SEC_DIR/.gitignore"
mkdir -p "$SEC_DIR/scripts"
cat > "$SEC_DIR/scripts/setup-server.sh" <<'SH'
#!/bin/bash
openssl genrsa -out jwt_private.pem 4096
openssl rsa -in jwt_private.pem -pubout -out jwt_public.pem
SH

_run_sec_with_gitignore_and_script() {
  (cd "$SEC_DIR" && gk_check_secret_file_refs)
}
assert_pass "gitignore entry and setup script resolves secret ref" _run_sec_with_gitignore_and_script

# ---------------------------------------------------------------------------
# DEP-1: Dependency lock compatibility
# ---------------------------------------------------------------------------
echo ""
echo "── DEP-1: Dependency lock compatibility ──"

DEP_DIR="$TEST_TMPDIR/dep-test"
mkdir -p "$DEP_DIR/.github/workflows"

# Test: Cargo.lock v4 + CI with old Rust (1.77) → fail
cat > "$DEP_DIR/Cargo.lock" <<'TOML'
# This file is automatically @generated by Cargo.
# It is not intended for manual editing.
version = 4
TOML

cat > "$DEP_DIR/.github/workflows/ci.yml" <<'YAML'
name: CI
on: [push]
env:
  RUST_VERSION: "1.77"
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
YAML

_run_dep_cargo_old_rust() {
  (cd "$DEP_DIR" && gk_check_dep_lock_compat)
}
assert_fail "Cargo.lock v4 with Rust 1.77 triggers failure" _run_dep_cargo_old_rust

# Test: same Cargo.lock v4 + CI with "stable" Rust → pass
cat > "$DEP_DIR/.github/workflows/ci.yml" <<'YAML'
name: CI
on: [push]
env:
  RUST_VERSION: "stable"
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
YAML

_run_dep_cargo_stable_rust() {
  (cd "$DEP_DIR" && gk_check_dep_lock_compat)
}
assert_pass "Cargo.lock v4 with stable Rust passes" _run_dep_cargo_stable_rust

# Test: package-lock.json lockfileVersion 3 + CI with Node 14 → fail
rm -f "$DEP_DIR/Cargo.lock"
cat > "$DEP_DIR/package-lock.json" <<'JSON'
{
  "name": "my-app",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {}
}
JSON

cat > "$DEP_DIR/.github/workflows/ci.yml" <<'YAML'
name: CI
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@v3
        with:
          node-version: "14"
YAML

_run_dep_npm_old_node() {
  (cd "$DEP_DIR" && gk_check_dep_lock_compat)
}
assert_fail "package-lock v3 with Node 14 triggers failure" _run_dep_npm_old_node

# ---------------------------------------------------------------------------
# PY-1: Python duplicate module names
# ---------------------------------------------------------------------------
echo ""
echo "── PY-1: Python duplicate module names ──"

PY_DIR="$TEST_TMPDIR/py-test"
mkdir -p "$PY_DIR/apps/svc-a" "$PY_DIR/apps/svc-b"

touch "$PY_DIR/apps/svc-a/main.py"
touch "$PY_DIR/apps/svc-b/main.py"

# No mypy config → default whole-project scan → should warn
_run_py_duplicate_modules() {
  (cd "$PY_DIR" && gk_check_python_duplicate_modules)
}
assert_contains "duplicate main.py with no mypy config warns" "Duplicate" _run_py_duplicate_modules
assert_fail "duplicate main.py without per-app config triggers failure" _run_py_duplicate_modules

# With per-app mypy config → should pass (standard monorepo)
cat > "$PY_DIR/pyproject.toml" <<'TOML'
[tool.mypy]
files = ["apps/svc-a", "apps/svc-b"]
TOML

_run_py_duplicate_with_config() {
  (cd "$PY_DIR" && gk_check_python_duplicate_modules)
}
assert_pass "duplicate main.py with per-app mypy config passes" _run_py_duplicate_with_config
rm -f "$PY_DIR/pyproject.toml"

# ---------------------------------------------------------------------------
# TEST-1: Test isolation
# ---------------------------------------------------------------------------
echo ""
echo "── TEST-1: Test isolation ──"

TEST_DIR="$TEST_TMPDIR/test-isolation"
mkdir -p "$TEST_DIR/tests"

# Create conftest.py with module-level Limiter (no teardown)
cat > "$TEST_DIR/tests/conftest.py" <<'PYTHON'
import pytest
from slowapi import Limiter

limiter = Limiter(key_func=lambda: "global")

@pytest.fixture
def client():
    return limiter
PYTHON

_run_test_isolation_warning() {
  (cd "$TEST_DIR" && gk_check_test_isolation)
}
assert_contains "module-level Limiter triggers isolation warning" "module-level" _run_test_isolation_warning

# Test: async test without marker and no global asyncio_mode → should warn
mkdir -p "$TEST_DIR/tests"
cat > "$TEST_DIR/tests/test_async.py" <<'PYTHON'
async def test_something():
    assert True
PYTHON

_run_test_async_unmarked() {
  (cd "$TEST_DIR" && gk_check_test_isolation)
}
assert_contains "unmarked async test triggers warning" "async test" _run_test_async_unmarked
rm -f "$TEST_DIR/tests/test_async.py"

# ---------------------------------------------------------------------------
# CI Health Audit
# ---------------------------------------------------------------------------
echo ""
echo "── CI Health Audit ──"

HEALTH_DIR="$TEST_TMPDIR/health-test"
mkdir -p "$HEALTH_DIR/.gate-audit"

# Create 5 audit JSON files: 2 PASSED (older), then 3 BLOCKED (newer).
# Write PASSED files first so BLOCKED files get a later mtime, making
# ls -t list BLOCKED entries first (most recent = newest streak).
for i in 4 5; do
  cat > "$HEALTH_DIR/.gate-audit/audit-2024-01-0${i}.json" <<JSON
{
  "timestamp": "2024-01-0${i}T10:00:00Z",
  "git_sha": "abc${i}def",
  "project": "test-project",
  "passed": 8,
  "failed": 0,
  "warnings": 0,
  "verdict": "PASSED",
  "checks": []
}
JSON
done

# Use touch -t to guarantee deterministic mtime ordering (no sleep needed)
for i in 1 2 3; do
  cat > "$HEALTH_DIR/.gate-audit/audit-2024-01-0${i}.json" <<JSON
{
  "timestamp": "2024-01-0${i}T10:00:00Z",
  "git_sha": "abc${i}def",
  "project": "test-project",
  "passed": 5,
  "failed": 3,
  "warnings": 0,
  "verdict": "BLOCKED",
  "checks": []
}
JSON
  # Touch with future timestamp to ensure BLOCKED files sort newest (format: YYYYMMDDhhmm.SS)
  touch -t "20240110010${i}.00" "$HEALTH_DIR/.gate-audit/audit-2024-01-0${i}.json"
done
# Ensure PASSED files have older timestamps
touch -t "202401040100.00" "$HEALTH_DIR/.gate-audit/audit-2024-01-04.json"
touch -t "202401050100.00" "$HEALTH_DIR/.gate-audit/audit-2024-01-05.json"

_run_health_blocked() {
  GK_AUDIT_DIR="$HEALTH_DIR/.gate-audit" gk_audit_health
}
assert_contains "health report shows consecutive BLOCKED streak" "consecutive BLOCKED" _run_health_blocked
assert_contains "health report shows pass rate" "Pass rate" _run_health_blocked

# ---------------------------------------------------------------------------
# Pre-commit Generation
# ---------------------------------------------------------------------------
echo ""
echo "── Pre-commit Generation ──"

PRECOMMIT_DIR="$TEST_TMPDIR/precommit-test"
mkdir -p "$PRECOMMIT_DIR"

touch "$PRECOMMIT_DIR/pyproject.toml"
touch "$PRECOMMIT_DIR/Cargo.toml"

_run_precommit_generate() {
  (cd "$PRECOMMIT_DIR" && gk_generate_precommit)
}

_check_precommit_file_exists() {
  (cd "$PRECOMMIT_DIR" && gk_generate_precommit >/dev/null 2>&1; [ -f "$PRECOMMIT_DIR/.pre-commit-config.yaml" ])
}
assert_pass "pre-commit config file is created" _check_precommit_file_exists

assert_contains "generated config includes ruff for Python" "ruff" \
  bash -c "cat '$PRECOMMIT_DIR/.pre-commit-config.yaml'"

assert_contains "generated config includes cargo-clippy for Rust" "cargo-clippy" \
  bash -c "cat '$PRECOMMIT_DIR/.pre-commit-config.yaml'"

# ---------------------------------------------------------------------------
# Raw Git Hook Generation (.githooks/pre-commit)
# ---------------------------------------------------------------------------
echo ""
echo "── Raw Git Hook Generation ──"

HOOKS_DIR="$TEST_TMPDIR/hooks-test"
mkdir -p "$HOOKS_DIR"

# Create a multi-language project
touch "$HOOKS_DIR/pyproject.toml"
touch "$HOOKS_DIR/Cargo.toml"
touch "$HOOKS_DIR/package.json"
mkdir -p "$HOOKS_DIR/src"
touch "$HOOKS_DIR/src/main.py"
touch "$HOOKS_DIR/deploy.sh"

_run_hooks_generate() {
  (cd "$HOOKS_DIR" && gk_generate_githooks)
}

_check_hooks_file_exists() {
  (cd "$HOOKS_DIR" && gk_generate_githooks >/dev/null 2>&1; [ -f "$HOOKS_DIR/.githooks/pre-commit" ])
}
assert_pass "raw git hook file is created" _check_hooks_file_exists

_check_hooks_executable() {
  [ -x "$HOOKS_DIR/.githooks/pre-commit" ]
}
assert_pass "raw git hook is executable" _check_hooks_executable

assert_contains "hook contains staged file detection" "git diff --cached" \
  bash -c "cat '$HOOKS_DIR/.githooks/pre-commit'"

assert_contains "hook contains language routing" "has_lang" \
  bash -c "cat '$HOOKS_DIR/.githooks/pre-commit'"

assert_contains "hook contains parallel execution" "PIDS" \
  bash -c "cat '$HOOKS_DIR/.githooks/pre-commit'"

assert_contains "hook contains no-verify bypass hint" "no-verify" \
  bash -c "cat '$HOOKS_DIR/.githooks/pre-commit'"

assert_contains "hook contains tool-missing WARNING pattern" "WARNING:" \
  bash -c "cat '$HOOKS_DIR/.githooks/pre-commit'"

assert_contains "hook includes Python checks (ruff)" "ruff" \
  bash -c "cat '$HOOKS_DIR/.githooks/pre-commit'"

assert_contains "hook includes Rust checks (cargo clippy)" "cargo clippy" \
  bash -c "cat '$HOOKS_DIR/.githooks/pre-commit'"

assert_contains "hook includes TypeScript checks (eslint)" "eslint" \
  bash -c "cat '$HOOKS_DIR/.githooks/pre-commit'"

assert_contains "hook includes Shell checks (shellcheck)" "shellcheck" \
  bash -c "cat '$HOOKS_DIR/.githooks/pre-commit'"

assert_contains "hook includes gate-keeper layer 1" "gate-keeper" \
  bash -c "cat '$HOOKS_DIR/.githooks/pre-commit'"

# Test: overwrite protection
_run_hooks_no_overwrite() {
  (cd "$HOOKS_DIR" && gk_generate_githooks 2>&1)
}
assert_fail "refuses to overwrite without --force" _run_hooks_no_overwrite

# Test: overwrite with --force
_run_hooks_force_overwrite() {
  (cd "$HOOKS_DIR" && GK_FORCE=true gk_generate_githooks 2>&1)
}
assert_pass "overwrites with GK_FORCE=true" _run_hooks_force_overwrite

# Test: Python-only project generates only Python hooks
HOOKS_PY_DIR="$TEST_TMPDIR/hooks-py-only"
mkdir -p "$HOOKS_PY_DIR"
touch "$HOOKS_PY_DIR/pyproject.toml"
touch "$HOOKS_PY_DIR/main.py"

_run_hooks_py_only() {
  (cd "$HOOKS_PY_DIR" && gk_generate_githooks >/dev/null 2>&1
   # Should have Python but not Rust
   grep -q "ruff" "$HOOKS_PY_DIR/.githooks/pre-commit" && \
   ! grep -q "cargo clippy" "$HOOKS_PY_DIR/.githooks/pre-commit")
}
assert_pass "Python-only project skips Rust hooks" _run_hooks_py_only

# Test: setup-hooks configures core.hooksPath (requires git repo)
HOOKS_GIT_DIR="$TEST_TMPDIR/hooks-git-test"
mkdir -p "$HOOKS_GIT_DIR"
(cd "$HOOKS_GIT_DIR" && git init -q)
mkdir -p "$HOOKS_GIT_DIR/.githooks"
touch "$HOOKS_GIT_DIR/.githooks/pre-commit"

_run_setup_hooks() {
  (cd "$HOOKS_GIT_DIR" && gk_setup_hooks_path >/dev/null 2>&1
   local hp=$(cd "$HOOKS_GIT_DIR" && git config core.hooksPath)
   [ "$hp" = ".githooks" ])
}
assert_pass "setup-hooks sets core.hooksPath to .githooks" _run_setup_hooks

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASSED passed, $FAILED failed"
[ $FAILED -eq 0 ] && exit 0 || exit 1
