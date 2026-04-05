#!/usr/bin/env bash
# formatters.sh — SARIF, JUnit XML, and HTML report output formats

# ─── SARIF 2.1.0 ────────────────────────────────────────────────────────────

gk_write_sarif() {
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local git_sha
  git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

  # Collect unique rule IDs from all checks
  local rules_json=""
  local results_json=""
  local first_rule=true
  local first_result=true

  for entry in "${GK_CHECKS[@]}"; do
    local id name status details severity
    id=$(echo "$entry"     | sed 's/.*"id":"\([^"]*\)".*/\1/')
    name=$(echo "$entry"   | sed 's/.*"name":"\([^"]*\)".*/\1/')
    status=$(echo "$entry" | sed 's/.*"status":"\([^"]*\)".*/\1/')
    details=$(echo "$entry"| sed 's/.*"details":"\([^"]*\)".*/\1/')
    severity=$(echo "$entry"| sed 's/.*"severity":"\([^"]*\)".*/\1/')

    local rule_id="GK${id}"

    # Map status to SARIF level
    local level
    case "$status" in
      FAIL) level="error"   ;;
      HIGH) level="error"   ;;
      WARN) level="warning" ;;
      INFO) level="note"    ;;
      *)    level="none"    ;;
    esac

    # Build rules array entry
    local comma_r=""
    [ "$first_rule" = false ] && comma_r=","
    rules_json="${rules_json}${comma_r}
        {
          \"id\": \"${rule_id}\",
          \"name\": \"${name}\",
          \"shortDescription\": { \"text\": \"${name}\" },
          \"properties\": { \"severity\": \"${severity}\" }
        }"
    first_rule=false

    # Build results array entry
    local msg_text="${status}"
    [ -n "$details" ] && msg_text="${status}: ${details}"
    local comma_res=""
    [ "$first_result" = false ] && comma_res=","
    results_json="${results_json}${comma_res}
      {
        \"ruleId\": \"${rule_id}\",
        \"level\": \"${level}\",
        \"message\": { \"text\": \"${msg_text}\" }
      }"
    first_result=false
  done

  cat <<SARIF
{
  "\$schema": "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json",
  "version": "2.1.0",
  "runs": [
    {
      "tool": {
        "driver": {
          "name": "gate-keeper",
          "version": "${VERSION:-unknown}",
          "informationUri": "https://github.com/NiuChou/gate-keeper",
          "rules": [${rules_json}
          ]
        }
      },
      "results": [${results_json}
      ],
      "properties": {
        "project": "${GK_PROJECT}",
        "timestamp": "${timestamp}",
        "gitSha": "${git_sha}",
        "passed": ${GK_PASSED},
        "failed": ${GK_FAILED},
        "high": ${GK_HIGHS},
        "warnings": ${GK_WARNINGS},
        "infos": ${GK_INFOS},
        "skipped": ${GK_SKIPPED}
      }
    }
  ]
}
SARIF
}

# ─── JUnit XML ──────────────────────────────────────────────────────────────

gk_write_junit() {
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local total=$((GK_PASSED + GK_FAILED + GK_HIGHS + GK_WARNINGS + GK_INFOS + GK_SKIPPED))
  local failures=$((GK_FAILED + GK_HIGHS))

  local testcases=""
  for entry in "${GK_CHECKS[@]}"; do
    local id name status details duration_ms severity
    id=$(echo "$entry"        | sed 's/.*"id":"\([^"]*\)".*/\1/')
    name=$(echo "$entry"      | sed 's/.*"name":"\([^"]*\)".*/\1/')
    status=$(echo "$entry"    | sed 's/.*"status":"\([^"]*\)".*/\1/')
    details=$(echo "$entry"   | sed 's/.*"details":"\([^"]*\)".*/\1/')
    duration_ms=$(echo "$entry"| sed 's/.*"duration_ms":\([0-9]*\).*/\1/')
    severity=$(echo "$entry"  | sed 's/.*"severity":"\([^"]*\)".*/\1/')

    # Convert ms to seconds (decimal)
    local time_s
    time_s=$(awk "BEGIN { printf \"%.3f\", ${duration_ms:-0}/1000 }")

    local classname="gate-keeper.${GK_LAYER:-all}"
    local tc_open="    <testcase name=\"[${id}] ${name}\" classname=\"${classname}\" time=\"${time_s}\">"

    case "$status" in
      FAIL|HIGH)
        local ftype
        [ "$status" = "FAIL" ] && ftype="critical" || ftype="high"
        testcases="${testcases}
