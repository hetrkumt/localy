# 응급 SQL을 재현 가능한 초기화로

> 일회성 `CREATE DATABASE`를 Argo CD Sync hook과 멱등 Job으로 정식화한 기록

## 문서 정보

- 정식화 시각: 2026-07-31 01:37~01:42 KST
- 환경: Amazon RDS PostgreSQL 15, EKS, Argo CD, ESO, Kustomize
- 선행 사건: 회고 3의 Keycloak `database "keycloak" does not exist`
- 기존 응급조치: 클러스터 내부 일회성 Job에서 `CREATE DATABASE keycloak`
- 설계 목표: RDS 재생성 후에도 사람 개입 없이 Database를 생성
- 구현 위치: `platform/keycloak/base/create-db-job.yaml`
- 실행 주체: Argo CD Sync hook
- 의존 순서: SecretStore → ExternalSecret → DB Job → Keycloak
- 검증 결과: 기존 Database에서 재실행해 `already exists`로 정상 완료

---

## Executive Summary

회고 3에서 Keycloak을 복구하기 위해 실행한 핵심 명령은 단순했다.

```sql
CREATE DATABASE keycloak OWNER postgres;
```

이 SQL은 당시 RDS에 `keycloak` Database를 만들었고 Keycloak 3개 replica를 정상 기동시켰다. 그러나 복구가 성공했다는 사실과 시스템이 재구축 가능해졌다는 사실은 다르다.

당시 상태는 다음과 같았다.

```text
현재 RDS:
  localy     존재
  keycloak   존재  ← 운영 중 일회성 Job으로 생성

Git/Terraform desired state:
  localy     선언됨
  keycloak   선언되지 않음
```

RDS를 삭제하고 다시 만들면 Terraform의 `db_name = "localy"`만 재현된다. 운영자가 장애 당시 실행했던 SQL을 기억하지 못하면 Keycloak은 다시 `database "keycloak" does not exist`로 실패한다.

처음 고려할 수 있는 방법은 Terraform PostgreSQL provider로 `postgresql_database.keycloak`을 관리하는 것이다. 그러나 Terraform을 실행하는 개발자 PC는 private RDS data-plane에 접속할 수 없었다. AWS provider가 RDS 인스턴스를 생성하는 것은 AWS control-plane API 호출이지만, PostgreSQL provider가 Database를 생성하는 것은 5432 포트로 실제 SQL을 실행하는 별개의 작업이다.

반면 EKS workload node와 Pod는 이미 VPC 내부에서 RDS에 접근할 수 있었다. 따라서 추가 Database의 생명주기를 다음처럼 나눴다.

```text
Terraform:
  RDS 인스턴스 + 초기 localy Database 생성

GitOps Job:
  같은 RDS 안에 keycloak Database 생성
```

Job은 다음 순서로 동작한다.

1. ESO가 만든 Secret의 host와 password 파일을 기다린다.
2. `pg_isready`로 PostgreSQL 연결 가능 상태를 기다린다.
3. `pg_database`에서 `keycloak` 존재 여부를 조회한다.
4. 없을 때만 `CREATE DATABASE`를 실행한다.
5. 이미 있으면 성공 코드 0으로 종료한다.

Argo CD sync wave는 다음 순서를 표현한다.

```text
wave -1  SecretStore
wave  0  ExternalSecret
wave  1  keycloak-create-db Sync hook
wave  2  Keycloak workload
```

실제 기존 RDS에서 재실행한 결과는 다음과 같았다.

```text
Waiting for ExternalSecret-backed credentials...
Waiting for PostgreSQL at prod-localy-rds....rds.amazonaws.com...
Database keycloak already exists — nothing to do
```

Job은 `Complete 1/1`로 끝났다. 이는 초기화 로직이 “처음 한 번만 성공하는 스크립트”가 아니라 현재 상태에 수렴하는 멱등 작업임을 검증했다.

---

# Step 1. 발단 — 장애는 복구했지만 코드는 고쳐지지 않았다

## 1.1 응급조치의 성공

