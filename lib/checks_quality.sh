#!/usr/bin/env bash
# checks_quality.sh — Dependency, module, and test quality checks (LUMI-inspired)

# DEP-1: Dependency lock file compatibility
# Verify lock files are compatible with the toolchain versions specified in CI or config.
gk_check_dep_lock_compat() {
  local errors=0

  # Check Cargo.lock
  if [ -f "Cargo.lock" ]; then
    local cargo_lock_version
    cargo_lock_version=$(grep -m1 '^version = ' "Cargo.lock" 2>/dev/null | awk '{print $3}' | tr -d '"')
    if [ -n "$cargo_lock_version" ] && [ "$cargo_lock_version" -ge 4 ] 2>/dev/null; then
      # Scan CI workflows for Rust toolchain version
      local ci_rust_version=""
      local workflow_file
      while IFS= read -r workflow_file; do
        [ -f "$workflow_file" ] || continue
        # Look for RUST_VERSION or toolchain specifiers
        local found_version
        found_version=$(grep -oE '(RUST_VERSION|toolchain)[[:space:]]*:[[:space:]]*"?[0-9]+\.[0-9]+[^"[:space:]]*"?' "$workflow_file" 2>/dev/null \
          | grep -oE '[0-9]+\.[0-9]+[0-9.]*' | head -1)
        if [ -n "$found_version" ]; then
          ci_rust_version="$found_version"
          break
        fi
      done < <(find .github/workflows -name '*.yml' 2>/dev/null)

      if [ -n "$ci_rust_version" ]; then
        # Extract major.minor
        local major minor
        major=$(echo "$ci_rust_version" | cut -d. -f1)
        minor=$(echo "$ci_rust_version" | cut -d. -f2)
        # Rust 1.78+ is required for Cargo.lock v4
        if [ "$major" -eq 1 ] && [ "$minor" -lt 78 ] 2>/dev/null; then
          echo "Cargo.lock v${cargo_lock_version} requires Rust 1.78+, but CI uses ${ci_rust_version}"
          echo "  Fix: Update CI toolchain version or regenerate lock file with compatible version"
          ((errors++)) || true
        fi
        # "stable" or "nightly" literals are OK — skip check
      fi
    fi
  fi

  # Check package-lock.json
  if [ -f "package-lock.json" ]; then
    local npm_lock_version
    npm_lock_version=$(grep -m1 '"lockfileVersion"' "package-lock.json" 2>/dev/null | grep -oE '[0-9]+')
    if [ -n "$npm_lock_version" ]; then
      local required_node_min=0
      if [ "$npm_lock_version" -eq 3 ]; then
        required_node_min=16
      elif [ "$npm_lock_version" -eq 2 ]; then
        required_node_min=14
      fi

      if [ "$required_node_min" -gt 0 ]; then
        # Scan CI workflows for Node version
        local ci_node_version=""
        local workflow_file
        while IFS= read -r workflow_file; do
          [ -f "$workflow_file" ] || continue
          local found_version
          found_version=$(grep -oE '(node-version|NODE_VERSION)[[:space:]]*:[[:space:]]*"?[0-9]+[^"[:space:]]*"?' "$workflow_file" 2>/dev/null \
            | grep -oE '[0-9]+' | head -1)
          if [ -n "$found_version" ]; then
            ci_node_version="$found_version"
            break
          fi
        done < <(find .github/workflows -name '*.yml' 2>/dev/null)

        if [ -n "$ci_node_version" ] && [ "$ci_node_version" -lt "$required_node_min" ] 2>/dev/null; then
          echo "package-lock.json lockfileVersion ${npm_lock_version} requires Node ${required_node_min}+, but CI uses Node ${ci_node_version}"
          echo "  Fix: Update CI toolchain version or regenerate lock file with compatible version"
          ((errors++)) || true
        fi
      fi
    fi
  fi

  [ "$errors" -eq 0 ] || return 1
  return 0
}

