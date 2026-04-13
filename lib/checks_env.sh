#!/usr/bin/env bash
# checks_env.sh — Environment & secret file integrity checks (LUMI-inspired)

# ENV-1: Scan .env* files for placeholder values indicating incomplete configuration
gk_check_env_placeholders() {
  # Find all .env* files, excluding templates/examples and vendor dirs
  local env_files
  env_files=$(find . \
    \( -name '.env' -o -name '.env.*' \) \
    -not -name '.env.example' \
    -not -name '.env.template' \
    -not -name '.env.sample' \
    -not -path '*/.git/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/vendor/*' \
    2>/dev/null)

  local errors=0

  # Check each .env file for placeholder patterns
  while IFS= read -r env_file; do
    [ -z "$env_file" ] && continue
    [ -f "$env_file" ] || continue

    # Pattern: known placeholder strings in values (after =), case-insensitive
    # Excludes comments (lines starting with #) and restricts TODO/FIXME to
    # standalone values to avoid false positives like JIRA_PROJECT=TODO-TRACKER
    local placeholder_hits
    placeholder_hits=$(grep -nE \
      '^[A-Za-z_][A-Za-z0-9_]*=.*(CHANGEME|YOUR_[A-Z_]+_HERE|REPLACE_ME|<your-|INSERT_)|^[A-Za-z_][A-Za-z0-9_]*=(TODO|FIXME|placeholder|xxx|yyy)$' \
      "$env_file" 2>/dev/null | grep -v '^\s*#' || true)

    if [ -n "$placeholder_hits" ]; then
      while IFS= read -r hit; do
        echo "$env_file: placeholder value detected: $hit"
      done <<< "$placeholder_hits"
      ((errors++)) || true
    fi

    # Pattern: empty value after = (KEY= with nothing after)
    # Only flag in production .env files — empty values in .env.development or
    # plain .env are often intentional (falsy/disabled/fallback semantics).
    local base_env
    base_env=$(basename "$env_file")
    if [[ "$base_env" == .env.prod* || "$base_env" == .env.production* || "$base_env" == .env.staging* ]]; then
      local empty_hits
      empty_hits=$(grep -nE '^[A-Za-z_][A-Za-z0-9_]*=$' "$env_file" 2>/dev/null || true)
      if [ -n "$empty_hits" ]; then
        while IFS= read -r hit; do
          echo "$env_file: empty value in production config: $hit"
        done <<< "$empty_hits"
        ((errors++)) || true
      fi
    fi
  done <<< "$env_files"

  # Check docker-compose env_file references exist on disk
  local compose_files
  compose_files=$(gk_find_compose_files)
  if [ -n "$compose_files" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      # Extract env_file: paths from compose file
      local ef_refs
      ef_refs=$(grep -oE 'env_file:[[:space:]]*[^#[:space:]]+' "$f" 2>/dev/null | sed 's/env_file:[[:space:]]*//' || true)
      # Also handle list-style env_file entries: "  - path/to/file"
      local ef_list
      ef_list=$(awk '/env_file:/{in_ef=1; next} in_ef && /^[[:space:]]*-[[:space:]]+[^#]/{print $2} in_ef && !/^[[:space:]]*[-]/{in_ef=0}' "$f" 2>/dev/null || true)
      local all_refs
      all_refs=$(printf '%s\n%s\n' "$ef_refs" "$ef_list" | grep -vE '^[[:space:]]*$' || true)
      [ -z "$all_refs" ] && continue
      local compose_dir
      compose_dir=$(dirname "$f")
      while IFS= read -r ref; do
        [ -z "$ref" ] && continue
        # Resolve path relative to compose file location
        local ref_path
        if [[ "$ref" == /* ]]; then
          ref_path="$ref"
        else
          ref_path="${compose_dir}/${ref}"
        fi
        if [ ! -f "$ref_path" ]; then
          echo "$f: env_file reference '$ref' does not exist on disk"
          ((errors++)) || true
        fi
      done <<< "$all_refs"
    done <<< "$compose_files"
  fi

  if [ $errors -gt 0 ]; then
    echo "  Fix: Replace placeholder values with real configuration before deploying"
    return 1
  fi
  return 0
}

# SEC-1: Verify secret/certificate files referenced in compose or k8s manifests
# have a documented generation path (.gitignore entry or generation script)
gk_check_secret_file_refs() {
  local errors=0
  local secret_ext_pattern='\.(pem|key|crt|cert|p12|jks|keystore)($|:| )'

  # Collect referenced secret file paths from docker-compose files
  local compose_files
  compose_files=$(gk_find_compose_files)
  local referenced_secrets=()

  if [ -n "$compose_files" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      # Extract volume mount paths containing secret file extensions
      local vol_paths
      vol_paths=$(grep -oE '[^[:space:]"'"'"']+\.(pem|key|crt|cert|p12|jks|keystore)' "$f" 2>/dev/null | grep -v '#' || true)
      while IFS= read -r vp; do
        [ -z "$vp" ] && continue
        # Strip trailing colons/quotes and leading ./
        vp="${vp%%:*}"
        vp="${vp#./}"
        referenced_secrets+=("$vp")
      done <<< "$vol_paths"
    done <<< "$compose_files"
  fi

  # Collect referenced secret file paths from k8s YAML files
  local k8s_dir
  k8s_dir=$(gk_find_k8s_dir)
  if [ -n "$k8s_dir" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      local k8s_paths
      k8s_paths=$(grep -oE '[^[:space:]"'"'"']+\.(pem|key|crt|cert|p12|jks|keystore)' "$f" 2>/dev/null | grep -v '#' || true)
      while IFS= read -r kp; do
        [ -z "$kp" ] && continue
        kp="${kp%%:*}"
        kp="${kp#./}"
        referenced_secrets+=("$kp")
      done <<< "$k8s_paths"
    done < <(find "$k8s_dir" -name '*.yaml' -o -name '*.yml' 2>/dev/null)
  fi

  # Deduplicate
  local unique_secrets=()
  if [ ${#referenced_secrets[@]} -gt 0 ]; then
    while IFS= read -r s; do
      [ -n "$s" ] && unique_secrets+=("$s")
    done < <(printf '%s\n' "${referenced_secrets[@]}" | sort -u)
  fi

  [ ${#unique_secrets[@]} -eq 0 ] && return 0

  # Collect all generation script candidates
  local gen_scripts=()
  for script_candidate in scripts/setup.sh scripts/gen.sh scripts/init.sh; do
    [ -f "$script_candidate" ] && gen_scripts+=("$script_candidate")
  done
  while IFS= read -r gs; do
    [ -n "$gs" ] && gen_scripts+=("$gs")
  done < <(find . -maxdepth 3 \( -name 'setup*.sh' -o -name 'gen*.sh' -o -name 'init*.sh' \) \
    -path '*/scripts/*' 2>/dev/null)

  # Check Makefile for cert/key generation targets
  local makefile_path=""
  for mk in Makefile makefile GNUmakefile; do
    if [ -f "$mk" ] && grep -qiE '^(generate|cert|certs|keys?|tls):' "$mk" 2>/dev/null; then
      makefile_path="$mk"
      break
    fi
  done

  for secret_ref in "${unique_secrets[@]}"; do
    # File present in working tree — check if it is git-tracked (accidental commit)
    if [ -f "$secret_ref" ]; then
      if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if git ls-files --error-unmatch "$secret_ref" >/dev/null 2>&1; then
          echo "Secret file '$secret_ref' exists and is tracked by git — should be in .gitignore"
          ((errors++)) || true
        fi
      fi
      continue
    fi

    # Check if listed in .gitignore
    local in_gitignore=false
    if [ -f ".gitignore" ]; then
      local base_name
      base_name=$(basename "$secret_ref")
      if grep -qE "(^|/)${base_name}$|^${secret_ref}$|\*\.${secret_ref##*.}$" ".gitignore" 2>/dev/null; then
        in_gitignore=true
      fi
    fi

    # Check if any generation script actually references this file or its extension
    local has_relevant_gen=false
    local secret_ext="${secret_ref##*.}"
    local secret_base
    secret_base=$(basename "$secret_ref")
    for gs in "${gen_scripts[@]}"; do
      # Script mentions the filename, the extension, or common generation commands
      if grep -qiE "(${secret_base}|\.${secret_ext}|openssl|keytool|ssh-keygen|certbot)" "$gs" 2>/dev/null; then
        has_relevant_gen=true
        break
      fi
    done
    # Also check Makefile content
    if [ "$has_relevant_gen" = false ] && [ -n "$makefile_path" ]; then
      if grep -qiE "(${secret_base}|\.${secret_ext}|openssl|keytool|ssh-keygen|certbot)" "$makefile_path" 2>/dev/null; then
        has_relevant_gen=true
      fi
    fi

    # Not in git AND not in .gitignore AND no relevant generation script → FAIL
    if [ "$in_gitignore" = false ] && [ "$has_relevant_gen" = false ]; then
      echo "Secret file '$secret_ref' is referenced but: not in .gitignore and no generation script found for it"
      ((errors++)) || true
    fi
  done

  if [ $errors -gt 0 ]; then
    echo "  Fix: Add a setup script (scripts/setup.sh) or document how to generate these files, and add them to .gitignore"
    return 1
  fi
  return 0
}