Keycloak password와 RDS master password를 일치시킨 뒤 오류가 다음처럼 바뀌었다.

```text
FATAL: database "keycloak" does not exist
```

클러스터 내부에서 `postgres:15-alpine` Job을 실행해 다음 SQL을 적용했다.

```sql
CREATE DATABASE keycloak OWNER postgres;
```

실행 결과:

```text
CREATE DATABASE
DONE
```

Keycloak은 이후 정상 기동했다.

```text
Keycloak 24.0.5 ... started
Listening on: http://0.0.0.0:8080
```

## 1.2 현재 상태와 선언 상태의 차이

응급 Job은 실행 후 삭제됐다. SQL 결과는 RDS 내부에 남았지만, 이를 만든 절차는 Git과 Terraform 어디에도 없었다.

```text
AWS 실제 상태:
  keycloak Database 있음

Terraform:
  keycloak Database 모름

GitOps:
  keycloak Database 모름

운영 지식:
  장애 대응 대화와 terminal 기록에만 있음
```

이 상태에서 RDS를 재생성하면 추가 Database는 복원되지 않는다.

## 1.3 왜 `terraform apply`만으로 복원되지 않는가

RDS resource에는 다음 설정이 있었다.

```hcl
resource "aws_db_instance" "rds" {
  db_name  = "localy"
  username = "postgres"
}
```

`db_name`은 RDS 인스턴스 초기 생성 때 Database 하나를 만든다. 여러 Database 이름을 배열로 전달하는 속성이 아니다.

다음과 같은 선언은 지원되지 않는다.

```hcl
# 존재하지 않는 형태
db_names = ["localy", "keycloak"]
```

따라서 RDS 인스턴스 생성과 추가 PostgreSQL Database 생성은 별도 lifecycle로 다뤄야 했다.

## 1.4 정식화의 완료 조건

단순히 Job YAML을 Git에 넣는 것만으로는 충분하지 않았다. 다음 조건을 만족해야 했다.

```text
[ ] Secret이 늦게 생성돼도 기다릴 수 있음
[ ] RDS가 아직 available이 아니어도 기다릴 수 있음
[ ] Database가 없으면 생성
[ ] 이미 있으면 성공
[ ] Keycloak보다 먼저 완료
[ ] 실패하면 Keycloak rollout을 진행시키지 않음
[ ] password를 manifest에 기록하지 않음
[ ] private RDS에 접근 가능한 위치에서 실행
[ ] RDS 재생성 후 자동으로 재실행
```

---

# Step 2. 기반 지식 — 인프라 생성과 Database 초기화는 다른 계층이다

## 2.1 AWS control plane과 PostgreSQL data plane

Terraform AWS provider가 RDS를 생성할 때 호출하는 것은 AWS API다.

```text
Terraform
  → AWS RDS API
    → DB instance 생성
```

PostgreSQL Database를 추가할 때는 RDS endpoint에 직접 접속해 SQL을 실행해야 한다.

```text
PostgreSQL client/provider
  → DNS
  → TCP 5432
  → PostgreSQL 인증
  → CREATE DATABASE
```

두 작업 모두 “Terraform으로 할 수 있는 일”처럼 보일 수 있지만 네트워크 요구사항이 다르다.

## 2.2 왜 PostgreSQL provider를 채택하지 않았는가

개념적으로 다음 구성은 가능하다.

```hcl
provider "postgresql" {
  host     = aws_db_instance.rds.address
  username = "postgres"
  password = random_password.db_password.result
}

resource "postgresql_database" "keycloak" {
  name  = "keycloak"
  owner = "postgres"
}
```

하지만 provider는 plan/apply 과정에서 private RDS endpoint에 접속해야 한다.

당시 실행 경계:

```text
Terraform runner:
  개발자 PC, VPC 외부

RDS:
  private database subnet

결과:
  AWS API 접근 가능
  PostgreSQL 5432 data-plane 접근 불가
```

VPN, bastion, self-hosted runner 또는 VPC 내부 Terraform 실행 환경을 새로 마련하지 않는 한 안정적으로 동작하지 않는다.

