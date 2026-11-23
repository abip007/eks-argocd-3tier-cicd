# The app in the cluster: namespace + DB secrets (never in Git) + the Argo CD
# Application that deploys gitops/bmi-cicd/overlays/prod from this repo.
# After this Terraform never touches the app again - Argo CD deploys it from Git.

resource "kubernetes_namespace_v1" "app" {
  metadata { name = var.name }
  depends_on = [aws_eks_node_group.general]
}

resource "random_password" "db" {
  length  = 32
  special = false # safe inside DATABASE_URL
}

resource "kubernetes_secret_v1" "postgres" {
  metadata {
    name      = "postgres-secret"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    POSTGRES_DB       = "bmidb"
    POSTGRES_USER     = "bmi_user"
    POSTGRES_PASSWORD = random_password.db.result
  }
}

resource "kubernetes_secret_v1" "backend" {
  metadata {
    name      = "backend-secret"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    DATABASE_URL = "postgres://bmi_user:${random_password.db.result}@bmi-postgres-svc:5432/bmidb"
  }
}

# Same content as gitops/argocd/bmi-cicd-app.yaml (the CLI/console paths apply that file).
# Shipped through the argocd-apps chart, not kubernetes_manifest, so 'plan' works
# before the cluster and Argo CD's CRDs exist.
resource "helm_release" "argocd_app" {
  name       = "${var.name}-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      (var.name) = {
        namespace  = "argocd"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        project    = "default"
        source = {
          repoURL        = "https://github.com/${var.github_repo}.git"
          targetRevision = var.git_branch
          path           = "gitops/bmi-cicd/overlays/prod"
        }
        destination = { server = "https://kubernetes.default.svc", namespace = var.name }
        syncPolicy = {
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=true"]
          retry = {
            limit   = 5
            backoff = { duration = "10s", factor = 2, maxDuration = "3m" }
          }
        }
        ignoreDifferences = [{
          group        = "apps"
          kind         = "Deployment"
          name         = "bmi-backend"
          jsonPointers = ["/spec/replicas"]
        }]
      }
    }
  })]

  depends_on = [
    helm_release.argocd,
    helm_release.external_dns,
    kubernetes_storage_class_v1.gp3,
    kubernetes_secret_v1.postgres,
    kubernetes_secret_v1.backend,
  ]
}

# On 'terraform destroy' this runs FIRST: delete the Argo CD Application (so the
# LB Controller removes the ALB) and the app namespace (frees the EBS volume)
# while the controllers are still running. Otherwise the VPC can't be deleted.
# depends_on below lists everything that must still exist while it runs:
# destroy goes in reverse order, so none of these is touched until it's done.
# Without the network entries, Terraform deleted the NAT gateway in parallel;
# Argo CD then couldn't reach GitHub, the LB Controller couldn't reach the AWS
# API, and the ALB kept the public subnets and internet gateway from deleting.
resource "terraform_data" "app_teardown" {
  input = { kubeconfig = local.kubeconfig_path, name = var.name }

  provisioner "local-exec" {
    when = destroy
    command = join(" && ", [
      "kubectl --kubeconfig ${self.input.kubeconfig} -n argocd delete application ${self.input.name} --ignore-not-found --wait=true --timeout=10m",
      "kubectl --kubeconfig ${self.input.kubeconfig} delete namespace ${self.input.name} --ignore-not-found --wait=true --timeout=10m",
    ])
  }

  depends_on = [
    # what it deletes
    helm_release.argocd_app,
    kubernetes_namespace_v1.app,
    # who does the deleting: Argo CD, the LB Controller (+ its AWS credentials), EBS CSI
    helm_release.argocd,
    helm_release.aws_load_balancer_controller,
    helm_release.external_dns,
    aws_eks_pod_identity_association.controller,
    aws_eks_addon.ebs_csi,
    aws_eks_addon.pod_identity_agent,
    terraform_data.gateway_crds,
    # their way out to GitHub and the AWS APIs, and the subnets the ALB lives in
    aws_route.private_nat,
    aws_route.public_internet,
    aws_route_table_association.public,
    aws_route_table_association.private,
    aws_nat_gateway.this,
    aws_internet_gateway.this,
    aws_subnet.public,
  ]
}
