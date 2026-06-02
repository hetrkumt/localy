resource "kubectl_manifest" "karpenter_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2
      # 1. IAM 권한 매핑 (Step 3에서 생성한 노드 역할)
      role: "${module.eks.karpenter_node_iam_role_name}"
      
      # 2. 서브넷 동적 탐색 (karpenter.sh/discovery 태그 활용)
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${module.eks.cluster_name}"
            
      # 3. 보안 그룹 동적 탐색
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${module.eks.cluster_name}"
            kubernetes.io/cluster/${module.eks.cluster_name}: "owned"
            
      # 4. 새로 생성될 EC2 인스턴스에 기본적으로 붙일 태그
      tags:
        karpenter.sh/discovery: "${module.eks.cluster_name}"
        Name: "karpenter-node-${module.eks.cluster_name}"
  YAML

  # [중요] 카펜터 컨트롤러(뇌)가 먼저 설치된 이후에 이 CRD를 배포해야 에러가 나지 않습니다.
  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          # 1. 인프라 연결 (Part 2에서 만든 EC2NodeClass 참조)
          nodeClassRef:
            apiVersion: karpenter.k8s.aws/v1beta1
            kind: EC2NodeClass
            name: default
            
          # 2. 인스턴스 요구사항 (비용 최적화의 핵심)
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64", "amd64"] # Graviton(ARM) 우선, 호환성을 위해 amd64도 남겨둠
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"] # Spot 인스턴스를 최우선으로 사용
            - key: karpenter.k8s.aws/instance-category
              operator: In
              values: ["c", "m", "r"] # 컴퓨팅, 메모리, 범용 인스턴스만 허용
            - key: karpenter.k8s.aws/instance-generation
              operator: Gt
              values: ["2"] # 너무 오래된 세대(1, 2세대)는 제외

      # 3. 최대 용량 제한 (무한정 늘어나는 과금 방지)
      limits:
        cpu: 1000
        memory: 1000Gi

      # 4. 빈집 털기 및 수명 관리 (Consolidation)
      disruption:
        consolidationPolicy: WhenUnderutilized # 활용도가 낮으면 파드를 옮기고 노드 삭제!
        expireAfter: 720h # 노드가 30일(720시간)이 지나면 강제로 새 노드로 교체 (보안/최신화)
  YAML

  # EC2NodeClass가 먼저 쿠버네티스에 존재해야 NodePool이 이를 참조할 수 있습니다.
  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}