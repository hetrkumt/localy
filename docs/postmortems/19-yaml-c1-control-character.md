# 한 글자가 플랫폼 Application 전체를 막았다

> 화면에는 깨진 주석으로만 보였던 UTF-8 `C2 80`이 Kustomize와 Argo CD manifest generation을 중단시킨 사건

## 문서 정보

- 사건 시각: 2026-07-31 22:45~22:50 KST
- 환경: Argo CD Multi-Source Application, Kustomize, YAML, PowerShell, UTF-8
- 대상 Application: `kube-prometheus-stack`
- 문제 파일: `apps/kube-prometheus-stack/network-policy.yaml`
- 최초 오류:
  - `MalformedYAMLError`
  - `control characters are not allowed`
- 직접 원인: 주석에 UTF-8 `C2 80`, 즉 Unicode `U+0080` C1 control character 포함
- 구조적 원인:
  - 인코딩이 깨진 주석이 Git에 들어감
  - CI에서 Kustomize build·Unicode control character 검사 부재
- 진단 방해 요인:
  - 일반 raw-byte C0 검사에서 0건
  - UTF-8 자체는 유효
  - editor·terminal에서 replacement glyph 또는 깨진 한글로 표시
  - YAML semantic 내용이 아니라 주석에 존재
- 복구:
  - 손상된 주석 다섯 줄을 ASCII 문장으로 교체
  - NetworkPolicy spec은 변경하지 않음
- commit: `15831f7` (`fix(kps): strip YAML C1 control chars from network-policy comments`)
- 검증:
  - `kubectl kustomize apps/kube-prometheus-stack` 성공
  - Argo manifest generation 재개
  - Grafana ExternalSecret `SecretSynced`
  - Grafana Pod `3/3 Running`
- 별도 잔여: kube-prometheus-stack의 CRD schema diff/Unknown은 이 문자 문제와 별개
- 남은 부채:
  - `.editorconfig` UTF-8 정책 없음
  - pre-commit/CI control-character scan 없음
  - 모든 overlay의 `kustomize build` CI gate 없음

---

## Executive Summary

Grafana admin credential을 Terraform으로 AWS Secrets Manager에 만들었지만 Grafana용 ExternalSecret이 기대대로 배포되지 않았다.

원인은 Secret Manager나 ESO 권한이 아니었다.

Argo CD가 `kube-prometheus-stack` Application의 desired manifests 자체를 만들지 못하고 있었다.

```text
Failed to load target state
MalformedYAMLError
network-policy.yaml
control characters are not allowed
```

문제 위치는 NetworkPolicy의 spec이 아니라 주석이었다.

수정 전 Git diff에는 다음처럼 보였다.

```yaml
# Loki Ruler ??Alertmanager (observability -> loki 蹂�?
```

파일에는 UTF-8 byte sequence:

```text
C2 80
```

이 들어 있었다.

이는 잘못된 UTF-8 byte sequence가 아니다.

```text
C2 80
  → valid UTF-8
  → Unicode U+0080
  → C1 control character
```

UTF-8 decoder는 성공하지만 YAML parser가 허용하지 않는 code point다.

처음 수행한 검사는 raw byte가 `0x20`보다 작은 C0 control인지 확인했다.

```text
0x00~0x1F 검사:
  0건
```

하지만 U+0080은 UTF-8에서 두 byte `0xC2 0x80`으로 인코딩된다. 개별 byte는 둘 다 `0x20`보다 크므로 단순 byte threshold 검사에 잡히지 않았다.

검사를 UTF-8 C1 sequence까지 확장하자 `C2 80`을 찾았다.

손상된 주석 다섯 줄을 평범한 ASCII 주석으로 다시 썼다.

```yaml
# Prometheus -> Alertmanager
# Loki Ruler -> Alertmanager
# Alertmanager HA gossip
# CoreDNS
```

NetworkPolicy의 selector, port, CIDR 등 기능적 spec은 바꾸지 않았다.

