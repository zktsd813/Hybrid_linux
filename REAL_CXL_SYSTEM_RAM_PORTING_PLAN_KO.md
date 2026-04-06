# 실제 CXL System-RAM 환경 기준 HybridTier Multi-tier Porting 계획서

## 1. 이번 계획의 전제

- 실험 CPU는 기존 HybridTier가 가정한 것과 같은 CPU 계열을 사용한다.
- 커널은 artifact가 전제한 `6.2.0-hybridtier+`가 아니라 다른 커널을 사용한다.
- 느린 tier는 `2-NUMA 에뮬레이션`이 아니라 `실제 CXL Type-3 memory`를 `daxctl reconfigure-device --mode=system-ram`으로 시스템 메모리에 편입한 NUMA node다.
- 따라서 이번 포팅은 더 이상 “remote NUMA로 CXL을 흉내내는 코드”가 아니라 “실제 CXL system-ram NUMA topology에 맞는 코드”를 만드는 작업이다.

## 2. 핵심 결론

현재 저장소는 아래 가정에 강하게 묶여 있다.

- `README.md:10-16`
  - “two NUMA node system to emulate fast-tier and slow-tier CXL memory”
- `README.md:51-71`
  - `memmap=`으로 node0 DRAM 용량을 줄여 fast tier를 에뮬레이션
- `run_exp_common.sh:397-443`
  - 특정 HybridTier 커널 버전과 kernel tiering 비활성화 전제
- `tiering_runtime/hybridtier.cpp:170-171`, `tiering_runtime/hybridtier_huge.cpp:169-170`
  - PFN 범위로 node0 fast tier 판정
- `tiering_runtime/hybridtier.cpp:337-338`, `tiering_runtime/hybridtier_huge.cpp:347-348`
  - `LOCAL_DRAM` / `REMOTE_DRAM` 두 개 perf event만 사용
- `tiering_runtime/hybridtier.cpp:676`, `1024`, `769-770`
  - 강등은 항상 node1, 승격은 항상 node0

실제 CXL system-ram 환경에서는 위 가정 대부분이 더 이상 맞지 않는다.

즉, 이번 포팅의 핵심은 다음 4개다.

1. `에뮬레이션 전제 제거`
2. `실제 NUMA/CXL topology 발견 및 기술`
3. `event model 재설계`
4. `kernel/version 의존성 완화`

## 3. 공식 문서 기준으로 본 실제 CXL system-ram 경로

### 3.1 실제 CXL memory가 System RAM이 되는 경로

Linux CXL 문서는 CXL Type-3 memory가 최종적으로 사용자에게 두 방식으로 노출된다고 설명한다.

- DAX device 그대로 사용
- DAX kmem 경로를 통해 page allocator에 일반 메모리로 편입

출처:

- Linux CXL overview
  - https://docs.kernel.org/next/driver-api/cxl/linux/overview.html
- DAX driver operation
  - https://docs.kernel.org/driver-api/cxl/linux/dax-driver.html

핵심 포인트:

- `overview.html`은 `CXL -> DAX region -> dax device -> kmem conversion -> memory hotplug -> page allocator` 경로를 명시한다.
- `dax-driver.html`은 `dax_kmem`이 DAX device를 hotplug memory block으로 바꿔 page allocator에 편입한다고 설명한다.

이건 현재 README의 `memmap` 기반 에뮬레이션과 완전히 다른 경로다.

### 3.2 NUMA node와 memory tier는 부팅/펌웨어 정보에 의해 먼저 결정됨

Linux CXL early boot 문서는 다음을 명확히 말한다.

- Early boot에서 immutable resource, 특히 NUMA node가 먼저 정해진다.
- SRAT의 proximity domain(PXM)이 NUMA node 생성의 핵심이다.
- CEDT / SRAT / HMAT / CDAT 정보가 memory tier 구성에 영향을 준다.
- NUMA node는 runtime에 새로 만드는 게 아니라 `__init` 시점에 식별된다.

출처:

- Linux Init (Early Boot)
  - https://docs.kernel.org/next/driver-api/cxl/linux/early-boot.html
- ACPI Tables
  - https://docs.kernel.org/6.18/driver-api/cxl/platform/acpi.html

이번 포팅에서 의미하는 바:

- 더 이상 “node0=fast, node1=slow”를 코드에 박으면 안 된다.
- 실제 실험 머신의 ACPI/firmware가 만들어낸 NUMA node와 memory tier를 읽어야 한다.
- `daxctl`은 메모리를 online/offline 할 수 있지만 NUMA node를 새로 창조하지는 않는다.

### 3.3 daxctl system-ram 운영 방식

