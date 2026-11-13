# Shared helpers for the stage scripts - sourced, not run directly.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."     # repo root

# Local runs: pick up pipeline/local.env (gitignored) for SONAR_HOST_URL etc.
# shellcheck disable=SC1091
if [ -z "${CODEBUILD_BUILD_ID:-}" ] && [ -f pipeline/local.env ]; then source pipeline/local.env; fi

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
need() { for t in "$@"; do command -v "$t" >/dev/null || die "'$t' not found on PATH"; done; }

# Hand a value to the next pipeline action (see buildspec.yml exported-variables).
# In GitHub Actions it also becomes a step output (steps.<id>.outputs.<KEY>).
output() {
  echo "$1=$2" >> .pipeline-outputs.env
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi
}

# Read one field from JSON on stdin without jq:  echo "$json" | jfield task.status
jfield() {
  node -e '
    let s = ""; process.stdin.on("data", c => s += c).on("end", () => {
      let v = JSON.parse(s);
      for (const k of process.argv[1].split(".")) v = v == null ? v : v[k];
      process.stdout.write(v == null ? "" : typeof v === "object" ? JSON.stringify(v) : String(v));
    });' "$1"
}

# SonarQube Web API call (token as basic-auth user, empty password).
sonar_api() { curl -fsS -u "${SONAR_TOKEN:?}:" "${SONAR_HOST_URL:?}/api/$1"; }
