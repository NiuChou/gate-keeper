#!/usr/bin/env bash
# layer2.sh — Cluster validation (requires kubectl access)

gk_layer2_run() {
  if ! command -v kubectl >/dev/null 2>&1; then
    gk_record "J" "deployment name match" "SKIP" "kubectl not available"
    gk_record "K" "image name match" "SKIP" "kubectl not available"
    gk_record "L" "secret key match" "SKIP" "kubectl not available"
    gk_print_check "J" "deployment name match" "SKIP"
    gk_print_check "K" "image name match" "SKIP"
    gk_print_check "L" "secret key match" "SKIP"
    return 0
  fi

  if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
    gk_record "J" "deployment name match" "SKIP" "cluster unreachable"
    gk_record "K" "image name match" "SKIP" "cluster unreachable"
    gk_record "L" "secret key match" "SKIP" "cluster unreachable"
    gk_print_check "J" "deployment name match" "SKIP"
    gk_print_check "K" "image name match" "SKIP"
    gk_print_check "L" "secret key match" "SKIP"
    return 0
  fi

  gk_run_check "J" "deployment name match" gk_check_deployment_names
  gk_run_check "K" "image name match" gk_check_image_names
  gk_run_check "L" "secret key match" gk_check_secret_keys
}

gk_check_deployment_names() {
  local ns="${GK_NAMESPACE:-production}"
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0

  local live=$(kubectl -n "$ns" get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort)
  local errors=0

  while IFS= read -r f; do
    local yaml_name=$(awk '/^kind: Deployment/{found=1} found && /^  name:/{print $2; found=0}' "$f" 2>/dev/null)
    [ -z "$yaml_name" ] && continue
    if echo "$live" | grep -qx "$yaml_name"; then
      : # Match
    else
      local base="${yaml_name%-svc}"
      if echo "$live" | grep -qx "$base"; then
        echo "$f: YAML '$yaml_name' but cluster has '$base'"
        ((errors++)) || true
      fi
    fi
  done < <(find "$k8s_dir" -name '*.yaml' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_image_names() {
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0
  local errors=0

  while IFS= read -r f; do
    local img=$(grep 'image:' "$f" 2>/dev/null | head -1 | awk '{print $2}' | sed 's|:.*||')
    [ -z "$img" ] && continue
    if ! echo "$img" | grep -q '/'; then
      echo "$f: image '$img' missing registry prefix"
      ((errors++)) || true
    fi
  done < <(find "$k8s_dir" -name '*.yaml' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

gk_check_secret_keys() {
  local ns="${GK_NAMESPACE:-production}"
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0

  # Get actual keys from the main secret
  local actual_keys=$(kubectl -n "$ns" get secret perseworks-secret -o json 2>/dev/null \
    | python3 -c "import sys,json; print('\n'.join(json.loads(sys.stdin.read())['data'].keys()))" 2>/dev/null || true)
  [ -z "$actual_keys" ] && return 0

  local errors=0
  # Find all secretKeyRef key references
  local ref_keys=$(grep -rh 'key:' "$k8s_dir" --include='*.yaml' 2>/dev/null \
    | grep -v 'configMapKeyRef\|#\|namespace' | awk '{print $NF}' | sort -u)

  for ref_key in $ref_keys; do
    if ! echo "$actual_keys" | grep -qx "$ref_key"; then
      # Check if the reference is marked optional
      if grep -r "key: $ref_key" "$k8s_dir" --include='*.yaml' -A1 2>/dev/null | grep -q 'optional: true'; then
        : # Optional, OK
      else
        echo "Key '$ref_key' referenced but missing from secret"
        ((errors++)) || true
      fi
    fi
  done
  [ $errors -eq 0 ] || return 1
  return 0
}
