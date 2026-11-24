# Build everything from the AWS Console (step by step)

This guide builds the whole project by clicking: the VPC and EKS cluster, the platform
(Load Balancer Controller, ExternalDNS, Argo CD), the app with its observability stack
(Prometheus, Alertmanager, Grafana, Loki, Alloy), the SonarQube server, and the
CodePipeline with unit tests, SonarQube, Trivy and smoke tests. The result is the same as
[Terraform](03-terraform-guide.md) and the [command-line guide](02-command-line-guide.md).

A few jobs can't be done by clicking (Helm installs, Kubernetes secrets, `kubectl apply`).
For those you use **AWS CloudShell**, the `>_` icon in the console's top bar, so you never
leave the browser.

> **Use one path only.** Console, CLI and Terraform create resources with the same names
> (`bmi-cicd-*`). If you mix them in one account, the names collide.

**Values used in this guide.** Replace them if yours differ:

| Setting | Value |
| --- | --- |
| Region | `ap-south-1` (Mumbai). Check it top-right **before every step** |
| Account ID | `014882039467` (yours: top-right menu) |
| Name prefix | `bmi-cicd` |
| Cluster name | `bmi-cicd-eks`, Kubernetes `1.36` |
| VPC CIDR | `10.2.0.0/16` |
| Domain (Route 53 hosted zone) | `bestclick.click` |
| App URL | `https://cicd-bmi.bestclick.click` |
| Argo CD URL | `https://argocd-cicd.bestclick.click` |
| Grafana URL | `https://grafana-cicd.bestclick.click` |
| GitHub repo (pipeline source, watched by Argo CD) | `abip007/eks-argocd-3tier-cicd` |

