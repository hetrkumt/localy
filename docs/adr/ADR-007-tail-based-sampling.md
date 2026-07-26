# [ADR-007] 핀옵스 기반 지능형 꼬리 샘플링 (Tail-Based Sampling) 정책

**진행 시점:** Phase 2 (OTel Collector) 설계 완료 시점

## 1. 배경 및 물리적 위협 (Context & Threat)

**[배경]** 
하루 1,000만 건의 트랜잭션이 발생하는 MSA 환경에서 100%의 트레이스를 저장하면 막대한 스토리지 비용(AWS OpenSearch)이 발생합니다.

**[물리적 위협: 무작위 샘플링의 함정과 관측 공백]**
비용을 아끼기 위해 앱 단에서 `1% 무작위 샘플링(Head-Based Sampling)`을 적용하면 치명적인 위협이 발생합니다. 1%만 수집하므로, 정작 에러가 터졌을 때 해당 트레이스가 99%의 확률로 '버려진' 데이터일 수 있습니다. 인프라는 붕괴했는데 로그가 남아있지 않는 최악의 관측 공백(Observability Blind Spot)이 발생합니다.

## 2. 의사결정의 진화와 맹점 격파 (Evolutionary History)

**[순진했던 초기 설계]**
이 문제를 해결하기 위해 앱에서는 100%를 보내고, Gateway에서 '에러(500)는 100% 살리고, 정상(200)은 1%만 살리는' 꼬리 기반 샘플링(Tail-Based Sampling)을 적용했습니다.

**[레드팀(App Architect)의 융단폭격과 맹점 발견]**
부하 테스트 결과, 이 설계는 **[성능 장애(Slow Query) 추적 불가]**라는 거대한 맹점을 드러냈습니다. DB 인덱스가 깨져서 쿼리 응답에 15초가 걸렸어도, HTTP 응답 코드가 '200 OK'면 샘플러는 이를 정상으로 간주하고 99% 확률로 버립니다. 고객은 분통을 터뜨리는데 모니터링 시스템에는 아무것도 잡히지 않게 됩니다.

## 3. 삼위일체 대타협 코드 (The Concrete Fix)

이 맹점을 완벽히 메우기 위해, 에러뿐만 아니라 **"2초(2000ms) 이상 걸린 느린 정상 응답"**도 100% 살려내도록 Latency 정책을 결합했습니다. 또한 무한 메모리 대기를 막기 위해 `decision_wait`을 10초로 강제했습니다.

```yaml
# localy-manifests/platform/otel-collector/values-gateway.yaml
  processors:
    tail_sampling:
      decision_wait: 10s # [SRE Fix] 무한 대기로 인한 OOM 폭발 방지
      num_traces: 50000
      policies:
        - name: errors-only
          type: status_code
          status_code:
            status_codes: [ERROR]
        - name: slow-traces
          type: latency
          latency:
            threshold_ms: 2000 # [App Architect Fix] 2초 이상 지연된 200 OK 트레이스는 무조건 살림!
        - name: probabilistic-normal
          type: probabilistic
          probabilistic:
            sampling_percentage: 1
```

## 4. 아키텍트의 저울 및 방어 논리 (Trade-offs & Defense)

**[트레이드오프 (Trade-offs)]**
* **잃은 것 (Memory Cost):** 트레이스가 완전히 끝날지(에러가 날지 정상일지) 판독하려면 Gateway가 10초 동안 모든 스팬을 메모리에 쥐고 있어야 하므로, 엄청난 양의 RAM이 소모됩니다.
* **얻은 것 (Actionable Insight & Storage Cost):** 스토리지 저장 비용을 99% 깎아내면서도, 트러블슈팅에 필요한 '핵심 단서(Error & Slow Query)'는 100% 보존해 냈습니다.

**[CTO 감사 방어 스크립트]**
* **CTO:** *"Gateway 파드 하나당 메모리를 2Gi 씩이나 주는 건 너무 낭비 아닙니까? 그냥 앱 단에서 10% 정도 샘플링해서 쏘면 메모리 낭비를 줄일 수 있을 텐데요."*
* **수석 아키텍트:** *"메모리는 일시적인 비용(Transient Cost)이지만 스토리지는 영구적인 비용(Permanent Cost)입니다. 앞단에서 10% 무작위 샘플링을 하면, 새벽에 단 1건 발생한 치명적인 결제 오류가 하필 버려진 90%에 속해 영원히 미제 사건이 될 수 있습니다. Gateway의 메모리에 월 몇 만 원을 투자하는 것은, 수천만 원짜리 스토리지 비용을 아끼면서도 핵심 증거 데이터를 100% 확보하기 위한 가장 저렴한 보험입니다."*
