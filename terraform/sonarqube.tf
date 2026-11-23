# SonarQube server: one EC2 instance in a public subnet of this project's VPC
# (network.tf) running SonarQube +
# PostgreSQL in Docker (sonarqube/user-data.sh). Port 9000 is open only to your
# IP and to CodeBuild's published IP ranges in this region. No SSH: use
# Session Manager (EC2 > Connect > Session Manager).

# CodeBuild (without VPC config) reaches SonarQube from these addresses.
data "aws_ip_ranges" "codebuild" {
  regions  = [var.region]
  services = ["codebuild"]
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "sonarqube" {
  name        = "${var.name}-sonarqube"
  description = "SonarQube UI/API: admin IPs + CodeBuild"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SonarQube from admins"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  ingress {
    description = "SonarQube from CodeBuild in ${var.region}"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = data.aws_ip_ranges.codebuild.cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "sonarqube" {
  name = "${var.name}-sonarqube-ec2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sonarqube_ssm" {
  role       = aws_iam_role.sonarqube.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "sonarqube" {
  name = "${var.name}-sonarqube-ec2"
  role = aws_iam_role.sonarqube.name
}

resource "aws_instance" "sonarqube" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.sonar_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.sonarqube.id]
  iam_instance_profile   = aws_iam_instance_profile.sonarqube.name
  user_data              = file("${path.module}/../sonarqube/user-data.sh")

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = var.sonar_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.name}-sonarqube" }

  # A newer AMI must not replace the server (and wipe its data) on the next apply.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# Fixed address, so SONAR_HOST_URL stays valid across stop/start.
resource "aws_eip" "sonarqube" {
  domain   = "vpc"
  instance = aws_instance.sonarqube.id
  tags     = { Name = "${var.name}-sonarqube" }
}

locals {
  sonar_host_url = "http://${aws_eip.sonarqube.public_ip}:9000"
}
