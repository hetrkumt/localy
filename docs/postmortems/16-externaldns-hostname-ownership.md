# 같은 도메인을 두 ALB가 주장했다

> ExternalDNS가 정상 reconcile하면서도 `feifo.click`을 internal ALB로 바꾼 hostname 소유권 충돌

## 문서 정보

- 사건 시각: 2026-07-31 22:40~22:46 KST
- 환경: ExternalDNS, Amazon Route 53, AWS Load Balancer Controller, public/internal ALB
- 선행 사건: 회고 15에서 external·internal ALB provisioning 복구
- 영향 hostname: `feifo.click`
- 최초 증상:
  - `ingress-core`는 `Synced / Healthy`
  - external·internal ALB 모두 `Active`
  - 그러나 Route 53 `feifo.click` Alias가 internal ALB를 가리킴
- 직접 원인: external Ingress와 internal Ingress가 같은 `spec.rules[].host` 사용
- 구조적 원인: DNS hostname의 authoritative source가 하나라는 invariant가 없었음
- 악화 요인:
  - ExternalDNS `source=ingress`
  - 같은 controller·같은 `txtOwnerId`
  - `policy=upsert-only`
  - public/private zone 경계 미분리
- 1차 조치:
  - external Ingress에 명시적 hostname annotation
  - internal Ingress에 `exclude=true`
- 최종 조치:
  - internal host를 `internal.feifo.click`로 분리
  - 중복 exclude annotation 제거
- 결과:
  - `feifo.click` → internet-facing external ALB
  - HTTPS `/` → Keycloak OAuth redirect `302`
  - `internal.feifo.click` → internal ALB
  - `ingress-core` `Synced / Healthy`
- 관련 commit:
  - `eeafad4` — public hostname을 external ALB에만 publish 시도
  - `056e6d2` — internal hostname 분리
  - `57f560a` — 완료 ledger 및 redundant exclude 제거
- 남은 부채:
  - internal hostname이 public hosted zone에 게시될 수 있음
  - public/private ExternalDNS controller와 hosted zone 분리 필요
  - `upsert-only` 때문에 source 제거 후 stale record 자동 삭제가 보장되지 않음

---

## Executive Summary

회고 15에서 세 Ingress가 생성되고 두 ALB가 준비됐다.

```text
external ALB:
  scheme=internet-facing
  group=localy-external-alb

internal ALB:
  scheme=internal
  group=localy-internal-alb
```

Argo CD도 성공을 표시했다.

```text
ingress-core:
  Synced
  Healthy
```

그런데 공개 도메인 `feifo.click`을 조회하자 internet-facing ALB가 아니라 internal ALB가 나왔다.

```text
Route 53:
  feifo.click A Alias
    → internal ALB DNS name
```

원인은 두 Ingress의 hostname이 같았기 때문이다.

external edge:

```yaml
spec:
  rules:
    - host: feifo.click
```

internal edge:

```yaml
spec:
  rules:
    - host: feifo.click
```

ExternalDNS는 `source=ingress`로 설정돼 있었다. 따라서 두 객체 모두 유효한 DNS source였다.

```text
external Ingress:
  feifo.click → external ALB

internal Ingress:
  feifo.click → internal ALB
```

Route 53의 simple Alias A record 하나는 동시에 두 개의 상충하는 ALB identity를 표현할 수 없다. 같은 reconcile 주체가 같은 hostname에 서로 다른 target을 제안했고, 관측 당시 internal ALB target의 UPSERT가 최종 레코드에 반영됐다.

이것은 ExternalDNS가 고장 난 것이 아니다.

```text
입력:
  같은 hostname에 target 두 개

ExternalDNS:
  입력을 Route 53 desired change로 변환

문제:
  어떤 Ingress가 hostname을 소유하는지 선언되지 않음
```

처음에는 internal Ingress에 `external-dns.alpha.kubernetes.io/exclude: "true"`를 추가하고 external Ingress에 hostname annotation을 명시했다.

그러나 record가 즉시 안정적으로 external ALB로 수렴하지 않았다. `upsert-only` 정책, 기존 record, reconcile 주기와 duplicate source 상태가 결합된 상황에서 exclude만으로는 소유권 모델이 충분히 명확하지 않았다.

최종적으로 internal Ingress host를 분리했다.

```text
public:
  feifo.click

internal:
  internal.feifo.click
```

이제 같은 DNS name을 서로 다른 ALB가 주장하지 않는다.

