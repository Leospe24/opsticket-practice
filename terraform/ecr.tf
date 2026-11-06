resource "aws_ecr_repository" "frontend" {
  name         = "opsticket-frontend"
  force_delete = true
}

resource "aws_ecr_repository" "backend" {
  name         = "opsticket-backend"
  force_delete = true
}

