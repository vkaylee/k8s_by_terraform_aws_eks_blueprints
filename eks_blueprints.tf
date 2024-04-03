resource "null_resource" "bcrypt" {
  triggers = {
    argocd_password = bcrypt(var.argocd_plain_password)
  }
  lifecycle {
    # Avoid bcrypt many times
    ignore_changes = [triggers]
  }
}

# https://github.com/aws-ia/terraform-aws-eks-blueprints-addons
module "eks_blueprints_addons" {
  source = "aws-ia/eks-blueprints-addons/aws"
  # https://developer.hashicorp.com/terraform/language/expressions/version-constraints
  # Just update hotfix
  version = "~> 1.11.0"

  cluster_name      = time_sleep.eks.triggers.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # We want to wait for the Fargate profiles to be deployed first
  create_delay_dependencies = [for prof in module.eks.fargate_profiles : prof.fargate_profile_arn]

  # karpenter
  enable_karpenter                           = true
  karpenter_enable_instance_profile_creation = true
  karpenter_enable_spot_termination          = true
  # AWS Node Termination Handler
  # https://github.com/aws/aws-node-termination-handler
  # enable_aws_node_termination_handler = true
  # metrics-server
  enable_metrics_server = true
  # cert manager
  enable_cert_manager = true
  # cluster autoscaler
  enable_cluster_autoscaler = false

  enable_external_dns = false
  enable_argocd       = true
  # Enable aws load balancer controller
  # This controller will monitor all ingress annotaions to issue and configure lb
  enable_aws_load_balancer_controller = true
  # An aws classic load balancer will be created
  # If using with aws_load_balancer_controller, an aws network load balancer can be issued
  # Due to use aws_load_balancer_controller, they have their own ingress controller alb
  # ingress controller alb is actually the aws application load balancer, one load balancer per ingress
  enable_ingress_nginx         = true
  enable_kube_prometheus_stack = true

  karpenter = {
    # we must wait until ready because we have to apply NodeTemplate and Provisioner right after
    # wait = true
    set = [
      {
        name : "controller.resources.requests.cpu"
        value : "0.25"
      },
      {
        name : "controller.resources.requests.memory"
        value : "768M"
      },
      {
        name : "controller.resources.limits.cpu"
        value : "0.25"
      },
      {
        name : "controller.resources.limits.memory"
        value : "768M"
      },
    ]
  }

  karpenter_node = {
    iam_role_additional_policies = merge(
      # Workaround due to the issue https://github.com/aws-ia/terraform-aws-eks-blueprints-addons/issues/301
      # Attach AmazonEKS_CNI_IPv6_Policy that is created by EKS module
      local.enable_ipv6_cluster ? {
        cni_ipv6 = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:policy/AmazonEKS_CNI_IPv6_Policy"
      } : {},
    )
  }

  metrics_server = {
    set = [
      # Autoscale base on amount of nodes
      {
        # Enable this one when having more than 100 nodes
        name : "addonResizer.enabled"
        value : "false"
      },
      {
        name : "apiService.insecureSkipTLSVerify"
        value : "true"
      },
    ]
  }

  # aws_load_balancer_controller = {
  #   wait          = true
  #   wait_for_jobs = true
  # }

  ingress_nginx = {
    reuse_values = true
    # wait          = true
    # wait_for_jobs = true
    # https://github.com/kubernetes/ingress-nginx/blob/main/charts/ingress-nginx/values.yaml
    set = [
      {
        name : "controller.enableAnnotationValidations"
        value : true
      },
      {
        name : "controller.terminationGracePeriodSeconds"
        value : "30"
      },
      {
        name : "controller.topologySpreadConstraints[0].maxSkew"
        value : "1"
      },
      {
        name : "controller.topologySpreadConstraints[0].topologyKey"
        value : "kubernetes.io/hostname"
      },
      {
        name : "controller.topologySpreadConstraints[0].whenUnsatisfiable"
        value : "DoNotSchedule"
      },
      {
        name : "controller.topologySpreadConstraints[0].labelSelector.matchLabels.app\\.kubernetes\\.io/name"
        value : "ingress-nginx"
      },
      # hpa autoscaling
      {
        name : "controller.autoscaling.enabled"
        value : "true"
      },
      {
        name : "controller.autoscaling.minReplicas"
        value : "1"
      },
      {
        name : "controller.autoscaling.maxReplicas"
        value : "110"
      },
      {
        name : "controller.autoscaling.behavior.scaleDown.stabilizationWindowSeconds"
        value : "180"
      },
      {
        name : "controller.autoscaling.behavior.scaleDown.selectPolicy"
        value : "Min"
      },
      {
        name : "controller.autoscaling.behavior.scaleDown.policies[0].type"
        value : "Pods"
      },
      {
        name : "controller.autoscaling.behavior.scaleDown.policies[0].value"
        value : "1"
      },
      {
        name : "controller.autoscaling.behavior.scaleDown.policies[0].periodSeconds"
        value : "60"
      },
      # resource
      {
        name : "controller.resources.requests.cpu"
        value : "150m"
      },
      {
        name : "controller.resources.requests.memory"
        value : "150Mi"
      },
      {
        name : "controller.resources.limits.cpu"
        value : "150m"
      },
      {
        name : "controller.resources.limits.memory"
        value : "150Mi"
      },
      # Due to EKS does not support dualstack
      {
        name : "controller.service.ipFamilyPolicy"
        value : "SingleStack"
      },
      # Enable this one if the cluster supports ipv6
      # Due to EKS does not support dualstack, we can only set IPv4 or IPv6
      {
        name : "controller.service.ipFamilies"
        value : "{${local.enable_ipv6_cluster ? "IPv6" : "IPv4"}}"
      },
      {
        # Disable the external one because this one is the classic load balancer, it does not support dualstack
        name : "controller.service.external.enabled"
        value : "false"
      },
      # https://github.com/kubernetes/ingress-nginx/blob/main/charts/ingress-nginx/README.md#additional-internal-load-balancer
      # If we have this, cloud service provider load balancer controller will read all annotations and issue load balancer
      {
        name : "controller.service.internal.enabled"
        value : "true"
      },
      # Set annotations in helm set https://stackoverflow.com/a/70369034/14510127
      # https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.2/guide/service/annotations/
      {
        name : "controller.service.internal.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
        value : "nlb-ip"
        # For nlb-ip type, controller will provision NLB with IP targets. This value is supported for backwards compatibility
        # For external type, NLB target type depend on the annotation nlb-target-type
      },
      {
        name : "controller.service.internal.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-name"
        value : lower("ingressNginxInternal${time_sleep.eks.triggers.cluster_name}") # If you modify this annotation after service creation, there is no effect.
      },
      # {
      #   name : "controller.service.internal.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
      #   value : "instance"
      #   # instance mode will route traffic to all EC2 instances within cluster on the NodePort opened for your service.
      #   # ec2 instance must set primary ip that is not set by default
      #   # ip mode will route traffic directly to the pod IP (this is the default)
      # },
      {
        name : "controller.service.internal.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
        value : "internet-facing"
      },
      {
        name : "controller.service.internal.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-ip-address-type"
        value : local.enable_ipv6_cluster ? "dualstack" : "ipv4"
      },
    ]
  }

