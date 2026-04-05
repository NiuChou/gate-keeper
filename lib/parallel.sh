#!/usr/bin/env bash
# parallel.sh — Parallel check execution engine

# Cross-platform processor count
gk_get_nproc() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null || echo 4
  else
    echo 4
  fi
}

# Preview a check without executing it
# Args: id name severity [function_name args...]
gk_dry_run_check() {
  local id="$1" name="$2" severity="$3"
  shift 3
  local fn="${1:-<no function>}"
  printf "  [DRY-RUN] [%s] %-35s (%s)  would call: %s\n" "$id" "$name" "$severity" "$fn"
}

# Run multiple checks in parallel
# Args: check_specs... where each spec is "id|name|severity|function_name"
# Returns: 0 if all pass, 1 if any fail
gk_parallel_run_checks() {
  [ $# -eq 0 ] && return 0

  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN

  local max_jobs
  if [ "${GK_PARALLEL:-0}" -eq 0 ] 2>/dev/null; then
    max_jobs=$(gk_get_nproc)
  else
    max_jobs="${GK_PARALLEL}"
  fi

  local active_jobs=0
  local -a pids=()
  local -a spec_list=("$@")

  for spec in "${spec_list[@]}"; do
    # Parse pipe-delimited spec: id|name|severity|function_name
    local id name severity fn_name
    id=$(echo "$spec"    | cut -d'|' -f1)
    name=$(echo "$spec"  | cut -d'|' -f2)
    severity=$(echo "$spec" | cut -d'|' -f3)
    fn_name=$(echo "$spec" | cut -d'|' -f4)

    [ -z "$id" ] && continue

    if [ "${GK_DRY_RUN:-false}" = true ]; then
      gk_dry_run_check "$id" "$name" "$severity" "$fn_name"
      continue
    fi

    # Semaphore: wait for a slot when at capacity
    while [ "$active_jobs" -ge "$max_jobs" ]; do
      local new_pids=()
      local still_running=0
      for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
          new_pids+=("$pid")
          ((still_running++)) || true
        fi
      done
      pids=("${new_pids[@]}")
      active_jobs=$still_running
      [ "$active_jobs" -ge "$max_jobs" ] && sleep 0.05
    done

    local result_file="$tmpdir/${id}.result"
    (
      local start_ms end_ms duration status output
      start_ms=$(gk_now_ms)

      if output=$("$fn_name" 2>&1); then
        status="PASS"
      else
        case "$severity" in
          critical) status="FAIL" ;;
          high)     status="HIGH" ;;
          warning)  status="WARN" ;;
          info)     status="INFO" ;;
          *)        status="FAIL" ;;
        esac
      fi

      end_ms=$(gk_now_ms)
      duration=$(( end_ms - start_ms ))
      # Encode output: replace newlines with \n for single-line storage
      local encoded_output
      encoded_output=$(printf '%s' "$output" | tr '\n' '\x01')
      printf '%s|%s|%s\n' "$status" "$duration" "$encoded_output" > "$result_file"
    ) &

    local pid=$!
    pids+=("$pid")
    ((active_jobs++)) || true
  done

  wait

  [ "${GK_DRY_RUN:-false}" = true ] && return 0

  # Collect results and call gk_record + gk_print_check
  local any_failed=0
  for spec in "${spec_list[@]}"; do
    local id name severity
    id=$(echo "$spec"    | cut -d'|' -f1)
    name=$(echo "$spec"  | cut -d'|' -f2)
    severity=$(echo "$spec" | cut -d'|' -f3)

    [ -z "$id" ] && continue

    local result_file="$tmpdir/${id}.result"
    if [ ! -f "$result_file" ]; then
      gk_record "$id" "$name" "FAIL" "result file missing" 0 "$severity"
      gk_print_check "$id" "$name" "FAIL" 0
      any_failed=1
      continue
    fi

    local line status duration_ms encoded_details details
    line=$(cat "$result_file")
    status=$(echo "$line"       | cut -d'|' -f1)
    duration_ms=$(echo "$line"  | cut -d'|' -f2)
    encoded_details=$(echo "$line" | cut -d'|' -f3-)
    # Decode \x01 back to newlines
    details=$(printf '%s' "$encoded_details" | tr '\x01' '\n')

    gk_record "$id" "$name" "$status" "$details" "$duration_ms" "$severity"
    gk_print_check "$id" "$name" "$status" "$duration_ms"

    if [ "$status" = "FAIL" ] || [ "$status" = "WARN" ] || [ "$status" = "HIGH" ]; then
      if [ -n "$details" ]; then
        echo "$details" | head -8 | sed 's/^/    /'
      fi
      { [ "$status" = "FAIL" ] || [ "$status" = "HIGH" ]; } && any_failed=1
    fi
  done

  return $any_failed
}
