#ifndef HYBRIDTIER_RUNTIME_CONTEXT_HPP
#define HYBRIDTIER_RUNTIME_CONTEXT_HPP

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <limits>
#include <sched.h>
#include <sstream>
#include <string>
#include <sys/file.h>
#include <unistd.h>
#include <vector>

#include <numa.h>

struct PageKey {
    uint32_t pid;
    uint32_t reserved;
    uint64_t addr;
};

struct PfnRange {
    uint64_t start_pfn = 0;
    uint64_t end_pfn = 0;

    bool contains(uint64_t pfn) const {
        return start_pfn <= pfn && pfn < end_pfn;
    }
};

inline bool operator==(const PageKey& lhs, const PageKey& rhs) {
    return lhs.pid == rhs.pid && lhs.addr == rhs.addr;
}

struct PageKeyHash {
    size_t operator()(const PageKey& key) const noexcept {
        return (static_cast<size_t>(key.pid) << 32) ^ static_cast<size_t>(key.addr >> 12);
    }
};

inline PageKey make_page_key(pid_t pid, uint64_t addr) {
    return PageKey{static_cast<uint32_t>(pid), 0, addr};
}

struct TierDesc {
    int tier_id = -1;
    int node_id = -1;
    uint64_t total_bytes = 0;
    uint64_t free_bytes = 0;
    int distance_from_fast = 0;
    bool has_cpus = false;
    std::vector<PfnRange> pfn_ranges;

    bool contains_pfn(uint64_t pfn) const {
        for (const PfnRange& range : pfn_ranges) {
            if (range.contains(pfn)) {
                return true;
            }
        }
        return false;
    }
};

struct RuntimeTopology {
    int fast_node = -1;
    std::vector<TierDesc> tiers;

    bool contains_node(int node_id) const {
        for (const TierDesc& tier : tiers) {
            if (tier.node_id == node_id) {
                return true;
            }
        }
        return false;
    }

    int first_slow_node() const {
        for (const TierDesc& tier : tiers) {
            if (tier.node_id != fast_node) {
                return tier.node_id;
            }
        }
        return -1;
    }

    const TierDesc* tier_for_node(int node_id) const {
        for (const TierDesc& tier : tiers) {
            if (tier.node_id == node_id) {
                return &tier;
            }
        }
        return nullptr;
    }

    bool fast_tier_contains_pfn(uint64_t pfn) const {
        const TierDesc* fast_tier = tier_for_node(fast_node);
        return fast_tier != nullptr && fast_tier->contains_pfn(pfn);
    }

    bool fast_tier_has_pfn_ranges() const {
        const TierDesc* fast_tier = tier_for_node(fast_node);
        return fast_tier != nullptr && !fast_tier->pfn_ranges.empty();
    }
};

struct CgroupRuntimeContext {
    bool enabled = false;
    bool leader = true;
    bool memcg_node_budget_supported = false;
    bool memcg_reclaimd_state_supported = false;
    bool memcg_numa_stat_supported = false;
    int cgroup_fd = -1;
    int leader_lock_fd = -1;
    std::string cgroup_relative_path;
    std::string cgroup_full_path;
    std::vector<int> allowed_cpus;
    std::vector<int> allowed_mems;
    uint64_t memory_current_bytes = 0;
};

struct MemcgNodeBudget {
    bool supported = false;
    bool configured = false;
    uint64_t capacity_pages = 0;
    uint64_t low_wmark_pages = 0;
    uint64_t high_wmark_pages = 0;
};

struct MemcgNodeRuntimeState {
    bool usage_available = false;
    bool reclaimd_running_available = false;
    bool reclaimd_running = false;
    uint64_t usage_pages = 0;
};

inline bool read_file_first_line(const std::string& path, std::string* out) {
    std::ifstream file(path);
    if (!file) {
        return false;
    }
    std::getline(file, *out);
    return true;
}

inline uint64_t read_hex_file_u64(const std::string& path) {
    std::string value;
    if (!read_file_first_line(path, &value) || value.empty()) {
        return 0;
    }
    return std::strtoull(value.c_str(), nullptr, 16);
}

