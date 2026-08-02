# 새 KMS 키로는 옛 로그를 열 수 없었다

> S3 Object Lock으로 보존된 Loki 객체와 삭제 예약된 legacy CMK, 재생성된 IRSA principal의 생명주기 충돌

## 문서 정보

- 최초 장애 시각: 2026-07-31
- policy 영구화 시각: 2026-07-31 23:05~23:11 KST
- 환경: Loki, Amazon S3, S3 Object Lock, AWS KMS, IRSA, Terraform
- 대상 bucket: `prod-eks-loki-logs-vault`
- Object Lock:
  - mode: `COMPLIANCE`
  - default retention: 90일
  - current version lifecycle expiration: 93일
- legacy KMS key ID: `c4e097ff-d777-4c9b-9098-e3d467a15f95`
- new KMS key: 재배포한 `aws_kms_key.loki_s3`
- 최초 증상:
  - Loki compactor/backend 기동 실패
  - `KMSInvalidStateException`
  - legacy key state `PendingDeletion`
- 직접 원인: 기존 S3 객체가 삭제 예약된 legacy key로 암호화됨
- 구조적 원인:
  - Object Lock retention은 90일
  - KMS deletion window는 7일
  - bucket은 teardown에서 보존했지만 암호 키는 같은 보존 경계에서 제외
- 1차 복구:
  - `cancel-key-deletion`
  - `enable-key`
  - Loki backend 재기동
- 추가 발견:
  - legacy key policy의 `AllowLokiIRSACrypto` principal이 삭제된 이전 role의 `AROA...` RoleId
  - 동일 이름으로 재생성한 현재 IRSA role과 연결되지 않음
- 영구화:
  - `kms_loki_legacy.tf`
  - current Loki IRSA ARN을 SSM에서 조회해 legacy key policy 관리
  - teardown에서 legacy key policy를 state remove
  - key 삭제 금지 안내
- 검증:
  - legacy key `Enabled`
  - policy principal이 current `prod-loki-irsa-role`
  - Loki backend 3개 각각 `2/2 Running`
  - Argo Loki `Healthy`
- 남은 중요 부채:
  - key state를 자동으로 보호하는 Terraform resource가 없음
  - teardown은 삭제를 막지 않고 경고만 출력
  - legacy key ID가 변수 default에 하드코딩
  - key retirement를 판단하는 object-version inventory 자동화 없음

---

## Executive Summary

Loki log bucket은 S3 Object Lock COMPLIANCE mode로 90일 동안 객체를 보존한다.

```text
bucket:
  prod-eks-loki-logs-vault

Object Lock:
  COMPLIANCE 90 days
```

첫 번째 teardown에서 bucket은 삭제할 수 없었다. 이는 예상된 동작이었다. teardown script는 bucket graph를 Terraform state에서 제거하고 실제 bucket과 객체를 AWS에 남겼다.

그러나 bucket의 기존 객체를 암호화한 KMS key는 삭제 예약됐다.

```text
S3 object:
  Object Lock으로 삭제 불가

KMS key:
  PendingDeletion
```

재배포에서는 새 KMS key가 만들어졌고 bucket의 default encryption은 새 key를 가리켰다.

```text
new PUT:
  new KMS key

old object:
  legacy KMS key
```

bucket default encryption을 바꾸는 것은 기존 객체를 재암호화하지 않는다. 객체마다 write 당시 사용한 key identity가 남는다.

Loki compactor가 기존 `index` 또는 `delete_requests` 객체를 읽자 S3는 legacy key로 data key를 복호화해야 했다. 하지만 legacy key가 `PendingDeletion`이어서 KMS operation이 거부됐다.

```text
KMSInvalidStateException:
  key state가 crypto operation을 허용하지 않음
```

key deletion을 취소하고 다시 enable하자 Loki backend는 복구됐다.

그 뒤 key policy를 검사하자 두 번째 생명주기 문제가 발견됐다.

```text
policy principal:
  AROA...U63NMB3MD

current role:
  prod-loki-irsa-role
  RoleId=AROAXYGMDHFORRCNNFOOE
```

IAM role은 같은 이름과 ARN으로 재생성해도 내부 principal ID가 달라진다. 과거 role이 삭제되면 KMS policy에는 해석할 수 없는 과거 `AROA...` ID가 남는다.

