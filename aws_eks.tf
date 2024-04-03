resource "random_string" "suffix" {
  length  = 8
  special = false
}
locals {
  # Use name with no hyphen like dash or underscore. Some components don't like the name like that 
  cluster_name = "${var.app-name}${random_string.suffix.result}"
  # https://github.com/bottlerocket-os/bottlerocket-admin-container
  bottlderocket-ssh-authorized-keys-data = "{\"ssh\":{\"authorized-keys\":[\"${local_file.key_pair_pub.content}\"]}}"
  # IPV6
  # We just provide --service-ipv6-cidr via the primary network config of the cluster info
  service_ipv6_cidr = local.enable_ipv6_cluster ? data.aws_eks_cluster.eks.kubernetes_network_config[0].service_ipv6_cidr : ""
  # --ip-family ipv6: optional, it is going to be "ipv6" if --service-ipv6-cidr is set
  # --dns-cluster-ip: optional, it is going to be set via --service-ipv6-cidr
  # If you want to set it to external DNS, set it here
  # dns_cluster_ipv6 = local.enable_ipv6_cluster ? "${replace(local.service_ipv6_cidr, "/\\/.+$/", "")}a" : ""
  # https://github.com/awslabs/amazon-eks-ami/blob/v20231106/files/bootstrap.sh#L457-L480
  ipv6_bootstrap_extra_args = local.enable_ipv6_cluster ? "--use-max-pods false --service-ipv6-cidr ${local.service_ipv6_cidr}" : ""
}

data "aws_ami" "eks_default_bottlerocket" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["bottlerocket-aws-k8s-${var.eks_cluster_version}-x86_64-*"]
  }
}

resource "null_resource" "aws_eks" {
  depends_on = [
    module.eks,
    local_file.kubeconfig,
    aws_security_group_rule.aws_fargate_coredns_tcp_53,
    aws_security_group_rule.aws_fargate_coredns_udp_53,
    aws_security_group_rule.aws_fargate_coredns_tcp_9153,
    aws_security_group_rule.aws_fargate_tcp_10250,
    aws_security_group_rule.metrics_server_tcp_10250,
    kubernetes_config_map.aws_auth,
  ]
}
module "eks" {
  source = "terraform-aws-modules/eks/aws"
  # https://developer.hashicorp.com/terraform/language/expressions/version-constraints
  # Just update hotfix
  version = "~> 19.19.0"

  cluster_name    = local.cluster_name
  cluster_version = var.eks_cluster_version

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  control_plane_subnet_ids       = module.vpc.intra_subnets
  cluster_endpoint_public_access = true
  create_iam_role                = true
  # ipv6 cluster
  # VPC must support by setting private_subnet_assign_ipv6_address_on_creation = true
  # unmanaged nodegroups (self managed node group) are not yet supported with IPv6 clusters https://eksctl.io/usage/vpc-ip-family/
  # Issue with self managed node group with ipv6 => Taints: node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule
  cluster_ip_family          = local.enable_ipv6_cluster ? "ipv6" : "ipv4"
  create_cni_ipv6_iam_policy = local.enable_ipv6_cluster

  # Cluster addons
  cluster_addons = {
    aws-ebs-csi-driver = {
      most_recent = true
    }
    coredns = {
      most_recent = true
      configuration_values = jsonencode(merge(
        local.enable_coredns_in_fargate ? {
          computeType = "Fargate"
        } : {},
        {
          # Ensure that the we fully utilize the minimum amount of resources that are supplied by
          # Fargate https://docs.aws.amazon.com/eks/latest/userguide/fargate-pod-configuration.html
          # Fargate adds 256 MB to each pod's memory reservation for the required Kubernetes
          # components (kubelet, kube-proxy, and containerd). Fargate rounds up to the following
          # compute configuration that most closely matches the sum of vCPU and memory requests in
          # order to ensure pods always have the resources that they need to run.
          resources = {
            limits = {
              cpu = "0.25"
              # We are targetting the smallest Task size of 512Mb, so we subtract 256Mb from the
              # request/limit to ensure we can fit within that task
              memory = "256M"
            }
            requests = {
              cpu = "0.25"
              # We are targetting the smallest Task size of 512Mb, so we subtract 256Mb from the
              # request/limit to ensure we can fit within that task
              memory = "256M"
            }
          }
        },
      ))
    }
    vpc-cni = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
  }
  # Must set karpenter tag to node security group to use karpenter
  # Karpenter will add all security groups to the new machine with this tag
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  # Set to false if we have fargate or managed node group, dont need to create again because of conflicting
  # We will manage all logic of aws_auth configmap, set all to false
  create_aws_auth_configmap = false
  manage_aws_auth_configmap = false