핵심 교훈:

> DNS 자동화에서 중요한 것은 어떤 값을 쓸지가 아니라 누가 그 hostname을 쓸 권한을 갖는지 먼저 유일하게 정하는 것이다.

---

# Step 1. ALB가 생성됐다는 것과 사용자가 올바른 ALB로 간다는 것은 다르다

## 1.1 회고 15의 완료 조건

```text
Ingress object 생성
AWS LBC reconcile 성공
external ALB 생성
internal ALB 생성
Ingress status.address 채워짐
Argo Synced/Healthy
```

여기까지는 Kubernetes와 ALB provisioning의 완료 조건이다.

## 1.2 사용자 경로의 완료 조건

```text
사용자
  → DNS lookup
    → Route 53 record
      → internet-facing ALB
        → listener rule
          → target group
            → Service/Pod
```

ALB가 존재해도 DNS가 다른 ALB를 가리키면 사용자는 올바른 data plane에 도달하지 못한다.

## 1.3 검증 결과

Route 53 record set을 직접 조회했다.

```text
feifo.click.
  Type=A
  AliasTarget=<internal-alb-dns>
```

Kubernetes Ingress status에는 external·internal ALB address가 모두 정상적으로 있었다.

따라서 문제는 ALB 생성이 아니라 DNS target 선택이었다.

---

# Step 2. ExternalDNS는 무엇을 하는가

## 2.1 source를 감시한다

현재 values:

```yaml
provider: "aws"
source: "ingress"
policy: "upsert-only"
txtOwnerId: "prod-platform-eks"

domainFilters:
  - "feifo.click"
```

ExternalDNS는 Ingress object를 읽어 DNS endpoint 후보를 만든다.

## 2.2 Ingress source에서 hostname을 얻는 방법

일반적으로 다음이 source가 된다.

```text
spec.rules[].host
external-dns.alpha.kubernetes.io/hostname
Ingress status.loadBalancer target
```

개념:

```text
Ingress:
  host=feifo.click
  status.address=external-alb.example.amazonaws.com

ExternalDNS endpoint:
  feifo.click
    → external-alb.example.amazonaws.com
```

## 2.3 Route 53에 반영

AWS provider는 endpoint를 Route 53 record change로 변환한다.

```text
A/AAAA Alias
또는
CNAME
```

ALB에는 보통 Alias target이 사용된다.

## 2.4 반복 reconcile

ExternalDNS는 한 번만 쓰고 끝나는 script가 아니다.

```text
Ingress watch/list
  → desired endpoints 계산
    → Route 53 현재 상태 비교
      → UPSERT
        → 다음 interval에 반복
```

따라서 사람이 Route 53 record를 수동으로 external ALB로 고쳐도 source 충돌이 남아 있으면 다음 reconcile에서 다시 바뀔 수 있다.

---

# Step 3. 두 종류의 중복 source가 있었다

## 3.1 benign duplicate

두 external Ingress가 `feifo.click`을 사용했다.

```text
edge external Ingress:
  host=feifo.click
  group=localy-external-alb

Keycloak external Ingress:
  host=feifo.click
  path=/auth
  group=localy-external-alb
```

둘은 같은 ALB group에 속한다.

```text
target:
  동일 external ALB
```

hostname source는 중복이지만 target이 같으므로 충돌 결과는 없다.

```text
feifo.click → external ALB
feifo.click → external ALB
```

## 3.2 conflicting duplicate

internal edge Ingress도 같은 host를 사용했다.

```text
host=feifo.click
group=localy-internal-alb
scheme=internal
```

target:

```text
internal ALB
```

전체 후보:

```text
feifo.click → external ALB
feifo.click → external ALB
feifo.click → internal ALB
```

세 번째 source가 hostname ownership을 깨뜨렸다.

## 3.3 핵심 invariant

같은 DNS view와 record type에서:

```text
hostname 하나
  → authoritative target 집합 하나
```

blue/green, weighted routing처럼 의도적으로 여러 target을 쓰는 경우에도 routing policy가 명시돼야 한다.

이번에는 그런 정책이 없었다.

---

# Step 4. 왜 internal ALB가 public Route 53에 나타났는가

## 4.1 ALB scheme은 DNS publication policy가 아니다

Ingress annotation:

```yaml
alb.ingress.kubernetes.io/scheme: internal
```

이 설정은 AWS Load Balancer Controller에게 internal ALB를 만들라고 지시한다.

