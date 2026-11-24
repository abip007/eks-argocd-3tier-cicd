# BMI Health Tracker: CI/CD, security scanning and observability on EKS + Argo CD

A self-contained EKS + Argo CD platform with a **CI/CD pipeline** (unit tests, SonarQube
quality gate, Trivy, smoke tests) in front of the GitOps deployment, and an **observability
stack** (Prometheus, Alertmanager, Grafana, Loki, Alloy) that watches the app and every release.
The Terraform path builds all of it in one apply. A `git push` to `app/` starts AWS CodePipeline:

```
git push (app/**, tests/**, pipeline/**)
   │
   ▼
┌────────┐  ┌───────────┐  ┌──────────────────────────┐  ┌──────────────────┐  ┌────────────┐
│ Source │─►│   Test    │─►│       CodeQuality        │─►│      Build       │─►│   Verify   │
│ GitHub │  │ UnitTests │  │ SonarScan ─► QualityGate │  │    BuildPush     │  │ SmokeTest  │
│        │  │           │  │ SecurityScan (Trivy)     │  │                  │  │            │
└────────┘  └───────────┘  └──────────────────────────┘  └──────────────────┘  └────────────┘
             Jest + Vitest   SonarQube analysis +      docker build, Trivy  wait until the
             coverage ≥ 80%  gate; Trivy: CVEs in      image scan, push to  live app reports
             (fails below)   deps, secrets, IaC        ECR, commit new      the new version,
                                                       tag to gitops/ ──┐   then 7 HTTP checks
                             Argo CD (in bmi-cicd-eks) ◄────────────────┘   against the public URL
                             syncs gitops/bmi-cicd → namespace bmi-cicd
                                    │ /metrics, JSON logs
                                    ▼
                  Prometheus ─► Alertmanager      Alloy ─► Loki
                        └──────► Grafana ◄───────────────┘   https://grafana-cicd.bestclick.click
```

Every stage can stop a release. Failing tests, coverage under 80%, a red quality gate or a
Trivy finding mean no image is built, and an image with a fixable HIGH/CRITICAL CVE is never pushed. If the smoke test fails, the pipeline goes red and the
team knows the release is broken. To roll back, `git revert` the release commit.

| What | Where |
| --- | --- |
| App (backend Express + pg, frontend React/Vite on nginx) | `app/` |
| **Unit tests (new)**: backend Jest + Supertest (41 tests), frontend Vitest + Testing Library (24 tests) | `app/backend/tests/`, `app/frontend/tests/` |
| **Smoke tests (new)**: curl checks against the live URL | `tests/smoke/smoke.sh` |
| Pipeline definition: one buildspec + one bash script per stage | `pipeline/` |
| SonarQube analysis settings | `sonar-project.properties` |
| **Security scan (Trivy)**: dependency CVEs, secrets, IaC misconfig, image CVEs | `pipeline/stages/security-scan.sh`, `.trivyignore` |
| SonarQube server bootstrap (EC2 user data) and one-time setup | `sonarqube/` |
| Kubernetes manifests Argo CD deploys | `gitops/bmi-cicd/` (app), `gitops/argocd/root-app.yaml` + `gitops/argocd/apps/` (app-of-apps) |
| **Observability**: chart values, BMI dashboard, alert rules | `gitops/observability/`, backend `/metrics` + JSON logs in `app/backend/src/app.js` |
| Terraform for everything above | `terraform/` |
| JSON templates for the command-line path | `cli/` |

## What gets created

