# CPU 동일 / 다른 커널 / 실제 CXL System-RAM 환경 기준 HybridTier Multi-tier Porting 계획서

## 1. 이번 계획의 전제

이번 계획은 기존 문서와 다른 아래 전제를 기준으로 한다.

- CPU는 기존과 동일한 계열을 사용한다.
- 커널은 artifact README가 가정하는 `6.2.0-hybridtier+`가 아니다.
- 메모리 계층은 `2-NUMA 에뮬레이션`이 아니라 `실제 CXL device`를 `daxctl reconfigure-device --mode=system-ram`으로 `System RAM / NUMA node`로 노출한 환경이다.

즉 이번 포팅은 더 이상 `memmap`으로 node 0 용량을 줄여 fast-tier를 흉내 내는 작업이 아니라, 실제 CXL capacity가 `DAX -> kmem -> memory hotplug -> NUMA node -> memory tier` 경로로 커널 페이지 할당자에 들어오는 환경을 대상으로 한다.

## 2. 무엇이 바뀌는가

이 전제 변화로 인해 기존 계획에서 가장 크게 달라지는 점은 세 가지다.

1. `특수 커널`의 의미가 줄어든다.
   - README도 런타임 자체는 특정 커널이 필수는 아니고, 기존 커널 수정은 `2-NUMA remote DRAM 에뮬레이션`을 위한 것이라고 설명한다. (`README.md:9-18`, `README.md:74-89`)
   - 실제 CXL system-ram이면 README의 `memmap` 기반 fast-tier 에뮬레이션 절차는 핵심 경로가 아니다.
2. `node0/node1` 가정이 완전히 깨진다.
   - 실제 CXL 메모리는 daxctl 결과의 `target_node`에 따라 node 2, node 3 등으로 노출될 수 있다.
   - 따라서 `fast=node0`, `slow=node1` 하드코딩은 거의 모두 다시 봐야 한다.
3. `remote_dram`이 곧 `CXL tier`라는 보장이 없어진다.
   - 같은 CPU라서 기존 raw event 인코딩 자체는 살아 있을 수 있지만, 실제 CXL 메모리 접근이 기존 `REMOTE_DRAM` 이벤트와 정확히 동일하게 관측된다는 보장은 없다.
   - CXL PMU도 존재하지만, 공식 문서상 sampling이 아니라 system-wide counting 전용이다.

## 3. 공식 문서 조사 요약

### 3.1 실제 CXL memory가 시스템 RAM으로 들어오는 경로

Linux CXL overview 문서는 CXL Type-3 메모리가 아래 경로로 노출된다고 설명한다.

1. Early boot에서 firmware가 `EFI_MEMORY_SP`, `Soft-Reserved`, `CFMWS`, `SRAT PXM` 정보를 제공한다.
2. NUMA node가 CEDT / SRAT proximity domain 기반으로 생성된다.
3. CXL driver가 region을 DAX region으로 surfacing 한다.
4. DAX driver가 해당 region을
   - `devdax`로 남기거나
   - `kmem`으로 변환해 memory hotplug 경로로 system RAM에 넣는다.
5. hotplug된 메모리 블록은 `/sys/bus/memory/devices` 아래에 나타나고 NUMA node에 연결되며, `ZONE_NORMAL` 또는 `ZONE_MOVABLE`로 online 된다.

출처:

- Linux kernel CXL overview
  - https://docs.kernel.org/next/driver-api/cxl/linux/overview.html
- Linux kernel DAX driver operation
  - https://docs.kernel.org/next/driver-api/cxl/linux/dax-driver.html

포팅 관점에서 중요한 해석은 아래다.

- 기존 artifact가 전제한 `remote DRAM으로 slow tier 흉내내기`와 달리, 실제 CXL 메모리는 부팅/펌웨어/NUMA/memory hotplug 파이프라인 전체가 메모리 계층 모델에 관여한다.
- 따라서 tier topology는 더 이상 `사용자 스크립트가 numactl로 흉내내는 것`이 아니라 `커널이 이미 인식한 NUMA node / memory tier`를 기준으로 잡아야 한다.

### 3.2 daxctl system-ram 경로에서 꼭 봐야 할 제약

`daxctl reconfigure-device` 공식 문서는 아래를 명시한다.

- `--mode=system-ram`은 DAX device를 hotplug memory로 바꿔 system memory에 넣는다.
- 기본 동작은 `online_movable` 정책이다.
- `--no-online`으로 자동 online을 끌 수 있다.
- `--no-movable`로 kernel zone에 올릴 수 있지만, 이후 hot-unplug 가능성을 떨어뜨릴 수 있다.
- `system-ram -> devdax` 복귀는 offline이 필요하고, 커널이 hot-unplug를 충분히 지원하지 않으면 reboot가 필요할 수 있다.
- 모드는 reboot 이후 기본적으로 persistence가 없고, 정책 파일을 별도로 써야 한다.