당시 Loki가 key enable 후 동작한 것은 key policy의 S3 ViaService 경로가 허용돼 있었기 때문이다. 그러나 direct IRSA crypto statement는 현재 role을 신뢰하지 않는 latent defect였다.

`kms_loki_legacy.tf`를 추가해 legacy key policy의 principal을 L2가 SSM에 게시한 current Loki IRSA ARN으로 정렬했다.

이 사건의 핵심은 다음과 같다.

> 데이터를 보존하면서 그 데이터를 여는 암호 키를 먼저 삭제하는 것은 보존이 아니라 복구 불가능한 crypto-shredding이다.

---

# Step 1. Object Lock이 teardown의 의미를 바꿨다

## 1.1 bucket 설정

```hcl
resource "aws_s3_bucket_object_lock_configuration" "loki_logs" {
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 90
    }
  }
}
```

## 1.2 COMPLIANCE mode

COMPLIANCE retention이 적용된 object version은 retain-until 시각 전까지 일반적인 권한으로 삭제하거나 retention을 단축할 수 없다.

```text
bucket owner
account administrator
root 수준 권한
```

을 갖고 있어도 일반적인 삭제 API로 우회할 수 없다.

이는 실수나 공격자가 감사 로그를 조기에 지우지 못하게 하는 목적이다.

## 1.3 `force_destroy=true`는 Object Lock을 우회하지 못한다

Terraform:

```hcl
force_destroy = true
```

이 설정은 provider가 bucket 안 객체를 삭제한 뒤 bucket을 지우도록 시도하게 한다.

하지만 AWS가 Object Lock 때문에 object version 삭제를 거부하면 provider도 강제할 수 없다.

```text
Terraform force_destroy
  ≠ AWS Object Lock override
```

## 1.4 teardown 전략

script는 Loki bucket graph를 state에서 제거했다.

```text
aws_s3_bucket.loki_logs
object lock configuration
versioning
encryption configuration
bucket policy
lifecycle
public access block
legacy key policy
```

실제 AWS resource는 남기고 Terraform destroy 대상에서 제외했다.

```text
terraform state rm:
  Terraform ownership만 제거

AWS delete:
  수행하지 않음
```

---

# Step 2. SSE-KMS는 객체별로 key에 묶인다

## 2.1 envelope encryption

S3 SSE-KMS의 단순화된 write 흐름:

```text
S3
  → KMS GenerateDataKey
    → plaintext data key로 객체 암호화
    → encrypted data key를 객체 metadata와 함께 저장
```

read 흐름:

```text
S3 object의 encrypted data key
  → KMS Decrypt
    → plaintext data key
      → 객체 복호화
```

## 2.2 bucket default encryption

```hcl
apply_server_side_encryption_by_default {
  sse_algorithm     = "aws:kms"
  kms_master_key_id = aws_kms_key.loki_s3.arn
}
```

이 설정은 이후 PUT에 사용할 기본 key를 지정한다.

## 2.3 기존 객체에는 소급되지 않는다

```text
어제 쓴 object A:
  key-old

오늘 bucket default를 key-new로 변경

오늘 쓴 object B:
  key-new

object A:
  여전히 key-old 필요
```

새 key가 old key의 대체품이라는 논리는 객체 암호화 metadata에는 적용되지 않는다.

## 2.4 key alias도 해결하지 못한다

alias가 새 key를 가리키도록 바꿔도 기존 object가 암호화된 key ID는 바뀌지 않는다.

```text
alias/prod-loki-s3-key:
  old key → new key

old object:
  old key ID와 encrypted data key 유지
```

alias는 lookup 편의와 새 operation routing에 쓰일 뿐 과거 ciphertext를 새 key가 해독하게 만들지 않는다.

---

# Step 3. KMS key rotation과 key replacement는 다르다

## 3.1 automatic rotation

```hcl
enable_key_rotation = true
```

AWS KMS automatic rotation은 logical KMS key identity를 유지하면서 내부 key material을 회전한다.

KMS는 과거 key material을 보존해 기존 ciphertext를 계속 decrypt할 수 있다.

