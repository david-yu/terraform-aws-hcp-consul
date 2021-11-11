variable "subnet_id" {
  type        = string
  description = "The subnet ID to create EC2 clients in"
}

variable "allowed_ssh_cidr_blocks" {
  description = "A list of CIDR-formatted IP address ranges from which the EC2 Instances will allow SSH connections"
  type        = list(string)
  default     = []
}

variable "allowed_http_cidr_blocks" {
  description = "A list of CIDR-formatted IP address ranges from which the EC2 Instances will allow connections over 8080"
  type        = list(string)
  default     = []
}

variable "client_config_file" {
  type        = string
  description = "The client config file provided by HCP"
}

variable "client_ca_file" {
  type        = string
  description = "The Consul client CA file provided by HCP"
}

variable "root_token" {
  type        = string
  description = "The Consul Secret ID of the Consul root token"
}

variable "consul_url" {
  type = string
  description = "The Consul URL"
}

variable "client_gossip_key" {
  type = string
  description = "The gossip key"
}

variable "client_retry_join" {
  type = list(string)
  description = "The retry join endpoints"
}

variable "datacenter" {
  type = string
  description = "The consul datacenter"
}

variable "region" {
  type = string
  description = "The AWS region"
}

variable "security_group_id" {
  type = string
}