${tc_open}
      <failure type=\"${ftype}\" message=\"${status}: ${name}\">${details}</failure>
    </testcase>"
        ;;
      WARN)
        testcases="${testcases}
${tc_open}
      <system-out>WARNING: ${name} — ${details}</system-out>
    </testcase>"
        ;;
      SKIP)
        testcases="${testcases}
    <testcase name=\"[${id}] ${name}\" classname=\"${classname}\" time=\"0.000\">
      <skipped message=\"${details:-disabled}\"/>
    </testcase>"
        ;;
      *)
        testcases="${testcases}
${tc_open}
    </testcase>"
        ;;
    esac
  done

  cat <<JUNIT
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="gate-keeper" tests="${total}" failures="${failures}" skipped="${GK_SKIPPED}" time="0" timestamp="${timestamp}">
  <testsuite name="${GK_PROJECT:-unknown}" tests="${total}" failures="${failures}" skipped="${GK_SKIPPED}" timestamp="${timestamp}">
${testcases}
  </testsuite>
</testsuites>
JUNIT
}

# ─── HTML Report ────────────────────────────────────────────────────────────

# Escape HTML special characters to prevent XSS
_gk_html_escape() {
  echo "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

gk_write_html() {
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local git_sha
  git_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  local total=$((GK_PASSED + GK_FAILED + GK_HIGHS + GK_WARNINGS + GK_INFOS + GK_SKIPPED))

  local verdict="PASSED"
  local verdict_color="#16a34a"
  if [ $GK_FAILED -gt 0 ] || [ $GK_HIGHS -gt 0 ]; then
    verdict="BLOCKED"
    verdict_color="#dc2626"
  elif [ $GK_WARNINGS -gt 0 ]; then
    verdict="WARNED"
    verdict_color="#d97706"
  fi

  # Build table rows
  local rows=""
  for entry in "${GK_CHECKS[@]}"; do
    local id name status details duration_ms severity
    id=$(echo "$entry"        | sed 's/.*"id":"\([^"]*\)".*/\1/')
    name=$(echo "$entry"      | sed 's/.*"name":"\([^"]*\)".*/\1/')
    status=$(echo "$entry"    | sed 's/.*"status":"\([^"]*\)".*/\1/')
    details=$(echo "$entry"   | sed 's/.*"details":"\([^"]*\)".*/\1/')
    duration_ms=$(echo "$entry"| sed 's/.*"duration_ms":\([0-9]*\).*/\1/')
    severity=$(echo "$entry"  | sed 's/.*"severity":"\([^"]*\)".*/\1/')

    local badge_color
    case "$status" in
      FAIL) badge_color="#dc2626" ;;
      HIGH) badge_color="#ea580c" ;;
      WARN) badge_color="#d97706" ;;
      INFO) badge_color="#2563eb" ;;
      PASS) badge_color="#16a34a" ;;
      *)    badge_color="#6b7280" ;;
    esac

    # Escape for XSS prevention
    id=$(_gk_html_escape "$id")
    name=$(_gk_html_escape "$name")
    details=$(_gk_html_escape "$details")

    rows="${rows}
    <tr>
      <td>${id}</td>
      <td>${name}</td>
      <td><span class=\"badge\" style=\"background:${badge_color}\">${status}</span></td>
      <td>${severity}</td>
      <td>${duration_ms}ms</td>
      <td class=\"details\">${details}</td>
    </tr>"
  done

  cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Gate Keeper Report — ${GK_PROJECT:-unknown}</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#f3f4f6;color:#111827}
  header{background:#1e293b;color:#f8fafc;padding:1.5rem 2rem;display:flex;align-items:center;justify-content:space-between}
  header h1{font-size:1.4rem;font-weight:700;letter-spacing:.02em}
  header .meta{font-size:.8rem;color:#94a3b8;margin-top:.25rem}
  .verdict{font-size:1rem;font-weight:700;padding:.4rem .9rem;border-radius:6px;color:#fff;background:${verdict_color}}
  .container{max-width:1100px;margin:2rem auto;padding:0 1rem}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:1rem;margin-bottom:2rem}
  .card{background:#fff;border-radius:8px;padding:1.2rem 1rem;text-align:center;box-shadow:0 1px 3px rgba(0,0,0,.1)}
  .card .num{font-size:2rem;font-weight:700}
  .card .lbl{font-size:.75rem;color:#6b7280;margin-top:.25rem;text-transform:uppercase;letter-spacing:.05em}
  .card.pass .num{color:#16a34a}
  .card.fail .num{color:#dc2626}
  .card.high .num{color:#ea580c}
  .card.warn .num{color:#d97706}
  .card.info .num{color:#2563eb}
  .card.skip .num{color:#6b7280}
  table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.1)}
  th{background:#1e293b;color:#f8fafc;padding:.75rem 1rem;text-align:left;font-size:.8rem;text-transform:uppercase;letter-spacing:.05em}
  td{padding:.7rem 1rem;border-bottom:1px solid #e5e7eb;font-size:.875rem;vertical-align:top}
  tr:last-child td{border-bottom:none}
  tr:hover td{background:#f9fafb}
  .badge{display:inline-block;padding:.2rem .55rem;border-radius:4px;color:#fff;font-size:.75rem;font-weight:600;letter-spacing:.04em}
  .details{color:#6b7280;font-size:.8rem;max-width:320px;word-break:break-word}
  footer{text-align:center;padding:2rem;font-size:.75rem;color:#9ca3af}
  @media(max-width:640px){.cards{grid-template-columns:repeat(3,1fr)}.details{display:none}}
</style>
</head>
<body>
<header>
  <div>
    <h1>Gate Keeper v${VERSION:-unknown} &mdash; ${GK_PROJECT:-unknown}</h1>
    <div class="meta">${timestamp} &nbsp;|&nbsp; git: ${git_sha} &nbsp;|&nbsp; layer: ${GK_LAYER:-all} &nbsp;|&nbsp; fail-on: ${GK_FAIL_ON:-critical}</div>
  </div>
  <div class="verdict">${verdict}</div>
</header>
<div class="container">
  <div class="cards">
    <div class="card pass"><div class="num">${GK_PASSED}</div><div class="lbl">Passed</div></div>
    <div class="card fail"><div class="num">${GK_FAILED}</div><div class="lbl">Critical</div></div>
    <div class="card high"><div class="num">${GK_HIGHS}</div><div class="lbl">High</div></div>
    <div class="card warn"><div class="num">${GK_WARNINGS}</div><div class="lbl">Warnings</div></div>
    <div class="card info"><div class="num">${GK_INFOS}</div><div class="lbl">Info</div></div>
    <div class="card skip"><div class="num">${GK_SKIPPED}</div><div class="lbl">Skipped</div></div>
  </div>
  <table>
    <thead>
      <tr>
        <th>ID</th><th>Check</th><th>Status</th><th>Severity</th><th>Time</th><th>Details</th>
      </tr>
    </thead>
    <tbody>
${rows}
    </tbody>
  </table>
</div>
<footer>Generated by gate-keeper v${VERSION:-unknown} &mdash; ${timestamp}</footer>
</body>
</html>
HTML
}
