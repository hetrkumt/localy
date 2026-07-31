# 1. GitHub OIDC Provider (GitHub Actions → AWS STS trust)
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

# 2. ECR push role — OIDC trust locked to backend repo main branch
# Live remote: hetrkumt/localy-backend (Architect doc also named localy-project/*).
# Allow both so rename/migration does not break CI.
resource "aws_iam_role" "github_actions_ecr_role" {
  name = "github-actions-ecr-push-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
              "repo:hetrkumt/localy-backend:ref:refs/heads/main",
              "repo:localy-project/localy-backend:ref:refs/heads/main"
            ]
          }
        }
      }
    ]
  })
}

# 3. Least-privilege inline policy — ECR push only to workload service repos
# (Repos are order-service etc., NOT localy-* — that mismatch blocked GHA push.)
resource "aws_iam_role_policy" "ecr_push_only" {
  name = "ecr-push-only"
  role = aws_iam_role.github_actions_ecr_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPushWorkloadServiceRepos"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories"
        ]
        Resource = [for name, repo in aws_ecr_repository.services : repo.arn]
      }
    ]
  })
}

# 4. Surface role ARN for GitHub Actions workflows
output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions_ecr_role.arn
  description = "Paste this ARN into GitHub Actions ROLE_TO_ASSUME (main branch only)."
}