공식 `daxctl` 문서는 아래를 명시한다.

- `daxctl reconfigure-device --mode=system-ram`은 dax device를 일반 메모리로 hotplug한다.
- `--no-online`을 쓰면 reconfigure만 하고, onlining은 나중에 `daxctl online-memory`로 분리할 수 있다.
- 기본 onlining 정책은 `online_movable`.
- `--movable`이 기본이며, 이 경우 kernel allocation은 이 메모리를 잘 쓰지 않고 application use 위주가 된다.
- `--no-movable`은 일반 kernel allocation도 이 메모리를 쓰게 하지만, 이후 hot-remove 가능성을 낮춘다.
- `offline-memory`와 `--force` 기반 devdax 복귀는 hot-unplug 가능성과 커널 상태에 따라 제약이 있다.

출처:

- daxctl reconfigure-device
  - https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-reconfigure-device
- daxctl online-memory
  - https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/untitled-3
- daxctl offline-memory
  - https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-offline-memory

이번 포팅에서 의미하는 바:

- 실험 자동화는 `reconfigure -> online policy 결정 -> online-memory`를 분리하는 방향이 안전하다.
- `ZONE_MOVABLE`과 `ZONE_NORMAL` 선택이 성능과 제거 가능성에 직접 영향을 준다.

### 3.4 memory hotplug / page allocator 특성

Linux CXL 문서는 memory hotplug에서 아래 사항을 강조한다.

- hotplug memory는 `ZONE_NORMAL` 또는 `ZONE_MOVABLE`로 online될 수 있다.
- `ZONE_MOVABLE`은 kernel allocation을 거의 받지 않으며 hot-unplug 가능성을 유지한다.
- `memmap_on_memory`가 켜져 있으면 folio metadata가 고지연 메모리에 놓일 수 있어 성능 문제가 생길 수 있다.
- CXL memory는 “Driver Managed”로 분류되며 kexec에서 제외된다.
- default mempolicy는 local NUMA node 우선이며, 비로소 pressure 시 다른 node로 fallback한다.

출처:

- Memory Hotplug
  - https://docs.kernel.org/driver-api/cxl/linux/memory-hotplug.html
- The Page Allocator
  - https://docs.kernel.org/next/driver-api/cxl/allocation/page-allocator.html

이번 포팅에서 의미하는 바:

- HybridTier가 성능 tiering을 직접 하려면, 커널 기본 local-first 정책과 충돌하지 않도록 실험 환경을 명시적으로 통제해야 한다.
- `memmap_on_memory`는 실험 전에 반드시 확인할 운영 파라미터다.

## 4. 현재 코드/문서에서 실제 CXL이면 틀어지는 가정

### 4.1 README의 에뮬레이션 전제가 그대로 박혀 있음

- `README.md:10-16`
  - two NUMA node 에뮬레이션 전제
- `README.md:18-83`
  - HybridTier 전용 patched kernel + `memmap=` 기반 fast tier 축소 절차
- `README.md:51-71`
  - node0 DRAM을 잘라 fast tier 크기를 맞추는 절차
- `README.md:85-90`
  - real CXL일 때 perf event를 바꿔야 한다고만 쓰고, daxctl / system-ram / hotplug / zone 정책은 전혀 다루지 않음

실제 CXL system-ram 환경에서는 README의 “setup” 섹션 대부분이 주 경로가 아니게 된다.

### 4.2 run_exp_common.sh가 특정 커널과 2-node topology를 강제함

- `run_exp_common.sh:397-403`
  - `uname -r`이 특정 HybridTier 커널과 정확히 같아야만 실행
- `run_exp_common.sh:406-443`
  - kernel NUMA demotion, balancing, MGLRU를 일괄 비활성화
- `run_exp_common.sh:466-490`
  - `numactl --cpunodebind=0`, `--membind=1` 전제
- `run_exp_common.sh:528-529`
  - perf stat이 `local_dram`, `remote_dram` 두 이벤트만 기록

실제 CXL system-ram 기준으로는 다음이 문제다.

- 다른 커널이면 시작부터 실패한다.
- 실제 CXL node id가 1이 아닐 수 있다.
- CXL memory tiering을 kernel이 어떻게 보고 있는지 확인도 하기 전에 일괄 비활성화한다.
- NUMA binding이 실험 topology를 반영하지 못한다.

### 4.3 regular runtime이 PFN과 node0/node1에 고정돼 있음

실제 CXL 환경에서 가장 위험한 부분이다.

- `tiering_runtime/hybridtier.cpp:169-171`
  - `pfn < 0x8080000`이면 node0 fast tier라고 판단