  argocd = {
    set = [
      {
        # -- Run server without TLS because of running server behide a reverse proxy like ingress-nginx
        name : "configs.params.server\\.insecure"
        value : "true"
      },
      {
        # -- Bcrypt hashed admin password
        ## Argo expects the password in the secret to be bcrypt hashed. You can create this hash with
        ## `htpasswd -nbBC 10 "" $ARGO_PWD | tr -d ':\n' | sed 's/$2y/$2a/'`
        name : "configs.secret.argocdServerAdminPassword"
        value : null_resource.bcrypt.triggers.argocd_password
      },
      {
        name : "server.ingress.enabled"
        value : "true"
      },
      {
        name : "server.ingress.ingressClassName"
        value : "nginx"
      },
      {
        name : "server.ingress.hosts[0]"
        value : "${var.argocd_subdomain}.${lower(time_sleep.eks.triggers.cluster_name)}.${var.root_domain}"
      },
      {
        name : "server.ingress.tls[0].secretName"
        value : "argocd-general-tls"
      },
      {
        name : "server.ingress.tls[0].hosts[0]"
        value : "${var.argocd_subdomain}.${lower(time_sleep.eks.triggers.cluster_name)}.${var.root_domain}"
      },
      {
        # https://cert-manager.io/docs/usage/ingress/#how-it-works
        # Manually create Issuer after configuring domain to avoid rate limiting
        name : "server.ingress.annotations.cert-manager\\.io/cluster-issuer"
        value : "acme-nginx"
      },
    ]
  }

  kube_prometheus_stack = {
    set = [
      {
        name : "prometheus.prometheusSpec.scrapeInterval"
        value : "10s"
      },
      {
        name : "grafana.enabled"
        value : "true"
      },
      {
        name : "grafana.adminPassword"
        value : var.grafana_plain_password
      },
      # Ingress: https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/values.yaml#L361
      {
        name : "grafana.ingress.enabled"
        value : "true"
      },
      {
        name : "grafana.ingress.ingressClassName"
        value : "nginx"
      },
      {
        name : "grafana.ingress.hosts[0]"
        value : "${var.grafana_subdomain}.${lower(time_sleep.eks.triggers.cluster_name)}.${var.root_domain}"
      },
      {
        name : "grafana.ingress.tls[0].secretName"
        value : "grafana-general-tls"
      },
      {
        name : "grafana.ingress.tls[0].hosts[0]"
        value : "${var.grafana_subdomain}.${lower(time_sleep.eks.triggers.cluster_name)}.${var.root_domain}"
      },
      {
        # https://cert-manager.io/docs/usage/ingress/#how-it-works
        # Manually create Issuer after configuring domain to avoid rate limiting
        name : "grafana.ingress.annotations.cert-manager\\.io/cluster-issuer"
        value : "acme-nginx"
      },
      # {
      #   name : "grafana.ingress.ingressClassName"
      #   # alb: aws_load_balancer_controller must be installed first
      #   value : "alb"
      # },
      # {
      #   name : "grafana.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/scheme"
      #   value : "internet-facing"
      # },
      # {
      #   name : "grafana.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/target-type"
      #   value : "ip"
      # },
      # {
      #   name : "grafana.ingress.annotations.alb\\.ingress\\.kubernetes\\.io/ip-address-type"
      #   value : local.enable_ipv6_cluster ? "dualstack" : "ipv4"
      # },
      {
        name : "grafana.ingress.path"
        value : "/"
      },
    ]
  }

  tags = merge(var.tags, {
    Name = local.cluster_name
  })

  depends_on = [
    null_resource.tools_and_networks,
    aws_security_group_rule.aws_fargate_coredns_tcp_53,
    aws_security_group_rule.aws_fargate_coredns_udp_53,
    aws_security_group_rule.aws_fargate_coredns_tcp_9153,
  ]
}