provider를 코드에 추가해 놓고 일부 환경에서만 접속되게 만드는 것은 재현성을 높이는 것이 아니라 실행 환경 의존성을 숨기는 결과가 된다.

## 2.3 `null_resource`와 `local-exec`도 같은 문제다

다음 방식도 근본적으로 다르지 않다.

```hcl
provisioner "local-exec" {
  command = "psql ... -c 'CREATE DATABASE keycloak'"
}
```

문제:

- `psql` binary가 runner에 필요
- runner가 private RDS에 접근해야 함
- password가 command line이나 process 목록에 노출될 수 있음
- Terraform provisioner 재실행 조건 관리가 불명확
- 실패 후 state와 실제 DB 상태를 해석하기 어려움

Terraform이 명령을 호출한다는 사실은 네트워크 경계를 없애지 않는다.

## 2.4 Kubernetes Job이 적합했던 이유

EKS workload node는 RDS가 있는 VPC 내부에 존재했다.

```text
Job Pod
  → VPC DNS
  → RDS security group 허용
  → private RDS:5432
```

또한 이미 ESO를 통해 필요한 host와 password가 Kubernetes Secret으로 제공되고 있었다.

```text
Secrets Manager
  → ESO
    → localy-keycloak-secret
      → DB bootstrap Job
```

즉 새로운 network path나 credential distribution 시스템을 만들 필요가 없었다.

## 2.5 Job과 initContainer의 차이

Keycloak Pod에 initContainer를 넣어 Database를 생성하는 방법도 생각할 수 있다.

하지만 replicaCount가 3이므로 세 Pod가 동시에 초기화를 시도할 수 있다.

```text
keycloak-0 initContainer ─┐
keycloak-1 initContainer ─┼→ CREATE DATABASE 경쟁
keycloak-2 initContainer ─┘
```

초기화 로직과 애플리케이션 lifecycle도 강하게 결합된다.

독립 Job의 장점:

- 초기화 실행 주체가 하나
- 성공·실패 상태가 별도 Kubernetes resource로 남음
- 로그를 독립적으로 확인 가능
- Argo CD가 Keycloak보다 앞에 배치 가능
- Keycloak replica 수와 무관

## 2.6 멱등성이 필요한 이유

Argo CD sync는 여러 번 실행될 수 있다.

- Git 변경
- 수동 sync
- self-heal
- Application 재생성
- 클러스터 복구

다음 SQL을 무조건 실행하면 두 번째 sync부터 실패한다.

```sql
CREATE DATABASE keycloak;
```

PostgreSQL의 `CREATE DATABASE`에는 일반적인 `IF NOT EXISTS` 문법이 없다. 따라서 먼저 catalog를 조회해야 한다.

```sql
SELECT 1
FROM pg_database
WHERE datname = 'keycloak';
```

원하는 상태:

```text
없음 → 생성 → 성공
있음 → 아무것도 하지 않음 → 성공
```

이것이 명령 반복이 아니라 상태 수렴을 기준으로 한 멱등성이다.

---

# Step 3. CCTV 추적 — Argo sync 한 번에서 일어난 일

## 3.1 wave -1: SecretStore 생성

Argo CD는 먼저 namespace-scoped SecretStore를 적용한다.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: keycloak-store
  namespace: auth-namespace
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

SecretStore는 ESO가 어느 AWS service와 region을 사용할지 정의한다.

```yaml
provider:
  aws:
    service: SecretsManager
    region: ap-northeast-2
```

## 3.2 wave 0: ExternalSecret 생성

다음 wave에서 ExternalSecret을 적용한다.

```yaml
metadata:
  name: keycloak-secrets
  annotations:
    argocd.argoproj.io/sync-wave: "0"
```

ExternalSecret은 다음 값을 요청한다.

```text
localy-prod-database-credentials.password
  → KEYCLOAK_DATABASE_PASSWORD

localy-prod-database-credentials.host
  → KEYCLOAK_DATABASE_HOST
```

여기서 중요한 점은 ExternalSecret resource가 생성됐다고 generated Secret이 같은 순간에 준비되는 것은 아니라는 사실이다. ESO controller의 reconciliation은 비동기다.