Before you start, finish the [Prerequisites](../README.md#prerequisites): the repo is on GitHub,
you have the fine-grained GitHub token, and the hosted zone and ACM certificate exist.
Sign in as your **IAM user**, never as root. The identity that creates the cluster becomes its first admin.

**Order:** Part A builds the platform (about 40 minutes, mostly waiting for EKS). Part B puts
the app on it. Part C builds the pipeline. Part B comes before C because creating the pipeline
starts a run at once, and its smoke test needs the app to exist.

---

# Part A: Platform

## Step 1: VPC

**VPC console → Create VPC**

1. **Resources to create**: `VPC and more`
2. **Name tag auto-generation**: `bmi-cicd-eks`
3. **IPv4 CIDR block**: `10.2.0.0/16`
4. **Number of Availability Zones**: `3`; **public subnets** `3`; **private subnets** `3`
5. **Customize subnets CIDR blocks**: public `10.2.0.0/20`, `10.2.16.0/20`, `10.2.32.0/20`;
   private `10.2.64.0/19`, `10.2.96.0/19`, `10.2.128.0/19`. Private subnets are bigger because every pod gets a VPC IP.
6. **NAT gateways**: `In 1 AZ` (cheap; `1 per AZ` is the HA option at about 3× the cost)
7. **VPC endpoints**: `S3 Gateway` (free, cuts NAT traffic for ECR image layers)
8. **DNS options**: enable **DNS hostnames** and **DNS resolution** → **Create VPC**

### 1.1 Tag the subnets (no ALB without these)

**VPC → Subnets**, for each subnet **Tags → Manage tags → Add new tag**:

| Subnets | Key | Value |
| --- | --- | --- |
| the 3 **public** ones | `kubernetes.io/role/elb` | `1` |
| the 3 **private** ones | `kubernetes.io/role/internal-elb` | `1` |

For each **public** subnet: **Actions → Edit subnet settings** → tick
**Enable auto-assign public IPv4 address** → Save. (SonarQube runs in a public subnet in Step 11.)

---

## Step 2: IAM roles and policies

### 2.1 Cluster role `bmi-cicd-eks-cluster-role`
**IAM → Roles → Create role** → *AWS service* → Use case **EKS** → **EKS - Cluster** →
`AmazonEKSClusterPolicy` (pre-selected) → name `bmi-cicd-eks-cluster-role` → **Create role**.

### 2.2 Node role `bmi-cicd-eks-node-role`
*AWS service* → **EC2** → attach `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryPullOnly`,
`AmazonEKS_CNI_Policy`, `AmazonSSMManagedInstanceCore` → name `bmi-cicd-eks-node-role`.

### 2.3 Controller policies
**IAM → Policies → Create policy → JSON**, paste the file, **Next**, name it:

| Policy name | Paste this file |
| --- | --- |
| `bmi-cicd-eks-lbc` | [`policies/aws-load-balancer-controller.json`](../policies/aws-load-balancer-controller.json) |
| `bmi-cicd-eks-external-dns` | [`policies/external-dns.json`](../policies/external-dns.json) |

### 2.4 Pod Identity roles
For each row: **Create role** → *AWS service* → **EKS** → **EKS - Pod Identity** → attach the policy → name it.

| Role name | Attach policy |
| --- | --- |
| `bmi-cicd-eks-ebs-csi` | `AmazonEBSCSIDriverPolicy` (AWS managed) |
| `bmi-cicd-eks-lbc` | `bmi-cicd-eks-lbc` (from 2.3) |
| `bmi-cicd-eks-external-dns` | `bmi-cicd-eks-external-dns` (from 2.3) |

---

## Step 3: EKS cluster

**EKS console → Clusters → Create cluster**

1. **Custom configuration**, **EKS Auto Mode off** (this project manages its own node group and add-ons).
2. **Configure cluster**: name `bmi-cicd-eks`, version `1.36`, cluster IAM role `bmi-cicd-eks-cluster-role`.
   *Bootstrap cluster administrator access* = **Allow**; *Cluster authentication mode* = **EKS API**;
   *Upgrade policy* = **Standard** (no paid extended support) → **Next**.
3. **Networking**: VPC `bmi-cicd-eks-vpc`, **only the 3 private subnets**, no extra security groups.
   Endpoint access **Public and private** (under *Advanced settings* you can limit the public
   endpoint to your IP) → **Next**.
4. **Observability**: control plane logs **API server**, **Audit**, **Authenticator** → **Next**.
5. **Add-ons**: tick **Amazon VPC CNI**, **kube-proxy**, **CoreDNS**, **Amazon EKS Pod Identity Agent**,
   **Metrics Server**, **Amazon EBS CSI Driver** → **Next**.
6. **Add-on settings**:
   - **Amazon EBS CSI Driver** → *Pod Identity IAM role*: `bmi-cicd-eks-ebs-csi`
   - **Amazon VPC CNI** → *Configuration values*: `{"enableNetworkPolicy":"true"}`
   - defaults for the rest → **Next** → **Create**.

Status goes from *Creating* to **Active** in 10–15 minutes.

---

## Step 4: Node group

**Cluster `bmi-cicd-eks` → Compute → Add node group**

1. Name `general`, node IAM role `bmi-cicd-eks-node-role`, label `role` = `general` → **Next**
2. AMI **Amazon Linux 2023 (x86_64) Standard**, **On-Demand**, **m7i-flex.large**, disk **20 GiB**
   (free-plan eligible, 29 pods per node; a t3.small fits only 11 → "Too many pods")
3. Scaling **min 2 / desired 2 / max 4**, max unavailable **1** → **Next**
4. Subnets: the **3 private** subnets, remote access **off** → **Create**

Wait until the node group is **Active** and every add-on on the **Add-ons** tab is *Active*
(CoreDNS and EBS CSI need running nodes first).

---

## Step 5: Pod Identity associations

**Cluster → Access → Pod Identity associations → Create** (the namespaces don't need to exist yet):

| IAM role | Namespace | Service account |
| --- | --- | --- |
| `bmi-cicd-eks-lbc` | `kube-system` | `aws-load-balancer-controller` |
| `bmi-cicd-eks-external-dns` | `external-dns` | `external-dns` |

The EBS CSI association came with the add-on in Step 3.

If your PC's `aws` profile is a **different** IAM identity from your console user:
**Access → IAM access entries → Create access entry** → its ARN → *Standard* → policy
`AmazonEKSClusterAdminPolicy`, scope *Cluster*.

---

## Step 6: Check the ACM certificate and the hosted zone

- **Certificate Manager (ap-south-1)**: a certificate for `bestclick.click` + `*.bestclick.click`
  must be **Issued**. If not: **Request → public** → both names → **DNS validation** →
  **Create records in Route 53** → wait for *Issued*. Copy the ARN.
- **Route 53 → Hosted zones**: there must be **one** `bestclick.click` zone, the one whose
  name servers match your registrar (`nslookup -type=ns bestclick.click`). Copy its **Hosted zone ID**.

If the certificate ARN or zone ID differ from the values in
[`platform/argocd-values.yaml`](../platform/argocd-values.yaml),
[`platform/external-dns-values.yaml`](../platform/external-dns-values.yaml) and
[the overlay](../gitops/bmi-cicd/overlays/prod/kustomization.yaml), change them there and push.

---

## Step 7: CloudShell: connect to the cluster

Open **CloudShell** (`>_`). It runs as your console identity (the cluster admin), and its
clock is always correct, which matters for the LB Controller (see [Troubleshooting](#troubleshooting)).

```bash
command -v kubectl || { curl -sLO "https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl" && chmod +x kubectl && mkdir -p ~/bin && mv kubectl ~/bin/; }
command -v helm    || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

aws eks update-kubeconfig --name bmi-cicd-eks --region ap-south-1
kubectl get nodes                      # 2 nodes, Ready
git clone https://github.com/abip007/eks-argocd-3tier-cicd.git && cd eks-argocd-3tier-cicd
```

---

## Step 8: Install the platform (CloudShell)

```bash
# 8.1 Default StorageClass gp3 (Postgres asks for storageClassName: gp3)
kubectl apply -f platform/storageclass-gp3.yaml
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite 2>/dev/null || true

# 8.2 Gateway API CRDs (the LB Controller v3 expects them) + AWS Load Balancer Controller
kubectl apply --server-side --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.0/config/crd/gateway/gateway-crds.yaml
VPC_ID=$(aws eks describe-cluster --name bmi-cicd-eks --query cluster.resourcesVpcConfig.vpcId --output text)
helm upgrade --install aws-load-balancer-controller aws-load-balancer-controller \
  --repo https://aws.github.io/eks-charts -n kube-system \
  --set clusterName=bmi-cicd-eks --set region=ap-south-1 --set vpcId=$VPC_ID \
  --set serviceAccount.name=aws-load-balancer-controller --wait --timeout 10m

# 8.3 ExternalDNS: a Route 53 record for every Ingress host
helm upgrade --install external-dns external-dns \
  --repo https://kubernetes-sigs.github.io/external-dns/ -n external-dns --create-namespace \
  -f platform/external-dns-values.yaml --wait

# 8.4 Prometheus Operator CRDs (ServiceMonitor, PrometheusRule, ...). Before Argo CD,
#     because Argo CD's own ServiceMonitors (8.5) and the app's need them.
kubectl create namespace observability
helm upgrade --install prometheus-operator-crds prometheus-operator-crds   --repo https://prometheus-community.github.io/helm-charts --version 33.0.1   -n observability --wait

# 8.5 Argo CD (UI on the shared ALB, metrics on for Prometheus)
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm -n argocd --create-namespace \
  -f platform/argocd-values.yaml --wait --timeout 15m

kubectl -n argocd get ingress          # ADDRESS k8s-shared-... after ~2 min
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Check: **EC2 → Load Balancers** shows `k8s-shared-…` *Active*; **Route 53** shows `argocd-cicd`
A + TXT records. Open `https://argocd-cicd.bestclick.click` (DNS can take a few minutes) and log
in as `admin` with the password above.

---

# Part B: The app

## Step 9: Secrets and the Argo CD root app (CloudShell)

The DB and Grafana secrets are created here, never stored in Git. The **root** Application
(app-of-apps) points Argo CD at `gitops/argocd/apps/`, and Argo CD creates the five apps in it:
`bmi-cicd` (the app) and the observability stack `kube-prometheus-stack`, `loki`, `alloy`,
`observability-extras`.

```bash
kubectl create namespace bmi-cicd
DB_PASS=$(openssl rand -hex 16)
kubectl -n bmi-cicd create secret generic postgres-secret \
  --from-literal=POSTGRES_DB=bmidb --from-literal=POSTGRES_USER=bmi_user \
  --from-literal=POSTGRES_PASSWORD="$DB_PASS"
kubectl -n bmi-cicd create secret generic backend-secret \
  --from-literal=DATABASE_URL="postgres://bmi_user:$DB_PASS@bmi-postgres-svc:5432/bmidb"

GRAFANA_PASS=$(openssl rand -hex 12)
kubectl -n observability create secret generic grafana-admin   --from-literal=admin-user=admin --from-literal=admin-password="$GRAFANA_PASS"
echo "Grafana: admin / $GRAFANA_PASS"            # note it down

kubectl apply -f gitops/argocd/root-app.yaml
kubectl -n argocd get applications -w             # Ctrl+C when all six are Synced
```

Postgres starts at once. Backend and frontend show **ImagePullBackOff** until the pipeline's
first BuildPush has pushed images to ECR (Step 14). That's expected on a fresh account.
ExternalDNS creates `cicd-bmi.bestclick.click` as soon as the Ingress exists, and
`grafana-cicd.bestclick.click` once kube-prometheus-stack is synced (3–5 minutes).

---

# Part C: Pipeline

## Step 10: ECR repositories and the pipeline secret

**ECR → Private registry → Repositories → Create repository**, twice:

| Field | Value |
| --- | --- |
| Repository name | `bmi-cicd-backend` (then `bmi-cicd-frontend`) |
| Image tag mutability | **Immutable** (a tag in Git always means the same image) |
| Scan on push | on |

Optional per repo: **Lifecycle policy → Create rule** → *Image count more than* `20` → *Expire*.

**Secrets Manager → Store a new secret** → *Other type of secret*:

| Key | Value |
| --- | --- |
| `github_token` | your fine-grained GitHub token (`github_pat_...`) |
| `sonar_token` | `placeholder` (Step 12 replaces it) |

**Secret name** `bmi-cicd/ci` (exactly: the buildspec reads it) → no rotation → **Store**.

---

## Step 11: SonarQube server (EC2)

### 11.1 CodeBuild IP ranges
CodeBuild reaches SonarQube from AWS-owned addresses. In **CloudShell**:

```bash
curl -s https://ip-ranges.amazonaws.com/ip-ranges.json \
  | jq -r '.prefixes[] | select(.service=="CODEBUILD" and .region=="ap-south-1") | .ip_prefix'
```

Also note your own IP: on your PC, `curl -s https://checkip.amazonaws.com`.

### 11.2 Instance role
**IAM → Roles → Create role** → *AWS service* → **EC2** → `AmazonSSMManagedInstanceCore` →
name `bmi-cicd-sonarqube-ec2`. (Session Manager instead of SSH keys.)

### 11.3 Security group
**EC2 → Security Groups → Create**: name `bmi-cicd-sonarqube`, VPC **`bmi-cicd-eks-vpc`**.
Inbound *Custom TCP* port `9000`: your IP `x.x.x.x/32` (`admins`) and each CodeBuild CIDR
from 11.1 (`codebuild`). Outbound: all. **Create**.

> Never open 9000 to `0.0.0.0/0`: the token travels over plain HTTP. For production, put
> SonarQube behind an HTTPS load balancer.

### 11.4 Launch the instance
**EC2 → Launch instances**:

| Field | Value |
| --- | --- |
| Name | `bmi-cicd-sonarqube` |
| AMI | **Amazon Linux 2023** (x86_64) |
| Instance type | `m7i-flex.large` (8 GiB; SonarQube needs ≥ 4 GiB) |
| Key pair | *Proceed without a key pair* |
| Network | VPC `bmi-cicd-eks-vpc`, a **public** subnet, auto-assign public IP **Enable**, security group `bmi-cicd-sonarqube` |
| Storage | `30` GiB **gp3**, encrypted |
| Advanced → IAM instance profile | `bmi-cicd-sonarqube-ec2` |
| Advanced → Metadata version | *V2 only (token required)* |
| Advanced → User data | the whole of [`sonarqube/user-data.sh`](../sonarqube/user-data.sh) |

### 11.5 Elastic IP
**EC2 → Elastic IPs → Allocate** → **Actions → Associate** → instance `bmi-cicd-sonarqube`.
Your **SONAR_HOST_URL** is `http://<elastic-ip>:9000`. SonarQube takes 3–5 minutes to start.
If it doesn't come up: **Connect → Session Manager** →
`sudo tail -50 /var/log/cloud-init-output.log; sudo docker logs sonarqube | tail`.

---

## Step 12: Configure SonarQube

**Shortcut (recommended):** run the setup script from CloudShell. It does all of 12.1–12.3 and
writes the token into the secret:

```bash
cd ~/eks-argocd-3tier-cicd
read -rsp "New SonarQube admin password (>=12 chars, upper/lower/digit/special): " P; echo
SONAR_HOST_URL=http://<elastic-ip>:9000 SONAR_ADMIN_PASSWORD="$P" AWS_REGION=ap-south-1 \
  bash sonarqube/setup-sonarqube.sh
```

(Add CloudShell's IP to the security group first, or run it from your PC with
`AWS_PROFILE=<your profile>`.) By hand, it's these clicks:

### 12.1 Project
Log in as `admin` / `admin` and set a new password. **Projects → Create project → Local
project**: name `BMI Health Tracker (CI/CD)`, **key `bmi-cicd`**, branch `main` →
*Use the global setting* → **Create project**.

### 12.2 Quality gate
**Quality Gates → Create** → `bmi-cicd-gate`. It already holds the *Clean as You Code*
conditions on new code. Add **On Overall Code**:

| Metric | Operator | Value |
| --- | --- | --- |
| Coverage | is less than | `80` |
| Duplicated Lines (%) | is greater than | `3` |
| Reliability Rating | is worse than | `A` |
| Security Rating | is worse than | `A` |
| Maintainability Rating | is worse than | `A` |

**Projects** tab of the gate → *All* → tick **bmi-cicd**.

### 12.3 CI user and token
1. **Administration → Security → Users → Create User**: `ci-pipeline`, long random password.
2. **bmi-cicd → Project Settings → Permissions** → `ci-pipeline` → **Browse** + **Execute Analysis**.
3. **Users** → `ci-pipeline` → **Tokens** → name `codebuild` → **Generate** → copy (`squ_...`).
4. **Secrets Manager → `bmi-cicd/ci` → Edit** → `sonar_token` = that token → **Save**.

---

## Step 13: GitHub connection

**Developer Tools → Settings → Connections → Create connection** → **GitHub**, name
`bmi-cicd-github` → **Connect to GitHub** → **Install a new app** → your account →
*Only select repositories* → `eks-argocd-3tier-cicd` → **Install** → **Connect**.
Status must be **Available**.

---

## Step 14: Create the pipeline

### 14.1 Wizard
**CodePipeline → Create pipeline** → *Build custom pipeline*.

| Field | Value |
| --- | --- |
| Pipeline name | `bmi-cicd` |
| Execution mode | **Queued** (one release at a time, in push order) |
| Service role | *New service role* |
| Source provider | **GitHub (via GitHub App)**, connection `bmi-cicd-github`, repo `abip007/eks-argocd-3tier-cicd`, branch `main` |
| Trigger | **Specify filter** → *Push*, branch `main`, file paths include `app/**`, `pipeline/**`, `tests/**`, `sonar-project.properties` |

> Leave `gitops/**` out of the trigger: BuildPush commits the new image tag there, and that
> commit must not start the pipeline again.

**Build:** **AWS CodeBuild** → **Create project**:

| Field | Value |
| --- | --- |
| Project name | `bmi-cicd` |
| Image | *Managed*, **Amazon Linux**, *Standard*, `aws/codebuild/amazonlinux-x86_64-standard:5.0` |
| Privileged | **✓** (docker build) |
| Service role | *New* → `codebuild-bmi-cicd-service-role` |
| Timeout | `30` minutes; compute `3 GB, 2 vCPUs` |
| Buildspec | *Use a buildspec file* → `pipeline/buildspec.yml` |
| Environment variables (plaintext) | `SONAR_HOST_URL`=`http://<elastic-ip>:9000`, `SONAR_PROJECT_KEY`=`bmi-cicd`, `ECR_PREFIX`=`bmi-cicd`, `GITHUB_REPO`=`abip007/eks-argocd-3tier-cicd`, `GIT_BRANCH`=`main`, `APP_URL`=`https://cicd-bmi.bestclick.click` |

**Continue to CodePipeline** → *Single build* → skip test and deploy → **Create pipeline**.
The first run **fails in Build** (no `STAGE` yet). That's expected.

### 14.2 CodeBuild role: ECR and the secret
**IAM → Roles → `codebuild-bmi-cicd-service-role` → Add permissions → Create inline policy → JSON**:

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
Name `bmi-cicd-ecr-secret` → **Create policy**.

### 14.3 The five stages
**CodePipeline → bmi-cicd → Edit**:

**a) Build → BuildPush.** Stage *Build* → **Edit stage** → ✎ on the action: name `BuildPush`,
**variable namespace** `Build`, env `STAGE`=`build-push`, `COMMIT_ID`=`#{SourceVariables.CommitId}` → Done.

**b) Test** (*+ Add stage* between Source and Build) → action `UnitTests`, CodeBuild, input
`SourceArtifact`, project `bmi-cicd`, env `STAGE`=`unit-test`.

**c) CodeQuality** (between Test and Build):
- **+ Add action group** → `SonarScan`, namespace `SonarScan`, env `STAGE`=`sonar-scan`,
  `COMMIT_ID`=`#{SourceVariables.CommitId}`.
- In the **same** action group, **+ Add action** → `SecurityScan`, env `STAGE`=`security-scan`.
  Same group = runs **in parallel** with SonarScan.
- **+ Add action group** *below* → `QualityGate`, env `STAGE`=`quality-gate`,
  `SONAR_CE_TASK_ID`=`#{SonarScan.SONAR_CE_TASK_ID}`.

**d) Verify** (after Build) → `SmokeTest`, env `STAGE`=`smoke-test`, `IMAGE_TAG`=`#{Build.IMAGE_TAG}`.

