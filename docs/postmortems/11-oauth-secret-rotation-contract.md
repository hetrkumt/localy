# Secret을 회전했더니 인증 관계가 끊어졌다

> Terraform·Secrets Manager·ESO·애플리케이션·Keycloak 사이에서 OAuth client credential의 양쪽 끝을 함께 바꿔야 했던 이유

## 문서 정보

- 사건 시각: 2026-07-31 18:00~20:15 KST
- 환경: Keycloak 24 계열, Spring Security OAuth2 Client, ESO, AWS Secrets Manager, Terraform L3
- 대상 client: `user-service`, `edge-service`
- Secret 경로:
  - `/localy/prod/workload/user-oauth`
  - `/localy/prod/workload/edge-oauth`
- consumer 전달 경로: Terraform → Secrets Manager → ESO → Kubernetes Secret → application
- verifier 전달 경로: Terraform → 운영 정렬 절차 → Keycloak client database
- 최초 문제: Secret 저장소와 Keycloak client가 서로 다른 값을 가질 수 있음
- 1차 복구: Keycloak admin 접근 복구 후 두 client secret을 Secrets Manager 값과 정렬
- 재발 시점: workload Secret을 Terraform state로 import·apply하면서 OAuth 값이 회전
- 2차 복구: 회전된 값을 Keycloak에 다시 반영하고 ESO 동기화 확인
- 검증: 두 client의 `client_credentials` token 발급 성공
- 테스트 함정: secret의 `+`를 form URL encoding하지 않아 `unauthorized_client`로 오판할 뻔함
- 영구 코드:
  - `secrets_workload.tf`
  - `secrets_mirroring.tf`
  - workload ExternalSecret
  - `keycloak-align-oauth.ps1`
- 남은 구조적 부채: Terraform apply와 Keycloak client update가 하나의 원자적 transaction이 아님

---

## Executive Summary

OAuth confidential client 인증에는 같은 secret을 가진 두 주체가 필요하다.

```text
client application
  └─ client_id + client_secret 제출

authorization server(Keycloak)
  └─ 저장된 client_secret과 비교
```

이 프로젝트에서는 애플리케이션이 사용할 secret을 Terraform이 생성하고 AWS Secrets Manager에 저장한다. ESO는 그 값을 Kubernetes Secret으로 복제하고, user-service와 edge-service가 이를 읽는다.

```text
Terraform random_password
  → AWS Secrets Manager
    → External Secrets Operator
      → Kubernetes Secret
        → Spring application
```

하지만 Keycloak의 client secret은 Keycloak database 안의 별도 상태다.

```text
Terraform random_password
  ── 자동 연결 없음 ──> Keycloak client secret
```

따라서 Secrets Manager 값만 바꾸면 consumer는 새 secret을 제출하지만 Keycloak은 과거 secret과 비교한다.

```text
application: NEW
Keycloak:     OLD
              ↓
        invalid_client / unauthorized_client
```

반대로 Keycloak만 먼저 바꾸면 새 값이 ESO와 애플리케이션에 도달하기 전까지 같은 실패가 발생한다.

이 문제는 두 번 드러났다.

첫 번째는 재배포 후 Keycloak admin과 OAuth client 상태를 복구할 때였다. Keycloak의 bootstrap admin 자체가 Secrets Manager 값과 정렬되지 않아 client 설정을 변경할 관리 API에 로그인할 수 없었다. admin bootstrap을 복구한 뒤 user-service와 edge-service client secret을 Secrets Manager 값으로 맞추고 token 발급을 확인했다.

두 번째는 workload Secrets Manager 경로를 Terraform SSOT로 정식화할 때였다. 기존 Secret resource를 Terraform state로 import한 뒤 targeted apply를 실행하자 `random_password`가 관리하는 OAuth 값이 갱신됐다. Secrets Manager와 ESO는 새 값을 정상적으로 전달했지만 Keycloak client database는 자동으로 바뀌지 않았다. 다시 Keycloak client를 정렬한 뒤 두 client 모두 `client_credentials` grant를 통과했다.

이 사건의 핵심은 다음과 같다.

> credential rotation은 값을 한 곳에서 바꾸는 CRUD 작업이 아니라, 인증 관계의 producer·consumer·verifier를 순서 있게 전환하고 실제 인증으로 검증하는 배포 작업이다.

---

# Step 1. 배경 — 하나의 client secret은 실제로 여러 시스템에 존재한다

