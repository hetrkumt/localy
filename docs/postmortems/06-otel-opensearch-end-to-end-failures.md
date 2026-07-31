# Running은 성공이 아니었다

> OTel Collector에서 OpenSearch 적재까지 설정·인증·매핑 세 계층을 통과한 기록

## 문서 정보

- 사건 시각: 2026-07-31 00:52~01:29 KST
- 환경: OpenTelemetry Collector Contrib 0.98.0, Amazon OpenSearch Service, EKS IRSA
- 배포 형태: OTel Gateway Deployment 2 replicas
- 수신 protocol: OTLP gRPC 4317, OTLP HTTP 4318
- 저장 경로: OTel Gateway → SigV4 → OpenSearch VPC endpoint
- 첫 번째 장애: OpenSearch exporter의 `auth` 설정 위치 오류
- 두 번째 장애: SigV4용 AWS credential provider 부재
- 세 번째 장애: SS4O index template과 OTel document mapping 충돌
- 잘못된 시도: 0.98에 존재하지 않는 `traces_index` 설정
- 최종 검증: OTLP HTTP 200, exporter 오류 없음, OpenSearch 검색 hit 1건
- 남은 위험: OpenSearch 재생성 시 충돌 template 재등장 가능

---

## Executive Summary

Karpenter와 Keycloak 장애를 처리한 뒤 OTel Gateway Pod 2개는 다음 상태였다.

```text
0/1  CrashLoopBackOff
```

최초 로그:

```text
error reading configuration for "opensearch"
invalid keys: auth
```

Collector 0.98의 OpenSearch exporter는 `auth`를 exporter 최상위가 아니라 HTTP client 설정 아래에서 받는다.

잘못된 설정:

```yaml
opensearch:
  http:
    endpoint: https://...
  auth:
    authenticator: sigv4auth
```

수정:

```yaml
opensearch:
  http:
    endpoint: https://...
    auth:
      authenticator: sigv4auth
```

설정 schema를 통과하자 새로운 오류가 나타났다.

```text
extensions::sigv4auth: could not retrieve credential provider
no EC2 IMDS role found
```

Collector는 OpenSearch 요청에 AWS SigV4 서명을 해야 하지만 Pod ServiceAccount에 IAM role이 없었다. Terraform으로 OTel Gateway 전용 IRSA role과 `es:ESHttp*` policy를 만들고 ServiceAccount에 annotation을 추가했다.

```text
monitoring/otel-gateway-opentelemetry-collector
  → prod-eks-otel-gateway-irsa-role
    → es:ESHttp*
      → prod-jaeger-backend domain
```

그 뒤 Pod 2개가 `1/1 Running`이 되고 다음 로그가 나왔다.

```text
Everything is ready. Begin running and processing data.
```

그러나 여기서 성공으로 판단하지 않았다. 테스트 span을 OTLP HTTP endpoint로 전송하자 Collector는 `HTTP 200`을 반환했지만 exporter 로그에는 다음 오류가 발생했다.

```text
Permanent error: mapper_parsing_exception
KeywordFieldMapper cannot be cast to ObjectMapper
```

즉 Collector process와 receiver는 정상이고 OpenSearch 저장만 실패했다.

원인은 OpenSearch의 `ss4o_traces_template`이 기대하는 field type과 OTel exporter가 보낸 document 구조의 충돌이었다. 기존 data stream을 먼저 삭제한 뒤 template을 제거하고, exporter에 `dataset`, `namespace`, `mapping.mode: flatten_attributes`를 설정했다.

```yaml
opensearch:
  dataset: localy
  namespace: traces
  mapping:
    mode: flatten_attributes
```

최종 probe는 다음 단계를 모두 통과했다.

```text
OTLP POST                   HTTP 200
Collector process           Running
Exporter mapper error       없음
OpenSearch query            hit 1
```

이 사건은 관측 파이프라인에서 Pod의 `Running`, health endpoint, 수신 HTTP 200이 end-to-end 성공을 의미하지 않는다는 사실을 보여줬다.

---

# Step 1. 발단 — Argo는 Synced인데 Collector는 죽어 있었다

