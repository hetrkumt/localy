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
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"

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
  description = "IAM Policy for Karpenter Controller with Least Privilege"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ① 리소스 수준 권한을 지원하지 않는 EC2 Describe/Pricing 액션 (Resource: "*")
      {
        Sid    = "AllowEC2ReadAndDescribe"
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
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
          "ec2:DescribeImages",
          "eks:DescribeCluster"
        ]
        Resource = "*"
      },
      # ② [핵심 제약사항 1] ec2:RunInstances 리소스 제한 (서브넷 & 보안그룹 락다운)
      {
        Sid    = "AllowKarpenterRunInstancesRestrictedSubnet"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          # 오직 EKS에 할당된 10 대역(private_subnets) 서브넷 ARN만 허용
          for id in var.subnet_ids : "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:subnet/${id}"
        ]
      },
      {
        Sid    = "AllowKarpenterRunInstancesRestrictedSgAndInstance"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          # 오직 1차 타격에서 생성된 EKS Node Security Group만 허용
          aws_security_group.node.arn,
          # 생성되는 인스턴스, 볼륨, 네트워크 인터페이스 범위 제한
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:volume/*",
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:network-interface/*"
        ]
      },
      {
        Sid    = "AllowKarpenterRunInstancesGlobalImagesAndTemplates"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          # 특정 ARN을 특정하기 어려운 글로벌 자원
          "arn:aws:ec2:ap-northeast-2::image/*",
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:launch-template/*",
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:fleet/*",
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:spot-instances-request/*"
        ]
      },
      # ③ 인스턴스 종료 및 태깅 권한 제한 (본인 계정 내 인스턴스만 제어 가능)
      {
        Sid    = "AllowKarpenterInstanceTerminationAndTagging"
        Effect = "Allow"
        Action = [
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate"
        ]
        Resource = [
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:launch-template/*",
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:fleet/*",
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:spot-instances-request/*",
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:volume/*",
          "arn:aws:ec2:ap-northeast-2:${data.aws_caller_identity.current.account_id}:network-interface/*"
        ]
      },
      # ④ IAM PassRole 제한
      {
        Sid      = "AllowPassRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.karpenter_node.arn
      },
      # ⑤ SQS Interruption Queue 읽기/쓰기 권한 제한
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
      # ⑥ 인스턴스 프로필 관리 권한
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