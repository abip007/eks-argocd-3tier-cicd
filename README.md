# BMI Health Tracker: CI/CD pipeline with SonarQube, quality gate and smoke tests

A self-contained EKS + Argo CD platform with a **CI/CD pipeline** in front of the GitOps
deployment. The Terraform path builds everything (VPC, EKS cluster, controllers, Argo CD,
SonarQube, pipeline) in one apply. A `git push` to `app/` starts AWS CodePipeline:

```
git push (app/**, tests/**, pipeline/**)
   │
   ▼
┌────────┐  ┌───────────┐  ┌──────────────────────────┐  ┌──────────────────┐  ┌────────────┐
│ Source │─►│   Test    │─►│       CodeQuality        │─►│      Build       │─►│   Verify   │
│ GitHub │  │ UnitTests │  │ SonarScan ─► QualityGate │  │    BuildPush     │  │ SmokeTest  │
└────────┘  └───────────┘  └──────────────────────────┘  └──────────────────┘  └────────────┘
             Jest + Vitest   upload analysis   wait for     docker build/push    wait until the
             coverage ≥ 80%  + coverage to     SonarQube,   to ECR, commit new   live app reports
             (fails below)   SonarQube         fail if red  tag to gitops/ ──┐   the new version,
                                                                              │   then 7 HTTP checks
                             Argo CD (in bmi-cicd-eks)           ◄──────────┘   against the public URL
                             syncs gitops/bmi-cicd → namespace bmi-cicd
```

Every stage can stop a release. Failing tests, coverage under 80% or a red quality gate
mean no image is built. If the smoke test fails, the pipeline goes red and the
team knows the release is broken. To roll back, `git revert` the release commit.

| What | Where |
| --- | --- |
| App (backend Express + pg, frontend React/Vite on nginx) | `app/` |
| **Unit tests (new)**: backend Jest + Supertest (34 tests), frontend Vitest + Testing Library (24 tests) | `app/backend/tests/`, `app/frontend/tests/` |
| **Smoke tests (new)**: curl checks against the live URL | `tests/smoke/smoke.sh` |
| Pipeline definition: one buildspec + one bash script per stage | `pipeline/` |
| SonarQube analysis settings | `sonar-project.properties` |
| SonarQube server bootstrap (EC2 user data) and one-time setup | `sonarqube/` |
| Kubernetes manifests Argo CD deploys | `gitops/bmi-cicd/`, `gitops/argocd/bmi-cicd-app.yaml` |
| Terraform for everything above | `terraform/` |
| JSON templates for the command-line path | `cli/` |

## What gets created

| Resource | Name | Notes |
| --- | --- | --- |
| CodePipeline (V2, QUEUED mode) | `bmi-cicd` | Trigger: push to `main` touching `app/**`, `pipeline/**`, `tests/**`, `sonar-project.properties` |
| CodeBuild project | `bmi-cicd` | One project for all 5 actions; the action's `STAGE` env var picks the script |
| CodeConnections GitHub connection | `bmi-cicd-github` | Must be approved once in the console |
| S3 bucket | `bmi-cicd-artifacts-<account>-<region>` | Pipeline artifacts, 30-day expiry |
| ECR repositories | `bmi-cicd-backend`, `bmi-cicd-frontend` | Immutable tags, scan on push |
| Secrets Manager secret | `bmi-cicd/ci` | `{"github_token": ..., "sonar_token": ...}` |
| EC2 + Elastic IP + SG | `bmi-cicd-sonarqube` | SonarQube Community + PostgreSQL in Docker, port 9000 open only to you and CodeBuild |
| IAM roles | `bmi-cicd-codebuild`, `bmi-cicd-codepipeline`, `bmi-cicd-sonarqube-ec2` | Least privilege, scoped to the resources above |
| VPC + EKS cluster (Terraform path) | `bmi-cicd-eks`, VPC `10.2.0.0/16`, 2 × m7i-flex.large nodes | One NAT gateway, add-ons, Pod Identity roles |
| Platform in the cluster (Terraform path) | LB Controller, ExternalDNS, Argo CD (`https://argocd-cicd.bestclick.click`) | App and Argo CD UI share one ALB (`group.name: shared`) |
| App in the cluster | namespace `bmi-cicd`, 2 secrets, Argo CD app `bmi-cicd` | |
| Public URL | `https://cicd-bmi.bestclick.click` | ExternalDNS creates the record; the existing wildcard ACM cert covers it |

Nothing here depends on the eks-argocd-3tier project. Its names (`argo-eks`, `argocd.bestclick.click`,
`10.1.0.0/16`) are different, so both can exist in one account.

## Prerequisites

1. A **Route 53 public hosted zone** (`bestclick.click`) and an **ISSUED ACM certificate** for
   `bestclick.click` + `*.bestclick.click` in the region. Terraform looks both up, it doesn't create them.
   The console and CLI guides still expect a cluster with Argo CD, the LB Controller and
   ExternalDNS to exist already; the Terraform path creates it.
2. A GitHub repo for this project: `abip007/eks-argocd-3tier-cicd`, **public**, because Argo CD
   reads it without credentials.
   ```bash
   cd E:/devops/eks-argocd-3tier-cicd
   git init -b main && git add -A && git commit -m "Initial import"
   git remote add origin https://github.com/abip007/eks-argocd-3tier-cicd.git
   git push -u origin main
   ```
3. A **fine-grained GitHub token**: GitHub → Settings → Developer settings → Fine-grained tokens →
   *Generate new token* → Repository access: *Only select repositories* →
   `eks-argocd-3tier-cicd` → Permissions → **Contents: Read and write**. The BuildPush stage uses it
   to commit the new image tag.
