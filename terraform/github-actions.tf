# AWS access for the GitHub Actions workflow (.github/workflows/ci-cd.yml).
# No access keys: GitHub's OIDC token is exchanged for this role, and only
# workflow runs on the main branch of var.github_repo can assume it.
#
# The role can: push to the two ECR repos, read the bmi-cicd/ci secret
# (sonar_token), and add/remove its own runner IP on the SonarQube SG.

variable "github_oidc_provider_arn" {
  description = "ARN of an existing token.actions.githubusercontent.com OIDC provider in this account. Empty = create one (an account can only have one)."
  type        = string
  default     = ""
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.github_oidc_provider_arn == "" ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  github_oidc_provider_arn = var.github_oidc_provider_arn != "" ? var.github_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_role" "github_actions" {
  name = "${var.name}-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/${var.git_branch}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions" {
  name = "${var.name}-github-actions"
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage",
        ]
        Resource = [for r in aws_ecr_repository.app : r.arn]
      },
      {
        Sid      = "SonarToken"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.ci.arn
      },
      {
        Sid      = "SonarQubeRunnerAccess"
        Effect   = "Allow"
        Action   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
        Resource = "arn:${local.partition}:ec2:${var.region}:${local.account_id}:security-group/${aws_security_group.sonarqube.id}"
      },
    ]
  })
}

output "github_actions_variables" {
  description = "Set these as GitHub repo variables (Settings > Secrets and variables > Actions > Variables)."
  value = {
    AWS_ROLE_ARN    = aws_iam_role.github_actions.arn
    AWS_REGION      = var.region
    SONAR_HOST_URL  = local.sonar_host_url
    SONARQUBE_SG_ID = aws_security_group.sonarqube.id
    APP_URL         = "https://${var.app_host}"
  }
}
