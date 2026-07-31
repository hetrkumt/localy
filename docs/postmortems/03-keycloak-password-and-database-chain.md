# 비밀번호를 맞췄더니 데이터베이스가 없었다

> Keycloak CrashLoop에서 RDS 인증, Secret 전달, 논리 Database를 한 계층씩 통과한 기록

## 문서 정보

- 사건 시각: 2026-07-30 23:40~2026-07-31 00:40 KST
- 환경: Keycloak 24.0.5, PostgreSQL 15 on Amazon RDS, ESO, Argo CD
- 선행 조건: workload node 등록 완료, Keycloak Pod 스케줄링 가능
- 영향 범위: Keycloak 3개 replica와 이를 사용하는 인증 기능 전체
- 최초 증상: Keycloak 3개 Pod가 모두 `CrashLoopBackOff`
- 첫 번째 직접 원인: Keycloak이 받은 비밀번호와 RDS master password 불일치
- 복구 중 추가 장애: 수동 Secrets Manager 갱신 과정에서 JSON schema 손상
- 두 번째 직접 원인: RDS 인스턴스에 `keycloak` 논리 Database가 없음
- 응급 복구: Terraform password 재생성 후 일회성 Job으로 Database 생성
- 최종 개선: Terraform password SSOT와 GitOps 기반 멱등 DB bootstrap

---

## Executive Summary

Karpenter node 문제가 해결되자 Keycloak Pod 3개는 Pending을 벗어났지만 모두 CrashLoopBackOff에 빠졌다. 최초의 결정적 로그는 다음 한 줄이었다.

```text
FATAL: password authentication failed for user "postgres"
```

이 메시지는 네트워크 연결 실패가 아니었다. Keycloak은 RDS hostname을 해석했고 5432 포트의 PostgreSQL까지 도달했으며, `postgres` 사용자로 인증을 시도했다. 실패 지점은 비밀번호 검증이었다.

자격증명 전달 경로는 다음과 같았다.

```text
Terraform random_password
  ├─ RDS master password
  └─ Secrets Manager JSON.password
       → ESO ExternalSecret
         → Kubernetes Secret
           → Keycloak
```

Secrets Manager와 Kubernetes Secret의 비밀번호 hash는 일치했지만 RDS는 해당 비밀번호를 거부했다. 따라서 ESO 전달 문제가 아니라, RDS에 실제 적용된 비밀번호와 Terraform·Secrets Manager 경로가 어긋난 상태였다.

처음에는 Secrets Manager 값을 RDS에 수동으로 넣어 맞추려 했다. 하지만 Windows PowerShell과 AWS CLI를 거쳐 JSON을 직접 재작성하는 과정에서 인용부호·파일 인코딩·property casing 문제가 발생했다. 어떤 시도는 RDS만 변경되고 Secrets Manager 쓰기는 실패했고, 어떤 시도는 ESO가 기대하는 소문자 `password` property를 잃게 만들었다. 복구 작업이 오히려 새로운 드리프트와 Secret schema 오류를 만들었다.

최종적으로 다음 명령으로 Terraform이 새로운 비밀번호를 만들고 RDS와 Secrets Manager를 동시에 갱신하게 했다.

```powershell
terraform apply -replace=random_password.db_password
```

그 결과 Keycloak 로그의 오류가 바뀌었다.

```text
이전:
FATAL: password authentication failed for user "postgres"

이후:
FATAL: database "keycloak" does not exist
```

이 변화는 실패가 아니었다. 인증 계층을 통과했다는 강한 증거였다. RDS 인스턴스에는 Terraform의 `db_name = "localy"`로 생성된 `localy` Database만 있었지만, Keycloak Helm values는 `database: keycloak`을 요청하고 있었다.

Kubernetes Job으로 같은 RDS 인스턴스에 다음 SQL을 실행했다.

```sql
CREATE DATABASE keycloak OWNER postgres;
```