```text
KeyId:
  동일

old ciphertext:
  decrypt 가능
```

## 3.2 Terraform destroy/recreate

Terraform이 key를 삭제하고 새 resource를 만들면:

```text
old KeyId:
  c4e097ff-...

new KeyId:
  다른 UUID
```

둘은 완전히 다른 cryptographic identity다.

```text
new key:
  old ciphertext decrypt 불가
```

## 3.3 잘못된 직관

```text
같은 Terraform resource address
같은 alias
같은 description
같은 policy
```

라도 KeyId가 다르면 old object를 열 수 없다.

---

# Step 4. retention 90일과 deletion window 7일의 충돌

## 4.1 현재 key 설정

```hcl
deletion_window_in_days = 7
```

## 4.2 현재 object retention

```text
Object Lock:
  90일

Lifecycle current expiration:
  93일
```

## 4.3 위험 구간

teardown 시점에 key deletion을 예약하면:

```text
T+7:
  KMS key 영구 삭제 가능

T+90:
  object retention 종료

T+93:
  lifecycle expiration 예정
```

최대 약 86일 동안:

```text
object는 법적으로/정책상 남아 있음
하지만 decrypt key는 없음
```

## 4.4 crypto-shredding

암호화된 데이터를 남겨 둔 채 key를 영구 삭제하면 사실상 복구 불가능하게 만든다.

이를 crypto-shredding이라고 부를 수 있다.

의도적인 data destruction에는 유효하지만 Object Lock 보존 목적과 동시에 적용하면 모순이다.

```text
retention:
  데이터가 읽을 수 있게 남아 있어야 함

premature key deletion:
  데이터는 남지만 읽을 수 없음
```

---

# Step 5. 실제 장애

## 5.1 Loki component

Loki backend/compactor는 새 로그만 쓰지 않는다.

기존 storage의:

```text
index
chunks
delete requests
compactor metadata
```

를 읽고 정리한다.

## 5.2 오류

기존 객체 GET 과정에서:

```text
KMSInvalidStateException
key state: PendingDeletion
```

이 발생했다.

이 오류는 `AccessDenied`와 다르다.

```text
AccessDenied:
  policy/permission 문제

KMSInvalidStateException:
  key 상태가 operation을 허용하지 않음
```

권한을 더 줘도 PendingDeletion key로 crypto operation을 수행할 수 없다.

## 5.3 runtime 영향

```text
loki-backend/compactor:
  기존 object 접근 실패

Pod:
  기동 실패 또는 readiness 실패

Argo:
  Loki health degraded
```

---

# Step 6. 1차 복구 — key deletion 취소

## 6.1 실행

```powershell
aws kms cancel-key-deletion `
  --key-id c4e097ff-d777-4c9b-9098-e3d467a15f95 `
  --region ap-northeast-2

aws kms enable-key `
  --key-id c4e097ff-d777-4c9b-9098-e3d467a15f95 `
  --region ap-northeast-2
```

## 6.2 상태

```text
PendingDeletion
  → Disabled 또는 취소 상태
    → Enabled
```

deletion 취소 후 key가 즉시 암호 operation 가능한 상태인지 확인해야 한다.

## 6.3 결과

```text
legacy key:
  Enabled

Loki backend:
  2/2 Running

Argo Loki:
  Synced/Healthy 당시 복구 확인
```

key state 복구만으로 기존 object를 다시 읽을 수 있었다.

이는 old object가 legacy key에 묶여 있다는 강한 증거다.

---

# Step 7. key가 Enabled여도 permission이 필요하다

## 7.1 접근 조건

Loki가 S3 SSE-KMS object를 읽으려면 여러 policy 계층을 통과해야 한다.

```text
Pod
  → IRSA AssumeRoleWithWebIdentity
    → role IAM policy
      → S3 bucket policy
        → KMS key policy
          → KMS key state
```

하나라도 실패하면 읽을 수 없다.

## 7.2 S3와 KMS permission은 별개

```text
s3:GetObject 허용
```

만으로 SSE-KMS object를 읽을 수 없다.

KMS:

```text
kms:Decrypt
kms:DescribeKey
```

등의 권한도 필요하다.

반대로 KMS Decrypt가 있어도 S3 GetObject가 없으면 읽을 수 없다.

