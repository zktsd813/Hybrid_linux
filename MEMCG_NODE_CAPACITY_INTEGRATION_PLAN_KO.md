# Memcg Node-Capacity Integration Plan

## 목적

`/Serverless/Migration-friendly/linux`에 추가된 memcg 기반 per-node memory limiting 기능을
현재 `hybridtier-asplos25-artifact`에 효율적으로 적용하는 방안을 정리한다.

이 문서의 목표는 다음 두 가지다.

1. 기존 HybridTier의 전역 `FAST_MEMORY_SIZE_GB` 가정을 memcg 기반 per-cgroup fast-tier budget으로 대체한다.
2. 현재 HybridTier의 직접 `move_pages()` promotion/demotion 경로와 새 kernel 기능이 충돌하지 않도록 통합 순서를 정의한다.


## 핵심 결론

가장 현실적인 1차 방향은 다음이다.

1. kernel의 `memory.node_capacity` 계열 파일을 각 cgroup의 fast-tier budget authority로 사용한다.
2. HybridTier는 계속 cgroup당 1개 인스턴스로 동작한다.
3. 다만 현재 HybridTier는 `move_pages()`를 직접 호출하므로, kernel의 memcg promotion gate가 자동으로 적용되지 않을 가능성이 높다.
4. 따라서 1차 구현은 `kernel budget enforcement + user-space promotion pre-check`의 혼합형으로 가는 것이 안전하다.


## Migration-friendly Kernel 분석

### 노출된 cgroup v2 인터페이스

`CONFIG_NUMA_BALANCING_MT`가 켜진 kernel에서 다음 memcg 파일들이 추가되어 있다.

- `memory.node_capacity`
- `memory.node_low_wmark`
- `memory.node_high_wmark`
- `memory.node_force_lru_evict`
- `memory.node_balancing`
- `memory.numa_balancing_scan_period_scale`
- `memory.numa_balancing_hot_threshold_ms`
- `memory.kswapd_demotion_enabled`
- `memory.reclaimd_state`
- `memory.numa_migrate_state`

관련 구현:

- `mm/memcontrol.c`
- `include/linux/memcontrol.h`
- `Documentation/admin-guide/cgroup-v2.rst`

### 의미

코드를 보면 `memory.node_capacity`와 watermark 값은 `pages` 단위로 처리된다.

- `node_capacity`: memcg가 특정 NUMA node에서 사용할 수 있는 목표 용량
- `node_low_wmark`: background reclaim이 되돌릴 하한
- `node_high_wmark`: pressure 감지 및 promotion 차단/steering 기준

`memory.node_capacity`를 쓰면 low/high watermark가 같이 초기화된다.

- default low: capacity의 90%
- default high: capacity의 95%

즉 kernel은 per-cgroup per-node budget을 직접 들고 있으며, 기존 HybridTier처럼 사용자 공간이
`FAST_MEMORY_SIZE_GB`를 들고 node free memory만 보는 구조와는 출발점이 다르다.

### reclaim / demotion helper

kernel에는 memcg별 background reclaim worker가 추가되어 있다.

- `memcg_reclaimd_*`
- `memory.reclaimd_state`

또 `memory.kswapd_demotion_enabled`는 demotion / steering 모드를 선택한다.

- `0`: 비활성
- `1`: 기존 TPP 스타일
- `2`: high watermark 기반 stronger steering

mode `2`는 fast-tier node가 high watermark에 도달하면 새 charge와 promotion을 더 보수적으로 막고,
background reclaim도 low watermark까지 과하게 밀지 않고 high watermark까지 되돌리는 쪽이다.


## 현재 HybridTier 분석

### 이미 들어간 cgroup 지원

현재 regular-path HybridTier는 이미 다음 정도의 cgroup awareness를 가진다.

- 현재 프로세스의 cgroup 탐지
- cgroup당 leader 1개 선출
- `PERF_FLAG_PID_CGROUP` 기반 sampling
- `cgroup.procs` 기반 multi-pid scan

즉 "cgroup당 HybridTier 하나"라는 실행 모델과는 맞는다.

### 아직 전역 하드코딩인 부분

다음은 여전히 전역 가정이다.

- `FAST_MEMORY_SIZE_GB`를 컴파일 시 주입
- `FAST_MEMORY_SIZE`에서 `NUM_FAST_MEMORY_PAGES`, `SAMPLE_SIZE` 계산
- `ALLOC_WMARK`, `DEMOTE_WMARK`를 `FAST_MEMORY_SIZE`에서 계산

즉 현재는 cgroup-aware sampling은 있지만, fast-tier budget은 여전히 전역이다.

### 직접 `move_pages()` 사용의 의미

현재 HybridTier는 hot page promotion과 cold page demotion을 직접 `move_pages()` / `numa_move_pages()`로 수행한다.

이 점이 중요하다.

Migration-friendly kernel의 memcg promotion gate는 `mm/migrate.c`의 misplaced folio migration 경로에 들어가 있다.
즉 NUMA balancing 기반 migration에는 바로 적용되지만, 현재 HybridTier의 직접 `move_pages()` 경로에는
자동으로 걸리지 않을 가능성이 높다.

