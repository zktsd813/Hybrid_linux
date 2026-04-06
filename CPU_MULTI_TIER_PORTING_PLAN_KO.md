# CPU 기준 HybridTier Multi-Tier 포팅 계획서

## 1. 범위와 목적

- 작업 범위는 `/Serverless/Hybrid_linux` 내부 분석/문서화로 제한한다.
- 현재 저장소는 ASPLOS 2025 HybridTier artifact이며, 구현은 사실상 "Intel + 2 NUMA node + fast/slow 2-tier" 전제를 강하게 깔고 있다.
- 새 실험 전제는 다음과 같다.
  - CPU는 현재와 동일한 계열의 CPU를 사용한다.
  - 커널은 저장소 문서의 커널과 다르다.
  - 실제 CXL device를 `daxctl`로 `system-ram`에 붙여, NUMA node로 보이는 CXL memory에서 실험한다.
- 목표는 이 실제 CXL system-ram 환경에서 기존 CPU 기반 HybridTier를 "multi-tier 메모리 계층을 다룰 수 있는 형태"로 포팅하기 위한 설계/작업 계획을 정리하는 것이다.
- 이번 문서는 구현이 아니라 사전 계획 문서다. public API나 설정 포맷 변경은 아직 제안만 하고 실제 변경은 하지 않는다.
- 추가 실험 전제는 다음과 같다.
  - CPU는 기존과 같은 계열이지만, kernel은 이 저장소와 다르다.
  - 실제 CXL Type-3 memory를 `daxctl`로 `system-ram` 모드로 바꾼 뒤 NUMA node로 붙인 환경에서 실험한다.
  - 따라서 이전의 fake NUMA 에뮬레이션보다 hotplug, onlining, zone 선택, tier 생성 경로가 더 중요하다.

## 2. 병렬 분석 대상

- 런타임 regular path: `hybridtier-asplos25-artifact/tiering_runtime/hybridtier.cpp`
- 런타임 huge path: `hybridtier-asplos25-artifact/tiering_runtime/hybridtier_huge.cpp`
- 주입 경계: `hybridtier-asplos25-artifact/hook/hook.cpp`
- 실행/재현 계층: `hybridtier-asplos25-artifact/run_exp_common.sh`, `hybridtier-asplos25-artifact/run_*.sh`, `hybridtier-asplos25-artifact/README.md`
- 대안 알고리즘 비교군: `hybridtier-asplos25-artifact/tiering_runtime/arc.cpp`, `hybridtier-asplos25-artifact/tiering_runtime/twoq.cpp`

## 3. 현재 구조 요약

### 3.1 런타임 진입 구조

- `hook/hook.cpp:6-16`은 컴파일 시점 매크로로 `hybridtier.cpp`, `hybridtier_huge.cpp`, `arc.cpp`, `twoq.cpp` 중 하나를 직접 `#include` 한다.
- `hook/hook.cpp:29-82`는 `__libc_start_main`를 가로채고, `TARGET_EXE_NAME`와 일치하는 프로세스에서만 `perf_func()` 스레드를 띄운다.
- 즉 현재 구조는 "공용 라이브러리 + 런타임 설정 파일"이 아니라 "워크로드마다 다시 컴파일되는 LD_PRELOAD 훅" 방식이다.

### 3.2 regular path 핵심 흐름

- `tiering_runtime/hybridtier.cpp:335-340`에서 CPU별로 두 개의 perf event만 연다.
- `tiering_runtime/hybridtier.cpp:695-798`에서 LFU/momentum, 샘플 버퍼, 워터마크, migration batch를 초기화한다.
- `tiering_runtime/hybridtier.cpp:819-1235`가 메인 샘플 처리 루프다.
- 원격 메모리에서 샘플된 hot page는 node 0으로 승격한다. 실제 승격 대상 구성은 `tiering_runtime/hybridtier.cpp:915-970`에 있다.
- fast tier 여유 메모리가 부족하면 cold page를 찾아 node 1로 강등한다. 강등 스캔/이주는 `tiering_runtime/hybridtier.cpp:557-692`, `tiering_runtime/hybridtier.cpp:988-1125`에 있다.