이후 Kustomize build가 성공했고 Argo CD가 다시 manifests를 생성했다. 같은 Kustomization에 있던 Grafana ESO ServiceAccount와 ExternalSecret도 비로소 sync됐고 Grafana Pod가 준비됐다.

핵심 교훈:

> parser는 화면에 보이는 글자가 아니라 Unicode code point를 읽는다. “control character가 없다”는 결론은 C0 raw byte뿐 아니라 UTF-8로 인코딩된 C1 code point까지 검사했을 때만 유효하다.

---

# Step 1. 표면 증상은 Grafana Secret 미배포였다

## 1.1 진행 중이던 작업

목표:

```text
Terraform
  → AWS Secrets Manager /localy/prod/platform/grafana
    → External Secrets Operator
      → Secret/grafana-admin-credentials
        → Grafana
```

AWS Secret과 Terraform code를 준비해도 Kubernetes resource가 생성되지 않았다.

## 1.2 처음 의심할 수 있는 영역

```text
Secret 경로 오타
JSON property 이름 불일치
Grafana IRSA 권한
SecretStore 누락
ESO controller 오류
monitoring namespace 누락
```

하지만 Argo Application condition을 확인하자 이 계층까지 도달하지 못하고 있었다.

## 1.3 manifest generation 실패

```text
Git source fetch
  → Kustomize parse
    → YAML lexical error
      → desired manifests 없음
```

ExternalSecret이 잘못된 것이 아니라 ExternalSecret을 포함한 Kustomization 전체가 render되지 않았다.

---

# Step 2. Multi-Source Application의 원자적 실패

## 2.1 Application sources

`kube-prometheus-stack`은 여러 source를 합친다.

```text
Source 1:
  upstream kube-prometheus-stack Helm chart 70.0.0

Source 2:
  Git values reference

Source 3:
  apps/kube-prometheus-stack Kustomize path
```

## 2.2 Kustomization 구성

```yaml
resources:
  - network-policy.yaml
  - rbac/role-binding.yaml
  - cert-manager-tls.yaml
  - grafana-eso-sa.yaml
  - grafana-admin-external-secret.yaml
```

문제 파일은 첫 번째 `network-policy.yaml`이었다.

## 2.3 부분 성공하지 않는다

원하는 직관:

```text
NetworkPolicy만 실패
Grafana ExternalSecret은 별도로 적용
```

실제:

```text
Kustomize source build 실패
  → 해당 source manifests 생성 실패
    → Multi-Source target state 생성 실패
      → Application sync 불가
```

Argo CD는 깨진 source를 제외하고 나머지만 임의로 apply하지 않는다.

이는 안전한 동작이다. 부분 desired state를 배포하면 Application의 원자성과 예측 가능성이 깨진다.

## 2.4 blast radius

주석의 control character 하나가 막은 것:

```text
NetworkPolicy
RoleBinding
certificate resource
Grafana ESO ServiceAccount
Grafana ExternalSecret
custom dashboard ConfigMap
Prometheus rule ConfigMap
Alertmanager template ConfigMap
Helm source와 합쳐진 전체 target state
```

파일 크기나 변경 중요도와 manifest generation blast radius는 비례하지 않는다.

---

# Step 3. YAML comment도 parser 입력이다

## 3.1 흔한 오해

```text
주석은 실행에 사용되지 않는다
  → 어떤 문자든 들어가도 된다
```

이는 틀렸다.

## 3.2 scanner가 먼저 읽는다

YAML parser의 단순화된 흐름:

```text
byte stream
  → character decoding
    → 허용 문자 검사
      → token scanning
        → comment/identifier/value 구분
          → YAML node parse
```

문자가 comment인지 판단하기 전후에 전체 stream이 유효한 character 집합인지 검사한다.

따라서 comment 안의 금지 control character도 parse를 중단시킨다.

## 3.3 spec은 정상이어도 파일은 invalid

NetworkPolicy의:

```text
podSelector
namespaceSelector
ports
ipBlock
```

