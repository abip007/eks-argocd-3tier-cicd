# ---------- General ----------
variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile. null = default credential chain."
  type        = string
  default     = "abip007home"
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

# ---------- EKS cluster (created by this project) ----------
variable "cluster_name" {
  description = "EKS cluster name. Prefixes the VPC, IAM roles and policies. Different from eks-argocd-3tier's argo-eks so both projects can live in one account."
  type        = string
  default     = "bmi-cicd-eks"
}

variable "kubernetes_version" {
  type    = string
  default = "1.36"
}

variable "vpc_cidr" {
  description = "VPC CIDR (3 public /20 + 3 private /19 across 3 AZs)."
  type        = string
  default     = "10.2.0.0/16"
}

variable "single_nat_gateway" {
  description = "true = one NAT gateway (cheap). false = one per AZ (HA)."
  type        = bool
  default     = true
}

variable "api_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API, e.g. [\"203.0.113.10/32\"]. Your PC must be in it: Terraform runs kubectl/helm from there."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "Free-plan eligible: m7i-flex.large / c7i-flex.large = 29 pods/node, t3.small = 11."
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

# ---------- DNS / TLS ----------
variable "domain_name" {
  description = "Public Route 53 hosted zone in this account (ExternalDNS writes records here)."
  type        = string
  default     = "bestclick.click"
}

variable "app_host" {
  description = "Public hostname of this app. Must equal the Ingress host in gitops/bmi-cicd/overlays/prod."
  type        = string
  default     = "cicd-bmi.bestclick.click"
}

variable "argocd_host" {
  description = "Public hostname of the Argo CD UI."
  type        = string
  default     = "argocd-cicd.bestclick.click"
}

variable "certificate_arn" {
  description = "ACM certificate for domain + *.domain. Empty = newest ISSUED cert for domain_name."
  type        = string
  default     = ""
}

# ---------- Platform chart versions ----------
variable "aws_lbc_version" {
  description = "LB Controller release whose gateway CRDs are installed (policies/aws-load-balancer-controller.json matches v3.6.0)."
  type        = string
  default     = "v3.6.0"
}

variable "gateway_api_version" {
  type    = string
  default = "v1.6.0"
}

variable "aws_lbc_chart_version" {
  description = "null = latest."
  type        = string
  default     = null
}

variable "external_dns_chart_version" {
  description = "null = latest."
  type        = string
  default     = null
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version; null = latest."
  type        = string
  default     = null
}

variable "argocd_apps_chart_version" {
  description = "argocd-apps Helm chart version; null = latest."
  type        = string
  default     = null
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