ExternalDNS에게:

```text
이 hostname을 public hosted zone에 쓰지 마라
```

라고 지시하는 것은 아니다.

## 4.2 ExternalDNS가 보는 것

```text
Ingress host:
  feifo.click

Ingress status:
  internal ALB hostname

domain filter:
  feifo.click 허용
```

따라서 source로 유효하다.

## 4.3 internal ALB DNS name은 public DNS에서 해석될 수 있다

AWS internal ALB의 DNS name이 공개 DNS 질의에서 IP를 반환하는 방식과 실제 접근 가능성은 별개다. 일반적으로 target은 private address이며 인터넷에서 접근할 수 없다.

즉 public hosted zone에 Alias를 만들 수 있다고 public data plane이 되는 것은 아니다.

```text
DNS record 존재
≠ internet reachability
```

이 상태는 사용자에게 timeout을 만들고 internal resource naming을 외부에 노출할 수도 있다.

---

# Step 5. `txtOwnerId`가 왜 막지 못했는가

## 5.1 TXT registry의 목적

ExternalDNS는 TXT registry를 사용해 record ownership을 표시할 수 있다.

현재 owner:

```yaml
txtOwnerId: "prod-platform-eks"
```

의도:

```text
ExternalDNS deployment A:
  owner-id=prod-platform-eks

ExternalDNS deployment B:
  owner-id=another-cluster

서로의 record를 함부로 관리하지 않게 함
```

## 5.2 같은 controller 내부 충돌

이번 두 Ingress는 같은 ExternalDNS deployment가 읽었다.

```text
external source owner:
  prod-platform-eks

internal source owner:
  prod-platform-eks
```

TXT ownership 관점에서는 둘 다 같은 주인이다.

```text
TXT registry:
  다른 controller/cluster와의 충돌 방지

이번 문제:
  같은 controller 입력 집합 안의 source 충돌
```

따라서 `txtOwnerId`는 해결책이 아니었다.

## 5.3 owner ID를 hostname owner와 혼동하면 안 된다

```text
txtOwnerId:
  이 ExternalDNS instance가 record를 관리할 수 있는가

Ingress hostname ownership:
  이 여러 source 중 누가 target을 결정하는가
```

서로 다른 계층이다.

---

# Step 6. “마지막 writer”라는 표현의 정확한 의미

## 6.1 관측 결과

Route 53의 simple Alias record는 internal ALB를 가리켰다.

ExternalDNS reconcile 과정에서 internal target에 대한 UPSERT가 최종 상태에 반영된 것으로 관측됐다.

## 6.2 순서에 의존하면 안 된다

다음에 따라 결과가 달라질 수 있다.

```text
source list 순서
endpoint deduplication 방식
controller version
provider change plan 생성
watch/reconcile timing
Ingress status 갱신 시각
```

따라서:

```text
external Ingress가 먼저 만들어졌으니 external이 이긴다
group.order가 낮으니 DNS도 우선한다
```

같은 가정은 안전하지 않다.

## 6.3 ALB group order는 DNS 우선순위가 아니다

```yaml
alb.ingress.kubernetes.io/group.order: "10"
```

이 값은 ALB listener rule merge/order에 사용된다.

ExternalDNS source ownership 우선순위가 아니다.

```text
ALB listener routing:
  group.order

DNS record target:
  ExternalDNS endpoint reconcile
```

서로 다른 controller의 계약이다.

---

# Step 7. 1차 해결 — annotation으로 external만 publish

## 7.1 external hostname 명시

external edge Ingress:

```yaml
external-dns.alpha.kubernetes.io/hostname: "feifo.click"
```

의도를 분명히 했다.

```text
이 external Ingress가 feifo.click을 publish한다
```

## 7.2 internal exclude

internal Ingress:

```yaml
external-dns.alpha.kubernetes.io/exclude: "true"
```

의도:

```text
이 Ingress는 ExternalDNS source에서 제외
```

commit:

```text
eeafad4
fix(ingress-core): publish feifo.click to external ALB only
```

## 7.3 왜 이것만으로 종료하지 않았는가

관측상 Route 53 record가 즉시 external target으로 안정적으로 수렴하지 않았다.

가능한 영향:

```text
reconcile interval
기존 desired/cache 상태
이미 존재하는 Route 53 record
upsert-only policy
동일 host가 spec에 여전히 존재
```