가 모두 정확해도 file stream이 invalid하면 Kubernetes object는 존재하지 않는다.

---

# Step 4. C0 검사에서 왜 발견되지 않았는가

## 4.1 첫 검사

PowerShell로 file bytes를 읽고 다음을 찾았다.

```text
byte < 0x20
단, TAB/LF/CR 제외
또는 0x7F
```

개념:

```powershell
if (
  ($b -lt 32 -and $b -notin 9,10,13) `
  -or $b -eq 127
) {
  # invalid control
}
```

결과:

```text
control_chars=0
```

## 4.2 이 검사가 찾는 범위

```text
C0 controls:
  U+0000~U+001F

DEL:
  U+007F
```

ASCII 또는 single-byte 관점 검사다.

## 4.3 실제 문자는 U+0080

```text
Unicode:
  U+0080

UTF-8:
  C2 80
```

raw bytes:

```text
0xC2 = 194
0x80 = 128
```

둘 다 32보다 크다.

따라서:

```text
raw byte < 32 검사
  → 통과

UTF-8 decode 후 code point 검사
  → U+0080 발견
```

## 4.4 “control character 없음”은 검사 범위에 대한 결론이었다

첫 결과가 틀렸다기보다 질문이 좁았다.

```text
확인한 것:
  C0 raw byte 없음

확인하지 않은 것:
  UTF-8 encoded C1 code point
```

진단에서는 음성 결과가 무엇을 배제하는지 정확히 말해야 한다.

---

# Step 5. valid UTF-8과 valid YAML은 다르다

## 5.1 UTF-8 decoder

`C2 80`은 올바른 UTF-8 encoding이다.

따라서 다음 검사는 성공할 수 있다.

```text
strict UTF-8 decode
```

## 5.2 YAML character set

YAML은 모든 Unicode code point를 허용하지 않는다.

제어 목적으로 예약된 C1 범위의 다수 문자는 plain YAML stream에서 금지된다.

```text
valid UTF-8
AND
invalid YAML character
```

가 동시에 가능하다.

## 5.3 검증 계층

```text
encoding validation:
  bytes가 UTF-8로 decode 가능한가

character validation:
  decode 결과에 금지 control code point가 있는가

syntax validation:
  YAML grammar에 맞는가

schema validation:
  Kubernetes resource schema에 맞는가
```

각 단계는 다른 오류를 찾는다.

---

# Step 6. editor와 terminal이 증거를 왜곡했다

## 6.1 표시 방식

U+0080과 주변의 손상된 다국어 문자는 환경에 따라 다음처럼 보일 수 있다.

```text
빈 공간
보이지 않는 문자
�
??
깨진 한글
```

## 6.2 Git diff도 완전한 hex viewer가 아니다

commit diff에는:

```text
# Prometheus ??Alertmanager
# Loki Ruler ??Alertmanager (observability -> loki 蹂�?
# Alertmanager HA 硫ㅻ�?��????
```

처럼 보였다.

이 출력만으로 실제 bytes를 복원할 수 없다.

## 6.3 line/column도 부정확해질 수 있다

parser가 control character를 만난 byte offset과 editor가 계산하는 character column은 다를 수 있다.

```text
UTF-8:
  한 code point가 여러 byte

terminal:
  replacement glyph로 표시
```

따라서 오류 file은 맞아도 화면상 정확한 한 글자를 찾기 어려울 수 있다.

---

# Step 7. UTF-8 C1 sequence를 직접 찾다

## 7.1 byte pattern

UTF-8의 U+0080~U+009F C1 range는 다음 형태다.

```text
C2 80
...
C2 9F
```

검사:

```powershell
if (
  $bytes[$i] -eq 0xC2 `
  -and $bytes[$i + 1] -ge 0x80 `
  -and $bytes[$i + 1] -le 0x9F
) {
  # UTF-8 encoded C1 control
}
```

## 7.2 결과

`network-policy.yaml`의 손상된 comment 영역에서 `C2 80`을 찾았다.

```text
C2 80
  → U+0080
