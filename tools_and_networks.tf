# Filter out local zones, which are not currently supported 
# with managed node groups
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
resource "null_resource" "tools_and_networks" {
  depends_on = [
    module.vpc,
    local_file.key_pair_pem,
    local_file.key_pair_pub,
    aws_instance.nat_instance,
    aws_network_interface.nat_instance,
    aws_eip.nat_instance,
    aws_route.nat-instance-ipv4,
    aws_security_group.nat_instance,
    null_resource.wild_resources,
    aws_instance.workstation,
    aws_ebs_volume.workstation,
    aws_volume_attachment.workstation,
    aws_security_group.workstation,
  ]
}
################################################################################
# VPC Module
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.1.0"

  name = local.cluster_name
  cidr = format("%s.0.0/16", var.ipv4_prefix)

  azs = data.aws_availability_zones.available.names
  # Function cidrsubnet(prefix, newbits, netnum)
  # For example:
  # prefix - 10.0.0.0/16
  # newbits 7, cidr will be 10.0.0.0/23 (7 + 16): 10.0.0.0 - 10.0.1.255
  # netnum: numerical order of range, first: 10.0.0.0/23, second: 10.0.2.0/23, third: 10.0.4.0/23
  # Use website: https://www.ipaddressguide.com/cidr
  # Use website: https://terraform-online-console.com/
  # /28: 0.0 - 0.15, 0.16 - 0.31, 0.32 - 0.47, 0.48 - 0.63, 0.64 - 0.80, ..., 240 - 255, ..., 1.208 - 1.223. (k: 0-29)
  intra_subnets = [for k, v in data.aws_availability_zones.available.names : cidrsubnet(format("%s.0.0/16", var.ipv4_prefix), 12, k)]
  # /28: 1.224 - 1.239, 3.160 - 3.175. (k + 30: 30-59)
  database_subnets = [for k, v in data.aws_availability_zones.available.names : cidrsubnet(format("%s.0.0/16", var.ipv4_prefix), 12, k + 30)]
  # /24: 4.0 - 33.255. (k+4: 4 - 33)
  public_subnets = [for k, v in data.aws_availability_zones.available.names : cidrsubnet(format("%s.0.0/16", var.ipv4_prefix), 8, k + 4)]
  # /22: 56.0 - 167.255. (k+14: 14 - 41)
  private_subnets = [for k, v in data.aws_availability_zones.available.names : cidrsubnet(format("%s.0.0/16", var.ipv4_prefix), 6, k + 14)]

  # Enable nat gateway to allow private subnet can access the internet
  enable_nat_gateway = local.enable_internet_egress ? local.enable_nat_instance ? false : true : false

  # Single NAT is just for dev only
  # Multi NAT is recommended for production environment
  # Current AWS NAT GW just support for ipv4
  # Because EKS API endpoint is an IPv4 public DNS but worker nodes are in private subnet
  # Worker node just can connect via NAT gateway 
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  create_database_subnet_route_table = true
  # Dont allow internet access for database
  create_database_internet_gateway_route = false

  ##########################
  ######### IPv6 ###########
  ##########################
  enable_ipv6            = true
  create_egress_only_igw = local.enable_internet_egress ? true : false
  # Design subnets for IPv6
  intra_subnet_ipv6_prefixes    = [for k, v in data.aws_availability_zones.available.names : k]
  database_subnet_ipv6_prefixes = [for k, v in data.aws_availability_zones.available.names : k + 10]
  public_subnet_ipv6_prefixes   = [for k, v in data.aws_availability_zones.available.names : k + 20]
  private_subnet_ipv6_prefixes  = [for k, v in data.aws_availability_zones.available.names : k + 30]
  # Enable to assign ipv6 on private subnet to allow going out by ipv6
  intra_subnet_assign_ipv6_address_on_creation    = true
  database_subnet_assign_ipv6_address_on_creation = true
  public_subnet_assign_ipv6_address_on_creation   = true
  private_subnet_assign_ipv6_address_on_creation  = true

  ##########################
  ######## DNS64 ###########
  ##########################
  # Just enable when cluster IPv6 only but wanting to reach out by IPv4
  intra_subnet_enable_dns64    = false
  database_subnet_enable_dns64 = true
  public_subnet_enable_dns64   = false
  private_subnet_enable_dns64  = false

  # Tags
  intra_subnet_tags = merge(var.tags, {
    Name = "intra-${local.cluster_name}"
  })

  public_subnet_tags = merge(var.tags, {
    Name                     = "public-${local.cluster_name}"
    "kubernetes.io/role/elb" = 1
  })

  public_route_table_tags = merge(var.tags, {
    Name = "public-${local.cluster_name}"
  })

  private_subnet_tags = merge(var.tags, {
    Name                              = "private-${local.cluster_name}"
    "kubernetes.io/role/internal-elb" = 1
    # Set tag for discovering by karpenter
    "karpenter.sh/discovery" = local.cluster_name
  })

  private_route_table_tags = merge(var.tags, {
    Name = "private-${local.cluster_name}"
  })

  database_subnet_tags = merge(var.tags, {
    Name = "database-${local.cluster_name}"
  })

  database_route_table_tags = merge(var.tags, {
    Name = "database-${local.cluster_name}"
  })

  tags = merge(var.tags, {
    Name = "${local.cluster_name}"
  })
}

