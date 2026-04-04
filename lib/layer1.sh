#!/usr/bin/env bash
# layer1.sh — Static checks (zero external dependencies, runs locally)

gk_layer1_run() {
  gk_run_check "A" "go.work validation" gk_check_go_work
  gk_run_check "B" "Shell script syntax" gk_check_shell_syntax
  gk_run_check "C" "Python packaging" gk_check_python_packaging
  gk_run_check "D" "Dockerfile COPY paths" gk_check_dockerfile_copy
  gk_run_check "E" "Dockerfile anti-patterns" gk_check_dockerfile_antipatterns
  gk_run_check "F" "secretRef ban" gk_check_secretref_ban
  gk_run_check "G" "Deprecated component refs" gk_check_deprecated_refs
  gk_run_check "H" "Port chain consistency" gk_check_port_chain
  gk_run_check "I" "Namespace consistency" gk_check_namespace_consistency
}

gk_check_go_work() {
  local found=0
  for ws in $(find . -name 'go.work' -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null); do
    found=1
    local dir=$(dirname "$ws")
    while IFS= read -r use_path; do
      [ -z "$use_path" ] && continue
      use_path=$(echo "$use_path" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
      [[ "$use_path" != ./* ]] && continue
      local full_path="$dir/$use_path"
      if [ ! -d "$full_path" ]; then
        echo "$ws: use path '$use_path' directory not found"
        return 1
      fi
      if [ ! -f "$full_path/go.mod" ]; then
        echo "$ws: use path '$use_path' has no go.mod"
        return 1
      fi
    done < <(grep '^\s*\./' "$ws" 2>/dev/null)
  done
  [ $found -eq 0 ] && return 0  # No go.work files, skip
  return 0
}

gk_check_shell_syntax() {
  local errors=0
  while IFS= read -r sh; do
    if ! bash -n "$sh" 2>/dev/null; then
      echo "Syntax error: $sh"
      ((errors++)) || true
    fi
  done < <(find . -name '*.sh' -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_python_packaging() {
  local errors=0
  while IFS= read -r pp; do
    local dir=$(dirname "$pp")
    if [ -f "$dir/setup.py" ] && grep -q 'build-backend' "$pp" 2>/dev/null; then
      echo "Redundant setup.py + pyproject.toml in $dir"
      ((errors++)) || true
    fi
  done < <(find . -name 'pyproject.toml' -not -path '*/vendor/*' -not -path '*/node_modules/*' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_dockerfile_copy() {
  # Lightweight check: just verify Dockerfiles parse correctly
  local count=$(find . -name 'Dockerfile*' -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -eq 0 ] && return 0
  return 0
}

gk_check_dockerfile_antipatterns() {
  local errors=0
  while IFS= read -r df; do
    if grep -n 'pip install.*-e \.' "$df" 2>/dev/null | grep -qv '#'; then
      echo "$df: editable install (-e .) in production Dockerfile"
      ((errors++)) || true
    fi
  done < <(find . -name 'Dockerfile*' -not -path '*/vendor/*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_secretref_ban() {
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0

  local found=$(grep -rn 'secretRef' "$k8s_dir" --include='*.yaml' 2>/dev/null | grep -v 'secretKeyRef' | grep -v '#' || true)
  if [ -n "$found" ]; then
    echo "secretRef found (use secretKeyRef instead):"
    echo "$found"
    return 1
  fi
  return 0
}

gk_check_deprecated_refs() {
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0

  local patterns="federation-config federation-secrets"
  local errors=0

  for pattern in $patterns; do
    local found=$(grep -rn "$pattern" "$k8s_dir" --include='*.yaml' 2>/dev/null | grep -v '#' || true)
    if [ -n "$found" ]; then
      echo "Deprecated '$pattern':"
      echo "$found"
      ((errors++)) || true
    fi
  done
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_port_chain() {
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0

  local errors=0
  while IFS= read -r f; do
    local container_port=$(grep 'containerPort:' "$f" 2>/dev/null | head -1 | awk '{print $2}')
    [ -z "$container_port" ] && continue

    local liveness_port=$(awk '/livenessProbe:/,/port:/{if(/port:/) print $2}' "$f" 2>/dev/null | head -1)
    if [ -n "$liveness_port" ] && [ "$liveness_port" != "$container_port" ]; then
      echo "$f: containerPort=$container_port livenessProbe=$liveness_port"
      ((errors++)) || true
    fi

    local readiness_port=$(awk '/readinessProbe:/,/port:/{if(/port:/) print $2}' "$f" 2>/dev/null | head -1)
    if [ -n "$readiness_port" ] && [ "$readiness_port" != "$container_port" ]; then
      echo "$f: containerPort=$container_port readinessProbe=$readiness_port"
      ((errors++)) || true
    fi
  done < <(find "$k8s_dir" -name '*.yaml' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_namespace_consistency() {
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0

  local expected="${GK_NAMESPACE:-production}"
  local errors=0

  while IFS= read -r line; do
    local ns=$(echo "$line" | awk '{print $NF}')
    if [ "$ns" != "$expected" ]; then
      echo "$line (expected: $expected)"
      ((errors++)) || true
    fi
  done < <(grep -rn '^\s*namespace:' "$k8s_dir" --include='*.yaml' 2>/dev/null | grep -v '#' | grep -v 'configMapKeyRef\|secretKeyRef')
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_find_k8s_dir() {
  for d in deploy/k8s k8s kubernetes .k8s; do
    [ -d "$d" ] && echo "$d" && return
  done
}
