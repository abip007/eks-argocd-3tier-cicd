# GitHub Actions pipeline

`.github/workflows/ci-cd.yml` runs the same stages as CodePipeline (unit tests, SonarQube,
Trivy, build, smoke test), using the same scripts in
`pipeline/stages/`. Use it **instead of** CodePipeline, not alongside it. If both run, each one
builds and commits its own release for the same push.

```
push to main (app/**, pipeline/**, tests/**, sonar-project.properties, the workflow)
   │
   ▼
┌────────────┐   ┌──────────────────────────┐   ┌──────────────────────┐   ┌────────────┐
│ unit-tests │──►│       code-quality       │──►│      build-push      │──►│ smoke-test │
│ coverage   │   │ sonar-scan + quality-gate│ ┌►│ Trivy image scan,    │   │ live URL   │
└────────────┘   └──────────────────────────┘ │ │ ECR + gitops tag bump│   └────────────┘
 also on PRs       main only (needs AWS)      │ └──────────────────────┘    main only
┌───────────────┐                             │      main only
│ security-scan │─────────────────────────────┘
│ Trivy fs      │  also on PRs (no AWS needed)
└───────────────┘
```

| | CodePipeline | GitHub Actions |
| --- | --- | --- |
| AWS credentials | CodeBuild service role | OIDC role `bmi-cicd-github-actions` (no keys stored in GitHub) |
| `SONAR_TOKEN` | Secrets Manager `bmi-cicd/ci` | same secret, read by the job |
| Release commit to `gitops/` | PAT in `bmi-cicd/ci:github_token` | built-in `GITHUB_TOKEN` (or the `GITOPS_TOKEN` secret) |
| Reaching SonarQube | SG allows CodeBuild IP ranges | job adds its runner IP to the SG, removes it at the end |
| Trivy | `SecurityScan` action + image scan in BuildPush | `security-scan` job + the same image scan in `build-push` |
| Reports | CodeBuild Reports | run summary + `unit-test-reports` / `trivy-report` / `smoke-test-report` artifacts |

## Prerequisites

The Terraform, CLI or console guide is done: the EKS cluster with Argo CD, ECR repos, the
`bmi-cicd/ci` secret with a `sonar_token`, the SonarQube server and the Argo CD app all exist.

## 1. Create the AWS role

**Terraform** (`terraform/github-actions.tf`):

```bash
cd terraform
# If the account already has a GitHub OIDC provider, reuse it:
#   export TF_VAR_github_oidc_provider_arn=arn:aws:iam::<account>:oidc-provider/token.actions.githubusercontent.com
terraform apply
terraform output github_actions_variables
```

**AWS CLI** (if you didn't use Terraform):

```bash
source cli/config.env
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$NAME-sonarqube --query 'SecurityGroups[0].GroupId' --output text)

# Skip this if the provider already exists (aws iam list-open-id-connect-providers)
aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com

aws iam create-role --role-name $NAME-github-actions --assume-role-policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",
  \"Principal\":{\"Federated\":\"arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com\"},
  \"Action\":\"sts:AssumeRoleWithWebIdentity\",
  \"Condition\":{\"StringEquals\":{
    \"token.actions.githubusercontent.com:aud\":\"sts.amazonaws.com\",
    \"token.actions.githubusercontent.com:sub\":\"repo:$GITHUB_REPO:ref:refs/heads/$GIT_BRANCH\"}}}]}"

aws iam put-role-policy --role-name $NAME-github-actions --policy-name $NAME-github-actions --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
  {\"Effect\":\"Allow\",\"Action\":\"ecr:GetAuthorizationToken\",\"Resource\":\"*\"},
  {\"Effect\":\"Allow\",\"Action\":[\"ecr:BatchCheckLayerAvailability\",\"ecr:BatchGetImage\",\"ecr:GetDownloadUrlForLayer\",
     \"ecr:InitiateLayerUpload\",\"ecr:UploadLayerPart\",\"ecr:CompleteLayerUpload\",\"ecr:PutImage\"],
   \"Resource\":[\"arn:aws:ecr:$AWS_REGION:$ACCOUNT_ID:repository/$NAME-backend\",\"arn:aws:ecr:$AWS_REGION:$ACCOUNT_ID:repository/$NAME-frontend\"]},
  {\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"arn:aws:secretsmanager:$AWS_REGION:$ACCOUNT_ID:secret:$NAME/ci-*\"},
  {\"Effect\":\"Allow\",\"Action\":[\"ec2:AuthorizeSecurityGroupIngress\",\"ec2:RevokeSecurityGroupIngress\"],
   \"Resource\":\"arn:aws:ec2:$AWS_REGION:$ACCOUNT_ID:security-group/$SG_ID\"}]}"

echo "AWS_ROLE_ARN=arn:aws:iam::$ACCOUNT_ID:role/$NAME-github-actions  SONARQUBE_SG_ID=$SG_ID"
```

## 2. Set the GitHub repo variables

GitHub → repo → **Settings → Secrets and variables → Actions → Variables**:

| Variable | Example |
| --- | --- |
| `AWS_ROLE_ARN` | `arn:aws:iam::014882039467:role/bmi-cicd-github-actions` |
| `AWS_REGION` | `ap-south-1` |
| `SONAR_HOST_URL` | `http://<sonarqube-elastic-ip>:9000` |
| `SONARQUBE_SG_ID` | `sg-0123...` |
| `APP_URL` | `https://cicd-bmi.bestclick.click` |

Or with the GitHub CLI:

```bash
gh variable set AWS_ROLE_ARN    --body "arn:aws:iam::<account>:role/bmi-cicd-github-actions"
gh variable set AWS_REGION      --body ap-south-1
gh variable set SONAR_HOST_URL  --body "http://<ip>:9000"
gh variable set SONARQUBE_SG_ID --body sg-xxxxxxxx
gh variable set APP_URL         --body https://cicd-bmi.bestclick.click
```

No secrets are required. The `build-push` job pushes the release commit with the built-in
`GITHUB_TOKEN`. If `main` is branch-protected and rejects that push, add a secret
`GITOPS_TOKEN` (fine-grained PAT, this repo, Contents: Read and write). The workflow uses
it automatically.

## 3. Turn off the CodePipeline trigger

Pick one release path. To keep CodePipeline but stop it from running on push, disable its
trigger in the console (Pipeline → Edit → Edit trigger), or delete the pipeline.

## 4. Run it

Push a change under `app/`, or go to **Actions → ci-cd → Run workflow**. The run summary shows
coverage and the released image tag. Test and coverage reports are attached to the run as
artifacts.

## Notes

- **Pull requests** run `unit-tests` and `security-scan` (Trivy needs no AWS access), so a PR
  that adds a vulnerable dependency or a secret goes red before it's merged. No SonarQube scan on
  PRs: Community Edition has one branch, so a PR scan would overwrite the `main` analysis.
- **Trivy** is downloaded by the stage script at a pinned version and checked against its
  SHA-256 (`pipeline/stages/lib.sh`). No third-party Trivy action is used.
- **Why the SG step:** GitHub-hosted runners use thousands of IP ranges, too many for a security
  group. The job adds its own `/32` (tagged with the run ID) and removes it in an `always()`
  step. If a run is killed hard, a stale `gha-run-*` rule can remain. Delete it in the console.
  A self-hosted runner inside the VPC avoids this step.
- **Re-running** a failed `build-push` is safe: the image tag includes a timestamp, so the
  immutable ECR repos never see the same tag twice.
