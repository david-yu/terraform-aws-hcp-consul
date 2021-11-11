data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "2.78.0"

  name                 = "${var.cluster_id}-vpc"
  cidr                 = "10.0.0.0/16"
  azs                  = data.aws_availability_zones.available.names
  private_subnets      = []
  public_subnets       = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  enable_dns_hostnames = true
}

# The HVN created in HCP
resource "hcp_hvn" "main" {
  hvn_id         = var.hvn_id
  cloud_provider = "aws"
  region         = var.region
  cidr_block     = var.hvn_cidr_block
}

module "aws_hcp_consul" {
  source = "../../../terraform-aws-hcp-consul/"

  hvn             = hcp_hvn.main
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.public_subnets
  route_table_ids = module.vpc.public_route_table_ids
}

resource "hcp_consul_cluster" "main" {
  cluster_id      = var.cluster_id
  hvn_id          = hcp_hvn.main.hvn_id
  public_endpoint = !var.disable_public_url
  size            = var.size
  tier            = var.tier
}

resource "hcp_consul_cluster_root_token" "token" {
  cluster_id = hcp_consul_cluster.main.id
}

module "aws_ecs_cluster" {
  source = "../../modules/hcp-ecs-client"

  subnet_id                = module.vpc.public_subnets[0]
  security_group_id        = module.aws_hcp_consul.security_group_id
  allowed_ssh_cidr_blocks  = ["0.0.0.0/0"]
  allowed_http_cidr_blocks = ["0.0.0.0/0"]
  client_config_file       = hcp_consul_cluster.main.consul_config_file
  client_ca_file           = hcp_consul_cluster.main.consul_ca_file
  client_gossip_key        = jsondecode(base64decode(hcp_consul_cluster.main.consul_config_file))["encrypt"]
  client_retry_join        = jsondecode(base64decode(hcp_consul_cluster.main.consul_config_file))["retry_join"][0]
  region                   = var.region
  root_token               = hcp_consul_cluster_root_token.token.secret_id
  consul_url = hcp_consul_cluster.main.public_endpoint ? (
    hcp_consul_cluster.main.consul_public_endpoint_url
    ) : (
    hcp_consul_cluster.main.consul_private_endpoint_url
  )

  depends_on = [module.aws_hcp_consul]
}