#!/usr/bin/env bash
# Stage: SonarScan. Re-runs the tests to get coverage (a few seconds for this app;
# simpler than passing artifacts between actions), then uploads the analysis to
# SonarQube. Does NOT wait for the result - the QualityGate action does that.
# Settings: sonar-project.properties. Needs SONAR_HOST_URL and SONAR_TOKEN.
source "$(dirname "$0")/lib.sh"
need node npm npx
: "${SONAR_HOST_URL:?set SONAR_HOST_URL (CodeBuild env var)}" "${SONAR_TOKEN:?set SONAR_TOKEN (secret bmi-cicd/ci)}"

bash pipeline/stages/unit-test.sh

say "Make coverage paths relative to the repo root"
# lcov files say 'SF:src/app.js'; SonarQube resolves paths from the repo root.
for app in backend frontend; do
  sed -i -E "s#^SF:(src/)#SF:app/$app/\1#" "app/$app/coverage/lcov.info"
  grep -m1 '^SF:' "app/$app/coverage/lcov.info"
done

say "SonarQube analysis -> $SONAR_HOST_URL"
rm -rf .scannerwork
# @sonar/scan downloads the scanner and a Java runtime from the SonarQube server.
npx --yes @sonar/scan@4.4.0 \
  -Dsonar.host.url="$SONAR_HOST_URL" \
  -Dsonar.token="$SONAR_TOKEN" \
  -Dsonar.projectKey="${SONAR_PROJECT_KEY:-bmi-cicd}" \
  -Dsonar.projectVersion="${COMMIT_ID:-local}"

TASK_ID=$(sed -n 's/^ceTaskId=//p' .scannerwork/report-task.txt)
[ -n "$TASK_ID" ] || die "no ceTaskId in .scannerwork/report-task.txt"
echo "Background task: $TASK_ID"
output SONAR_CE_TASK_ID "$TASK_ID"