## 1.1 OAuth confidential client

`user-service`와 `edge-service`는 Keycloak에 등록된 confidential client다.

개념적으로 token 요청은 다음 형태다.

```http
POST /realms/localy/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=user-service
&client_secret=<secret>
```

Keycloak은 `client_id`로 client를 찾고, 제출된 secret을 자신이 저장한 값과 비교한다.

```text
값 일치:
  token 발급

값 불일치:
  invalid_client 또는 unauthorized_client
```

여기서 secret은 여러 복사본으로 존재한다.

```text
Terraform state
AWS Secrets Manager
Kubernetes Secret
application process memory
Keycloak database
```

여러 위치에 있다는 사실 자체가 잘못은 아니다. 문제는 **어느 것이 원본이고 어떤 경로로 나머지를 갱신하는지** 정의되지 않을 때 생긴다.

## 1.2 이 프로젝트의 의도한 원본

workload OAuth secret의 의도한 원본은 Terraform `random_password`다.

```hcl
resource "random_password" "user_keycloak_client_secret" {
  length  = 48
  special = false
}

resource "random_password" "edge_oauth_client_secret" {
  length  = 48
  special = false
}
```

각 값은 서비스별 Secrets Manager path에 기록된다.

```hcl
secret_string = jsonencode({
  clientSecret = random_password.user_keycloak_client_secret.result
})
```

```hcl
secret_string = jsonencode({
  clientSecret = random_password.edge_oauth_client_secret.result
})
```

따라서 원본과 복제본의 관계는 다음과 같다.

```text
SSOT:
  Terraform random_password

managed copy:
  Secrets Manager secret version

delivery copy:
  Kubernetes Secret

runtime copy:
  application process

verifier copy:
  Keycloak client database
```

마지막 Keycloak verifier copy는 Terraform graph 안에서 직접 관리되지 않았다. 이 단절이 사건의 구조적 원인이었다.

---

# Step 2. 공유 Secret을 서비스별 경로로 분리하다

## 2.1 과거 구조

초기 설계에는 user와 edge의 OAuth 값이 하나의 공유 JSON 안에 섞여 있었다.

```text
/localy/prod/workload/jwt-secret
  ├─ clientSecret
  └─ edgeClientSecret
```

이 구조에는 몇 가지 문제가 있다.

```text
한 서비스의 IAM 권한이 다른 서비스 credential까지 읽을 수 있음
JSON property 이름에 서비스 경계가 숨어 있음
rotation 단위가 불명확함
SecretStore path 정책을 서비스별로 제한하기 어려움
```

## 2.2 서비스별 경로

경로를 다음과 같이 분리했다.

```text
/localy/prod/workload/user-oauth
  └─ clientSecret

/localy/prod/workload/edge-oauth
  └─ clientSecret
```

이제 경로 자체가 소유권을 표현한다.

```text
user-service IAM:
  user-oauth만 읽기

edge-service IAM:
  edge-oauth만 읽기
```

## 2.3 ESO가 애플리케이션 schema로 변환한다

user-service ExternalSecret은 remote property를 여러 application binding key로 투영했다.

```yaml
data:
  - secretKey: clientSecret
    remoteRef:
      key: /localy/prod/workload/user-oauth
      property: clientSecret
```

target Secret:

```yaml
data:
  KEYCLOAK_CLIENT_SECRET: "{{ .clientSecret }}"
  keycloak.client-secret: "{{ .clientSecret }}"
  spring.security.oauth2.client.registration.keycloak.client-secret: "{{ .clientSecret }}"
```

edge-service도 자신의 path를 읽어 Spring registration key에 넣는다.

```yaml
data:
  spring.security.oauth2.client.registration.keycloak.client-secret: "{{ .clientSecret }}"
  keycloak.client-secret: "{{ .clientSecret }}"
```

여기서 ESO는 값을 변환하고 전달할 뿐 Keycloak client database를 수정하지 않는다.

```text
ESO 책임:
  remote secret → Kubernetes Secret

ESO 책임 아님:
  Keycloak admin API 호출
  client secret 변경
  token 발급 검증
```

---

# Step 3. 첫 번째 장애 — 관리자가 로그인할 수 없으면 client도 고칠 수 없다

## 3.1 OAuth 정렬의 선행조건

Keycloak client secret을 변경하려면 Keycloak admin API를 호출해야 한다.

