#!/usr/bin/env bash
# One-time SonarQube setup through its Web API (the console guide does the same
# by clicking). Safe to re-run: existing items are kept, the CI token is renewed.
#
#   SONAR_HOST_URL=http://<elastic-ip>:9000 SONAR_ADMIN_PASSWORD='Str0ng-Passw0rd!' \
#     bash sonarqube/setup-sonarqube.sh
#
# 1. waits for SonarQube, changes the default admin/admin password
# 2. creates project 'bmi-cicd'
# 3. creates quality gate 'bmi-cicd-gate' and assigns it to the project
# 4. creates user 'ci-pipeline' (Browse + Execute Analysis on the project only)
# 5. generates a token for it and stores it in Secrets Manager (bmi-cicd/ci:sonar_token)
set -euo pipefail
: "${SONAR_HOST_URL:?e.g. http://13.200.1.2:9000}"
: "${SONAR_ADMIN_PASSWORD:?new admin password: >= 12 chars, upper, lower, digit, special}"
PROJECT_KEY="${SONAR_PROJECT_KEY:-bmi-cicd}"
GATE="${SONAR_GATE:-bmi-cicd-gate}"
CI_USER="ci-pipeline"
SECRET_ID="${SECRET_ID:-bmi-cicd/ci}"
SONAR_HOST_URL="${SONAR_HOST_URL%/}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
# api <GET|POST> <path> [curl args...]  (admin basic auth)
api() { local m=$1 p=$2; shift 2; curl -fsS -u "admin:$SONAR_ADMIN_PASSWORD" -X "$m" "$SONAR_HOST_URL/api/$p" "$@"; }
try() { api "$@" >/dev/null 2>&1; }

say "1. Wait for SonarQube at $SONAR_HOST_URL"
for i in $(seq 1 60); do
  status=$(curl -fsS --max-time 5 "$SONAR_HOST_URL/api/system/status" 2>/dev/null | grep -o '"status":"[A-Z_]*"' | cut -d'"' -f4 || true)
  echo "  status: ${status:-unreachable}"
  [ "$status" = UP ] && break
  [ "$i" = 60 ] && die "SonarQube not UP after 10 minutes (EC2 user data log: /var/log/cloud-init-output.log)"
  sleep 10
done

if curl -fsS -u admin:admin "$SONAR_HOST_URL/api/authentication/validate" | grep -q '"valid":true'; then
  echo "  changing the default admin password"
  curl -fsS -u admin:admin -X POST "$SONAR_HOST_URL/api/users/change_password" \
    --data-urlencode login=admin --data-urlencode previousPassword=admin \
    --data-urlencode "password=$SONAR_ADMIN_PASSWORD" >/dev/null
fi
api GET authentication/validate | grep -q '"valid":true' || die "admin login failed - wrong SONAR_ADMIN_PASSWORD?"

say "2. Project $PROJECT_KEY"
if api GET "projects/search?projects=$PROJECT_KEY" | grep -q "\"key\":\"$PROJECT_KEY\""; then
  echo "  exists"
else
  api POST projects/create --data-urlencode "project=$PROJECT_KEY" \
    --data-urlencode "name=BMI Health Tracker (CI/CD)" --data-urlencode visibility=private >/dev/null
  echo "  created"
fi

say "3. Quality gate $GATE"
api GET "qualitygates/show?name=$GATE" >/dev/null 2>&1 \
  || { api POST qualitygates/create --data-urlencode "name=$GATE" >/dev/null; echo "  created"; }
# A new gate already holds SonarQube's "Clean as You Code" conditions on NEW
# code (coverage < 80, duplication > 3%, hotspots reviewed < 100%, new issues > 0).
# Add conditions on the WHOLE code base too: the first analysis has no "new
# code" yet, and a gate that only looks at new code lets old debt through.
CONDITIONS=$(api GET "qualitygates/show?name=$GATE")
cond() {  # cond <op LT|GT> <threshold> <metric> [fallback-metric]
  local op=$1 err=$2 m; shift 2
  for m in "$@"; do
    if grep -q "\"metric\":\"$m\"" <<<"$CONDITIONS"; then echo "  condition exists: $m"; return; fi
  done
  for m in "$@"; do   # first metric this SonarQube version accepts wins
    if api POST qualitygates/create_condition --data-urlencode "gateName=$GATE" \
         --data-urlencode "metric=$m" --data-urlencode "op=$op" --data-urlencode "error=$err" >/dev/null 2>&1; then
      echo "  condition added:  $m $op $err"; return
    fi
  done
  die "could not add a condition on $*"
}
cond LT 80 coverage
cond GT 3  duplicated_lines_density
# Rating 1 = A. MQR-mode metric first (default since 10.8), Standard-mode fallback.
cond GT 1  software_quality_reliability_rating     reliability_rating
cond GT 1  software_quality_security_rating        security_rating
cond GT 1  software_quality_maintainability_rating sqale_rating
api POST qualitygates/select --data-urlencode "gateName=$GATE" --data-urlencode "projectKey=$PROJECT_KEY" >/dev/null
echo "  assigned to $PROJECT_KEY"

say "4. User $CI_USER"
# v2 users API: the old api/users/create drops the connection on SonarQube 26.x
# ("curl: (52) Empty reply from server").
if api GET "v2/users-management/users?q=$CI_USER" | grep -q "\"login\" *: *\"$CI_USER\""; then
  echo "  exists"
else
  # Random password nobody needs: the pipeline only uses the token.
  CI_PASS="$(openssl rand -base64 24 | tr -d '/+=\r\n')Aa1!"
  api POST v2/users-management/users -H 'Content-Type: application/json' \
    -d "{\"login\":\"$CI_USER\",\"name\":\"CI pipeline\",\"password\":\"$CI_PASS\",\"local\":true}" >/dev/null
  echo "  created"
fi
for perm in user scan; do   # user = Browse (read the gate), scan = Execute Analysis
  api POST permissions/add_user --data-urlencode "login=$CI_USER" \
    --data-urlencode "permission=$perm" --data-urlencode "projectKey=$PROJECT_KEY" >/dev/null
done
echo "  permissions: Browse + Execute Analysis on $PROJECT_KEY"

say "5. Token -> Secrets Manager $SECRET_ID"
try POST user_tokens/revoke --data-urlencode "login=$CI_USER" --data-urlencode "name=codebuild" || true
TOKEN=$(api POST user_tokens/generate --data-urlencode "login=$CI_USER" --data-urlencode "name=codebuild" \
  --data-urlencode "type=USER_TOKEN" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
[ -n "$TOKEN" ] || die "token generation failed"

CURRENT=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text)
GITHUB=$(echo "$CURRENT" | grep -o '"github_token" *: *"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/')
aws secretsmanager put-secret-value --secret-id "$SECRET_ID" \
  --secret-string "{\"github_token\":\"$GITHUB\",\"sonar_token\":\"$TOKEN\"}" >/dev/null
echo "  stored (github_token kept)"

cat <<EOF

Done. Open $SONAR_HOST_URL (admin / your new password).
Project:  $SONAR_HOST_URL/dashboard?id=$PROJECT_KEY
Gate:     $SONAR_HOST_URL/quality_gates
EOF
