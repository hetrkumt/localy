# ========================================================================
# 🛡️ Phase 3: AWS ACM 공인 인증서 자동 발급 및 Route 53 DNS 검증
# ========================================================================
# [설명] AWS Certificate Manager(ACM)를 호출하여 도메인 인증서를 발급하고,
# Route 53에 DNS 챌린지 레코드를 자동으로 꽂아 넣어 "콘솔 접속 없이" 승인을 받아냅니다.
# ========================================================================

# 1. AWS ACM에 feifo.click 및 하위 와일드카드 도메인(*.feifo.click) 인증서 발급 요청
resource "aws_acm_certificate" "prod_cert" {
  domain_name               = var.base_domain
  subject_alternative_names = ["*.${var.base_domain}"]
  validation_method         = "DNS" # Route 53을 통한 DNS-01 검증 방식 선택

  tags = {
    Environment = "prod"
    Name        = "prod-feifo-click-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 2. ACM이 요구하는 DNS-01 검증용 임시 TXT 레코드를 Route 53 장부에 자동으로 쓰기 (Zero-Touch)
resource "aws_route53_record" "prod_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.prod_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.prod_zone.zone_id # 우리가 1단계에서 가져온 Route53 장부 ID 사용
}

# 3. AWS가 DNS 레코드를 확인하여 인증서를 "발급 완료(Issued)" 상태로 만들 때까지 테라폼 실행을 동기 대기
resource "aws_acm_certificate_validation" "prod_cert_validation" {
  certificate_arn         = aws_acm_certificate.prod_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.prod_cert_validation : record.fqdn]
}
