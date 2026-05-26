output "cluster_name" {
  description = "생성된 EKS 클러스터의 이름"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS 클러스터의 API 서버 엔드포인트"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "EKS 클러스터의 CA 인증서 데이터 (base64)"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_certificate_authority_data" {
  description = "EKS 클러스터 CA 인증서 (certificate_authority[0].data, base64)"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "EKS IRSA용 IAM OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.this.arn
}

output "cluster_oidc_issuer_url" {
  description = "EKS 클러스터 OIDC issuer URL (IRSA trust policy 조건에 사용)"
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "kms_key_arn" {
  description = "EKS Secret 암호화용 KMS Key ARN (EBS CSI 등 IRSA에서 참조)"
  value       = aws_kms_key.eks_secrets.arn
}

output "karpenter_controller_role_arn" {
  description = "Karpenter 컨트롤러 파드가 사용할 IAM Role ARN"
  value       = aws_iam_role.karpenter_controller.arn
}

output "karpenter_interruption_queue_name" {
  description = "Karpenter가 모니터링할 SQS 큐 이름"
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "karpenter_node_iam_role_name" {
  description = "The name of the IAM role for Karpenter nodes"
  value       = aws_iam_role.karpenter_node.name
}

output "ebs_csi_role_name" {
  value = aws_iam_role.ebs_csi.name
}

output "ebs_csi_role_arn" {
  value = aws_iam_role.ebs_csi.arn
}