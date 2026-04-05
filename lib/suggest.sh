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
    ((suggestions+=3)) || true
  fi

  # Detect Node.js projects
  if [ -f "package.json" ]; then
    echo "  Detected: Node.js project"
    _gk_suggest_custom "no_console_log" "console\\.log" "src" "warning" "Remove console.log before production"
    _gk_suggest_custom "no_debugger" "debugger;" "src" "critical" "Remove debugger statements"
    ((suggestions+=2)) || true
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
    ((suggestions++)) || true
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
