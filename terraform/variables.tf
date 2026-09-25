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

variable "vpc_cidr" {
  description = "CIDR block for the ml-coursera VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the ml-coursera public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "availability_zone" {
  description = "Availability zone for the ml-coursera subnet"
  type        = string
  default     = "us-east-1a"
}

variable "key_name" {
  description = "Name of the existing EC2 key pair for SSH access"
  type        = string
  default     = "house-price-predictor-20260917"
}