- `tiering_runtime/hybridtier.cpp:538-555`
  - free memory는 오직 node0만 읽음
- `tiering_runtime/hybridtier.cpp:674-680`
  - demotion target은 무조건 node1
- `tiering_runtime/hybridtier.cpp:769-770`
  - promotion target은 무조건 node0
- `tiering_runtime/hybridtier.cpp:924-937`
  - `numa_move_pages(..., NULL, ...)` 결과를 node0 / node1 두 값만 의미 있게 사용

실제 CXL system-ram에서는 다음이 달라져야 한다.

- node id는 discovery 또는 설정에서 받아야 한다.
- PFN 범위로 fast tier 판정하면 안 된다.
- 현재 page 위치 판단은 `move_pages(status)` 기반으로 일반화해야 한다.
- free memory / watermark는 tier별이어야 한다.

### 4.4 huge runtime도 같은 문제를 복제하고 있음

- `tiering_runtime/hybridtier_huge.cpp:167-170`
  - PFN 범위로 node0 fast tier 판정
- `tiering_runtime/hybridtier_huge.cpp:537-554`
  - node0 free memory만 확인
- `tiering_runtime/hybridtier_huge.cpp:710-716`
  - demotion target은 node1
- `tiering_runtime/hybridtier_huge.cpp:968-983`
  - promotion은 node1에 있는 page만 골라 node0로 이동
- `tiering_runtime/hybridtier_huge.cpp:1061-1067`
  - second-chance demotion도 node1 고정

즉 huge path도 별도 포팅이 아니라 같은 topology abstraction을 공유해야 한다.

## 5. perf / PMU 관점에서 달라지는 점

### 5.1 같은 CPU라면 유지 가능한 부분

같은 Intel CPU 계열이라면 아래는 유지 가능성이 있다.

- PEBS 기반 샘플링
- `precise_ip=1`
- `PERF_SAMPLE_ADDR`를 사용하는 현재 user-space loop
- 기존 `LOCAL_DRAM` / `REMOTE_DRAM` raw event

다만 이건 `같은 CPU microarchitecture`라는 조건에서만 그렇다. 커널 버전이 달라도 PMU 하드웨어 자체는 같으므로 raw event 자체는 유지될 수 있다.

### 5.2 하지만 실제 CXL이면 event model은 재검증해야 함

Intel PerfMon 공식 문서에 따르면 최신 플랫폼은 다음 이벤트를 가진다.

- `MEM_LOAD_L3_MISS_RETIRED.LOCAL_DRAM`
- `MEM_LOAD_L3_MISS_RETIRED.REMOTE_DRAM`
- `MEM_LOAD_L3_MISS_RETIRED.REMOTE_CXL_MEM`
- `MEM_LOAD_RETIRED.LOCAL_CXL_MEM`

출처:

- Intel PerfMon Granite Rapids core events
  - https://perfmon-events.intel.com/platforms/graniterapids/core-events/core/

중요한 점:

- `LOCAL_DRAM`과 `REMOTE_DRAM`은 `DataLinearAddress`를 제공한다.
- 위 문서상 `REMOTE_CXL_MEM`은 `DataLinearAddress`가 빠져 있다.

이건 현재 HybridTier에 매우 중요하다.

현재 코드는 `PERF_SAMPLE_ADDR` 기반으로 virtual address를 받아 page 단위로 hot/cold를 추적한다. (`tiering_runtime/hybridtier.cpp:284`, `853-865`)

따라서 `REMOTE_CXL_MEM`이 실제 CPU에서 주소를 싣지 않는다면:

- `REMOTE_CXL_MEM`을 현재 코드에 그대로 drop-in replacement 할 수 없다.
- `LOCAL_DRAM` / `REMOTE_DRAM`로 계속 갈지
- 다른 load-latency event와 결합할지
- 샘플 소스와 page location cache를 조합할지

를 다시 설계해야 한다.

이 항목은 공식 문서를 바탕으로 한 핵심 리스크다.

### 5.3 CXL CPMU는 보조 계측용으로는 유용하지만 대체재는 아님

Linux CXL CPMU 문서는 다음을 말한다.

- CXL device는 `cxl_pmu_mem<X>.<Y>` 형태 perf PMU를 노출할 수 있다.
- CPMU는 discoverable counter를 제공한다.
- 하지만 system-wide counting만 지원하고, sampling과 task-attach는 지원하지 않는다.

출처:

- CXL Performance Monitoring Unit
  - https://docs.kernel.org/6.8/admin-guide/perf/cxl.html

즉 CPMU는:

