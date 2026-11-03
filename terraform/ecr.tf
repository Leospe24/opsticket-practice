resource "aws_ecr_repository" "frontend" {
  name         = "opsticket-frontend"
  force_delete = true
}

output "ecr_repository_url" {
  value = aws_ecr_repository.frontend.repository_url
}