```text
Argo: ExternalSecret object applied
ESO:  이후 AWS를 읽고 Secret 생성
```

## 3.3 wave 1: Sync hook Job 생성

DB Job은 일반 resource가 아니라 Sync phase의 hook이다.

```yaml
metadata:
  name: keycloak-create-db
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

의미:

```text
hook: Sync
  → 일반 sync 과정 안에서 실행

wave: 1
  → wave -1, 0 이후 실행

BeforeHookCreation
  → 다음 sync에서 같은 이름의 이전 hook이 남아 있으면 먼저 삭제
```

## 3.4 Secret이 아직 없어도 Pod가 생성된다

Secret volume에는 `optional: true`가 설정됐다.

```yaml
volumes:
  - name: secret-volume
    secret:
      secretName: localy-keycloak-secret
      optional: true
```

이 설정이 없으면 Secret이 아직 생성되지 않았을 때 Pod가 다음 상태에 머물 수 있다.

```text
CreateContainerConfigError
또는
FailedMount
```

optional volume을 사용하면 Pod를 먼저 시작하고 shell script가 필요한 파일의 등장을 기다릴 수 있다.

## 3.5 Job이 Secret 파일을 기다린다

Secret은 `/etc/secrets`에 read-only로 mount된다.

```yaml
items:
  - key: KEYCLOAK_DATABASE_HOST
    path: host
  - key: KEYCLOAK_DATABASE_PASSWORD
    path: password
```

script:

```sh
while [ ! -s "$PGHOSTFILE" ] || [ ! -s "$PGPASSFILE" ]; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "Timed out waiting for /etc/secrets/{host,password}"
    exit 1
  fi
  sleep 2
done
```

최대 대기 시간은 약 120초다.

```text
60회 × 2초 = 120초
```

무한정 기다리지 않고 명확한 timeout으로 실패시킨다.

## 3.6 파일을 읽어 PostgreSQL client 환경을 준비한다

Kubernetes manifest는 password 값을 직접 env `value`로 기록하지 않는다. 컨테이너가 시작된 뒤 mount file을 읽어 현재 shell과 `psql` process에 전달한다.

```sh
export PGHOST="$(cat "$PGHOSTFILE")"
export PGPASSWORD="$(cat "$PGPASSFILE")"
```

정확히 말하면 password는 최종적으로 `PGPASSWORD` 환경변수에 들어간다. 다만 Kubernetes Pod spec의 env section이나 `kubectl describe pod`에 Secret 값 자체가 나타나지 않고, source는 read-only Secret volume으로 유지된다.

## 3.7 RDS 준비 상태를 기다린다

Secret이 준비돼도 RDS가 password 변경이나 재시작 중일 수 있다.

```sh
until pg_isready \
  -h "$PGHOST" \
  -U "$PGUSER" \
  -d "$PGDATABASE"
do
  # 최대 120초 대기
done
```

`PGDATABASE=localy`를 사용한 이유는 `keycloak` Database가 아직 없기 때문이다. 이미 존재하는 초기 Database에 접속한 후 catalog를 조회하고 sibling Database를 만든다.

```text
접속 대상: localy
생성 대상: keycloak
```

## 3.8 catalog에서 원하는 상태를 확인한다

```sh
exists="$(
  psql -Atc \
    "SELECT 1 FROM pg_database WHERE datname = 'keycloak'"
)"
```

옵션:

```text
-A  unaligned output
-t  tuple only
-c  command 실행
```

존재하면 출력이 `1`이 된다.

```sh
if [ "$exists" = "1" ]; then
  echo "Database keycloak already exists — nothing to do"
  exit 0
fi
```

이미 원하는 상태이므로 실패가 아니라 성공으로 종료한다.

## 3.9 없을 때만 Database를 만든다

```sh
psql -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE keycloak OWNER postgres"
```

`ON_ERROR_STOP=1`은 SQL 오류가 발생했을 때 `psql`이 성공처럼 다음 단계로 진행하지 않도록 한다.

성공 로그:

```text
Creating database keycloak...
Database keycloak created
```

## 3.10 wave 2: Keycloak이 배포된다

Keycloak Helm values에는 공통 sync wave가 추가됐다.

```yaml
commonAnnotations:
  argocd.argoproj.io/sync-wave: "2"