### 3.3 huge path 핵심 흐름

- `tiering_runtime/hybridtier_huge.cpp:345-349`도 동일하게 두 개의 perf event만 연다.
- huge path는 `PAGE_SIZE=2MB` 기반이며 `frequency_sketch_block_huge.hpp`를 사용한다 (`tiering_runtime/hybridtier_huge.cpp:68-71`).
- regular와 거의 같은 알고리즘을 별도 파일로 복제해 놓았고, 일부 예외 처리만 다르다.
- huge path는 승격 전 `check_pages_on_node()`로 현재 node를 조회하는 로직을 추가했다 (`tiering_runtime/hybridtier_huge.cpp:733-752`, `tiering_runtime/hybridtier_huge.cpp:968-999`).

### 3.4 실행/실험 구조

- `run_exp_common.sh:33-143`가 공통 실행 경로다.
- `run_exp_common.sh:85-131`는 매 실행마다 `hook.so`를 다시 컴파일한다.
- `run_exp_common.sh:461-496`는 `numactl` 접두어를 설정한다.
- `run_*.sh`는 모두 `FAST_TIER_SIZE_GB`, `TIERING_SYSTEM`, `PAGE_TYPE` 세 인자만 받는다. 예: `run_cachelib.sh:11-24`, `run_gap.sh:9-23`, `run_silo.sh:10-22`.

## 4. 현재 구현에 박혀 있는 2-tier 가정

### 4.1 런타임 상수/배열 수준 하드코딩

1. `tiering_runtime/hybridtier.cpp:55-57`, `tiering_runtime/hybridtier_huge.cpp:55-57`
   `NPBUFTYPES=2`, `LOCAL_DRAM_LOAD=0`, `REMOTE_DRAM_LOAD=1`로 계층 수가 코드 상수로 고정되어 있다.
2. `tiering_runtime/hybridtier.cpp:98-99`, `tiering_runtime/hybridtier_huge.cpp:92-93`
   perf fd/ring buffer 배열이 `[NPROC][2]`로 선언되어 있다.
3. `tiering_runtime/hybridtier.cpp:786`, `tiering_runtime/hybridtier_huge.cpp:830`
   샘플 집계 해시맵도 정확히 두 종류의 메모리 접근만 기록한다.
4. `tiering_runtime/hybridtier.cpp:431-460`, `tiering_runtime/hybridtier_huge.cpp:449-479`
   hit ratio 계산이 local/remote 두 카운터만 가정한다.

### 4.2 perf 이벤트 구성의 2-tier/Intel 종속성

1. `tiering_runtime/hybridtier.cpp:337-338`, `tiering_runtime/hybridtier_huge.cpp:347-348`
   event `0x1d3`와 `0x2d3` 두 개만 연다.
2. `tiering_runtime/hybridtier.cpp:358-361`, `tiering_runtime/hybridtier_huge.cpp:368-371`
   샘플링 주파수 변경도 local/remote 두 카운터 분기만 있다.
3. `tiering_runtime/hybridtier.cpp:370-371`, `tiering_runtime/hybridtier_huge.cpp:380-381`
   perf stat도 `mem_load_l3_miss_retired.local_dram`, `remote_dram` 두 이벤트만 사용한다.
4. `README.md:85-90`
   문서도 Intel PEBS와 `MEM_LOAD_L3_MISS_RETIRED.{LOCAL,REMOTE}_DRAM` 기반 포팅만 설명한다.

### 4.3 NUMA node 번호 하드코딩

1. `tiering_runtime/hybridtier.cpp:676`, `tiering_runtime/hybridtier.cpp:1024`
   강등 대상 node가 무조건 `1`이다.
2. `tiering_runtime/hybridtier.cpp:769-771`
   승격 대상 node가 무조건 `0`이다.
3. `tiering_runtime/hybridtier_huge.cpp:712`, `tiering_runtime/hybridtier_huge.cpp:1063`
   huge path도 동일하게 강등은 node 1 고정이다.
