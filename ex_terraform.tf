# Delete some load balancers
# These services are not created by terraform
resource "null_resource" "ingresses" {
  triggers = {
    kubeconfig_file = abspath(local_file.kubeconfig.filename)
    delete_command  = "kubectl --context aws delete"
  }

  # Delete all ingress resources, some ingress type alb having alb load balancer in aws
  provisioner "local-exec" {
    when = destroy
    # We should specify context in case we have many contexts in kubeconfig
    command = "${self.triggers.delete_command} --all ingresses --all-namespaces"
    environment = {
      KUBECONFIG = self.triggers.kubeconfig_file
    }
    on_failure = continue
  }

  depends_on = [
    # When deleting ingresses and loadbalancers, we need network, aws_load_balancer_controller, ingress-nginx, dns, worker nodes, fargates
    null_resource.stable_cluster,
    module.karpenter_default_nodepool,
    module.eks_blueprints_addons.ingress_nginx,
    module.eks_blueprints_addons.aws_load_balancer_controller,
  ]
}

resource "null_resource" "ingress-nginx-controller-external" {
  triggers = {
    kubeconfig_file = abspath(local_file.kubeconfig.filename)
    delete_command  = "kubectl --context aws delete"
  }
  # Delete all services in ingress-nginx namespace to destroy load balancers in aws
  provisioner "local-exec" {
    when = destroy
    # We should specify context in case we have many contexts in kubeconfig
    command = "${self.triggers.delete_command} svc ingress-nginx-controller-external --namespace ingress-nginx"
    environment = {
      KUBECONFIG = self.triggers.kubeconfig_file
    }
    on_failure = continue
  }

  depends_on = [
    # When deleting ingresses and loadbalancers, we need network, aws_load_balancer_controller, ingress-nginx, dns, worker nodes, fargates
    null_resource.stable_cluster,
    module.karpenter_default_nodepool,
    module.eks_blueprints_addons.ingress_nginx,
  ]
}

resource "null_resource" "ingress-nginx-controller-internal" {
  triggers = {
    kubeconfig_file = abspath(local_file.kubeconfig.filename)
    delete_command  = "kubectl --context aws delete"
  }

  # Delete all services in ingress-nginx namespace to destroy load balancers in aws
  provisioner "local-exec" {
    when = destroy
    # We should specify context in case we have many contexts in kubeconfig
    command = "${self.triggers.delete_command} svc ingress-nginx-controller-internal --namespace ingress-nginx"
    environment = {
      KUBECONFIG = self.triggers.kubeconfig_file
    }
    on_failure = continue
  }

  depends_on = [
    # When deleting ingresses and loadbalancers, we need network, aws_load_balancer_controller, ingress-nginx, dns, worker nodes, fargates
    null_resource.stable_cluster,
    module.karpenter_default_nodepool,
    module.eks_blueprints_addons.ingress_nginx,
  ]
}


data "kubernetes_service_v1" "ingress_nginx_internal" {
  metadata {
    name      = "ingress-nginx-controller-internal"
    namespace = "ingress-nginx"
  }
  depends_on = [
    module.eks_blueprints_addons.ingress_nginx,
    module.eks_blueprints_addons.aws_load_balancer_controller,
  ]
}

provider "desec" {
  api_token = var.desec_token
}

resource "desec_rrset" "cluster" {
  count   = var.desec_token == "" ? 0 : 1
  domain  = lower(var.root_domain)
  subname = lower(time_sleep.eks.triggers.cluster_name)
  type    = "CNAME"
  records = ["${data.kubernetes_service_v1.ingress_nginx_internal.status.0.load_balancer.0.ingress.0.hostname}."]
  ttl     = 3600
}

resource "desec_rrset" "cluster_wildcard" {
  count   = var.desec_token == "" ? 0 : 1
  domain  = lower(var.root_domain)
  subname = "*.${lower(time_sleep.eks.triggers.cluster_name)}"
  type    = "CNAME"
  records = ["${data.kubernetes_service_v1.ingress_nginx_internal.status.0.load_balancer.0.ingress.0.hostname}."]
  ttl     = 3600
}

module "cluster_issuer_acme_nginx" {
  source                = "./modules/kubectl_apply"
  kubeconfig_file       = abspath(local_file.kubeconfig.filename)
  kubectl_context       = "aws"
  delay_before_creating = 30
  manifest              = <<-EOF
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: acme-nginx
      namespace: cert-manager
    spec:
      acme:
        # You must replace this email address with your own.
        # Let's Encrypt will use this to contact you about expiring
        # certificates, and issues related to your account.
        email: me@vlee.dev
        # staging server: https://acme-staging-v02.api.letsencrypt.org/directory
        server: https://acme-v02.api.letsencrypt.org/directory
        privateKeySecretRef:
          name: acme-nginx-account-key
        solvers:
        - http01:
            ingress:
              ingressClassName: nginx
    EOF
  depends_on = [
    desec_rrset.cluster,
    desec_rrset.cluster_wildcard,
    module.eks_blueprints_addons.cert_manager,
  ]
}
