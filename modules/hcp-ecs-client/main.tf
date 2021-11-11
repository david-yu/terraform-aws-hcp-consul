locals {
  secret_prefix = "consul-ecs-test"
}

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
  name  = "${local.secret_prefix}-bootstrap-token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "bootstrap_token" {
  secret_id     = aws_secretsmanager_secret.bootstrap_token.id
  secret_string = var.root_token
}

resource "aws_secretsmanager_secret" "ca_cert" {
  name  = "${local.secret_prefix}-client-ca-cert"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ca_cert" {
  secret_id     = aws_secretsmanager_secret.ca_cert.id
  secret_string = base64decode(var.client_ca_file)
}

resource "aws_secretsmanager_secret" "gossip_key" {
  name  = "${local.secret_prefix}-gossip-encryption-key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "gossip_key" {
  secret_id     = aws_secretsmanager_secret.gossip_key.id
  secret_string = var.client_gossip_key
}


module "acl-controller" {
  source = "git::https://github.com/hashicorp/terraform-aws-consul-ecs.git//modules/acl-controller?ref=pglass/expose-public-ip-setting"

  log_configuration = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.log_group.name
      awslogs-region        = var.region
      awslogs-stream-prefix = "consul-acl-controller"
    }
  }

  consul_server_http_addr           = var.consul_url
  consul_bootstrap_token_secret_arn = aws_secretsmanager_secret.bootstrap_token.arn
  ecs_cluster_arn                   = aws_ecs_cluster.clients.arn
  region                            = var.region
  subnets                           = [var.subnet_id]

  name_prefix                       = local.secret_prefix

  assign_public_ip = true
}

resource "aws_cloudwatch_log_group" "log_group" {
  name = "something-log"
}

module "product_db" {
  source = "git::https://github.com/hashicorp/terraform-aws-consul-ecs.git//modules/mesh-task?ref=pglass/expose-public-ip-setting"

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
  consul_ecs_image = "docker.mirror.hashicorp.services/hashicorpdev/consul-ecs:latest"

  retry_join = var.client_retry_join
  consul_datacenter = var.datacenter

  tls                            = true
  consul_server_ca_cert_arn      = aws_secretsmanager_secret.ca_cert.arn
  gossip_key_secret_arn          = aws_secretsmanager_secret.gossip_key.arn

  acls                           = true
  consul_client_token_secret_arn = module.acl-controller.client_token_secret_arn
  // TODO: use the unique name from above
  acl_secret_name_prefix         = local.secret_prefix
}

resource "aws_ecs_service" "product_db" {
  name            = "product-db"
  cluster         = aws_ecs_cluster.clients.arn
  task_definition = module.product_db.task_definition_arn
  desired_count   = 1
  network_configuration {
    subnets = [var.subnet_id]
    assign_public_ip = true
  }
  launch_type            = "FARGATE"
  propagate_tags         = "TASK_DEFINITION"
  enable_execute_command = true
}
