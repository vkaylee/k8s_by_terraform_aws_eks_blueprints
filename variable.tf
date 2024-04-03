variable "app-name" {
  default = "EKS"
}
# Manually check your pool
# VPC cidr will be ipv4_prefix + ".0.0/16"
# For example:
# with prefix 10.255, vpc cidr will be: "10.255.0.0/16"
# IPs range: 10.255.0.0 - 10.255.255.255
variable "ipv4_prefix" {
  default = "10.255"
}

variable "tags" {
  type = object({
    Terraform   = string
    Environment = string
  })
  default = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# variable will be set by local environment.
# For example: EXAMPLEVAR will be set by TF_VAR_EXAMPLEVAR
variable "AWS_ACCESS_KEY" {
  type = string
}
variable "AWS_SECRET_KEY" {
  type = string
}

variable "AWS_DEFAULT_REGION" {
  default = "ap-southeast-1"
}

variable "eks_cluster_version" {
  default = "1.28"
}

variable "root_domain" {
  default = "i.wip.la"
}
# https://desec.io/tokens
variable "desec_token" {
  default = ""
}
# Grafana
variable "grafana_subdomain" {
  default = "grafana"
}
variable "grafana_plain_password" {
  default = "password"
}

# Argocd
variable "argocd_subdomain" {
  default = "argocd"
}
variable "argocd_plain_password" {
  default = "password"
}
