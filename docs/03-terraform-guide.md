# Build the pipeline with Terraform

[`terraform/`](../terraform) creates everything in one apply:

| File | Creates |
| --- | --- |
| `sonarqube.tf` | EC2 (Amazon Linux 2023, `sonarqube/user-data.sh`), Elastic IP, security group (your IP + CodeBuild ranges from `aws_ip_ranges`), SSM instance role |
| `ecr-secrets.tf` | ECR `bmi-cicd-backend` / `-frontend`, secret `bmi-cicd/ci` |
| `codebuild.tf` | CodeBuild project `bmi-cicd`, its role and log group |
| `codepipeline.tf` | GitHub connection, artifact bucket, pipeline role, pipeline `bmi-cicd` with trigger and 5 stages |
| `kubernetes.tf` | In the **existing** `argo-eks` cluster: namespace, DB secrets, Argo CD Application |

Terraform only reads the cluster (`data "aws_eks_cluster"`), so the eks-argocd-3tier state is never touched.

Before you start, finish the [Prerequisites](../README.md#prerequisites). You also need
`kubectl` access to `argo-eks` with the same profile, because Terraform uses `aws eks get-token`.

## Step 1: Variables

```bash
cd E:/devops/eks-argocd-3tier-cicd/terraform
cp terraform.tfvars.example terraform.tfvars
curl -s https://checkip.amazonaws.com          # put this IP into admin_cidrs as x.x.x.x/32
# edit terraform.tfvars: profile, repo, admin_cidrs ...

read -rsp "GitHub fine-grained token: " TF_VAR_github_token; echo; export TF_VAR_github_token
```

The token goes only into the Secrets Manager secret (and the Terraform state). Keep the state
private, or use the S3 backend that's commented out in `versions.tf`.

## Step 2: Apply

```bash
terraform init
terraform plan -out tf.plan
terraform apply tf.plan          # ~3 minutes
terraform output
```

The new pipeline starts a run at once. It **fails in Source** because the GitHub connection is
still pending. That's expected.

## Step 3: Approve the GitHub connection (one click in the console)

```bash
terraform output -raw github_connection_console_url
```

Open the URL → `bmi-cicd-github` → **Update pending connection** → install the GitHub App for
`eks-argocd-3tier-cicd` → **Connect**. Status becomes **Available**.

## Step 4: Configure SonarQube

Wait 3–5 minutes after the apply for SonarQube to start. Then:

```bash
cd ..        # project root
read -rsp "New SonarQube admin password (>=12 chars, upper/lower/digit/special): " P; echo
SONAR_HOST_URL=$(terraform -chdir=terraform output -raw sonarqube_url) \
SONAR_ADMIN_PASSWORD="$P" AWS_PROFILE=abip007 AWS_REGION=ap-south-1 \
  bash sonarqube/setup-sonarqube.sh
```

The script changes the admin password and creates the project, the quality gate
`bmi-cicd-gate` and the `ci-pipeline` user. It then writes that user's token into the secret.
Terraform ignores later changes to the secret value (`ignore_changes`), so the next
`terraform apply` doesn't overwrite the token.

## Step 5: Run the pipeline

The Argo CD Application already exists (from `kubernetes.tf`), so the app is up with the initial
images:

```bash
kubectl -n argocd get application bmi-cicd       # Synced / Healthy
```

Start a run:

```bash
aws codepipeline start-pipeline-execution --name bmi-cicd
terraform -chdir=terraform output -raw pipeline_console_url
```

Or push a change to `app/`. From now on, every push that touches `app/**`, `tests/**`,
`pipeline/**` or `sonar-project.properties` runs the pipeline.

## Changing things later

| Change | How |
| --- | --- |
| Pipeline stages, trigger paths, CodeBuild settings | edit `.tf`, `terraform apply` |
| What a stage *does* | edit `pipeline/stages/*.sh` or `pipeline/buildspec.yml` and push. No apply needed |
| Coverage threshold | `app/*/package.json` / `vite.config.js` and the gate in SonarQube (UI or script) |
| Rotate the GitHub token | `aws secretsmanager put-secret-value` (Terraform ignores the value after creation) |
| Your IP changed | update `admin_cidrs`, `terraform apply` |
| Stop paying for SonarQube when idle | `aws ec2 stop-instances --instance-ids <id>`. The Elastic IP keeps the URL; start it again before running the pipeline |

## Destroy

```bash
terraform -chdir=terraform destroy
```

The Argo CD Application has the resources finalizer. Destroying it makes Argo CD delete the pods
and the Ingress rule first. Then the namespace goes, and with it the Postgres PVC and EBS volume.
ECR repos and the artifact bucket are force-deleted with their contents. The secret is deleted
without a recovery window, so you can run `apply` again at once. Delete the Route 53 records for
`cicd-bmi` by hand, because ExternalDNS runs `upsert-only`.
