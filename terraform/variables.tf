variable "aws_region" {
  description = "AWS region to launch the instance in"
  type        = string
  default     = "us-east-1"
}

variable "instance_name" {
  description = "Value for the Name tag on the instance"
  type        = string
  default     = "house-price-predictor"
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access (leave null for none)"
  type        = string
  default     = null
}

variable "security_group_ids" {
  description = "List of security group IDs to attach to the instance"
  type        = list(string)
  default     = []
}

variable "subnet_id" {
  description = "Subnet ID to launch the instance in (leave null to use the default VPC/subnet)"
  type        = string
  default     = null
}
