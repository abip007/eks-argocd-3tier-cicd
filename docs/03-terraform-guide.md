# Build everything with Terraform

[`terraform/`](../terraform) builds the whole project in **one apply** (about 25 minutes): the VPC
and EKS cluster, the platform (Load Balancer Controller, ExternalDNS, Argo CD), the app and
its observability stack (Prometheus, Alertmanager, Grafana, Loki, Alloy, deployed by Argo CD),
the SonarQube server, and the CodePipeline with unit tests, SonarQube, Trivy and smoke tests.

| File | Creates |
| --- | --- |
| `network.tf` | VPC `10.2.0.0/16`: 3 public + 3 private subnets (tagged for ALBs), one NAT gateway, S3 endpoint |
| `eks.tf` | EKS cluster `bmi-cicd-eks` (1.36, API auth mode), add-ons (VPC CNI with network policy, CoreDNS, kube-proxy, Pod Identity agent, metrics-server, EBS CSI), node group 2 × m7i-flex.large |
| `iam.tf` | Pod Identity roles for the LB Controller and ExternalDNS (from `policies/*.json`) and the EBS CSI driver |
| `platform.tf` | ACM certificate lookup, `gp3` StorageClass, Gateway API CRDs, LB Controller, ExternalDNS, namespace `observability` + Prometheus Operator CRDs, Argo CD (UI at `argocd_host`, metrics on) |
| `kubernetes.tf` | Namespace `bmi-cicd`, DB secrets and Grafana admin secret (random passwords), Argo CD **root** app (`argocd-apps` chart) → everything in `gitops/argocd/apps/`, destroy-time teardown |
| `sonarqube.tf` | EC2 in a public subnet of the VPC (`sonarqube/user-data.sh`), Elastic IP, security group (your IP + CodeBuild ranges), SSM role |
| `ecr-secrets.tf` | ECR `bmi-cicd-backend` / `-frontend`, secret `bmi-cicd/ci` |
| `codebuild.tf` | CodeBuild project `bmi-cicd`, its role and log group |
| `codepipeline.tf` | GitHub connection, artifact bucket, pipeline role, pipeline `bmi-cicd` (trigger + 6 actions) |
| `github-actions.tf` | OIDC role for the optional [GitHub Actions workflow](04-github-actions-guide.md) |

