#!/usr/bin/env bash
# Stage: SmokeTest. Argo CD deploys asynchronously, so first wait until the live
# app reports the version this pipeline built (GET /api/health -> "version"),
# then run tests/smoke/smoke.sh against the public URL.
# Input: IMAGE_TAG (= #{Build.IMAGE_TAG}), APP_URL (CodeBuild env var).
source "$(dirname "$0")/lib.sh"
need curl
: "${APP_URL:?e.g. https://cicd-bmi.bestclick.click}"
WAIT="${SMOKE_WAIT_SECONDS:-900}"

if [ -n "${IMAGE_TAG:-}" ]; then
  say "1. Wait for Argo CD to roll out $IMAGE_TAG (max ${WAIT}s)"
  start=$(date +%s)
  while :; do
    live=$(curl -fsS --max-time 10 "$APP_URL/api/health" 2>/dev/null | grep -o '"version":"[^"]*"' | cut -d'"' -f4 || true)
    elapsed=$(( $(date +%s) - start ))
    echo "  [${elapsed}s] live version: ${live:-unreachable}"
    [ "$live" = "$IMAGE_TAG" ] && break
    [ "$elapsed" -lt "$WAIT" ] || die "version $IMAGE_TAG not live after ${WAIT}s. Check: kubectl -n argocd get application bmi-cicd; kubectl -n bmi-cicd get pods"
    sleep 15
  done
else
  say "1. IMAGE_TAG not set - testing whatever version is live"
fi

say "2. Smoke tests against $APP_URL"
bash tests/smoke/smoke.sh "$APP_URL"
