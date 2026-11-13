# Build the pipeline from the command line (step by step)

The same result as the console guide and Terraform, with the AWS CLI. Run everything in
**Git Bash** from the project root (`E:/devops/eks-argocd-3tier-cicd`). The longer JSON
documents are templates in [`cli/`](../cli). `render <file>` fills in your values and writes
them to `cli/.out/`.

IDs you'll need again are appended to `cli/ids.env` (gitignored). If you open a new terminal,
run `source cli/config.env; source cli/ids.env`.

Before you start, finish the [Prerequisites](../README.md#prerequisites).

---

## Step 0: Settings

```bash
cd E:/devops/eks-argocd-3tier-cicd
# edit cli/config.env first if your values differ
source cli/config.env
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="$NAME-artifacts-$ACCOUNT_ID-$AWS_REGION"
echo "export ACCOUNT_ID=$ACCOUNT_ID BUCKET=$BUCKET" > cli/ids.env
echo "account $ACCOUNT_ID  region $AWS_REGION  profile $AWS_PROFILE"
```

> Windows `curl` (schannel) may fail with `CRYPT_E_NO_REVOCATION_CHECK`. If it does, add `--ssl-no-revoke`.

---

## Step 1: ECR repositories

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

## Step 2: Secret for the pipeline

```bash
read -rsp "GitHub fine-grained token: " GH_TOKEN; echo
aws secretsmanager create-secret --name "$NAME/ci" \
  --description "CI secrets for the $NAME pipeline" \
  --secret-string "{\"github_token\":\"$GH_TOKEN\",\"sonar_token\":\"placeholder\"}" \
  --query ARN --output text
unset GH_TOKEN
```

`sonar_token` gets its real value in Step 4.

---

## Step 3: SonarQube server (EC2)

### 3.1 Instance role (Session Manager, no SSH)

```bash
aws iam create-role --role-name "$NAME-sonarqube-ec2" \
  --assume-role-policy-document file://cli/trust-ec2.json --query Role.Arn --output text
aws iam attach-role-policy --role-name "$NAME-sonarqube-ec2" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name "$NAME-sonarqube-ec2" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$NAME-sonarqube-ec2" \
  --role-name "$NAME-sonarqube-ec2"
```

### 3.2 Security group: port 9000 for you and for CodeBuild

```bash
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text)
SG_ID=$(aws ec2 create-security-group --group-name "$NAME-sonarqube" \
  --description "SonarQube UI/API: admin IPs + CodeBuild" --vpc-id "$VPC_ID" --query GroupId --output text)
echo "export SG_ID=$SG_ID SUBNET_ID=$SUBNET_ID" >> cli/ids.env

MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=9000,ToPort=9000,IpRanges=[{CidrIp=$MY_IP/32,Description=admins}]" >/dev/null

# CodeBuild's published ranges for this region (no jq needed)
CB_CIDRS=$(curl -s https://ip-ranges.amazonaws.com/ip-ranges.json \
  | awk -F'"' -v R="$AWS_REGION" '/"ip_prefix"/{p=$4} /"region"/{r=$4} /"service": "CODEBUILD"/{if (r==R) print p}')
echo "CodeBuild ranges: $CB_CIDRS"
for c in $CB_CIDRS; do
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=9000,ToPort=9000,IpRanges=[{CidrIp=$c,Description=codebuild}]" >/dev/null
done
```

### 3.3 Launch the instance, attach an Elastic IP

```bash
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)
sleep 10   # a brand-new instance profile takes a few seconds to become usable
INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$SONAR_INSTANCE_TYPE" \
  --subnet-id "$SUBNET_ID" --security-group-ids "$SG_ID" \
  --iam-instance-profile Name="$NAME-sonarqube-ec2" \
  --metadata-options HttpTokens=required \
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

## Step 4: Configure SonarQube (project, quality gate, CI user, token)

[`sonarqube/setup-sonarqube.sh`](../sonarqube/setup-sonarqube.sh) waits until SonarQube is up, then:
1. replaces `admin/admin` with your password
2. creates project `bmi-cicd`
3. creates gate `bmi-cicd-gate`: SonarQube's new-code conditions plus whole-code coverage ≥ 80%,
   duplication ≤ 3% and A ratings
4. creates user `ci-pipeline` with Browse + Execute Analysis
5. writes its token into `bmi-cicd/ci` → `sonar_token`

```bash
read -rsp "New SonarQube admin password (>=12 chars, upper/lower/digit/special): " SONAR_ADMIN_PASSWORD; echo
SONAR_ADMIN_PASSWORD="$SONAR_ADMIN_PASSWORD" bash sonarqube/setup-sonarqube.sh
```

Open `$SONAR_HOST_URL`, log in as `admin`, and look at **Quality Gates → bmi-cicd-gate**.

---

## Step 5: GitHub connection

```bash
CONNECTION_ARN=$(aws codeconnections create-connection --provider-type GitHub \
  --connection-name "$NAME-github" --query ConnectionArn --output text)
echo "export CONNECTION_ARN=$CONNECTION_ARN" >> cli/ids.env
echo "https://$AWS_REGION.console.aws.amazon.com/codesuite/settings/connections?region=$AWS_REGION"
```

**This step needs the console.** Open the URL → `bmi-cicd-github` → **Update pending connection** →
install the GitHub App for `eks-argocd-3tier-cicd` → **Connect**. Then check:

```bash
aws codeconnections get-connection --connection-arn "$CONNECTION_ARN" --query Connection.ConnectionStatus
# "AVAILABLE"
```

---

## Step 6: Artifact bucket and log group

```bash
aws s3api create-bucket --bucket "$BUCKET" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration \
  '{"Rules":[{"ID":"expire-old-artifacts","Status":"Enabled","Filter":{},"Expiration":{"Days":30}}]}'

aws logs create-log-group --log-group-name "/codebuild/$NAME"
aws logs put-retention-policy --log-group-name "/codebuild/$NAME" --retention-in-days 30
```

---

## Step 7: IAM roles for CodeBuild and CodePipeline

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
sleep 10   # let IAM propagate before CodeBuild checks the role
```

What the policies allow: [`cli/codebuild-policy.json`](../cli/codebuild-policy.json) covers its
log group, the artifact bucket, pushing to the two ECR repos, reading `bmi-cicd/ci`, and writing
test reports. [`cli/codepipeline-policy.json`](../cli/codepipeline-policy.json) covers the
artifact bucket, the GitHub connection, and starting the one CodeBuild project.

---

## Step 8: CodeBuild project

```bash
aws codebuild create-project --cli-input-json file://$(render codebuild-project.json) \
  --query project.arn --output text
```

One project serves all five actions. Each action sets `STAGE`, and
[`pipeline/buildspec.yml`](../pipeline/buildspec.yml) runs `pipeline/stages/$STAGE.sh`.

---

## Step 9: The pipeline

```bash
aws codepipeline create-pipeline --cli-input-json file://$(render pipeline.json) \
  --query pipeline.name --output text
```

[`cli/pipeline.json`](../cli/pipeline.json) defines the following:
- **V2** pipeline in **QUEUED** mode
- **trigger**: push to `main` touching `app/**`, `pipeline/**`, `tests/**` or
  `sonar-project.properties`. `gitops/**` is left out, so the pipeline's own tag commit doesn't
  start it again.
- **stages**: Source → Test(UnitTests) → CodeQuality(SonarScan → QualityGate) → Build(BuildPush) → Verify(SmokeTest)
- **variables**: `#{SourceVariables.CommitId}`, `#{SonarScan.SONAR_CE_TASK_ID}` and `#{Build.IMAGE_TAG}` pass values between actions

Creating the pipeline starts a first run straight away. Do Step 10 while it runs. The SmokeTest
action waits up to 15 minutes for the app. If it times out anyway, click **Retry** on the stage
in the console, or run Step 11.

---

## Step 10: The app in the cluster

```bash
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION"
kubectl create namespace "$NAME"

DB_PASS=$(openssl rand -hex 16)
kubectl -n "$NAME" create secret generic postgres-secret \
  --from-literal=POSTGRES_DB=bmidb --from-literal=POSTGRES_USER=bmi_user \
  --from-literal=POSTGRES_PASSWORD="$DB_PASS"
kubectl -n "$NAME" create secret generic backend-secret \
  --from-literal=DATABASE_URL="postgres://bmi_user:$DB_PASS@bmi-postgres-svc:5432/bmidb"
unset DB_PASS

kubectl apply -f gitops/argocd/bmi-cicd-app.yaml
kubectl -n argocd get application "$NAME" -w        # Synced + Healthy, Ctrl+C
curl -s "https://$APP_HOST/" | grep -o '<title>.*</title>'
```

---

## Step 11: Run it and watch

```bash
aws codepipeline start-pipeline-execution --name "$NAME" --query pipelineExecutionId --output text

# stage-by-stage status, refresh every 20 s (Ctrl+C to stop)
while :; do
  clear; date
  aws codepipeline get-pipeline-state --name "$NAME" \
    --query 'stageStates[].[stageName, latestExecution.status, actionStates[0].latestExecution.summary]' --output table
  sleep 20
done
```

Logs of one stage (for example the quality gate table):

```bash
BUILD_ID=$(aws codebuild list-builds-for-project --project-name "$NAME" --query 'ids[0]' --output text)
aws logs tail "/codebuild/$NAME" --log-stream-name-prefix "${BUILD_ID#*:}" --since 1h
```

From now on, a `git push` that touches `app/` runs the pipeline on its own.

---

## Troubleshooting

See the table in the [console guide](01-console-guide.md#troubleshooting). It has the same causes and fixes.
Useful commands:

```bash
aws codepipeline list-action-executions --pipeline-name "$NAME" --max-items 5 \
  --query 'actionExecutionDetails[].[actionName,status,output.executionResult.externalExecutionSummary]' --output table
aws ssm start-session --target "$INSTANCE_ID"        # shell on the SonarQube box (needs the SSM plugin)
kubectl -n "$NAME" get pods,ingress; kubectl -n argocd get application "$NAME"
```

---

## Clean up

```bash
source cli/config.env; source cli/ids.env
kubectl -n argocd delete application "$NAME" --wait      # pods + Ingress rule
kubectl delete namespace "$NAME"                          # PVC -> EBS volume

aws codepipeline delete-pipeline --name "$NAME"
aws codebuild delete-project --name "$NAME"
for g in $(aws codebuild list-report-groups --query "reportGroups[?contains(@, ':report-group/$NAME-')]" --output text); do
  aws codebuild delete-report-group --arn "$g" --delete-reports; done
aws codeconnections delete-connection --connection-arn "$CONNECTION_ARN"
aws s3 rm "s3://$BUCKET" --recursive && aws s3api delete-bucket --bucket "$BUCKET"
aws logs delete-log-group --log-group-name "/codebuild/$NAME"

aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
aws ec2 release-address --allocation-id "$ALLOC_ID"
aws ec2 delete-security-group --group-id "$SG_ID"

for c in backend frontend; do aws ecr delete-repository --repository-name "$NAME-$c" --force >/dev/null; done
aws secretsmanager delete-secret --secret-id "$NAME/ci" --force-delete-without-recovery >/dev/null

aws iam delete-role-policy --role-name "$NAME-codebuild" --policy-name "$NAME-codebuild"
aws iam delete-role --role-name "$NAME-codebuild"
aws iam delete-role-policy --role-name "$NAME-codepipeline" --policy-name "$NAME-codepipeline"
aws iam delete-role --role-name "$NAME-codepipeline"
aws iam remove-role-from-instance-profile --instance-profile-name "$NAME-sonarqube-ec2" --role-name "$NAME-sonarqube-ec2"
aws iam delete-instance-profile --instance-profile-name "$NAME-sonarqube-ec2"
aws iam detach-role-policy --role-name "$NAME-sonarqube-ec2" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name "$NAME-sonarqube-ec2"
rm -f cli/ids.env; rm -rf cli/.out
```

The Route 53 records `cicd-bmi` (A + TXT) stay, because ExternalDNS runs `upsert-only`. Delete them in Route 53.
