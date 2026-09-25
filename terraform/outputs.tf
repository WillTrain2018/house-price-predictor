output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.this.public_ip
}

output "ami_id" {
  description = "AMI ID used for the instance"
  value       = data.aws_ami.ubuntu_22_04.id
}

output "vpc_id" {
  description = "VPC ID used by the instance"
  value       = aws_vpc.ml_coursera.id
}

output "subnet_id" {
  description = "Subnet ID used by the instance"
  value       = aws_subnet.ml_coursera.id
}

output "route_table_id" {
  description = "Route table ID for the public subnet"
  value       = aws_route_table.ml_coursera.id
}

output "internet_gateway_id" {
  description = "Internet gateway ID attached to the VPC"
  value       = aws_internet_gateway.ml_coursera.id
}

output "security_group_id" {
  description = "Security group ID attached to the instance"
  value       = aws_security_group.ml_coursera.id
}

output "key_name" {
  description = "EC2 key pair name used by the instance"
  value       = var.key_name
}