  # We should put critical resources to fargate nodes
  fargate_profiles = merge(
    local.enable_karpenter_in_fargate ? {
      "karpenter" = {
        selectors = [
          { namespace = "karpenter" }
        ]
        tags = {
          Owner = "secondary"
        }
        subnet_ids = module.vpc.private_subnets
        timeouts = {
          create = "20m"
          delete = "20m"
        }
      }
    } : {},
    local.enable_coredns_in_fargate ? {
      "coredns" = {
        name = "coredns"
        selectors = [
          {
            namespace = "kube-system"
            labels = {
              k8s-app = "kube-dns"
            }
          },
        ]
        subnet_ids = module.vpc.private_subnets
        tags = {
          Owner = "secondary"
        }

        timeouts = {
          create = "20m"
          delete = "20m"
        }
      }
    } : {},
  )
  # Start additional security group rules
  ## Start node additional security group rules
  node_security_group_additional_rules = {
    ssh_access_from_workstation = {
      description              = "SSH access from workstation"
      protocol                 = "tcp"
      from_port                = 22
      to_port                  = 22
      type                     = "ingress"
      source_security_group_id = aws_security_group.workstation.id
    }
  }
  ## End node additional security group rules
  # End additional security group rules

  ## Start eks_managed_node_groups
  # eks_managed_node_groups = {
  #   # blue = {}
  #   green = {
  #     name     = "${local.cluster_name}-green"
  #     min_size = 0
  #     max_size = 5
  #     # Currently, self managed node group does not support ipv6 https://github.com/terraform-aws-modules/terraform-aws-eks/issues/2805
  #     # Set it atleast 2
  #     desired_size   = local.enable_ipv6_cluster ? 2 : 1
  #     key_name       = module.key_pair.key_pair_name
  #     instance_types = ["t3a.medium", "t3.medium"]
  #     capacity_type  = "SPOT"
  #   }
  # }
  ## End eks_managed_node_groups