사용한 도구는 `kcadm.sh`였다.

```text
kcadm login
  → realm의 client 조회
    → client 생성 또는 update
      → secret 설정
```

그러나 재배포된 Keycloak에서는 admin credential 자체가 꼬여 있었다.

관찰된 원인은 다음과 같았다.

```text
Bitnami Keycloak 24 bootstrap env가 기대와 다름
admin 대신 user 계정이 생성됨
3 replica가 같은 DB bootstrap에 동시에 참여
Secrets Manager의 admin password와 DB 내부 admin 상태가 불일치
```

즉 OAuth client를 고치기 전에 관리 control plane부터 복구해야 했다.

## 3.2 admin bootstrap과 OAuth client secret은 다른 credential이다

둘을 구분해야 한다.

```text
Keycloak admin credential:
  누가 Keycloak 설정을 변경할 수 있는가

OAuth client credential:
  서비스가 token endpoint에서 자신을 어떻게 인증하는가
```

admin password를 맞췄다고 OAuth client secret이 자동으로 맞는 것은 아니다.

반대로 OAuth secret을 알고 있어도 admin API 권한이 생기지 않는다.

## 3.3 admin SSOT 복구

당시 복구 절차는 다음과 같았다.

```text
1. Keycloak StatefulSet을 0으로 scale
2. keycloak database를 재생성
3. bootstrap username을 admin으로 명시
4. Secrets Manager password로 1 replica bootstrap
5. "Added user 'admin'" 확인
6. kcadm login 확인
7. 최종 3 replica 복구
```

한 replica로 먼저 bootstrap한 이유는 세 replica가 동시에 초기 관리자 생성에 참여하는 race를 피하기 위해서다.

`kcadm` 자체에도 별도 마찰이 있었다.

기본 config 위치 `/home/keycloak/.keycloak`에 쓸 수 없어 admin 인증 실패처럼 보였고, writable path를 명시해야 했다.

```text
--config /tmp/kc/kcadm.config
```

이는 중요한 진단 구분이다.

```text
admin password가 틀림
  vs
kcadm가 config 파일을 못 씀
```

두 오류는 결과적으로 “관리 명령 실패”처럼 보이지만 원인은 다르다.

---

# Step 4. Keycloak의 두 client를 Secrets Manager 값과 맞추다

## 4.1 Secret 값은 출력하지 않았다

정렬 스크립트는 Secrets Manager에서 값을 읽었지만 평문을 log에 출력하지 않았다.

```powershell
$userOauth = aws secretsmanager get-secret-value ... | ConvertFrom-Json
$edgeOauth = aws secretsmanager get-secret-value ... | ConvertFrom-Json

Write-Host "user-oauth len=$($userOauth.clientSecret.Length)"
Write-Host "edge-oauth len=$($edgeOauth.clientSecret.Length)"
```

값 대신 다음만 확인했다.

```text
property 존재 여부
문자열 길이
업데이트 결과
token smoke 결과
```

## 4.2 client가 없으면 만들고 있으면 갱신한다

정렬 로직은 `clientId`로 Keycloak client를 조회했다.

```text
user-service
edge-service
```

client가 없으면 confidential client로 생성했다.

```text
enabled = true
publicClient = false
serviceAccountsEnabled = true
standardFlowEnabled = true
clientAuthenticatorType = client-secret
```

이미 있으면 내부 UUID를 얻어 secret을 갱신했다.

```text
clientId는 사람이 사용하는 논리 이름
id는 Keycloak 내부 resource UUID
```

따라서 update path는 `clientId` 문자열이 아니라 조회된 내부 ID를 사용했다.

```text
clients/<internal-id>
```

## 4.3 두 client 모두 같은 절차를 거쳤다

```text
Secrets Manager user-oauth
  → Keycloak user-service secret

Secrets Manager edge-oauth
  → Keycloak edge-service secret
```

정렬이 끝나면 다음 상태가 된다.

```text
Terraform/SM user secret == Keycloak user-service verifier
Terraform/SM edge secret == Keycloak edge-service verifier
```

하지만 이것만으로 애플리케이션까지 새 값을 사용한다고 단정할 수 없다.

```text
ESO refresh
Kubernetes Secret 갱신
Pod rollout 또는 재시작
application binding key 확인
```

이 전달 경로도 별도로 검증해야 한다.

---

# Step 5. 스모크 테스트가 새로운 오판을 만들 뻔했다