## 7.3 key state는 policy보다 먼저 막을 수 있다

policy가 완벽해도:

```text
KeyState=PendingDeletion
```

이면 crypto operation은 실패한다.

진단 순서:

```text
1. object가 사용하는 key ID
2. key state
3. caller identity
4. IAM/key/bucket policy
5. encryption context/condition
```

---

# Step 8. 삭제된 IAM role의 principal ID

## 8.1 policy의 stale principal

legacy key policy:

```text
Sid=AllowLokiIRSACrypto
Principal=AROA...U63NMB3MD
```

현재 role:

```text
name:
  prod-loki-irsa-role

RoleId:
  AROAXYGMDHFORRCNNFOOE
```

## 8.2 ARN을 저장했는데 왜 AROA가 보이는가

AWS resource-based policy에 IAM role ARN을 저장하면 AWS가 내부적으로 unique principal ID로 변환해 연결할 수 있다.

role이 삭제되면 이 principal ID를 다시 ARN으로 해석할 수 없다.

policy에:

```text
AROA...
```

가 그대로 보이는 것은 삭제된 principal을 가리키는 단서다.

## 8.3 같은 이름으로 role을 재생성해도 다르다

```text
old:
  arn:aws:iam::<account>:role/prod-loki-irsa-role
  RoleId=AROA-OLD

delete

new:
  arn:aws:iam::<account>:role/prod-loki-irsa-role
  RoleId=AROA-NEW
```

표면적 ARN/name은 같아도 principal identity는 새로 생긴다.

old policy의 AROA-OLD는 자동으로 AROA-NEW에 연결되지 않는다.

## 8.4 일반적인 stale principal 패턴

다음 resource-based policy에서도 발생할 수 있다.

```text
KMS key policy
S3 bucket policy
SQS/SNS policy
assume role trust policy
resource share policy
```

IAM role을 teardown/recreate하는 시스템은 policy 재바인딩 절차가 필요하다.

---

# Step 9. stale direct principal인데 왜 Loki가 먼저 복구됐는가

## 9.1 별도 S3 ViaService statement

legacy key policy에는 다음 경로가 있었다.

```text
Principal:
  s3.amazonaws.com

Condition:
  kms:ViaService = s3.ap-northeast-2.amazonaws.com
  aws:SourceArn = Loki bucket ARN
```

허용 action:

```text
kms:Decrypt
kms:GenerateDataKey
kms:DescribeKey
```

## 9.2 실제 경로

Loki가 S3 object를 요청하면 S3 service가 SSE-KMS 처리를 위해 KMS를 호출한다.

이 ViaService statement가 유효해 key enable 직후 object access가 복구됐다.

## 9.3 direct IRSA statement도 고쳐야 하는 이유

현재 동작한다고 stale principal을 방치하면:

```text
direct KMS API 호출 실패
policy condition 변경 시 장애
S3 integration behavior 변경 시 장애
감사 시 삭제된 principal 발견
least-privilege 의도와 실제 policy 불일치
```

가 남는다.

따라서 latent defect로 분류해 current role ARN으로 정렬했다.

---

# Step 10. legacy key policy를 Terraform으로 관리하다

## 10.1 외부에 남은 key 참조

```hcl
variable "loki_legacy_kms_key_id" {
  type    = string
  default = "c4e097ff-d777-4c9b-9098-e3d467a15f95"
}

data "aws_kms_key" "loki_legacy" {
  key_id = var.loki_legacy_kms_key_id
}
```

Terraform이 key 자체를 새로 만드는 것이 아니다.

```text
legacy key:
  기존 AWS resource

Terraform:
  data source로 조회
  key policy를 관리
```

## 10.2 current role ARN

```hcl
Principal = {
  AWS = data.aws_ssm_parameter.role_loki_arn.value
}
```

L2 EKS 계층이 current IRSA role ARN을 SSM에 게시하고 L3가 읽는다.

```text
L2 creates role
  → SSM current role ARN
    → L3 legacy key policy
```

role 재생성 후에도 Terraform apply가 current principal을 다시 bind할 수 있다.

## 10.3 policy statements