## 1.1 최초 상태

Argo CD:

```text
NAME           SYNC STATUS   HEALTH STATUS
otel-gateway   Synced        Degraded
```

Pod:

```text
NAME                                                    READY   STATUS
otel-gateway-opentelemetry-collector-6bb7b5b886-...     0/1     CrashLoopBackOff
otel-gateway-opentelemetry-collector-6bb7b5b886-...     0/1     CrashLoopBackOff
```

`Synced`는 Git desired manifest가 적용됐다는 뜻이다. manifest가 애플리케이션 버전에 맞고 프로세스가 정상이라는 뜻은 아니다.

```text
Argo Synced:
  Git == rendered/live desired state

Argo Healthy:
  workload health assessment 통과
```

따라서 `Synced / Degraded`는 “잘못된 설정이 정확히 배포된 상태”일 수도 있다.

## 1.2 첫 번째 오류

```text
Error: failed to get config:
cannot unmarshal the configuration

error reading configuration for "opensearch":
invalid keys: auth
```

Collector는 receiver port를 열기 전에 설정 decode 단계에서 종료했다.

```text
YAML load
  → component config decode 실패
    → service start 이전 종료
      → CrashLoopBackOff
```

이 시점에는 OpenSearch network, IAM, index mapping을 조사할 필요가 없었다. exporter가 요청을 보내는 단계까지 도달하지 못했기 때문이다.

## 1.3 rollout 중 옛 로그와 새 로그가 섞였다

`auth` 위치를 고쳐 Git에 반영한 직후에도 `kubectl logs -l ...`에는 같은 오류가 보였다.

이유는 두 ReplicaSet이 동시에 존재했기 때문이다.

```text
old ReplicaSet:
  잘못된 auth 설정
  오래된 CrashLoop Pod

new ReplicaSet:
  수정된 auth 설정
  새 Pod
```

label selector로 여러 Pod 로그를 한꺼번에 조회하면 rollout 중인 old Pod 오류가 계속 출력될 수 있다.

따라서 다음을 함께 확인해야 했다.

```powershell
kubectl get rs -n monitoring
kubectl get pods -n monitoring --sort-by=.metadata.creationTimestamp
kubectl logs -n monitoring <newest-pod>
```

## 1.4 수정된 Pod에서 새로운 오류가 나타난다

새 Pod는 config decode를 통과했지만 다음 단계에서 종료했다.

```text
extensions::sigv4auth:
could not retrieve credential provider
no EC2 IMDS role found
```

오류가 바뀌었다는 사실은 `http.auth` 수정이 성공했다는 증거였다.

---

# Step 2. 기반 지식 — OTel pipeline은 다섯 개의 독립 구간이다

## 2.1 Collector 구성 요소

OTel Collector trace pipeline:

```text
receiver
  → processor
    → exporter
```

현재 구성:

```yaml
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [opensearch]
```

각 구성 요소는 독립적으로 실패할 수 있다.

```text
receiver:
  OTLP 요청 수신·decode

processor:
  memory 제한과 batch 처리

exporter:
  OpenSearch 연결·인증·document 저장
```

## 2.2 end-to-end 성공 단계

```text
1. Config parse
2. Process start
3. OTLP receive
4. Export authentication/network
5. OpenSearch indexing
6. Query/read-back
```

각 단계의 증거:

```text
Config parse:
  invalid keys 없음

Process start:
  Everything is ready

OTLP receive:
  POST /v1/traces → HTTP 200

Export:
  exporter send failure 없음

Indexing:
  OpenSearch docs.count 증가

Read-back:
  probe trace query hit
```

## 2.3 `Running`의 정확한 의미

Kubernetes `Running`은 컨테이너 process가 현재 실행 중이라는 뜻이다.

다음을 보장하지 않는다.

- receiver에 실제 traffic이 들어오는가
- exporter가 credential을 얻는가
- OpenSearch endpoint에 도달하는가
- index mapping이 document를 허용하는가
- trace가 검색 가능한가

exporter가 비동기로 실패하면서 Collector process는 계속 Running일 수 있다.

## 2.4 AWS SigV4와 credential provider chain