  ## Start self_managed_node_groups
  # Declare the default one, it will be overrided by others if have
  self_managed_node_group_defaults = {
    name          = "default-managed-node-group"
    instance_type = "t3.medium"
    key_name      = module.key_pair.key_pair_name
    # Min is 2 because we have to run karpenter, the requirement is at least 2 nodes
    min_size                = 1
    max_size                = 5
    desired_size            = 1
    ebs_optimized           = true
    enable_monitoring       = true
    capacity_rebalance      = true
    pre_bootstrap_user_data = <<-EOT
        export FOO=bar
      EOT

    post_bootstrap_user_data = <<-EOT
    echo "Finish post_bootstrap_user_data"
    EOT
    # enable discovery of autoscaling groups by cluster-autoscaler
    autoscaling_group_tags = {
      "k8s.io/cluster-autoscaler/enabled" : true,
      "k8s.io/cluster-autoscaler/${local.cluster_name}" : "owned",
    }
    block_device_mappings = {
      # Increase size of root volume
      # The device_name is /dev/xvda as usual, it must be set by ami root_device_name
      # It should be added new feature like root_block_device
      root = {
        device_name = "/dev/xvda"
        ebs = {
          volume_type           = "standard"
          volume_size           = 20
          delete_on_termination = true
        }
      }
    }

    instance_refresh = {
      strategy = "Rolling"
      preferences = {
        min_healthy_percentage = 66
      }
    }
  }
  self_managed_node_groups = {
    ## Start self-managed-spot
    self-mng-spot = {
      # Due to the issue https://github.com/terraform-aws-modules/terraform-aws-eks/issues/2805
      # It seems to be the self-managed node group does not support IPv6
      # create = local.enable_ipv6_cluster ? false : true
      create = true
      name   = "${local.cluster_name}-self-mng-spot"
      # Min is 2 because we have to run karpenter, the requirement is at least 2 nodes
      min_size           = 0
      max_size           = 5
      desired_size       = 2
      capacity_rebalance = false
      # Add more local.bootstrap_extra_args to support ipv6
      bootstrap_extra_args       = "--kubelet-extra-args '--node-labels=node.kubernetes.io/lifecycle=spot' ${local.ipv6_bootstrap_extra_args}"
      use_mixed_instances_policy = true
      mixed_instances_policy = {
        instances_distribution = {
          # on_demand_base_capacity
          # The minimum amount of the Auto Scaling group's capacity that must be fulfilled by On-Demand Instances. This base portion is launched first as your group scales.
          on_demand_base_capacity = 0
          # on_demand_percentage_above_base_capacity
          # Controls the percentages of On-Demand Instances and Spot Instances for your additional capacity beyond OnDemandBaseCapacity.
          # Expressed as a number (for example, 20 specifies 20% On-Demand Instances, 80% Spot Instances). If set to 100, only On-Demand Instances are used.
          on_demand_percentage_above_base_capacity = 0
          # price-capacity-optimized
          # The price and capacity optimized allocation strategy looks at both price and capacity to select the Spot Instance pools that are the least likely to be interrupted and have the lowest possible price.
          spot_allocation_strategy = "price-capacity-optimized"
        }
        override = [
          {
            instance_requirements = {
              memory_mib = {
                min = 2048
              }

              memory_gib_per_vcpu = {
                min = 1
                max = 2
              }

              vcpu_count = {
                min = 2
              }
              cpu_manufacturers = [
                "intel",
                "amd",
                "amazon-web-services",
              ]
              instance_generations = ["current"]
              # local_storage = "excluded"
              local_storage_types = ["ssd"]
              # The specified instances are not supported by Network Load Balancers
              excluded_instance_types = [
                "m1.*",
                "m2.*",
                "m3.*",
                # NVME ssd
                # "*d.*",
                # higher bandwidth
                # "*n.*",
                # GPU
                # "P2.*",
                # "P3.*",
                # "P4.*",
                # "P5.*",
                # "DL1.*",
                # "Trn1.*",
                # "Inf2.*",
                # "Inf1.*",
                # "G5g.*",
                # "G5.*",
                # "G4dn.*",
                # "G4ad.*",
                # "G3.*",
                # "F1.*",
                # "VT1.*",
              ]
            }
          }
        ]
      }
      tags = {
        "node.kubernetes.io/lifecycle" = "spot"
      }
    }
    ## End self-managed-spot
    ## Start bottlerocket
    # bottlerocket = {
    #   name     = "${local.cluster_name}-bottlerocket"
    #   platform = "bottlerocket"
    #   ami_id   = data.aws_ami.eks_default_bottlerocket.id

    #   min_size           = 0
    #   max_size           = 5
    #   desired_size       = 1
    #   capacity_rebalance = false
    #   # Add more local.bootstrap_extra_args to support ipv6
    #   # https://bottlerocket.dev/en/os/1.16.x/api/settings/
    #   # bootstrap_extra_args       = "--kubelet-extra-args '--node-labels=node.kubernetes.io/lifecycle=spot' ${local.bootstrap_extra_args}"
    #   bootstrap_extra_args       = <<-EOT
    #     # The admin host container provides SSH access and runs with "superpowers".
    #     # It is disabled by default, but can be disabled explicitly.
    #     [settings.host-containers.admin]
    #     enabled = true
    #     user-data = "${base64encode(local.bottlderocket-ssh-authorized-keys-data)}"


    #     # The control host container provides out-of-band access via SSM.
    #     # It is enabled by default, and can be disabled if you do not expect to use SSM.
    #     # This could leave you with no way to access the API and change settings on an existing node!
    #     [settings.host-containers.control]
    #     enabled = true

    #     # extra args added
    #     [settings.kernel]
    #     lockdown = "integrity"

    #     [settings.kubernetes]
    #     cluster-dns-ip = "${local.dns_cluster_ip}a"
    #     [settings.kubernetes.node-labels]
    #     label1 = "foo"
    #     label2 = "bar"
    #   EOT
    #   use_mixed_instances_policy = true
    #   mixed_instances_policy = {
    #     instances_distribution = {
    #       # on_demand_base_capacity
    #       # The minimum amount of the Auto Scaling group's capacity that must be fulfilled by On-Demand Instances. This base portion is launched first as your group scales.
    #       on_demand_base_capacity = 0
    #       # on_demand_percentage_above_base_capacity
    #       # Controls the percentages of On-Demand Instances and Spot Instances for your additional capacity beyond OnDemandBaseCapacity.
    #       # Expressed as a number (for example, 20 specifies 20% On-Demand Instances, 80% Spot Instances). If set to 100, only On-Demand Instances are used.
    #       on_demand_percentage_above_base_capacity = 0
    #       # price-capacity-optimized
    #       # The price and capacity optimized allocation strategy looks at both price and capacity to select the Spot Instance pools that are the least likely to be interrupted and have the lowest possible price.
    #       spot_allocation_strategy = "price-capacity-optimized"
    #     }
    #     override = [
    #       {
    #         instance_requirements = {
    #           memory_mib = {
    #             min = 2048
    #           }

    #           memory_gib_per_vcpu = {
    #             min = 1
    #             max = 2
    #           }

    #           vcpu_count = {
    #             min = 2
    #           }
    #           cpu_manufacturers = [
    #             "intel",
    #             "amd",
    #             "amazon-web-services",
    #           ]
    #           instance_generations = ["current"]
    #           # local_storage = "excluded"
    #           local_storage_types = ["ssd"]
    #           # The specified instances are not supported by Network Load Balancers
    #           excluded_instance_types = [
    #             "m1.*",
    #             "m2.*",
    #             "m3.*",
    #           ]
    #         }
    #       }
    #     ]
    #   }
    #   tags = {
    #     "node.kubernetes.io/lifecycle" = "spot"
    #   }
    # }
    ## End bottlerocket
  }
  ## End self_managed_node_groups