그 뒤 Keycloak 3개 replica가 기동했고 다음 로그가 확인됐다.

```text
Keycloak 24.0.5 ... started in 47.290s.
Listening on: http://0.0.0.0:8080
```

응급 복구 후에는 두 작업을 정식화했다.

1. RDS 비밀번호의 유일한 쓰기 주체를 Terraform으로 명시
2. `keycloak` Database 생성 작업을 멱등한 Argo CD Sync hook Job으로 전환

---

# Step 1. 발단 — Pending 다음에는 CrashLoopBackOff가 기다리고 있었다

## 1.1 노드 장애 해결 후 드러난 애플리케이션 장애

회고 1과 2의 문제를 해결하면서 workload node가 Ready가 됐다. Keycloak Pod는 스케줄링 단계에서 컨테이너 실행 단계로 넘어갔다.

```text
이전:
Pending

이후:
CrashLoopBackOff
```

상태만 보면 또 다른 실패지만, 시스템 관점에서는 한 단계 전진한 결과였다.

```text
Pending
  → scheduler가 Pod를 배치하지 못함

CrashLoopBackOff
  → Pod는 배치됐고 컨테이너도 실행됐지만 프로세스가 반복 종료됨
```

따라서 더 이상 node selector나 Karpenter를 조사할 이유가 없었다. 조사 대상은 Keycloak 프로세스 로그였다.

## 1.2 최초의 결정적 로그

Keycloak 3개 Pod에서 공통으로 다음 오류가 발생했다.

```text
Datasource '<default>':
FATAL: password authentication failed for user "postgres"

ERROR: Failed to start server in (development) mode
ERROR: Failed to obtain JDBC connection
ERROR: FATAL: password authentication failed for user "postgres"
```

Pod 상태:

```text
NAME         READY   STATUS             RESTARTS
keycloak-0   0/1     CrashLoopBackOff   8
keycloak-1   0/1     CrashLoopBackOff   8
keycloak-2   0/1     CrashLoopBackOff   8
```

세 replica가 동일한 오류를 냈기 때문에 개별 Pod나 AZ 문제일 가능성은 낮았다. 세 Pod가 공유하는 RDS 자격증명 경로가 우선 조사 대상이었다.

## 1.3 로그 한 줄이 이미 배제한 가설

`password authentication failed`는 다음이 통과했음을 뜻한다.

```text
Keycloak 프로세스 기동        통과
Secret mount/env 구성         최소한 값 전달됨
RDS hostname DNS              통과
Pod → RDS 네트워크            통과
PostgreSQL 5432 연결          통과
postgres 사용자 인식          통과
password 검증                 실패
```

반대로 다음 메시지였다면 다른 계층을 조사해야 했다.

```text
UnknownHostException
  → DNS/hostname

Connection timed out
  → route/SG/NACL

Connection refused
  → endpoint/port/PostgreSQL 상태

password authentication failed
  → 자격증명 불일치
```

---

# Step 2. 기반 지식 — 비밀번호 하나가 네 시스템에 존재하는 이유

## 2.1 Terraform의 의도된 자격증명 흐름

RDS Terraform 구성은 `random_password.db_password` 하나를 두 소비자에게 전달하도록 설계돼 있었다.

```hcl
resource "random_password" "db_password" {
  length  = 16
  special = true
}

resource "aws_db_instance" "rds" {
  username = "postgres"
  password = random_password.db_password.result
}

resource "aws_secretsmanager_secret_version" "db_secret" {
  secret_string = jsonencode({
    username = "postgres"
    password = random_password.db_password.result
  })
}
```

논리적으로는 다음 등식이 항상 성립해야 한다.

```text
Terraform state password
==
RDS master password
==
Secrets Manager JSON.password
```

## 2.2 ESO는 비밀번호의 소유자가 아니다

ExternalSecret은 Secrets Manager의 값을 읽어 Kubernetes Secret으로 복제한다.