4. `tiering_runtime/hybridtier_huge.cpp:968-983`
   huge path 승격 로직도 현재 slow tier를 node 1로 해석하고 node 0으로만 올린다.
5. `tiering_runtime/arc.cpp:66-83`, `tiering_runtime/twoq.cpp:82-103`
   대안 알고리즘도 0/1 양방향만 전제한다.

### 4.4 fast tier 판단 방식의 기계 종속성

1. `tiering_runtime/hybridtier.cpp:167-173`
   pagemap PFN이 `0x8080000` 미만이면 "node 0 fast tier"라고 간주한다.
2. `tiering_runtime/hybridtier_huge.cpp:165-172`
   huge path도 동일한 PFN 임계값을 사용한다.

이 부분은 multi-tier 이전에 먼저 깨야 할 하드코딩이다. PFN 범위로 계층을 유추하는 방식은 머신/부팅 구성/메모리 맵에 따라 바로 깨진다.

### 4.5 워터마크와 capacity 모델의 단일 fast tier 전제

1. `tiering_runtime/hybridtier.cpp:83-86`, `tiering_runtime/hybridtier_huge.cpp:77-80`
   `FAST_MEMORY_SIZE` 하나로 전체 정책을 계산한다.
2. `tiering_runtime/hybridtier.cpp:538-555`, `tiering_runtime/hybridtier_huge.cpp:538-555`
   free memory 조회도 오직 `node0`만 본다.
3. `tiering_runtime/hybridtier.cpp:973-1047`, `tiering_runtime/hybridtier_huge.cpp:1011-1082`
   승격 후 압박 판단, 강등량 계산, demotion throttle 모두 "top tier = node0" 단일 모델이다.

### 4.6 실험 스크립트/문서의 2-tier 전제

1. `README.md:9-16`, `README.md:62-72`, `README.md:85-90`
   문서가 명시적으로 "two NUMA node system", "node 0 fast", "node 1 slow"를 전제한다.
2. `run_exp_common.sh:38`, `run_exp_common.sh:46`, `run_exp_common.sh:70`
   설정 입력이 `FAST_TIER_SIZE_GB` 하나뿐이다.
3. `run_exp_common.sh:466-490`
   `numactl` 바인딩도 `--membind=0` 또는 `--membind=1`, `--cpunodebind=0`만 사용한다.
4. `run_cachelib.sh:22`, `run_gap.sh:23`, `run_silo.sh:22`, `run_xgboost.sh:21`, `run_speccpu_*.sh:21-22`
   workload 경로와 topology 가정이 고정되어 있다.

## 5. huge path와 regular path 차이 및 공통화 포인트

### 5.1 차이점

- page size: regular는 4KB (`hybridtier.cpp:74`), huge는 2MB (`hybridtier_huge.cpp:68`)
- CBF 구현: regular는 4-bit 카운터 (`frequency_sketch_block.hpp:33-46`), huge는 16-bit 카운터 (`frequency_sketch_block_huge.hpp:33-46`)
- threshold 튜닝: huge는 hot/momentum/plateau 관련 임계값이 regular와 크게 다르다. 예: `hybridtier_huge.cpp:179-184`, `hybridtier_huge.cpp:1180-1212`
- 승격 대상 필터링: huge는 `check_pages_on_node()`를 사용해 현재 node를 한 번 더 확인한다 (`hybridtier_huge.cpp:733-752`)

### 5.2 공통화 포인트

- perf 설정/링 버퍼 열기/닫기
- 샘플 batch 수집과 CBF 증가
- 승격 후보 선정 파이프라인
- free memory 기반 압박 감지
- cold page 스캔 루프
- second-chance demotion
- monitor mode / plateau 처리

즉 현재 구조는 "정책은 비슷한데 파일이 두 벌"이다. multi-tier 포팅 전에 공통 코어를 추출하지 않으면 regular/huge를 모두 N-tier로 각각 다시 구현하게 된다.

## 6. 외부 자료 조사 요약

### 6.1 Linux는 이미 memory tier 모델을 갖고 있다

