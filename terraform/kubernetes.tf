# In the existing cluster: namespace + DB secrets (never in Git) + the Argo CD
# Application that deploys gitops/bmi-cicd/overlays/prod from this repo.

resource "kubernetes_namespace_v1" "app" {
  metadata { name = var.name }
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
resource "kubernetes_manifest" "argocd_app" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name       = var.name
      namespace  = "argocd"
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = "https://github.com/${var.github_repo}.git"
        targetRevision = var.git_branch
        path           = "gitops/bmi-cicd/overlays/prod"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.name
      }
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

  depends_on = [kubernetes_secret_v1.postgres, kubernetes_secret_v1.backend]
}