- CXL traffic volume / bandwidth 검증
- 실험 후 정합성 확인

에는 좋지만, 현재 HybridTier의 `샘플 주소 기반 page migration`을 대체하지는 못한다.

### 5.4 로컬 호스트 기준으로 지금 확인된 사실

이번 작업 중 로컬 호스트에서 아래를 확인했다.

- `lscpu`
  - CPU는 `Intel Xeon Gold 6548N`이며 `pebs` 플래그가 있다.
- `numactl -H`
  - 현재 호스트는 `3`개 NUMA node를 보지만, `node2`는 CPU가 없고 메모리도 `0 MB`다.
- `perf list`
  - 현재 커널 `6.6.0-rc6`에 대응하는 `perf` 도구가 설치되지 않아 실행이 실패했다.

이 관찰이 주는 의미는 다음과 같다.

- 같은 CPU 계열이라면 PEBS 기반 샘플링 자체는 유지 가능성이 높다.
- 하지만 node id만 보고 실제 tier를 추정하면 안 된다. 메모리 없는 placeholder node가 있을 수도 있다.
- target 장비에서는 코드 포팅 전에 반드시 `kernel-matched perf tool` 설치 여부를 먼저 확인해야 한다.

`perf list` 실패 원인은 코드 문제가 아니라 “현재 커널 버전에 맞는 perf tool이 설치되지 않음”이었다.

## 6. 수정 방향

### 6.1 1차 목표

1차 목표는 “real CXL system-ram + 다른 커널”에서도 기존 HybridTier 정책이 돌아가도록 만드는 것이다.

이를 위해 우선 바꿔야 하는 것은 아래다.

1. topology discovery
2. event abstraction
3. kernel/script dependency 제거

### 6.2 topology abstraction

반드시 도입해야 하는 구조:

- `TierDesc`
  - `tier_id`
  - `node_id`
  - `kind` (`DRAM`, `CXL`, `OTHER`)
  - `capacity_bytes`
  - `alloc_wmark`
  - `demote_wmark`
- `RuntimeTopology`
  - `compute_nodes`
  - `fast_tiers`
  - `slow_tiers`
  - promotion/demotion adjacency

이 구조가 들어가면 아래 하드코딩을 제거할 수 있다.

- node0 / node1
- PFN upper bound
- 단일 `FAST_MEMORY_SIZE`
- local/remote 두 종류만 있는 bucket

### 6.3 page location 판단은 PFN이 아니라 status 기반으로

실제 CXL node는 물리 주소 범위가 기존 에뮬레이션과 다르므로 PFN 상수는 폐기해야 한다.

대신 아래 방식이 필요하다.

- `numa_move_pages(..., nodes=NULL, status=...)`로 현재 node 확인
- 샘플 주소에 대한 location cache 유지
- demotion scan에서도 “현재 tier가 fast tier인가”를 status 기반으로 판단

이 방식은 이미 current code의 promotion debug path가 부분적으로 쓰고 있다. (`tiering_runtime/hybridtier.cpp:924-937`)

즉 완전히 새로운 접근이 아니라 기존 코드의 더 이식성 있는 경로를 승격시키면 된다.

### 6.4 event abstraction

권장 방향:

- `PerfSourceDesc`
  - `name`
  - `raw_config`
  - `requires_addr`
  - `tier_hint`
- 시작 시점 self-check
  - `perf list` 또는 설정된 raw event 열기 가능 여부 확인
  - event가 주소를 주는지 여부 확인

권장 1차 전략:

1. 같은 CPU라는 점을 이용해 기존 `LOCAL_DRAM` / `REMOTE_DRAM`을 baseline으로 유지
2. 실제 CXL device 환경에서 샘플 page의 current node를 추가 확인
3. 추후 CPU가 `LOCAL_CXL_MEM` / `REMOTE_CXL_MEM`를 제공하고 주소도 usable하면 event map 확장

### 6.5 kernel/version dependency 완화

현재 `run_exp_common.sh`는 특정 kernel version과 exact sysctl 상태를 전제한다.

실제 CXL 환경용으로는 아래처럼 바뀌어야 한다.

- `kernel version equality check` 제거
- 대신 capability check 도입
  - `daxctl` 존재
  - target node 존재
  - `move_pages` 동작
  - required perf event open 가능
- kernel tiering 관련 sysctl은 “무조건 0”이 아니라 `실험 모드`에 따라 제어

권장 실험 모드:

- `hybridtier-exclusive`
  - AutoNUMA / kernel demotion 비활성화
- `hybridtier-vs-kernel`
  - kernel demotion baseline 유지, HybridTier는 측정용 또는 비교군

