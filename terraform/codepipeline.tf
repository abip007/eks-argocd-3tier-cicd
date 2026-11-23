# The pipeline:
#   Source -> Test (UnitTests) -> CodeQuality (SonarScan + SecurityScan -> QualityGate)
#          -> Build (BuildPush: ECR + gitops commit) -> Verify (SmokeTest)

# ---------- GitHub connection ----------
# Created as PENDING. Finish it once in the console:
# Developer Tools > Settings > Connections > bmi-cicd-github > Update pending connection.
resource "aws_codestarconnections_connection" "github" {
  name          = "${var.name}-github"
  provider_type = "GitHub"
}

# ---------- Artifact bucket ----------
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name}-artifacts-${local.account_id}-${var.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

# ---------- Pipeline role ----------
resource "aws_iam_role" "pipeline" {
  name = "${var.name}-codepipeline"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "pipeline" {
  name = "${var.name}-codepipeline"
  role = aws_iam_role.pipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Artifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning", "s3:GetBucketLocation"]
        Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
      },
      {
        Sid      = "GitHubConnection"
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection", "codeconnections:UseConnection"]
        Resource = aws_codestarconnections_connection.github.arn
      },
      {
        Sid      = "RunBuilds"
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = aws_codebuild_project.ci.arn
      },
    ]
  })
}

# ---------- Pipeline ----------
locals {
  # CodeBuild action configuration for one stage script.
  build_action = { for stage, env in {
    "unit-test"     = {}
    "sonar-scan"    = { COMMIT_ID = "#{SourceVariables.CommitId}" }
    "security-scan" = {}
    "quality-gate"  = { SONAR_CE_TASK_ID = "#{SonarScan.SONAR_CE_TASK_ID}" }
    "build-push"    = { COMMIT_ID = "#{SourceVariables.CommitId}" }
    "smoke-test"    = { IMAGE_TAG = "#{Build.IMAGE_TAG}" }
    } : stage => {
    ProjectName = aws_codebuild_project.ci.name
    EnvironmentVariables = jsonencode([
      for k, v in merge({ STAGE = stage }, env) : { name = k, value = v, type = "PLAINTEXT" }
    ])
  } }
}

resource "aws_codepipeline" "this" {
  name           = var.name
  role_arn       = aws_iam_role.pipeline.arn
  pipeline_type  = "V2"
  execution_mode = "QUEUED" # one release at a time, in push order

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  # Start only for pushes to the branch that touch app code, tests or the
  # pipeline - not for the pipeline's own commit to gitops/.
  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches {
          includes = [var.git_branch]
        }
        file_paths {
          includes = var.trigger_paths
        }
      }
    }
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      namespace        = "SourceVariables"
      output_artifacts = ["SourceOutput"]
      configuration = {
        ConnectionArn        = aws_codestarconnections_connection.github.arn
        FullRepositoryId     = var.github_repo
        BranchName           = var.git_branch
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  stage {
    name = "Test"
    action {
      name            = "UnitTests"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["SourceOutput"]
      configuration   = local.build_action["unit-test"]
    }
  }

  stage {
    name = "CodeQuality"
    action {
      name            = "SonarScan"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      run_order       = 1
      namespace       = "SonarScan"
      input_artifacts = ["SourceOutput"]
      configuration   = local.build_action["sonar-scan"]
    }
    # Trivy: dependency CVEs, secrets, IaC misconfig. Runs in parallel with SonarScan.
    action {
      name            = "SecurityScan"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      run_order       = 1
      input_artifacts = ["SourceOutput"]
      configuration   = local.build_action["security-scan"]
    }
    action {
      name            = "QualityGate"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      run_order       = 2
      input_artifacts = ["SourceOutput"]
      configuration   = local.build_action["quality-gate"]
    }
  }

  stage {
    name = "Build"
    action {
      name            = "BuildPush"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      namespace       = "Build"
      input_artifacts = ["SourceOutput"]
      configuration   = local.build_action["build-push"]
    }
  }

  stage {
    name = "Verify"
    action {
      name            = "SmokeTest"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["SourceOutput"]
      configuration   = local.build_action["smoke-test"]
    }
  }
}
