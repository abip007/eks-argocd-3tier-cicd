# Build the pipeline from the AWS Console (step by step)

This guide builds the same thing as `terraform/` and [the CLI guide](02-command-line-guide.md),
by clicking. Three small jobs can't be done by clicking: Kubernetes secrets, `kubectl apply`,
and listing CodeBuild's IP ranges. For those, use **AWS CloudShell** (the `>_` icon in the
console's top bar).

**Values used in this guide.** Replace them if yours differ:

| Setting | Value |
| --- | --- |
| Region | `ap-south-1` (Mumbai). Check it top-right **before every step** |
| Name prefix | `bmi-cicd` |
| Existing EKS cluster | `argo-eks` (from eks-argocd-3tier, with Argo CD running) |
| GitHub repo of this project | `abip007/eks-argocd-3tier-cicd` |
| App URL | `https://cicd-bmi.bestclick.click` |
| Account ID | `014882039467` (yours: top-right menu) |

Before you start, finish the [Prerequisites](../README.md#prerequisites): the repo is on GitHub
and you have the fine-grained GitHub token.

---

## Step 1: ECR repositories

**ECR console → Private registry → Repositories → Create repository**, twice:

| Field | Value |
| --- | --- |
| Repository name | `bmi-cicd-backend` (second time: `bmi-cicd-frontend`) |
| Image tag mutability | **Immutable** (a tag in Git always means the same image) |
| Image scanning → Scan on push | on (under *Image scan settings*, or Private registry → Settings → Scanning) |

Optional, per repo: **Lifecycle policy → Create rule** → *Image count more than* `20` → *Expire*.

---

## Step 2: Secret for the pipeline

**Secrets Manager → Store a new secret**

1. **Secret type**: *Other type of secret*
2. **Key/value pairs**:
   | Key | Value |
   | --- | --- |
   | `github_token` | your fine-grained GitHub token (`github_pat_...`) |
   | `sonar_token` | `placeholder` (Step 4 replaces it) |
3. **Secret name**: `bmi-cicd/ci` (exactly this: `pipeline/buildspec.yml` reads it) → *Next* → no rotation → **Store**.

---

## Step 3: SonarQube server (EC2)

### 3.1 Find the CodeBuild IP ranges

CodeBuild calls SonarQube from AWS-owned addresses. Open **CloudShell** and run:

```bash
curl -s https://ip-ranges.amazonaws.com/ip-ranges.json \
  | jq -r '.prefixes[] | select(.service=="CODEBUILD" and .region=="ap-south-1") | .ip_prefix'
curl -s https://checkip.amazonaws.com        # your own IP (run this one on your PC instead)
```

Write down the CIDRs. At the time of writing, ap-south-1 has two: `13.127.70.136/29` and `3.109.72.152/29`.

### 3.2 IAM role for the instance (Session Manager instead of SSH)

**IAM → Roles → Create role** → *AWS service* → **EC2** → *Next* → attach
**AmazonSSMManagedInstanceCore** → name `bmi-cicd-sonarqube-ec2` → **Create role**.

### 3.3 Security group

**EC2 → Security Groups → Create security group**

- Name `bmi-cicd-sonarqube`, VPC: the **default VPC**
- **Inbound rules**: *Custom TCP*, port `9000`, one rule per source:
  - your IP `x.x.x.x/32`, description `admins`
  - each CodeBuild CIDR from 3.1, description `codebuild`
- Outbound: leave *All traffic*. **Create**.

> Don't open 9000 to `0.0.0.0/0`. The token travels over plain HTTP. For production, put
> SonarQube behind an HTTPS load balancer.

### 3.4 Launch the instance

**EC2 → Instances → Launch instances**

| Field | Value |
| --- | --- |
| Name | `bmi-cicd-sonarqube` |
| AMI | **Amazon Linux 2023** (x86_64) |
| Instance type | `m7i-flex.large` (8 GiB). SonarQube needs ≥ 4 GiB |
| Key pair | *Proceed without a key pair* (use Session Manager) |
| Network settings → Edit | default VPC, any subnet, **Auto-assign public IP: Enable**, *Select existing security group*: `bmi-cicd-sonarqube` |
| Storage | `30` GiB **gp3**, *Advanced → Encrypted: Yes* |
| Advanced details → IAM instance profile | `bmi-cicd-sonarqube-ec2` |
| Advanced details → Metadata version | *V2 only (token required)* |
| Advanced details → User data | paste the whole of [`sonarqube/user-data.sh`](../sonarqube/user-data.sh) |

**Launch instance.**

### 3.5 Elastic IP (fixed URL)

**EC2 → Elastic IPs → Allocate Elastic IP address → Allocate.** Then **Actions → Associate** →
instance `bmi-cicd-sonarqube` → **Associate**. Tag it `Name=bmi-cicd-sonarqube`.

Your SonarQube URL is now `http://<elastic-ip>:9000`. Write it down; this guide calls it
**SONAR_HOST_URL**. Startup takes 3–5 minutes. If the page doesn't load after that:
**Connect → Session Manager** → `sudo tail -50 /var/log/cloud-init-output.log; sudo docker logs sonarqube | tail`.

---

## Step 4: Configure SonarQube

> **Shortcut:** all of Step 4 is automated by `sonarqube/setup-sonarqube.sh` (see the CLI guide,
> Step 4). You can run it from CloudShell after `git clone`-ing the repo. The clicks below do
> the same thing.

Open **SONAR_HOST_URL** and log in as `admin` / `admin`. SonarQube asks for a new password
(at least 12 characters with upper case, lower case, a digit and a special character).

### 4.1 Project

**Projects → Create project → Local project**: display name `BMI Health Tracker (CI/CD)`,
**project key `bmi-cicd`**, main branch `main` → *Next* → *Use the global setting* → **Create project**.
Ignore the "how do you want to analyze" page; the pipeline does the analysis.

### 4.2 Quality gate

**Quality Gates → Create** → name `bmi-cicd-gate` → **Create**. The new gate already has
SonarQube's *Clean as You Code* conditions on **new code**: coverage < 80%, duplicated lines
> 3%, hotspots reviewed < 100%, issues > 0. Add these with **Add condition → On Overall Code**:

| Metric | Operator | Value |
| --- | --- | --- |
| Coverage | is less than | `80` |
| Duplicated Lines (%) | is greater than | `3` |
| Reliability Rating | is worse than | `A` |
| Security Rating | is worse than | `A` |
| Maintainability Rating | is worse than | `A` |

Then, on the gate page, open the **Projects** tab → *All* → tick **bmi-cicd**. This assigns the gate to the project.

### 4.3 CI user and token

1. **Administration → Security → Users → Create User**: login `ci-pipeline`, name `CI pipeline`,
   any long password → **Create**.
2. **Projects → bmi-cicd → Project Settings → Permissions** → search `ci-pipeline` → tick
   **Browse** and **Execute Analysis**.
3. **Administration → Security → Users** → `ci-pipeline` row → **Tokens** column (⋯ / *Update tokens*)
   → name `codebuild`, *No expiration* or 1 year → **Generate** → copy the token (`squ_...`).
4. **Secrets Manager → `bmi-cicd/ci` → Retrieve secret value → Edit** → set `sonar_token` to that
   token → **Save**.

---

## Step 5: GitHub connection

**Developer Tools → Settings → Connections → Create connection**

1. Provider **GitHub**, name `bmi-cicd-github` → **Connect to GitHub**.
2. **Install a new app** → pick your GitHub account → *Only select repositories* →
   `eks-argocd-3tier-cicd` → **Install** → **Connect**.
3. Status must be **Available**.

---

## Step 6: Create the pipeline (wizard)

**CodePipeline → Pipelines → Create pipeline**

**Step 1, creation option:** *Build custom pipeline* → Next.

**Step 2, pipeline settings:**

| Field | Value |
| --- | --- |
| Pipeline name | `bmi-cicd` |
| Execution mode | **Queued** (one release at a time, in push order) |
| Service role | *New service role* (leave the generated name) |
| Advanced → Artifact store | *Default location* |

**Step 3, source:**

| Field | Value |
| --- | --- |
| Source provider | **GitHub (via GitHub App)** |
| Connection | `bmi-cicd-github` |
| Repository name | `abip007/eks-argocd-3tier-cicd` |
| Default branch | `main` |
| Output artifact format | *CodePipeline default* |
| Trigger → Trigger type | **Specify filter** |
| Event type | *Push* |
| Filter type | *Branch*, include `main` |
| File paths → Include | `app/**`, `pipeline/**`, `tests/**`, `sonar-project.properties` |

> Leave `gitops/**` out. BuildPush commits the new image tag to `gitops/`, and that commit must
> not start the pipeline again.

**Step 4, build:** *Other build providers* → **AWS CodeBuild** → **Create project**. A CodeBuild
window opens:

| Field | Value |
| --- | --- |
| Project name | `bmi-cicd` |
| Environment image | *Managed image*, OS **Amazon Linux**, runtime *Standard*, image `aws/codebuild/amazonlinux-x86_64-standard:5.0` |
| Privileged | **✓ Enable** (docker build) |
| Service role | *New service role* → `codebuild-bmi-cicd-service-role` |
| Additional configuration → Timeout | `30` minutes |
| Additional configuration → Compute | `3 GB memory, 2 vCPUs` |
| Additional configuration → Environment variables | the 6 below |
| Buildspec | *Use a buildspec file*, name `pipeline/buildspec.yml` |
| Logs | CloudWatch logs ✓ |

CodeBuild environment variables (Plaintext):

| Name | Value |
| --- | --- |
| `SONAR_HOST_URL` | `http://<elastic-ip>:9000` |
| `SONAR_PROJECT_KEY` | `bmi-cicd` |
| `ECR_PREFIX` | `bmi-cicd` |
| `GITHUB_REPO` | `abip007/eks-argocd-3tier-cicd` |
| `GIT_BRANCH` | `main` |
| `APP_URL` | `https://cicd-bmi.bestclick.click` |

**Continue to CodePipeline.** Back in the wizard, leave *Build type: Single build* and add
nothing else. **Next** → *Skip test stage* → *Skip deploy stage* → **Create pipeline**.

The first run starts at once and **fails in Build**, because no `STAGE` is set yet. That's expected.

### 6.1 Give the CodeBuild role ECR and the secret

**IAM → Roles → `codebuild-bmi-cicd-service-role` → Add permissions → Create inline policy → JSON**.
The auto-created policy already covers logs, the artifact bucket and test reports. Add:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    { "Effect": "Allow",
      "Action": ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
                 "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"],
      "Resource": ["arn:aws:ecr:ap-south-1:014882039467:repository/bmi-cicd-backend",
                   "arn:aws:ecr:ap-south-1:014882039467:repository/bmi-cicd-frontend"] },
    { "Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
      "Resource": "arn:aws:secretsmanager:ap-south-1:014882039467:secret:bmi-cicd/ci-*" }
  ]
}
```
Name it `bmi-cicd-ecr-secret` → **Create policy**.

### 6.2 Turn the wizard pipeline into the five stages

**CodePipeline → bmi-cicd → Edit.**

**a) The wizard's Build stage becomes BuildPush.** On stage *Build* click **Edit stage** → the
action's ✎ (edit):
- Action name `BuildPush`, **Variable namespace** `Build`
- Input artifact `SourceArtifact`, project `bmi-cicd`
- Environment variables: `STAGE` = `build-push`, `COMMIT_ID` = `#{SourceVariables.CommitId}`
- **Done** → **Done**.

