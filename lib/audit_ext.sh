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
