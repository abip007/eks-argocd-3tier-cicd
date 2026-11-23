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

# Install a pinned Trivy release into .tools/ unless it's already on PATH.
# Version + SHA-256 are fixed here on purpose: a moved tag or tampered release
# asset fails the checksum instead of running in the pipeline. To upgrade, take
# both values from trivy_<ver>_checksums.txt of a release at least 2 weeks old.
TRIVY_VERSION="${TRIVY_VERSION:-0.76.2}"
TRIVY_SHA256="${TRIVY_SHA256:-bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf}"
install_trivy() {
  if command -v trivy >/dev/null; then TRIVY_CONTRIB=""; trivy --version | head -1; return; fi
  local dir=.tools/trivy-$TRIVY_VERSION tgz
  tgz="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
  if [ ! -x "$dir/trivy" ]; then
    mkdir -p "$dir"
    curl -fsSL -o "$dir/$tgz" "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/$tgz"
    echo "$TRIVY_SHA256  $dir/$tgz" | sha256sum -c - >/dev/null || die "Trivy download failed its SHA-256 check"
    tar -xzf "$dir/$tgz" -C "$dir" && rm -f "$dir/$tgz"
  fi
  export PATH="$PWD/$dir:$PATH"
  TRIVY_CONTRIB="$PWD/$dir/contrib"   # junit.tpl for CodeBuild test reports
  trivy --version | head -1
}

# SonarQube Web API call (token as basic-auth user, empty password).
sonar_api() { curl -fsS -u "${SONAR_TOKEN:?}:" "${SONAR_HOST_URL:?}/api/$1"; }
