# [ADR-008] L4 스플릿 브레인 방어를 위한 TraceID 라우팅 (Stickiness)

**진행 시점:** Phase 2 (OTel Collector) 설계 완료 시점

## 1. 배경 및 물리적 위협 (Context & Threat)

**[배경]** 
Gateway 계층에서 꼬리 기반 샘플링(Tail-Based Sampling)을 완벽하게 수행하려면, 하나의 트레이스(결제 요청 1건)에 속하는 모든 스팬(Span: 장바구니->주문->결제 조각들)이 **무조건 동일한 단일 Gateway 파드**로 모여야 합니다. 

**[물리적 위협: 샘플링 스플릿 브레인 (Split-Brain)]**
기본적인 K8s Service(ClusterIP)를 사용해 Agent가 Gateway로 데이터를 쏘면, L4 라운드로빈 밸런싱에 의해 스팬들이 여러 Gateway 파드로 갈기갈기 흩어집니다. 
* **치명적 결과:** `Gateway-1`은 주문 스팬만 보고, `Gateway-2`는 결제 에러 스팬만 봅니다. 두 Gateway 모두 자신이 가진 데이터가 불완전하다고 판단하여 **서로 합의 없이 100%의 데이터를 가차 없이 버려버립니다(Drop).** 수백만 건의 트레이스가 허공으로 증발합니다.

## 2. 의사결정의 진화와 맹점 격파 (Evolutionary History)

**[순진했던 초기 설계]**
Agent 설정에서 평범한 `otlp` 익스포터를 사용하여 `otel-gateway-...:4317` 로 데이터를 밀어 넣었습니다.

**[레드팀(Platform Engineer)의 타격과 맹점 발견]**
레드팀 분석 결과, Gateway가 다중 파드(3대)로 스케일아웃 되어 있는 이상 L4 통신 구조에서는 샘플링 로직이 구조적으로 완전히 박살난다는 사실을 찾아냈습니다.

## 3. 삼위일체 대타협 코드 (The Concrete Fix)

이 치명적인 데이터 분산 문제를 해결하기 위해, Agent 단에 **`loadbalancing` 익스포터**를 도입하여 트레이스 고유 번호(`traceID`)를 기준으로 L7 라우팅을 강제했습니다.

```yaml
# localy-manifests/platform/otel-collector/values-agent.yaml
config:
  exporters:
    # [Platform/App Architect Fix] Tail-Sampling 붕괴 방지를 위한 traceID 기반 라우팅
    loadbalancing:
      protocol:
        otlp:
          tls:
            insecure: true
      resolver:
        dns:
          hostname: "otel-gateway-opentelemetry-collector.platform.svc.cluster.local"
      # [핵심] 동일한 traceID를 가진 조각들은 항상 동일한 Gateway 파드로만 향함 (Stickiness)
      routing_key: "traceID"

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        # 일반 otlp가 아닌 loadbalancing 익스포터 장착
        exporters: [loadbalancing] 
```

## 4. 아키텍트의 저울 및 방어 논리 (Trade-offs & Defense)

**[트레이드오프 (Trade-offs)]**
* **잃은 것 (Load Distribution):** 만약 특정 `traceID` 하나가 비정상적으로 거대한 크기(예: 무한 루프 버그로 수백만 개의 스팬 생성)를 가질 경우, 트래픽이 골고루 분산되지 않고 특정 1대의 Gateway 파드에만 트래픽이 집중되어 파드가 터질 수 있습니다(Hotspotting).
* **얻은 것 (Data Integrity):** 데이터 스플릿 브레인 현상을 방지하여 꼬리 기반 샘플링의 데이터 유실률을 100%에서 0%로 완벽하게 복구해 냈습니다.

**[CTO 감사 방어 스크립트]**
* **CTO:** *"TraceID로 해시 라우팅을 하면 트래픽 쏠림(Hotspot) 현상 때문에 특정 Gateway 파드가 죽을 위험이 있지 않습니까? 그냥 L4 라운드로빈으로 골고루 뿌리는 게 안전하지 않나요?"*
* **수석 아키텍트:** *"L4 라운드로빈을 쓰면 파드의 부하는 평등해지겠지만, 정작 우리가 지켜야 할 트레이스 데이터는 100% 쓰레기로 판정되어 폐기됩니다. 우리는 파드를 지키기 위해 이 인프라를 깐 것이 아니라 데이터를 지키기 위해 깐 것입니다. 핫스팟으로 특정 파드가 터진다면, 그건 앱 단의 비정상적인 무한 루프 버그가 원인이므로 오히려 그 버그를 색출해내는 순기능으로 작용할 것입니다."*
