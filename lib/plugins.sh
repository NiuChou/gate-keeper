#!/usr/bin/env bash
# plugins.sh — Plugin system for installing and running external rule packs

GK_PLUGIN_DIR="${GK_PLUGIN_DIR:-.gate-plugins}"

# Parse a top-level field from a metadata.yaml file
_gk_yaml_field() {
  local file="$1" field="$2"
  grep "^${field}:" "$file" 2>/dev/null | sed "s/^${field}:[[:space:]]*//" | tr -d '"' | tr -d "'"
}

# Parse a field that may be indented (for check metadata)
_gk_yaml_any_field() {
  local file="$1" field="$2"
  grep "[[:space:]]*${field}:" "$file" 2>/dev/null | head -1 | sed "s/.*${field}:[[:space:]]*//" | tr -d '"' | tr -d "'"
}

# Returns 0 if check_tags intersects GK_TAGS (or GK_TAGS is unset), 1 otherwise
_gk_tags_match() {
  local check_tags="$1"
  [ -z "${GK_TAGS:-}" ] && return 0
  local IFS=','
  for filter_tag in $GK_TAGS; do
    filter_tag=$(echo "$filter_tag" | tr -d '[:space:]')
    for check_tag in $check_tags; do
      check_tag=$(echo "$check_tag" | tr -d '[:space:]')
      [ "$filter_tag" = "$check_tag" ] && return 0
    done
  done
  return 1
}

# Install a plugin from a Git URL
gk_plugin_install() {
  local url="$1"
  if [ -z "$url" ]; then
    echo "Usage: gk_plugin_install <git-url>" >&2
    return 1
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo "git is required to install plugins" >&2
    return 1
  fi

  # Derive plugin directory name from URL
  local repo_name
  repo_name=$(basename "$url" .git)
  local plugin_path="${GK_PLUGIN_DIR}/${repo_name}"

  # Check if already installed
  if [ -d "$plugin_path" ]; then
    local existing_name
    existing_name=$(_gk_yaml_field "${plugin_path}/metadata.yaml" "name")
    echo "Plugin '${existing_name:-$repo_name}' already installed at ${plugin_path}"
    return 0
  fi

  # Security: warn about executing remote code
  if [ "${GK_TRUST_PLUGINS:-false}" != "true" ]; then
    echo "WARNING: Installing plugin from $url"
    echo "Plugin checks execute as shell scripts with full access."
    echo "Only install plugins from sources you trust."
    echo "Set GK_TRUST_PLUGINS=true to suppress this warning."
    echo ""
    # In interactive mode, ask for confirmation
    if [ -t 0 ]; then
      printf "Continue? [y/N] "
      read -r confirm
      if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        return 1
      fi
    fi
  fi

  # Clone into plugin dir
  mkdir -p "$GK_PLUGIN_DIR"
  if ! git clone --depth=1 "$url" "$plugin_path" 2>&1; then
    echo "Failed to clone plugin from $url" >&2
    rm -rf "$plugin_path"
    return 1
  fi

  # Validate structure
  if [ ! -f "${plugin_path}/metadata.yaml" ]; then
    echo "Invalid plugin: missing metadata.yaml in $url" >&2
    rm -rf "$plugin_path"
    return 1
  fi

  if [ ! -d "${plugin_path}/checks" ]; then
    echo "Invalid plugin: missing checks/ directory in $url" >&2
    rm -rf "$plugin_path"
    return 1
  fi

  local plugin_name
  plugin_name=$(_gk_yaml_field "${plugin_path}/metadata.yaml" "name")
  echo "Plugin '${plugin_name:-$repo_name}' installed successfully"
  return 0
}

# List installed plugins
gk_plugin_list() {
  if [ ! -d "$GK_PLUGIN_DIR" ]; then
    echo "No plugins installed (${GK_PLUGIN_DIR} not found)"
    return 0
  fi

  local found=0
  for plugin_path in "${GK_PLUGIN_DIR}"/*/; do
    [ -d "$plugin_path" ] || continue
    local meta="${plugin_path}metadata.yaml"
    if [ ! -f "$meta" ]; then
      continue
    fi
    local name version description
    name=$(_gk_yaml_field "$meta" "name")
    version=$(_gk_yaml_field "$meta" "version")
    description=$(_gk_yaml_field "$meta" "description")
    printf "  %-20s  %-10s  %s\n" "${name:-unknown}" "${version:--}" "${description:-}"
    found=$((found + 1))
  done

  if [ $found -eq 0 ]; then
    echo "No plugins installed"
  fi
}

# Run all checks from installed plugins (uses GK_PLUGIN_DIR, GK_TAGS)
gk_plugin_run() {
  if [ ! -d "$GK_PLUGIN_DIR" ]; then
    return 0
  fi

  for plugin_path in "${GK_PLUGIN_DIR}"/*/; do
    [ -d "$plugin_path" ] || continue
    local plugin_meta="${plugin_path}metadata.yaml"
    [ -f "$plugin_meta" ] || continue

    local plugin_name
    plugin_name=$(_gk_yaml_field "$plugin_meta" "name")

    local checks_dir="${plugin_path}checks"
    [ -d "$checks_dir" ] || continue

    for check_dir in "${checks_dir}"/*/; do
      [ -d "$check_dir" ] || continue
      local check_meta="${check_dir}metadata.yaml"
      local check_script="${check_dir}check.sh"

      [ -f "$check_meta" ] || continue
      [ -f "$check_script" ] || continue

      local check_id check_severity check_tags check_compliance check_fix_hint
      check_id=$(_gk_yaml_any_field "$check_meta" "id")
      check_severity=$(_gk_yaml_any_field "$check_meta" "severity")
      check_tags=$(_gk_yaml_any_field "$check_meta" "tags")
      check_compliance=$(_gk_yaml_any_field "$check_meta" "compliance")
      check_fix_hint=$(_gk_yaml_any_field "$check_meta" "fix_hint")

      check_id="${check_id:-$(basename "$check_dir")}"
      check_severity="${check_severity:-critical}"

      # Filter by tags if GK_TAGS is set
      if ! _gk_tags_match "$check_tags"; then
        gk_skip_check "P:${check_id}" "${plugin_name}/${check_id}" "tag-filtered"
        continue
      fi

      local label="P:${check_id}"
      local display_name="${plugin_name}/${check_id}"
      [ -n "$check_compliance" ] && display_name="${display_name} [${check_compliance}]"

      gk_run_check "$label" "$display_name" "$check_severity" bash "$check_script"
    done
  done
}

# Remove a plugin by name
gk_plugin_remove() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "Usage: gk_plugin_remove <name>" >&2
    return 1
  fi

  if [ ! -d "$GK_PLUGIN_DIR" ]; then
    echo "No plugins directory found at ${GK_PLUGIN_DIR}" >&2
    return 1
  fi

  local removed=0
  for plugin_path in "${GK_PLUGIN_DIR}"/*/; do
    [ -d "$plugin_path" ] || continue
    local meta="${plugin_path}metadata.yaml"
    local plugin_name
    plugin_name=$(_gk_yaml_field "$meta" "name")

    # Match by metadata name or directory name
    local dir_name
    dir_name=$(basename "$plugin_path")
    if [ "$plugin_name" = "$name" ] || [ "$dir_name" = "$name" ]; then
      rm -rf "$plugin_path"
      echo "Plugin '${plugin_name:-$dir_name}' removed"
      removed=$((removed + 1))
    fi
  done

  if [ $removed -eq 0 ]; then
    echo "Plugin '$name' not found" >&2
    return 1
  fi
  return 0
}
