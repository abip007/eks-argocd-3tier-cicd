# In the cluster: app namespace + DB secrets and the Grafana admin secret (never in
# Git), and the Argo CD root Application that deploys everything in gitops/argocd/apps/.
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

# Grafana admin login (kube-prometheus-stack reads Secret "grafana-admin"). Never in Git.
resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.observability.metadata[0].name
  }
  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana.result
  }
}

# Root Application (app-of-apps) = gitops/argocd/root-app.yaml. Argo CD then creates
# every Application in gitops/argocd/apps/: bmi-cicd (the app) and the observability
# stack (kube-prometheus-stack, loki, alloy, observability-extras).
# Shipped through the argocd-apps chart, not kubernetes_manifest, so 'plan' works
# before the cluster and Argo CD's CRDs exist.
resource "helm_release" "argocd_app" {
  name       = "argocd-root-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      root = {
        namespace  = "argocd"
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        project    = "default"
        source = {
          repoURL        = "https://github.com/${var.github_repo}.git"
          targetRevision = var.git_branch
          path           = "gitops/argocd/apps"
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
  })]

  depends_on = [
    helm_release.argocd,
    helm_release.external_dns,
    helm_release.prometheus_operator_crds,
    kubernetes_storage_class_v1.gp3,
    kubernetes_secret_v1.postgres,
    kubernetes_secret_v1.backend,
    kubernetes_secret_v1.grafana_admin,
  ]
}

# On 'terraform destroy' this runs FIRST: delete the Argo CD apps (so the LB
# Controller removes the ALB), the app namespace and the observability volumes
# (frees the EBS volumes) while the controllers are still running. Otherwise the VPC can't be deleted.
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
      # root first: its finalizer deletes the child apps, theirs delete what they deployed
      "kubectl --kubeconfig ${self.input.kubeconfig} -n argocd delete application root --ignore-not-found --wait=true --timeout=10m",
      "kubectl --kubeconfig ${self.input.kubeconfig} -n argocd delete application ${self.input.name} kube-prometheus-stack loki alloy observability-extras --ignore-not-found --wait=true --timeout=10m",
      "kubectl --kubeconfig ${self.input.kubeconfig} delete namespace ${self.input.name} --ignore-not-found --wait=true --timeout=10m",
      # StatefulSet volumes (Prometheus, Alertmanager, Loki) outlive their apps: delete
      # them while the EBS CSI driver still runs, or the EBS volumes are orphaned
      "kubectl --kubeconfig ${self.input.kubeconfig} delete pvc --all -n observability --ignore-not-found --wait=true --timeout=10m",
      # Argo CD's own Ingress keeps the shared ALB alive: delete every Ingress now,
      # so the LB Controller removes the ALB while it can still reach the AWS API
      "kubectl --kubeconfig ${self.input.kubeconfig} delete ingress --all -A --ignore-not-found --wait=true --timeout=10m",
    ])
  }

  depends_on = [
    # what it deletes
    helm_release.argocd_app,
    kubernetes_namespace_v1.app,
    kubernetes_namespace_v1.observability,
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
