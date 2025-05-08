terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.0" }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

# Namespace voor Argo CD
resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
}

# Helm release ArgoCD
resource "helm_release" "argocd" {
  name      = "argocd"
  namespace = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart     = "argo-cd"

  create_namespace   = false
  atomic             = true
  timeout            = 600
  dependency_update  = true

  # Gebruik NodePort voor lokale toegang
  set {
    name  = "server.service.type"
    value = "NodePort"
  }
  set {
    name  = "server.service.nodePorts.http"
    value = "30080"
  }
  set {
    name  = "server.service.nodePorts.https"
    value = "30443"
  }

  # Zorg dat pods niet proberen hostPorts te binden (standaard false)
  set {
    name  = "server.hostNetwork"
    value = "false"
  }
}