출처:

- daxctl reconfigure-device
  - https://pmem.io/ndctl/daxctl/daxctl-reconfigure-device.html

이 문서가 현재 HybridTier 포팅에 주는 의미는 다음과 같다.

- CXL 메모리가 `ZONE_MOVABLE`로 올라오면 huge page, kernel allocation, hot-unplug 가능성, reclaim 경로가 모두 영향을 받는다.
- 따라서 포팅 계획에는 `CXL tier를 online_movable로 둘지`, `online_kernel로 둘지`가 반드시 들어가야 한다.
- 이 선택은 구현보다 먼저 실험 정책으로 결정해야 한다.

### 3.3 memory hotplug 관점의 위험 요소

memory hotplug 문서는 아래를 설명한다.

- hotplug는 `추가(add)`와 `online` 두 단계다.
- hotunplug는 `offline`과 `remove` 두 단계다.
- hotplug memory는 `online_movable` 또는 `online_kernel`로 명시적으로 online 할 수 있다.
- memory hotplug는 “persistent memory, other performance-differentiated memory, reserved memory”를 ordinary system RAM으로 노출하는 데에도 사용된다.

출처:

- Linux kernel memory hotplug
  - https://docs.kernel.org/admin-guide/mm/memory-hotplug.html

HybridTier 입장에서 핵심 포인트는 다음이다.

- CXL system-ram 노드는 평범한 “node 1”이 아니라 memory hotplug 정책이 개입된 driver-managed memory다.
- 따라서 기존 코드가 기대하는 “slow tier도 일반 DRAM과 동일한 방식으로 free memory / THP / migration이 동작한다”는 가정은 재검증해야 한다.

### 3.4 CXL PMU는 telemetry용이지 현재 HybridTier sampling 대체재는 아님

Linux CXL CPMU 문서는 아래를 명시한다.

- CXL CPMU는 `perf` PMU로 노출된다.
- perf list / perf stat로 counting이 가능하다.
- `perf record`는 지원하지 않는다.
- task attach도 지원하지 않고 system-wide counting만 지원한다.

출처:

- Linux kernel CXL CPMU
  - https://docs.kernel.org/6.8/admin-guide/perf/cxl.html

따라서 CXL CPMU는 다음 용도로는 유용하다.

- 장치 수준 bandwidth / protocol traffic validation
- 실험 중 CXL activity sanity check

하지만 다음 용도로는 현재 HybridTier를 대체하지 못한다.

- 샘플 주소 기반 hot page 판별
- PEBS 주소 샘플링 대체

## 4. 현재 저장소 코드가 새 환경에서 깨지는 지점

### 4.1 커널 체크 / 커널 정책 강제

`run_exp_common.sh:395-443`는 아래를 가정한다.

- 특정 커널 버전이어야 한다.
- `zone_reclaim_mode=0`
- `numa_balancing=0`
- `demotion_enabled=0`
- `lru_gen=0x0000`

실제 CXL system-ram + 다른 커널 환경에서는 이 블록이 바로 문제다.

- 커널 버전 체크는 더 이상 맞지 않는다.
- 실제 CXL memory tier가 있는 시스템에서 커널 demotion path와 NUMA balancing을 무조건 꺼야 하는지도 다시 검토해야 한다.
- baseline 비교용으로는 꺼야 할 수 있지만, 환경 준비 단계에서 강제 전제처럼 두면 안 된다.

즉 `enable_hybridtier()`는 “환경 bootstrap 함수”가 아니라 “특정 artifact 실험용 정책 함수”로 격하해야 한다.

### 4.2 node0 / node1 하드코딩

실제 런타임은 아래를 강하게 가정한다.

- `NPBUFTYPES=2`, `LOCAL_DRAM_LOAD`, `REMOTE_DRAM_LOAD`: `tiering_runtime/hybridtier.cpp:55-57`
- fast tier 용량은 단일 `FAST_MEMORY_SIZE`: `tiering_runtime/hybridtier.cpp:62-86`
- fast tier free memory는 `/sys/devices/system/node/node0/meminfo`: `tiering_runtime/hybridtier.cpp:538-555`
- cold page demotion target은 항상 node 1: `tiering_runtime/hybridtier.cpp:674-680`, `tiering_runtime/hybridtier.cpp:1022-1028`
- promotion status도 사실상 node 0 / node 1만 의미 있게 처리: `tiering_runtime/hybridtier.cpp:924-938`