```yaml
- secretKey: KEYCLOAK_DATABASE_PASSWORD
  remoteRef:
    key: localy-prod-database-credentials
    property: password
```

ESO의 역할:

```text
AWS Secrets Manager 읽기
  → property=password 추출
    → K8s Secret의 KEYCLOAK_DATABASE_PASSWORD 생성
```

ESO는 RDS 비밀번호를 변경하지 않는다. 따라서 다음 상태는 충분히 가능하다.

```text
SM == K8s Secret
RDS != SM
```

이 경우 ESO는 완벽하게 동작하면서도 애플리케이션 인증은 실패한다.

## 2.3 Secrets Manager JSON은 값뿐 아니라 schema도 계약이다

`localy-prod-database-credentials`는 단순 문자열이 아니라 JSON 객체였다.

```json
{
  "engine": "postgres",
  "host": "...rds.amazonaws.com",
  "port": 5432,
  "username": "postgres",
  "password": "<redacted>",
  "database": "localy"
}
```

ExternalSecret의 `property: password`는 대소문자를 포함해 정확한 key를 요구한다.

```text
password   → 일치
Password   → 다른 key
PASSWORD   → 다른 key
```

비밀번호 문자열이 올바르더라도 key 이름이나 JSON 문법이 깨지면 ESO는 값을 읽을 수 없다.

## 2.4 PostgreSQL 인스턴스와 Database는 다르다

RDS 인스턴스는 PostgreSQL 서버 한 대에 해당한다. 그 안에는 여러 논리 Database를 둘 수 있다.

```text
RDS instance: prod-localy-rds
├─ database: postgres
├─ database: localy
└─ database: keycloak
```

Terraform `aws_db_instance.db_name`은 인스턴스 생성 시 초기 Database 하나만 만든다.

```hcl
db_name = "localy"
```

그러나 Keycloak values는 다른 이름을 요구했다.

```yaml
externalDatabase:
  user: postgres
  database: keycloak
```

RDS 인스턴스가 존재한다는 사실은 `keycloak` Database가 존재한다는 뜻이 아니다.

## 2.5 인증과 Database 선택의 실행 순서

PostgreSQL 접속은 개념적으로 다음 순서로 진행된다.

```text
1. host DNS 조회
2. TCP 5432 연결
3. PostgreSQL protocol handshake
4. 사용자·비밀번호 인증
5. 요청한 Database 선택
6. session 생성
```

비밀번호가 틀리면 4단계에서 멈춘다. 비밀번호를 고친 뒤에야 5단계의 `database does not exist`가 보일 수 있다.

따라서 처음부터 두 문제가 동시에 존재했어도 로그에는 앞단의 비밀번호 오류만 나타난다.

---

# Step 3. CCTV 추적 — Keycloak이 두 개의 문에서 차례로 막힌 과정

## 3.1 ESO가 Secrets Manager를 읽는다

ExternalSecret `keycloak-secrets`는 다음 두 AWS Secret을 읽었다.

```text
localy-prod-keycloak-admin
localy-prod-database-credentials
```

그 결과 Kubernetes Secret `localy-keycloak-secret`에 다음 key가 생성됐다.

```text
KEYCLOAK_ADMIN
KEYCLOAK_ADMIN_PASSWORD
KEYCLOAK_DATABASE_HOST
KEYCLOAK_DATABASE_PASSWORD
```

## 3.2 Keycloak이 Kubernetes Secret을 소비한다

Helm values는 기존 Secret을 참조했다.

```yaml
auth:
  existingSecret: localy-keycloak-secret
  passwordSecretKey: KEYCLOAK_ADMIN_PASSWORD

externalDatabase:
  user: postgres
  database: keycloak
  existingSecret: localy-keycloak-secret
  existingSecretPasswordKey: KEYCLOAK_DATABASE_PASSWORD
```

RDS hostname도 같은 Secret에서 env로 주입됐다.