inline uint64_t read_node_meminfo_value_kb(int node_id, const std::string& key) {
    std::ifstream file("/sys/devices/system/node/node" + std::to_string(node_id) + "/meminfo");
    if (!file) {
        return 0;
    }
    std::string line;
    while (std::getline(file, line)) {
        std::size_t key_pos = line.find(key);
        if (key_pos == std::string::npos) {
            continue;
        }
        std::istringstream iss(line.substr(key_pos + key.size()));
        uint64_t value = 0;
        iss >> value;
        return value;
    }
    return 0;
}

inline bool node_has_cpus(int node_id) {
    std::string cpulist;
    if (!read_file_first_line("/sys/devices/system/node/node" + std::to_string(node_id) + "/cpulist", &cpulist)) {
        return false;
    }
    return !cpulist.empty();
}

inline std::vector<PfnRange> detect_node_pfn_ranges(int node_id) {
    std::vector<PfnRange> ranges;
    uint64_t block_size_bytes = read_hex_file_u64("/sys/devices/system/memory/block_size_bytes");
    if (block_size_bytes == 0) {
        return ranges;
    }

    const uint64_t pages_per_block = block_size_bytes / static_cast<uint64_t>(sysconf(_SC_PAGESIZE));
    if (pages_per_block == 0) {
        return ranges;
    }

    const std::string node_dir = "/sys/devices/system/node/node" + std::to_string(node_id);
    DIR* dir = opendir(node_dir.c_str());
    if (dir == nullptr) {
        return ranges;
    }

    struct dirent* entry = nullptr;
    while ((entry = readdir(dir)) != nullptr) {
        if (std::strncmp(entry->d_name, "memory", 6) != 0) {
            continue;
        }

        const std::string memory_block_path = node_dir + "/" + entry->d_name;
        uint64_t phys_index = read_hex_file_u64(memory_block_path + "/phys_index");
        if (phys_index == 0 && access((memory_block_path + "/phys_index").c_str(), R_OK) != 0) {
            continue;
        }

        PfnRange range;
        range.start_pfn = phys_index * pages_per_block;
        range.end_pfn = range.start_pfn + pages_per_block;
        ranges.push_back(range);
    }
    closedir(dir);

    std::sort(ranges.begin(), ranges.end(), [](const PfnRange& lhs, const PfnRange& rhs) {
        if (lhs.start_pfn != rhs.start_pfn) {
            return lhs.start_pfn < rhs.start_pfn;
        }
        return lhs.end_pfn < rhs.end_pfn;
    });

    std::vector<PfnRange> merged_ranges;
    for (const PfnRange& range : ranges) {
        if (merged_ranges.empty() || merged_ranges.back().end_pfn < range.start_pfn) {
            merged_ranges.push_back(range);
            continue;
        }
        merged_ranges.back().end_pfn = std::max(merged_ranges.back().end_pfn, range.end_pfn);
    }
    return merged_ranges;
}

inline RuntimeTopology detect_runtime_topology() {
    RuntimeTopology topology;
    if (numa_available() < 0) {
        return topology;
    }

    int current_cpu = sched_getcpu();
    int preferred_fast_node = current_cpu >= 0 ? numa_node_of_cpu(current_cpu) : 0;
    int max_node = numa_max_node();

    std::vector<TierDesc> detected;
    for (int node = 0; node <= max_node; ++node) {
        long long free_bytes = 0;
        long long total_bytes = numa_node_size64(node, &free_bytes);
        if (total_bytes <= 0) {
            continue;
        }
        TierDesc tier;
        tier.node_id = node;
        tier.total_bytes = static_cast<uint64_t>(total_bytes);
        tier.free_bytes = static_cast<uint64_t>(free_bytes);
        tier.has_cpus = node_has_cpus(node);
        tier.pfn_ranges = detect_node_pfn_ranges(node);
        detected.push_back(tier);
    }

    if (detected.empty()) {
        return topology;
    }

    bool fast_node_found = false;
    for (const TierDesc& tier : detected) {
        if (tier.node_id == preferred_fast_node) {
            fast_node_found = true;
            break;
        }
    }
    topology.fast_node = fast_node_found ? preferred_fast_node : detected.front().node_id;

    for (TierDesc& tier : detected) {
        tier.distance_from_fast = numa_distance(topology.fast_node, tier.node_id);
    }

    std::sort(detected.begin(), detected.end(), [&](const TierDesc& lhs, const TierDesc& rhs) {
        if (lhs.node_id == topology.fast_node) {
            return true;
        }
        if (rhs.node_id == topology.fast_node) {
            return false;
        }
        if (lhs.distance_from_fast != rhs.distance_from_fast) {
            return lhs.distance_from_fast < rhs.distance_from_fast;
        }
        return lhs.node_id < rhs.node_id;
    });

    for (size_t i = 0; i < detected.size(); ++i) {
        detected[i].tier_id = static_cast<int>(i);
    }
    topology.tiers = detected;
    return topology;
}

