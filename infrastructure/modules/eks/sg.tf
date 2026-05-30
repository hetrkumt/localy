# 1. 방화벽 껍데기 생성
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS Control Plane Security Group"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.cluster_name}-cluster-sg" }
}

resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node-sg"
  description = "EKS Worker Node Security Group"
  vpc_id      = var.vpc_id


  tags = {
    Name = "${var.cluster_name}-node-sg"
    # karpenter.sh/discovery 태그를 추가합니다.
    "karpenter.sh/discovery" = var.cluster_name # "prod-eks"로 매핑됨
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.cluster_name}-alb-sg"
  description = "Application Load Balancer Security Group"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.cluster_name}-alb-sg" }
}

# ---------------------------------------------------------
# 2. 방화벽 규칙 (Rules) 주입
# ---------------------------------------------------------

# [Cluster SG] 관리자 IP(로컬 PC)에서 API 서버(443) 접근 허용
resource "aws_security_group_rule" "cluster_ingress_admin" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.admin_ip]
  security_group_id = aws_security_group.cluster.id
  description       = "Allow Admin IP to access Control Plane API"
}

resource "aws_security_group_rule" "cluster_additional" {
  for_each = var.cluster_security_group_additional_rules

  type                     = each.value.type
  from_port                = each.value.from_port
  to_port                  = each.value.to_port
  protocol                 = each.value.protocol
  security_group_id        = aws_security_group.cluster.id
  cidr_blocks              = lookup(each.value, "cidr_blocks", [])
  ipv6_cidr_blocks         = lookup(each.value, "ipv6_cidr_blocks", [])
  source_security_group_id = lookup(each.value, "source_security_group_id", null)
  description              = lookup(each.value, "description", null)
}

# [Node SG] 노드 간 통신 전면 허용 (같은 SG를 가진 노드끼리)
resource "aws_security_group_rule" "node_ingress_self" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  source_security_group_id = aws_security_group.node.id
  security_group_id        = aws_security_group.node.id
  description              = "Allow nodes to communicate with each other"
}

# [Node SG] ALB로부터 들어오는 트래픽 허용 (SG 체이닝)
resource "aws_security_group_rule" "node_ingress_alb" {
  type                     = "ingress"
  from_port                = 8080 # App 포트에 맞게 추후 변경 가능
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.node.id
  description              = "Allow traffic from ALB"
}

# [공통] 모든 아웃바운드 허용 (초기 구축 편의를 위해 일단 개방, 나중에 조일 수 있음)
resource "aws_security_group_rule" "cluster_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.cluster.id
}

resource "aws_security_group_rule" "node_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node.id
}

# ========================================================================
# [🚨 NEW 핫픽스] Control Plane과 Worker Node 간의 통신 고리 연결
# ========================================================================

# 1. 일꾼 노드들(Node SG)이 관리실(Cluster SG)의 API 서버(443)에 접근할 수 있도록 허용
resource "aws_security_group_rule" "cluster_ingress_node" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.node.id    # 노드들이
  security_group_id        = aws_security_group.cluster.id # 관리실로 들어옵니다
  description              = "Allow EKS nodes to communicate with Control Plane API"
}

# 2. 관리실(Cluster SG)이 일꾼 노드들(Node SG)의 Kubelet(10250) 및 내부 통신망에 접근할 수 있도록 허용
resource "aws_security_group_rule" "node_ingress_cluster" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.cluster.id # 관리실의 신호가
  security_group_id        = aws_security_group.node.id    # 노드들로 들어갑니다
  description              = "Allow Control Plane to communicate with nodes"
}