## 5.1 edge는 성공하고 user는 실패했다

client secret을 맞춘 뒤 token endpoint를 검사했다.

관찰 결과:

```text
edge-service: 성공
user-service: unauthorized_client
```

이 결과만 보면 user-service의 Keycloak secret이 여전히 다르다고 판단하기 쉽다.

그래서 user-service secret을 다시 설정하고 client flags도 확인했다.

하지만 실제 문제는 인증 관계가 아니라 테스트 요청의 encoding이었다.

## 5.2 `application/x-www-form-urlencoded`에서 `+`의 의미

당시 user secret에는 `+` 문자가 포함돼 있었다.

token endpoint의 body는 form encoding을 사용한다.

```http
Content-Type: application/x-www-form-urlencoded
```

이 encoding에서 `+`는 일반적으로 공백을 나타낸다.

예를 들어 실제 secret이 다음과 같다고 가정한다.

```text
abc+def
```

body에 그대로 넣으면 server가 다음처럼 해석할 수 있다.

```text
abc def
```

올바른 percent encoding은 다음과 같다.

```text
abc%2Bdef
```

따라서 단순 `wget --post-data` 테스트는 원본 secret과 다른 값을 Keycloak에 보냈다.

```text
Keycloak 저장값: abc+def
테스트 제출값:   abc def
               ↓
        unauthorized_client
```

Spring Security OAuth2 client는 정상적인 form encoding을 수행하므로 실제 애플리케이션과 임시 shell smoke의 동작이 달랐다.

## 5.3 테스트 도구도 시스템의 일부다

이 사건은 중요한 진단 원칙을 보여준다.

> smoke test가 실패했다고 production path가 같은 이유로 실패했다고 단정할 수 없다.

확인해야 할 것은 다음과 같다.

```text
같은 protocol인가?
같은 encoding인가?
같은 client authentication method인가?
같은 endpoint와 realm인가?
같은 secret bytes를 전송했는가?
```

테스트 도구의 encoding 차이를 찾지 못했다면 이미 맞는 secret을 반복 변경하면서 상태를 더 혼란스럽게 만들 수 있었다.

## 5.4 왜 이후 random password를 alphanumeric으로 제한했는가

Terraform 정의는 OAuth secret에 `special = false`를 사용한다.

```hcl
length  = 48
special = false
```

이는 OAuth protocol이 특수문자를 지원하지 않아서가 아니다.

정확한 이유는 운영 경로의 shell quoting, form encoding, 임시 진단 도구에서 발생할 수 있는 실수를 줄이기 위해서다.

```text
보안 강도:
  48자 alphanumeric이면 충분히 높은 entropy

운영 안정성:
  shell/form/JSON 경계에서 escaping 위험 감소
```

단, “특수문자를 제거하면 모든 문제가 해결된다”는 일반 규칙은 아니다. secret 생성 정책은 길이와 entropy, 전달 protocol, 저장 방식까지 함께 판단해야 한다.

---

# Step 6. Terraform SSOT 정식화가 secret을 다시 회전시켰다

## 6.1 수동 seed의 문제

재배포 직후 workload Secret은 PowerShell seed나 운영 명령으로 생성할 수 있었다.

이 방식은 빠르게 ESO를 unblock하지만 다음 질문에 답하지 못한다.

```text
teardown 후 누가 다시 만드는가?
어떤 값이 RDS/MSK/S3/KMS와 연결되는가?
rotation history를 어디서 추적하는가?
Terraform state와 실제 Secret이 일치하는가?
```

따라서 `/localy/prod/workload/*`를 Terraform L3 소유로 정식화했다.

## 6.2 기존 Secret shell을 import하다

이미 AWS에 존재하는 Secret과 같은 이름으로 Terraform resource를 바로 apply하면 충돌한다.

그래서 먼저 Secret resource를 state로 import했다.

```text
/localy/prod/workload/order-db
/localy/prod/workload/payment-db
/localy/prod/workload/store-db
/localy/prod/workload/cart-redis
/localy/prod/workload/user-oauth
/localy/prod/workload/edge-oauth
```

Secret container와 Secret version은 다르게 생각해야 한다.

```text
Secret resource:
  이름, ARN, tag, recovery policy

Secret version:
  실제 JSON payload
```

기존 container를 import한 뒤 Terraform이 version payload를 생성하도록 했다.

## 6.3 targeted apply의 결과