inline std::vector<int> parse_cpu_or_node_list(const std::string& value) {
    std::vector<int> parsed;
    std::stringstream ss(value);
    std::string token;
    while (std::getline(ss, token, ',')) {
        if (token.empty()) {
            continue;
        }
        std::size_t dash = token.find('-');
        if (dash == std::string::npos) {
            parsed.push_back(std::stoi(token));
            continue;
        }
        int start = std::stoi(token.substr(0, dash));
        int end = std::stoi(token.substr(dash + 1));
        for (int value_num = start; value_num <= end; ++value_num) {
            parsed.push_back(value_num);
        }
    }
    std::sort(parsed.begin(), parsed.end());
    parsed.erase(std::unique(parsed.begin(), parsed.end()), parsed.end());
    return parsed;
}

inline std::vector<int> detect_current_allowed_cpus() {
    std::vector<int> cpus;
    cpu_set_t mask;
    CPU_ZERO(&mask);
    if (sched_getaffinity(0, sizeof(mask), &mask) == 0) {
        for (int cpu = 0; cpu < CPU_SETSIZE; ++cpu) {
            if (CPU_ISSET(cpu, &mask)) {
                cpus.push_back(cpu);
            }
        }
    }
    if (!cpus.empty()) {
        return cpus;
    }

    long num_online_cpus = sysconf(_SC_NPROCESSORS_ONLN);
    for (int cpu = 0; cpu < num_online_cpus; ++cpu) {
        cpus.push_back(cpu);
    }
    return cpus;
}

inline std::string detect_unified_cgroup_relative_path() {
    std::ifstream file("/proc/self/cgroup");
    if (!file) {
        return "";
    }

    std::string line;
    while (std::getline(file, line)) {
        if (line.rfind("0::", 0) == 0) {
            return line.substr(3);
        }
    }
    return "";
}

inline uint64_t fnv1a_hash(const std::string& value) {
    uint64_t hash = 1469598103934665603ULL;
    for (unsigned char ch : value) {
        hash ^= static_cast<uint64_t>(ch);
        hash *= 1099511628211ULL;
    }
    return hash;
}

inline std::string cgroup_lock_path(const std::string& cgroup_relative_path) {
    return "/tmp/hybridtier_cgroup_" + std::to_string(fnv1a_hash(cgroup_relative_path)) + ".lock";
}

inline RuntimeTopology filter_topology_by_allowed_mems(const RuntimeTopology& original, const std::vector<int>& allowed_mems) {
    if (allowed_mems.empty()) {
        return original;
    }

    RuntimeTopology filtered;
    for (const TierDesc& tier : original.tiers) {
        if (std::find(allowed_mems.begin(), allowed_mems.end(), tier.node_id) != allowed_mems.end()) {
            filtered.tiers.push_back(tier);
        }
    }

    if (filtered.tiers.empty()) {
        return original;
    }

    filtered.fast_node = filtered.tiers.front().node_id;
    for (size_t i = 0; i < filtered.tiers.size(); ++i) {
        filtered.tiers[i].tier_id = static_cast<int>(i);
    }
    return filtered;
}