실제 CXL 환경에서는 CXL node가 node 1이 아닐 수 있고, 다중 CXL device면 node 2, 3, 4가 동시에 등장할 수 있다.

따라서 포팅 1순위는 `node0/node1` 제거다.

### 4.3 PFN 범위로 fast tier를 판정하는 경로

`tiering_runtime/hybridtier.cpp:167-171`는

- pagemap에서 PFN을 읽고
- `pfn < 0x8080000`이면 node 0 fast tier라고 가정한다.

이건 실제 CXL system-ram 환경에서 가장 먼저 깨질 가능성이 큰 부분이다.

이유:

- PFN 범위와 NUMA node의 관계는 플랫폼마다 다르다.
- 실제 CXL memory는 firmware / CXL decoder / hotplug 순서에 따라 물리 주소 배치가 달라질 수 있다.
- 다른 커널에서는 memmap placement와 folio metadata 배치도 바뀔 수 있다.

따라서 PFN threshold 방식은 제거하고, `move_pages(..., nodes=NULL, ...)` 또는 별도 page-location cache 기반으로 대체하는 것이 맞다.

### 4.4 numactl prefix가 실제 topology를 반영하지 못함

`run_exp_common.sh:461-490`는

- compute는 항상 `--cpunodebind=0`
- slow tier 초기 배치는 `--membind=1`

을 전제한다.

실제 CXL system-ram 환경에서는 다음이 모두 바뀔 수 있다.

- compute CPU node가 0이 아닐 수 있다.
- CXL node가 1이 아닐 수 있다.
- 여러 CXL node 중 어떤 tier를 초기 placement로 사용할지 결정이 필요하다.

즉 실행 스크립트는 `node ids를 topology 입력으로 받는 구조`로 바뀌어야 한다.

### 4.5 perf event 경로는 일부 유지 가능하지만 재검증이 필요함

유지 가능성이 있는 것:

- 같은 CPU면 raw event 인코딩 `0x1d3`, `0x2d3` 자체는 여전히 유효할 가능성이 있다. (`tiering_runtime/hybridtier.cpp:335-338`)
- 현재 샘플링 엔진은 `perf_event_open(PERF_TYPE_RAW)`를 쓰므로, perf tool의 symbolic alias보다 CPU PMU raw support에 더 직접 의존한다.

재검증이 필요한 것:

- 실제 CXL 접근이 이 raw event에서 어떻게 보이는지
- `REMOTE_DRAM`과 `REMOTE_CXL_MEM`이 분리되는 CPU인지
- 다른 커널/perf ABI에서 PEBS sampling이 동일하게 작동하는지
- `run_exp_common.sh:528-529`의 `perf stat` symbolic event명이 target kernel/perf에서 그대로 사용 가능한지

중요한 해석:

- “같은 CPU”는 좋은 조건이지만, “실제 CXL memory를 기존 remote_dram 이벤트로 그대로 판별할 수 있다”는 보장은 아니다.
- 따라서 event validation은 구현 착수 전에 별도 체크리스트로 빼야 한다.

## 5. 새 환경 기준 권장 포팅 전략

### 단계 A. 환경 탐지와 실험 기준선 정리

코드 수정 전에 아래를 수집해야 한다.

1. `cxl list -M -D -R`
2. `daxctl list -R -D`
3. `numactl -H`
4. `/sys/devices/system/node/node*/`
5. `/sys/devices/system/memory/auto_online_blocks`
6. `perf list | rg 'MEM_LOAD_L3_MISS_RETIRED|CXL|cxl_pmu'`
7. `dmesg | rg 'HMAT|SRAT|SLIT|CXL|Soft Reserved'`

이 단계의 산출물:

- 실제 DRAM node 목록
- 실제 CXL system-ram node 목록
- 각 node의 capacity / free memory / zone policy
- CPU PMU event 후보
- CXL CPMU 사용 가능 여부

### 단계 B. runtime을 “에뮬레이션 의존”에서 “실제 NUMA topology 의존”으로 전환

우선 다음 네 가지를 없애야 한다.

1. `node0/node1` 하드코딩
2. PFN threshold fast-tier 판정
3. 단일 `FAST_MEMORY_SIZE`
4. `get_node0_free_mem()` 단일 경로

권장 변경 방향:

- `TierDesc { tier_id, node_id, kind, capacity_bytes, free_mem_path, perf_source }`
- `RuntimeTopology { compute_nodes, dram_tiers, cxl_tiers, promotion_edges, demotion_edges }`
- `get_node_free_mem(node_id)`
- `page_current_node(addr)` helper

### 단계 C. sampling과 telemetry를 분리

