# [ADR-006] OTel Gateway 영구 큐(PQ) 도입 및 오토스케일링(HPA) 폐지 결단

**진행 시점:** Phase 2 (OTel Collector 2-Tier 아키텍처) 구현 완료 시점

## 1. 배경 및 물리적 위협 (Context & Threat)

**[배경]** 
하루 수백만 건의 마이크로서비스 트레이스가 중앙 게이트웨이(Gateway)로 쏟아집니다. 만약 최종 종착지인 OpenSearch(Jaeger)가 순간적인 장애로 멈추거나 네트워크가 지연될 경우, 게이트웨이의 메모리에 쌓여있던 귀중한 에러 데이터들은 단 몇 초 만에 한계(2Gi)에 도달하게 됩니다. 

**[물리적 위협: OOM 데스 스파이럴과 데이터 완전 증발]**
만약 메모리에만 데이터를 쥐고 있다면 (In-Memory Queue), 메모리 한계치 도달 시 OTel Collector는 살기 위해 즉각 **OOM(Out of Memory) 폭발**을 일으키거나 데이터를 무자비하게 버리게(Soft Drop) 됩니다. 
* **SRE 관점의 치명적 위협:** 하필 가장 중요한 장애 상황(블랙프라이데이 등)에서 장애를 분석해야 할 단서(Trace)들이 가장 먼저 증발해 버리는 **'관측성의 역설'**이 발생합니다. 인프라는 붕괴했는데, 대시보드는 평온하고 원인은 영원히 미궁에 빠지게 됩니다. 

이를 방어하기 위해 우리는 데이터를 메모리가 아닌 안전한 디스크(EBS 볼륨)로 대피시키는 영구 큐(Persistent Queue)를 도입해야만 했습니다.

## 2. 의사결정의 진화와 맹점 격파 (Evolutionary History)

**[순진했던 초기 설계]**
초기 설계에서는 트래픽 폭주에 대비해 Gateway를 StatefulSet(EBS 볼륨 장착)으로 구성하고, 여기에 **HPA(오토스케일링, 1~5대)**를 붙여 비용 효율을 극대화하려 했습니다.

**[레드팀(SRE/FinOps)의 융단폭격과 맹점 발견]**
모의 부하 테스트 결과, 이 설계는 **데이터 인질극(Stranded Data Blackhole)**과 **고아 볼륨 요금 폭탄**이라는 궤멸적 부작용을 낳았습니다.
* 트래픽이 폭주하여 파드가 5대까지 늘어납니다. 이때 Jaeger가 지연되면 파드 2~5번의 EBS 디스크(PQ)에 트레이스 데이터가 안전하게 저장됩니다.
* 트래픽이 빠지면 HPA가 파드를 다시 1대로 축소(Scale-down)합니다. 파드 2~5번은 즉시 종료됩니다.
* **치명적 맹점 1 (데이터 인질):** 파드는 죽었지만 EBS 디스크 안에는 아직 Jaeger로 보내지 못한 데이터가 남아있습니다. 이 데이터는 다음 번 트래픽이 폭주해 파드가 다시 살아날 때까지 영원히 전송되지 않고 갇혀버립니다.
* **치명적 맹점 2 (비용 폭탄):** 쿠버네티스 기본 정책상 StatefulSet이 축소되어도 연결되었던 PVC(EBS)는 지워지지 않고 영구 보존됩니다. 스케일링이 반복될수록 버려진 EBS 디스크가 무한정 증식하며 AWS 청구서를 박살 냅니다.

## 3. 삼위일체 대타협 코드 (The Concrete Fix)

이 치명적인 함정을 피하기 위해, 우리는 핀옵스(비용 최적화)를 과감히 포기하고 **고정 레플리카(3대)**로 아키텍처를 단순화 및 락인(Lock-in)했습니다.

```yaml
# localy-manifests/platform/otel-collector/values-gateway.yaml

mode: statefulset

# [SRE 대타협 1] StatefulSet + HPA의 데이터 유실/고아 볼륨을 막기 위한 고정 3대 배포
replicaCount: 3

statefulset:
  volumeClaimTemplates:
    - metadata:
        name: file-storage-queue
      spec:
        accessModes: [ "ReadWriteOnce" ]
        storageClassName: "gp3" 
        resources:
          requests:
            storage: 5Gi
  # [SRE 대타협 2] 가짜 PQ 방지: 선언된 볼륨을 컨테이너 내부에 물리적으로 마운트
  volumeMounts:
    - name: file-storage-queue
      mountPath: /var/lib/otelcol/pq

config:
  extensions:
    file_storage:
      directory: /var/lib/otelcol/pq

  exporters:
    otlp/jaeger:
      endpoint: "jaeger-collector.platform.svc.cluster.local:4317"
      tls:
        insecure: true
      sending_queue:
        enabled: true
        storage: file_storage # 디스크 기반 영구 큐(PQ) 활성화

# [FinOps 타협] HPA 폐기 (스토리지 좀비 방지)
autoscaling:
  enabled: false
```

## 4. 아키텍트의 저울 및 방어 논리 (Trade-offs & Defense)

**[트레이드오프 (Trade-offs)]**
* **잃은 것 (FinOps):** 야간이나 트래픽이 적은 시간대에도 무조건 3대의 Gateway 인스턴스가 켜져 있으므로, 잉여 컴퓨팅 비용이 발생합니다.
* **얻은 것 (Reliability):** 그 어떤 장애나 스케일다운 이벤트에서도 단 1바이트의 트레이스 데이터도 증발하거나 인질로 잡히지 않는 **절대적인 데이터 신뢰성(Zero Data Loss)**을 확보했습니다. K8s 스토리지 고아 객체 관리라는 골칫거리도 영구 제거했습니다.

**[CTO 감사 방어 스크립트]**
* **CTO:** *"요즘 시대에 클라우드를 쓰면서 오토스케일링(HPA)을 끈다고요? 야간에 노는 서버 비용은 어떡합니까? 기술 퇴보 아닙니까?"*
* **수석 아키텍트:** *"맞습니다. 잉여 컴퓨팅 비용이 발생합니다. 하지만 CTO님, 디스크 상태(Stateful)를 가진 앱에 무턱대고 HPA를 달면 K8s 생태계 특성상 파드 축소 시 디스크 안에 있는 큐 데이터가 인질로 잡히는 끔찍한 부작용이 발생합니다."*
* **수석 아키텍트:** *"만약 결제 장애가 터진 야간 시간대에 스케일다운이 일어나서, 장애 원인이 담긴 트레이스 로그가 EBS 볼륨 안에 통째로 갇혀버린다면 어떨까요? 월 몇 만 원의 컴퓨팅 비용을 아끼려다 장애 원인 분석이 반나절 지연되면 회사는 수억 원의 기회비용을 잃습니다. 관측 인프라의 최우선 순위는 '비용'이 아니라 '절대적인 데이터의 생존'입니다."*