###################################################
################# NAT instance ####################
###################################################
resource "aws_security_group" "nat_instance" {
  count       = local.enable_internet_egress ? local.enable_internet_egress ? local.enable_nat_instance ? 1 : 0 : 0 : 0
  name        = "nat_instance"
  description = "Some rules for nat instance"
  vpc_id      = module.vpc.vpc_id

  # Allow all connections from the same VPC
  ingress {
    description      = "All"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = [module.vpc.vpc_cidr_block]
    ipv6_cidr_blocks = [module.vpc.vpc_ipv6_cidr_block]
  }

  # Allow to go to the internet
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  tags = merge(var.tags, {
    Name = "nat-${local.cluster_name}"
  })
}

resource "aws_network_interface" "nat_instance" {
  count             = local.enable_internet_egress ? local.enable_nat_instance ? 1 : 0 : 0
  subnet_id         = module.vpc.public_subnets[0]
  security_groups   = [aws_security_group.nat_instance[0].id]
  source_dest_check = false
  tags = merge(var.tags, {
    Name = "NAT-${local.cluster_name}"
  })
}

# Request an elastic IP for nat network interface
# AWS just allow to request public IP for free when creating instance, network interface at zero index
# If we create a dedicated network interface before creating instance, we must use an elastic IP
resource "aws_eip" "nat_instance" {
  count             = local.enable_internet_egress ? local.enable_nat_instance ? 1 : 0 : 0
  domain            = "vpc"
  network_interface = aws_network_interface.nat_instance[0].id
  tags = merge(var.tags, {
    Name = "nat_instance-${local.cluster_name}"
  })
}

# Add nat instance to route table
resource "aws_route" "nat-instance-ipv4" {
  count                  = local.enable_internet_egress ? local.enable_nat_instance ? length(module.vpc.private_route_table_ids) : 0 : 0
  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_network_interface.nat_instance[0].id
}

data "aws_ami" "nat_instance" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "name"
    values = ["amzn-ami-vpc-nat-*"]
  }
}

resource "aws_instance" "nat_instance" {
  count         = local.enable_internet_egress ? local.enable_nat_instance ? 1 : 0 : 0
  ami           = data.aws_ami.nat_instance.id
  instance_type = "t3a.nano"

  root_block_device {
    volume_type = "standard"
    volume_size = 8
    encrypted   = false
    tags = merge(var.tags, {
      Name = "nat_instance-root-${local.cluster_name}"
    })
  }
  # Add nat network interface to the instance at index 0  (first interface)
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.nat_instance[0].id
  }

  instance_market_options {
    market_type = "spot"
    spot_options {
      # If this instance is claimed by aws, we can start again to use because it's just stopped, not terminated
      instance_interruption_behavior = "stop"
      spot_instance_type             = "persistent"
    }
  }

  tags = merge(var.tags, {
    Name = "nat_instance-${local.cluster_name}"
  })

  # Waiting for the instance ready
  provisioner "local-exec" {
    when    = create
    command = "sleep 120s"
  }
}


data "aws_ami" "amazon-x86_64" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "name"
    values = ["al2023-ami-2023*"]
  }
}

resource "aws_instance" "workstation" {
  ami                    = data.aws_ami.amazon-x86_64.id
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.workstation.id]
  key_name               = module.key_pair.key_pair_name
  user_data              = <<EOT
#!/bin/bash
set -e
USER="ec2-user"
HOME_DIR="/home/$${USER}"