실제 CXL 환경에서는 두 경로를 분리하는 것이 좋다.

1. 주소 샘플링 경로
   - 기존 CPU PEBS / raw PMU 기반
   - hot page 판별용
2. 장치 텔레메트리 경로
   - CXL CPMU / perf stat
   - CXL traffic sanity check용

이유:

- CXL CPMU는 counting은 되지만 sampling은 안 된다.
- 현재 HybridTier는 주소 샘플 기반 page migration 정책이 핵심이다.

즉 “CPU PMU로 hotness를 잡고, CXL PMU로 실험 검증을 보조”하는 구조가 더 현실적이다.

### 단계 D. multi-tier는 실제 node chain 기준으로 일반화

1차 구현 권장안:

- `tier0 = local DRAM`
- `tier1 = near CXL`
- `tier2 = farther CXL` 또는 추가 CXL node

정책:

- hot page는 인접 상위 tier로 승격
- cold page는 인접 하위 tier로 강등
- 각 boundary는 독립 watermark 보유

이 방식이 현재 HybridTier와 가장 잘 맞는다.

### 단계 E. huge page는 나중에 붙인다

이번 환경에서는 먼저 regular page 경로를 맞추는 것이 더 안전하다.

이유:

- CXL system-ram + hotplug + zone policy만으로도 변수가 많다.
- huge path는 별도 sketch / threshold / location filtering 로직이 있어서 debugging 표면적이 크다.

따라서 이번 개정 계획에서는

1. regular path
2. actual CXL node support
3. multi-tier generalization
4. huge path follow-up

순서를 권장한다.

## 6. 즉시 착수 우선순위

### P0

- `run_exp_common.sh`의 커널 버전 체크와 node0/node1 prefix 가정 제거 계획 수립
- target 환경 탐지 명령 집합 정리
- tier config 초안 정의

### P1

- `hybridtier.cpp` regular path에서
  - `get_node0_free_mem()` 제거
  - PFN threshold fast-tier 판정 제거
  - promotion/demotion target을 topology 기반으로 변경

### P2

- perf source abstraction 도입
- CPU PMU sampling event와 CXL telemetry event 분리
- multi-tier adjacency policy 도입

### P3

- `run_exp_common.sh`와 `run_*.sh`를 topology-aware 하게 확장
- `daxctl --mode=system-ram` 준비 절차와 실험 절차 문서화
- huge page 경로 이식

## 7. 가장 중요한 리스크

1. event semantics 리스크
   - 같은 CPU라도 실제 CXL memory가 기존 `REMOTE_DRAM`으로만 잡히지 않을 수 있다.
2. online policy 리스크
   - `online_movable` / `online_kernel` 선택에 따라 THP, hot-unplug, kernel allocation behavior가 달라진다.
3. topology drift 리스크
   - 실제 CXL node id는 고정 1이 아닐 수 있다.
4. kernel policy interaction 리스크
   - 커널의 NUMA balancing / demotion path와 user-space HybridTier가 충돌할 수 있다.
5. code duplication 리스크
   - regular path를 정리하기 전에 huge path까지 동시에 만지면 복잡도가 급증한다.

## 8. 결론

이번 전제에서는 포팅의 핵심이 바뀐다.

- 예전 핵심: `2-NUMA 에뮬레이션 위에서 HybridTier를 돌리기`
- 지금 핵심: `실제 CXL system-ram NUMA topology 위에서 HybridTier를 다시 topology-aware 하게 만들기`

따라서 다음 구현 단계의 출발점은 `커널 패치 복원`이 아니라 아래 두 가지다.

1. `실제 node topology를 읽는 runtime`
2. `PFN / node0 / node1 / remote_dram 고정 가정을 제거한 sampling + migration pipeline`

## 9. 참고 자료

- Linux kernel CXL overview
  - https://docs.kernel.org/next/driver-api/cxl/linux/overview.html
- Linux kernel DAX driver operation
  - https://docs.kernel.org/next/driver-api/cxl/linux/dax-driver.html
- daxctl reconfigure-device
  - https://pmem.io/ndctl/daxctl/daxctl-reconfigure-device.html
- Linux kernel memory hotplug
  - https://docs.kernel.org/admin-guide/mm/memory-hotplug.html
- Linux kernel CXL CPMU
  - https://docs.kernel.org/6.8/admin-guide/perf/cxl.html
- Linux kernel HMAT
  - https://docs.kernel.org/driver-api/cxl/platform/acpi/hmat.html
- Linux kernel CDAT
  - https://docs.kernel.org/driver-api/cxl/platform/cdat.html
- Linux `move_pages(2)`
  - https://man7.org/linux/man-pages/man2/move_pages.2.html
