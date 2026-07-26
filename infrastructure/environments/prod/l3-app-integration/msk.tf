# ========================================================================
# Amazon MSK (Managed Streaming for Kafka) Provisioning
# ========================================================================

# 1. MSK 전용 보안그룹 (VPC CIDR 및 EKS Pod 대역 교차 허용)
resource "aws_security_group" "msk" {
  name        = "${var.env_name}-msk-sg"
  description = "Security Group for MSK Cluster"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  # Plaintext(9092), TLS(9094), IAM Auth(9098) 포트 대역 일괄 통제
  ingress {
    description = "Allow Kafka ports from VPC"
    from_port   = 9092
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.existing.cidr_block]
  }

  ingress {
    description = "Allow Kafka ports from EKS Pods (Secondary CIDR)"
    from_port   = 9092
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = ["100.64.0.0/10"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.env_name}-msk-sg" }
}

# 2. MSK Cluster 본체
resource "aws_msk_cluster" "msk" {
  cluster_name           = "${var.env_name}-localy-msk"
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 3 # 3개 AZ 가용성 분산

  broker_node_group_info {
    instance_type   = "kafka.t3.small"                                          # 비용 최적화 최하위 사양 탑재
    client_subnets  = split(",", data.aws_ssm_parameter.database_subnets.value) # database_subnets 격리
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = 10 # 10GB 시작 (최저 스토리지 비용 방어)
      }
    }
  }

  client_authentication {
    sasl {
      iam = true # EKS Pod Identity용 IAM 인증 활성화
    }
    unauthenticated = true # 마이그레이션 초기 단계 연동을 위한 Plaintext 허용
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS_PLAINTEXT" # Plaintext(9092)와 TLS(9094) 하이브리드 지원
      in_cluster    = true
    }
  }

  tags = {
    Name = "${var.env_name}-localy-msk"
  }
}

# -----------------------------------------------------------------------------
# [역제안 적용] MSK Broker Storage Auto Scaling
# -----------------------------------------------------------------------------
resource "aws_appautoscaling_target" "msk_storage" {
  max_capacity       = 100 # 최대 100GB 자동 확장 허용
  min_capacity       = 1
  resource_id        = aws_msk_cluster.msk.arn
  scalable_dimension = "kafka:broker-storage:VolumeSize"
  service_namespace  = "kafka"
}

resource "aws_appautoscaling_policy" "msk_storage" {
  name               = "${var.env_name}-msk-storage-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_msk_cluster.msk.arn
  scalable_dimension = aws_appautoscaling_target.msk_storage.scalable_dimension
  service_namespace  = aws_appautoscaling_target.msk_storage.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 70.0 # 디스크 사용률 70% 도달 시 롤링 확장 트리거

    predefined_metric_specification {
      predefined_metric_type = "KafkaBrokerStorageUtilization"
    }
  }
}
