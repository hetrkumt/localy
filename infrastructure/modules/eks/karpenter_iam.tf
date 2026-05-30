# ========================================================================
# 1. Role B: Karpenter Node Role (생성될 EC2 노드들이 입을 옷)
# ========================================================================
resource "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ])
  policy_arn = each.value
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = aws_iam_role.karpenter_node.name
  role = aws_iam_role.karpenter_node.name
}


# ========================================================================
# [🚨 NEW 핫픽스] EKS Access Entry 등록 (노드가 클러스터에 조인할 수 있게 허용)
# ========================================================================
resource "aws_eks_access_entry" "karpenter_node" {
  # [수정] var.cluster_name 대신 실제 클러스터 리소스의 name 속성을 참조합니다.
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"

  # [추가] 클러스터의 인증 모드(authentication_mode) 전환이 100% 완료된 후 
  # 이 엑세스 엔트리가 생성되도록 테라폼 엔진에게 순서를 강제합니다.
  depends_on = [
    aws_eks_cluster.this
  ]
}

# ========================================================================
# 2. Role A: Karpenter Controller Role (Karpenter 파드 자체가 입을 옷 - IRSA)
# ========================================================================
resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.this.arn
      }
      Condition = {
        "StringEquals" = {
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:sub" : "system:serviceaccount:kube-system:karpenter",
          "${replace(aws_iam_openid_connect_provider.this.url, "https://", "")}:aud" : "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "karpenter_controller" {
  name        = "${var.cluster_name}-karpenter-controller-policy"
  description = "IAM Policy for Karpenter Controller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2Management"
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSpotPriceHistory",
          "pricing:GetProducts",
          "ssm:GetParameter",
          "ec2:DescribeImages"
        ]
        Resource = "*"
      },
      {
        Sid      = "AllowPassRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node.arn
      },
      {
        Sid    = "AllowInterruptionQueue"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage"
        ]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        Sid    = "AllowInstanceProfileManagement"
        Effect = "Allow"
        Action = [
          "iam:GetInstanceProfile",
          "iam:CreateInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  policy_arn = aws_iam_policy.karpenter_controller.arn
  role       = aws_iam_role.karpenter_controller.name
}