# HybridTier Porting Handoff

## 목적

이 문서는 새 대화나 다른 작업 컨텍스트에서 현재 포팅 상태를 빠르게 이어받기 위한 handoff 문서다.
분석 문서와 구현 상태, 남은 작업, 최소 검증 결과를 한 곳에 정리한다.

## 먼저 읽을 문서

1. `REAL_CXL_SYSTEM_RAM_PORTING_PLAN_KO.md`
   - 실제 CXL `system-ram` NUMA 환경 기준 포팅 전제와 topology 관련 분석
2. `MEMCG_NODE_CAPACITY_INTEGRATION_PLAN_KO.md`
   - memcg per-node budget 기능과 현재 HybridTier 통합 방향
3. `CPU_MULTI_TIER_PORTING_PLAN_KO.md`
   - 원래 CPU 기준 multi-tier 포팅 분석과 코드 하드코딩 위치
4. `CPU_REAL_CXL_SYSTEM_RAM_PORTING_PLAN_KO.md`
   - 동일 CPU / 다른 커널 / 실제 CXL system-ram 전제 재정리

## 현재 구현 상태

### 반영된 항목

- regular path가 cgroup-aware로 동작한다.
  - 현재 프로세스의 cgroup 탐지
  - cgroup당 leader 1개 선출
  - `PERF_FLAG_PID_CGROUP` 기반 sampling
  - `cgroup.procs` 기반 multi-pid demotion scan
- huge path도 같은 방향으로 포팅되어 있다.
- `node0/node1` 고정을 줄이기 위해 runtime topology detection을 넣었다.
- PFN 상수 기반 fast-tier 판정은 startup 시 node별 PFN range를 읽는 방식으로 바꿨다.
- promotion은 `owner_pid`별로 residency를 먼저 조회한 뒤 slow-tier 페이지에만 migration을 수행한다.
- memcg `memory.node_capacity` / `memory.node_high_wmark` / `memory.numa_stat` / `memory.reclaimd_state`를 읽어
  - startup fast-tier budget 결정
  - promotion pre-check
  - demotion backoff
  에 사용한다.
- 실험용 점검/launch 스크립트가 추가되어 있다.

### 현재 코드 기준 핵심 파일

- `tiering_runtime/runtime_context.hpp`
- `tiering_runtime/hybridtier.cpp`
- `tiering_runtime/hybridtier_huge.cpp`
- `run_exp_common.sh`
- `tools/test_real_cxl_multitenant_env.sh`
- `tools/test_real_cxl_multitenant_launch.sh`

## 현재 동작 모델

- 실행 모델은 `cgroup당 HybridTier 하나`다.
- 여러 cgroup이 동시에 존재할 수 있고, 각 cgroup 안에서는 leader 한 개만 tiering thread를 실행한다.
- 전역 공정성은 runtime이 직접 조정하지 않는다.
  - 실험자는 script에서 cgroup별 budget을 수동으로 맞추는 모델이다.
- fast-tier budget은 가능하면 각 cgroup의 `memory.node_capacity[fast_node]`에서 읽고,
  없으면 기존 `FAST_MEMORY_SIZE_GB`로 fallback 한다.

## 남은 작업

### 구현적으로 아직 남은 것

- runtime 중 `memory.node_capacity` 변경 시
  - `FAST_MEMORY_SIZE`
  - `NUM_FAST_MEMORY_PAGES`
  - `SAMPLE_SIZE`
  - user-space watermark
  를 자동으로 refresh하지 않는다.
- cgroup 간 전역 공정성 조정은 없다.
- 실제 target 환경에서 런타임 검증은 아직 하지 않았다.
- 커널에 memcg node-capacity 기능이 없는 경우에는 fallback 경로로만 동작한다.

### 코드 리스크 / 확인 필요 항목

- regular demotion scan의 `last_page_reached` 계산은 huge path와 단위가 다르게 보이므로 재검토가 필요하다.
- PFN range는 startup snapshot이라 memory hotplug 재구성 이후 stale할 수 있다.
- perf event가 실제 target CPU/CXL 환경에서 기대한 semantic으로 계속 들어오는지는 실험 검증이 필요하다.

## 최소 검증 결과

아래 수준까지만 확인했다.

- `bash -n run_exp_common.sh`
- `bash -n tools/test_real_cxl_multitenant_env.sh`
- `bash -n tools/test_real_cxl_multitenant_launch.sh`
- `g++ -std=c++17 -fsyntax-only -DHYBRIDTIER_REGULAR -DFAST_MEMORY_SIZE_GB=1 -DTARGET_EXE_NAME="dummy" hook/hook.cpp`
- `g++ -std=c++17 -fsyntax-only -DHYBRIDTIER_HUGE -DFAST_MEMORY_SIZE_GB=1 -DTARGET_EXE_NAME="dummy" hook/hook.cpp`

실제 benchmark run, perf 데이터 검증, migration correctness 실험은 아직 하지 않았다.

## 새 대화에서 바로 이어갈 때 추천 시작점

1. 이 문서와 `REAL_CXL_SYSTEM_RAM_PORTING_PLAN_KO.md`를 먼저 읽는다.
2. 현재 budget 모델이 script-managed fixed budget인지, runtime dynamic refresh까지 필요한지 결정한다.
3. 실제 target 환경 정보
   - `numactl -H`
   - `cxl list`
   - `daxctl list`
   - `perf list`
   - cgroup 경로와 `memory.node_capacity` 지원 여부
   를 확인한다.
4. 구현을 더 진행한다면 우선순위는 아래 순서가 맞다.
   - budget refresh
   - target kernel/runtime validation
   - residual demotion-scan correctness cleanup
   - 필요 시 global coordinator 설계

## Git 상태 메모

- 현재 작업은 `https://github.com/zktsd813/Hybrid_linux`의 `main`으로 push 가능한 상태를 전제로 정리됐다.
- 새 대화에서는 먼저 현재 브랜치와 remote 상태를 다시 확인하는 것이 안전하다.