**b) Add stage Test** with **+ Add stage** *between Source and Build*: name `Test` → **+ Add action group**:
- Action name `UnitTests`, provider **AWS CodeBuild**, input `SourceArtifact`, project `bmi-cicd`
- Environment variable `STAGE` = `unit-test` → **Done**.

**c) Add stage CodeQuality** between Test and Build: name `CodeQuality`.
- **+ Add action group**: `SonarScan`, CodeBuild, input `SourceArtifact`, project `bmi-cicd`,
  **Variable namespace** `SonarScan`, env `STAGE` = `sonar-scan`, `COMMIT_ID` = `#{SourceVariables.CommitId}` → Done.
- **+ Add action group** *below* SonarScan, so it runs after it: `QualityGate`, CodeBuild,
  input `SourceArtifact`, project `bmi-cicd`, env `STAGE` = `quality-gate`,
  `SONAR_CE_TASK_ID` = `#{SonarScan.SONAR_CE_TASK_ID}` → Done.

**d) Add stage Verify** after Build: name `Verify` → **+ Add action group**: `SmokeTest`,
CodeBuild, input `SourceArtifact`, project `bmi-cicd`, env `STAGE` = `smoke-test`,
`IMAGE_TAG` = `#{Build.IMAGE_TAG}` → Done.

