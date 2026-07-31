# 비밀번호의 주인은 한 명이어야 한다

> Terraform·RDS·Secrets Manager·ESO 사이의 password 소유권과 rotation 경계를 정리한 기록

## 문서 정보

- 정식화 시각: 2026-07-31 02:11~02:21 KST
- 선행 사건: 회고 3의 RDS password drift와 수동 Secret JSON 손상
- 대상 시스템: Terraform, Amazon RDS, AWS Secrets Manager, ESO, Kubernetes Secret
- 설계 목표: password write path를 Terraform 하나로 제한
- authoritative resource: `random_password.db_password`
- RDS 역할: 인증에 사용하는 password 적용 대상
- Secrets Manager 역할: 애플리케이션 전달용 mirror
- ESO 역할: Secrets Manager → Kubernetes 복제
- Kubernetes Secret 역할: Pod 전달용 runtime copy
- rotation 명령: `terraform apply -replace=random_password.db_password`
- 검증 결과: SM JSON 정상, SM과 K8s Secret 일치, Keycloak 3개 Ready

---

## Executive Summary

Keycloak 장애의 출발점은 같은 RDS password가 여러 시스템에 존재하지만 어느 시스템이 원본인지 운영 규칙이 분명하지 않았다는 데 있었다.

당시 password는 다음 위치에 존재했다.

```text
Terraform state
RDS master password
Secrets Manager JSON.password
Kubernetes Secret
Keycloak process environment
```

값이 여러 곳에 존재하는 것 자체는 피할 수 없다. RDS는 인증 검증을 위해 값을 가져야 하고, 애플리케이션은 접속을 위해 같은 값을 받아야 한다. 문제는 각 복제본을 독립적으로 수정할 수 있었던 것이다.

```text
RDS Console에서 password 변경
Secrets Manager put-secret-value
Kubernetes Secret 직접 수정
Terraform apply
```

이 네 경로를 모두 “비밀번호 변경 방법”으로 인정하면 어느 순간 반드시 drift가 생긴다.

최종 ownership 모델은 다음과 같다.

```text
Terraform random_password.db_password
  ├─ RDS master password
  └─ Secrets Manager secret version
       └─ ESO
          └─ Kubernetes Secret
             └─ Keycloak / applications
```

쓰기 주체:

```text
Terraform만 허용
```

나머지 시스템:

```text
RDS               적용 대상
Secrets Manager   전달용 mirror
ESO                복제 controller
K8s Secret         runtime copy
Pod                read-only consumer
```

Terraform 코드에는 RDS와 Secrets Manager가 동일한 `random_password.db_password.result`를 참조하도록 명시했다. Secret JSON은 수동 문자열 조립이 아니라 `jsonencode`로 생성한다.

```hcl
password = random_password.db_password.result
```

수동 변경 금지 사항도 코드 주석과 AWS tag에 남겼다.

```text
localy.io/password-ssot=terraform
localy.io/rotate-via=
terraform-apply-replace=random_password.db_password
```

rotation은 다음 명령으로만 수행한다.

```powershell
terraform apply -replace=random_password.db_password
```

처음에는 variable token과 `keepers`를 연결하는 방식을 검토했다. 그러나 기존 `random_password`에 `keepers`를 새로 추가하는 첫 apply 자체가 resource replacement와 즉시 password rotation을 유발한다. 현재 운영 중인 credential을 의도하지 않게 바꿀 수 있어 적용하지 않았다. 변수는 향후 전환을 위한 reserved 상태이며 현재 rotation 동작에는 영향을 주지 않는다.

검증 script도 추가했다. 이 script는 Secret 값을 출력하지 않고 다음을 확인한다.

- Secrets Manager JSON 필수 key
- ownership tag
- Secrets Manager와 Kubernetes Secret의 password 일치
- ExternalSecret 및 Keycloak Pod 상태

다만 RDS API는 현재 master password를 읽어 주지 않으므로 script가 RDS와 SM의 값을 직접 비교할 수는 없다. Keycloak의 실제 DB 연결 성공이 RDS password 정합성에 대한 data-plane 검증 역할을 한다.

