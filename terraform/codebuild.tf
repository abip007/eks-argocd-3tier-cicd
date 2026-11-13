# One CodeBuild project used by all five pipeline actions. Each action sets
# STAGE; pipeline/buildspec.yml runs pipeline/stages/$STAGE.sh.

resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/codebuild/${var.name}"
  retention_in_days = 30
}

resource "aws_iam_role" "codebuild" {
  name = "${var.name}-codebuild"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "${var.name}-codebuild"
  role = aws_iam_role.codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.codebuild.arn}:*"
      },
      {
        Sid      = "PipelineArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
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
        Sid      = "Secret"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.ci.arn
      },
      {
        Sid    = "TestReports"
        Effect = "Allow"
        Action = [
          "codebuild:CreateReportGroup", "codebuild:CreateReport", "codebuild:UpdateReport",
          "codebuild:BatchPutTestCases", "codebuild:BatchPutCodeCoverages",
        ]
        Resource = "arn:${local.partition}:codebuild:${var.region}:${local.account_id}:report-group/${var.name}-*"
      },
    ]
  })
}

resource "aws_codebuild_project" "ci" {
  name          = var.name
  description   = "Unit tests, SonarQube, quality gate, image build, smoke test (STAGE picks one)"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30 # minutes; the smoke test waits up to 15 for Argo CD

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "pipeline/buildspec.yml"
  }

  environment {
    compute_type    = var.codebuild_compute_type
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true # docker build in the BuildPush stage

    environment_variable {
      name  = "SONAR_HOST_URL"
      value = local.sonar_host_url
    }
    environment_variable {
      name  = "SONAR_PROJECT_KEY"
      value = var.name
    }
    environment_variable {
      name  = "ECR_PREFIX"
      value = var.name
    }
    environment_variable {
      name  = "GITHUB_REPO"
      value = var.github_repo
    }
    environment_variable {
      name  = "GIT_BRANCH"
      value = var.git_branch
    }
    environment_variable {
      name  = "APP_URL"
      value = "https://${var.app_host}"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild.name
    }
  }
}