**Save** → *Save* again in the dialog. The pipeline now reads:
`Source → Test(UnitTests) → CodeQuality(SonarScan → QualityGate) → Build(BuildPush) → Verify(SmokeTest)`.

The `#{...}` values are CodePipeline variables. `SourceVariables.CommitId` comes from the
source action. `SonarScan.SONAR_CE_TASK_ID` and `Build.IMAGE_TAG` are exported by the buildspec
(`exported-variables`).

---

## Step 7: The app in the cluster (CloudShell)

Argo CD needs the DB secrets (never in Git) and the Application that points at this repo.

```bash
aws eks update-kubeconfig --name argo-eks --region ap-south-1
kubectl create namespace bmi-cicd

DB_PASS=$(openssl rand -hex 16)
kubectl -n bmi-cicd create secret generic postgres-secret \
  --from-literal=POSTGRES_DB=bmidb --from-literal=POSTGRES_USER=bmi_user \
  --from-literal=POSTGRES_PASSWORD="$DB_PASS"
kubectl -n bmi-cicd create secret generic backend-secret \
  --from-literal=DATABASE_URL="postgres://bmi_user:$DB_PASS@bmi-postgres-svc:5432/bmidb"

git clone https://github.com/abip007/eks-argocd-3tier-cicd.git && cd eks-argocd-3tier-cicd
kubectl apply -f gitops/argocd/bmi-cicd-app.yaml
kubectl -n argocd get application bmi-cicd -w     # Synced / Healthy after ~3 min
```