여기서 정확한 내부 dedup 순서를 추측하는 대신 source model 자체를 단순화했다.

---

# Step 8. `upsert-only`가 cleanup을 보장하지 않는다

## 8.1 현재 policy

```yaml
policy: "upsert-only"
```

ExternalDNS는 필요한 record를 생성하거나 갱신한다.

그러나 source에서 사라진 record를 자동 삭제하는 데 제한이 있다.

```text
sync policy:
  create/update/delete 가능

upsert-only:
  create/update 중심
  stale delete를 하지 않음
```

## 8.2 exclude의 한계

internal source를 exclude하면 앞으로 desired endpoint에서 빠질 수 있다.

하지만 기존 Route 53 record가 자동 삭제·교체되는지는 다른 source가 같은 hostname을 계속 제안하는지와 policy에 달려 있다.

이번에는 external source가 같은 `feifo.click`을 계속 제안했기 때문에 다음 UPSERT로 external target에 수렴할 수 있었다.

그러나 hostname 자체를 완전히 제거했다면 stale record가 남을 수 있다.

## 8.3 안전한 운영

`upsert-only`를 유지하려면:

```text
source 제거/rename 시
  → Route 53 stale record inventory
  → TXT ownership 확인
  → 승인된 수동 삭제 또는 cleanup Job
```

가 필요하다.

---

# Step 9. 최종 해결 — hostname을 분리하다

## 9.1 변경

internal edge:

```yaml
spec:
  rules:
    - host: "internal.feifo.click"
```

commit:

```text
056e6d2
fix(ingress-core): use internal.feifo.click for private ALB host
```

## 9.2 소유권

변경 전:

```text
feifo.click
  ├─ external edge Ingress
  ├─ external Keycloak Ingress
  └─ internal edge Ingress
```

변경 후:

```text
feifo.click
  ├─ external edge Ingress
  └─ external Keycloak Ingress
      └─ same external ALB group

internal.feifo.click
  └─ internal edge Ingress
      └─ internal ALB group
```

이제 target이 상충하지 않는다.

## 9.3 exclude 제거

hostname이 분리된 뒤 internal Ingress의 exclude annotation은 제거했다.

commit:

```text
57f560a
docs: mark backlog #7 ingress-core complete in OutOfSync ledger
```

이 결정은 internal hostname도 ExternalDNS가 publish하도록 허용한다.

하지만 어느 hosted zone에 publish해야 하는지에 대한 public/private 경계는 아직 부족하다.

---

# Step 10. 검증

## 10.1 Kubernetes source

```text
external edge:
  host=feifo.click
  address=external ALB

external Keycloak:
  host=feifo.click
  address=external ALB

internal edge:
  host=internal.feifo.click
  address=internal ALB
```

## 10.2 Route 53

확인 대상:

```text
feifo.click A Alias
  → internet-facing external ALB

internal.feifo.click A Alias
  → internal ALB
```

## 10.3 HTTPS smoke

```text
https://feifo.click/
  → HTTP 302
  → /oauth2/authorization/keycloak
```

이 결과는 다음을 함께 검증한다.

```text
public DNS
TLS listener
ACM certificate
external ALB
listener rule
edge-service
OAuth entry path
```

## 10.4 Argo CD

```text
ingress-core:
  Synced
  Healthy
```

---

# Step 11. 현재 해결의 한계 — internal hostname이 public zone에 있다

## 11.1 domain filter만 있다

```yaml
domainFilters:
  - "feifo.click"
```

이는 `feifo.click` 하위 이름만 허용한다.

public hosted zone과 private hosted zone을 구분하지 않는다.

## 11.2 단일 ExternalDNS deployment

현재 source는 external·internal Ingress를 모두 본다.

```text
source=ingress
cluster 전체 Ingress
```

internal Ingress에서 exclude를 제거했으므로 `internal.feifo.click`도 현재 controller의 대상이 된다.

## 11.3 가능한 결과

public hosted zone만 선택되면:

```text
internal.feifo.click
  → public Route 53 Alias
  → internal ALB
```

DNS name은 외부에서 보이지만 data plane은 private이다.

이는 기능적으로 VPC 내부 client가 public resolver 경로를 통해 record를 얻을 수는 있어도 다음 문제가 있다.

```text
내부 topology 이름 노출
public/private DNS 의도 불명확
외부 사용자는 resolve 후 timeout
split-horizon 정책 부재
```

## 11.4 권장 구조