DEVICE="/dev/sdf"
if [ -f "$${DEVICE}" -o -h "$${DEVICE}" ]; then
    MOUNT_POINT="$${HOME_DIR}/data"
    echo "Do mount device $${DEVICE} to $${MOUNT_POINT}"
    mkdir -p "$${MOUNT_POINT}"
    chown -R $${USER}:$${USER} "$${MOUNT_POINT}"
    while ! mount "$${DEVICE}" "$${MOUNT_POINT}"; do
        echo "Mount is not ok"
        echo "Formating device"
        if mkfs -t xfs "$${DEVICE}"; then
          echo "Format is ok"
          echo "Mount again"
        else
          echo "Format is not ok"
          echo "Can not mount"
        fi
    done
fi

ssh_dir="$${HOME_DIR}/.ssh"
mkdir -p "$${ssh_dir}"
tee $${ssh_dir}/id_rsa &>/dev/null <<EOF
${module.key_pair.private_key_pem}
EOF
chmod 644 $${ssh_dir}/id_rsa
EOT
  instance_market_options {
    market_type = "spot"
    spot_options {
      # If this instance is claimed by aws, we can start again to use because it's just stop, not terminated
      instance_interruption_behavior = "stop"
      spot_instance_type             = "persistent"

      # Do not set this one, it is always replaced every running terraform
      # Instance will be hibernated after 1 hour
      # valid_until = timeadd(timestamp(), "1h") # 2018-05-13T07:44:12Z UTC format (YYYY-MM-DDTHH:MM:SSZ)
    }
  }
  associate_public_ip_address = true
  root_block_device {
    volume_type = "standard"
    volume_size = 8
    encrypted   = false
    tags = merge(var.tags, {
      Name = "workstation-root-${local.cluster_name}"
    })
    delete_on_termination = true
  }
  ebs_optimized = false
  monitoring    = false
  tags = merge(var.tags, {
    Name = "workstation-${local.cluster_name}"
  })

  depends_on = [aws_security_group.workstation]
}

resource "aws_ebs_volume" "workstation" {
  availability_zone = module.vpc.azs[0]
  size              = 10
  type              = "standard"
  tags = merge(var.tags, {
    Name = "workstation-data-${local.cluster_name}"
  })
}
resource "aws_volume_attachment" "workstation" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.workstation.id
  instance_id = aws_instance.workstation.id
}

resource "aws_security_group" "workstation" {
  name        = "workstation"
  description = "Some rules for workstation"
  vpc_id      = module.vpc.vpc_id
  # Allow ssh from the internet
  ingress {
    description      = "SSH access"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  # Allow going out all targets
  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
  tags = merge(var.tags, {
    Name = "workstation-${local.cluster_name}"
  })
}

# Delete all wild resources
resource "null_resource" "wild_resources" {
  triggers = {
    cluster_name          = local.cluster_name
    AWS_ACCESS_KEY_ID     = var.AWS_ACCESS_KEY
    AWS_SECRET_ACCESS_KEY = var.AWS_SECRET_KEY
    AWS_DEFAULT_REGION    = var.AWS_DEFAULT_REGION
  }

  # Delete karpenter instances
  provisioner "local-exec" {
    when = destroy
    # We must have aws cli in the local computer
    command = "instance_ids=$(aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId' --filters \"Name=tag:karpenter.sh/managed-by,Values=${self.triggers.cluster_name}\" --output text); if [[ -n \"$${instance_ids}\" ]]; then aws ec2 terminate-instances --instance-ids $${instance_ids}; fi"
    environment = {
      AWS_ACCESS_KEY_ID     = self.triggers.AWS_ACCESS_KEY_ID
      AWS_SECRET_ACCESS_KEY = self.triggers.AWS_SECRET_ACCESS_KEY
      AWS_DEFAULT_REGION    = self.triggers.AWS_DEFAULT_REGION
    }
  }
}

module "key_pair" {
  source  = "terraform-aws-modules/key-pair/aws"
  version = "~> 2.0"

  key_name_prefix    = local.cluster_name
  create_private_key = true

  tags = var.tags
}

resource "local_file" "key_pair_pem" {
  content         = module.key_pair.private_key_pem
  filename        = "${path.module}/key_pair.pem"
  file_permission = "0600" # Only read write for owner
  depends_on      = [module.key_pair]
}

resource "local_file" "key_pair_pub" {
  content         = module.key_pair.public_key_openssh
  filename        = "${path.module}/key_pair.pub"
  file_permission = "0600" # Only read write for owner
  depends_on      = [module.key_pair]
}