정리하면:

- kernel 기능은 "memcg budget을 안 넘도록 kernel migration/reclaim을 제어"한다.
- 하지만 HybridTier는 "사용자 공간에서 직접 migration syscall을 호출"한다.
- 따라서 kernel 기능만 켜고 HybridTier를 그대로 두면 budget enforcement가 느슨해질 수 있다.


## 통합 방식 후보

### 후보 A: control plane만 kernel로 이관

구성:

- 각 cgroup에 대해 `memory.node_capacity` / `node_low_wmark` / `node_high_wmark`를 설정
- HybridTier는 기존처럼 동작
- 다만 `FAST_MEMORY_SIZE_GB` 대신 현재 cgroup의 fast-node capacity를 읽어 local watermark를 계산

장점:

- 최소 diff
- 기존 HybridTier 구조 보존
- 실험 자동화 스크립트에 붙이기 쉬움

단점:

- 직접 `move_pages()` promotion은 여전히 user-space가 budget을 넘길 수 있음
- kernel reclaim과 user-space demotion이 중복될 수 있음

판단:

- 단독으로는 부족하다.

### 후보 B: kernel budget + user-space pre-check

구성:

- cgroup별 `memory.node_capacity`를 설정
- HybridTier는 promotion 직전에 현재 cgroup의 fast-node 사용량을 보고 budget 초과 여부를 검사
- 초과 예상 시 promotion batch를 줄이거나 중단
- demotion은 kernel reclaimd와 user-space demotion이 동시에 싸우지 않도록 backoff 규칙을 둠

장점:

- 현재 HybridTier 구조를 유지하면서도 memcg budget을 실질적으로 반영할 수 있음
- 직접 `move_pages()` 경로의 구멍을 user-space에서 막을 수 있음
- 단계적 전환이 가능

단점:

- `memory.numa_stat` 또는 대응 통계를 읽어야 하므로 user-space bookkeeping이 필요
- 완전한 single source of truth는 아님

판단:

- 현재 시스템에 가장 적합한 1차 통합 방식

### 후보 C: kernel-native tiering으로 수렴

구성:

- HybridTier의 직접 promotion/demotion 비중을 줄임
- memcg node balancing + reclaimd + NUMA balancing 기반 migration을 kernel에 맡김
- HybridTier는 threshold/advisor 역할만 수행

장점:

- 장기적으로 가장 깔끔함
- budget enforcement 일관성 우수

단점:

- 기존 실험 특성과 알고리즘 구현 방식이 크게 바뀜
- 검증 비용 큼

판단:

- 장기 방향으로는 맞지만, 1차 포팅 목표로는 과함


## 권장 방향

권장 방향은 후보 B다.

즉:

- cgroup별 fast-tier budget은 kernel memcg feature로 설정
- HybridTier는 그대로 cgroup당 1개 인스턴스
- direct `move_pages()` promotion에는 user-space pre-check 추가
- demotion은 점진적으로 kernel reclaimd 의존도를 높임


## 단계별 계획

### P0. Capability Probe

현재 시스템에서 먼저 확인할 것:

- target kernel에 `memory.node_capacity` 계열 파일이 실제로 노출되는지
- `CONFIG_NUMA_BALANCING_MT`가 켜져 있는지
- target fast node / slow node 번호
- 각 tenant cgroup의 `cpuset.mems.effective`
- `memory.numa_stat`가 fast node 사용량을 안정적으로 보여주는지

산출물:

- cgroup별 budget 설정 스크립트
- 환경 점검 스크립트

### P1. Script / Control Plane 통합

현재 실험 스크립트는 `FAST_TIER_SIZE_GB`만 받는다.
1차 통합에서는 이 입력을 당장 없애지 않고, 다음처럼 재해석한다.

- 기존 의미: 전체 시스템 fast tier 크기
- 새 의미: 해당 cgroup의 fast node budget

실행 전 단계에서 각 tenant cgroup에 대해 다음을 설정한다.

- `memory.node_capacity <fast_nid> <budget_pages>`
- `memory.node_low_wmark <fast_nid> <low_pages>` 또는 default 사용
- `memory.node_high_wmark <fast_nid> <high_pages>` 또는 default 사용
- `memory.kswapd_demotion_enabled 2`
- 필요 시 `memory.node_balancing`

이 단계에서는 runtime 코드는 최소 변경으로 유지한다.

### P2. HybridTier Runtime 통합

regular path 기준 변경점:

1. `FAST_MEMORY_SIZE_GB` fallback을 유지하되,
   현재 cgroup의 `memory.node_capacity`가 있으면 그 값을 우선 사용
2. `alloc_wmark`, `demote_wmark`를 전역 fast-tier 크기가 아니라
   cgroup fast-node capacity 기반으로 계산
3. promotion 직전에 현재 cgroup의 fast-node 사용량을 읽고,
   batch가 high watermark를 넘기면 promotion을 skip 또는 shrink