workload Secret 범위로 targeted apply를 수행했다.

```text
7 add
6 change
```

DB와 infrastructure-derived 값은 기존 Terraform resource에서 다시 계산됐다.

OAuth 값은 `random_password`에서 왔다.

이 시점에 user와 edge client secret이 회전했다.

```text
Terraform random_password: NEW
Secrets Manager version:    NEW
ESO/Kubernetes Secret:      곧 NEW
Keycloak client database:   OLD
```

즉 Terraform apply 자체는 성공했지만 인증 시스템은 잠시 불일치 상태가 됐다.

## 6.4 apply 성공은 end-to-end 성공이 아니었다

Terraform이 확인할 수 있는 범위:

```text
random_password 생성
Secrets Manager version 기록
resource state 저장
```

Terraform이 당시 확인하지 못한 범위:

```text
Keycloak client secret 갱신
ESO refresh 완료
application Pod가 새 값 로드
token endpoint 인증 성공
```

따라서 `Apply complete!`는 rotation workflow의 중간 단계였다.

---

# Step 7. 두 번째 정렬과 최종 검증

## 7.1 DB를 다시 만들 필요는 없었다

첫 번째 복구 스크립트에는 admin SSOT를 되찾기 위한 database 재생성 단계가 포함돼 있었다.

하지만 두 번째 사건에서는 admin login과 Keycloak database가 정상이다.

문제는 OAuth secret rotation뿐이었다.

따라서 다음 작업은 하지 않았다.

```text
Keycloak database drop/create
admin bootstrap 재실행
StatefulSet 전체 초기화
```

필요한 변경만 수행했다.

```text
새 SM OAuth 값 읽기
Keycloak user-service secret update
Keycloak edge-service secret update
ESO 동기화 확인
token smoke
```

이 구분은 blast radius를 줄였다.

## 7.2 ESO 상태

6개 workload ExternalSecret을 확인했다.

최종적으로 모두 다음 상태가 됐다.

```text
SecretSynced
```

edge 쪽에는 일시적인 update conflict가 있었지만 재동기화 후 정상화됐다.

이는 회고 5에서 다룬 것처럼 여러 controller가 metadata와 Secret을 동시에 만질 때 발생할 수 있는 optimistic concurrency 충돌이다.

중요한 것은 일시적 conflict 자체보다 최종 condition과 생성된 Secret schema였다.

## 7.3 `client_credentials`를 acceptance test로 사용

최종 검증은 “Keycloak client가 존재한다”가 아니었다.

실제 token 발급을 요청했다.

```text
grant_type=client_credentials
client_id=user-service
client_secret=<current SM value>
```

```text
grant_type=client_credentials
client_id=edge-service
client_secret=<current SM value>
```

두 요청 모두 token을 받았다.

```text
user-service: OK
edge-service: OK
```

이 테스트는 다음을 한 번에 증명한다.

```text
realm endpoint 접근 가능
client 존재
client enabled
confidential client 설정
service account grant 허용
제출 secret과 Keycloak verifier 일치
```

단, 애플리케이션 Pod가 같은 Kubernetes Secret을 실제로 읽는지는 별도 binding/rollout 검증이 필요하다.

---

# Step 8. 임시방편과 영구 해결

## 8.1 임시방편

당시 운영 복구에 사용된 다음 작업은 즉시 상태를 맞추는 데 유용했다.

```text
Secrets Manager 값을 직접 조회
kcadm으로 client secret update
live Pod 안에서 token smoke
필요 시 ESO 강제 refresh
```

하지만 이것만으로는 다음 재배포를 보장하지 못한다.

```text
누가 secret을 생성하는지 불명확
다음 Terraform apply가 다시 회전할 수 있음
Keycloak 정렬 단계 누락 가능
명령 history/argv에 secret 노출 위험
```

## 8.2 영구화된 부분

다음은 코드로 고정됐다.

### 생성

```text
Terraform random_password
Terraform aws_secretsmanager_secret
Terraform aws_secretsmanager_secret_version
```

### 격리

```text
user-oauth path
edge-oauth path
서비스별 IAM/SecretStore
```

### 전달

```text
ExternalSecret
애플리케이션이 기대하는 target key schema
```

### 운영 정렬

```text
keycloak-align-oauth.ps1
secret 값을 출력하지 않는 검증
client_credentials smoke
```

### 레거시 강등

