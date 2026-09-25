terraform {
  required_version = ">= 1.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_vpc" "ml_coursera" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "ml-coursera"
  }
}

resource "aws_subnet" "ml_coursera" {
  vpc_id                  = aws_vpc.ml_coursera.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "ml-coursera"
  }
}

resource "aws_internet_gateway" "ml_coursera" {
  vpc_id = aws_vpc.ml_coursera.id

  tags = {
    Name = "ml-coursera"
  }
}

resource "aws_route_table" "ml_coursera" {
  vpc_id = aws_vpc.ml_coursera.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ml_coursera.id
  }

  tags = {
    Name = "ml-coursera"
  }
}

resource "aws_route_table_association" "ml_coursera" {
  subnet_id      = aws_subnet.ml_coursera.id
  route_table_id = aws_route_table.ml_coursera.id
}

resource "aws_security_group" "ml_coursera" {
  name        = "ml-coursera"
  description = "SSH access for the ml-coursera EC2 instance"
  vpc_id      = aws_vpc.ml_coursera.id

  ingress {
    description = "SSH from approved public IPv4 address"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["71.113.76.77/32"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ml-coursera"
  }
}

# Latest Ubuntu 22.04 LTS (Jammy) AMI, published by Canonical (owner ID 099720109477)
data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu_22_04.id
  instance_type          = "t3.micro"
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.ml_coursera.id]
  subnet_id              = aws_subnet.ml_coursera.id

  associate_public_ip_address = true

  tags = {
    Name = var.instance_name
  }
}
