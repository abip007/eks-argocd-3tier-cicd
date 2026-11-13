#!/usr/bin/env bash
# Stage: QualityGate. Waits until SonarQube has processed the analysis from the
# SonarScan action, then reads the quality gate. Red gate = failed action =
# nothing is built or deployed.
# Input: SONAR_CE_TASK_ID (= #{SonarScan.SONAR_CE_TASK_ID}); locally it falls back
# to .scannerwork/report-task.txt from your last sonar-scan run.
source "$(dirname "$0")/lib.sh"
need node curl
: "${SONAR_HOST_URL:?}" "${SONAR_TOKEN:?}"

TASK_ID="${SONAR_CE_TASK_ID:-}"
[ -n "$TASK_ID" ] || TASK_ID=$(sed -n 's/^ceTaskId=//p' .scannerwork/report-task.txt 2>/dev/null || true)
[ -n "$TASK_ID" ] || die "SONAR_CE_TASK_ID is empty - did the SonarScan action run?"
TIMEOUT="${SONAR_GATE_TIMEOUT:-300}"

say "1. Wait for SonarQube to process task $TASK_ID (max ${TIMEOUT}s)"
start=$(date +%s)
while :; do
  task=$(sonar_api "ce/task?id=$TASK_ID")
  status=$(echo "$task" | jfield task.status)
  echo "  task status: $status"
  case "$status" in
    SUCCESS) break ;;
    FAILED|CANCELED) die "SonarQube could not process the analysis: $(echo "$task" | jfield task.errorMessage)" ;;
  esac
  [ $(( $(date +%s) - start )) -lt "$TIMEOUT" ] || die "timed out waiting for SonarQube"
  sleep 5
done
ANALYSIS_ID=$(echo "$task" | jfield task.analysisId)
PROJECT=$(echo "$task" | jfield task.componentKey)

say "2. Quality gate for analysis $ANALYSIS_ID"
gate=$(sonar_api "qualitygates/project_status?analysisId=$ANALYSIS_ID")
GATE_STATUS=$(echo "$gate" | jfield projectStatus.status)

# Print every condition: metric, actual value, threshold, result.
echo "$gate" | node -e '
  let s=""; process.stdin.on("data",c=>s+=c).on("end",()=>{
    const rows = JSON.parse(s).projectStatus.conditions || [];
    console.log("  " + "METRIC".padEnd(40) + "ACTUAL".padEnd(10) + "THRESHOLD".padEnd(14) + "RESULT");
    for (const c of rows)
      console.log("  " + c.metricKey.padEnd(40) + String(c.actualValue ?? "-").padEnd(10) +
                  (c.comparator + " " + c.errorThreshold).padEnd(14) + c.status);
  });'

echo
echo "Dashboard: $SONAR_HOST_URL/dashboard?id=$PROJECT"
case "$GATE_STATUS" in
  OK)   echo "Quality gate PASSED" ;;
  NONE) die "no quality gate is assigned to project $PROJECT" ;;
  *)    die "Quality gate FAILED ($GATE_STATUS) - see the conditions above" ;;
esac
