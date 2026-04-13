#!/usr/bin/env bash
# suggest.sh — Smart check recommendation engine (Phase 5)
# Analyzes project structure and recommends checks to enable

gk_suggest() {
  echo ""
  echo "============================================"
  echo "  Gate Keeper · Smart Suggestions"
  echo "============================================"
  echo ""

  local suggestions=0

  # Detect Go projects
  if [ -f "go.mod" ] || [ -f "go.work" ]; then
    echo "  Detected: Go project"
    _gk_suggest_check "go_work" "Validate go.work use directives" "critical"
    ((suggestions++)) || true
  fi

  # Detect Python projects
  if [ -f "pyproject.toml" ] || [ -f "requirements.txt" ] || [ -f "setup.py" ]; then
    echo "  Detected: Python project"
    _gk_suggest_check "python_packaging" "Check pyproject.toml / setup.py consistency" "warning"
    _gk_suggest_custom "no_debug_true" "DEBUG.*=.*True" "." "critical" "Prevent DEBUG=True in production"
    _gk_suggest_custom "no_hardcoded_secrets" "password.*=.*['\"]" "." "critical" "Detect hardcoded passwords"
    # FastAPI-specific checks
    if grep -rql 'fastapi\|FastAPI' requirements*.txt pyproject.toml setup.py setup.cfg 2>/dev/null; then
      echo "  Detected: FastAPI dependency"
      _gk_suggest_check "fastapi_exception_handler" "Require global Exception handler" "critical"
      _gk_suggest_check "fastapi_endpoint_try_except" "Require try/except in mutation endpoints" "high"
      _gk_suggest_check "ratelimit_retry_after" "Require Retry-After on 429 responses" "critical"
      ((suggestions+=3)) || true
    fi
    ((suggestions+=3)) || true
  fi

  # Detect Node.js projects
  if [ -f "package.json" ]; then
    echo "  Detected: Node.js project"
    _gk_suggest_custom "no_console_log" "console\\.log" "src" "warning" "Remove console.log before production"
    _gk_suggest_custom "no_debugger" "debugger;" "src" "critical" "Remove debugger statements"
    _gk_suggest_check "api_path_literal_ban" "Ban hardcoded API path literals" "warning"
    # Detect Next.js projects
    if [ -f "next.config.js" ] || [ -f "next.config.ts" ] || [ -f "next.config.mjs" ] || [ -f "next.config.cjs" ]; then
      echo "  Detected: Next.js project"
      _gk_suggest_check "nextjs_rewrite_completeness" "Verify API paths have matching rewrites" "critical"
      ((suggestions++)) || true
    fi
    ((suggestions+=3)) || true
  fi

  # Detect Dockerfiles
  local dockerfile_count=$(find . -name 'Dockerfile*' -not -path '*/vendor/*' -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dockerfile_count" -gt 0 ]; then
    echo "  Detected: $dockerfile_count Dockerfile(s)"
    _gk_suggest_check "dockerfile_copy" "Validate COPY source paths" "critical"
    _gk_suggest_check "dockerfile_antipatterns" "Detect editable installs in prod" "warning"
    _gk_suggest_custom "no_latest_tag" "FROM.*:latest" "." "warning" "Pin Docker image versions instead of :latest"
    ((suggestions+=3)) || true
  fi

  # Detect K8s manifests
  local k8s_dir=""
  for d in deploy/k8s k8s kubernetes .k8s; do
    [ -d "$d" ] && k8s_dir="$d" && break
  done
  if [ -n "$k8s_dir" ]; then
    echo "  Detected: Kubernetes manifests in $k8s_dir"
    _gk_suggest_check "secretref_ban" "Ban plain secretRef usage" "critical"
    _gk_suggest_check "namespace_consistency" "Verify namespace consistency" "critical"
    _gk_suggest_check "port_chain" "Check port chain consistency" "critical"
    _gk_suggest_custom "no_privileged" "privileged: true" "$k8s_dir" "critical" "Remove privileged containers"
    _gk_suggest_custom "resource_limits" "resources:" "$k8s_dir" "warning" "Ensure resource limits are set"
    ((suggestions+=5)) || true
  fi

  # Detect shell scripts
  local sh_count=$(find . -name '*.sh' -not -path '*/vendor/*' -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$sh_count" -gt 0 ]; then
    echo "  Detected: $sh_count shell script(s)"
    _gk_suggest_check "shell_syntax" "Validate shell script syntax" "critical"
    ((suggestions++)) || true
  fi

  # Detect CI configuration
  if ls .github/workflows/*.yml 1>/dev/null 2>&1 || [ -f ".gitlab-ci.yml" ] || [ -f "Jenkinsfile" ]; then
    echo "  Detected: CI configuration"
    _gk_suggest_custom "no_allow_failure" "allow_failure: true" "." "warning" "Review allow_failure usage"
    ((suggestions++)) || true
  fi

  # Detect .env files (should not be committed)
  if find . -name '.env' -not -path '*/.git/*' 2>/dev/null | grep -q '.'; then
    echo "  Detected: .env file(s)"
    _gk_suggest_custom "no_env_committed" "^[A-Z_]+=.+" ".env" "critical" "Remove .env from version control"
    _gk_suggest_check "env_placeholders" "Detect placeholder values in .env files" "critical"
    ((suggestions+=2)) || true
  fi

  # Detect Docker Compose files
  local compose_count=$(find . -maxdepth 2 \( -name 'docker-compose*.yml' -o -name 'docker-compose*.yaml' \
    -o -name 'compose*.yml' -o -name 'compose*.yaml' \) \
    -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$compose_count" -gt 0 ]; then
    echo "  Detected: $compose_count Docker Compose file(s)"
    _gk_suggest_check "dc_env_multiline" "Detect PEM/cert multi-line values in .env" "critical"
    _gk_suggest_check "dc_env_completeness" "Verify compose \${VAR} refs exist in .env" "critical"
    _gk_suggest_check "dc_healthcheck_antipatterns" "Detect healthcheck anti-patterns" "high"
    _gk_suggest_check "dc_tmpfs_shadow" "Detect tmpfs vs Dockerfile mkdir conflicts" "high"
    _gk_suggest_check "dc_cap_drop_all" "Detect cap_drop ALL on middleware images" "warning"
    _gk_suggest_check "dc_depends_on_deadlock" "Detect circular depends_on chains" "warning"
    _gk_suggest_check "dc_resource_limits" "Check worker count vs memory limit sanity" "warning"
    _gk_suggest_check "secret_file_refs" "Verify secret file references" "critical"
    _gk_suggest_custom "dsn_protocol_consistency" "postgresql\\+asyncpg://" ". .env" "warning" "Detect asyncpg DSN in shared env"
    _gk_suggest_custom "pem_file_permissions" "" "." "warning" "Verify PEM/key file permissions"
    ((suggestions+=10)) || true
  fi

  # Detect multi-app Python monorepo structure
  if ([ -f "pyproject.toml" ] || [ -f "requirements.txt" ] || [ -f "setup.py" ]) && \
     ([ -d "apps" ] || [ -d "services" ] || [ -d "packages" ]); then
    echo "  Detected: Multi-app Python structure"
    _gk_suggest_check "python_duplicate_modules" "Detect duplicate module names" "warning"
    _gk_suggest_check "test_isolation" "Check test fixture isolation" "warning"
    ((suggestions+=2)) || true
  fi

  # Detect dependency lock files
  local lock_found=0
  if [ -f "Cargo.lock" ]; then
    echo "  Detected: Cargo.lock"
    lock_found=1
  fi
  if [ -f "package-lock.json" ] || [ -f "yarn.lock" ] || [ -f "pnpm-lock.yaml" ]; then
    echo "  Detected: Node.js lock file"
    lock_found=1
  fi
  if [ "$lock_found" -eq 1 ]; then
    _gk_suggest_check "dep_lock_compat" "Check lock file vs toolchain compatibility" "warning"
    ((suggestions++)) || true
  fi

  # Detect pytest / conftest
  if find . -name 'conftest.py' -not -path '*/.git/*' 2>/dev/null | grep -q '.' || \
     find . -name 'pytest.ini' -o -name 'pyproject.toml' -not -path '*/.git/*' 2>/dev/null | xargs grep -l 'pytest' 2>/dev/null | grep -q '.'; then
    echo "  Detected: pytest configuration"
    _gk_suggest_check "test_isolation" "Check test fixture isolation" "warning"
    ((suggestions++)) || true
  fi

  # Suggest pre-commit hooks if not present
  if [ ! -f ".pre-commit-config.yaml" ] && [ ! -f ".githooks/pre-commit" ]; then
    echo "  Detected: No pre-commit hooks configured"
    printf "    ${BLUE}+${RESET} %-35s gate-keeper init --hooks\n" "Generate raw git hooks (zero deps)"
    printf "    ${BLUE}+${RESET} %-35s gate-keeper init --pre-commit\n" "Generate pre-commit framework config"
    ((suggestions+=2)) || true
  elif [ ! -f ".githooks/pre-commit" ] && [ -f ".pre-commit-config.yaml" ]; then
    printf "    ${GREEN}✓${RESET} %-35s (pre-commit framework)\n" "pre-commit hooks"
  elif [ -f ".githooks/pre-commit" ]; then
    printf "    ${GREEN}✓${RESET} %-35s (.githooks/pre-commit)\n" "raw git hooks"
    # Check if core.hooksPath is set
    local hooks_path
    hooks_path=$(git config core.hooksPath 2>/dev/null || true)
    if [ "$hooks_path" != ".githooks" ]; then
      printf "    ${YELLOW}○${RESET} %-35s gate-keeper init --setup-hooks\n" "hooks not activated (core.hooksPath)"
      ((suggestions++)) || true
    fi
  fi

  echo ""
  if [ $suggestions -eq 0 ]; then
    echo "  No specific suggestions for this project structure."
  else
    echo "  $suggestions suggestion(s) generated."
    echo "  Use 'gate-keeper add --id=<ID> --pattern=<PATTERN>' to add custom checks."
  fi
  echo ""
}

_gk_suggest_check() {
  local key="$1" desc="$2" sev="$3"
  local enabled=$(gk_config_enabled "$key" 2>/dev/null || echo "unknown")
  if [ "$enabled" = "true" ]; then
    printf "    ${GREEN}✓${RESET} %-35s (enabled, %s)\n" "$key" "$sev"
  elif [ "$enabled" = "false" ]; then
    printf "    ${YELLOW}○${RESET} %-35s (disabled, recommend: %s)\n" "$key" "$sev"
  else
    printf "    ${BLUE}+${RESET} %-35s (suggest: %s)\n" "$key" "$sev"
  fi
}

_gk_suggest_custom() {
  local id="$1" pattern="$2" paths="$3" sev="$4" desc="$5"
  # Check if already in config
  if [ -f "$GK_CONFIG" ] && grep -q "id: ${id}$" "$GK_CONFIG" 2>/dev/null; then
    printf "    ${GREEN}✓${RESET} %-35s (already configured)\n" "$id"
  else
    printf "    ${BLUE}+${RESET} %-35s gate-keeper add --id=%s --pattern='%s' --paths='%s' --severity=%s\n" "$desc" "$id" "$pattern" "$paths" "$sev"
  fi
}