```

Argo CD는 wave 1의 Sync hook이 성공한 뒤 Keycloak workload를 진행한다.

```text
DB Job Complete
  → Keycloak StatefulSet/Pod rollout
```

Database 초기화가 실패하면 Keycloak rollout을 먼저 진행해 CrashLoop을 대량 생성하지 않는다.

---

# Step 4. 삽질과 해결 — “한 번 실행”을 “언제든 재실행”으로 바꾸기

## 4.1 채택하지 않은 방식: 새 RDS 인스턴스 생성

Keycloak 전용 RDS를 하나 더 만드는 방법은 격리 측면에서 장점이 있다.

하지만 현재 단계에서는 다음 비용이 늘어난다.

- 별도 RDS 인스턴스 비용
- subnet group과 security group 관리
- backup·monitoring·patching 대상 증가
- credential과 Secret 추가
- connection pool과 운영 복잡도 증가

현재 요구사항은 데이터 격리가 아니라 논리 Database 하나의 추가였다. 같은 PostgreSQL 인스턴스에 sibling Database를 만드는 것으로 충분했다.

## 4.2 채택하지 않은 방식: Keycloak이 `localy` Database 사용

values를 다음처럼 바꾸면 Database 추가가 필요 없을 수 있다.

```yaml
externalDatabase:
  database: localy
```

하지만 애플리케이션 데이터와 Keycloak schema가 같은 Database에 섞인다.

```text
localy Database
├─ 서비스 table
└─ Keycloak table
```

schema를 별도로 나누더라도 ownership, migration, backup 복구 범위가 결합된다. 이미 `keycloak`이라는 명확한 경계가 설계돼 있었으므로 이를 유지했다.

## 4.3 채택하지 않은 방식: PreSync hook

DB 초기화는 애플리케이션보다 앞서야 하므로 처음에는 PreSync가 자연스러워 보일 수 있다.

하지만 SecretStore와 ExternalSecret도 같은 Application이 생성한다. PreSync hook은 일반 Sync resource보다 먼저 실행되기 때문에 Secret 생성 기반 자체가 아직 없을 수 있다.

```text
PreSync DB Job
  → SecretStore 없음
  → ExternalSecret 없음
  → credential 없음
  → bootstrap deadlock
```

따라서 모든 resource를 Sync phase에 두고 wave로 순서를 표현했다.

```text
Sync/-1 → Sync/0 → Sync/1 hook → Sync/2
```

## 4.4 ExternalSecret wave만으로 충분하지 않았던 이유

Argo CD의 wave는 Kubernetes resource apply 순서를 보장한다. 외부 controller의 reconciliation 완료까지 자동으로 기다려 주는 범용 barrier는 아니다.

```text
ExternalSecret applied
≠
generated Secret ready
```

그래서 Job 내부에 credential file 대기 loop를 추가했다. 선언 순서와 runtime readiness를 각각 처리한 것이다.

```text
sync wave:
  resource 생성 순서

polling loop:
  실제 준비 완료 대기
```

## 4.5 `sleep 30` 대신 조건을 기다린 이유

고정 sleep:

```sh
sleep 30
```

문제:

- Secret이 2초 만에 준비돼도 30초 낭비
- 31초 걸리면 실패
- 무엇을 기다리는지 로그에서 알 수 없음

조건 기반 대기:

```sh
while [ ! -s "$PGHOSTFILE" ] || [ ! -s "$PGPASSFILE" ]; do
  sleep 2