```yaml
- name: KEYCLOAK_DATABASE_HOST
  valueFrom:
    secretKeyRef:
      name: localy-keycloak-secret
      key: KEYCLOAK_DATABASE_HOST
```

## 3.3 Keycloak이 RDS에 접속한다

Keycloak은 hostname을 해석하고 PostgreSQL에 도달했다.

```text
Found PostgreSQL server listening at
prod-localy-rds....rds.amazonaws.com:5432
```

하지만 RDS에 설정된 실제 master password와 Pod가 받은 password가 달랐다.

```text
FATAL: password authentication failed for user "postgres"
```

## 3.4 SM과 K8s Secret을 비교한다

비밀번호 자체를 출력하지 않고 길이와 SHA-256 hash를 비교했다.

```text
SM password hash == K8s password hash
```

이 결과로 확인된 것:

```text
Secrets Manager → ESO → K8s Secret 전달은 일치
```

이 결과만으로는 확인할 수 없는 것:

```text
RDS가 같은 비밀번호를 사용하고 있는가
```

RDS API는 현재 master password를 조회해 주지 않는다. 실제 인증 성공 여부로만 검증할 수 있다.

## 3.5 수동 동기화가 Secret schema를 손상시킨다

Secrets Manager 값과 RDS password를 동일한 새 값으로 수동 갱신하려 했다. Windows 환경에서 다음 요소가 겹쳤다.

- PowerShell object의 property casing
- `ConvertTo-Json`
- AWS CLI `--secret-string`
- `file://`와 `fileb://`
- UTF-8 BOM
- shell 인용부호
- 특수문자가 포함된 password

일부 시도는 Secrets Manager 갱신에 실패한 뒤 RDS만 변경했다. 이는 기존 드리프트를 해소하지 못하고 새로운 비밀번호 불일치를 만들었다.

또 다른 시도 이후 ESO는 기대한 소문자 `password` property를 찾지 못했다.

```text
ExternalSecret expects: password
actual JSON schema:      expected key missing or altered
```

복구 대상이 두 개에서 세 개로 늘어났다.

```text
처음:
RDS password ↔ SM password

수동 복구 후:
RDS password ↔ SM password
               +
SM JSON schema ↔ ExternalSecret property contract
```

## 3.6 Terraform이 RDS와 Secrets Manager를 다시 한 번에 갱신한다

수동 문자열 전달을 중단하고 원래 소유자인 Terraform으로 돌아갔다.

```powershell
terraform apply -replace=random_password.db_password
```

Terraform은 다음 작업을 하나의 dependency graph로 처리했다.

```text
random_password 재생성
  ├─ aws_db_instance.rds.password 갱신
  └─ aws_secretsmanager_secret_version.db_secret 재작성
       └─ jsonencode로 정해진 schema 보장
```

이 작업은 단순히 같은 password를 두 군데에 복사한 것이 아니다. **값과 JSON 구조를 코드에 선언된 형태로 함께 복원한 것**이다.

## 3.7 ESO와 Argo CD 충돌이 새 Secret 전달을 지연시킨다

Terraform으로 AWS 쪽을 고친 뒤에도 ExternalSecret은 다음 상태를 보였다.

```text
reason=SecretSyncedError
message=could not update Secret
```

이는 password 값 자체와 다른 문제였다. Argo CD와 ESO가 `localy-keycloak-secret`을 동시에 관리하면서 update 충돌이 발생했다.

당시 복구를 위해 ESO를 재시작하고, generated Secret에서 Argo tracking label을 제거하고, ExternalSecret 강제 sync와 Keycloak Pod 재시작을 수행했다.

이 충돌의 구조적 원인과 영구 수정은 회고 5에서 별도로 다룬다.

## 3.8 로그가 `database does not exist`로 바뀐다

새 password가 Keycloak에 전달된 뒤 로그는 다음처럼 바뀌었다.

```text
Found PostgreSQL server listening at ...:5432
Configuring database settings
FATAL: database "keycloak" does not exist
```

이 변화로 확인된 사실:

```text
DNS                   통과
네트워크              통과
postgres 사용자       통과
새 password 인증      통과
Database 선택         실패
```

비밀번호 복구가 실패한 것이 아니라, 이전 오류 뒤에 가려져 있던 두 번째 장애가 노출된 것이다.

## 3.9 일회성 Job이 `keycloak` Database를 생성한다

RDS는 private subnet에 있어 로컬 실행 환경에서 직접 접근하기 어려웠다. 반면 workload Pod는 RDS security group이 허용하는 VPC 내부에 있었다.

`postgres:15-alpine` 이미지의 일회성 Job을 실행했다.

```text
PGHOST     ← localy-keycloak-secret
PGPASSWORD ← localy-keycloak-secret
PGUSER     = postgres
PGDATABASE = localy
```

Job이 실행한 핵심 SQL:

```sql
CREATE DATABASE keycloak OWNER postgres;
```

실행 결과:

```text
job.batch/create-keycloak-db created
job.batch/create-keycloak-db condition met
CREATE DATABASE
DONE
```

## 3.10 Keycloak이 최종 기동한다

Job 완료 후 Keycloak 3개 Pod를 재시작했다.

```text
NAME         READY   STATUS    RESTARTS
keycloak-0   1/1     Running   0
keycloak-1   1/1     Running   0
keycloak-2   1/1     Running   0
```

로그:

```text
Realm 'localy' already exists. Import skipped
Import finished successfully
Keycloak 24.0.5 on JVM ... started in 47.290s.
Listening on: http://0.0.0.0:8080
```

---

# Step 4. 삽질과 해결 — Secret을 손으로 맞추는 일이 왜 위험했는가

## 4.1 첫 번째 접근: SM 값을 RDS에 직접 적용

처음 제안한 응급 복구는 다음과 같았다.

```powershell
$secret = aws secretsmanager get-secret-value ... |
  ConvertFrom-Json

aws rds modify-db-instance `
  --master-user-password $secret.password `
  --apply-immediately
```

이 방법은 현재 SM 값을 RDS에 맞추는 즉시 복구로는 논리적이다. 하지만 Terraform state는 변경되지 않는다.

```text
Terraform state: 값 A
SM:              값 B
RDS:             값 B
```

다음 Terraform apply에서 A가 다시 주입될 수 있어 장기 해결이 아니다.

## 4.2 두 번째 접근: 새 password를 만들어 SM과 RDS에 직접 기록

다음 시도는 한 PowerShell 프로세스에서 password를 생성하고 두 시스템에 넣는 방식이었다.

개념:

```text
$newPassword
  ├─ aws secretsmanager put-secret-value
  └─ aws rds modify-db-instance
```

문제는 이 두 API 호출이 transaction이 아니라는 점이다.

```text
첫 번째 성공 + 두 번째 실패
또는
첫 번째 실패 + 두 번째 성공
```

둘 중 하나만 성공하면 즉시 drift가 생긴다. 실제 과정에서도 SM 쓰기가 실패했지만 RDS 변경이 진행된 시도가 있었다.

## 4.3 PowerShell JSON 재구성의 함정

Secret JSON을 직접 다룰 때는 password 문자열만이 아니라 객체 전체를 재작성하게 된다.

위험 요소:

```text
property 대소문자 변경
필드 누락
port의 number → string 변환
잘못된 escaping
BOM 포함 파일
CLI가 파일 URI를 값 자체로 인식
오류 출력에 민감값 노출
```

특히 ExternalSecret은 정확한 `property: password`를 요구하므로 schema 변화는 즉시 운영 장애로 이어진다.

## 4.4 실패한 복구에서 얻은 보안 교훈

한 수동 시도에서는 AWS CLI 오류 출력에 민감한 password가 노출될 가능성이 생겼다. 이 경우 올바른 대응은 “명령을 고쳐 같은 password를 다시 사용”하는 것이 아니다.