---

# Step 1. 발단 — 같은 비밀번호를 네 곳에서 바꿀 수 있었다

## 1.1 회고 3에서 드러난 구조 문제

Keycloak 로그:

```text
FATAL: password authentication failed for user "postgres"
```

조사 결과:

```text
Secrets Manager password
==
Kubernetes Secret password

하지만

RDS는 해당 password를 거부
```

ESO 전달은 정상이어도 upstream인 RDS와 Secrets Manager가 다르면 애플리케이션은 실패한다.

## 1.2 수동 복구가 drift를 더 만들었다

장애 중 다음 두 API를 수동으로 호출했다.

```text
aws secretsmanager put-secret-value
aws rds modify-db-instance --master-user-password
```

두 작업은 원자적 transaction이 아니다.

```text
SM update 성공 + RDS update 실패
RDS update 성공 + SM update 실패
```

둘 중 하나만 성공하면 즉시 password drift가 생긴다.

실제 복구 과정에서는 PowerShell JSON 처리까지 겹쳐 Secrets Manager schema가 손상됐다.

```text
값 불일치
  +
JSON password property 손상
```

## 1.3 Kubernetes Secret 직접 수정도 해결이 아니다

다음 명령으로 K8s Secret만 바꾸면 Keycloak을 잠시 움직일 수 있어 보인다.

```powershell
kubectl edit secret localy-keycloak-secret
```

하지만 ESO가 다음 reconcile에서 Secrets Manager 값으로 되돌린다.

```text
수동 K8s 수정
  → ESO refresh
    → SM 값으로 덮어씀
```

RDS와 SM은 그대로이므로 root cause도 해결되지 않는다.

## 1.4 “모두 원본”인 구조의 문제

```text
Terraform:        내가 원본
RDS Console:      여기서 바꿔도 됨
Secrets Manager:  여기서 rotate해도 됨
K8s Secret:       급하면 직접 수정
```

이 구조에는 올바른 최종값을 판정할 기준이 없다.

필요한 것은 값 복사 script보다 ownership 선언이었다.

```text
누가 생성하는가
누가 변경하는가
누가 읽기만 하는가
어떤 경로는 금지되는가
```

---

# Step 2. 기반 지식 — SSOT는 값이 한 곳에만 있다는 뜻이 아니다

## 2.1 SSOT의 정확한 의미

Single Source of Truth는 동일 데이터가 물리적으로 한 곳에만 존재한다는 의미가 아니다.

password는 여러 시스템에 복제될 수밖에 없다.

```text
Terraform state      생성·desired value
RDS                  인증 verifier
Secrets Manager      distribution store
K8s Secret           workload delivery
process memory       runtime use
```

SSOT가 의미하는 것:

```text
어떤 값을 정답으로 인정할지 결정하는 authority가 하나
모든 변경이 그 authority에서 시작
나머지는 단방향으로 수렴
```

## 2.2 이 설계에서의 authoritative source

코드상 authority:

```hcl
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}
```

실제 generated value는 Terraform state에 저장된다.

따라서 더 정확한 표현은 다음과 같다.

```text
ownership/생성 규칙: Terraform configuration
현재 secret value:   Terraform state의 random_password result
```

Git의 HCL 파일에는 password 평문이 없다. 하지만 Terraform state에는 민감값이 존재하므로 state backend 보안이 Secret 보안의 일부다.

## 2.3 RDS는 원본이 아니라 적용 대상이다

```hcl
resource "aws_db_instance" "rds" {
  password = random_password.db_password.result
}
```

RDS는 실제 인증에서 password를 검증한다. 그러나 AWS API는 현재 master password를 다시 읽어 주지 않는다.

```text
Terraform → RDS password 쓰기 가능
RDS → Terraform password 읽기 불가
```

따라서 out-of-band 변경을 완벽하게 read-back 비교하기 어렵다.

## 2.4 Secrets Manager는 mirror다

```hcl
resource "aws_secretsmanager_secret_version" "db_secret" {
  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.rds.address
    port     = 5432
    username = "postgres"
    password = random_password.db_password.result
    database = "localy"
  })
}
```