done
```

장점:

- 준비되는 즉시 진행
- timeout을 명시
- 실패 이유가 로그에 남음

RDS도 같은 방식으로 `pg_isready`를 사용했다.

## 4.6 password를 command line 인자로 전달하지 않은 이유

다음 형태는 피했다.

```sh
psql "postgresql://postgres:password@host/localy"
```

URL encoding이 필요한 특수문자 문제가 있고, process list나 로그에 credential이 노출될 수 있다.

대신 Secret volume에서 읽은 값을 process 환경으로 전달했다.

```sh
export PGPASSWORD="$(cat /etc/secrets/password)"
```

더 엄격한 구현에서는 PostgreSQL `.pgpass` 형식 파일을 만들어 `PGPASSFILE`만 지정할 수 있다.

```text
host:5432:localy:postgres:password
```

현재 코드의 `/etc/secrets/password`는 raw password 파일이므로 PostgreSQL 표준 `.pgpass` 파일 자체는 아니다. 따라서 실제 인증은 `PGPASSWORD` export가 담당한다.

## 4.7 보안 컨텍스트를 최소화한다

Pod:

```yaml
runAsNonRoot: true
runAsUser: 70
runAsGroup: 70
fsGroup: 70
seccompProfile:
  type: RuntimeDefault
```

Container:

```yaml
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
```

`psql`은 Database 생성 권한이 필요하지만 Linux root 권한은 필요하지 않다. OS 권한과 PostgreSQL 권한을 분리했다.

쓰기 가능한 `/tmp`는 memory-backed `emptyDir`로 제한했다.

```yaml
emptyDir:
  medium: Memory
  sizeLimit: 32Mi
```

## 4.8 실제 멱등성 검증

정식 Job을 처음 sync한 시점에는 응급조치로 `keycloak` Database가 이미 존재했다.

이 상황은 멱등성을 검증하기에 적합했다.

```text
NAME                 STATUS     COMPLETIONS   DURATION
keycloak-create-db   Complete   1/1           17s
```

로그:

```text
Waiting for ExternalSecret-backed credentials...
Waiting for PostgreSQL at prod-localy-rds....rds.amazonaws.com...
Database keycloak already exists — nothing to do
```

두 번째 실행에서도 실패하지 않고 현재 상태를 확인한 뒤 성공했다.

---

# Step 5. 넥스트 스텝 — 초기화도 애플리케이션의 일부다

## 5.1 가장 중요한 설계 원칙

> 운영 중 수동으로 한 번 실행해야 하는 명령이 서비스 기동 조건이라면, 그 명령은 문서가 아니라 배포 시스템의 일부가 되어야 한다.

응급 상태:

```text
Terraform apply
  → RDS(localy) 생성
    → 운영자가 SQL 기억
      → keycloak DB 수동 생성
        → Keycloak 기동
```

정식 상태:

```text
Terraform apply
  → RDS(localy) 생성

Argo sync
  → Secret 준비
    → keycloak DB 수렴
      → Keycloak 기동
```

## 5.2 bootstrap과 migration을 구분한다

이번 Job의 책임:

```text
Database container 생성
  CREATE DATABASE keycloak
```

Keycloak의 책임:

```text
Database 안의 table/schema migration
```

두 작업을 섞지 않는다.

```text
bootstrap:
  DB가 존재하는가

migration:
  DB 내부 schema가 현재 앱 버전과 맞는가
```

## 5.3 소유권 경계를 코드에 남긴다

RDS Terraform에는 다음 근거를 주석으로 남겼다.

```hcl
# aws_db_instance.db_name creates exactly ONE database ("localy").
# Keycloak needs a sibling DB named "keycloak" on this same instance.
# That is owned by GitOps: platform/keycloak/base/create-db-job.yaml
# Do NOT add a postgresql provider here — L3 runs outside the VPC.
```

이 주석은 단순 설명이 아니라 두 제어면의 ownership 계약이다.

```text
RDS instance owner:       Terraform
initial localy DB owner:  Terraform
keycloak DB owner:        GitOps bootstrap Job
Keycloak schema owner:    Keycloak
```

## 5.4 현재 구현의 제한

### Check-then-create race

현재 로직은 다음 두 SQL 사이가 원자적이지 않다.

```text
SELECT 존재 확인
CREATE DATABASE
```

동일 Job 두 개가 동시에 실행되면 둘 다 “없음”을 보고 한쪽이 `already exists` 오류로 실패할 수 있다.

현재는 다음 장치가 동시 실행 가능성을 낮춘다.

- 고정된 Job 이름
- Argo hook lifecycle
- `BeforeHookCreation`
- 단일 Application sync

향후 여러 배포 제어면이 같은 DB를 초기화한다면 PostgreSQL advisory lock 또는 더 강한 serialization을 고려해야 한다.

### Master user 사용

Job은 `postgres` master user로 `CREATE DATABASE`를 실행한다. 필요한 권한이지만 credential 영향 범위가 크다.

향후 개선:

```text
bootstrap 전용 role
  → CREATEDB 권한만 부여
  → Keycloak runtime credential과 분리