## 7. Multi-tenant / multiple cgroup 확장

이번 전제에서는 `multi-tenant`와 `multiple cgroup`이 단순 부가 요구가 아니라 핵심 제약이다. 즉, tier policy는 프로세스 단위가 아니라 `cgroup 단위`로 분리되어야 한다.

### 7.1 현재 코드가 multi-cgroup에 약한 이유

- `hook/hook.cpp:55-79`는 실행 파일 이름 하나로 타깃을 골라 `perf_func()` 스레드를 하나만 띄운다.
- `tiering_runtime/hybridtier.cpp:707`, `tiering_runtime/hybridtier_huge.cpp:761`는 `getpid()`로 현재 프로세스만 대상으로 삼는다.
- `tiering_runtime/hybridtier.cpp:570-630`, `tiering_runtime/hybridtier_huge.cpp:626-671`는 `/proc/<pid>/maps`, `/proc/<pid>/pagemap`을 현재 PID 하나에 대해서만 스캔한다.
- `hybridtier.cpp`와 `hybridtier_huge.cpp`는 전역 LFU/momentum, 전역 migration queue, 전역 fast-tier watermark를 사용한다.
- `run_exp_common.sh`는 단일 workload를 한 번에 하나만 실행하는 방식에 가깝고, tenant별 정책 상태를 별도로 유지하지 않는다.
- `tiering_runtime/hybridtier.cpp:299-304`, `tiering_runtime/hybridtier_huge.cpp:300-305`는 `perf_event_open(..., pid=-1, cpu=i, ...)`로 CPU 기준 system-wide 샘플링을 수행한다.
- `tiering_runtime/hybridtier.cpp:924-948`, `tiering_runtime/hybridtier_huge.cpp:738`, `982-983`는 `numa_move_pages(0, ...)`로 현재 프로세스 기준 migration만 수행한다.

이 구조는 여러 cgroup이 동시에 실행될 때 다음 문제를 만든다.

- 서로 다른 cgroup의 hotness가 섞여서 잘못된 승격이 일어난다.
- 하나의 tenant가 다른 tenant의 fast tier 예산을 잠식할 수 있다.
- memory charge가 과거 cgroup에 남아 있는데도 프로세스만 옮겼다고 정책이 끝났다고 착각할 수 있다.
- 더 심각하게는, 다른 cgroup에서 수집한 샘플 주소를 현재 프로세스의 주소처럼 해석할 수 있다.
- 즉 현재 구조는 single-tenant 또는 CPU exclusivity가 강하게 보장된 환경에서는 버틸 수 있어도, multi-tenant 일반 환경에서는 오동작 가능성이 높다.

### 7.2 cgroup 단위로 새로 정의해야 할 것

반드시 필요한 추상화:

- `TenantDesc`
  - `cgroup_path`
  - `cgroup_fd`
  - `cpuset_cpus_effective`
  - `cpuset_mems_effective`
  - `memory_budget_bytes`
  - `tier_budget_bytes`
  - `perf_group_fd`
- `TenantPolicyState`
  - tenant별 hot threshold
  - tenant별 momentum threshold
  - tenant별 migration queue
  - tenant별 second-chance queue
  - tenant별 watermark
  - tenant별 active pid / pidfd set
  - tenant별 page ownership cache

이 구조를 두면 tiering 정책을 `tenant x tier` 이중 축으로 분리할 수 있다.

### 7.2.1 저장소 안에서 이미 보이는 cgroup 관련 흔적

이 저장소에는 memcg를 독립 제어 대상으로 본 흔적이 있다.

- `memtis/scripts/set_htmm_memcg.sh:16-27`
  - cgroup v2의 `memory`, `cpuset` subtree를 켜고 `memory.htmm_enabled`를 tenant별로 토글한다.
- `memtis/scripts/set_htmm_memcg.sh:19-21`
  - PID를 `cgroup.procs`에 넣고 `cpuset.cpus`를 설정한다.
- `memtis/scripts/set_mem_size.sh:20-37`
  - `memory.max_at_node<N>`로 node별 예산을 제한한다.
- `memtis/scripts/run_bench.sh:141-145`
  - 실험마다 `htmm` cgroup 하나를 만들고 DRAM node 예산을 설정한다.

재사용 가능한 아이디어:

- tenant를 cgroup 객체로 본다는 점
- tenant별 node budget 인터페이스
- tenant별 cpuset 초기화 루틴

그대로 재사용하면 안 되는 점:

- `set_htmm_memcg.sh:20-21`는 CPU 범위를 하드코딩한다.
- `run_bench.sh:141-145`는 cgroup 이름을 하나(`htmm`)만 쓰므로 multi-tenant 동시 실행을 전혀 다루지 않는다.
- `memory.htmm_enabled`, `memory.max_at_node<N>`는 HTMM 전용 커널 인터페이스일 가능성이 높아 일반 HybridTier 포팅의 공용 API로 가정하면 안 된다.

### 7.3 perf는 cgroup 단위로 필터링해야 함

man page 기준으로 `PERF_FLAG_PID_CGROUP`는 per-container system-wide monitoring을 활성화한다. 이때 이벤트는 `pid` 자리에 넣은 cgroup 파일 디스크립터에 대해, 해당 CPU에서 실행 중인 해당 cgroup의 thread에 대해서만 측정된다. 이 모드는 system-wide event일 때만 의미가 있다.

따라서 multi-tenant 환경에서는 다음이 필요하다.

1. cgroup마다 별도의 perf event set을 만든다.
2. `PERF_FLAG_PID_CGROUP` 또는 perf cgroup filtering을 사용한다.
3. 결과를 cgroup path 기준으로 집계한다.
4. CPU별 ring buffer를 `tenant x cpu x perf source` 축으로 관리한다.
5. 가능하면 `LD_PRELOAD` 내부 thread보다 외부 `cgroup-scoped manager`가 perf fd를 소유하는 쪽을 우선 검토한다.

관련 공식 문서:

- `perf_event_open(2)`의 `PERF_FLAG_PID_CGROUP`
  - https://man7.org/linux/man-pages/man2/perf_event_open.2.html
- cgroup v2의 perf_event controller
  - perf events can always be filtered by cgroup v2 path
  - https://docs.kernel.org/6.6/admin-guide/cgroup-v2.html

### 7.4 cpuset은 “요청값”이 아니라 “effective 값”을 봐야 함

cgroup v2 문서에 따르면:

- `cpuset.cpus.effective`와 `cpuset.mems.effective`는 실제로 부모로부터 허용된 onlined CPU/node만 보여준다.
- `cpuset.mems`를 설정하면 해당 cgroup의 task memory가 지정 노드로 migrate될 수 있다.
- 이 migration은 비용이 있고, 완료되지 않을 수도 있다.
- `cpuset.mems.effective`는 memory hotplug 이벤트의 영향을 받는다.

따라서 multi-tenant CXL 계획에서는 항상 다음을 기준으로 삼아야 한다.

- `cpuset.cpus.effective`
- `cpuset.mems.effective`
- `memory.numa_stat`
- 필요하면 `memory.low`, `memory.high`, `memory.max`

공식 문서:

- https://docs.kernel.org/6.6/admin-guide/cgroup-v2.html

해석:

- tenant가 요청한 `cpuset.mems`보다 실제 `cpuset.mems.effective`가 더 좁을 수 있다.
- `cpuset.mems`를 바꾸면 memory migration이 일어나지만 비용이 크고 일부 페이지는 남을 수 있다.
- 따라서 HybridTier migration planner는 “원하는 tier”보다 먼저 “tenant가 실제로 접근 가능한 node 집합”을 계산해야 한다.

### 7.5 move_pages와 NUMA policy는 cpuset에 의해 제한됨

`move_pages(2)`는 페이지를 특정 node로 옮길 수 있지만, 다음 제약이 있다.

- target node가 current cpuset에서 허용되지 않으면 `EACCES`
- target node가 online이 아니면 `ENODEV`
- `move_pages()`는 `mbind(2)` / `set_mempolicy(2)`로 정해진 memory policy를 강제하지 않는다
- 즉 destination node는 policy보다 cpuset의 영향을 더 직접적으로 받는다

공식 문서:

- https://man7.org/linux/man-pages/man2/move_pages.2.html

포팅 의미:

- tenant별 허용 node가 다르면 migration edge도 tenant별로 달라져야 한다.
- 하나의 global migration planner로 모든 cgroup을 동시에 옮기면 `EACCES`와 `ENODEV`가 빈번해질 수 있다.
- `cpuset.mems.effective` 또는 `get_mempolicy(MPOL_F_MEMS_ALLOWED)`로 tenant별 allowed node를 먼저 줄여야 한다.

### 7.6 memory charge migration은 process migration과 별개

cgroup v2 문서의 핵심 문장은 이렇다.

- process를 다른 cgroup으로 옮겨도, 그 process가 이전 cgroup에서 생성한 memory usage는 따라가지 않는다.
- memory는 그것을 생성한 cgroup에 계속 charged 된다.

즉 multi-tenant에서는 다음을 분리해야 한다.

- `process placement`
- `memory charge ownership`
- `page location`

