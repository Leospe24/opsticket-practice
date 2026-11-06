data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ecr_profile.name

  # Startup script
  user_data = <<-EOF
                #!/usr/bin/env bash
                dnf update -y
                dnf install -y docker
                systemctl enable --now docker

                # Log in to private ECR using EC2 IAM Role badge
                aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${aws_ecr_repository.frontend.repository_url}

                # Pull and run the frontend container 
                docker run -d --name frontend --restart unless-stopped -p 80:8080 ${aws_ecr_repository.frontend.repository_url}:v1
                EOF

  tags = {
    Name = "opsticket-web-server"
  }
}

output "website_url" {
  value = "http://${aws_instance.web.public_ip}"
}