- Linux NUMA emulation 문서는 `numa_emulation.adistance=`로 fake node마다 abstract distance를 주어 여러 memory tier를 만들 수 있다고 설명한다.
- 특히 abstract distance chunk가 128 단위라서, CPU-only 환경에서도 fake NUMA + distance 설정으로 다중 계층 실험이 가능하다.
- 다만 이번 포팅의 본선은 fake NUMA가 아니라 실제 CXL system-ram NUMA node다. fake NUMA는 smoke test와 회귀 확인용 보조 수단으로 두는 것이 맞다.
- 관련 자료:
  - Linux kernel NUMA emulation doc: `https://docs.kernel.org/next/mm/numa_emulation.html`

### 6.2 기본 page allocator는 local-first + fallback이다

- CXL page allocator 문서는 기본 메모리 정책이 "local NUMA node 우선, 압박 시 다른 node fallback"이라고 설명한다.
- 또한 zone 구성에 따라 어떤 느린 메모리는 direct allocation 대상에서 사실상 제외될 수 있다고 명시한다.
- 이는 multi-tier HybridTier에서 "promotion만 설계하면 된다"가 아니라, 기본 할당 정책/zone/cpuset과의 상호작용을 같이 봐야 함을 의미한다.
- 관련 자료:
  - Linux kernel page allocator/CXL doc: `https://docs.kernel.org/6.18/driver-api/cxl/allocation/page-allocator.html`

### 6.3 `move_pages()`는 이미 multi-node API다

- `move_pages(2)`는 page별 target node 배열을 받는다.
- `nodes == NULL`이면 이동 없이 현재 node를 조회할 수 있다.
- 다만 cpuset에 허용되지 않은 node는 `EACCES`, offline node는 `ENODEV`, target node 메모리 부족은 `ENOMEM`이 될 수 있다.
- 또한 `move_pages()`는 기존 memory policy를 강제하지 않으므로, 사용자 정책과 계층 정책이 충돌할 수 있다.
- 관련 자료:
  - man7 `move_pages(2)`: `https://man7.org/linux/man-pages/man2/move_pages.2.html`

### 6.4 `perf_event_open()`은 N-tier 샘플러 일반화의 핵심 인터페이스다

- `perf_event_open(2)`는 sampled event를 `mmap()` 버퍼로 읽는 구조를 제공한다.
- 현재 코드처럼 CPU별로 event fd를 열 수 있지만, 계층 수가 늘면 event 개수도 CPU 수에 비례해 증가한다.
- PEBS/precise sampling 가용성, event type availability, permission(`perf_event_paranoid`)이 중요한 제약이다.
- 관련 자료:
  - man7 `perf_event_open(2)`: `https://man7.org/linux/man-pages/man2/perf_event_open.2.html`

### 6.5 CXL/메모리 장치의 tier 판단은 결국 성능 좌표 기반이 되어야 한다

- CXL access coordinate 문서는 SRAT/HMAT/CDAT 기반으로 latency/bandwidth를 조합해 접근 성능을 계산한다고 설명한다.
- CPU-only multi-tier 포팅에서도 장기적으로는 "node 번호"가 아니라 "latency/bandwidth/abstract distance" 기반 계층 정의가 맞다.
- 관련 자료:
  - Linux kernel CXL access coordinates doc: `https://docs.kernel.org/driver-api/cxl/linux/access-coordinates.html`

### 6.6 실제 CXL Type-3 system-ram 경로는 fake NUMA와 다르다