Argo CD first deploys the **initial images**: the last `bmi-app` release, set in the overlay.
ExternalDNS creates `cicd-bmi.bestclick.click` on the shared ALB. Open
`https://cicd-bmi.bestclick.click`; it should show the app.

---

## Step 8: Run the pipeline

**CodePipeline → bmi-cicd → Release change**, or push a change to `app/`:

```bash
# on your PC, in E:/devops/eks-argocd-3tier-cicd
sed -i 's/Hello BMI/CI\/CD BMI/' app/frontend/src/App.jsx
git commit -am "feat: new title" && git push
```

What you'll see (about 8–12 minutes):

| Stage | Where to look |
| --- | --- |
| Test → UnitTests | *Details* → CodeBuild log; **CodeBuild → Report groups** `bmi-cicd-unit-tests` and `bmi-cicd-coverage` |
| CodeQuality → SonarScan | log ends with `ANALYSIS SUCCESSFUL`; SonarQube → Projects → bmi-cicd |
| CodeQuality → QualityGate | log prints a table of every condition and `Quality gate PASSED` |
| Build → BuildPush | ECR shows a new tag; GitHub shows commit `release: bmi-cicd images <tag>` |
| Verify → SmokeTest | `live version: <tag>` and then `Smoke tests: 8 passed, 0 failed`; report group `bmi-cicd-smoke-tests` |

The pushed commit only changes `gitops/`, so it doesn't start a second run.

To check that a red gate really stops a release, see
[Proving the gates work](../README.md#proving-the-gates-work).

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Source: *connection is not available* | Step 5 status must be **Available**; the GitHub App must have access to the repo |
| Any action: `Secrets Manager ... AccessDenied` / `ResourceNotFound` | Secret name must be exactly `bmi-cicd/ci` with both keys; inline policy from 6.1 |
| SonarScan: `connect ETIMEDOUT <ip>:9000` | Security group misses the CodeBuild CIDRs (3.1/3.3) or the instance is stopped |
| SonarScan: `Not authorized` / 401 | `sonar_token` wrong, or `ci-pipeline` lacks *Execute Analysis* |
| QualityGate: `no quality gate is assigned` | Step 4.2, Projects tab |
| QualityGate: FAILED | Working as intended: open the dashboard link in the log and fix the listed issues |
| BuildPush: `denied: ... not authorized to perform ecr:InitiateLayerUpload` | Inline policy 6.1 (repo names) |
| BuildPush: `Permission to ... denied` / 403 on git push | GitHub token needs **Contents: Read and write** on this repo |
| SmokeTest: `version ... not live after 900s` | `kubectl -n argocd get application bmi-cicd`, `kubectl -n bmi-cicd get pods`; Argo CD must be able to read the repo (public) |
| Pipeline starts twice per release | `gitops/**` got into the trigger's file paths: remove it |

---

## Clean up

1. CloudShell: `kubectl -n argocd delete application bmi-cicd` (removes the pods and the Ingress rule;
   the shared ALB stays), then `kubectl delete namespace bmi-cicd` (removes the EBS volume).
2. **CodePipeline**: delete `bmi-cicd`. **CodeBuild**: delete project `bmi-cicd` and its report groups.
3. **Connections**: delete `bmi-cicd-github`.
4. **EC2**: terminate `bmi-cicd-sonarqube`, release the Elastic IP, delete SG `bmi-cicd-sonarqube`.
5. **ECR**: delete both repos. **Secrets Manager**: delete `bmi-cicd/ci`.
6. **IAM**: delete roles `bmi-cicd-sonarqube-ec2`, `codebuild-bmi-cicd-service-role`,
   `AWSCodePipelineServiceRole-ap-south-1-bmi-cicd` and their customer-managed policies.
7. **S3**: empty and delete the `codepipeline-ap-south-1-...` bucket if nothing else uses it.
8. Route 53: ExternalDNS runs `upsert-only`, so delete the `cicd-bmi` A/TXT records by hand.