Secrets Manager가 애플리케이션 배포 관점에서 중요한 distribution store인 것은 맞다. 그러나 이 설계에서는 password를 독립 생성하거나 rotation하는 authority가 아니다.

```text
Terraform password
  → Secrets Manager에 mirror
```

## 2.5 ESO와 Kubernetes Secret은 하위 복제본이다

```text
Secrets Manager
  → ESO reconcile
    → Kubernetes Secret
```

ESO는 외부 Secret 값을 Kubernetes에 전달한다. RDS password를 바꾸거나 Terraform state를 갱신하지 않는다.

Kubernetes Secret도 애플리케이션 전달 형식일 뿐 rotation 원본이 아니다.

## 2.6 Terraform state 보안

`random_password`의 `result`는 sensitive로 표시돼 CLI 출력에서는 가려질 수 있다. 하지만 state에는 실제 값이 저장된다.

필수 보호:

- remote backend encryption at rest
- state bucket 접근 최소화
- state locking
- versioning
- audit logging
- local state file 금지 또는 강한 보호
- plan artifact 보관 정책
- CI log에 sensitive output 출력 금지

`sensitive = true`는 암호화가 아니라 출력 억제 기능에 가깝다.

## 2.7 password rotation은 단순 값 변경이 아니다

전체 rotation:

```text
1. 새 password 생성
2. RDS에 적용
3. Secrets Manager 새 version 생성
4. ESO refresh
5. Kubernetes Secret 갱신
6. workload rollout
7. 새 connection 인증 검증
8. old connection 종료/재연결
```

한 단계라도 실패하면 일부 consumer가 old credential을 사용할 수 있다.

---

# Step 3. CCTV 추적 — Terraform 한 값이 소비자까지 내려가는 과정

## 3.1 Terraform이 password를 생성한다

```hcl
random_password.db_password.result
```

일반 apply에서는 resource가 state에 존재하는 한 값이 유지된다.

새 값을 만들려면 명시적으로 replacement를 요청한다.

```powershell
terraform apply `
  -replace=random_password.db_password
```

## 3.2 dependency graph가 변경을 전파한다

두 resource가 같은 result를 참조한다.

```text
random_password.db_password
  │
  ├─ aws_db_instance.rds.password
  │
  └─ aws_secretsmanager_secret_version.db_secret
```

Terraform plan은 password resource replacement로 인해 downstream 변경이 필요함을 계산한다.

## 3.3 RDS password를 갱신한다

```hcl
apply_immediately = true
```

password 변경이 maintenance window까지 대기하지 않도록 설정했다.

장점:

```text
SM은 새 password
RDS는 maintenance window까지 old password
```

같은 장시간 불일치 구간을 줄일 수 있다.

단점:

- 운영 중 connection 재인증 영향
- 즉시 변경
- application restart와 timing 조율 필요

따라서 명령을 maintenance window에서 실행하라는 운영 원칙과 `apply_immediately=true`를 함께 이해해야 한다.

```text
실행 시점은 운영자가 maintenance window로 선택
선택한 시점에는 RDS 변경을 즉시 적용
```

## 3.4 Secrets Manager version을 갱신한다

Terraform은 같은 password로 JSON을 생성한다.

```text
password value 일치
JSON schema 일치
host/port/user/database field 유지
```

`jsonencode`가 quoting과 property 구조를 담당하므로 PowerShell 수동 JSON 조립 문제를 피한다.

## 3.5 ESO가 새 version을 읽는다

ExternalSecret의 `refreshInterval` 또는 강제 reconciliation 시점에 AWS의 current Secret version을 읽는다.

```text
AWS AWSCURRENT
  → ExternalSecret property=password
    → KEYCLOAK_DATABASE_PASSWORD
```

회고 5에서 generated Secret ownership 충돌을 제거했기 때문에 ESO가 유일한 Secret writer로 동작해야 한다.

## 3.6 Kubernetes Secret이 갱신된다

검증:

```text
ExternalSecret Ready=True
Reason=SecretSynced
SM password == K8s Secret password
```

비밀번호 값 자체는 출력하지 않는다.

## 3.7 Pod가 새 password를 사용한다

Keycloak이 Secret을 env로 소비하면 기존 process 환경은 자동 갱신되지 않는다.

```text
K8s Secret 변경
  ≠