- `daxctl reconfigure-device --mode=system-ram`은 device-dax 범위를 일반 메모리로 hotplug 하는 경로다. `--no-online`을 쓰면 hotplug만 수행하고, onlining은 별도 단계로 분리할 수 있다.
- `daxctl online-memory`는 이미 `system-ram`으로 바뀐 memory sections를 onlining 하는 도구다.
- NDCTL Quick Start와 `daxctl-reconfigure-device(1)`는 `system-ram` 모드가 기본적으로 `online_movable` 정책으로 online 될 수 있고, `auto_online_blocks` 또는 boot parameter가 이 동작을 바꿀 수 있다고 설명한다.
- Linux memory-hotplug 문서는 hotplug memory가 `OFFLINE`, `ZONE_NORMAL`, `ZONE_MOVABLE`로 도착할 수 있으며, `ZONE_MOVABLE`은 이동 가능한 할당만 수용한다고 설명한다.
- Linux page allocator 문서는 CXL capacity가 `ZONE_NORMAL` 또는 `ZONE_MOVABLE`에 놓이는지에 따라 직접 할당 가용성이 달라지고, 어떤 경우에는 demotion 경로로만 CXL memory를 쓰게 된다고 설명한다.
- 즉 실제 CXL device를 붙인 환경에서는 "node가 존재한다"보다 "그 node가 어떤 zone으로 onlined 되었는가"가 HybridTier 포팅에 직접적인 영향을 준다.
- CXL PMU 문서는 `cxl_pmu_mem<X>.<Y>` PMU가 `perf list`에 노출되고, counting 용도만 지원하며 `perf record` sampling 은 지원하지 않는다고 설명한다.
- 따라서 CXL memory 관측은 다음 두 경로를 분리하는 것이 맞다.
  - DRAM locality / page hotness sampling: 기존 Intel PEBS 기반 `LOCAL_DRAM` / `REMOTE_DRAM` 또는 플랫폼이 제공하는 동등 alias
  - CXL device traffic accounting: `cxl_pmu_mem<X>.<Y>` counting event
- 관련 자료:
  - NDCTL Quick Start: `https://docs.pmem.io/ndctl-user-guide/quick-start`
  - `daxctl-reconfigure-device(1)`: `https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-reconfigure-device`
  - `daxctl-offline-memory(1)`: `https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-offline-memory`
  - Linux memory-hotplug: `https://docs.kernel.org/6.18/driver-api/cxl/linux/memory-hotplug.html`
  - Linux page allocator and CXL allocation: `https://docs.kernel.org/6.18/driver-api/cxl/allocation/page-allocator.html`
  - Linux CXL PMU: `https://docs.kernel.org/6.8/admin-guide/perf/cxl.html`

## 7. 포팅 목표 구조 제안

### 7.1 권장 목표 모델

현재 2-tier 모델:

- top tier 1개
- bottom tier 1개
- promote: slow -> fast
- demote: fast -> slow

권장 multi-tier 모델:

- ordered tier list: `tier[0]`이 가장 빠르고, `tier[n-1]`이 가장 느림
- page마다 현재 tier를 식별
- promotion은 기본적으로 `current_tier -> current_tier - 1`
- demotion은 기본적으로 `current_tier -> current_tier + 1`
- 필요하면 정책 플래그로 direct jump를 허용
- 실제 CXL system-ram 환경에서는 `tier_id`와 `numa_node_id`를 분리해야 한다.
  - 예를 들어 local DRAM이 `node0`, CXL system-ram이 `node2`로 붙을 수 있다.
  - 그러므로 코드와 문서는 `node1 = slow tier` 같은 번호 가정을 버려야 한다.

adjacent migration을 기본으로 두는 이유:

- `move_pages()` 실패/ENOMEM 발생 시 rollback이 단순하다.
- event 해석과 hotness 임계값을 계층별로 독립 조절하기 쉽다.
- Linux memory tiering의 "next demotion node" 개념과도 맞는다.

### 7.2 새 내부 추상화 초안

```text
TierInfo
  - tier_id
  - numa_node_id
  - tier_role
  - capacity_bytes
  - alloc_wmark_bytes
  - demote_wmark_bytes
  - access_event / sampling_source
  - promotion_target_tier
  - demotion_target_tier

RuntimeConfig
  - tiers[]
  - cpu_list[]
  - page_granularity
  - hot_thresholds[]
  - momentum_thresholds[]
  - sample_freqs[]
  - batch_sizes

PageLocationTracker
  - query current node with move_pages(nodes=NULL)
  - map node -> tier

MigrationPlanner
  - select target tier
  - batch pages by destination node
  - retry / ENOMEM backoff

Sampler
  - one counter set per (cpu, tier-signal)
  - sampled_address_counts[tier]
```

