# Build everything from the command line (step by step)

The same result as the [console guide](01-console-guide.md) and [Terraform](03-terraform-guide.md),
with `aws`, `eksctl`, `kubectl` and `helm`: the EKS cluster and its VPC, the platform (Load
Balancer Controller, ExternalDNS, Argo CD), the app, SonarQube, and the CodePipeline with unit
tests, SonarQube, Trivy and smoke tests.

Run everything in **Git Bash** from the project root. Longer JSON documents are templates in
[`cli/`](../cli); `render <file>` fills in your values and writes them to `cli/.out/`. IDs you'll
need again are appended to `cli/ids.env` (gitignored). In a new terminal, run
`source cli/config.env; source cli/ids.env`.

**Tools:** AWS CLI v2, `eksctl` (`winget install eksctl`), `kubectl`, `helm` 3, `envsubst`
(ships with Git for Windows), `curl`, `openssl`. Docker is not needed: images are built by CodeBuild.

Before you start, finish the [Prerequisites](../README.md#prerequisites). The order is the same
as in the console guide: platform → app → pipeline, because creating the pipeline starts a run
and its smoke test needs the app.

---

## Step 0: Settings

```bash
cd C:/DevOps/eks-argocd-3tier-cicd
# edit cli/config.env first if your values differ (profile, cluster, hosts, repo)
source cli/config.env
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="$NAME-artifacts-$ACCOUNT_ID-$AWS_REGION"
echo "export ACCOUNT_ID=$ACCOUNT_ID BUCKET=$BUCKET" > cli/ids.env
echo "account $ACCOUNT_ID  region $AWS_REGION  profile $AWS_PROFILE  cluster $CLUSTER"
```

Account ID, certificate ARN and Route 53 zone ID are written into a few files. Check that they
match yours (README → *Your values*): `eksctl/cluster.yaml` (2 policy ARNs),
`platform/argocd-values.yaml`, `platform/external-dns-values.yaml`, and the overlay
`gitops/bmi-cicd/overlays/prod/kustomization.yaml`.

```bash
aws acm list-certificates --certificate-statuses ISSUED \
  --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn" --output text
nslookup -type=ns "$DOMAIN" 8.8.8.8 | grep nameserver           # registrar's name servers
aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
  --query "HostedZones[?Name=='$DOMAIN.'].Id" --output text      # exactly one zone, please
```

> Windows `curl` (schannel) may fail with `CRYPT_E_NO_REVOCATION_CHECK`. Add `--ssl-no-revoke` if it does.

---

# Part A: Platform

## Step 1: EKS cluster (eksctl, ~20 minutes)

### 1.1 IAM policies for the controllers

```bash
for p in lbc:aws-load-balancer-controller external-dns:external-dns; do
  aws iam create-policy --policy-name "$CLUSTER-${p%%:*}" \
    --policy-document "file://policies/${p#*:}.json" --query Policy.Arn --output text
done
```

### 1.2 Cluster

[`eksctl/cluster.yaml`](../eksctl/cluster.yaml) creates the VPC (`10.2.0.0/16`, 3 public + 3
private subnets already tagged for ALBs, one NAT gateway), the control plane, the add-ons
(VPC CNI with network policy, kube-proxy, CoreDNS, Pod Identity agent, metrics-server, EBS CSI),
the Pod Identity associations for the two controllers, and a node group of 2 × m7i-flex.large
in the private subnets.

```bash
eksctl create cluster -f eksctl/cluster.yaml
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"
kubectl get nodes                                  # 2 nodes, Ready
```

---

## Step 2: Platform (Helm)

The LB Controller's webhook certificate is signed with **your PC's clock**. If it runs ahead of
AWS, later installs fail with x509 *not yet valid*. Check first:

```bash
AWS_DATE=$(curl -sI "https://sts.$AWS_REGION.amazonaws.com" | tr -d '\r' | awk -F': ' 'tolower($1)=="date"{print $2}')
echo "skew: $(( $(date -u +%s) - $(date -u -d "$AWS_DATE" +%s) ))s"   # must be within ±5 s
# fix (admin PowerShell): Start-Service w32time; w32tm /resync /force
```

```bash
mkdir -p .helm/cache
# 2.1 Default StorageClass gp3
kubectl apply -f platform/storageclass-gp3.yaml
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite 2>/dev/null || true

# 2.2 Gateway API CRDs + AWS Load Balancer Controller
kubectl apply --server-side --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.6.0/config/crd/gateway/gateway-crds.yaml
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --query cluster.resourcesVpcConfig.vpcId --output text)
echo "export VPC_ID=$VPC_ID" >> cli/ids.env
helm upgrade --install aws-load-balancer-controller aws-load-balancer-controller \
  --repo https://aws.github.io/eks-charts -n kube-system \
  --set clusterName="$CLUSTER" --set region="$AWS_REGION" --set vpcId="$VPC_ID" \
  --set serviceAccount.name=aws-load-balancer-controller --wait --timeout 10m

# 2.3 ExternalDNS
helm upgrade --install external-dns external-dns \
  --repo https://kubernetes-sigs.github.io/external-dns/ -n external-dns --create-namespace \
  -f platform/external-dns-values.yaml --wait

# 2.4 Argo CD
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm -n argocd --create-namespace \
  -f platform/argocd-values.yaml --wait --timeout 15m

kubectl -n argocd get ingress                      # ADDRESS after ~2 min
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

Argo CD UI: `https://$ARGOCD_HOST`, user `admin`, the password above.

---

# Part B: The app

## Step 3: Secrets and the Argo CD Application

```bash
kubectl create namespace "$NAME"
DB_PASS=$(openssl rand -hex 16)          # hex = safe inside DATABASE_URL
kubectl -n "$NAME" create secret generic postgres-secret \
  --from-literal=POSTGRES_DB=bmidb --from-literal=POSTGRES_USER=bmi_user \
  --from-literal=POSTGRES_PASSWORD="$DB_PASS"
kubectl -n "$NAME" create secret generic backend-secret \
  --from-literal=DATABASE_URL="postgres://bmi_user:$DB_PASS@bmi-postgres-svc:5432/bmidb"
unset DB_PASS

kubectl apply -f gitops/argocd/bmi-cicd-app.yaml
kubectl -n argocd get application "$NAME"          # Synced; pods come up below
kubectl -n "$NAME" get pods,ingress
```

Postgres starts now. Backend and frontend stay in **ImagePullBackOff** until the pipeline's
first BuildPush pushes images (Step 13). That's expected on a fresh account.

---

# Part C: Pipeline

## Step 4: ECR repositories

```bash
for c in backend frontend; do
  aws ecr create-repository --repository-name "$NAME-$c" \
    --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true \
    --query repository.repositoryUri --output text
  aws ecr put-lifecycle-policy --repository-name "$NAME-$c" --lifecycle-policy-text \
    '{"rules":[{"rulePriority":1,"description":"Keep the last 20 images","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":20},"action":{"type":"expire"}}]}' >/dev/null
done
```

---

## Step 5: Pipeline secret

```bash
read -rsp "GitHub fine-grained token: " GH_TOKEN; echo
aws secretsmanager create-secret --name "$NAME/ci" \
  --description "CI secrets for the $NAME pipeline" \
  --secret-string "{\"github_token\":\"$GH_TOKEN\",\"sonar_token\":\"placeholder\"}" \
  --query ARN --output text
unset GH_TOKEN
```

`sonar_token` gets its real value in Step 7.

---

## Step 6: SonarQube server (EC2 in the cluster's VPC)

### 6.1 Instance role (Session Manager, no SSH)

```bash
aws iam create-role --role-name "$NAME-sonarqube-ec2" \
  --assume-role-policy-document file://cli/trust-ec2.json --query Role.Arn --output text
aws iam attach-role-policy --role-name "$NAME-sonarqube-ec2" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name "$NAME-sonarqube-ec2" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$NAME-sonarqube-ec2" \
  --role-name "$NAME-sonarqube-ec2"
```

### 6.2 Security group: port 9000 for you and CodeBuild

```bash
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=$VPC_ID Name=tag:kubernetes.io/role/elb,Values=1 \
  --query 'Subnets[0].SubnetId' --output text)        # a public subnet made by eksctl
SG_ID=$(aws ec2 create-security-group --group-name "$NAME-sonarqube" \
  --description "SonarQube UI/API: admin IPs + CodeBuild" --vpc-id "$VPC_ID" --query GroupId --output text)
echo "export SG_ID=$SG_ID SUBNET_ID=$SUBNET_ID" >> cli/ids.env

MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=9000,ToPort=9000,IpRanges=[{CidrIp=$MY_IP/32,Description=admins}]" >/dev/null

CB_CIDRS=$(curl -s https://ip-ranges.amazonaws.com/ip-ranges.json \
  | awk -F'"' -v R="$AWS_REGION" '/"ip_prefix"/{p=$4} /"region"/{r=$4} /"service": "CODEBUILD"/{if (r==R) print p}')
echo "CodeBuild ranges: $CB_CIDRS"
for c in $CB_CIDRS; do
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=9000,ToPort=9000,IpRanges=[{CidrIp=$c,Description=codebuild}]" >/dev/null
done
```

### 6.3 Instance + Elastic IP

```bash
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
sleep 10   # a new instance profile needs a few seconds
INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$SONAR_INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
  --iam-instance-profile Name="$NAME-sonarqube-ec2" --metadata-options HttpTokens=required \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,Encrypted=true}' \
  --user-data file://sonarqube/user-data.sh \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME-sonarqube}]" \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

ALLOC_ID=$(aws ec2 allocate-address --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$NAME-sonarqube}]" \
  --query AllocationId --output text)
aws ec2 associate-address --allocation-id "$ALLOC_ID" --instance-id "$INSTANCE_ID" >/dev/null
EIP=$(aws ec2 describe-addresses --allocation-ids "$ALLOC_ID" --query 'Addresses[0].PublicIp' --output text)
export SONAR_HOST_URL="http://$EIP:9000"
echo "export INSTANCE_ID=$INSTANCE_ID ALLOC_ID=$ALLOC_ID SONAR_HOST_URL=$SONAR_HOST_URL" >> cli/ids.env
echo "SonarQube: $SONAR_HOST_URL (ready in 3-5 minutes)"
```

---

## Step 7: Configure SonarQube

[`sonarqube/setup-sonarqube.sh`](../sonarqube/setup-sonarqube.sh) waits until SonarQube is up, then
replaces `admin/admin` with your password, creates project `bmi-cicd`, the gate `bmi-cicd-gate`
(new-code conditions plus whole-code coverage ≥ 80%, duplication ≤ 3%, A ratings), the user
`ci-pipeline` (Browse + Execute Analysis), and writes its token into `bmi-cicd/ci`. Safe to re-run.

```bash
read -rsp "New SonarQube admin password (>=12 chars, upper/lower/digit/special): " SONAR_ADMIN_PASSWORD; echo
SONAR_ADMIN_PASSWORD="$SONAR_ADMIN_PASSWORD" bash sonarqube/setup-sonarqube.sh
```

---

## Step 8: GitHub connection

```bash
CONNECTION_ARN=$(aws codeconnections create-connection --provider-type GitHub \
  --connection-name "$NAME-github" --query ConnectionArn --output text)
echo "export CONNECTION_ARN=$CONNECTION_ARN" >> cli/ids.env
echo "https://$AWS_REGION.console.aws.amazon.com/codesuite/settings/connections?region=$AWS_REGION"
```

**One click in the console:** open the URL → `bmi-cicd-github` → **Update pending connection** →
install the GitHub App for `eks-argocd-3tier-cicd` → **Connect**. Then:

```bash
aws codeconnections get-connection --connection-arn "$CONNECTION_ARN" --query Connection.ConnectionStatus   # "AVAILABLE"
```

---

## Step 9: Artifact bucket and log group

```bash
aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration \
  '{"Rules":[{"ID":"expire-old-artifacts","Status":"Enabled","Filter":{},"Expiration":{"Days":30}}]}'

MSYS_NO_PATHCONV=1 aws logs create-log-group --log-group-name "/codebuild/$NAME"
MSYS_NO_PATHCONV=1 aws logs put-retention-policy --log-group-name "/codebuild/$NAME" --retention-in-days 30
```

(`MSYS_NO_PATHCONV=1` stops Git Bash from turning `/codebuild/...` into a Windows path.)

---

## Step 10: IAM roles for CodeBuild and CodePipeline

```bash
source cli/config.env; source cli/ids.env    # render needs every value set so far

aws iam create-role --role-name "$NAME-codebuild" \
  --assume-role-policy-document file://$(render trust-codebuild.json) --query Role.Arn --output text
aws iam put-role-policy --role-name "$NAME-codebuild" --policy-name "$NAME-codebuild" \
  --policy-document file://$(render codebuild-policy.json)

aws iam create-role --role-name "$NAME-codepipeline" \
  --assume-role-policy-document file://$(render trust-codepipeline.json) --query Role.Arn --output text
aws iam put-role-policy --role-name "$NAME-codepipeline" --policy-name "$NAME-codepipeline" \
  --policy-document file://$(render codepipeline-policy.json)
sleep 10   # let IAM propagate
```

[`cli/codebuild-policy.json`](../cli/codebuild-policy.json): its log group, the artifact bucket,
pushing to the two ECR repos, reading `bmi-cicd/ci`, writing test reports.
[`cli/codepipeline-policy.json`](../cli/codepipeline-policy.json): the artifact bucket, the GitHub
connection, starting the one CodeBuild project.

---

## Step 11: CodeBuild project

```bash
aws codebuild create-project --cli-input-json file://$(render codebuild-project.json) \
  --query project.arn --output text
```

One project serves all six actions. Each sets `STAGE`, and
[`pipeline/buildspec.yml`](../pipeline/buildspec.yml) runs `pipeline/stages/$STAGE.sh`.

---

## Step 12: The pipeline

```bash
aws codepipeline create-pipeline --cli-input-json file://$(render pipeline.json) \
  --query pipeline.name --output text
```

[`cli/pipeline.json`](../cli/pipeline.json):
- **V2**, **QUEUED** mode (one release at a time)
- **trigger**: push to `main` touching `app/**`, `pipeline/**`, `tests/**`, `sonar-project.properties`.
  `gitops/**` is left out, so the pipeline's own tag commit doesn't start it again.
- **stages**: Source → Test(UnitTests) → CodeQuality(**SonarScan + SecurityScan** in parallel → QualityGate)
  → Build(BuildPush) → Verify(SmokeTest)
- **variables**: `#{SourceVariables.CommitId}`, `#{SonarScan.SONAR_CE_TASK_ID}`, `#{Build.IMAGE_TAG}`

Creating the pipeline starts the first run.

---

## Step 13: Watch it

```bash
while :; do
  clear; date
  aws codepipeline get-pipeline-state --name "$NAME" \
    --query 'stageStates[].[stageName, latestExecution.status]' --output table
  sleep 20
done
```

Logs of the newest build (for example the Trivy or quality gate output):

```bash
BUILD_ID=$(aws codebuild list-builds-for-project --project-name "$NAME" --query 'ids[0]' --output text)
MSYS_NO_PATHCONV=1 aws logs tail "/codebuild/$NAME" --log-stream-name-prefix "${BUILD_ID#*:}" --since 1h
```

When Verify is green: `curl -s https://$APP_HOST/api/health` shows the released `version`.
From now on, every push that touches `app/` runs the pipeline.

**Trivy** runs twice: `SecurityScan` scans the repo (dependency CVEs, secrets, misconfig in
Dockerfiles / `gitops/` / Terraform), and `BuildPush` scans each image before it's pushed. Both
fail on HIGH/CRITICAL CVEs **that have a fix**; misconfig is report-only unless
`TRIVY_MISCONFIG_GATE=true`. Accept a finding in [`.trivyignore`](../.trivyignore) with a reason.
Run the repo scan locally with `bash pipeline/stages/security-scan.sh` (Linux/WSL/CodeBuild image).

---

## Troubleshooting

Causes and fixes are in the [console guide's table](01-console-guide.md#troubleshooting). Useful commands:

```bash
aws codepipeline list-action-executions --pipeline-name "$NAME" --max-items 6 \
  --query 'actionExecutionDetails[].[actionName,status,output.executionResult.externalExecutionSummary]' --output table
aws codepipeline retry-stage-execution --pipeline-name "$NAME" --stage-name Verify \
  --pipeline-execution-id <id> --retry-mode FAILED_ACTIONS      # e.g. smoke test hit cached DNS
aws ssm start-session --target "$INSTANCE_ID"                    # shell on SonarQube (SSM plugin)
kubectl -n "$NAME" get pods,ingress; kubectl -n argocd get application "$NAME"
kubectl -n external-dns logs deploy/external-dns --tail=20
```

---

## Clean up

```bash
source cli/config.env; source cli/ids.env
# 1. App first, so the ALB and the EBS volume go away while the controllers still run
kubectl -n argocd delete application "$NAME" --wait
kubectl delete namespace "$NAME"
helm -n argocd uninstall argocd; sleep 60                       # last Ingress -> ALB deleted
helm -n external-dns uninstall external-dns
helm -n kube-system uninstall aws-load-balancer-controller

# 2. Pipeline
aws codepipeline delete-pipeline --name "$NAME"
aws codebuild delete-project --name "$NAME"
for g in $(aws codebuild list-report-groups --query "reportGroups[?contains(@, ':report-group/$NAME-')]" --output text); do
  aws codebuild delete-report-group --arn "$g" --delete-reports; done
aws codeconnections delete-connection --connection-arn "$CONNECTION_ARN"
aws s3 rm "s3://$BUCKET" --recursive && aws s3api delete-bucket --bucket "$BUCKET"
MSYS_NO_PATHCONV=1 aws logs delete-log-group --log-group-name "/codebuild/$NAME"
for c in backend frontend; do aws ecr delete-repository --repository-name "$NAME-$c" --force >/dev/null; done
aws secretsmanager delete-secret --secret-id "$NAME/ci" --force-delete-without-recovery >/dev/null

# 3. SonarQube (must go before the VPC)
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
aws ec2 release-address --allocation-id "$ALLOC_ID"
aws ec2 delete-security-group --group-id "$SG_ID"

# 4. Cluster + VPC (eksctl deletes what it created)
eksctl delete cluster -f eksctl/cluster.yaml --wait

# 5. IAM
for r in codebuild codepipeline; do
  aws iam delete-role-policy --role-name "$NAME-$r" --policy-name "$NAME-$r"; aws iam delete-role --role-name "$NAME-$r"; done
aws iam remove-role-from-instance-profile --instance-profile-name "$NAME-sonarqube-ec2" --role-name "$NAME-sonarqube-ec2"
aws iam delete-instance-profile --instance-profile-name "$NAME-sonarqube-ec2"
aws iam detach-role-policy --role-name "$NAME-sonarqube-ec2" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name "$NAME-sonarqube-ec2"
for p in lbc external-dns; do aws iam delete-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/$CLUSTER-$p"; done
rm -f cli/ids.env; rm -rf cli/.out
```

Route 53: delete the `cicd-bmi` and `argocd-cicd` records by hand (ExternalDNS is `upsert-only`).