Amazon OpenSearch Service data-plane 요청은 IAM policy만 있다고 끝나지 않는다. 요청마다 AWS Signature Version 4 서명이 필요하다.

```text
HTTP method
path
headers
payload hash
region
service=es
AWS credential
  → signature
```

OTel `sigv4auth` extension:

```yaml
extensions:
  sigv4auth:
    region: ap-northeast-2
    service: es
```

exporter 연결:

```yaml
http:
  auth:
    authenticator: sigv4auth
```

extension은 AWS credential provider chain에서 credential을 찾는다.

Pod에 IRSA가 없으면 node IMDS credential 등을 시도할 수 있다. 이 환경에서는 사용할 node role credential이 없어 다음 오류가 발생했다.

```text
no EC2 IMDS role found
```

## 2.5 IRSA의 신뢰 경로

```text
Kubernetes ServiceAccount
  → projected OIDC token
    → AWS STS AssumeRoleWithWebIdentity
      → temporary IAM credentials
        → SigV4 signed OpenSearch request
```

trust policy의 핵심:

```text
sub =
system:serviceaccount:monitoring:
otel-gateway-opentelemetry-collector

aud =
sts.amazonaws.com
```

namespace나 ServiceAccount 이름이 하나라도 다르면 role assumption은 실패한다.

## 2.6 OpenSearch mapping은 schema 계약이다

OpenSearch는 field마다 type을 저장한다.

```json
{
  "attributes": {
    "type": "keyword"
  }
}
```

이미 `keyword`로 정의된 field path에 object가 들어오면 저장할 수 없다.

```json
{
  "attributes": {
    "probe": "mapping-fix"
  }
}
```

동일 경로가 scalar와 object로 동시에 존재할 수 없기 때문이다.

오류:

```text
KeywordFieldMapper cannot be cast to ObjectMapper
```

## 2.7 SS4O data stream과 template

OTel OpenSearch exporter 0.98은 trace를 SS4O naming과 mapping model에 맞춰 저장한다.

관찰된 기본 대상:

```text
ss4o_traces-default-namespace
```

OpenSearch에는 다음 composable index template이 있었다.

```text
ss4o_traces_template
pattern: ss4o_traces-*-*
```

data stream이 이 template을 사용하고 있었기 때문에 template만 먼저 삭제하려 하자 OpenSearch가 거부했다.

```text
unable to remove composable templates
[ss4o_traces_template]
as they are in use by a data stream
[ss4o_traces-default-namespace]
```

삭제 순서도 dependency를 따라야 했다.

```text
data stream 삭제
  → template 삭제
```

---

# Step 3. CCTV 추적 — trace 한 건이 어디에서 사라졌는가

## 3.1 Collector가 잘못된 YAML을 읽는다

초기 설정:

```yaml
exporters:
  opensearch:
    http:
      endpoint: https://opensearch.prod.localy.internal:443
      tls:
        insecure: false
    auth:
      authenticator: sigv4auth
```

Collector 0.98 config decoder는 `opensearch.auth`를 알지 못했다.

```text
invalid keys: auth
```

process는 pipeline을 구성하지 못하고 종료했다.

## 3.2 `auth`를 HTTP client 아래로 옮긴다

```yaml
exporters:
  opensearch:
    http:
      endpoint: https://...
      auth:
        authenticator: sigv4auth
```

이제 YAML schema는 통과했다.

## 3.3 sigv4auth가 credential을 찾는다

extension은 설정상 활성화됐다.

```yaml
service:
  extensions:
    - health_check
    - sigv4auth
```

하지만 Pod ServiceAccount에 role annotation이 없었다.

```text
WebIdentity credential 없음
  → fallback provider 탐색
    → IMDS role 없음
      → credential provider 생성 실패
```

Collector는 다시 종료했다.

## 3.4 OTel 전용 IRSA를 만든다

Terraform policy:

```hcl
Action = [
  "es:ESHttp*"
]

Resource = [
  aws_opensearch_domain.jaeger_backend.arn,
  "${aws_opensearch_domain.jaeger_backend.arn}/*"
]
```