Before you start, finish the [Prerequisites](../README.md#prerequisites). Terraform runs `aws` and
`kubectl` itself (cluster auth, Gateway API CRDs), so both must be on PATH.

## Step 1: Variables

```bash
cd C:/DevOps/eks-argocd-3tier-cicd/terraform
cp terraform.tfvars.example terraform.tfvars
curl -s https://checkip.amazonaws.com          # -> admin_cidrs = ["x.x.x.x/32"]
```

Edit `terraform.tfvars`:

| Variable | What to set |
| --- | --- |
| `aws_profile`, `region` | your CLI profile and region |
| `admin_cidrs` | your IP for the SonarQube UI |
| `domain_name`, `app_host`, `argocd_host`, `grafana_host` | your hosted zone and the three hostnames (`grafana_host` must equal `gitops/observability/kube-prometheus-stack-values.yaml`) |
| `external_dns_zone_id` | only if the account has more than one zone with that name: the one whose name servers match `nslookup -type=ns <domain>` |
| `github_oidc_provider_arn` | only if the account already has a GitHub OIDC provider (`aws iam list-open-id-connect-providers`) |
| `api_public_access_cidrs` | optional: lock the Kubernetes API to your IP |

Pass the GitHub token through the environment, never in a file:

```bash
read -rsp "GitHub fine-grained token: " TF_VAR_github_token; echo; export TF_VAR_github_token
# PowerShell: $env:TF_VAR_github_token = "github_pat_..."
```

The token ends up only in Secrets Manager and in the Terraform state. Keep the state private,
or use the S3 backend that's commented out in `versions.tf`.

## Step 2: Apply

```bash
terraform init
terraform plan -out tf.plan
terraform apply tf.plan                             # ~25 minutes
terraform output
$(terraform output -raw kubeconfig_command)         # kubectl access for you
kubectl get nodes; kubectl -n argocd get application bmi-cicd
```

The pipeline starts a first run as soon as it exists. It **fails**, because the GitHub connection
is still pending and SonarQube isn't configured. That's expected. The app's backend and frontend
show `ImagePullBackOff` until the first successful BuildPush.

Argo CD: `terraform output argocd_url`, user `admin`, password from
`terraform output -raw argocd_admin_password_command`. Six apps appear: `root`, `bmi-cicd`,
`kube-prometheus-stack`, `loki`, `alloy`, `observability-extras`.

Grafana: `terraform output grafana_url`, user `admin`, password from
`terraform output -raw grafana_admin_password_command`. Dashboard **BMI → BMI app (CI/CD)**;
what's where is in the [console guide](01-console-guide.md#observability-what-you-get).

## Step 3: Approve the GitHub connection (one click)

```bash
terraform output -raw github_connection_console_url
```

Open it → `bmi-cicd-github` → **Update pending connection** → install the GitHub App for
`eks-argocd-3tier-cicd` → **Connect**. Status becomes **Available**.

## Step 4: Configure SonarQube

Give SonarQube 3–5 minutes after the apply. Then, from the project root:

```bash
cd ..
read -rsp "New SonarQube admin password (>=12 chars, upper/lower/digit/special): " P; echo
SONAR_HOST_URL=$(terraform -chdir=terraform output -raw sonarqube_url) \
SONAR_ADMIN_PASSWORD="$P" AWS_PROFILE=abip007home AWS_REGION=ap-south-1 \
  bash sonarqube/setup-sonarqube.sh
```

It changes the admin password, creates the project, the quality gate `bmi-cicd-gate` and the
`ci-pipeline` user, and writes that user's token into the secret. Terraform ignores later
changes to the secret's value (`ignore_changes`), so the next apply doesn't overwrite it.

## Step 5: Run the pipeline

```bash
aws codepipeline start-pipeline-execution --name bmi-cicd
terraform -chdir=terraform output -raw pipeline_console_url
```

Or push a change to `app/`. The run takes 10–15 minutes:

`Source → Test(UnitTests) → CodeQuality(SonarScan + SecurityScan → QualityGate) → Build(BuildPush) → Verify(SmokeTest)`

- **SecurityScan** (Trivy, parallel to SonarScan): dependency CVEs, committed secrets, and
  misconfig in Dockerfiles / `gitops/` / Terraform. Fails on secrets and on HIGH/CRITICAL CVEs
  that have a fix. Misconfig is report-only unless `TRIVY_MISCONFIG_GATE=true`.
- **BuildPush** scans each image with Trivy after `docker build`. An image with a fixable
  HIGH/CRITICAL CVE is **not pushed**.
- Accept a finding on purpose in [`.trivyignore`](../.trivyignore), with the reason.

When Verify is green, `https://cicd-bmi.bestclick.click` serves the new version, and Grafana's
**Live version** panel shows the same tag. From now on,
every push that touches `app/**`, `tests/**`, `pipeline/**` or `sonar-project.properties` runs it.

## Changing things later

| Change | How |
| --- | --- |
| Pipeline stages, trigger paths, CodeBuild settings | edit `.tf`, `terraform apply` |
| What a stage *does* (tests, Trivy rules, smoke checks) | edit `pipeline/stages/*.sh` or `pipeline/buildspec.yml` and push. No apply needed |
| Trivy version | `TRIVY_VERSION` + `TRIVY_SHA256` in `pipeline/stages/lib.sh` (from the release's checksums file) |
| Trivy threshold | `TRIVY_SEVERITY` / `TRIVY_MISCONFIG_GATE` as environment variables on the CodeBuild project |
| Node count / instance type | `node_*` variables, apply |
| Dashboards, alert rules | `gitops/observability/extras/` (JSON + PrometheusRule), push. Argo CD syncs it |
| Retention, volume sizes, alert receivers | `gitops/observability/*-values.yaml`, push |
| Observability chart versions | `targetRevision` in `gitops/argocd/apps/*.yaml`; keep `prometheus_operator_crds_chart_version` in step with kube-prometheus-stack |
| Rotate the GitHub token | `aws secretsmanager put-secret-value` (Terraform ignores the value after creation) |
| Your IP changed | update `admin_cidrs` (and `api_public_access_cidrs` if set), apply |
| Stop paying for SonarQube when idle | `aws ec2 stop-instances --instance-ids <id>`. The Elastic IP keeps the URL; start it before running the pipeline |

## Leftovers from an earlier console or CLI build

If the account already has `bmi-cicd` resources without Terraform state, `apply` fails with
"already exists". Add `import { to = ..., id = ... }` blocks for them (for example the approved
GitHub connection, which saves Step 3), plan, apply, then delete the import blocks.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `No value for required variable` / `Invalid number literal` at the prompt | Set the variable in `terraform.tfvars`. Lists need HCL syntax: `["1.2.3.4/32"]` |
| Helm release fails with x509 *not yet valid* | Your PC's clock is ahead of AWS: `w32tm /resync /force`, then apply again |
| `Error: Kubernetes cluster unreachable` | `aws` not on PATH, wrong `aws_profile`, or your IP isn't in `api_public_access_cidrs` |
| Hostname doesn't resolve, but the ALB works | More than one hosted zone with the same name: set `external_dns_zone_id` |
| First SmokeTest times out on `unreachable`, browser works | CodeBuild's resolver cached "no such name" from before the record existed. Retry the Verify stage |
| Grafana login fails | `grafana-admin` must exist before kube-prometheus-stack syncs (Terraform creates it first). Restart the Grafana deployment after changing it |

Everything else: the [console guide's table](01-console-guide.md#troubleshooting).

## Destroy

```bash
terraform -chdir=terraform destroy
```

`terraform_data.app_teardown` runs first: it deletes the Argo CD root app (and with it every
child app), the `bmi-cicd` namespace, the observability volumes (Prometheus, Alertmanager, Loki)
and every Ingress, while the LB Controller, EBS CSI driver and NAT gateway still run. So the ALB
and all EBS volumes are gone before the network is deleted. ECR repos and the artifact bucket are force-deleted with their
contents; the secret is deleted without a recovery window, so you can apply again at once.
Delete the `cicd-bmi`, `argocd-cicd` and `grafana-cicd` Route 53 records by hand (ExternalDNS is `upsert-only`).