핵심은 `NPBUFTYPES=2`를 없애고, "event 종류"와 "tier"를 분리하는 것이다. 일부 플랫폼은 tier 수보다 관측 가능한 event 수가 적을 수 있기 때문이다.

## 8. 구현 단계 제안

### Phase 0. 기준선 고정

- 실제 CXL Type-3 system-ram hotplug 후의 node/zone 상태를 먼저 기록
  - `daxctl list`
  - `numactl -H`
  - `lsmem`
  - `/sys/devices/virtual/memory_tiering/*` 또는 target kernel의 memory-tier sysfs
  - onlining policy와 block state
- 그 다음 현재 2-tier 동작을 그대로 유지하는 baseline 로그 수집
- `numastat`, `/proc/vmstat`, perf stat 출력을 저장하는 현 구조는 유지
- 목적: refactor 이후 behavior regression 판단 기준 확보

### Phase 1. 하드코딩 제거만 먼저 수행

- `node 0`, `node 1`, `FAST_MEMORY_SIZE`, `NPBUFTYPES=2`를 config 구조로 치환
- `get_node0_free_mem()`를 `get_node_free_mem(node_id)`로 일반화
- PFN cutoff 방식 제거
  - 최소안: `move_pages(nodes=NULL)` 기반 현재 node 조회로 대체
  - 이후 성능 문제 있으면 page-location cache 추가
- 실제 CXL node를 tier로 취급하도록 `TierInfo`에 `numa_node_id`, `zone_kind`, `online_policy`를 넣는다

이 단계 완료 조건:

- multi-tier는 아직 꺼져 있어도 됨
- 기존 2-tier를 config 기반으로 동일 동작시킬 수 있어야 함
- 실제 CXL system-ram 노드가 있어도 잘못된 zone 가정 없이 동일 동작해야 함

### Phase 2. 샘플러/마이그레이터 N-tier 일반화

- `perf_page[cpu][type]`를 동적 컨테이너로 전환
- `sampled_address_counts[2]`를 `sampled_address_counts[num_classes]`로 전환
- promotion/demotion 대상 node를 batch별로 구성
- local/remote hit ratio 계산을 "top-tier occupancy trend" 또는 "tier pair trend"로 재설계
- CXL PMU counting은 별도 accounting 채널로 두고, page sampling 경로와 분리

주의:

- 기존 hit ratio window는 2값(local/remote)만 받아서 slope를 계산한다.
- multi-tier에서는 최소한 다음 중 하나를 선택해야 한다.
  - top tier hit ratio만 추적
  - cumulative prefix hit ratio 추적
  - tier별 hit ratio 벡터를 따로 추적
- 실제 CXL 환경에서는 `LOCAL_DRAM/REMOTE_DRAM`만으로 CXL node traffic을 설명할 수 없을 수 있으므로, `LOCAL_CXL_MEM/REMOTE_CXL_MEM` 또는 `cxl_pmu_mem<X>.<Y>` 가능성을 검증해야 한다.

### Phase 3. 계층 정책 도입

- adjacent demotion 기본
- adjacent promotion 기본
- `tier[0]`만 특별 취급하던 watermark를 tier별 watermark로 분해
- cold page scanning도 "특정 tier에서 다음 tier로 내릴 페이지"라는 관점으로 일반화

### Phase 4. regular/huge 공통 코어 분리

- page size와 sketch 타입만 template/strategy로 분리
- shared control loop를 한 벌로 합치기
- huge 특이 로직은 별도 policy object로 주입

### Phase 5. 실행 스크립트 재설계

- `FAST_TIER_SIZE_GB` 단일 인자를 tier spec으로 대체하는 안을 설계
- 다만 public config format 변경은 사용자 확인 후 진행
- 우선은 backward-compatible wrapper를 권장
- 실험 스크립트에는 `daxctl list`, `cxl list`, `numactl -H`, `perf list` 검증 단계를 넣는다.

예시 초안:

```text
FAST_TIER_SIZE_GB=64
```

를 장기적으로는

```text
TIER_LAYOUT="0:64G,1:128G,2:rest"
```

또는