```text
public ExternalDNS:
  public hosted zone
  internet-facing Ingress만
  aws-zone-type=public
  annotation/ingressClass filter
  owner-id=prod-public

private ExternalDNS:
  private hosted zone
  internal Ingress만
  aws-zone-type=private
  annotation filter
  owner-id=prod-private
```

또는 internal Ingress를 ExternalDNS에서 exclude하고 private record를 Terraform으로 관리할 수 있다.

---

# Step 12. 더 강한 hostname ownership 정책

## 12.1 명시적 annotation

모든 공개 Ingress:

```yaml
external-dns.alpha.kubernetes.io/hostname: "feifo.click"
```

모든 internal Ingress:

```yaml
external-dns.alpha.kubernetes.io/hostname: "internal.feifo.click"
```

spec host에서 암묵적으로 추론하는 것보다 의도가 명확하다.

## 12.2 source filter

label/annotation으로 scope를 분리한다.

개념:

```yaml
metadata:
  annotations:
    localy.io/dns-scope: public
```

ExternalDNS args:

```text
--annotation-filter=localy.io/dns-scope=public
```

private controller:

```text
--annotation-filter=localy.io/dns-scope=private
```

실제 ExternalDNS가 지원하는 filter 문법과 chart version을 확인해 적용해야 한다.

## 12.3 admission policy

Kyverno/Gatekeeper로 다음을 차단할 수 있다.

```text
scheme=internal Ingress가 public hostname 사용
scheme=internet-facing Ingress가 internal.* hostname 사용
같은 hostname을 서로 다른 ALB group이 사용
DNS scope annotation 누락
```

마지막 조건은 cluster 전체 uniqueness 조회가 필요해 일반적인 단일-resource validation보다 복잡하다.

CI에서 rendered manifests를 집계하는 방식이 더 단순할 수 있다.

---

# Step 13. CI에서 충돌을 찾는 방법

## 13.1 수집

rendered Ingress마다 다음 tuple을 만든다.

```text
hostname
scheme
group.name
namespace/name
dns-scope
```

예:

```text
feifo.click
internet-facing
localy-external-alb
edge-service/localy-external-alb-edge
public
```

## 13.2 허용

같은 hostname을 여러 Ingress가 사용해도 다음이 모두 같으면 허용할 수 있다.

```text
scheme
ALB group
DNS scope
expected target identity
```

Keycloak path와 edge root path가 같은 external ALB를 공유하는 현재 구조가 이에 해당한다.

## 13.3 거부

```text
같은 hostname
AND
scheme 또는 group 또는 dns-scope가 다름
```

예:

```text
feifo.click / internet-facing / external group
feifo.click / internal        / internal group
```

CI 실패:

```text
hostname ownership conflict:
  feifo.click claimed by incompatible ingress groups
```

---

# Step 14. 수동 Route 53 수정이 해결책이 아닌 이유

## 14.1 controller가 source를 다시 적용한다

```text
사람:
  feifo.click → external ALB로 수동 변경

ExternalDNS:
  internal source도 여전히 유효
  → 다음 reconcile에서 UPSERT
```

## 14.2 GitOps와 DNS controller

Route 53 record의 간접 desired state는 Ingress에 있다.

```text
Git Ingress
  → live Ingress
    → ExternalDNS endpoint
      → Route 53 record
```

따라서 최종 record만 고치면 upstream desired source와 충돌한다.

## 14.3 올바른 수정 위치

```text
hostname이 틀림:
  Ingress source 수정

public/private scope가 틀림:
  ExternalDNS filter/zone 설정 수정

record가 stale:
  ownership 확인 후 cleanup
```

---

# Step 15. `upsert-only`와 `sync` 선택

## 15.1 upsert-only

장점:

```text
실수로 source가 사라져도 DNS record 자동 삭제 방지
cutover 중 보수적
```

단점:

```text
rename/delete 후 stale record
manual cleanup 필요
실제 desired와 Route 53이 계속 달라질 수 있음
```

## 15.2 sync

장점:

```text
source 제거가 DNS 삭제로 반영
완전한 desired-state reconciliation
```

단점:

```text
잘못된 manifest 삭제가 즉시 DNS outage
ownership/filter 오류의 blast radius 큼
```

## 15.3 권장 전환 조건

`sync`로 바꾸기 전:

```text
[ ] public/private controller 분리
[ ] zone ID/type filter
[ ] unique owner ID
[ ] hostname conflict CI
[ ] TXT record migration 검증
[ ] deletion preview와 승인 절차
[ ] critical record 보호
```

현재처럼 scope가 섞여 있다면 `upsert-only`는 안전장치지만 cleanup debt를 만든다.

---

# Step 16. 운영 Runbook

## 16.1 DNS가 잘못된 ALB를 가리킬 때

```text
1. Route 53 record target 확인
2. ExternalDNS log에서 hostname 검색
3. cluster 전체 Ingress host/annotation 수집
4. 각 Ingress status.address 확인
5. ALB scheme/group 비교
6. TXT owner ID 확인
7. ExternalDNS source/filter/policy 확인
8. source ownership 수정
9. reconcile 후 Route 53 재검증
10. HTTPS data-plane smoke
```

## 16.2 확인 명령의 목적

Ingress inventory:

```powershell
kubectl get ingress -A `
  -o custom-columns=`
NS:.metadata.namespace,`
NAME:.metadata.name,`
HOSTS:.spec.rules[*].host,`
ADDRESS:.status.loadBalancer.ingress[*].hostname
```

ExternalDNS args:

```powershell
kubectl get deployment external-dns `
  -n kube-system `
  -o jsonpath='{.spec.template.spec.containers[0].args}'
```

Route 53:

```text
record name
record type
AliasTarget.DNSName
EvaluateTargetHealth
TXT ownership
```

## 16.3 완료 조건

```text
[ ] public hostname target=external ALB
[ ] internal hostname target=internal ALB
[ ] incompatible duplicate source 없음
[ ] TXT owner 예상값
[ ] ExternalDNS 반복 reconcile 후 target 유지
[ ] public HTTPS 정상
[ ] internal 접근은 VPC 경로에서 검증
[ ] stale record inventory 완료
```

한 번 맞는 것만으로 부족하다. 최소 두 번 이상의 reconcile cycle 뒤에도 유지돼야 한다.

---

# Step 17. 개선된 목표 상태

```text
Git:
  public Ingress dns-scope=public
  internal Ingress dns-scope=private

CI:
  rendered hostname ownership conflict 검사

Public ExternalDNS:
  public zone only
  public sources only
  owner-id=prod-public

Private ExternalDNS:
  private zone only
  private sources only
  owner-id=prod-private

Route 53:
  feifo.click public Alias → external ALB
  internal.feifo.click private Alias → internal ALB
```

이 구조에서는 ALB scheme, DNS view, hostname이 같은 경계를 공유한다.

---

## 최종 원인 트리

```text
feifo.click이 internal ALB를 가리킴
│
├─ ALB provisioning
│  ├─ external ALB 정상
│  ├─ internal ALB 정상
│  └─ ingress-core Synced/Healthy
│
├─ ExternalDNS source
│  ├─ source=ingress
│  ├─ external edge host=feifo.click
│  ├─ external Keycloak host=feifo.click
│  └─ internal edge host=feifo.click
│
├─ target 집합
│  ├─ feifo.click → external ALB
│  ├─ feifo.click → external ALB
│  └─ feifo.click → internal ALB
│
├─ 보호가 되지 않은 이유
│  ├─ 같은 ExternalDNS deployment
│  ├─ 같은 txtOwnerId
│  ├─ group.order는 DNS priority가 아님
│  └─ ALB scheme은 zone publication filter가 아님
│
├─ 1차 조치
│  ├─ external hostname annotation
│  └─ internal exclude annotation
│
├─ 최종 조치
│  ├─ public host=feifo.click
│  ├─ internal host=internal.feifo.click
│  └─ redundant exclude 제거
│
├─ 검증
│  ├─ Route 53 public alias → external ALB
│  ├─ HTTPS 302 → Keycloak OAuth
│  └─ ingress-core Synced/Healthy
│
└─ 남은 부채
   ├─ public/private hosted zone 경계 미분리
   ├─ internal hostname public publication 가능
   ├─ upsert-only stale record cleanup
   ├─ hostname conflict CI 없음
   └─ DNS scope admission policy 없음
```

## 한 문장으로 남기는 교훈

**ExternalDNS의 TXT owner는 controller의 소유권을 표시할 뿐 같은 controller가 읽는 여러 Ingress 사이의 hostname 충돌을 해결하지 않으므로, 하나의 DNS view에서 하나의 hostname은 호환되는 target 집합 하나만 가져야 한다.**
