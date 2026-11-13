#!/usr/bin/env bash
# Stage: BuildPush. Only runs after the quality gate passed.
#  1. docker build + push both images to ECR with a unique tag
#  2. write that tag into gitops/bmi-cicd/overlays/prod/kustomization.yaml and
#     push the commit -> Argo CD deploys it (nobody runs kubectl)
# The commit only touches gitops/, which is not in the pipeline's trigger paths,
# so it does not start the pipeline again.
source "$(dirname "$0")/lib.sh"
need aws docker git sed
: "${GITHUB_REPO:?e.g. abip007/eks-argocd-3tier-cicd}" "${GITHUB_TOKEN:?}"
: "${AWS_REGION:=${AWS_DEFAULT_REGION:?set AWS_REGION}}"
ECR_PREFIX="${ECR_PREFIX:-bmi-cicd}"
GIT_BRANCH="${GIT_BRANCH:-main}"
OVERLAY=gitops/bmi-cicd/overlays/prod/kustomization.yaml

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"
COMMIT="${COMMIT_ID:-$(git rev-parse HEAD 2>/dev/null || echo manual000)}"
TAG="${COMMIT:0:7}-${CODEBUILD_BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"

say "1. Build and push images ($TAG)"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"
for c in backend frontend; do
  docker build --platform linux/amd64 -t "$REGISTRY/$ECR_PREFIX-$c:$TAG" "app/$c"
  docker push "$REGISTRY/$ECR_PREFIX-$c:$TAG"
done

say "2. Bump image tag in Git ($GITHUB_REPO@$GIT_BRANCH)"
# The pipeline source is a zip without .git, so clone the branch fresh.
WORK=$(mktemp -d)
git clone --quiet --depth 20 --branch "$GIT_BRANCH" \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git" "$WORK/repo"
cd "$WORK/repo"
for c in backend frontend; do
  # Only the lines between '- name: bmi-<c>' and its 'newTag:' line.
  sed -i -E "/- name: bmi-$c\$/,/newTag:/ {
    s|^(\s*newName:).*|\1 $REGISTRY/$ECR_PREFIX-$c|
    s|^(\s*newTag:).*|\1 $TAG|
  }" "$OVERLAY"
done
sed -i -E "s|^(\s*value:).*(# app-version)\$|\1 \"$TAG\"  \2|" "$OVERLAY"
git --no-pager diff --stat
grep -nE 'newName:|newTag:|app-version' "$OVERLAY"

git -c user.name="bmi-cicd pipeline" -c user.email="pipeline@noreply.local" \
  commit -qam "release: bmi-cicd images $TAG"
for attempt in 1 2 3; do
  git push -q origin "HEAD:$GIT_BRANCH" && break
  [ "$attempt" = 3 ] && die "git push failed 3 times"
  echo "push rejected (someone pushed meanwhile) - rebasing and retrying"
  git pull -q --rebase origin "$GIT_BRANCH"
done
echo "Pushed $(git rev-parse --short HEAD). Argo CD will sync it."
cd - >/dev/null && rm -rf "$WORK"

output IMAGE_TAG "$TAG"