실행 중 process env 변경
```

rollout이 필요하다.

```text
Secret update
  → Deployment/StatefulSet rollout
    → 새 Pod
      → 새 password 로드
```

Reloader를 사용한다면 Reloader health와 annotation도 검증해야 한다. 당시 전체 health snapshot에서 Reloader CrashLoop이 관찰됐으므로 자동 rollout만 신뢰해서는 안 된다.

## 3.8 실제 DB 연결로 최종 확인한다

RDS는 password read-back을 제공하지 않는다. 따라서 최종 검증은 data-plane 인증이다.

```text
Keycloak Pod Ready
JDBC password authentication error 없음
DB bootstrap Job이 pg_isready/psql 성공
```

이 검증은 다음 등식을 간접 증명한다.

```text
K8s Secret password == RDS accepted password
```

---

# Step 4. 삽질과 해결 — 좋은 rotation knob도 지금 추가하면 장애가 된다

## 4.1 처음 고려한 `keepers` 방식

`random_password`에는 `keepers`를 연결할 수 있다.

```hcl
resource "random_password" "db_password" {
  keepers = {
    rotation_token = var.db_master_password_rotation_token
  }
}
```

token을 바꾸면 password resource가 교체된다.

```text
rotation_token 변경
  → random_password replacement
    → RDS + SM 갱신
```

명시적인 rotation revision을 코드로 관리할 수 있어 좋은 패턴이다.

## 4.2 왜 즉시 적용하지 않았는가

기존 state의 `random_password`에는 `keepers`가 없었다. 여기에 새로운 `keepers` map을 추가하는 첫 apply도 resource identity 변경으로 해석돼 password를 rotate할 수 있다.

```text
운영자의 의도:
  rotation mechanism만 추가

Terraform 실제 plan:
  password resource replacement 가능
```

소유권 정리 작업에서 password까지 갑자기 변경하면 Keycloak 재시작과 ESO refresh가 다시 필요하다. 따라서 적용 직전에 위험을 발견하고 keepers를 제거했다.

현재 상태:

```text
db_master_password_rotation_token 변수 존재
keepers 연결 없음
변수 변경해도 rotation 안 됨
```

변수 설명에도 reserved 상태임을 명시했다.

## 4.3 채택한 rotation 방식

```powershell
terraform apply `
  -replace=random_password.db_password
```

장점:

- 운영자가 rotation 의도를 명령에 명시
- 지금 코드 구조를 바꾸지 않음
- plan에서 replacement가 분명하게 보임

단점:

- rotation revision이 Git history에 남지 않음
- CLI 절차를 따라야 함
- 자동 schedule rotation이 아님

현재 단계에서는 예기치 않은 최초 rotation보다 명시적 수동 trigger가 안전했다.

## 4.4 `ignore_changes = [password]`를 금지한 이유

다음 설정은 drift 경고를 줄이는 방법처럼 보일 수 있다.

```hcl
lifecycle {
  ignore_changes = [password]
}
```

하지만 RDS password를 Terraform 관리에서 제외한다.

```text
Terraform random_password → SM
Terraform은 RDS password 변경 무시
```

그러면 SSOT graph가 영구적으로 끊어진다.

```text
SM password != RDS password
```

비밀번호 drift를 숨기는 것이 해결이 아니다.

## 4.5 태그와 주석을 추가한다

RDS:

```hcl
tags = {
  "localy.io/password-ssot" = "terraform"
}
```

Secrets Manager:

```hcl
tags = {
  "localy.io/password-ssot" = "terraform"
  "localy.io/rotate-via" =
    "terraform-apply-replace=random_password.db_password"
}
```

tag는 API write를 차단하지 않는다. 운영자가 Console에서 변경하는 것을 기술적으로 막는 IAM guardrail도 아니다.

역할:

```text
ownership 가시성
자동 검사 단서
운영 runbook 안내
```

실제 강제력이 필요하면 IAM/SCP 정책을 추가해야 한다.

## 4.6 검증 script를 추가한다

```text
infrastructure/scripts/check-rds-password-ssot.ps1
```

검사 항목:

```text
SM JSON required keys
SM ownership tag
ExternalSecret 상태
SM password == K8s password
Keycloak Pod 상태
```

출력 예:

```text
PASS: SM JSON healthy and ESO Secret matches SM.
Rotate only:
terraform apply -replace=random_password.db_password
```

## 4.7 검증 script의 한계

script 이름은 SSOT check지만 다음을 직접 확인하지 못한다.

### Terraform state와 SM 비교

현재 script는 Terraform state의 password를 읽지 않는다. state 민감값 노출 위험을 줄이기 위한 선택이지만, 그만큼 `TF == SM`을 직접 증명하지 않는다.

### RDS와 SM 비교

RDS password는 API로 조회할 수 없어 직접 equality 비교가 불가능하다.

### Pod Ready의 의미

Pod가 기존 connection pool로 Ready일 수 있고 rotation 직후 새 connection 검증이 충분하지 않을 수 있다.

따라서 완전한 rotation test는 새 DB connection을 명시적으로 열어야 한다.

정확한 script 보장 범위:

```text
SM schema 정상
ownership tag 확인
SM == K8s Secret
Keycloak workload 현재 Ready
```

보장하지 않는 범위:

```text
TF state == SM 직접 비교
RDS stored password 직접 read-back
새 connection으로 end-to-end 인증
```

## 4.8 tag/description만 apply한다

소유권 정리 apply에서는 password replacement를 수행하지 않았다.

```text
변경:
  tags
  description
  apply_immediately 설정

변경하지 않음:
  random_password result
```

목표는 운영 중인 credential을 다시 rotate하는 것이 아니라 future write path를 명확히 하는 것이었다.

---

# Step 5. 넥스트 스텝 — rotation은 작은 배포다

## 5.1 가장 중요한 설계 원칙

> 비밀번호가 여러 시스템에 복제되는 것은 문제없지만, 새 비밀번호를 결정할 수 있는 주체는 하나여야 한다.

## 5.2 권장 rotation runbook

### 사전 점검

```text
[ ] maintenance window 확보
[ ] Terraform state lock 정상
[ ] current plan 검토
[ ] ESO Ready
[ ] Secret ownership 충돌 없음
[ ] workload restart 방법 준비
[ ] rollback 전략 준비
```

### plan

```powershell
terraform plan `
  -replace=random_password.db_password
```

확인:

```text
random_password replacement
RDS password update
SM secret version update
예상 밖 resource 변경 없음
```

### apply

```powershell
terraform apply `
  -replace=random_password.db_password
```

### propagation

```text
RDS available 확인
ESO refresh 확인
K8s Secret resourceVersion 확인
workload rollout
```

### 검증

```text
새 Pod Ready
새 DB connection 성공
password authentication failed 없음
Keycloak login smoke test
```

## 5.3 rollback의 어려움

password rotation은 application code rollback과 다르다.

Terraform state가 새 password로 전환된 뒤 RDS나 SM 일부만 실패하면 이전 값 복원이 단순하지 않을 수 있다.

필요한 전략:

- apply 실패 시 같은 plan/desired state로 재실행
- 현재 어느 시스템이 old/new인지 기록
- 민감값을 terminal에 출력하지 않음
- 이전 Secret version을 무조건 수동 promote하지 않음
- data-plane 인증으로 convergence 확인

## 5.4 자동 rotation으로 발전할 때

선택지:

### Terraform token/keepers

```text
Git token bump
  → plan/review
    → Terraform apply
```

장점:

- Git에 rotation event 기록
- 기존 ownership 유지

주의:

- 최초 keepers 도입도 rotation
- maintenance window 필요

### AWS Secrets Manager managed rotation

AWS rotation Lambda가 RDS와 Secret을 관리하는 구조로 바꿀 수도 있다.

