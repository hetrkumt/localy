# 1. GitHub OIDC Provider 생성 (GitHub이 발급한 토큰을 AWS가 믿을 수 있도록 설정)
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # GitHub Actions OIDC 서버의 공식 인증서 지문 (Thumbprint)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"] 
}

# 2. GitHub Actions가 빌드할 때 임시로 빌려 입을 권한(Role) 생성
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
          # 원래는 "repo:내계정/내저장소:*" 처럼 지정해야 안전하지만, 
          # 지금은 테스트를 위해 모든 저장소(*)에서 사용할 수 있도록 넓게 열어둡니다.
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:*/*:*"
          }
        }
      }
    ]
  })
}

# 3. 위에서 만든 권한(Role)에 "ECR에 이미지를 푸시할 수 있는 권한"을 연결
resource "aws_iam_role_policy_attachment" "github_actions_ecr_policy" {
  role       = aws_iam_role.github_actions_ecr_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# 4. 나중에 GitHub Actions 파일(.yml)에 적어야 할 ARN 주소를 화면에 출력
output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions_ecr_role.arn
  description = "이 ARN 값을 복사해서 GitHub Actions 워크플로우에 붙여넣어야 합니다."
}