```text
TIER_NODES="0,2,5"
TIER_CAPS_GB="64,128,512"
```

형태로 바꾸는 방향이 적절하다.

### Phase 6. 검증

- 2-tier regression test
- 실제 CXL system-ram node의 onlined zone 차이(`ZONE_NORMAL` vs `ZONE_MOVABLE`) 검증
- 3-tier synthetic test
- huge/regular parity test
- cpuset 제한 시나리오
- `move_pages` ENOMEM/EACCES/ENODEV 처리 확인

## 9. 구현 전 선결정이 필요한 항목

1. multi-tier의 정확한 의미
   - 여러 NUMA node를 선형 tier로 볼지
   - 서로 다른 CPU socket local DRAM도 별도 tier로 볼지
2. CPU-only 실험 환경 구성 방식
   - 실 NUMA 하드웨어 사용
   - `numa=fake=` + `numa_emulation.adistance=`로 계층 에뮬레이션
   - 실제 CXL Type-3 memory를 `system-ram`으로 hotplug한 뒤 tiering
3. 계층 간 이동 정책
   - adjacent-only
   - direct jump 허용
4. hotness 모델
   - 단일 전역 hot threshold
   - tier별 threshold
   - page size별 threshold
5. sampling source 설계
   - tier마다 별도 perf event를 둘 수 있는지
   - 아니면 node residency 조회와 access hotness를 분리할지
   - CXL PMU counting을 sampling과 분리할지
6. 초기 배치 정책
   - 현재처럼 특정 slow tier에서 시작할지
   - tier별 interleave/membind/preferred-many를 사용할지
   - CXL memory를 `--no-online`으로 두고 수동 onlining할지
   - `online_movable`과 `online_kernel` 중 어떤 zone을 기본값으로 둘지
7. regular 먼저 할지 huge까지 동시에 할지
   - 권장: regular 먼저, huge는 2단계
8. 호환성 범위
   - 현재의 `run_*.sh <fast-mem-size> <tiering-system> <page-type>` 인터페이스를 당장 유지할지
   - 새 kernel에서 `daxctl list` / `numactl -H` / `/sys/devices/virtual/memory_tiering/*`를 기준 상태 점검에 포함할지

## 10. 리스크와 우선순위

### 우선순위 A: 먼저 깨야 하는 부분

1. PFN cutoff 기반 node 판정
2. node 0 / node 1 직접 참조
3. `NPBUFTYPES=2` 전제
4. `FAST_MEMORY_SIZE` 단일 capacity 모델

### 우선순위 B: 구조 리팩터링 없이는 계속 비용이 커지는 부분

1. regular/huge 제어 루프 중복
2. hook compile-time include 구조
3. `run_exp_common.sh`의 단일 fast-tier 입력 형식

### 예상 리스크

- perf event가 계층 수만큼 자연스럽게 매핑되지 않을 수 있음
- `move_pages()` 기반 현재 node 조회가 빈번하면 오버헤드가 커질 수 있음
- cpuset / container / zone 정책 때문에 "옮기고 싶어도 못 옮기는 node"가 생길 수 있음
- huge page는 node 판정/threshold/CBF 스케일이 regular와 달라 일괄 공통화가 쉽지 않음
- CXL PMU는 counting only라 현재 PEBS sampling 경로를 대체하지 못할 수 있음

## 11. 권장 첫 구현 슬라이스

가장 안전한 첫 슬라이스는 아래다.

1. 실제 CXL system-ram hotplug 환경에서 node/zone inventory 캡처
2. regular path만 대상으로 진행
3. 2-tier 동작은 그대로 유지
4. `node0/node1` 하드코딩 제거
5. PFN cutoff 제거
6. `TierInfo[2]` 기반으로 현재 로직을 재구성

이 슬라이스가 끝나면:

- 동작은 여전히 2-tier지만
- multi-tier 확장이 가능한 데이터 구조로 바뀌고
- 이후 huge/commonization/script 포팅이 훨씬 단순해진다

## 12. 다음 액션 제안

