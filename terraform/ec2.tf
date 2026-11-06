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

                # Create private internet Docker network 
                docker network create opsticket-net

                # Log in to private ECR using EC2 IAM Role badge
                aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin ${aws_ecr_repository.frontend.repository_url}

                # 1. Start Database container (PostgreSQL)
                docker run -d --name database --network opsticket-net --restart unless-stopped \
                    -e POSTGRES_USER=opsticket \
                    -e POSTGRES_PASSWORD=opsticket \
                    -e POSTGRES_DB=opsticket \
                    postgres:16-alpine

                # Wait 10 seconds for the database to initialize
                sleep 10

                # 2. Start Backend container (Runs migrations automatically on startup)
                docker run -d --name backend --network opsticket-net --restart unless-stopped \
                    -e PORT=3000 \
                    -e DB_HOST=database \
                    -e DB_PORT=5432 \
                    -e DB_USER=opsticket \
                    -e DB_PASSWORD=opsticket \
                    -e DB_NAME=opsticket \
                    -e JWT_SECRET=production-lab-jwt-secret-key \
                    -e FRONTEND_URL=http://localhost \
                    ${aws_ecr_repository.backend.repository_url}:v1

                # 3. Start Frontend container (Nginx on port 80 -> proxies /api/ to backend:3000)
                docker run -d --name frontend --network opsticket-net --restart unless-stopped \
                    -p 80:8080 \
                    ${aws_ecr_repository.frontend.repository_url}:v1
                EOF

  tags = {
    Name = "opsticket-web-server"
  }
}

output "website_url" {
  value = "http://${aws_instance.web.public_ip}"
}