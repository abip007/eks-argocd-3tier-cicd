#!/usr/bin/env bash
# Smoke tests: a few fast checks against the LIVE app, through the real path
# (Route 53 -> ALB -> nginx -> backend -> Postgres). Needs only bash + curl.
#
#   bash tests/smoke/smoke.sh https://cicd-bmi.bestclick.click
#
# Writes reports/smoke-junit.xml (CodeBuild shows it under Reports).
# Note: check 4 inserts one real measurement per run.
set -uo pipefail
BASE="${1:?usage: smoke.sh <base-url>}"; BASE="${BASE%/}"
CURL=(curl -sS --max-time 15)
# Windows Git Bash curl (schannel) often cannot reach the revocation server.
case "$(uname -s)" in MINGW*|MSYS*) CURL+=(--ssl-no-revoke) ;; esac

pass=0; fail=0; cases=""
check() {   # check <name> <ok?> <detail>
  if [ "$2" = 0 ]; then
    pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"
    cases+="<testcase classname=\"smoke\" name=\"$1\"/>"
  else
    fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n       %s\n' "$1" "$3"
    cases+="<testcase classname=\"smoke\" name=\"$1\"><failure message=\"$(echo "$3" | tr -d '"<>&' | head -c 300)\"/></testcase>"
  fi
}
# req <method> <path> [json-body] -> sets CODE and BODY
req() {
  local out
  if [ -n "${3:-}" ]; then
    out=$("${CURL[@]}" -X "$1" -H 'Content-Type: application/json' -d "$3" -w $'\n%{http_code}' "$BASE$2" 2>&1)
  else
    out=$("${CURL[@]}" -X "$1" -w $'\n%{http_code}' "$BASE$2" 2>&1)
  fi
  CODE="${out##*$'\n'}"; BODY="${out%$'\n'*}"
}
has() { [[ "$BODY" == *"$1"* ]]; }

echo "Smoke testing $BASE"

req GET /
[ "$CODE" = 200 ] && has '<div id="root">'; check "frontend serves index.html" $? "HTTP $CODE"

req GET /api/health
[ "$CODE" = 200 ] && has '"status":"ok"' && has '"database":"up"'; check "api health: backend and database up" $? "HTTP $CODE $BODY"

if [[ "$BASE" == https://* ]]; then   # skipped for a local http:// run
  http_url="http://${BASE#https://}"
  code=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$http_url/")
  [[ "$code" =~ ^30[178]$ ]]; check "http redirects to https (ALB)" $? "HTTP $code from $http_url/"
fi

req POST /api/measurements '{"weightKg":70,"heightCm":175,"age":30,"sex":"male","activity":"moderate"}'
[ "$CODE" = 201 ] && has '"bmi":"22.9"' && has '"bmi_category":"Normal"' && has '"bmr":1649'
check "create measurement calculates BMI 22.9 / BMR 1649" $? "HTTP $CODE $BODY"

req POST /api/measurements '{"weightKg":70}'
[ "$CODE" = 400 ]; check "invalid measurement is rejected (400)" $? "HTTP $CODE $BODY"

req GET /api/measurements
[ "$CODE" = 200 ] && has '"rows":[{'; check "list measurements returns rows" $? "HTTP $CODE ${BODY:0:200}"

req GET /api/measurements/trends
[ "$CODE" = 200 ] && has '"rows":'; check "30-day trends endpoint" $? "HTTP $CODE ${BODY:0:200}"

req GET /api/does-not-exist
[ "$CODE" = 404 ]; check "unknown api route returns 404" $? "HTTP $CODE"

mkdir -p reports
printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="smoke" tests="%d" failures="%d">%s</testsuite>\n' \
  $((pass+fail)) "$fail" "$cases" > reports/smoke-junit.xml

echo
echo "Smoke tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