role:

```hcl
resource "aws_iam_role" "otel_gateway" {
  name = "prod-eks-otel-gateway-irsa-role"
}
```

ServiceAccount:

```yaml
serviceAccount:
  create: true
  annotations:
    eks.amazonaws.com/role-arn: >-
      arn:aws:iam::533003975005:
      role/prod-eks-otel-gateway-irsa-role
```

실제 설정은 한 줄 ARN이며 위 표기는 설명을 위해 줄을 나눈 것이다.

## 3.5 실제 OpenSearch VPC endpoint로 맞춘다

기존 설정:

```text
https://opensearch.prod.localy.internal:443
```

실제 domain endpoint:

```text
https://vpc-prod-jaeger-backend-...
.ap-northeast-2.es.amazonaws.com:443
```

private DNS alias가 실제로 구성됐는지 불확실한 이름 대신 AWS가 반환한 VPC endpoint를 사용했다.

## 3.6 Pod가 Running으로 전환한다

IRSA와 endpoint를 적용하고 rollout한 결과:

```text
2개 Pod 모두 1/1 Running
Argo Synced / Healthy
Everything is ready. Begin running and processing data.
```

이 시점에 configuration과 credential initialization은 통과했다.

하지만 아직 실제 trace를 보내지 않았기 때문에 exporter의 document 저장 성공은 증명되지 않았다.

## 3.7 OTLP probe를 전송한다

임시 Job에서 Collector service의 HTTP receiver로 test span을 보냈다.

```text
POST
http://otel-gateway-opentelemetry-collector
.monitoring.svc.cluster.local:4318/v1/traces
```

probe 식별자:

```text
service.name = localy-otel-probe
span.name    = localy-otel-probe-span
probe        = step2-verify
```

receiver 응답:

```text
HTTP_CODE=200
```

여기서 증명된 것:

```text
Service DNS/port 정상
OTLP HTTP receiver 정상
JSON trace payload decode 정상
Collector가 요청 수락
```

증명되지 않은 것:

```text
OpenSearch indexing 성공
```

## 3.8 batch processor가 trace를 exporter로 보낸다

Collector는 수신한 span을 batch processor를 거쳐 OpenSearch exporter로 전달했다.

```yaml
processors:
  batch:
    send_batch_size: 8192
    timeout: 5s
```

exporter는 SigV4 요청을 만들고 OpenSearch에 document를 보냈다.

## 3.9 OpenSearch가 mapping 충돌로 거부한다

Collector log:

```text
Sender failed
not retryable error
Permanent error:
mapper_parsing_exception

KeywordFieldMapper cannot be cast to ObjectMapper
```

`not retryable`와 `Permanent error`는 같은 payload를 다시 보내도 성공하지 않는 schema 문제임을 나타냈다.

```text
일시적 network timeout:
  retry 가치 있음

mapping conflict:
  payload/template 변경 전에는 retry해도 실패
```

## 3.10 data stream과 template을 조사한다

OpenSearch:

```text
.ds-ss4o_traces-default-namespace-000001
ss4o_traces_template [ss4o_traces-*-*]
```

template 삭제를 먼저 시도했지만 data stream이 사용 중이라 HTTP 400으로 거부됐다.

의존 순서가 확인됐다.

## 3.11 data stream과 template을 순서대로 제거한다

```text
DELETE /_data_stream/ss4o_traces-default-namespace
→ 200 {"acknowledged":true}

DELETE /_index_template/ss4o_traces_template
→ 200 {"acknowledged":true}
```

이 작업은 기존 trace data를 삭제하는 파괴적 작업이다. 당시 새로 구축한 환경이고 검증용 데이터뿐이라는 전제에서 수행했다.

## 3.12 exporter mapping을 평탄화한다

```yaml
opensearch:
  dataset: localy
  namespace: traces
  mapping:
    mode: flatten_attributes
```

`flatten_attributes`는 OTel attributes의 중첩 구조가 OpenSearch field mapping과 충돌할 가능성을 줄인다.

## 3.13 다시 probe하고 OpenSearch에서 조회한다

재전송:

```text
HTTP_CODE=200
```