inline std::vector<pid_t> read_cgroup_procs(const std::string& cgroup_full_path) {
    std::vector<pid_t> pids;
    std::ifstream file(cgroup_full_path + "/cgroup.procs");
    if (!file) {
        return pids;
    }

    pid_t pid = 0;
    while (file >> pid) {
        if (pid > 0) {
            pids.push_back(pid);
        }
    }
    std::sort(pids.begin(), pids.end());
    pids.erase(std::unique(pids.begin(), pids.end()), pids.end());
    return pids;
}

inline uint64_t read_cgroup_memory_current(const std::string& cgroup_full_path) {
    std::string value;
    if (!read_file_first_line(cgroup_full_path + "/memory.current", &value)) {
        return 0;
    }
    if (value.empty()) {
        return 0;
    }
    return std::strtoull(value.c_str(), nullptr, 10);
}

inline bool read_cgroup_node_file_value_pages(const std::string& cgroup_full_path,
                                              const std::string& file_name,
                                              int node_id,
                                              uint64_t* out_pages) {
    std::ifstream file(cgroup_full_path + "/" + file_name);
    if (!file) {
        return false;
    }

    const std::string expected_label = "node" + std::to_string(node_id);
    std::string label;
    uint64_t value = 0;
    while (file >> label >> value) {
        if (label == expected_label) {
            *out_pages = value;
            return true;
        }
    }
    return false;
}

inline bool read_cgroup_flat_key_u64(const std::string& path,
                                     const std::string& key,
                                     uint64_t* out_value) {
    std::ifstream file(path);
    if (!file) {
        return false;
    }

    std::string current_key;
    uint64_t current_value = 0;
    while (file >> current_key >> current_value) {
        if (current_key == key) {
            *out_value = current_value;
            return true;
        }
    }
    return false;
}

inline bool is_memcg_lru_usage_key(const std::string& key) {
    return key == "inactive_anon" ||
           key == "active_anon" ||
           key == "inactive_file" ||
           key == "active_file" ||
           key == "unevictable";
}

inline uint64_t read_cgroup_numa_stat_node_usage_bytes(const std::string& cgroup_full_path, int node_id) {
    std::ifstream file(cgroup_full_path + "/memory.numa_stat");
    if (!file) {
        return 0;
    }

    const std::string expected_prefix = "N" + std::to_string(node_id) + "=";
    uint64_t total_bytes = 0;
    std::string line;
    while (std::getline(file, line)) {
        std::istringstream iss(line);
        std::string key;
        if (!(iss >> key) || !is_memcg_lru_usage_key(key)) {
            continue;
        }

        std::string token;
        while (iss >> token) {
            if (token.rfind(expected_prefix, 0) == 0) {
                total_bytes += std::strtoull(token.c_str() + expected_prefix.size(), nullptr, 10);
                break;
            }
        }
    }
    return total_bytes;
}

inline MemcgNodeBudget read_cgroup_memcg_node_budget(const CgroupRuntimeContext& context, int node_id) {
    MemcgNodeBudget budget;
    if (!context.enabled || !context.memcg_node_budget_supported || node_id < 0) {
        return budget;
    }

    budget.supported = true;
    read_cgroup_node_file_value_pages(context.cgroup_full_path, "memory.node_capacity", node_id, &budget.capacity_pages);
    read_cgroup_node_file_value_pages(context.cgroup_full_path, "memory.node_low_wmark", node_id, &budget.low_wmark_pages);
    read_cgroup_node_file_value_pages(context.cgroup_full_path, "memory.node_high_wmark", node_id, &budget.high_wmark_pages);
    budget.configured = (budget.capacity_pages > 0);
    return budget;
}

