# https://github.com/kubernetes/org/issues/4258
# https://docs.google.com/document/d/1rHhltfLV5V1kcnKr_mKRKDC4ZFPYGP4Tde2Zy-LE72w/edit#heading=h.iof64m6gewln

module "karpenter_default_nodepool" {
  source          = "./modules/kubectl_apply"
  kubeconfig_file = abspath(local_file.kubeconfig.filename)
  kubectl_context = "aws"
  # Enough time for shutting down all instances
  delay_after_detroying = 180
  # https://karpenter.sh/v0.32/concepts/nodepools/
  # Becareful when updating this manifest because all nodeclaims will be terminated
  manifest = <<-EOF
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: default
    spec:
      disruption:
        consolidationPolicy: WhenUnderutilized
        expireAfter: 168h0m0s
      limits:
        cpu: 100k
        memory: 5000Gi
      template:
        spec:
          kubelet: {}
          nodeClassRef:
            apiVersion: karpenter.k8s.aws/v1beta1
            kind: EC2NodeClass
            name: default
          requirements:
          - key: karpenter.k8s.aws/instance-family
            operator: NotIn
            values:
            - m1
            - m2
            - m3
          - key: topology.kubernetes.io/zone
            operator: In
            values:
            - ap-southeast-1a
            - ap-southeast-1b
            - ap-southeast-1c
          - key: karpenter.k8s.aws/instance-cpu
            operator: In
            values:
            - "2"
            - "4"
            - "8"
            - "16"
            - "32"
          - key: karpenter.k8s.aws/instance-memory
            operator: In
            values:
            - "1024"
            - "2048"
            - "4096"
            - "8192"
            - "16384"
          - key: karpenter.k8s.aws/instance-gpu-count
            operator: DoesNotExist
          - key: kubernetes.io/os
            operator: In
            values:
            - linux
          - key: kubernetes.io/arch
            operator: In
            values:
            - arm64
            - amd64
          - key: karpenter.k8s.aws/instance-generation
            operator: Gt
            values:
            - "2"
          - key: karpenter.sh/capacity-type
            operator: In
            values:
            - spot
            - on-demand
    EOF
  depends_on = [
    null_resource.stable_cluster,
    module.karpenter_default_nodeclass,
  ]
}

module "karpenter_default_nodeclass" {
  source                = "./modules/kubectl_apply"
  kubeconfig_file       = abspath(local_file.kubeconfig.filename)
  kubectl_context       = "aws"
  delay_before_creating = 60
  # Ignore deleting this resource, because it can lead to hang
  ignore_delete = true
  # tags.Name must have "karpenter" keyword, karpenter just has permission
  manifest = <<-EOF
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2
      subnetSelectorTerms:          
        - tags:
            karpenter.sh/discovery: ${local.cluster_name}
      securityGroupSelectorTerms:   
        - tags:
            karpenter.sh/discovery: ${local.cluster_name}
      role: "${module.eks_blueprints_addons.karpenter.node_iam_role_name}"
      blockDeviceMappings:
      - deviceName: /dev/xvda
        ebs:
          volumeSize: 20Gi
          volumeType: gp3
          encrypted: false
          deleteOnTermination: true
      tags:                  
        Name: default-${local.cluster_name}-karpenter
      detailedMonitoring: false
      userData: |
        # Allow SSH access
        echo "${module.key_pair.public_key_openssh}" >> /home/ec2-user/.ssh/authorized_keys
    EOF
  depends_on = [
    # Module karpenter must set wait = true for sure we have some CRD for karpenter
    module.eks_blueprints_addons.karpenter,
    null_resource.aws_eks,
  ]
}
