#!/usr/bin/env bash
# supervision.sh — Supervision layer: bypass detection and tamper verification

# Check if deployments have gate-keeper-run-id annotation
gk_check_bypass() {
  local ns="${GK_NAMESPACE:-production}"
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl not available"
    return 0
  fi
  local errors=0
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    local ann
    ann=$(kubectl -n "$ns" get deployment "$dep" \
      -o jsonpath='{.metadata.annotations.gate-keeper-run-id}' 2>/dev/null || true)
    if [ -z "$ann" ]; then
      echo "Deployment '$dep' missing gate-keeper-run-id annotation (possible bypass)"
      ((errors++)) || true
    fi
  done < <(kubectl -n "$ns" get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  [ $errors -eq 0 ] || return 1
  return 0
}

# Verify gate-keeper integrity via SHA256 hash
gk_check_integrity() {
  local hash_file="${GK_HASH_FILE:-.gate-keeper.sha256}"
  if [ ! -f "$hash_file" ]; then
    echo "No hash file found at $hash_file (run 'gate-keeper stamp' to generate)"
    return 0  # Not a failure if no hash file exists yet
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c "$hash_file" --quiet 2>/dev/null || {
      echo "INTEGRITY VIOLATION: gate-keeper files have been modified!"
      echo "Expected hashes in $hash_file don't match current files."
      return 1
    }
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c "$hash_file" --quiet 2>/dev/null || {
      echo "INTEGRITY VIOLATION: gate-keeper files have been modified!"
      return 1
    }
  else
    echo "No sha256sum or shasum available"
    return 0
  fi
  return 0
}

# Generate hash file for current gate-keeper installation
# Usage: gk_stamp [--verify]
gk_stamp() {
  local verify=false
  for arg in "$@"; do
    case "$arg" in --verify) verify=true ;; esac
  done

  if [ "$verify" = true ]; then
    gk_check_integrity
    return $?
  fi

  local hash_file="${GK_HASH_FILE:-.gate-keeper.sha256}"

  # Hash all critical files
  local files=()
  for f in "${SCRIPT_DIR}/gate-keeper" "${LIB_DIR}"/*.sh; do
    [ -f "$f" ] && files+=("$f")
  done

  if [ ${#files[@]} -eq 0 ]; then
    echo "No gate-keeper files found to hash"
    return 1
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${files[@]}" > "$hash_file"
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${files[@]}" > "$hash_file"
  else
    echo "No sha256sum or shasum available"
    return 1
  fi
  echo "Hash file generated: $hash_file"
  echo "Add this file to your CI workflow for tamper detection."
}

# Annotate deployments with gate-keeper run ID after successful run
gk_annotate_deployments() {
  local ns="${GK_NAMESPACE:-production}"
  local run_id="$1"
  if ! command -v kubectl >/dev/null 2>&1; then
    return 0
  fi
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    kubectl -n "$ns" annotate deployment "$dep" \
      "gate-keeper-run-id=$run_id" --overwrite 2>/dev/null || true
  done < <(kubectl -n "$ns" get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
}