```text
EnableIAMUserPermissions:
  account root control plane

AllowLokiIRSACrypto:
  current Loki IRSA role

AllowS3ViaServiceForLokiVault:
  S3 service + region/bucket 조건
```

## 10.4 targeted apply

```text
data.aws_kms_key.loki_legacy[0]
aws_kms_key_policy.loki_legacy[0]
```

만 대상으로 plan/apply해 current role principal로 바꿨다.

---

# Step 11. 현재 Terraform이 보장하는 것과 보장하지 않는 것

## 11.1 보장하는 것

Terraform apply 시:

```text
legacy key 조회
정책을 current IRSA ARN으로 정렬
S3 ViaService statement 유지
root administration path 유지
```

## 11.2 보장하지 않는 것

현재 `kms_loki_legacy.tf`에는 key state를 자동 복구하는 resource가 없다.

```text
cancel-key-deletion 자동화 없음
enable-key 자동화 없음
deletion schedule 방지 policy 없음
```

초기 작성 중 `null_resource` local-exec 접근이 검토됐지만 최종 파일에서는 제거됐다.

따라서:

```text
KeyState=PendingDeletion
  → 먼저 운영자가 deletion 취소
  → 그다음 policy Terraform apply
```

순서가 필요하다.

## 11.3 왜 단순 null_resource도 조심해야 하는가

policy resource가 먼저 적용되고 local-exec가 나중에 실행되면 PendingDeletion 상태에서 policy update가 먼저 실패할 수 있다.

또한:

```text
AWS CLI 의존
PowerShell 의존
Terraform 밖 side effect
실패 코드 처리
재실행 idempotency
```

문제가 있다.

key lifecycle 보호는 teardown 설계와 별도 preflight에서 명시적으로 다루는 편이 낫다.

---

# Step 12. teardown script 변경

## 12.1 경고

```text
Keep legacy Loki CMK Enabled
do NOT schedule-key-deletion until retention expires
```

를 출력한다.

## 12.2 policy state removal

```powershell
"aws_kms_key_policy.loki_legacy[0]"
```

를 Loki state removal 목록에 추가했다.

목적:

```text
L3 destroy가 legacy policy를 제거·변경하지 않음
orphan bucket과 key access policy를 함께 보존
```

## 12.3 경고는 guardrail이 아니다

현재 script는 legacy key의 state를 조회해 deletion을 차단하거나 취소하지 않는다.

```text
출력:
  삭제하지 마라

기술적 강제:
  없음
```

더 강한 preflight:

```text
legacy key state 조회
PendingDeletion이면 teardown 중단
bucket object-version retention/KMS inventory 확인
key가 Terraform destroy target인지 검사
명시적 승인 없이는 schedule-key-deletion 금지
```

가 필요하다.

---

# Step 13. bucket lifecycle도 key retirement를 자동 증명하지 않는다

## 13.1 설정

```text
Object Lock:
  90일

current version expiration:
  93일
```

## 13.2 versioning

bucket versioning이 Enabled다.

동일 key에 새 object를 copy/overwrite하면 새 version이 생긴다.

```text
new version:
  new KMS key

old version:
  legacy KMS key
  retention 동안 계속 존재
```

## 13.3 noncurrent version

현재 lifecycle에서 `noncurrent-version-expiration`이라는 ID를 가진 rule은 실제로 incomplete multipart upload abort만 설정한다.

```hcl
abort_incomplete_multipart_upload {
  days_after_initiation = 1
}
```

명칭과 달리 noncurrent object version expiration 설정은 보이지 않는다.

따라서 old versions가 예상보다 오래 남을 가능성을 별도로 확인해야 한다.

## 13.4 key retirement 조건

달력상 93일이 지났다는 사실만으로 key를 삭제하면 안 된다.

```text
[ ] legacy key로 암호화된 모든 current version 없음
[ ] legacy key로 암호화된 모든 noncurrent version 없음
[ ] delete marker 뒤 old version 없음
[ ] multipart artifact 없음
[ ] 법적/감사 보존 요구 종료
[ ] restore/backup copy 확인
```

를 증명해야 한다.

---

# Step 14. re-encryption의 의미

## 14.1 새 key로 copy

S3 CopyObject를 사용해 object를 새 KMS key로 다시 쓸 수 있다.