```text
sm-seed-workload-secrets.ps1
  → LEGACY / emergency only
```

## 8.3 아직 완전한 영구 해결은 아니다

Terraform apply와 Keycloak client update가 하나의 transaction으로 묶인 것은 아니다.

현재 workflow:

```text
terraform apply
  → OAuth secret 회전
    → 별도 align script
      → ESO/Pod rollout
        → smoke
```

중간 단계에서 실패하면 불일치 window가 생긴다.

```text
apply 성공, align 실패:
  consumer NEW / verifier OLD

align 성공, ESO 지연:
  verifier NEW / consumer OLD
```

따라서 현재 해결은 **명시적인 운영 절차를 가진 two-system rotation**이지, 원자적인 secret rotation 플랫폼은 아니다.

---

# Step 9. 더 나은 대안

## 9.1 Keycloak provider로 client를 Terraform 관리

가능한 대안은 Terraform Keycloak provider가 client와 secret을 함께 관리하는 것이다.

개념:

```text
random_password
  ├─ Secrets Manager version
  └─ Keycloak client secret
```

장점:

```text
한 plan에서 drift 확인
client flags와 secret을 코드로 관리
수동 kcadm 단계 감소
```

주의:

```text
Keycloak API가 먼저 살아 있어야 Terraform apply 가능
L3 infrastructure와 in-cluster Keycloak 사이 순환 의존 가능
private endpoint/network 접근 필요
provider credential bootstrap 문제
Keycloak DB 재생성 시 provider state 복구 설계 필요
```

이 프로젝트는 private RDS와 in-cluster Keycloak을 사용하므로 단순히 provider를 추가한다고 문제가 사라지지는 않는다.

## 9.2 GitOps Job 또는 Argo hook으로 정렬

Secret이 준비된 뒤 Kubernetes Job이 Keycloak admin API를 호출하도록 만들 수 있다.

```text
SecretStore
  → ExternalSecret
    → Keycloak Healthy
      → client alignment Job
        → workload rollout
```

장점:

```text
cluster 내부 network 사용
재배포 시 자동 재현
sync wave로 순서 표현 가능
```

주의:

```text
admin credential을 Job에 전달해야 함
Job log/argv secret 노출 방지 필요
반복 실행의 idempotency 필요
Argo hook history와 실패 재시도 설계
Keycloak readiness와 realm import 완료 구분
```

## 9.3 두 credential을 겹쳐 운영하는 staged rotation

가장 안전한 rotation은 old와 new를 일정 기간 함께 허용하는 방식이다.

```text
1. verifier가 OLD + NEW 모두 허용
2. consumer를 NEW로 전환
3. token smoke와 rollout 확인
4. OLD 폐기
```

그러나 Keycloak client secret의 multi-secret/rotation 기능은 사용 중인 Keycloak version과 설정에서 실제 지원·동작을 검증해야 한다.

지원되지 않으면 다음 대안을 고려할 수 있다.

```text
임시 두 번째 client 생성
consumer를 새 client로 전환
구 client 폐기
```

이 방식은 client ID 변경과 권한 복제라는 추가 복잡성이 있다.

## 9.4 애플리케이션 rollout을 rotation workflow에 포함

ESO가 Kubernetes Secret을 갱신해도 환경변수로 읽은 application process는 자동으로 바뀌지 않을 수 있다.

따라서 rotation acceptance criteria에 rollout을 포함해야 한다.

```text
ExternalSecret SecretSynced
Kubernetes Secret resourceVersion 변경
Deployment rollout 발생
새 Pod의 Secret binding 확인
old Pod 종료
token smoke 또는 실제 login flow 확인
```

Reloader를 사용한다면 회고 10의 가용성 문제도 이 workflow의 dependency가 된다.

---

# Step 10. 보안 관점에서 본 정렬 스크립트

## 10.1 잘한 부분

스크립트는 secret 평문을 일반 출력에 남기지 않았다.

```text
값 대신 length 출력
출력에 secret이 섞이면 <redacted> 치환
token 자체는 출력하지 않고 GOT_TOKEN만 확인
```

## 10.2 남은 노출 가능성

운영 중에는 secret이 다음 경계를 잠시 통과했다.

```text
PowerShell process memory
생성된 shell command 문자열
kubectl exec argument
container process argv 또는 shell environment
```

따라서 “로그에 출력하지 않았다”와 “어디에도 노출되지 않았다”는 같은 말이 아니다.