Collector:

```text
Everything is ready
Sender failed 없음
mapper_parsing_exception 없음
```

OpenSearch query:

```text
service.name = localy-otel-probe
hits.total.value = 1
```

장애 당시 실제 read-back은 재생성된 `ss4o_traces-default-namespace`에서 확인됐다. 이후 Git desired config에는 명시적 `dataset: localy`, `namespace: traces`가 추가됐다. 따라서 향후 stream/index 이름은 적용된 exporter 버전과 live config를 기준으로 다시 검증해야 한다.

---

# Step 4. 삽질과 해결 — 지원하지 않는 옵션과 live patch가 조사를 지연시켰다

## 4.1 잘못된 첫 시도: `traces_index`

mapping 충돌을 피하기 위해 index 이름을 바꾸려 했다.

```yaml
opensearch:
  traces_index: otel-traces-localy
```

의도:

```text
ss4o template pattern을 피하는 새 index 사용
```

그러나 Collector Contrib 0.98의 OpenSearch exporter config에는 이 field가 없었다.

문제:

- 다른 exporter/버전의 옵션을 혼동
- 실행 image 버전의 config schema를 먼저 확인하지 않음
- 이름 변경이 실제 live target을 바꿨다고 성급히 가정

결과적으로 exporter는 계속 기본 SS4O 경로를 사용했고 mapping 오류도 지속됐다.

## 4.2 버전의 source code가 최종 근거였다

문서와 검색 결과만으로 옵션을 추측하지 않고 실제 사용 중인 tag의 source를 확인했다.

```text
opentelemetry-collector-contrib
tag: v0.98.0
exporter/opensearchexporter/config.go
```

여기서 `traces_index`가 지원되지 않음을 확인하고 설정에서 제거했다.

원칙:

```text
latest documentation
≠
현재 실행 버전의 schema
```

## 4.3 live ConfigMap patch가 Argo self-heal로 되돌아갔다

빠른 검증을 위해 chart-generated ConfigMap을 직접 수정했다.

그러나 Argo CD self-heal이 Git desired state와 다른 변경을 다시 되돌렸다.

```text
kubectl apply live patch
  → 잠시 적용
    → Argo diff 감지
      → Git 값으로 복원
```

따라서 `traces_index`가 live에 남아 있는지 반복 확인해야 했다.

이 현상은 Argo가 잘못된 것이 아니다. self-heal이 설계대로 동작했다. 문제는 Git 변경과 live 실험을 동시에 진행하면서 어느 설정이 현재 실행 중인지 불명확해진 데 있었다.

## 4.4 ConfigMap 재작성 과정에서 YAML이 손상됐다

PowerShell 문자열 치환과 `kubectl create configmap --from-file`을 반복하는 과정에서 relay config가 예상한 key/줄바꿈 형태와 달라졌다.

이 때문에 다음을 다시 확인해야 했다.

```text
ConfigMap data key 이름
Deployment volume mount key
relay 내용 줄바꿈
실제 Pod가 읽는 파일
```

구조화된 YAML을 문자열 정규식으로 부분 수정하는 것은 indentation과 newline에 취약했다.

## 4.5 실제 config source가 무엇인지 확인한다

repository에는 두 설정 표현이 있었다.

```text
values-prod.yaml의 config
standalone configmap.yaml의 relay.yaml
```

Helm chart가 실제 Deployment에 mount한 ConfigMap은 chart values에서 생성된 resource였다. 별도 `otel-collector-config`가 존재하더라도 Pod가 mount하지 않으면 runtime에 영향을 주지 않는다.

따라서 검증은 repository 파일만 보지 않고 다음을 따라가야 한다.

```text
Deployment volume
  → ConfigMap name
    → data key
      → mounted file
        → process --config argument
```

두 설정 복사본은 현재 같은 내용을 유지하고 있지만 drift 위험이 있다. 장기적으로 하나를 SSOT로 통합해야 한다.

## 4.6 template 삭제 순서의 실패

처음 template부터 삭제하려 하자 OpenSearch가 거부했다.

```text
template is in use by data stream
```