```text
old object version:
  key-old

new copied version:
  key-new
```

## 14.2 Object Lock에서는 old version이 남는다

COMPLIANCE retention 동안 old version을 지울 수 없다.

따라서 re-encryption은 current read path를 새 key로 옮길 수 있지만 legacy key dependency를 즉시 제거하지 못할 수 있다.

```text
새 version은 new key
old locked version은 old key
```

감사나 version-specific read가 필요하면 old key가 계속 필요하다.

## 14.3 안전한 migration

```text
1. object version inventory
2. KMS key ID별 분류
3. 새 key로 copy/new version 생성
4. application current read 검증
5. old version retain-until 대기
6. old version 삭제 가능 여부 확인
7. legacy key dependency 0 검증
8. key deletion 승인
```

---

# Step 15. key policy 교체 시 주의

## 15.1 전체 policy resource

`aws_kms_key_policy`는 default policy 전체를 관리한다.

누락 위험:

```text
기존 break-glass principal
CloudTrail/S3 integration
grant 관리 권한
다른 consumer
condition
```

legacy policy를 코드화하기 전에 기존 statement를 전부 inventory해야 한다.

## 15.2 lockout 방지

다음 administrative path를 유지했다.

```text
account root:
  kms:*
```

KMS policy update에서 관리 principal을 모두 제거하면 key를 다시 관리하지 못할 수 있다.

## 15.3 최소 권한

Loki role에:

```text
Encrypt
Decrypt
ReEncrypt*
GenerateDataKey*
DescribeKey
```

를 허용했다.

old object read만 필요하다면 legacy key에는 Encrypt/GenerateDataKey가 과도할 수 있다.

장기적으로 legacy key를 read-only migration 상태로 바꾸면:

```text
kms:Decrypt
kms:DescribeKey
```

중심으로 줄이는 방안을 검토할 수 있다.

단, S3 copy/re-encryption 흐름과 실제 API 호출을 먼저 검증해야 한다.

---

# Step 16. 검증

## 16.1 key state

```text
legacy key:
  Enabled=True
  KeyState=Enabled
```

## 16.2 principal

`AllowLokiIRSACrypto`:

```text
arn:aws:iam::<account>:role/prod-loki-irsa-role
```

AWS 내부 현재 RoleId:

```text
AROAXYGMDHFORRCNNFOOE
```

과거:

```text
AROA...U63NMB3MD
```

## 16.3 Loki

```text
loki-backend:
  3 Pods
  각각 2/2 Running

Argo Loki:
  Healthy
```

남은 Argo OutOfSync가 있었다면 KMS runtime health와 별도 diff 문제로 구분했다.

## 16.4 실제 object read

가장 강한 검증은 Pod가 기존 legacy-encrypted object를 읽는 것이다.

```text
backend/compactor 정상 기동
KMSInvalidStateException 없음
AccessDenied 없음
old index 조회 성공
```

key state와 policy 문자열만 확인하는 것보다 end-to-end read가 중요하다.

---

# Step 17. 비용과 보안의 균형

## 17.1 key 유지 비용

legacy CMK 유지에는 월별 KMS key 비용이 발생한다.

하지만:

```text
로그 보존 90일
감사 가능성
복구 불가능한 데이터 손실 위험
```

과 비교해야 한다.

## 17.2 조기 삭제의 위험

비용을 줄이기 위해 key를 먼저 삭제하면:

```text
S3 storage 비용은 계속 발생
Object Lock 때문에 object도 삭제 불가
그런데 읽을 수도 없음
```

가장 나쁜 조합이 된다.

## 17.3 종료 시점

legacy key는 “새 key가 생긴 날”이 아니라:

```text
legacy key로 암호화된 마지막 object version의
retention과 access requirement가 종료된 날
```

까지 유지해야 한다.

---

# Step 18. 권장 생명주기 정책

## 18.1 key retention invariant

```text
KMS key usable lifetime
  >=
모든 ciphertext object version의 retention lifetime
  + restore/audit safety margin
```

## 18.2 teardown

```text
Object Lock bucket 보존
  → 관련 KMS key 보존
  → current reader principal policy 재바인딩
  → key state monitor 유지
```

