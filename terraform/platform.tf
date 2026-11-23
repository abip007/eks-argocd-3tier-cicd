# Platform inside the cluster: StorageClass, LB Controller, ExternalDNS, Argo CD.
# The app itself (namespace, secrets, Argo CD Application) is in kubernetes.tf.

# Certificate for domain + *.domain. Not created here: an ISSUED cert already
# exists in the account (set certificate_arn to pin a specific one).
data "aws_acm_certificate" "wildcard" {
  count       = var.certificate_arn == "" ? 1 : 0
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

locals {
  certificate_arn = var.certificate_arn != "" ? var.certificate_arn : data.aws_acm_certificate.wildcard[0].arn
}

# ---------- Storage (Postgres PVC uses storageClassName: gp3) ----------
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  parameters             = { type = "gp3", encrypted = "true", fsType = "ext4" }

  depends_on = [aws_eks_addon.ebs_csi]
}

# ---------- Gateway API CRDs (the LB Controller v3 expects them before it starts) ----------
# Needs aws + kubectl on PATH. One '&&' line works in bash and cmd.exe.
resource "terraform_data" "gateway_crds" {
  triggers_replace = [aws_eks_cluster.this.arn, var.gateway_api_version, var.aws_lbc_version]

  provisioner "local-exec" {
    command = join(" && ", [
      "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region} --kubeconfig ${local.kubeconfig_path} ${local.profile_flag}",
      "kubectl --kubeconfig ${local.kubeconfig_path} apply --server-side=true --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/standard-install.yaml",
      "kubectl --kubeconfig ${local.kubeconfig_path} apply --server-side=true --force-conflicts -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${var.aws_lbc_version}/config/crd/gateway/gateway-crds.yaml",
    ])
  }

  depends_on = [aws_eks_node_group.general]
}

# ---------- AWS Load Balancer Controller ----------
# NOTE: Helm signs this controller's webhook certificate with YOUR PC clock.
# If the clock is ahead of AWS, later releases fail with x509 "not yet valid"
# on mservice.elbv2.k8s.aws. Keep Windows Time running (w32tm /resync).
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_lbc_chart_version
  namespace  = "kube-system"
  wait       = true
  timeout    = 600

  values = [yamlencode({
    clusterName    = aws_eks_cluster.this.name
    region         = var.region
    vpcId          = aws_vpc.this.id
    replicaCount   = 2
    serviceAccount = { create = true, name = "aws-load-balancer-controller" } # = Pod Identity association
  })]

  depends_on = [
    terraform_data.gateway_crds,
    aws_eks_pod_identity_association.controller,
    aws_eks_addon.coredns,
    aws_eks_addon.pod_identity_agent,
  ]
}

# ---------- ExternalDNS: Route 53 records for every Ingress host ----------
resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.external_dns_chart_version
  namespace        = "external-dns"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    provider       = { name = "aws" }
    env            = [{ name = "AWS_DEFAULT_REGION", value = var.region }]
    domainFilters  = [var.domain_name]
    extraArgs      = var.external_dns_zone_id == "" ? [] : ["--zone-id-filter=${var.external_dns_zone_id}"]
    policy         = "upsert-only"
    txtOwnerId     = var.cluster_name
    sources        = ["ingress"]
    serviceAccount = { create = true, name = "external-dns" } # = Pod Identity association
  })]

  depends_on = [
    aws_eks_pod_identity_association.controller,
    helm_release.aws_load_balancer_controller, # webhook must be up before charts create Services
  ]
}

# ---------- Argo CD ----------
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [yamlencode({
    configs = {
      params = { "server.insecure" = true }         # TLS ends at the ALB
      cm     = { "timeout.reconciliation" = "60s" } # poll Git every 60 s
    }
    server = {
      ingress = {
        enabled          = true
        ingressClassName = "alb"
        hostname         = var.argocd_host
        annotations = {
          "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
          "alb.ingress.kubernetes.io/target-type"      = "ip"
          "alb.ingress.kubernetes.io/group.name"       = "shared" # same ALB as the app
          "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
          "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"
          "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTP\":80},{\"HTTPS\":443}]"
          "alb.ingress.kubernetes.io/ssl-redirect"     = "443"
          "alb.ingress.kubernetes.io/ssl-policy"       = "ELBSecurityPolicy-TLS13-1-2-2021-06"
          "alb.ingress.kubernetes.io/certificate-arn"  = local.certificate_arn
        }
      }
    }
  })]

  depends_on = [helm_release.aws_load_balancer_controller]
}