All actions: provider **AWS CodeBuild**, input `SourceArtifact`, project `bmi-cicd`. **Save**.
The pipeline now reads:

`Source → Test(UnitTests) → CodeQuality(SonarScan + SecurityScan → QualityGate) → Build(BuildPush) → Verify(SmokeTest)`

---

## Step 15: Run it

**CodePipeline → bmi-cicd → Release change**, or push a change under `app/`. About 10–15 minutes:

| Stage | What happens / where to look |
| --- | --- |
| Test → UnitTests | Jest + Vitest, coverage ≥ 80%. Report groups `bmi-cicd-unit-tests`, `bmi-cicd-coverage` |
| CodeQuality → SonarScan | log ends `ANALYSIS SUCCESSFUL`; SonarQube → Projects → bmi-cicd |
| CodeQuality → SecurityScan | Trivy: dependency CVEs, secrets, IaC misconfig. Report group `bmi-cicd-security-scan` |
| CodeQuality → QualityGate | table of every condition, `Quality gate PASSED` |
| Build → BuildPush | per image: `docker build` → **Trivy image scan** → push. ECR shows the tag; GitHub shows `release: bmi-cicd images <tag>` |
| Verify → SmokeTest | `live version: <tag>`, then `Smoke tests: 8 passed`; report group `bmi-cicd-smoke-tests` |

