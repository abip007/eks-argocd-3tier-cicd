#!/usr/bin/env bash
# Stage: SecurityScan (Trivy). Runs next to SonarScan, before any image is built.
#  1. dependencies: known CVEs in app/*/package-lock.json
#  2. secrets:      keys, tokens, passwords committed to the repo
#  3. misconfig:    Dockerfiles, Kubernetes manifests (gitops/), Terraform
#
# Fails on: any secret, and HIGH/CRITICAL dependency CVEs that have a fix.
# Misconfigurations are reported but don't fail the build unless
# TRIVY_MISCONFIG_GATE=true. Accept a finding with a reason in .trivyignore.
# The images themselves are scanned in build-push.sh, before they're pushed.
source "$(dirname "$0")/lib.sh"
need curl tar sha256sum
SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
mkdir -p reports

say "Install Trivy $TRIVY_VERSION"
install_trivy
COMMON=(--cache-dir .tools/trivy-cache --ignorefile .trivyignore --skip-dirs node_modules --skip-dirs .tools)

say "1+2. Dependency CVEs ($SEVERITY, fixable) and secrets"
rc=0
trivy fs "${COMMON[@]}" --scanners vuln,secret --severity "$SEVERITY" --ignore-unfixed \
  --exit-code 1 . || rc=1

say "3. Misconfigurations: Dockerfiles, Kubernetes, Terraform ($SEVERITY)"
gate=0; [ "${TRIVY_MISCONFIG_GATE:-false}" = true ] && gate=1
trivy config "${COMMON[@]}" --severity "$SEVERITY" --exit-code "$gate" . || rc=1

# JUnit file for CodeBuild > Reports (all three scanners, one file).
if [ -n "${TRIVY_CONTRIB:-}" ] && [ -f "$TRIVY_CONTRIB/junit.tpl" ]; then
  trivy fs "${COMMON[@]}" --scanners vuln,secret,misconfig --severity "$SEVERITY" --ignore-unfixed \
    --quiet --format template --template "@$TRIVY_CONTRIB/junit.tpl" -o reports/trivy-junit.xml . || true
fi

[ "$rc" = 0 ] || die "Trivy found blocking issues (see above). Fix them, or accept one in .trivyignore with a reason."
echo "No blocking findings."