OpenSearch resource dependency:

```text
index template
  → data stream 생성 규칙
    → backing indices
```

삭제:

```text
data stream
  → template
```

생성 순서와 삭제 순서는 대체로 반대라는 인프라 원칙이 여기에도 적용됐다.

## 4.7 파괴적 삭제를 일반 해결책으로 사용하면 안 된다

이번에는 검증 데이터만 있는 재구축 환경이라 data stream 삭제를 허용했다.

실제 운영 trace가 있다면 다음 절차가 필요하다.

```text
1. 새 template/version 설계
2. 새 index/data stream 생성
3. exporter write target 전환
4. 필요 시 reindex
5. query/retention 검증
6. 이전 stream 폐기
```

운영에서 `DELETE /_data_stream/...`를 즉시 실행하면 관측 이력을 잃는다.

## 4.8 응급 수정과 Git 고정을 분리한다

IRSA annotation을 live ServiceAccount에 먼저 적용해 복구한 뒤 Helm values에도 추가했다.

```text
live patch:
  즉시 서비스 복구

Git commit:
  Argo self-heal 이후에도 유지
```

검증:

```text
Git main == origin/main
Argo Synced / Healthy
ServiceAccount IRSA annotation 존재
Pod 2/2 Running
```

---

# Step 5. 넥스트 스텝 — 관측 파이프라인은 관측 대상보다 더 엄격히 검증하라

## 5.1 가장 중요한 진단 원칙

> Collector가 Running이라는 사실은 telemetry를 받고 있다는 뜻도, 저장하고 있다는 뜻도 아니다.

검증 사다리:

```text
Config valid
  → Process Running
    → Receiver accepts
      → Processor handles
        → Exporter sends
          → Backend indexes
            → User can query
```

## 5.2 단계별 장애 분류

### Config parse

```text
invalid keys
cannot unmarshal
unknown component
```

조사:

```text
실행 버전 schema
YAML nesting
extension 등록
pipeline 참조
```

### Credential

```text
could not retrieve credential provider
AssumeRoleWithWebIdentity
AccessDenied
```

조사:

```text
ServiceAccount annotation
OIDC issuer
trust policy sub/aud
IAM policy resource/action
```

### Network/TLS

```text
no such host
timeout
x509
connection refused
```

조사:

```text
VPC endpoint
DNS
security group
certificate
```

### Backend schema

```text
mapper_parsing_exception
illegal_argument_exception
permanent error
```

조사:

```text
index template
data stream
field mapping
exporter mapping mode
```

## 5.3 자동 smoke test가 필요하다

재배포 후 다음 probe를 자동화할 수 있다.

```text
1. 고유 trace ID로 OTLP span 전송
2. HTTP 200 확인
3. exporter failure metric이 증가하지 않는지 확인
4. OpenSearch에서 trace ID 조회
5. 일정 시간 안에 hit=1 확인
```

HTTP 200만 확인하면 receiver까지만 테스트한 것이다.

## 5.4 유용한 Collector metric

버전에 따라 metric 이름은 달라질 수 있지만 다음 범주를 감시한다.

```text
receiver accepted spans
receiver refused spans
exporter sent spans
exporter failed spans
queue size/capacity
send failed requests
```

알람 예:

```text
accepted spans 증가
AND
sent spans 증가 없음
OR
failed spans 증가
```

이는 “Collector는 traffic을 받고 있지만 backend로 보내지 못함”을 감지한다.

## 5.5 least privilege를 더 좁힐 수 있다

현재 policy:

```hcl
Action = ["es:ESHttp*"]
```

초기 복구와 관리 probe에는 편리하지만 runtime exporter에는 넓을 수 있다.

향후 분리:

```text
OTel runtime role:
  POST/PUT 등 indexing에 필요한 최소 ESHttp action

운영 migration role:
  template 조회·삭제·관리 권한
```

Collector ServiceAccount로 template과 data stream 삭제 Job을 실행한 것은 incident 대응을 위한 임시 권한 활용이었다. 정상 운영에서는 data writer와 index administrator를 분리하는 것이 더 안전하다.

## 5.6 OpenSearch template을 코드로 관리한다