```

## 7.3 directory scan

한 file만 고친 뒤 다른 file에서 같은 문제가 나타나지 않도록 `apps/kube-prometheus-stack` 아래 YAML·template file을 재귀 검사했다.

```text
*.yaml
*.yml
*.tmpl
```

이 단계는 encoding corruption이 copy/paste 또는 bulk conversion으로 여러 파일에 퍼졌을 가능성을 확인하기 위한 것이었다.

---

# Step 8. 문자열 정규식보다 Unicode category 검사가 낫다

## 8.1 byte pattern의 한계

`C2 80~9F` 검사는 UTF-8 C1에는 정확하다.

하지만 다음을 모두 일반화하지는 못한다.

```text
다른 encoding
다른 금지 code point
잘못된 UTF-8 sequence
Unicode noncharacter
BOM 위치 오류
```

## 8.2 권장 검사

```text
1. strict UTF-8 decode
2. Unicode code point/category 검사
3. YAML parser 실행
4. Kustomize build
```

Python 개념 예:

```python
from pathlib import Path
import unicodedata

text = Path(path).read_text(encoding="utf-8", errors="strict")

for index, char in enumerate(text):
    if unicodedata.category(char) == "Cc" and char not in "\t\n\r":
        raise ValueError(
            f"control character U+{ord(char):04X} at character {index}"
        )
```

YAML spec의 허용 예외까지 엄밀히 반영하려면 사용 parser와 YAML version을 기준으로 rule을 조정해야 한다.

## 8.3 non-ASCII 전체 금지는 과도하다

```text
Korean comment
Unicode symbol
UTF-8 documentation
```

은 정상일 수 있다.

문제는:

```text
non-ASCII
```

가 아니라:

```text
금지된 control code point
```

다.

이번에는 빠르고 확실한 복구를 위해 손상된 주석만 ASCII로 바꿨다.

---

# Step 9. 수정

## 9.1 변경한 comment

```yaml
# Prometheus -> Alertmanager
# Loki Ruler -> Alertmanager
# Alertmanager HA gossip
# Alertmanager HA gossip
# CoreDNS
```

## 9.2 변경하지 않은 spec

```text
NetworkPolicy name/namespace
podSelector
policyTypes
Prometheus ingress
Loki ingress
Alertmanager gossip TCP/UDP
CoreDNS egress
SNS/STS endpoint CIDR
port
```

## 9.3 왜 file 전체를 다시 썼는가

눈에 보이는 한 문자만 삭제하면 주변에 다른 mojibake나 control character가 남을 수 있었다.

작은 manifest였기 때문에 semantic 내용을 유지하면서 clean text로 다시 쓰는 편이 안전했다.

## 9.4 commit

```text
15831f7
fix(kps): strip YAML C1 control chars from network-policy comments
```

diff:

```text
1 file changed
5 insertions
5 deletions
```

기능 변경이 아니라 comment encoding cleanup이었다.

---

# Step 10. 검증

## 10.1 local Kustomize

```powershell
kubectl kustomize apps/kube-prometheus-stack
```

성공:

```text
kustomize_exit=0
```

이 검증은 YAML parse와 Kustomization resource aggregation을 함께 확인한다.

## 10.2 Argo CD

```text
hard refresh
sync retry
MalformedYAML/control character condition 제거
```

## 10.3 ESO

같은 Kustomization에 포함된:

```text
ServiceAccount/grafana-eso-sa
SecretStore/platform-secret-store
ExternalSecret/grafana-admin-credentials
```

가 생성됐다.

ExternalSecret:

```text
SecretSynced
Ready=True
```

## 10.4 Grafana

```text
Grafana Pod:
  3/3 Running
```

## 10.5 별도 Argo 상태

kube-prometheus-stack에는 이후에도:

```text
CRD schema diff
trackTimestampsStaleness
Unknown/OutOfSync 가능성
```

이 남을 수 있었다.

이는 control character와 다른 사건이다.

```text
manifest generation:
  복구됨

