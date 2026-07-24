terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

#####################################################
# VARIABLES
#####################################################

variable "environment" {
  default = "dev"
}

variable "ecr_image" {
  default = "123456789012.dkr.ecr.ap-south-1.amazonaws.com/my-app:latest"
}

#####################################################
# AVAILABILITY ZONES
#####################################################

data "aws_availability_zones" "available" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

#####################################################
# LATEST AMAZON LINUX AMI
#####################################################

data "aws_ami" "amazon_linux" {
  most_recent = true

  owners = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

#####################################################
# VPC
#####################################################

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "dev-vpc"
  }
}

#####################################################
# INTERNET GATEWAY
#####################################################

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

#####################################################
# PUBLIC SUBNETS
#####################################################

resource "aws_subnet" "public" {
  count = 3

  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet("10.0.0.0/16", 8, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "public-${count.index + 1}"
  }
}

#####################################################
# PRIVATE SUBNETS
#####################################################

resource "aws_subnet" "private" {
  count = 3

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]

  cidr_block = cidrsubnet(
    "10.0.0.0/16",
    8,
    count.index + 10
  )

  tags = {
    Name = "private-${count.index + 1}"
  }
}

#####################################################
# ISOLATED SUBNETS
#####################################################

resource "aws_subnet" "isolated" {
  count = 3

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]

  cidr_block = cidrsubnet(
    "10.0.0.0/16",
    8,
    count.index + 20
  )

  tags = {
    Name = "isolated-${count.index + 1}"
  }
}

#####################################################
# EIP FOR NAT
#####################################################

resource "aws_eip" "nat" {
  count  = 3
  domain = "vpc"
}

#####################################################
# NAT GATEWAYS
#####################################################

resource "aws_nat_gateway" "nat" {
  count = 3

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  depends_on = [aws_internet_gateway.igw]
}

#####################################################
# PUBLIC ROUTE TABLE
#####################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"

  gateway_id = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  count = 3

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

#####################################################
# PRIVATE ROUTE TABLES
#####################################################

resource "aws_route_table" "private" {
  count = 3

  vpc_id = aws_vpc.main.id
}

resource "aws_route" "private_nat" {
  count = 3

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"

  nat_gateway_id = aws_nat_gateway.nat[count.index].id
}

resource "aws_route_table_association" "private" {
  count = 3

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

#####################################################
# FLOW LOGS S3
#####################################################

resource "aws_s3_bucket" "flowlogs" {
  bucket = "dev-flowlogs-${random_id.bucket.hex}"
}

resource "random_id" "bucket" {
  byte_length = 4
}

resource "aws_flow_log" "vpc_flow_log" {
  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.flowlogs.arn

  traffic_type = "ALL"
  vpc_id       = aws_vpc.main.id
}

#####################################################
# SECURITY GROUPS
#####################################################

resource "aws_security_group" "alb_sg" {
  name   = "alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2_sg" {
  name   = "ec2-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["YOUR_PUBLIC_IP/32"]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = ["0.0.0.0/0"]
  }
}

#####################################################
# TARGET GROUP
#####################################################

resource "aws_lb_target_group" "tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"

  vpc_id = aws_vpc.main.id

  health_check {
    path = "/"
  }
}

#####################################################
# ALB
#####################################################

resource "aws_lb" "alb" {
  name               = "dev-alb"
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb_sg.id]

  subnets = aws_subnet.public[*].id
}

#####################################################
# LISTENER
#####################################################

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn

  port     = 80
  protocol = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

#####################################################
# USER DATA
#####################################################

locals {
  userdata = templatefile("${path.module}/userdata.sh.tpl", {
    image = var.ecr_image
  })
}

#####################################################
# LAUNCH TEMPLATE
#####################################################

resource "aws_launch_template" "app" {
  name_prefix   = "app-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  vpc_security_group_ids = [
    aws_security_group.ec2_sg.id
  ]

  user_data = base64encode(local.userdata)
}

#####################################################
# AUTOSCALING GROUP
#####################################################

resource "aws_autoscaling_group" "asg" {

  desired_capacity = 2
  max_size         = 4
  min_size         = 2

  vpc_zone_identifier = aws_subnet.private[*].id

  target_group_arns = [
    aws_lb_target_group.tg.arn
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  health_check_type = "ELB"
}

#####################################################
# OUTPUTS
#####################################################

output "alb_dns_name" {
  value = aws_lb.alb.dns_name
}

output "vpc_id" {
  value = aws_vpc.main.id
}