세 개를 하나의 preservation set으로 취급해야 한다.

## 18.3 resource tags

legacy key:

```text
Purpose=loki-object-lock-legacy
DoNotDeleteBefore=<date>
ProtectedBy=object-lock
Bucket=prod-eks-loki-logs-vault
```

같은 metadata를 붙이면 자동화와 사람이 의존성을 파악하기 쉽다.

현재 legacy key policy resource에는 이런 key tag 관리가 없다.

## 18.4 삭제 제어

다음 방어를 검토할 수 있다.

```text
SCP로 protected key ScheduleKeyDeletion 거부
IAM permission boundary
tag condition 기반 deny
AWS Config rule
EventBridge alert on ScheduleKeyDeletion
CloudTrail alarm
pre-teardown dependency gate
```

문자열 경고보다 강한 통제다.

---

# Step 19. 운영 Runbook

## 19.1 Loki에서 KMS 오류가 날 때

```text
1. 실패한 object/key path 확인
2. bucket default encryption key 확인
3. object version의 실제 KMS key ID 확인
4. key state 확인
5. PendingDeletion이면 deletion date 확인
6. 보존 대상이면 cancel deletion
7. key enable
8. caller Role ARN/RoleId 확인
9. key policy의 stale AROA 확인
10. S3 ViaService condition 확인
11. backend/compactor old object read 검증
```

## 19.2 teardown 전

```text
[ ] locked object version 존재
[ ] legacy KMS key 목록
[ ] 각 key state=Enabled
[ ] deletion schedule 없음
[ ] current IRSA principal policy
[ ] bucket policy current role
[ ] state-rm 대상과 실제 preserve set 일치
[ ] CloudTrail/EventBridge deletion alert
```

## 19.3 key retirement 전

```text
[ ] version별 legacy key dependency inventory
[ ] retention 만료
[ ] lifecycle 실제 삭제 확인
[ ] noncurrent version 없음
[ ] backup/replication copy 없음
[ ] audit/legal 승인
[ ] Loki read path가 new key만 사용
[ ] rollback 불필요 확인
```

그 뒤:

```hcl
loki_legacy_kms_key_id = ""
```

로 policy 관리에서 제외하고 승인된 key deletion 절차를 진행한다.

---

## 최종 원인 트리

```text
Loki backend/compactor KMSInvalidStateException
│
├─ S3 data
│  ├─ Object Lock COMPLIANCE 90일
│  ├─ bucket/version은 teardown 후 보존
│  └─ old object는 legacy CMK로 암호화
│
├─ KMS lifecycle
│  ├─ Terraform key deletion window 7일
│  ├─ teardown에서 legacy key 삭제 예약
│  └─ KeyState=PendingDeletion
│
├─ 재배포
│  ├─ new aws_kms_key.loki_s3 생성
│  ├─ bucket default encryption은 new key
│  └─ old object는 자동 재암호화되지 않음
│
├─ 1차 복구
│  ├─ cancel-key-deletion
│  ├─ enable-key
│  └─ old object read 복구
│
├─ IAM identity drift
│  ├─ old prod-loki-irsa-role 삭제
│  ├─ key policy에 stale AROA RoleId
│  ├─ 같은 이름의 new role은 새 RoleId
│  └─ S3 ViaService 경로 덕분에 우선 동작
│
├─ 영구화
│  ├─ legacy key data source
│  ├─ current SSM role ARN으로 key policy
│  ├─ S3 ViaService bucket 조건
│  ├─ teardown policy state-rm
│  └─ 삭제 금지 경고
│
└─ 남은 부채
   ├─ key state 자동 guard 없음
   ├─ teardown 경고만 있고 강제 차단 없음
   ├─ legacy key ID 하드코딩
   ├─ noncurrent version lifecycle 불명확
   ├─ key dependency inventory 없음
   └─ retirement 승인 자동화 없음
```

## 한 문장으로 남기는 교훈

**Object Lock으로 ciphertext를 보존한다면 그 모든 object version의 보존 기간이 끝날 때까지 decrypt key와 현재 reader principal의 policy도 함께 보존해야 하며, 새 key 생성은 기존 ciphertext의 복호화 능력을 승계하지 않는다.**