현재 해결은 live domain의 충돌 template을 제거했다. 도메인을 다시 만들면 기본 `ss4o_traces_template`이 다시 생길 수 있다.

재발 방지 선택지:

- 호환되는 custom index template을 배포
- OpenSearch exporter와 domain plugin의 호환 버전 고정
- 초기화 Job/runbook으로 template 상태 검증
- 별도 write target과 versioned template 사용
- integration test로 representative attributes indexing

단순 삭제 명령만 자동화하기 전에 해당 template이 다른 SS4O consumer에게 필요한지 확인해야 한다.

## 5.7 config SSOT를 하나로 줄인다

현재:

```text
values-prod.yaml config
configmap.yaml relay.yaml
```

둘 중 실제 workload가 사용하는 source 하나를 선택해야 한다.

추천 방향:

```text
Helm chart를 계속 사용:
  values-prod.yaml만 SSOT

직접 ConfigMap을 사용:
  chart config 생성을 끄고
  explicit ConfigMap mount
```

“두 파일을 항상 같이 고친다”는 규칙은 시간이 지나면 깨지기 쉽다.

## 5.8 배포 acceptance criteria

```text
[ ] Collector config validation 통과
[ ] Pod 2/2 Ready
[ ] Service OTLP ports 존재
[ ] IRSA role assumption 성공
[ ] OpenSearch endpoint DNS/TLS 연결 성공
[ ] test span POST HTTP 200
[ ] exporter failure 없음
[ ] OpenSearch index docs.count 증가
[ ] trace ID read-back 성공
[ ] Argo Synced / Healthy
[ ] Git과 live ConfigMap 일치
```

## 5.9 재발 방지 체크리스트

- [ ] 문서는 실행 중인 Collector 버전에 맞춰 확인한다.
- [ ] unknown config key를 다른 버전 옵션으로 우회하지 않는다.
- [ ] rollout 중 old/new ReplicaSet 로그를 분리한다.
- [ ] Pod Running에서 검증을 끝내지 않는다.
- [ ] OTLP HTTP 200을 저장 성공으로 해석하지 않는다.
- [ ] OTel 전용 IRSA와 최소 권한을 사용한다.
- [ ] OpenSearch VPC endpoint를 실제 AWS output과 비교한다.
- [ ] template과 data stream dependency를 확인한다.
- [ ] mapping 변경 전 기존 데이터 보존 계획을 세운다.
- [ ] 고유 probe span을 backend에서 read-back한다.
- [ ] Collector exporter failure metric에 알람을 건다.
- [ ] chart config와 standalone ConfigMap을 하나로 통합한다.

---

## 최종 원인 트리

```text
OTel trace가 OpenSearch에 저장되지 않음
│
├─ 장애 1: Collector 기동 실패
│  └─ opensearch exporter auth 위치 오류
│     ├─ 잘못: exporters.opensearch.auth
│     └─ 수정: exporters.opensearch.http.auth
│
├─ 장애 2: SigV4 credential 초기화 실패
│  └─ ServiceAccount에 IRSA 없음
│     ├─ no EC2 IMDS role found
│     └─ OTel 전용 role + es:ESHttp* policy 연결
│
├─ 장애 3: OpenSearch indexing 실패
│  └─ SS4O template과 OTel document field type 충돌
│     └─ KeywordFieldMapper cannot be cast to ObjectMapper
│
├─ 잘못된 시도
│  ├─ 0.98에 없는 traces_index 설정
│  ├─ Argo self-heal과 경쟁한 live ConfigMap patch
│  └─ data stream보다 template을 먼저 삭제
│
└─ 최종 해결
   ├─ data stream → template 순서로 제거
   ├─ dataset / namespace 명시
   ├─ mapping.mode=flatten_attributes
   ├─ probe HTTP 200 확인
   └─ OpenSearch query hit 1 확인
```

## 한 문장으로 남기는 교훈

**관측 파이프라인의 성공은 Collector가 살아 있다는 사실이 아니라, 보낸 trace를 저장소에서 다시 찾을 수 있다는 사실로 증명해야 한다.**

