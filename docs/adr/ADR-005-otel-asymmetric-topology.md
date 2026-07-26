# [ADR-005] OTel 비대칭 2-Tier 토폴로지 도입 (DaemonSet + StatefulSet)

**진행 시점:** Phase 2 (OTel Collector) 설계 완료 시점

## 1. 배경 및 물리적 위협 (Context & Threat)

**[배경]** 
OpenTelemetry 수집기를 쿠버네티스에 배포할 때, 모든 노드에 무거운 수집기를 띄우거나(DaemonSet Only), 중앙에만 거대한 수집기를 두는(Gateway Only) 방식 중 하나를 선택해야 합니다.

**[물리적 위협: 앱 리소스 기아(Starvation) 현상]**
만약 모든 노드에 띄워진 DaemonSet에서 트레이스 샘플링, 압축, 영구 큐 등 무거운 연산을 수행하게 되면, OTel 파드가 노드의 CPU와 메모리를 무자비하게 집어삼킵니다. 결과적으로 동일한 노드에서 실행 중이던 핵심 비즈니스 앱(Spring Boot)들이 **자원 기아(Starvation) 상태에 빠져 연쇄적으로 OOM-Kill 당하는 대참사**가 발생합니다.

## 2. 의사결정의 진화와 맹점 격파 (Evolutionary History)

**[순진했던 초기 설계]**
수집기를 하나만 두는 단일 구조를 구상했으나, 앱들이 멀리 있는 중앙 수집기로 직접 데이터를 쏘면 네트워크 병목이 발생하고, 노드 자체의 인프라 메트릭(CPU/메모리)을 수집할 주체가 사라진다는 맹점이 발견되었습니다.

**[레드팀의 타격과 진화]**
역할을 철저히 쪼개야만 했습니다. 최전방에는 연산 능력을 거세한 '깡통 우체통(Agent)'을 데몬셋으로 띄우고, 무거운 연산은 후방의 안전한 '중앙 지휘소(Gateway)'로 몰아주는 **비대칭 2-Tier 아키텍처**로 진화했습니다.

## 3. 삼위일체 대타협 코드 (The Concrete Fix)

```yaml
# 1. Tier 1: Agent (localy-manifests/platform/otel-collector/values-agent.yaml)
mode: daemonset
resources:
  requests: { cpu: 100m, memory: 256Mi }
  limits: { memory: 512Mi } # 연산을 하지 않으므로 극도로 가벼운 리소스 제한

# 2. Tier 2: Gateway (localy-manifests/platform/otel-collector/values-gateway.yaml)
mode: statefulset
resources:
  requests: { cpu: 1, memory: 1Gi }
  limits: { memory: 2Gi } # 무거운 샘플링 연산을 전담하므로 메모리를 대량 할당
```

## 4. 아키텍트의 저울 및 방어 논리 (Trade-offs & Defense)

**[트레이드오프 (Trade-offs)]**
* **잃은 것 (Operation Cost):** 단일 수집기 구조에 비해 2개의 파이프라인(Agent, Gateway)을 동시에 유지보수해야 하므로 운영 복잡도가 상승합니다.
* **얻은 것 (Isolation):** 관측성 인프라의 과부하가 비즈니스 애플리케이션의 장애로 번지는 것을 100% 물리적으로 차단(Isolation)했습니다.

**[CTO 감사 방어 스크립트]**
* **CTO:** *"어차피 트레이스를 중앙으로 보낼 건데, 앱에서 바로 Gateway로 쏘면 되지 굳이 중간에 Agent를 둬서 네트워크 홉(Hop)을 늘리는 이유가 뭡니까?"*
* **수석 아키텍트:** *"네트워크 홉이 1회 늘어나지만, 그 대신 앱은 '자신의 노드(localhost)'에 있는 Agent로 데이터를 쏘기 때문에 네트워크 지연 없이 즉시 비즈니스 로직으로 복귀할 수 있습니다. 무거운 네트워크 통신과 재시도(Retry), 버퍼링은 모두 Agent가 백그라운드에서 대신 처리합니다. 앱의 레이턴시(Latency)를 보호하기 위한 가장 강력한 방어막입니다."*