  tags = var.tags
}

# https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/node_groups.tf#L180
# ipv6 egress is enable when the cluster is ipv6 stack due to the code above
# Manual enable it when the cluster stack is not ipv6 to allow pulling image by ipv6 connection
# If pulling image by ipv4 via NAT, it will consume more bandwidth and it is more expensive
resource "aws_security_group_rule" "node_egress_ipv6" {
  count             = local.enable_ipv6_cluster ? 0 : 1
  security_group_id = module.eks.node_security_group_id
  description       = "Allow all egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  type              = "egress"
  ipv6_cidr_blocks  = ["::/0"]
}

# Because aws fargate takes the cluster primary security group that is created automatically by EKS
# We want to run coredns in aws fargate, we must allow some coredns ports in the cluster primary security group to allow requests from nodes 
resource "aws_security_group_rule" "aws_fargate_coredns_tcp_53" {
  count                    = local.enable_coredns_in_fargate ? 1 : 0
  description              = "DNS requests from nodes to coredns in aws fargate"
  type                     = "ingress"
  security_group_id        = module.eks.cluster_primary_security_group_id
  from_port                = 53
  to_port                  = 53
  protocol                 = "tcp"
  source_security_group_id = module.eks.node_security_group_id
}
resource "aws_security_group_rule" "aws_fargate_coredns_udp_53" {
  count                    = local.enable_coredns_in_fargate ? 1 : 0
  description              = "DNS requests from nodes to coredns in aws fargate"
  type                     = "ingress"
  security_group_id        = module.eks.cluster_primary_security_group_id
  from_port                = 53
  to_port                  = 53
  protocol                 = "udp"
  source_security_group_id = module.eks.node_security_group_id
}
resource "aws_security_group_rule" "aws_fargate_coredns_tcp_9153" {
  count                    = local.enable_coredns_in_fargate ? 1 : 0
  description              = "DNS metrics from nodes to coredns in aws fargate"
  type                     = "ingress"
  security_group_id        = module.eks.cluster_primary_security_group_id
  from_port                = 9153
  to_port                  = 9153
  protocol                 = "tcp"
  source_security_group_id = module.eks.node_security_group_id
}
# Allow 10250 ingress port for taking metrics
resource "aws_security_group_rule" "aws_fargate_tcp_10250" {
  description              = "metrics requests from nodes (metrics_server) to aws fargate"
  type                     = "ingress"
  security_group_id        = module.eks.cluster_primary_security_group_id
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = module.eks.node_security_group_id
}
resource "aws_security_group_rule" "metrics_server_tcp_10250" {
  description              = "metrics requests from nodes (metrics_server) to kubelet"
  type                     = "ingress"
  security_group_id        = module.eks.node_security_group_id
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = module.eks.node_security_group_id
}