그 경우 authority가 Terraform에서 Secrets Manager rotation system으로 이동한다.

```text
현재:
Terraform owns password

전환 후:
Secrets Manager rotation owns password
Terraform은 lifecycle을 그에 맞게 변경
```

두 ownership 모델을 동시에 활성화하면 안 된다.

## 5.5 IAM guardrail이 필요하다

주석과 tag만으로 수동 API 호출을 막을 수 없다.

향후:

- 운영자 role에서 `secretsmanager:PutSecretValue` 제한
- RDS `ModifyDBInstance` password 변경 경로 제한
- break-glass role만 예외
- CloudTrail alert
- tag condition을 이용한 deny policy

단, Terraform execution role은 허용해야 한다.

## 5.6 애플리케이션별 credential 분리

현재 Keycloak은 RDS master user `postgres`를 사용한다.

장기적으로는 다음이 더 안전하다.

```text
bootstrap admin credential:
  CREATE DATABASE / role 관리

Keycloak runtime credential:
  keycloak DB에 필요한 최소 권한

서비스 runtime credential:
  각 서비스 DB/schema 최소 권한
```

master password rotation 영향 범위를 줄이고 least privilege를 적용할 수 있다.

## 5.7 상태 검증 개선

현재 script에 추가할 수 있는 항목:

- Terraform plan이 password drift를 제안하는지 확인
- SM version stage 확인
- ExternalSecret refreshTime 확인
- K8s Secret resourceVersion 변경 확인
- disposable Pod에서 새 PostgreSQL connection test
- application rollout generation 확인
- CloudTrail에서 out-of-band password API 탐지

민감값 equality는 가능하면 별도 격리된 process 안에서 boolean만 반환한다.

## 5.8 재구축 acceptance criteria

```text
[ ] random_password resource가 state에 존재
[ ] RDS와 SM이 동일 resource를 참조
[ ] SM JSON schema가 jsonencode로 생성
[ ] RDS/SM ownership tag가 terraform
[ ] out-of-band write 금지 문서 존재
[ ] ExternalSecret SecretSynced
[ ] SM == K8s Secret
[ ] Keycloak 3개 Ready
[ ] 새 JDBC connection 성공
[ ] Terraform plan에 예상 밖 password drift 없음
```

## 5.9 재발 방지 체크리스트

- [ ] password authority를 한 시스템으로 제한한다.
- [ ] RDS Console에서 password를 바꾸지 않는다.
- [ ] Secrets Manager 값을 직접 갱신하지 않는다.
- [ ] Kubernetes Secret을 직접 수정하지 않는다.
- [ ] `ignore_changes=[password]`를 추가하지 않는다.
- [ ] Secret JSON은 `jsonencode`로 생성한다.
- [ ] Terraform state를 Secret 수준으로 보호한다.
- [ ] rotation은 plan review 후 maintenance window에서 수행한다.
- [ ] ESO sync 후 workload를 rollout한다.
- [ ] Running 상태가 아니라 새 DB connection으로 검증한다.
- [ ] keepers 최초 도입이 rotation임을 기억한다.
- [ ] Terraform rotation과 AWS managed rotation을 동시에 사용하지 않는다.

---

## 최종 소유권 트리

```text
Password authority
│
└─ Terraform
   ├─ configuration
   │  └─ random_password.db_password 생성 규칙
   │
   └─ state
      └─ 현재 password value
         │
         ├─ Amazon RDS
         │  └─ master password 적용 대상
         │
         └─ AWS Secrets Manager
            └─ JSON password mirror
               │
               └─ External Secrets Operator
                  └─ Kubernetes Secret
                     └─ Keycloak / application Pod

금지된 역방향 쓰기
│
├─ RDS Console → password 변경
├─ Secrets Manager → put-secret-value
├─ K8s Secret → kubectl edit
└─ application → credential 변경
```

## 한 문장으로 남기는 교훈

**여러 시스템이 같은 비밀번호를 가지고 있어도 괜찮지만, 그 비밀번호를 새로 결정할 권한까지 여러 시스템이 가지면 반드시 드리프트가 생긴다.**

