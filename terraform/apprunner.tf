resource "aws_apprunner_service" "frontend" {
  service_name = "opsticket-frontend"

  source_configuration {
    # Hand App Runner IAM Role badge
    authentication_configuration {
      access_role_arn = aws_iam_role.apprunner_ecr_role.arn
    }

    # Point App Runner to ECR image (:v1) and port 8080
    image_repository {
      image_identifier      = "${aws_ecr_repository.frontend.repository_url}:v1"
      image_repository_type = "ECR"

      image_configuration {
        port = "8080"
      }
    }
  }

  # Make sure the permission policy is attached before App Runner starts
  depends_on = [aws_iam_role_policy_attachment.apprunner_ecr_policy]
}

output "apprunner_service_url" {
  value = "https://${aws_apprunner_service.frontend.service_url}"
}