output "cluster_ingress" {
  value = "http://${desec_rrset.cluster[0].subname}.${desec_rrset.cluster[0].domain}"
}

output "grafana_ingress" {
  value = "https://${var.grafana_subdomain}.${desec_rrset.cluster[0].subname}.${desec_rrset.cluster[0].domain}"
}

output "argocd_ingress" {
  value = "https://${var.argocd_subdomain}.${desec_rrset.cluster[0].subname}.${desec_rrset.cluster[0].domain}"
}
