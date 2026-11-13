# ---------- General ----------
variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile. null = default credential chain."
  type        = string
  default     = "abip007"
}

variable "name" {
  description = "Prefix for every resource: pipeline, CodeBuild project, ECR repos (<name>-backend), secret (<name>/ci), namespace."
  type        = string
  default     = "bmi-cicd"
}

variable "tags" {
  type = map(string)
  default = {
    "managed-by" = "terraform"
    "project"    = "eks-argocd-3tier-cicd"
  }
}

# ---------- Existing platform (from eks-argocd-3tier) ----------
variable "cluster_name" {
  description = "Existing EKS cluster with Argo CD, LB Controller and ExternalDNS installed."
  type        = string
  default     = "argo-eks"
}

variable "app_host" {
  description = "Public hostname of this app. Must equal the Ingress host in gitops/bmi-cicd/overlays/prod."
  type        = string
  default     = "cicd-bmi.bestclick.click"
}

# ---------- GitHub ----------
variable "github_repo" {
  description = "owner/name of THIS project's GitHub repo (pipeline source, and what Argo CD watches)."
  type        = string
  default     = "abip007/eks-argocd-3tier-cicd"
}

variable "git_branch" {
  type    = string
  default = "main"
}

variable "github_token" {
  description = "Fine-grained GitHub token, this repo only, Contents: Read and write. Used by BuildPush to commit the new image tag."
  type        = string
  sensitive   = true
}

# ---------- SonarQube server ----------
variable "admin_cidrs" {
  description = "Who may open the SonarQube UI on port 9000, e.g. [\"203.0.113.10/32\"] (curl https://checkip.amazonaws.com)."
  type        = list(string)
}

variable "sonar_instance_type" {
  description = "SonarQube needs >= 4 GiB RAM. m7i-flex.large (8 GiB) is free-plan eligible."
  type        = string
  default     = "m7i-flex.large"
}

variable "sonar_volume_gb" {
  type    = number
  default = 30
}

# ---------- Pipeline ----------
variable "codebuild_compute_type" {
  description = "BUILD_GENERAL1_SMALL = 2 vCPU / 3 GiB (free tier: 100 build minutes per month)."
  type        = string
  default     = "BUILD_GENERAL1_SMALL"
}

variable "trigger_paths" {
  description = "Pushes touching these paths start the pipeline. gitops/** is left out on purpose: the pipeline's own tag commit must not start it again."
  type        = list(string)
  default     = ["app/**", "pipeline/**", "tests/**", "sonar-project.properties"]
}