- 1차 구현 대상은 `tiering_runtime/hybridtier.cpp` regular path로 제한
- 먼저 실제 CXL node의 `TierInfo`를 구성하고, `RuntimeConfig` / `get_node_free_mem()` / `query_page_node()`를 추출
- 그 다음 `NPBUFTYPES=2` 제거와 migration planner 분리
- CXL system-ram의 `target_node`와 zone 정책을 반영하도록 `tier` 모델을 다시 정리
- huge path와 스크립트는 regular 경로가 안정화된 뒤 따라가는 순서가 적절하다

## 13. 참고 자료

- 저장소 내부
  - `hybridtier-asplos25-artifact/README.md`
  - `hybridtier-asplos25-artifact/tiering_runtime/hybridtier.cpp`
  - `hybridtier-asplos25-artifact/tiering_runtime/hybridtier_huge.cpp`
  - `hybridtier-asplos25-artifact/tiering_runtime/arc.cpp`
  - `hybridtier-asplos25-artifact/tiering_runtime/twoq.cpp`
  - `hybridtier-asplos25-artifact/hook/hook.cpp`
  - `hybridtier-asplos25-artifact/run_exp_common.sh`
- 외부 자료
  - NDCTL Quick Start: `https://docs.pmem.io/ndctl-user-guide/quick-start`
  - `daxctl reconfigure-device`: `https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-reconfigure-device`
  - `daxctl offline-memory`: `https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-offline-memory`
  - Linux memory hotplug: `https://docs.kernel.org/6.18/driver-api/cxl/linux/memory-hotplug.html`
  - Linux CXL page allocator: `https://docs.kernel.org/6.18/driver-api/cxl/allocation/page-allocator.html`
  - Linux CXL PMU: `https://docs.kernel.org/6.8/admin-guide/perf/cxl.html`
  - Linux kernel NUMA emulation: `https://docs.kernel.org/next/mm/numa_emulation.html`
  - Linux kernel CXL access coordinates: `https://docs.kernel.org/driver-api/cxl/linux/access-coordinates.html`
  - `move_pages(2)`: `https://man7.org/linux/man-pages/man2/move_pages.2.html`
  - `perf_event_open(2)`: `https://man7.org/linux/man-pages/man2/perf_event_open.2.html`

## 14. HybridTier 실험 운영 체크리스트

실제 CXL system-ram 환경에서는 아래를 먼저 확인해야 한다.

1. `daxctl list`로 대상 device의 `target_node`, `mode`, 용량, region을 먼저 기록한다.
2. `daxctl reconfigure-device --mode=system-ram`을 실행하기 전에 데이터 손실을 감안하고 백업 여부를 결정한다.
3. 자동 onlining이 필요 없으면 `--no-online`을 사용하고, udev가 새 memory block을 즉시 online하지 않는지 확인한다.
4. 가능하면 system-ram 메모리는 `online_movable`로 올려 hot-unplug 가능성을 유지한다.
5. `online_kernel` 또는 `ZONE_NORMAL`로 올라간 메모리는 나중에 offlining/hot-unplug가 어려울 수 있다.
6. `memoryXXX/state`, `auto_online_blocks`, `valid_zones`를 확인해 실제 zone과 onlining policy를 검증한다.
7. `daxctl offline-memory`와 `devdax` 복귀 경로가 동작하는지 미리 시험한다.
8. kernel이 kmem hot-unplug를 지원하지 않으면 `devdax` 복귀는 reboot이 필요할 수 있다.
9. `memmap_on_memory`와 local `ZONE_NORMAL` 여유를 확인해 folio/page table allocation 병목을 피한다.
10. `numactl -H`와 `/sys/devices/system/node/node*/meminfo`로 실제 CXL node 번호를 확인한 뒤, 코드의 `node0/node1` 가정을 모두 제거한다.
11. perf 이벤트가 `REMOTE_DRAM`만으로 충분한지 재검토하고, 필요하면 `REMOTE_CXL_MEM` / `LOCAL_CXL_MEM` 또는 `cxl_pmu_mem<X>.<Y>`로 교체한다.
12. benchmark process의 `cpunodebind`와 `membind`를 실제 node topology에 맞춘다.