4. `reclaimd_state`를 읽어 reclaim가 이미 pending/running이면 aggressive demotion을 줄임

이 단계의 목표는:

- 기존 알고리즘을 최대한 유지
- fast-tier 총량만 memcg budget에 맞게 바꾸기

### P3. Policy 정리

P2 이후 정리할 것:

- kernel reclaimd가 충분히 동작하면 user-space demotion 강도를 줄이기
- `FAST_MEMORY_SIZE_GB`를 최종적으로 optional fallback으로 내리기
- huge path에도 동일 정책 반영


## 구현 상세 제안

### 1. 새 helper 추가

현재 runtime context에 다음 helper를 추가하는 것이 적절하다.

- 현재 cgroup의 `memory.node_capacity` 읽기
- 현재 cgroup의 `memory.node_high_wmark` 읽기
- 현재 cgroup의 `memory.node_low_wmark` 읽기
- `memory.numa_stat`에서 fast node 사용량 파싱
- `memory.reclaimd_state`에서 `running`, `pending_nodes`, `inflight_nodes` 파싱

### 2. fast-tier size 해석 변경

현재:

- `FAST_MEMORY_SIZE_GB -> FAST_MEMORY_SIZE -> watermarks`

변경:

- 우선순위 1: current cgroup `memory.node_capacity[fast_node] * PAGE_SIZE`
- 우선순위 2: fallback `FAST_MEMORY_SIZE_GB`

### 3. promotion pre-check

현재 direct promotion path는 pid별 `move_pages()`를 바로 호출한다.
그 전에:

- `fast_usage_pages = memory.numa_stat[fast_node] / PAGE_SIZE`
- `high_pages = memory.node_high_wmark[fast_node]`
- `remaining = high_pages - fast_usage_pages`

를 계산해서:

- `remaining <= 0` 이면 promotion skip
- batch size > remaining 이면 batch truncate

를 적용하는 것이 1차 구현으로 가장 단순하다.

### 4. demotion 충돌 완화

`kswapd_demotion_enabled=2` 사용 시 kernel reclaimd가 fast-tier 초과를 줄이려 한다.
따라서 user-space HybridTier demotion은 다음 조건에서 backoff하는 것이 좋다.

- `reclaimd_state.running == 1`
- `pending_nodes`에 fast node 포함
- 방금 직전 reclaim run이 있었음

즉 kernel reclaim가 이미 수행 중이면 user-space가 같은 목표를 중복 수행하지 않게 한다.


## 왜 이 방향이 효율적인가

이 방식은 기존 구조를 가장 덜 깨뜨린다.

- hook 구조 유지
- `PERF_FLAG_PID_CGROUP` sampling 유지
- 기존 hot/cold 분류 로직 유지
- 실험 스크립트 입력 형식도 크게 흔들지 않음

동시에 가장 문제였던 부분도 해결한다.

- 전역 `FAST_MEMORY_SIZE_GB` 하드코딩 완화
- cgroup별 fast-tier budget 적용
- kernel memcg reclaim helper 활용
- direct `move_pages()`와 kernel budget enforcement 간의 구멍을 user-space pre-check로 보완


## 리스크

### 1. kernel hook 적용 범위 차이

현재 확인된 memcg promotion block은 `mm/migrate.c`의 NUMA balancing migration 경로에 있다.
현재 HybridTier의 `move_pages()` 직접 호출이 이 훅을 그대로 타지 않을 가능성이 높다.

따라서:

- "kernel 기능을 켰으니 HybridTier direct promotion도 자동으로 budgeted일 것"이라고 가정하면 안 된다.

### 2. 통계 기반 pre-check의 race

`memory.numa_stat`는 실시간 절대값이지만, promotion batch 직전/직후 경쟁은 있을 수 있다.
그래서 batch truncate와 여유분 reserve가 필요하다.

### 3. huge path 미반영

현재 huge path는 regular path와 정책 동기화가 안 되어 있다.
regular path 통합 이후 별도 반영이 필요하다.


## 권장 구현 순서

1. cgroup launch/control-plane 스크립트에 `memory.node_capacity` 설정 추가
2. runtime에서 current cgroup의 node capacity / high watermark / numa_stat 읽기 helper 추가
3. promotion pre-check 추가
4. demotion backoff를 `reclaimd_state`와 연동
5. huge path 동일 포팅


## 최종 판단

현재 시스템에 이 kernel feature를 붙이는 가장 효율적인 방법은
`HybridTier를 버리고 kernel tiering으로 완전히 갈아타는 것`이 아니라,
`kernel memcg node budget을 control plane과 reclaim plane으로 사용하고,
HybridTier는 sampling/promotion advisor 역할을 유지하는 방식`이다.

즉 1차 목표는 다음 문장으로 요약된다.

`FAST_MEMORY_SIZE_GB 기반 전역 fast-tier 추정을 제거하고, 각 cgroup의 memory.node_capacity를 읽어 그 budget 안에서만 HybridTier가 promotion하도록 바꾼다.`