The release commit only touches `gitops/`, so it doesn't start another run. Argo CD deploys it
within about a minute, and `https://cicd-bmi.bestclick.click` serves the new version.

### Observability: what you get

Open `https://grafana-cicd.bestclick.click`, log in as `admin` with the password from Step 9.

| Where in Grafana | What it shows |
| --- | --- |
| **Dashboards → BMI → BMI app (CI/CD)** | live release (image tag), Argo CD sync and health, pods per version (each step is a release), request rate, 5xx ratio, p50/p95/p99 latency, CPU/memory per pod, Postgres volume free, logs |
| **Dashboards → Kubernetes / …** | the chart's standard cluster, node, namespace and pod dashboards |
| **Explore → Prometheus** | any metric, e.g. `sum by (route, status_code) (rate(http_request_duration_seconds_count{namespace="bmi-cicd"}[5m]))` |
| **Explore → Loki** | every pod's logs and Kubernetes events, e.g. `{namespace="bmi-cicd", app="bmi-backend"} \| json \| status >= 500` |
| **Alerting → Alert rules** | the chart's defaults plus `bmi-cicd`: backend down, 5xx > 5%, p95 > 1 s, Postgres volume < 15% free, Argo CD app out of sync / unhealthy, pods stuck on two versions |

How it's wired: the backend serves `/metrics` (prom-client) and writes one JSON log line per
request. A ServiceMonitor tells Prometheus to scrape it every 30 s; Alloy reads every pod's
output and pushes it to Loki. `/metrics` is only reachable inside the cluster: the ALB and nginx
route `/api/*` only. Alerts reach Alertmanager but aren't sent anywhere until you add a receiver
(Slack, email) under `alertmanager.config` in
[`gitops/observability/kube-prometheus-stack-values.yaml`](../gitops/observability/kube-prometheus-stack-values.yaml).