data "aws_eks_cluster" "eks" {
  name = time_sleep.eks.triggers.cluster_name
  # This one is a data block, terraform is going to query based on the name
  # On creating, tf will wait until it has a name and query
  # On destroying, tf can not refer to a name due to the destroyed cluster. It will throw an error
  # To avoid error, use depends_on attribute. If the dependencies don't exist, don't query
}
# data "aws_eks_cluster_auth" "ephemeral" {
#   name = time_sleep.eks.triggers.cluster_name
#   # This one is a data block, terraform is going to query based on the name
#   # On creating, tf will wait until it has a name and query
#   # On destroying, tf can not refer to a name due to the destroyed cluster. It will throw an error
#   # To avoid error, use depends_on attribute. If the dependencies don't exist, don't query

#   # Add dependency module.eks.cluster_name instead of module.eks to create kubeconfig right after the cluster has active status
#   # If we wait for module.eks, it will wait for all addons and components
# }
resource "local_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig"
  file_permission = "0600"
  content = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    preferences     = {}
    current-context = "terraform"
    clusters = [
      {
        name = module.eks.cluster_arn
        cluster = {
          certificate-authority-data = data.aws_eks_cluster.eks.certificate_authority[0].data
          server                     = data.aws_eks_cluster.eks.endpoint
        }
      },
    ]
    contexts = [
      # {
      #   name = "terraform"
      #   context = {
      #     cluster = module.eks.cluster_arn
      #     user    = "terraform"
      #   }
      # },
      {
        name = "aws"
        context = {
          cluster = module.eks.cluster_arn
          user    = "aws"
        }
      },
    ]
    users = [
      # {
      #   name = "terraform"
      #   user = {
      #     # This token is always new every request, that's why the kubeconfig file is always created
      #     token = data.aws_eks_cluster_auth.ephemeral.token
      #   }
      # },
      {
        name = "aws"
        user = {
          exec = {
            apiVersion = "client.authentication.k8s.io/v1beta1"
            args = [
              "eks",
              "get-token",
              "--cluster-name",
              time_sleep.eks.triggers.cluster_name,
              "--output",
              "json",
            ]
            command = "aws"
            env = [
              {
                name  = "AWS_ACCESS_KEY_ID"
                value = var.AWS_ACCESS_KEY
              },
              {
                name  = "AWS_SECRET_ACCESS_KEY"
                value = var.AWS_SECRET_KEY
              },
              {
                name  = "AWS_DEFAULT_REGION"
                value = var.AWS_DEFAULT_REGION
              },
            ]
          }
        }
      }
    ]
  })
}

