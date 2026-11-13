# ECR repositories for the two images, and the pipeline's secret.

resource "aws_ecr_repository" "app" {
  for_each             = toset(["backend", "frontend"])
  name                 = "${var.name}-${each.key}"
  image_tag_mutability = "IMMUTABLE" # a tag in Git always means the same image
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each   = aws_ecr_repository.app
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# One secret, two keys: github_token (from var.github_token) and sonar_token
# (written later by sonarqube/setup-sonarqube.sh). Terraform sets the first
# version only, then leaves the value alone so the script's token survives.
resource "aws_secretsmanager_secret" "ci" {
  name                    = "${var.name}/ci"
  description             = "CI secrets for the ${var.name} pipeline"
  recovery_window_in_days = 0 # allow re-creating the same name right after destroy
}

resource "aws_secretsmanager_secret_version" "ci" {
  secret_id = aws_secretsmanager_secret.ci.id
  secret_string = jsonencode({
    github_token = var.github_token
    sonar_token  = "set-by-sonarqube/setup-sonarqube.sh"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