CRD live/desired schema diff:
  별도
```

오류 하나가 사라지지 않았다고 fix가 실패한 것으로 오판하면 안 된다.

---

# Step 11. 이 문제가 왜 늦게 발견됐는가

## 11.1 file은 Git에 commit될 수 있다

Git은 YAML 문법을 검증하지 않는다.

```text
valid bytes/blob
  → commit 가능
```

## 11.2 editor가 경고하지 않을 수 있다

editor가:

```text
문자를 숨김
replacement glyph로 표시
comment라 lint 우선순위를 낮춤
YAML language server가 file 전체 build 경로를 실행하지 않음
```

수 있다.

## 11.3 해당 overlay가 local에서 build되지 않음

변경 시:

```text
kubectl kustomize apps/kube-prometheus-stack
```

가 자동 실행됐다면 merge 전에 잡혔을 가능성이 높다.

## 11.4 Argo가 최초 통합 parser 역할을 했다

결국 production GitOps reconciliation이 첫 end-to-end syntax gate가 됐다.

```text
CI가 찾아야 할 오류
  → Argo runtime에서 발견
```

---

# Step 12. encoding corruption의 원인은 확정하지 않았다

## 12.1 관측 사실

```text
여러 comment의 한글/화살표가 mojibake
U+0080 존재
spec 자체는 정상
```

## 12.2 가능한 원인

```text
UTF-8과 CP949/EUC-KR 사이의 잘못된 변환
terminal copy/paste
editor encoding 변경
생성 script의 decode/encode mismatch
replacement text 재저장
```

## 12.3 단정할 수 없는 이유

원본 입력 경로, editor encoding history, 변환 script log가 없었다.

따라서 문서에는:

```text
직접 원인:
  U+0080

발생 경로:
  미확정
```

으로 남긴다.

mojibake 모양만 보고 특정 encoding 변환 횟수를 추측하는 것은 증거가 아니다.

---

# Step 13. CI 방어선

## 13.1 strict UTF-8

모든 text manifest:

```text
UTF-8 decode errors=strict
```

## 13.2 control character scan

```text
C0:
  TAB/LF/CR 외 거부

C1:
  parser가 허용하지 않는 code point 거부
