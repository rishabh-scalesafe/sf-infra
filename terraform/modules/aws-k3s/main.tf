# k3s cluster on plain AWS EC2 instances (1 server + N agents).

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  name = var.cluster_name
  tags = merge({ project = "scalesafe", cluster = var.cluster_name, managed_by = "terraform" }, var.tags)
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = "${local.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-igw" })
}

resource "aws_subnet" "nodes" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${local.name}-nodes" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${local.name}-public" })
}

resource "aws_route_table_association" "nodes" {
  subnet_id      = aws_subnet.nodes.id
  route_table_id = aws_route_table.public.id
}

# Lock down the VPC default security group (CIS AWS 5.4).
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-default-locked" })
}

resource "aws_security_group" "nodes" {
  name        = "${local.name}-nodes"
  description = "ScaleSafe k3s nodes"
  vpc_id      = aws_vpc.this.id
  tags        = merge(local.tags, { Name = "${local.name}-nodes" })
}

resource "aws_vpc_security_group_ingress_rule" "intra_cluster" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  description                  = "node-to-node (flannel, kubelet, apiserver)"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  description       = "ssh admin"
}

resource "aws_vpc_security_group_ingress_rule" "kubeapi" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
  description       = "kube-apiserver admin"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  for_each          = toset(var.web_cidrs)
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each          = toset(var.web_cidrs)
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_key_pair" "admin" {
  key_name   = "${local.name}-admin"
  public_key = var.ssh_public_key
  tags       = local.tags
}

# ---------------------------------------------------------------- server
resource "aws_eip" "server" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${local.name}-server" })
}

locals {
  server_private_ip = cidrhost(var.subnet_cidr, 10)
}

module "server_init" {
  source       = "../k3s-cloudinit"
  role         = "server"
  k3s_version  = var.k3s_version
  k3s_token    = var.k3s_token
  tls_sans     = concat([aws_eip.server.public_ip], var.extra_tls_sans)
  cloud        = "aws"
  cluster_name = var.cluster_name
}

resource "aws_instance" "server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.server_instance_type
  subnet_id              = aws_subnet.nodes.id
  private_ip             = local.server_private_ip
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.admin.key_name
  user_data_base64       = base64encode(module.server_init.rendered)

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.disk_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.tags, { Name = "${local.name}-server-0", role = "server" })

  lifecycle {
    ignore_changes = [ami, user_data_base64]
  }
}

resource "aws_eip_association" "server" {
  instance_id   = aws_instance.server.id
  allocation_id = aws_eip.server.id
}

# ---------------------------------------------------------------- agents
module "agent_init" {
  source       = "../k3s-cloudinit"
  role         = "agent"
  k3s_version  = var.k3s_version
  k3s_token    = var.k3s_token
  server_url   = "https://${local.server_private_ip}:6443"
  cloud        = "aws"
  cluster_name = var.cluster_name
}

resource "aws_instance" "agent" {
  count                  = var.agent_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.agent_instance_type
  subnet_id              = aws_subnet.nodes.id
  vpc_security_group_ids = [aws_security_group.nodes.id]
  key_name               = aws_key_pair.admin.key_name
  user_data_base64       = base64encode(module.agent_init.rendered)

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.disk_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.tags, { Name = "${local.name}-agent-${count.index}", role = "agent" })

  lifecycle {
    ignore_changes = [ami, user_data_base64]
  }

  depends_on = [aws_instance.server]
}
