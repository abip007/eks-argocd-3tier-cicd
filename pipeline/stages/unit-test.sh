#!/usr/bin/env bash
# Stage: UnitTests. Runs both test suites with coverage. Fails when a test fails
# or when coverage drops under 80% (thresholds in app/backend/package.json and
# app/frontend/vite.config.js). Writes coverage/lcov.info for SonarQube.
source "$(dirname "$0")/lib.sh"
need node npm

for app in backend frontend; do
  say "Unit tests + coverage: app/$app"
  (cd "app/$app" && npm ci --no-audit --no-fund && npm run test:ci)
done

say "Coverage summary"
for app in backend frontend; do
  printf '%-9s ' "$app"; grep -o 'line-rate="[0-9.]*"' "app/$app/coverage/cobertura-coverage.xml" | head -1
done
