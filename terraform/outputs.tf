output "sonarqube_url" {
  value = local.sonar_host_url
}

output "sonarqube_setup_command" {
  description = "Run once SonarQube is up (2-3 min after apply)."
  value       = "SONAR_HOST_URL=${local.sonar_host_url} SONAR_ADMIN_PASSWORD='<new-strong-password>' AWS_REGION=${var.region} bash sonarqube/setup-sonarqube.sh"
}

output "github_connection_arn" {
  description = "PENDING until you click 'Update pending connection' in the console."
  value       = aws_codestarconnections_connection.github.arn
}

output "github_connection_console_url" {
  value = "https://${var.region}.console.aws.amazon.com/codesuite/settings/connections?region=${var.region}"
}

output "pipeline_console_url" {
  value = "https://${var.region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.this.name}/view?region=${var.region}"
}

output "ecr_repository_urls" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "app_url" {
  value = "https://${var.app_host}"
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region}${var.aws_profile == null ? "" : " --profile ${var.aws_profile}"}"
}

output "argocd_url" {
  value = "https://${var.argocd_host}"
}

output "argocd_admin_password_command" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "certificate_arn" {
  value = local.certificate_arn
}