####################################################################################################
############################ Create and update aws_auth configmap ##################################
####################################################################################################
resource "kubernetes_config_map" "aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }
  data = {
    # Create first, update as soon as possible
    mapRoles    = yamlencode([])
    mapUsers    = yamlencode([])
    mapAccounts = yamlencode([])
  }

  lifecycle {
    # We are ignoring the data here since we will manage it with the resource below
    # This is only intended to be used in scenarios where the configmap does not exist
    ignore_changes = [data, metadata[0].labels, metadata[0].annotations]
  }
}


# We should put every type of role to a resource because if we put all roles into one resource, the resource will wait all data before applying
# Because this behaviour, the aws_auth configmap is not updated on time
# Update when having the fargate roles data
data "kubernetes_config_map_v1" "aws_auth_mapRoles_fargate_profiles" {
  metadata {
    name      = kubernetes_config_map.aws_auth.metadata[0].name
    namespace = kubernetes_config_map.aws_auth.metadata[0].namespace
  }
}
resource "kubernetes_config_map_v1_data" "aws_auth_mapRoles_fargate_profiles" {
  force = true
  metadata {
    name      = kubernetes_config_map.aws_auth.metadata[0].name
    namespace = kubernetes_config_map.aws_auth.metadata[0].namespace
  }
  # Get the current configmap data and merge with the new one and update
  data = {
    mapRoles = yamlencode([for rolearn, roleobject in merge(
      { for role in toset(yamldecode(data.kubernetes_config_map_v1.aws_auth_mapRoles_fargate_profiles.data["mapRoles"])) : role["rolearn"] => role },
      { for role in toset([for k, fargate_group in module.eks.fargate_profiles :
        {
          rolearn  = fargate_group.iam_role_arn
          username = "system:node:{{SessionName}}"
          groups = [
            "system:bootstrappers",
            "system:nodes",
            "system:node-proxier",
          ]
        }
      ]) : role["rolearn"] => role }
    ) : roleobject])
    mapUsers    = data.kubernetes_config_map_v1.aws_auth_mapRoles_fargate_profiles.data["mapUsers"]
    mapAccounts = data.kubernetes_config_map_v1.aws_auth_mapRoles_fargate_profiles.data["mapAccounts"]
  }
  # It should be depended to the previous for sure we have only one task to update configmap
  depends_on = [kubernetes_config_map.aws_auth]
}
# Update when having the node roles data
data "kubernetes_config_map_v1" "aws_auth_mapRoles_eks_managed_nodes" {
  metadata {
    name      = kubernetes_config_map.aws_auth.metadata[0].name
    namespace = kubernetes_config_map.aws_auth.metadata[0].namespace
  }
}
resource "kubernetes_config_map_v1_data" "aws_auth_mapRoles_eks_managed_nodes" {
  force = true
  metadata {
    name      = kubernetes_config_map.aws_auth.metadata[0].name
    namespace = kubernetes_config_map.aws_auth.metadata[0].namespace
  }
  # Get the current configmap data and merge with the new one and update
  data = {
    mapRoles = yamlencode([for rolearn, roleobject in merge(
      { for role in toset(yamldecode(data.kubernetes_config_map_v1.aws_auth_mapRoles_eks_managed_nodes.data["mapRoles"])) : role["rolearn"] => role },
      { for role in toset([for k, node_group in module.eks.eks_managed_node_groups : {
        rolearn  = node_group.iam_role_arn
        username = "system:node:{{EC2PrivateDNSName}}"
        groups = concat([
          "system:bootstrappers",
          "system:nodes",
        ], node_group.platform == "windows" ? ["eks:kube-proxy-windows"] : [])
      }]) : role["rolearn"] => role }
    ) : roleobject])
    mapUsers    = data.kubernetes_config_map_v1.aws_auth_mapRoles_eks_managed_nodes.data["mapUsers"]
    mapAccounts = data.kubernetes_config_map_v1.aws_auth_mapRoles_eks_managed_nodes.data["mapAccounts"]
  }
  # It should be depended to the previous for sure we have only one task to update configmap
  depends_on = [kubernetes_config_map_v1_data.aws_auth_mapRoles_fargate_profiles]
}
data "kubernetes_config_map_v1" "aws_auth_mapRoles_self_managed_nodes" {
  metadata {
    name      = kubernetes_config_map.aws_auth.metadata[0].name
    namespace = kubernetes_config_map.aws_auth.metadata[0].namespace
  }
}
resource "kubernetes_config_map_v1_data" "aws_auth_mapRoles_self_managed_nodes" {
  force = true
  metadata {
    name      = kubernetes_config_map.aws_auth.metadata[0].name
    namespace = kubernetes_config_map.aws_auth.metadata[0].namespace
  }
  # Get the current configmap data and merge with the new one and update
  data = {
    mapRoles = yamlencode([for rolearn, roleobject in merge(
      { for role in toset(yamldecode(data.kubernetes_config_map_v1.aws_auth_mapRoles_self_managed_nodes.data["mapRoles"])) : role["rolearn"] => role },
      { for role in toset([for k, node_group in module.eks.self_managed_node_groups : {
        rolearn  = node_group.iam_role_arn
        username = "system:node:{{EC2PrivateDNSName}}"
        groups = concat([
          "system:bootstrappers",
          "system:nodes",
        ], node_group.platform == "windows" ? ["eks:kube-proxy-windows"] : [])
      }]) : role["rolearn"] => role }
    ) : roleobject])
    mapUsers    = data.kubernetes_config_map_v1.aws_auth_mapRoles_self_managed_nodes.data["mapUsers"]
    mapAccounts = data.kubernetes_config_map_v1.aws_auth_mapRoles_self_managed_nodes.data["mapAccounts"]
  }
  # It should be depended to the previous for sure we have only one task to update configmap
  depends_on = [kubernetes_config_map_v1_data.aws_auth_mapRoles_eks_managed_nodes]
}
# Update when having the karpenter roles data
data "kubernetes_config_map_v1" "aws_auth_mapRoles_karpenter_nodes" {
  metadata {
    name      = kubernetes_config_map.aws_auth.metadata[0].name
    namespace = kubernetes_config_map.aws_auth.metadata[0].namespace
  }
}
resource "kubernetes_config_map_v1_data" "aws_auth_mapRoles_karpenter_nodes" {
  force = true
  metadata {
    name      = kubernetes_config_map.aws_auth.metadata[0].name
    namespace = kubernetes_config_map.aws_auth.metadata[0].namespace
  }
  # Get the current configmap data and merge with the new one and update
  data = {
    # The karpenter is created via eks blueprints, we can not wait for all. Update it later
    # We just create configmap with node_group and fargate first because it's all in eks module
    mapRoles = yamlencode([for rolearn, roleobject in merge(
      { for role in toset(yamldecode(data.kubernetes_config_map_v1.aws_auth_mapRoles_karpenter_nodes.data["mapRoles"])) : role["rolearn"] => role },
      { for role in toset(module.eks_blueprints_addons.karpenter.node_iam_role_arn == "" ? [] : [
        # We need to add in the Karpenter node IAM role for nodes launched by Karpenter
        # If missed, the new node can not join to the cluster
        {
          rolearn  = module.eks_blueprints_addons.karpenter.node_iam_role_arn
          username = "system:node:{{EC2PrivateDNSName}}"
          groups = [
            "system:bootstrappers",
            "system:nodes",
          ]
        }
      ]) : role["rolearn"] => role }
    ) : roleobject])
    mapUsers    = data.kubernetes_config_map_v1.aws_auth_mapRoles_karpenter_nodes.data["mapUsers"]
    mapAccounts = data.kubernetes_config_map_v1.aws_auth_mapRoles_karpenter_nodes.data["mapAccounts"]
  }
  # It should be depended to the previous for sure we have only one task to update configmap
  depends_on = [kubernetes_config_map_v1_data.aws_auth_mapRoles_self_managed_nodes]
}