```text
노출 가능성이 생긴 credential
  → 폐기
  → 새로운 password로 rotate
```

비밀번호를 콘솔에 직접 전달하는 명령은 process history, terminal output, shell transcript에도 남을 수 있다.

## 4.5 채택한 해결: password 생성 주체로 돌아간다

최종 복구는 Terraform resource replacement였다.

```powershell
terraform apply -replace=random_password.db_password
```

이 방식의 장점:

- password를 Terraform dependency graph 안에서 생성
- RDS와 SM이 같은 resource를 참조
- `jsonencode`가 schema와 escaping을 보장
- state가 실제 변경을 추적
- 다음 plan에서 drift를 만들지 않음

주의할 점:

Terraform apply도 AWS API 두 개를 완전한 분산 transaction으로 묶지는 않는다. 중간 실패 가능성은 있다. 그러나 동일 선언과 state를 기반으로 재실행해 convergence할 수 있다는 점이 수동 명령 두 개와 다르다.

## 4.6 `database keycloak`을 Terraform provider로 만들지 않은 이유

`postgresql_database` 같은 resource를 사용하려면 Terraform 실행 위치에서 private RDS로 TCP 연결할 수 있어야 한다.

현재 L3 Terraform 실행 위치:

```text
개발자 PC / VPC 외부
```

RDS 위치:

```text
private database subnet
publicly_accessible = false 성격의 내부 endpoint
```

AWS control-plane API로 RDS 인스턴스를 만드는 것은 가능하지만 PostgreSQL data-plane에 접속해 SQL을 실행하는 것은 별도 네트워크 경로가 필요하다.

따라서 PostgreSQL provider를 L3에 억지로 추가하지 않고, 이미 VPC 안에서 실행되는 Kubernetes Job이 Database를 생성하도록 했다.

## 4.7 응급 Job을 정식 GitOps Job으로 전환

일회성 `create-keycloak-db` Job은 현재 RDS만 복구한다. RDS를 재생성하면 `keycloak` Database는 다시 사라진다.

이를 다음 멱등 로직으로 정식화했다.

```sh
exists="$(
  psql -Atc \
    "SELECT 1 FROM pg_database WHERE datname = 'keycloak'"
)"

if [ "$exists" = "1" ]; then
  echo "Database keycloak already exists — nothing to do"
  exit 0
fi

psql -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE keycloak OWNER postgres"
```

Argo CD Sync hook과 wave:

```text
SecretStore       wave -1
ExternalSecret    wave  0
DB bootstrap Job  wave  1
Keycloak          wave  2
```

정식 Job은 Secret 값을 환경변수에 직접 선언하지 않고 read-only volume 파일로 받는다.

```text
/etc/secrets/host
/etc/secrets/password
```

Job 실행 결과가 다음과 같다면 멱등성이 검증된 것이다.

```text
Database keycloak already exists — nothing to do
```

---

# Step 5. 넥스트 스텝 — 오류가 바뀌면 조사 계층도 바꿔라

## 5.1 가장 중요한 진단 원칙

> 이전 오류가 사라지고 더 뒤 단계의 오류가 나타났다면, 앞 단계의 수정은 성공했을 가능성이 높다.

이번 사건의 오류 진행:

```text
Pending
  → node/scheduling 문제

CrashLoopBackOff
  → 프로세스 기동 문제

password authentication failed
  → RDS 도달 성공, 인증 실패

database "keycloak" does not exist
  → 인증 성공, Database 선택 실패

Keycloak started / Listening
  → JDBC와 애플리케이션 기동 성공
```

## 5.2 RDS credential SSOT 규칙

허용되는 쓰기 주체:

```text
Terraform random_password.db_password
```

파생 소비자:

```text
RDS master password
Secrets Manager secret version
ESO
Kubernetes Secret
Keycloak
```

금지:

```text
aws secretsmanager put-secret-value
aws rds modify-db-instance --master-user-password
Kubernetes Secret 직접 수정
RDS Console에서 password 변경
```