공식 문서:

- https://docs.kernel.org/6.6/admin-guide/cgroup-v2.html

이 점 때문에 `tenant migration`은 단순한 task 이동이 아니다. page ownership과 charge ownership을 같이 보고, 필요하면 cgroup별 charge accounting을 기준으로 policy를 다시 계산해야 한다.

또한 shared page cache나 공유 매핑은 시간에 따라 어느 cgroup에 charge되는지가 달라질 수 있으므로, 단순 PID 소속만으로 tenant page를 정의하면 안 된다.

### 7.7 memcg 단위 페이지 식별은 `/proc/kpagecgroup`을 같이 써야 함

현재 HybridTier는 `pagemap -> virtual address -> migrate` 경로만 본다. multi-tenant에서는 이걸 그대로 쓰면 다른 cgroup의 페이지가 섞일 수 있다.

공식 문서 기준으로:

- `/proc/kpagecgroup`는 PFN별 memory cgroup inode 번호를 제공한다.
- idle page tracking 문서는 workload가 memcg로 표현될 때 alien page를 걸러내기 위해 `/proc/kpagecgroup`를 함께 쓰라고 설명한다.

공식 문서:

- https://docs.kernel.org/admin-guide/mm/pagemap.html
- https://docs.kernel.org/admin-guide/mm/idle_page_tracking.html

포팅 의미:

- `virtual address -> PFN -> kpagecgroup inode -> tenant(memcg)` 매핑이 있어야 cgroup별 hotness와 demotion 후보를 분리할 수 있다.
- 특히 여러 프로세스가 하나의 cgroup을 공유할 때는 per-process view보다 memcg charge view가 더 안정적인 tenant 경계가 된다.

### 7.8 권장 구현 모드

multi-tenant 요구사항을 만족시키는 구현 모드는 사실상 두 가지다.

1. `과도기 모드`
   - 현재 `LD_PRELOAD` 방식을 유지하되, 각 프로세스가 자기 cgroup path를 읽고 tenant-tagged 상태를 별도로 기록한다.
   - 장점: 기존 regular path와 diff가 작다.
   - 단점: 한 cgroup에 프로세스가 여러 개면 상태가 중복되고, fast-tier budget을 tenant 단위로 통합하기 어렵다.
2. `권장 모드`
   - cgroup 단위 controller/daemon이 cgroup fd를 잡고 `PERF_FLAG_PID_CGROUP`로 샘플링하고, tenant별 상태와 budget을 중앙에서 관리한다.
   - tenant에 속한 PID 목록은 `cgroup.procs` 또는 pidfd 집합으로 유지한다.
   - 실제 `move_pages(pid, ...)` 호출은 tenant 소속 PID별 주소공간에 대해 수행한다.

최종 목표는 2번이다. 1번은 `regular path P0/P1`을 빠르게 검증하는 과도기 경로로만 적합하다.

### 7.9 multi-tenant용 운영 체크포인트

구현 전에 각 cgroup에 대해 아래를 확인해야 한다.

1. `cgroup path`와 `cgroup fd`
2. `cpuset.cpus.effective`
3. `cpuset.mems.effective`
4. `memory.numa_stat`
5. `memory.current`
6. perf cgroup filtering 가능 여부
7. `move_pages()`가 해당 cgroup의 cpuset 허용 node에서 성공하는지
8. `memory.low`, `memory.high`, `memory.max`가 tenant 보호/스로틀 정책과 충돌하지 않는지

### 7.10 권장 정책

권장 1차 정책은 다음과 같다.

- tenant별 tier budget을 둔다.
- tenant별 hotness/momentum state를 분리한다.
- tenant별 migration queue를 따로 둔다.
- global planner는 있더라도 최종 실행은 `tenant policy + cpuset effective nodes`를 통과해야 한다.
- `memory.numa_stat`와 `cpuset.mems.effective`를 tenant별 telemetry의 기본값으로 둔다.
- `memory.low`는 tenant 보호 예산, `memory.high`는 tenant throttling 예산의 후보로 검토한다.
- page ownership 식별은 `pagemap`만 보지 말고 `/proc/kpagecgroup`를 함께 써서 memcg 경계를 먼저 자른다.
- idle page tracking은 tenant-local working set 추정에만 쓰고, 다른 cgroup의 alien page가 섞이지 않았는지 `kpagecgroup`로 먼저 확인한다.

## 8. 운영 체크리스트

구현 전, 실제 머신에서 아래를 확인해야 한다.

1. CXL memory가 어떤 경로로 surfacing 되는지
   - 이미 early boot에 SystemRAM인가
   - Soft Reserved로 잡힌 뒤 daxctl로 system-ram 전환하는가
