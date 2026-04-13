#!/usr/bin/env bash
# audit_ext.sh — Extended audit capabilities (trend, CSV export, heatmap)

# Show pass rate trend as ASCII bar chart (last 10 runs)
gk_audit_trend() {
  if [ ! -d "$GK_AUDIT_DIR" ]; then
    echo "No audit logs found at $GK_AUDIT_DIR"
    return 0
  fi

  local files=()
  while read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(ls -t "$GK_AUDIT_DIR"/*.json 2>/dev/null | head -10)

  if [ ${#files[@]} -eq 0 ]; then
    echo "No audit logs found."
    return 0
  fi

  # Reverse so oldest is first (chronological order)
  local ordered=()
  for (( i=${#files[@]}-1; i>=0; i-- )); do
    ordered+=("${files[$i]}")
  done

  echo "Pass Rate Trend (last 10 runs):"
  echo ""

  for f in "${ordered[@]}"; do
    local ts
    ts=$(grep '"timestamp"' "$f" | sed 's/.*"timestamp": *"//' | sed 's/".*//' | cut -c1-10)
    local passed failed high total rate
    passed=$(grep '"passed"' "$f" | sed 's/.*"passed": *//' | sed 's/[^0-9].*//')
    failed=$(grep '"failed"' "$f" | sed 's/.*"failed": *//' | sed 's/[^0-9].*//')
    high=$(grep '"high"' "$f" | sed 's/.*"high": *//' | sed 's/[^0-9].*//')
    passed=${passed:-0}
    failed=${failed:-0}
    high=${high:-0}
    total=$(( passed + failed + high ))

    if [ "$total" -eq 0 ]; then
      rate=100
    else
      rate=$(( passed * 100 / total ))
    fi

    # Build 20-char bar: filled = rate/5 chars, empty = rest
    local filled=$(( rate / 5 ))
    local empty=$(( 20 - filled ))
    local bar=""
    local i
    for (( i=0; i<filled; i++ )); do bar="${bar}█"; done
    for (( i=0; i<empty; i++ )); do bar="${bar}░"; done

    printf "%-12s  %s  %3d%%\n" "$ts" "$bar" "$rate"
  done
}

# Export audit history as CSV to stdout
gk_audit_export_csv() {
  if [ ! -d "$GK_AUDIT_DIR" ]; then
    echo "No audit logs found at $GK_AUDIT_DIR"
    return 0
  fi

  local files=()
  while read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(ls -t "$GK_AUDIT_DIR"/*.json 2>/dev/null)

  if [ ${#files[@]} -eq 0 ]; then
    echo "No audit logs found."
    return 0
  fi

  echo "timestamp,git_sha,project,passed,failed,warnings,verdict"

  for f in "${files[@]}"; do
    local timestamp git_sha project passed failed warnings verdict
    timestamp=$(grep '"timestamp"' "$f" | sed 's/.*"timestamp": *"//' | sed 's/".*//')
    git_sha=$(grep '"git_sha"' "$f" | sed 's/.*"git_sha": *"//' | sed 's/".*//')
    project=$(grep '"project"' "$f" | sed 's/.*"project": *"//' | sed 's/".*//')
    passed=$(grep '"passed"' "$f" | sed 's/.*"passed": *//' | sed 's/[^0-9].*//')
    failed=$(grep '"failed"' "$f" | sed 's/.*"failed": *//' | sed 's/[^0-9].*//')
    warnings=$(grep '"warnings"' "$f" | sed 's/.*"warnings": *//' | sed 's/[^0-9].*//')
    verdict=$(grep '"verdict"' "$f" | sed 's/.*"verdict": *"//' | sed 's/".*//')
    timestamp=${timestamp:-}
    git_sha=${git_sha:-}
    project=${project:-}
    passed=${passed:-0}
    failed=${failed:-0}
    warnings=${warnings:-0}
    verdict=${verdict:-}
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
      "$timestamp" "$git_sha" "$project" "$passed" "$failed" "$warnings" "$verdict"
  done
}

# Show check duration heatmap from most recent audit log
gk_audit_heatmap() {
  if [ ! -d "$GK_AUDIT_DIR" ]; then
    echo "No audit logs found at $GK_AUDIT_DIR"
    return 0
  fi

  local latest
  latest=$(ls -t "$GK_AUDIT_DIR"/*.json 2>/dev/null | head -1)

  if [ -z "$latest" ]; then
    echo "No audit logs found."
    return 0
  fi

  # Extract check id, name, duration_ms from each check object.
  # The checks array may be single-line JSON; split on },{  to get one object per line.
  # Each object looks like: {"id":"A ","name":"go.work validation ","status":"PASS",...,"duration_ms":120,...}
  local raw
  raw=$(sed 's/},{/}\n{/g' "$latest" | awk '
    /\{/ {
      id=""; name=""; dur=0
      # extract id: match "id":"VALUE" — 6 chars prefix, 1 char trailing quote
      match($0, /"id":"[^"]*"/)
      if (RSTART) {
        val=substr($0, RSTART+6, RLENGTH-7)
        gsub(/[[:space:]]/, "", val)
        id=val
      }
      # extract name: match "name":"VALUE" — 8 chars prefix, 1 char trailing quote
      match($0, /"name":"[^"]*"/)
      if (RSTART) {
        val=substr($0, RSTART+8, RLENGTH-9)
        gsub(/[[:space:]]*$/, "", val)
        name=val
      }
      # extract duration_ms (numeric)
      match($0, /"duration_ms":[0-9]+/)
      if (RSTART) {
        val=substr($0, RSTART+13, RLENGTH-13)
        dur=val+0
      }
      if (id != "") print id "|" name "|" dur
    }
  ')

  if [ -z "$raw" ]; then
    echo "No check data found in $latest"
    return 0
  fi

  # Find max duration for scaling
  local max_ms=1
  while IFS='|' read -r id name dur; do
    [ -z "$dur" ] && continue
    [ "$dur" -gt "$max_ms" ] && max_ms="$dur"
  done <<< "$raw"

  echo "Check Duration Heatmap:"
  echo ""

  # Sort by duration descending and display
  while IFS='|' read -r id name dur; do
    [ -z "$id" ] && continue
    dur=${dur:-0}
    # Scale to 10-char bar
    local bar_len=0
    if [ "$max_ms" -gt 0 ]; then
      bar_len=$(( dur * 10 / max_ms ))
      [ "$bar_len" -eq 0 ] && [ "$dur" -gt 0 ] && bar_len=1
    fi
    local bar=""
    local i
    for (( i=0; i<bar_len; i++ )); do bar="${bar}█"; done
    # Trim trailing spaces from name
    name=$(echo "$name" | sed 's/[[:space:]]*$//')
    id=$(echo "$id" | sed 's/[[:space:]]*$//')
    printf "[%-2s] %-35s %-10s  %dms\n" "$id" "$name" "$bar" "$dur"
  done < <(echo "$raw" | awk -F'|' '{print $3"|"$0}' | sort -t'|' -k1 -rn | cut -d'|' -f2-)
}

# Analyze CI/deployment health from audit history (last 20 runs)
gk_audit_health() {
  if [ ! -d "$GK_AUDIT_DIR" ]; then
    echo "No audit logs found at $GK_AUDIT_DIR"
    return 0
  fi

  local files=()
  while read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(ls -t "$GK_AUDIT_DIR"/*.json 2>/dev/null | head -20)

  local n=${#files[@]}
  if [ "$n" -eq 0 ]; then
    echo "No audit logs found."
    return 0
  fi

  # --- Current streak: consecutive same verdict from most recent run ---
  local streak_verdict streak_count i
  streak_verdict=$(grep '"verdict"' "${files[0]}" | sed 's/.*"verdict": *"//' | sed 's/".*//')
  streak_count=1
  for (( i=1; i<n; i++ )); do
    local v
    v=$(grep '"verdict"' "${files[$i]}" | sed 's/.*"verdict": *"//' | sed 's/".*//')
    if [ "$v" = "$streak_verdict" ]; then
      streak_count=$(( streak_count + 1 ))
    else
      break
    fi
  done

  # --- Pass rate: PASSED or WARNED vs BLOCKED ---
  local pass_count=0
  for (( i=0; i<n; i++ )); do
    local v
    v=$(grep '"verdict"' "${files[$i]}" | sed 's/.*"verdict": *"//' | sed 's/".*//')
    if [ "$v" = "PASSED" ] || [ "$v" = "WARNED" ]; then
      pass_count=$(( pass_count + 1 ))
    fi
  done
  local pass_rate=$(( pass_count * 100 / n ))

  # --- Regression count: PASSED->BLOCKED transitions (newest first, so look forward) ---
  local regressions=0
  for (( i=0; i<n-1; i++ )); do
    local cur next
    cur=$(grep '"verdict"' "${files[$i]}" | sed 's/.*"verdict": *"//' | sed 's/".*//')
    next=$(grep '"verdict"' "${files[$((i+1))]}" | sed 's/.*"verdict": *"//' | sed 's/".*//')
    # files are newest-first: transition from older PASSED (files[i+1]) to newer BLOCKED (files[i])
    if [ "$cur" = "BLOCKED" ] && ( [ "$next" = "PASSED" ] || [ "$next" = "WARNED" ] ); then
      regressions=$(( regressions + 1 ))
    fi
  done

  # --- Most failing checks: aggregate check IDs with status FAIL or HIGH across all runs ---
  local check_counts
  check_counts=$(
    for (( i=0; i<n; i++ )); do
      # Split checks array on },{ then parse each object for id and status
      sed 's/},{/}\n{/g' "${files[$i]}" | awk '
        /\{/ {
          id=""; status=""
          match($0, /"id":"[^"]*"/)
          if (RSTART) {
            val=substr($0, RSTART+6, RLENGTH-7)
            gsub(/[[:space:]]/, "", val)
            id=val
          }
          match($0, /"status":"[^"]*"/)
          if (RSTART) {
            val=substr($0, RSTART+10, RLENGTH-11)
            gsub(/[[:space:]]/, "", val)
            status=val
          }
          match($0, /"name":"[^"]*"/)
          if (RSTART) {
            val=substr($0, RSTART+8, RLENGTH-9)
            gsub(/[[:space:]]*$/, "", val)
            name=val
          }
          if (id != "" && (status == "FAIL" || status == "HIGH")) {
            print id "|" name
          }
        }
      '
    done | sort | awk -F'|' '
      {
        key=$1; name=$2
        count[key]++
        names[key]=name
      }
      END {
        for (k in count) print count[k] "|" k "|" names[k]
      }
    ' | sort -t'|' -k1 -rn | head -5
  )

  # --- Output ---
  echo "CI Health Report (last $n runs):"
  echo ""

  if [ "$streak_verdict" = "BLOCKED" ]; then
    printf "  Current streak:  %d consecutive BLOCKED ❌\n" "$streak_count"
  else
    printf "  Current streak:  %d consecutive PASSED ✅\n" "$streak_count"
  fi
  printf "  Pass rate:       %d%% (%d/%d)\n" "$pass_rate" "$pass_count" "$n"
  printf "  Regressions:     %d (PASS→BLOCK transitions)\n" "$regressions"

  if [ -n "$check_counts" ]; then
    echo ""
    echo "  Most failing checks:"
    while IFS='|' read -r cnt cid cname; do
      cid=$(echo "$cid" | sed 's/[[:space:]]*$//')
      cname=$(echo "$cname" | sed 's/[[:space:]]*$//')
      printf "    [%-4s] %-35s — failed %d/%d runs\n" "$cid" "$cname" "$cnt" "$n"
    done <<< "$check_counts"
  fi

  echo ""

  # Warnings
  if [ "$streak_verdict" = "BLOCKED" ] && [ "$streak_count" -ge 3 ]; then
    echo "  ⚠ WARNING: 3+ consecutive failures. Tech debt is accumulating."
    echo "  Consider fixing CI before merging new features."
  fi

  if [ "$pass_rate" -lt 50 ]; then
    echo "  ⚠ CRITICAL: Pass rate below 50%. Deployment quality is degraded."
  fi
}