rotation:

```powershell
terraform apply -replace=random_password.db_password
```

## 5.3 Secret 검증 시 값을 출력하지 않는다

안전한 비교 방법:

- key 이름만 출력
- 문자열 길이 비교
- 메모리 안에서 hash를 계산해 equality만 출력
- 임시 파일은 사용 직후 삭제
- command history에 password literal을 넣지 않음

예:

```text
SM==K8s: True
```

다만 hash prefix도 낮은 entropy secret에는 추측 공격 보조 정보가 될 수 있다. 가능하면 최종 출력은 equality boolean만 남긴다.

## 5.4 DB 연결 오류 분기표

```text
could not translate host name
  → Secret host / DNS

connection timed out
  → SG / NACL / route / endpoint

password authentication failed
  → 사용자·password SSOT

database does not exist
  → 논리 Database bootstrap

permission denied for schema/table
  → DB role / grant / migration

relation does not exist
  → 애플리케이션 schema migration
```

## 5.5 재구축 acceptance criteria

```text
[ ] Terraform plan에서 RDS password drift 없음
[ ] Secrets Manager JSON에 정확한 lowercase key 존재
[ ] ESO ExternalSecret Ready=True
[ ] generated Secret의 writer는 ESO 하나
[ ] DB bootstrap Job Complete
[ ] Job 재실행 시 "already exists"로 성공
[ ] Keycloak 3개 replica Ready
[ ] Keycloak 로그에 JDBC FATAL 없음
[ ] realm import가 성공하거나 기존 realm을 정상 skip
```

## 5.6 재발 방지 체크리스트

- [ ] RDS와 SM이 동일한 `random_password` resource를 참조한다.
- [ ] `lifecycle.ignore_changes = [password]`를 추가하지 않는다.
- [ ] Secret JSON은 Terraform `jsonencode`로만 생성한다.
- [ ] 수동 password rotation runbook을 제공하지 않는다.
- [ ] rotation 후 ESO refresh와 Pod rollout을 검증한다.
- [ ] RDS 재생성 테스트에 `keycloak` Database bootstrap을 포함한다.
- [ ] DB Job은 존재 여부를 먼저 확인해 멱등하게 실행한다.
- [ ] private RDS data-plane 작업은 VPC 내부 runner에서 실행한다.
- [ ] 오류 메시지가 바뀌면 같은 수정만 반복하지 않는다.
- [ ] Secret ownership 충돌은 password 문제와 분리해 조사한다.

---

## 최종 원인 트리

```text
Keycloak 3개 replica CrashLoopBackOff
│
├─ 첫 번째 직접 원인
│  └─ RDS password와 Keycloak password 불일치
│     ├─ Keycloak password = K8s Secret
│     ├─ K8s Secret = Secrets Manager
│     └─ RDS password != Secrets Manager
│
├─ 복구 중 추가 장애
│  ├─ 수동 SM/RDS 갱신이 원자적이지 않음
│  ├─ PowerShell/AWS CLI JSON 전달 실패
│  └─ SM JSON의 lowercase password schema 손상
│
├─ 복구 지연 요인
│  └─ Argo CD와 ESO가 generated Secret을 동시에 수정
│
├─ 두 번째 직접 원인
│  └─ database "keycloak" does not exist
│     ├─ RDS db_name = localy
│     └─ Keycloak externalDatabase.database = keycloak
│
└─ 최종 해결
   ├─ Terraform -replace로 RDS + SM password 재수렴
   ├─ ESO를 통해 K8s Secret 갱신
   ├─ 같은 RDS에 keycloak Database 생성
   └─ 멱등 Argo Sync hook Job으로 정식화
```

## 한 문장으로 남기는 교훈

**오류 메시지가 `비밀번호 불일치`에서 `Database 없음`으로 바뀐 것은 복구 실패가 아니라, 인증이라는 첫 번째 문을 통과했다는 증거였다.**

