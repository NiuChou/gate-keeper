#!/usr/bin/env bash
# layer2.sh — Cluster validation (requires kubectl access)

gk_layer2_run() {
  if ! command -v kubectl >/dev/null 2>&1; then
    gk_skip_check "J" "deployment name match" "kubectl not available"
    gk_skip_check "K" "image name match" "kubectl not available"
    gk_skip_check "L" "secret key match" "kubectl not available"
    return 0
  fi
  if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
    gk_skip_check "J" "deployment name match" "cluster unreachable"
    gk_skip_check "K" "image name match" "cluster unreachable"
    gk_skip_check "L" "secret key match" "cluster unreachable"
    return 0
  fi

  gk_maybe_run "J" "deployment name match" "deployment_name_match" gk_check_deployment_names
  gk_maybe_run "K" "image name match" "image_name_match" gk_check_image_names
  gk_maybe_run "L" "secret key match" "secret_key_match" gk_check_secret_keys
}

gk_check_deployment_names() {
  local ns="${GK_NAMESPACE:-production}"
  local k8s_dir=$(gk_find_k8s_dir)
  [ -z "$k8s_dir" ] && return 0
  local live=$(kubectl -n "$ns" get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort)
  local errors=0
  while IFS= read -r f; do
    local yaml_name=$(awk '/^kind:\s*Deployment/{d=1} d && /^\s+name:/{print $2; exit}' "$f" 2>/dev/null)
    [ -z "$yaml_name" ] && continue
    if echo "$live" | grep -qx "$yaml_name"; then
      :
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
    if echo "$img" | grep -q '\.' && ! echo "$img" | grep -q '/'; then
      echo "$f: image '$img' has domain but no path"
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
  local secret_name="${GK_SECRET_NAME:-perseworks-secret}"
  local actual_keys=$(kubectl -n "$ns" get secret "$secret_name" \
    -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null || true)
  [ -z "$actual_keys" ] && return 0
  local errors=0
  local ref_keys=$(grep -rh 'key:' "$k8s_dir" --include='*.yaml' 2>/dev/null \
    | grep -v 'configMapKeyRef\|#\|namespace' | awk '{print $NF}' | sort -u)
  for ref_key in $ref_keys; do
    if ! echo "$actual_keys" | grep -qx "$ref_key"; then
      if grep -r "key: $ref_key" "$k8s_dir" --include='*.yaml' -A1 2>/dev/null | grep -q 'optional: true'; then
        :
      else
        echo "Key '$ref_key' missing from secret '$secret_name'"
        ((errors++)) || true
      fi
    fi
  done
  [ $errors -eq 0 ] || return 1
  return 0
}