4. Tools on your PC: AWS CLI v2, kubectl, Git Bash, and Terraform ≥ 1.6 for the Terraform path
   (Terraform runs `aws` and `kubectl` itself, so both must be on PATH).
   Docker is only needed to run the stage scripts locally.

### Your values

These values are in the files. Change them if yours differ:

| Value | Default | Files |
| --- | --- | --- |
| Region / profile | `ap-south-1` / `abip007` | `cli/config.env`, `terraform/terraform.tfvars` |
| App host | `cicd-bmi.bestclick.click` | `gitops/bmi-cicd/overlays/prod/kustomization.yaml` (2×), `cli/config.env`, tfvars |
| ACM certificate ARN | wildcard cert of `bestclick.click` | overlay `kustomization.yaml` |
| GitHub repo | `abip007/eks-argocd-3tier-cicd` | `gitops/argocd/bmi-cicd-app.yaml`, `cli/config.env`, tfvars |
| Initial images | last `bmi-app` release | overlay `kustomization.yaml` (replaced by the first pipeline run) |

## Three ways to build it (pick one)

| Path | Guide |
| --- | --- |
| AWS Console, click by click | [docs/01-console-guide.md](docs/01-console-guide.md) |
| AWS CLI, one command at a time | [docs/02-command-line-guide.md](docs/02-command-line-guide.md) |
| Terraform | [docs/03-terraform-guide.md](docs/03-terraform-guide.md) |
| GitHub Actions instead of CodePipeline (after one of the above) | [docs/04-github-actions-guide.md](docs/04-github-actions-guide.md) |

All three use the same names (`bmi-cicd-*`), so **don't mix paths in one account**.
Every path has one manual click: approving the GitHub connection in the console.

## How each quality check works

**Code coverage.** `npm run test:ci` in each app runs the tests with coverage. The build fails
when statements, branches, functions or lines drop below **80%**. The thresholds are in
`app/backend/package.json` (`jest.coverageThreshold`) and `app/frontend/vite.config.js`
(`test.coverage.thresholds`). Today the coverage is 100% of lines in both apps. CodeBuild shows the
JUnit results and Cobertura coverage under **Reports**.

**SonarQube.** `pipeline/stages/sonar-scan.sh` runs the tests again to produce `lcov.info`,
rewrites the paths so they're relative to the repo root, and runs `@sonar/scan`. It writes the
background-task ID to an exported variable. It doesn't wait for the result.

**Quality gate.** `pipeline/stages/quality-gate.sh` polls `api/ce/task` until SonarQube has
processed that exact analysis, then reads `api/qualitygates/project_status`. If the gate isn't
`OK`, the action fails and prints every condition. The gate `bmi-cicd-gate` checks:

| Condition | Scope | Fails when |
| --- | --- | --- |
| Coverage | new code / whole code | < 80% |
| Duplicated lines | new code / whole code | > 3% |
| New issues | new code | > 0 |
| Security hotspots reviewed | new code | < 100% |
| Reliability / Security / Maintainability rating | whole code | worse than A |

**Smoke test.** Argo CD deploys on its own schedule, so `smoke-test.sh` first polls
`GET /api/health` until the live `version` equals the pipeline's `IMAGE_TAG` (max 15 min). The
build writes that tag into the backend ConfigMap as `APP_VERSION`. Then `tests/smoke/smoke.sh`
checks:
the frontend loads, `/api/health` reports the database up, HTTP redirects to HTTPS, creating a
measurement returns BMI 22.9 / BMR 1649, invalid input returns 400, the list and trends endpoints
work, and an unknown route returns 404. Each run adds one real measurement.

### Proving the gates work

```bash
# 1. Coverage gate: delete a test file, push, watch UnitTests fail under 80%
git rm app/backend/tests/app.test.js && git commit -m "test: drop tests" && git push
git revert --no-edit HEAD && git push

# 2. Quality gate: add a bug that tests don't catch but SonarQube does. At the end of
#    app/backend/src/calculations.js add:
#      function isMissing(v) { return v === NaN; }   // always false (rule S2688)
#    UnitTests passes (coverage stays > 80%); QualityGate fails on
#    new_violations, reliability rating and new_coverage. Revert to go green again.
```

## Running the stages on your PC

The stage scripts are plain bash. You need Node 20 for tests, or run them in Docker:

```bash
cp pipeline/local.env.example pipeline/local.env     # fill in SONAR_HOST_URL, SONAR_TOKEN, ...
bash pipeline/stages/unit-test.sh
bash pipeline/stages/sonar-scan.sh && bash pipeline/stages/quality-gate.sh
bash tests/smoke/smoke.sh https://cicd-bmi.bestclick.click

# without Node installed:
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W)":/repo -w /repo node:20 bash pipeline/stages/unit-test.sh
```

## Cost (ap-south-1, roughly)

| Item | Cost |
| --- | --- |
| SonarQube EC2 m7i-flex.large + 30 GB gp3 | ~$0.10/h running. Free-plan eligible; **stop the instance when you're not using it** (the Elastic IP keeps the URL) |
| Elastic IP | ~$0.005/h |
| CodePipeline V2 | $0.002 per action-minute (~$0.02 per run) |
| CodeBuild small | 100 free minutes/month, then ~$0.005/min (~8 min per run) |
| ALB | none extra, it joins the existing shared ALB |

## Tear down

Use the path you built with: Terraform `terraform destroy`, or the *Clean up* section of the
console or CLI guide. Delete the Argo CD application **first**, so the Ingress rule and the EBS
volume go away cleanly.