| Resource | Name | Notes |
| --- | --- | --- |
| CodePipeline (V2, QUEUED mode) | `bmi-cicd` | Trigger: push to `main` touching `app/**`, `pipeline/**`, `tests/**`, `sonar-project.properties` |
| CodeBuild project | `bmi-cicd` | One project for all 6 actions; the action's `STAGE` env var picks the script |
| CodeConnections GitHub connection | `bmi-cicd-github` | Must be approved once in the console |
| S3 bucket | `bmi-cicd-artifacts-<account>-<region>` | Pipeline artifacts, 30-day expiry |
| ECR repositories | `bmi-cicd-backend`, `bmi-cicd-frontend` | Immutable tags, scan on push |
| Secrets Manager secret | `bmi-cicd/ci` | `{"github_token": ..., "sonar_token": ...}` |
| EC2 + Elastic IP + SG | `bmi-cicd-sonarqube` | SonarQube Community + PostgreSQL in Docker, port 9000 open only to you and CodeBuild |
| IAM roles | `bmi-cicd-codebuild`, `bmi-cicd-codepipeline`, `bmi-cicd-sonarqube-ec2` | Least privilege, scoped to the resources above |
| VPC + EKS cluster (Terraform path) | `bmi-cicd-eks`, VPC `10.2.0.0/16`, 2 × m7i-flex.large nodes | One NAT gateway, add-ons, Pod Identity roles |
| Platform in the cluster (Terraform path) | LB Controller, ExternalDNS, Argo CD (`https://argocd-cicd.bestclick.click`) | App and Argo CD UI share one ALB (`group.name: shared`) |
| App in the cluster | namespace `bmi-cicd`, 2 secrets, Argo CD `root` app → `bmi-cicd` | |
| Observability (Argo CD apps) | namespace `observability`: kube-prometheus-stack (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics), Loki, Alloy, BMI dashboard + alerts | Grafana at `https://grafana-cicd.bestclick.click`; EBS volumes: Prometheus 20 GiB, Loki 10 GiB, Alertmanager 2 GiB |
| Public URL | `https://cicd-bmi.bestclick.click` | ExternalDNS creates the record; the existing wildcard ACM cert covers it |

Nothing here depends on the eks-argocd-3tier project. Its names (`argo-eks`, `argocd.bestclick.click`,
`10.1.0.0/16`) are different, so both can exist in one account.

## Prerequisites

1. A **Route 53 public hosted zone** (`bestclick.click`) and an **ISSUED ACM certificate** for
   `bestclick.click` + `*.bestclick.click` in the region. Terraform looks both up, it doesn't create them.
   Every path creates the cluster, Argo CD and the rest itself.
   Only **one** public hosted zone for the domain, please: with duplicates, ExternalDNS may
   write records into a zone nobody queries (or pin it with `external_dns_zone_id`).
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
4. Tools on your PC: AWS CLI v2, kubectl, Git Bash, plus Terraform ≥ 1.6 (Terraform path) or
   eksctl + Helm 3 (CLI path). The console path needs nothing: it uses CloudShell.
   Docker is only needed to run the stage scripts locally.

### Your values

These values are in the files. Change them if yours differ:

| Value | Default | Files |
| --- | --- | --- |
| Region / profile | `ap-south-1` / `abip007home` | `cli/config.env`, `terraform/terraform.tfvars` |
| Account ID | `014882039467` | `eksctl/cluster.yaml` (policy ARNs), overlay `kustomization.yaml` (cert ARN) |
| Cluster / VPC | `bmi-cicd-eks` / `10.2.0.0/16` | `cli/config.env`, `eksctl/cluster.yaml`, tfvars |
| Argo CD host | `argocd-cicd.bestclick.click` | `platform/argocd-values.yaml`, `cli/config.env`, tfvars |
| Grafana host + certificate | `grafana-cicd.bestclick.click` | `gitops/observability/kube-prometheus-stack-values.yaml` (3×), tfvars `grafana_host` |
| Route 53 zone ID (only with duplicate zones) | `Z070283435VR70B93SKIX` | `platform/external-dns-values.yaml`, tfvars `external_dns_zone_id` |
| App host | `cicd-bmi.bestclick.click` | `gitops/bmi-cicd/overlays/prod/kustomization.yaml` (2×), `cli/config.env`, tfvars |
| ACM certificate ARN | wildcard cert of `bestclick.click` | overlay `kustomization.yaml`, `platform/argocd-values.yaml` (Terraform looks it up) |
| GitHub repo | `abip007/eks-argocd-3tier-cicd` | `gitops/argocd/root-app.yaml` + `apps/*.yaml`, `cli/config.env`, tfvars |
| Image tags | written by every pipeline run | overlay `kustomization.yaml` (`ImagePullBackOff` on a fresh account until the first BuildPush) |

## Three ways to build it (pick one)

