data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-hirsute-21.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_security_group_rule" "allow_ssh_inbound" {
  count       = length(var.allowed_ssh_cidr_blocks) >= 1 ? 1 : 0
  type        = "ingress"
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = var.allowed_ssh_cidr_blocks

  security_group_id = var.security_group_id
}

resource "aws_security_group_rule" "allow_nomad_inbound" {
  count       = length(var.allowed_http_cidr_blocks) >= 1 ? 1 : 0
  type        = "ingress"
  from_port   = 8081
  to_port     = 8081
  protocol    = "tcp"
  cidr_blocks = var.allowed_http_cidr_blocks

  security_group_id = var.security_group_id
}

resource "aws_security_group_rule" "allow_http_inbound" {
  count       = length(var.allowed_http_cidr_blocks) >= 1 ? 1 : 0
  type        = "ingress"
  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  cidr_blocks = var.allowed_http_cidr_blocks

  security_group_id = var.security_group_id
}

resource "aws_ecs_cluster" "clients" {
  name = "${random_id.id.dec}-hcp-ecs-cluster"
  capacity_providers = ["FARGATE"]
}

resource "random_id" "id" {
  prefix      = "consul-client"
  byte_length = 8
}

resource "aws_secretsmanager_secret" "bootstrap_token" {
  name  = "consul-ecs-bootstrap-token"
}

resource "aws_secretsmanager_secret_version" "bootstrap_token" {
  secret_id     = aws_secretsmanager_secret.bootstrap_token.id
  secret_string = var.root_token
}

resource "aws_secretsmanager_secret" "ca_cert" {
  name  = "consul-ecs-client-ca-cert"
}

resource "aws_secretsmanager_secret_version" "ca_cert" {
  secret_id     = aws_secretsmanager_secret.ca_cert.id
  secret_string = var.client_ca_file
}

resource "aws_secretsmanager_secret" "gossip_key" {
  name  = "consul-ecs-gossip-encryption-key"
}

resource "aws_secretsmanager_secret_version" "gossip_key" {
  secret_id     = aws_secretsmanager_secret.gossip_key.id
  secret_string = var.client_gossip_key
}


module "consul-ecs_acl-controller" {
  source  = "hashicorp/consul-ecs/aws//modules/acl-controller"
  version = "0.2.0-beta2"

  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.log_group.name
      awslogs-region        = var.region
      awslogs-stream-prefix = "consul-acl-controller"
    }
  }

  consul_bootstrap_token_secret_arn = aws_secretsmanager_secret.bootstrap_token.arn
  consul_server_http_addr           = var.consul_url
  consul_server_ca_cert_arn         = aws_secretsmanager_secret.ca_cert.arn
  ecs_cluster_arn                   = aws_ecs_cluster.clients.arn
  region                            = var.region
  subnets                           = [var.subnet_id]
  // TODO: make unique
  name_prefix                       = "consul-ecs"
}

resource "aws_cloudwatch_log_group" "log_group" {
  name = "something-log"
}

module "product-db" {
  source  = "hashicorp/consul-ecs/aws//modules/mesh-task"
  version = "0.2.0-beta2"

  family                = "product-db"
  container_definitions = [
    {
      name         = "product-db"
      image = "hashicorpdemoapp/product-api-db:v0.0.17"
      essential    = true
      portMappings = [
        {
          containerPort = 5432
          protocol      = "tcp"
        }
      ]

      environment = [
        {
          name = "POSTGRES_DB"
          value= "products"
        },
        {
          name = "POSTGRES_USER"
          value= "postgres"
        },
        {
          name = "POSTGRES_PASSWORD"
          value= "password"
        },
      ]
      cpu         = 0
      mountPoints = []
      volumesFrom = []
    }
  ]

  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.log_group.name
      awslogs-region        = var.region
      awslogs-stream-prefix = "product-db"
    }
  }

  port       = "5432"
  retry_join = var.client_retry_join

  tls                            = true
  consul_server_ca_cert_arn      = aws_secretsmanager_secret.ca_cert.arn
  gossip_key_secret_arn          = aws_secretsmanager_secret.gossip_key.arn

  acls                           = true
  consul_client_token_secret_arn = module.consul-ecs_acl-controller.client_token_secret_arn
  // TODO: use the unique name from above
  acl_secret_name_prefix         = "consul-ecs"
}

