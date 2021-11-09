terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.43"
    }
    hcp = {
      source  = "hashicorp/hcp"
      version = "~> 0.19"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.4"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.3"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.11"
    }
  }
}

locals {
  vpc_region     = "{{ .VPCRegion }}"
  hvn_region     = "{{ .HVNRegion }}"
  cluster_id     = "{{ .ClusterID }}"
  vpc_id         = "{{ .VPCID }}"
  route_table_id = "{{ .RouteTableID }}"
  subnet1        = "{{ .Subnet1 }}"
  subnet2        = "{{ .Subnet2 }}"
}

provider "aws" {
  region = local.vpc_region
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "17.22.0"

  cluster_name    = "${local.cluster_id}-eks"
  cluster_version = "1.21"
  subnets         = [local.subnet1, local.subnet2]
  vpc_id          = local.vpc_id

  node_groups = {
    application = {
      instance_types   = ["t3a.medium"]
      desired_capacity = 3
      max_capacity     = 3
      min_capacity     = 3
    }
  }
}

resource "hcp_hvn" "main" {
  hvn_id         = "${local.cluster_id}-hvn"
  cloud_provider = "aws"
  region         = local.hvn_region
  cidr_block     = "172.25.32.0/20"
}

module "aws_hcp_consul" {
  source  = "hashicorp/hcp-consul/aws"
  version = "0.3.0"

  hvn                = hcp_hvn.main
  vpc_id             = local.vpc_id
  subnet_ids         = [local.subnet1, local.subnet2]
  route_table_ids    = [local.route_table_id]
  security_group_ids = [module.eks.cluster_primary_security_group_id]
}

resource "hcp_consul_cluster" "main" {
  cluster_id      = local.cluster_id
  hvn_id          = hcp_hvn.main.hvn_id
  public_endpoint = true
  tier            = "development"
}

resource "hcp_consul_cluster_root_token" "token" {
  cluster_id = hcp_consul_cluster.main.id
}

module "eks_consul_client" {
  source  = "hashicorp/hcp-consul/aws//modules/hcp-eks-client"
  version = "0.3.0"

  cluster_id       = hcp_consul_cluster.main.cluster_id
  consul_hosts     = jsondecode(base64decode(hcp_consul_cluster.main.consul_config_file))["retry_join"]
  k8s_api_endpoint = module.eks.cluster_endpoint

  boostrap_acl_token    = hcp_consul_cluster_root_token.token.secret_id
  consul_ca_file        = base64decode(hcp_consul_cluster.main.consul_ca_file)
  datacenter            = hcp_consul_cluster.main.datacenter
  gossip_encryption_key = jsondecode(base64decode(hcp_consul_cluster.main.consul_config_file))["encrypt"]

  depends_on = [module.eks]
}

module "demo_app" {
  source     = "hashicorp/hcp-consul/aws//modules/k8s-demo-app"
  version    = "0.3.0"
  depends_on = [module.eks_consul_client]
}

output "consul_root_token" {
  value     = hcp_consul_cluster_root_token.token.secret_id
  sensitive = true
}

output "consul_url" {
  value = hcp_consul_cluster.main.consul_public_endpoint_url
}

output "kubeconfig_filename" {
  value = abspath(module.eks.kubeconfig_filename)
}

output "hashicups_url" {
  value = module.demo_app.hashicups_url
}