After a release, the dashboard's **Live version** turns to the new tag within about a minute of
the smoke test passing.

### What Trivy checks

| Layer | Fails on | Doesn't fail on |
| --- | --- | --- |
| SecurityScan (repo) | any committed secret; a HIGH/CRITICAL CVE in `package-lock.json` **that has a fix** | misconfigurations (printed only, until `TRIVY_MISCONFIG_GATE=true` is set on the action) |
| BuildPush (image) | a HIGH/CRITICAL CVE with a fix in the image's OS packages or node modules. The image isn't pushed | CVEs without a fix |

Usual fix for an image finding: a newer base image tag in `app/*/Dockerfile`, or `npm update`
of the named package. To accept a finding on purpose, add its ID to [`.trivyignore`](../.trivyignore)
with the reason and a review date.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Helm: `x509 ... not yet valid` on `mservice.elbv2.k8s.aws` | Helm signs the LB Controller webhook cert with the clock of the machine running it. Use CloudShell, or fix the PC clock (`w32tm /resync /force`), `helm uninstall`, reinstall |
| Helm: `cannot re-use a name that is still in use` | `helm -n <ns> uninstall <name>`, install again |
| Ingress has no ADDRESS | Subnet tags (1.1) or the LBC Pod Identity association (5): `kubectl -n kube-system logs deploy/aws-load-balancer-controller` |
| Postgres / PVC `Pending` | EBS CSI role (Step 3, item 6) or StorageClass (8.1) |
| Backend/frontend `ImagePullBackOff` | Normal until the first BuildPush (Step 15) |
| Argo CD apps show `ServiceMonitor ... no matches for kind` | The CRDs (8.4) weren't installed before Argo CD. Install them, then **Refresh** the app |
| `kube-prometheus-stack` OutOfSync on webhooks / CRDs | Click **Sync** once; `ServerSideApply` is set, the webhook `caBundle` is ignored |
| Grafana login fails | Secret `grafana-admin` must exist in `observability` before the first sync. Recreate it, then `kubectl -n observability rollout restart deploy/kube-prometheus-stack-grafana` |
| Dashboard panels empty | Explore → Prometheus → `up{namespace="bmi-cicd"}`. 0 or nothing: Service label `app: bmi-backend` / port name `http` (ServiceMonitor) |
| No logs in Loki | `kubectl -n observability logs deploy/alloy` and `kubectl -n observability get pods` (loki-0 Running) |
| Host doesn't resolve | `kubectl -n external-dns logs deploy/external-dns`. If records went to a different zone ID than your registrar's: delete the duplicate zone or set `--zone-id-filter` (Step 6) |
| SmokeTest: `live version: unreachable` for 15 min on the first run, app works in a browser | The DNS record was created after the test started, and CodeBuild's resolver cached the "no such name" answer. **Retry** the Verify stage |
| Source: *connection is not available* | Step 13 status must be **Available** |
| `Secrets Manager ... AccessDenied` / `ResourceNotFound` | Secret name exactly `bmi-cicd/ci`, both keys; inline policy 14.2 |
| SonarScan: `ETIMEDOUT <ip>:9000` | SG misses the CodeBuild CIDRs, or the instance is stopped |
| SonarScan: 401 | Wrong `sonar_token`, or `ci-pipeline` lacks *Execute Analysis* |
| QualityGate FAILED | Working as intended: open the dashboard link in the log |
| SecurityScan / BuildPush: `Trivy found blocking issues` / `image ... not pushed` | Working as intended: the log lists each CVE with the fixed version. Update, or accept in `.trivyignore` |
| BuildPush: 403 on `git push` | GitHub token needs **Contents: Read and write** |
| Pipeline runs twice per release | `gitops/**` is in the trigger paths: remove it |