더 안전한 방식:

```text
Secret volume으로 파일 전달
stdin 사용
짧은 수명의 Kubernetes Secret/Job
실행 후 임시 파일 삭제
shell history 비활성 또는 command에 값 미삽입
audit log 정책 검토
```

## 10.3 password character 정책

admin과 OAuth random password는 운영 안정성을 위해 alphanumeric으로 제한했다.

```text
admin: 24자
OAuth: 48자
special=false
```

이는 특수문자가 “위험”해서가 아니라 여러 shell·form·JSON 경계의 escaping 실수를 줄이기 위한 trade-off다.

entropy는 길이로 충분히 확보한다.

---

# Step 11. 권장 rotation runbook

## 11.1 사전 확인

```text
[ ] Keycloak admin login 가능
[ ] realm localy 존재
[ ] user-service / edge-service client 존재
[ ] ExternalSecret Ready
[ ] Reloader 또는 수동 rollout 경로 정상
[ ] rollback용 이전 secret 보관 정책 확인
```

## 11.2 회전

```text
1. 새 random_password 생성
2. Secrets Manager version 기록
3. Keycloak client verifier 갱신
4. ESO refresh 완료 대기
5. consumer workload rollout
6. 새 Pod 준비 완료
7. client_credentials smoke
8. 실제 authorization-code/login path smoke
```

현재처럼 Keycloak이 단일 secret만 허용하는 전제라면 2~5 사이에 짧은 인증 실패 window가 생길 수 있다. 유지보수 창 또는 staged client 전략을 고려해야 한다.

## 11.3 완료 조건

```text
[ ] Terraform state의 random_password가 원본
[ ] Secrets Manager current version이 원본과 일치
[ ] ESO SecretSynced
[ ] Kubernetes Secret key schema가 application binding과 일치
[ ] Keycloak client secret이 current version과 일치
[ ] 새 application Pod만 Running
[ ] user-service token smoke 성공
[ ] edge-service token smoke 성공
[ ] secret 평문이 log/artifact에 없음
```

## 11.4 rollback 조건

다음 중 하나라도 실패하면 rotation 완료로 표시하지 않는다.

```text
Keycloak update 실패
ESO sync 실패
Pod rollout 실패
token smoke 실패
application login flow 실패
```

rollback에는 이전 값이 필요하다. Terraform이 새 random을 이미 state에 기록한 뒤라면 console에서 임의로 과거 값을 복원하면 다시 drift가 생긴다.

따라서 rollback도 SSOT를 기준으로 설계해야 한다.

---

## 최종 원인 트리

```text
OAuth client authentication 불일치 위험
│
├─ 같은 credential이 여러 시스템에 존재
│  ├─ Terraform state
│  ├─ Secrets Manager
│  ├─ Kubernetes Secret
│  ├─ application process
│  └─ Keycloak client database
│
├─ 전달 경로가 둘로 분리
│  ├─ consumer: TF → SM → ESO → app
│  └─ verifier: 운영 절차 → Keycloak
│
├─ 첫 번째 복구
│  ├─ admin bootstrap credential 불일치
│  ├─ kcadm writable config path 필요
│  ├─ user/edge client 생성·정렬
│  └─ client_credentials 검증
│
├─ smoke test 오판 가능성
│  ├─ user secret에 + 포함
│  ├─ form URL encoding 누락
│  └─ unauthorized_client가 실제 drift처럼 보임
│
├─ 두 번째 rotation
│  ├─ 기존 SM resource Terraform import
│  ├─ targeted apply
│  ├─ random_password와 SM version 갱신
│  ├─ Keycloak verifier는 OLD 유지
│  └─ 별도 alignment 필요
│
├─ 최종 복구
│  ├─ user/edge Keycloak secret update
│  ├─ ESO 6개 SecretSynced
│  ├─ workload rollout 경로 확인
│  └─ 두 client token smoke 성공
│
└─ 남은 부채
   ├─ apply와 Keycloak update 비원자적
   ├─ rotation 중 불일치 window
   ├─ secret의 argv/shell 노출 가능성
   └─ staged rotation/failback 자동화 부재
```

## 한 문장으로 남기는 교훈

**OAuth client secret 회전은 저장소의 값을 바꾸는 작업이 아니라 consumer와 verifier를 함께 전환하고, encoding이 동일한 실제 protocol 요청으로 일치를 증명해야 끝나는 배포다.**