```

다만 bootstrap role 자체를 처음 누가 생성할지에 대한 신뢰 root 설계가 필요하다.

### Job 완료와 건강 상태

Database가 존재한다고 Keycloak이 반드시 정상이라는 뜻은 아니다. password, schema migration, realm import, probe를 별도로 검증해야 한다.

## 5.5 배포 전 검증 항목

manifest 검증:

```powershell
kubectl kustomize platform/keycloak/overlays/prod
```

runtime 검증:

```powershell
kubectl -n auth-namespace get job keycloak-create-db
kubectl -n auth-namespace logs job/keycloak-create-db
kubectl -n auth-namespace get pods -l app.kubernetes.io/name=keycloak
```

Database 부재 시 기대 로그:

```text
Creating database keycloak...
Database keycloak created
```

Database 존재 시 기대 로그:

```text
Database keycloak already exists — nothing to do
```

## 5.6 재구축 acceptance criteria

```text
[ ] RDS에는 Terraform이 localy Database 생성
[ ] SecretStore가 Ready
[ ] ExternalSecret이 Ready
[ ] localy-keycloak-secret에 host/password key 존재
[ ] DB Job이 credential을 기다린 뒤 RDS 연결
[ ] keycloak Database가 없으면 생성
[ ] DB Job Complete 1/1
[ ] 재실행 시 already exists로 성공
[ ] Keycloak은 DB Job 이후 rollout
[ ] Keycloak 3개 replica Ready
```

## 5.7 재발 방지 체크리스트

- [ ] 운영 SQL을 개인 shell history에만 남기지 않는다.
- [ ] 추가 Database의 owner를 명시한다.
- [ ] Terraform runner의 data-plane 연결 가능성을 확인한다.
- [ ] `null_resource local-exec`로 네트워크 문제를 숨기지 않는다.
- [ ] initialization은 앱 replica와 분리된 단일 Job에서 실행한다.
- [ ] Job은 현재 상태를 먼저 조회한다.
- [ ] 존재하는 상태를 성공으로 처리한다.
- [ ] sync wave와 runtime readiness polling을 함께 사용한다.
- [ ] Secret 값은 Git과 command line에 기록하지 않는다.
- [ ] bootstrap 실패 시 애플리케이션 rollout을 중단한다.
- [ ] RDS 완전 재생성 테스트로 최초 생성 경로를 검증한다.

---

## 최종 설계 트리

```text
Terraform L3
│
└─ RDS instance: prod-localy-rds
   └─ initial database: localy

Argo CD Keycloak Application
│
├─ wave -1
│  └─ SecretStore/keycloak-store
│
├─ wave 0
│  └─ ExternalSecret/keycloak-secrets
│     └─ Secret/localy-keycloak-secret
│
├─ wave 1
│  └─ Job/keycloak-create-db
│     ├─ credential file 대기
│     ├─ pg_isready 대기
│     ├─ pg_database 조회
│     └─ 없을 때만 CREATE DATABASE keycloak
│
└─ wave 2
   └─ Keycloak workload
      └─ keycloak Database schema 초기화·사용
```

## 한 문장으로 남기는 교훈

**응급처치가 성공한 직후 해야 할 일은 명령을 기록하는 것이 아니라, 같은 결과가 다음 재구축에서도 자동으로 수렴하도록 만드는 것이다.**