2. `daxctl reconfigure-device --mode=system-ram --no-online` 가능 여부
3. `daxctl list`에서 target NUMA node 확인 가능 여부
4. `/sys/devices/virtual/memory_tiering/memory_tierN/nodelist`로 tier membership 확인
5. `auto_online_blocks`, `CONFIG_MHP_DEFAULT_ONLINE_TYPE`, `memhp_default_state` 확인
6. `memmap_on_memory` 설정 확인
7. `perf list` 또는 raw open으로 필요한 PMU event 확인
8. target kernel에 맞는 `perf` userspace tool 설치 여부 확인
9. 각 tenant(cgroup)의 `cpuset.cpus.effective`와 `cpuset.mems.effective` 확인
10. 각 tenant의 `memory.numa_stat`와 `memory.current` 확인
11. cgroup path 기반 perf filtering이 실제로 동작하는지 확인
12. `move_pages()`가 tenant별 허용 node에서 성공하는지 확인
13. `/proc/kpagecgroup`와 idle page tracking 경로가 tenant-local page만 보고 있는지 확인

이 체크리스트가 통과돼야 코드를 porting 할 가치가 있다.

## 9. 구현 우선순위

### P0

- real CXL 환경 capability probe 설계
- `TierDesc`, `PerfSourceDesc` 설계
- `TenantDesc`, `TenantPolicyState` 설계
- `cgroup-scoped manager` vs 과도기 `LD_PRELOAD` 모드 결정
- node0/node1/PFN 상수 제거 포인트 정리

### P1

- `get_node0_free_mem()` -> `get_node_free_mem(node_id)`
- promotion/demotion target을 `TierDesc` 기반으로 전환
- perf cgroup filtering을 tenant 단위로 붙이기
- `virtual address -> PFN -> kpagecgroup inode -> tenant` 경로 추가
- `run_exp_common.sh`의 kernel version check 제거

### P2

- page location cache 도입
- perf source abstraction 도입
- `REMOTE_CXL_MEM` 사용 가능 여부 실기 검증
- `memory.numa_stat` / `cpuset.mems.effective` 집계 추가

### P3

- huge path 공통화
- multi-tier adjacency migration
- daxctl / online policy 자동화

## 10. 최종 권장 포팅 순서

1. `regular path`만 대상으로 real CXL NUMA topology 인식
2. PFN 기반 fast tier 판정 제거
3. `move_pages(status)` 기반 위치 판정 일반화
4. `cgroup-scoped manager`와 tenant context 도입
5. 커널/스크립트 의존성 제거
6. perf source layer 추가
7. huge path 반영
8. multi-tier + multi-tenant 일반화

이번 환경에서는 `NUMA fake 기반 검증`이 주 경로가 아니라 fallback이 되어야 한다.

## 11. 참고 자료

- Linux CXL overview
  - https://docs.kernel.org/next/driver-api/cxl/linux/overview.html
- Linux Init (Early Boot)
  - https://docs.kernel.org/next/driver-api/cxl/linux/early-boot.html
- Linux DAX driver operation
  - https://docs.kernel.org/driver-api/cxl/linux/dax-driver.html
- Linux Memory Hotplug
  - https://docs.kernel.org/driver-api/cxl/linux/memory-hotplug.html
- Linux Page Allocator and CXL allocation
  - https://docs.kernel.org/next/driver-api/cxl/allocation/page-allocator.html
- Linux ACPI tables for CXL
  - https://docs.kernel.org/6.18/driver-api/cxl/platform/acpi.html
- daxctl reconfigure-device
  - https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-reconfigure-device
- daxctl online-memory
  - https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/untitled-3
- daxctl offline-memory
  - https://docs.pmem.io/ndctl-user-guide/daxctl-man-pages/daxctl-offline-memory
- Linux CXL CPMU
  - https://docs.kernel.org/6.8/admin-guide/perf/cxl.html
- Intel PerfMon Granite Rapids core events
  - https://perfmon-events.intel.com/platforms/graniterapids/core-events/core/
- cgroup v2
  - https://docs.kernel.org/6.6/admin-guide/cgroup-v2.html
- `perf_event_open(2)`
  - https://man7.org/linux/man-pages/man2/perf_event_open.2.html
- `move_pages(2)`
  - https://man7.org/linux/man-pages/man2/move_pages.2.html
- pagemap / `kpagecgroup`
  - https://docs.kernel.org/admin-guide/mm/pagemap.html
- idle page tracking
  - https://docs.kernel.org/admin-guide/mm/idle_page_tracking.html
