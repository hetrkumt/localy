# ==========================================
# EKS Managed Add-ons
# ==========================================

# 1. VPC CNI (파드 네트워크 관리)
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"

  # 제약사항 3 반영: 향후 K8s 레벨에서 환경변수(Custom Networking)가 변경되어도 덮어쓰지 않고 보존
  resolve_conflicts_on_update = "PRESERVE"

  # ⭐️ 여기에 Prefix Delegation 설정을 추가합니다!
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })
}

# 2. kube-proxy (서비스 라우팅 관리)
resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# 3. CoreDNS (클러스터 내부 DNS)
# CoreDNS는 파드 형태로 실행되므로 워커 노드가 준비된 후에 설치되어야 합니다.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  depends_on                  = [aws_eks_node_group.this]
}

# 4. EKS Pod Identity Agent (워크로드용 차세대 IAM 연동 에이전트)
resource "aws_eks_addon" "pod_identity" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}