| Path | Guide |
| --- | --- |
| AWS Console, click by click (+ CloudShell for Helm/kubectl) | [docs/01-console-guide.md](docs/01-console-guide.md) |
| AWS CLI + eksctl + Helm, one command at a time | [docs/02-command-line-guide.md](docs/02-command-line-guide.md) |
| Terraform, one apply | [docs/03-terraform-guide.md](docs/03-terraform-guide.md) |
| GitHub Actions instead of CodePipeline (after one of the above) | [docs/04-github-actions-guide.md](docs/04-github-actions-guide.md) |

Each path builds **everything**: VPC + EKS cluster, LB Controller, ExternalDNS, Argo CD, the app,
SonarQube, and the pipeline with unit tests, SonarQube, Trivy and smoke tests. All three use the
same names (`bmi-cicd-*`), so **don't mix paths in one account**.
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

**Security scan (Trivy).** Two layers, both with Trivy pinned to one version and SHA-256 in
`pipeline/stages/lib.sh`:

| Layer | Where | Scans | Fails on |
| --- | --- | --- | --- |
| Repo | `SecurityScan` action (parallel to SonarScan), `security-scan.sh` | `package-lock.json` CVEs, committed secrets, Dockerfiles / `gitops/` manifests / Terraform | any secret; HIGH/CRITICAL CVE that has a fix |
| Image | `BuildPush`, before `docker push` | OS packages + node modules inside each built image | HIGH/CRITICAL CVE that has a fix (image not pushed) |

Misconfigurations are printed but don't fail the build until you set `TRIVY_MISCONFIG_GATE=true`
on the action. `TRIVY_SEVERITY` (default `HIGH,CRITICAL`) changes the threshold. To accept a
finding, add its ID to `.trivyignore` with the reason and a review date. CodeBuild shows the
results under **Reports** (`security-scan`).

**Observability.** The backend serves `/metrics` (prom-client: request histogram per route and
status code, Node.js runtime, and `bmi_app_info{version}` = the live image tag) and writes one
JSON log line per request. Argo CD deploys the stack from `gitops/argocd/apps/`:

| Piece | Job |
| --- | --- |
| Prometheus | scrapes the backend (ServiceMonitor), Argo CD, Loki, Alloy, nodes and Kubernetes objects; 7-day retention |
| Alertmanager | receives the alerts; no receiver yet (add Slack/email in `kube-prometheus-stack-values.yaml`) |
| Grafana | dashboard **BMI → BMI app (CI/CD)**: live version, Argo CD sync/health, pods per version, request rate, 5xx ratio, latency percentiles, CPU/memory, Postgres volume, logs. Plus the chart's Kubernetes dashboards and Explore |
| Loki + Alloy | every pod's logs and Kubernetes events, 7-day retention; `{namespace="bmi-cicd", app="bmi-backend"} \| json \| status >= 500` |
| Alert rules (`gitops/observability/extras/bmi-alerts.yaml`) | backend down, 5xx > 5%, p95 > 1 s, Postgres volume < 15% free, Argo CD app out of sync / unhealthy, pods stuck on two versions |

The pipeline and the stack meet at the version: BuildPush writes the image tag into `gitops/`,
the backend reports it as `bmi_app_info`, and the dashboard's **Live version** panel flips to it
when the rollout is done. A release that never lands raises `BmiArgoAppOutOfSync` or `BmiMixedVersions`.

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
bash pipeline/stages/security-scan.sh               # Trivy (Linux/WSL; downloads a pinned Trivy)
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
| EKS control plane | ~$0.10/h |
| 2 × m7i-flex.large nodes | ~$0.20/h together (free-plan eligible) |
| NAT gateway | ~$0.056/h + data |
| ALB (shared by the app, Argo CD and Grafana) | ~$0.025/h + LCU |
| Observability volumes (32 GiB gp3) | ~$2.60/month; the stack itself runs on the existing nodes |

## Tear down

Use the path you built with: Terraform `terraform destroy`, or the *Clean up* section of the
console or CLI guide. Delete the Argo CD **root** app, the observability volumes and the
Ingresses **first** (Terraform's teardown step does this), so the ALB and every EBS volume go
away cleanly instead of being left behind.