inline MemcgNodeRuntimeState read_cgroup_memcg_node_runtime_state(const CgroupRuntimeContext& context,
                                                                  int node_id,
                                                                  uint64_t page_size) {
    MemcgNodeRuntimeState state;
    if (!context.enabled || node_id < 0) {
        return state;
    }

    if (context.memcg_numa_stat_supported && page_size > 0) {
        state.usage_pages = read_cgroup_numa_stat_node_usage_bytes(context.cgroup_full_path, node_id) / page_size;
        state.usage_available = true;
    }

    if (context.memcg_reclaimd_state_supported) {
        uint64_t running = 0;
        if (read_cgroup_flat_key_u64(context.cgroup_full_path + "/memory.reclaimd_state",
                                     "running",
                                     &running)) {
            state.reclaimd_running_available = true;
            state.reclaimd_running = (running != 0);
        }
    }
    return state;
}

inline uint64_t resolve_fast_memory_size_bytes(uint64_t fallback_fast_memory_size_bytes,
                                               const CgroupRuntimeContext& context,
                                               int fast_node,
                                               uint64_t page_size,
                                               bool* from_memcg,
                                               MemcgNodeBudget* budget_out) {
    MemcgNodeBudget budget = read_cgroup_memcg_node_budget(context, fast_node);
    if (budget_out != nullptr) {
        *budget_out = budget;
    }
    if (from_memcg != nullptr) {
        *from_memcg = budget.configured;
    }
    if (budget.configured && page_size > 0) {
        return budget.capacity_pages * page_size;
    }
    return fallback_fast_memory_size_bytes;
}

inline CgroupRuntimeContext init_cgroup_runtime_context() {
    CgroupRuntimeContext context;
    context.cgroup_relative_path = detect_unified_cgroup_relative_path();
    if (context.cgroup_relative_path.empty() || context.cgroup_relative_path == "/") {
        return context;
    }

    context.cgroup_full_path = "/sys/fs/cgroup" + context.cgroup_relative_path;
    context.cgroup_fd = open(context.cgroup_full_path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (context.cgroup_fd < 0) {
        std::cerr << "[WARN] Failed to open cgroup directory " << context.cgroup_full_path
                  << ": " << strerror(errno) << std::endl;
        return context;
    }

    std::string effective_mems;
    if (read_file_first_line(context.cgroup_full_path + "/cpuset.mems.effective", &effective_mems)) {
        context.allowed_mems = parse_cpu_or_node_list(effective_mems);
    }
    std::string effective_cpus;
    if (read_file_first_line(context.cgroup_full_path + "/cpuset.cpus.effective", &effective_cpus)) {
        context.allowed_cpus = parse_cpu_or_node_list(effective_cpus);
    }
    context.memory_current_bytes = read_cgroup_memory_current(context.cgroup_full_path);
    context.memcg_node_budget_supported =
        (access((context.cgroup_full_path + "/memory.node_capacity").c_str(), R_OK) == 0 &&
         access((context.cgroup_full_path + "/memory.node_low_wmark").c_str(), R_OK) == 0 &&
         access((context.cgroup_full_path + "/memory.node_high_wmark").c_str(), R_OK) == 0);
    context.memcg_reclaimd_state_supported =
        (access((context.cgroup_full_path + "/memory.reclaimd_state").c_str(), R_OK) == 0);
    context.memcg_numa_stat_supported =
        (access((context.cgroup_full_path + "/memory.numa_stat").c_str(), R_OK) == 0);

    std::string lock_path = cgroup_lock_path(context.cgroup_relative_path);
    context.leader_lock_fd = open(lock_path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (context.leader_lock_fd >= 0) {
        context.leader = (flock(context.leader_lock_fd, LOCK_EX | LOCK_NB) == 0);
    }
    context.enabled = true;
    return context;
}

inline std::vector<int> detect_monitored_cpus(const CgroupRuntimeContext& context) {
    if (context.enabled && !context.allowed_cpus.empty()) {
        return context.allowed_cpus;
    }
    return detect_current_allowed_cpus();
}

inline int get_page_current_node(pid_t pid, uint64_t addr) {
    void* page = reinterpret_cast<void*>(addr);
    int status = -1;
    long ret = numa_move_pages(pid, 1, &page, nullptr, &status, 0);
    if (ret != 0) {
        return -1;
    }
    return status;
}

#endif