---

## Clean up (in this order, or the VPC won't delete)

1. CloudShell:
   ```bash
   kubectl -n argocd delete application root --wait        # deletes all five child apps
   kubectl delete namespace bmi-cicd                       # Postgres EBS volume
   kubectl delete pvc --all -n observability               # Prometheus, Alertmanager, Loki volumes
   kubectl delete ingress --all -A                         # last Ingress -> ALB is deleted
   helm -n argocd uninstall argocd
   helm -n observability uninstall prometheus-operator-crds
   sleep 60
   helm -n external-dns uninstall external-dns
   helm -n kube-system uninstall aws-load-balancer-controller
   ```
2. **EC2 → Load Balancers**: no `k8s-shared-…` left.
3. **CodePipeline** `bmi-cicd`, **CodeBuild** project + report groups, **Connections** `bmi-cicd-github`.
4. **EC2**: terminate `bmi-cicd-sonarqube`, release its Elastic IP, delete SG `bmi-cicd-sonarqube`.
5. **ECR**: both `bmi-cicd-*` repos. **Secrets Manager**: `bmi-cicd/ci`.
6. **EKS**: delete node group `general`, then the cluster.
7. **VPC**: delete `bmi-cicd-eks-vpc` (takes the NAT gateway, subnets, endpoint); release the NAT's Elastic IP.
8. **IAM**: roles `bmi-cicd-eks-*` (5), `bmi-cicd-sonarqube-ec2`, `codebuild-bmi-cicd-service-role`,
   `AWSCodePipelineServiceRole-ap-south-1-bmi-cicd`; policies `bmi-cicd-eks-lbc`, `bmi-cicd-eks-external-dns`
   and the pipeline/CodeBuild customer-managed ones.
9. **S3**: the `codepipeline-ap-south-1-…` bucket if nothing else uses it.
10. **Route 53**: delete the `cicd-bmi`, `argocd-cicd` and `grafana-cicd` A/AAAA/TXT records (ExternalDNS is `upsert-only`).
11. **EC2 → Volumes**: no *available* volume named `bmi-cicd-eks-dynamic-pvc-…` should be left. Delete any that are.
