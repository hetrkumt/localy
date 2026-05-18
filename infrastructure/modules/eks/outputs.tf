output "cluster_name" {
  description = "생성된 EKS 클러스터의 이름"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS 클러스터의 API 서버 엔드포인트"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "EKS 클러스터의 CA 인증서 데이터"
  value       = aws_eks_cluster.this.certificate_authority[0].data
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