# PY-1: Python duplicate module name detection
# Only flags duplicate main.py/app.py when mypy is configured to scan them
# together (whole-project scan). Standard monorepo layouts with per-app scanning
# are NOT flagged — duplicate names are fine when tools run independently.
gk_check_python_duplicate_modules() {
  local warnings=0

  local search_dirs=""
  for d in apps services packages src; do
    [ -d "$d" ] && search_dirs="$search_dirs $d"
  done

  [ -z "$search_dirs" ] && return 0

  local exclude_args=(
    -not -path '*/__pycache__/*'
    -not -path '*/.venv/*'
    -not -path '*/node_modules/*'
    -not -path '*/vendor/*'
    -not -path '*/test/*'
    -not -path '*/tests/*'
  )

  for target_name in main.py app.py; do
    local found_files=()
    while IFS= read -r f; do
      found_files+=("$f")
    done < <(find $search_dirs -name "$target_name" "${exclude_args[@]}" 2>/dev/null | sort)

    if [ "${#found_files[@]}" -ge 2 ]; then
      # Check if mypy is configured for whole-project scanning (the dangerous case).
      # If mypy runs per-app (each app scanned independently), duplicates are safe.
      local mypy_scans_whole_project=false

      # Case 1: CI runs "mypy ." or "mypy" with no specific paths
      local workflow_files
      workflow_files=$(find .github/workflows -name '*.yml' 2>/dev/null || true)
      if [ -n "$workflow_files" ]; then
        if echo "$workflow_files" | xargs grep -lE 'mypy\s*$|mypy\s+\.' 2>/dev/null | grep -q .; then
          mypy_scans_whole_project=true
        fi
      fi

      # Case 2: pyproject.toml / mypy.ini has files = "." or no files restriction
      if [ "$mypy_scans_whole_project" = false ]; then
        if [ -f "mypy.ini" ] && ! grep -qE '^\s*files\s*=' "mypy.ini" 2>/dev/null; then
          mypy_scans_whole_project=true
        fi
        if [ -f "pyproject.toml" ] && grep -q '\[tool\.mypy\]' "pyproject.toml" 2>/dev/null; then
          if ! grep -A10 '\[tool\.mypy\]' "pyproject.toml" 2>/dev/null | grep -qE '^\s*files\s*=|^\s*packages\s*='; then
            mypy_scans_whole_project=true
          fi
        fi
      fi

      # Case 3: No mypy config at all but multiple main.py exist — still warn
      # because default mypy behavior scans everything
      if [ "$mypy_scans_whole_project" = false ]; then
        local has_mypy_config=false
        [ -f "mypy.ini" ] && has_mypy_config=true
        [ -f "setup.cfg" ] && grep -q '\[mypy\]' "setup.cfg" 2>/dev/null && has_mypy_config=true
        [ -f "pyproject.toml" ] && grep -q '\[tool\.mypy\]' "pyproject.toml" 2>/dev/null && has_mypy_config=true
        [ "$has_mypy_config" = false ] && mypy_scans_whole_project=true
      fi

      if [ "$mypy_scans_whole_project" = true ]; then
        echo "Duplicate '${target_name}' found in multiple packages with whole-project mypy scanning:"
        for f in "${found_files[@]}"; do
          echo "    $f"
        done
        echo "  Fix: Configure mypy to scan apps independently (e.g. 'mypy apps/svc-a apps/svc-b' separately)"
        ((warnings++)) || true
      fi
    fi
  done

  [ "$warnings" -eq 0 ] || return 1
  return 0
}