```

## 13.3 YAML parse

모든 `*.yaml`, `*.yml`:

```text
syntax parse
duplicate key 검출
multi-document 처리
```

## 13.4 Kustomize build

standalone file parse만으로 부족하다.

```text
모든 active kustomization root build
```

를 해야 한다.

예:

```text
apps/kube-prometheus-stack
apps/ingress-core/overlays/prod
platform/karpenter/overlays/prod
workloads/*/overlays/prod
gitops/overlays/prod
```

## 13.5 Argo Multi-Source render

가능하면 CI에서:

```text
Helm chart version
values ref
Kustomize source
```

를 실제 Application과 같은 revision으로 render한다.

로컬 Kustomize만 성공하고 Helm values 경로가 깨지는 문제도 별도로 잡아야 한다.

---

# Step 14. repository 정책

## 14.1 `.editorconfig`

현재 repository root에 `.editorconfig`가 없다.

권장:

```ini
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true

[*.{yaml,yml}]
indent_style = space
indent_size = 2
```

이는 editor의 저장 encoding을 통일하지만 control character 자체를 모두 차단하지는 않는다.

## 14.2 pre-commit

```text
UTF-8 strict decode
Unicode control scan
YAML parser
Kustomize build
```

## 14.3 CI

local hook은 우회될 수 있다.

같은 검사를 required CI check로 실행해야 한다.

## 14.4 생성 파일

dashboard JSON, template, generated values도 text encoding 검사가 필요하다.

Kustomize `configMapGenerator`는 이런 file까지 읽기 때문에 YAML만 검사하면 충분하지 않을 수 있다.

---

# Step 15. 오류 메시지를 읽는 방법

## 15.1 `MalformedYAMLError`

```text
Kubernetes schema 오류
```

가 아니라 parser가 object를 만들기 전 실패한 것이다.

따라서:

```text
kubectl describe resource
```

로는 찾을 live resource가 없을 수 있다.

## 15.2 `control characters are not allowed`

확인 순서:

```text
NUL/C0
DEL
UTF-8 C1
BOM/zero-width/noncharacter
invalid UTF-8
file concatenation/binary contamination
```

## 15.3 filename이 있으면 먼저 isolated parse

```text
전체 Application sync 반복
```

보다:

```text
문제 file byte scan
해당 Kustomization local build
```

가 빠르고 안전하다.

---

# Step 16. 운영 Runbook

## 16.1 parser 오류 수집

```text
[ ] Application condition 원문
[ ] source index/path
[ ] repository revision
[ ] filename
[ ] line/column
[ ] local reproduction command
```

## 16.2 파일 검사

```text
[ ] BOM
[ ] strict UTF-8 decode
[ ] C0 bytes
[ ] decoded C1 code points
[ ] replacement character U+FFFD
[ ] zero-width characters
[ ] hex context
[ ] Git 이전 revision 비교
```

## 16.3 수정

```text
[ ] semantic spec 유지
[ ] 손상된 comment만 clean text로 교체
[ ] directory 전체 동일 pattern scan
[ ] unrelated formatting 변경 최소화
```

## 16.4 검증

```text
[ ] YAML parse
[ ] Kustomize build
[ ] rendered resource inventory
[ ] Argo hard refresh
[ ] manifest generation condition 제거
[ ] downstream resource 생성
[ ] downstream workload health
```

---

# Step 17. 탐지 script의 목표 형태

```text
입력:
  repository의 text candidate

검사:
  strict UTF-8
  forbidden Unicode control
  YAML syntax
  Kustomize roots

출력:
  file
  byte offset
  character offset
  line/column
  code point
  주변 hex

exit:
  하나라도 발견 시 non-zero
```

예상 오류:

```text
apps/kube-prometheus-stack/network-policy.yaml:
  forbidden control U+0080
  UTF-8 bytes C2 80
  line <n>, column <m>
```

이 정도 정보가 있으면 editor 표시와 무관하게 바로 수정할 수 있다.

---

## 최종 원인 트리

```text
Grafana ExternalSecret이 배포되지 않음
│
├─ Argo kube-prometheus-stack target state 생성 실패
│  └─ Kustomize source parse 실패
│
├─ 문제 file
│  └─ apps/kube-prometheus-stack/network-policy.yaml
│
├─ 직접 원인
│  ├─ comment 안 Unicode U+0080
│  ├─ UTF-8 bytes C2 80
│  ├─ valid UTF-8
│  └─ invalid YAML character
│
├─ 진단 방해
│  ├─ raw C0 byte scan 결과 0
│  ├─ 개별 C2/80 byte는 0x20보다 큼
│  ├─ editor/terminal의 mojibake
│  ├─ comment라 무해하다는 직관
│  └─ Multi-Source가 downstream 전체를 차단
│
├─ 복구
│  ├─ UTF-8 C1 sequence scan
│  ├─ 손상된 comment 5줄 재작성
│  ├─ NetworkPolicy spec 유지
│  ├─ Kustomize build 성공
│  └─ commit 15831f7
│
├─ 결과
│  ├─ Argo manifest generation 재개
│  ├─ Grafana ExternalSecret SecretSynced
│  └─ Grafana Pod 3/3 Running
│
└─ 남은 부채
   ├─ 발생 encoding 경로 미확정
   ├─ .editorconfig 없음
   ├─ Unicode control pre-commit 없음
   ├─ Kustomize required CI 없음
   └─ Multi-Source render gate 없음
```

## 한 문장으로 남기는 교훈

**화면에 보이는 문자열과 valid UTF-8만으로 YAML의 유효성을 판단할 수 없으며, parser가 control character를 보고했다면 raw C0 byte를 넘어 decoded Unicode code point와 실제 Kustomize build까지 검사해야 한다.**