# TEST-1: Python test isolation indicators
# Detect potential test isolation issues in Python test suites.
# Severity: warning (heuristic detection)
# Known limitation: the fixture-without-yield awk detection does not account for
# Python indentation levels, so nested helper functions or class methods may
# produce incorrect counts. The secondary grep -A20 filter on state-modifying
# assignments mitigates most false positives.
gk_check_test_isolation() {
  local warnings=0

  # Find conftest.py files
  local conftest_files=()
  while IFS= read -r f; do
    conftest_files+=("$f")
  done < <(find . -name 'conftest.py' \
    -not -path '*/.venv/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/vendor/*' \
    2>/dev/null | sort)

  [ "${#conftest_files[@]}" -eq 0 ] && return 0

  # Check for async def test_ functions that lack BOTH @pytest.mark.asyncio AND
  # a global asyncio_mode=auto config. The original LUMI bug was missing markers,
  # not the reverse. Only flag if there is NO global auto mode anywhere.
  local has_global_asyncio_auto=false
  # Check pyproject.toml, pytest.ini, setup.cfg, conftest.py for asyncio_mode
  for cfg_file in pyproject.toml pytest.ini setup.cfg; do
    if [ -f "$cfg_file" ] && grep -qE 'asyncio_mode\s*=\s*["\x27]?auto' "$cfg_file" 2>/dev/null; then
      has_global_asyncio_auto=true
      break
    fi
  done
  if [ "$has_global_asyncio_auto" = false ]; then
    for conftest in "${conftest_files[@]}"; do
      if grep -qE 'asyncio_mode.*auto' "$conftest" 2>/dev/null; then
        has_global_asyncio_auto=true
        break
      fi
    done
  fi

  if [ "$has_global_asyncio_auto" = false ]; then
    # Look for async def test_ without @pytest.mark.asyncio
    for conftest in "${conftest_files[@]}"; do
      local conftest_dir
      conftest_dir=$(dirname "$conftest")
      while IFS= read -r test_file; do
        [ -f "$test_file" ] || continue
        # Find async def test_ functions that are NOT preceded by @pytest.mark.asyncio
        local unmarked
        unmarked=$(awk '
          /^[[:space:]]*@pytest\.mark\.asyncio/ { marked=1; next }
          /^[[:space:]]*async[[:space:]]+def[[:space:]]+test_/ {
            if (!marked) print FILENAME ":" NR ": " $0
            marked=0; next
          }
          /^[[:space:]]*@/ { next }
          { marked=0 }
        ' "$test_file" 2>/dev/null || true)
        if [ -n "$unmarked" ]; then
          echo "$test_file: async test functions without @pytest.mark.asyncio (no global asyncio_mode=auto found):"
          echo "$unmarked" | head -3 | sed 's/^/    /'
          echo "  Fix: Add @pytest.mark.asyncio or set asyncio_mode=auto in pyproject.toml"
          ((warnings++)) || true
        fi
      done < <(find "$conftest_dir" -name 'test_*.py' -o -name '*_test.py' 2>/dev/null)
    done
  fi

  # Check for fixtures without yield that modify state (no teardown)
  while IFS= read -r test_file; do
    [ -f "$test_file" ] || continue

    # Detect @pytest.fixture blocks that lack a yield (potential missing teardown)
    if grep -q '@pytest\.fixture' "$test_file" 2>/dev/null; then
      local fixture_count no_yield_count
      fixture_count=$(grep -c '@pytest\.fixture' "$test_file" 2>/dev/null || echo 0)
      no_yield_count=$(awk '
        /@pytest\.fixture/{in_fixture=1; has_yield=0; next}
        in_fixture && /^def /{in_def=1}
        in_def && /yield/{has_yield=1}
        in_def && /^def / && !/^def test_/{
          if (!has_yield) count++
          in_fixture=0; in_def=0; has_yield=0
        }
        END{print count+0}
      ' "$test_file" 2>/dev/null || echo 0)

      if [ "$no_yield_count" -gt 0 ] 2>/dev/null; then
        # Only warn if the fixture seems to modify state (has an assignment)
        if grep -A20 '@pytest\.fixture' "$test_file" 2>/dev/null | grep -qE '^\s+[a-z_]+\s*=\s*\[|\{'; then
          echo "$test_file: $no_yield_count fixture(s) without yield may leave shared state between tests"
          echo "  Fix: Add teardown to fixtures that modify shared state; use yield fixtures"
          ((warnings++)) || true
        fi
      fi
    fi
  done < <(find . -name 'test_*.py' -o -name '*_test.py' 2>/dev/null \
    | grep -v '/.venv/' | grep -v '/node_modules/' | grep -v '/vendor/')

  # Check for module-level stateful instances in test fixtures (no cleanup).
  # Only match known-stateful types: slowapi.Limiter, redis.Redis/StrictRedis,
  # fakeredis.FakeRedis. Generic "Cache(" is excluded — too many false positives
  # from cachetools, functools, etc. that are stateless or test-scoped.
  local limiter_patterns='Limiter\(|redis\.\(Strict\)?Redis\(|FakeRedis\('
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if grep -qE "$limiter_patterns" "$f" 2>/dev/null; then
      # Check if at module level (not inside a function/fixture with yield)
      local module_level_hits
      module_level_hits=$(grep -nE "^[a-z_].*= .*(Limiter|redis\.(Strict)?Redis|FakeRedis)\(" "$f" 2>/dev/null || true)
      if [ -n "$module_level_hits" ]; then
        echo "$f: module-level Limiter/Redis instance may persist between tests:"
        echo "$module_level_hits" | head -3 | sed 's/^/    /'
        echo "  Fix: Move stateful instances into fixtures with yield for proper teardown"
        ((warnings++)) || true
      fi
    fi
  done < <(find . \( -name 'conftest.py' -o -name 'test_*.py' -o -name '*_test.py' \) \
    -not -path '*/.venv/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/vendor/*' \
    2>/dev/null)

  [ "$warnings" -eq 0 ] || return 1
  return 0
}
