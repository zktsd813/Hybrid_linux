#define _GNU_SOURCE

#include <errno.h>
#include <linux/perf_event.h>
#include <sched.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

struct perf_sample_record {
    struct perf_event_header header;
    uint32_t pid;
    uint32_t tid;
    uint64_t addr;
};

struct options {
    int cpu;
    size_t size_mb;
    unsigned int duration_sec;
    size_t stride_bytes;
    bool sample_enabled;
    uint64_t sample_event;
    uint64_t sample_config1;
    uint64_t sample_period;
};

struct sample_stats {
    uint64_t sample_count;
    uint64_t buffer_hits;
    uint64_t first_addr;
    uint64_t last_addr;
};

static long perf_event_open(struct perf_event_attr *hw_event,
                            pid_t pid,
                            int cpu,
                            int group_fd,
                            unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

static long move_pages_syscall(pid_t pid,
                               unsigned long count,
                               void **pages,
                               const int *nodes,
                               int *status,
                               int flags) {
    return syscall(__NR_move_pages, pid, count, pages, nodes, status, flags);
}

static void usage(const char *prog) {
    fprintf(stderr,
            "usage: %s --cpu <id> --size-mb <mb> [--duration-sec <sec>] [--stride <bytes>]\n"
            "          [--sample-event <hex>] [--config1 <value>] [--sample-period <period>]\n",
            prog);
}

static bool parse_u64(const char *value, uint64_t *out) {
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(value, &end, 0);
    if (errno != 0 || end == value || *end != '\0') {
        return false;
    }
    *out = parsed;
    return true;
}

static bool parse_options(int argc, char **argv, struct options *opts) {
    opts->cpu = -1;
    opts->size_mb = 0;
    opts->duration_sec = 5;
    opts->stride_bytes = 64;
    opts->sample_enabled = false;
    opts->sample_event = 0;
    opts->sample_config1 = 0;
    opts->sample_period = 200;

    for (int i = 1; i < argc; ++i) {
        const char *arg = argv[i];
        if (strcmp(arg, "--cpu") == 0 && i + 1 < argc) {
            uint64_t value = 0;
            if (!parse_u64(argv[++i], &value)) {
                return false;
            }
            opts->cpu = (int)value;
        } else if (strcmp(arg, "--size-mb") == 0 && i + 1 < argc) {
            uint64_t value = 0;
            if (!parse_u64(argv[++i], &value)) {
                return false;
            }
            opts->size_mb = (size_t)value;
        } else if (strcmp(arg, "--duration-sec") == 0 && i + 1 < argc) {
            uint64_t value = 0;
            if (!parse_u64(argv[++i], &value)) {
                return false;
            }
            opts->duration_sec = (unsigned int)value;
        } else if (strcmp(arg, "--stride") == 0 && i + 1 < argc) {
            uint64_t value = 0;
            if (!parse_u64(argv[++i], &value) || value == 0) {
                return false;
            }
            opts->stride_bytes = (size_t)value;
        } else if (strcmp(arg, "--sample-event") == 0 && i + 1 < argc) {
            if (!parse_u64(argv[++i], &opts->sample_event)) {
                return false;
            }
            opts->sample_enabled = true;
        } else if (strcmp(arg, "--config1") == 0 && i + 1 < argc) {
            if (!parse_u64(argv[++i], &opts->sample_config1)) {
                return false;
            }
        } else if (strcmp(arg, "--sample-period") == 0 && i + 1 < argc) {
            if (!parse_u64(argv[++i], &opts->sample_period) || opts->sample_period == 0) {
                return false;
            }
        } else {
            return false;
        }
    }

    return opts->cpu >= 0 && opts->size_mb > 0 && opts->duration_sec > 0;
}

static int pin_to_cpu(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    return sched_setaffinity(0, sizeof(set), &set);
}

static int query_page_node(void *addr) {
    void *pages[1];
    int status[1] = {-1};
    pages[0] = addr;
    if (move_pages_syscall(0, 1, pages, NULL, status, 0) != 0) {
        return -1;
    }
    return status[0];
}

static double monotonic_now_sec(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0.0;
    }
    return (double)ts.tv_sec + ((double)ts.tv_nsec / 1000000000.0);
}

static int open_perf_event(const struct options *opts) {
    struct perf_event_attr pe;
    memset(&pe, 0, sizeof(pe));
    pe.type = PERF_TYPE_RAW;
    pe.size = sizeof(pe);
    pe.config = opts->sample_event;
    pe.config1 = opts->sample_config1;
    pe.disabled = 1;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;
    pe.precise_ip = 1;
    pe.inherit = 0;
    pe.sample_type = PERF_SAMPLE_TID | PERF_SAMPLE_ADDR;
    pe.sample_period = opts->sample_period;
    pe.wakeup_events = 1;

    return (int)perf_event_open(&pe, 0, -1, -1, 0);
}

static uint64_t count_samples(struct perf_event_mmap_page *meta,
                              uintptr_t buffer_start,
                              uintptr_t buffer_end,
                              struct sample_stats *stats) {
    char *data = ((char *)meta) + meta->data_offset;
    uint64_t count = 0;

    stats->sample_count = 0;
    stats->buffer_hits = 0;
    stats->first_addr = 0;
    stats->last_addr = 0;

    __sync_synchronize();
    while (meta->data_tail != meta->data_head) {
        struct perf_event_header *header =
            (struct perf_event_header *)(data + (meta->data_tail % meta->data_size));

        if (header->type == PERF_RECORD_SAMPLE) {
            struct perf_sample_record *sample = (struct perf_sample_record *)header;
            if (count == 0) {
                stats->first_addr = sample->addr;
            }
            stats->last_addr = sample->addr;
            if (buffer_start <= sample->addr && sample->addr < buffer_end) {
                stats->buffer_hits++;
            }
            count++;
        }
        meta->data_tail += header->size;
    }
    __sync_synchronize();

    stats->sample_count = count;
    return count;
}

int main(int argc, char **argv) {
    struct options opts;
    if (!parse_options(argc, argv, &opts)) {
        usage(argv[0]);
        return 2;
    }

    if (pin_to_cpu(opts.cpu) != 0) {
        fprintf(stderr, "sched_setaffinity cpu=%d failed: %s\n", opts.cpu, strerror(errno));
        return 3;
    }

    size_t size_bytes = opts.size_mb * 1024UL * 1024UL;
    char *buffer = mmap(NULL, size_bytes, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buffer == MAP_FAILED) {
        fprintf(stderr, "mmap failed: %s\n", strerror(errno));
        return 4;
    }

    size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
    for (size_t off = 0; off < size_bytes; off += page_size) {
        buffer[off] = 1;
    }

    int start_page_node = query_page_node(buffer);
    volatile uint64_t sink = 0;

    int perf_fd = -1;
    struct perf_event_mmap_page *perf_meta = NULL;
    size_t perf_mmap_len = 0;
    if (opts.sample_enabled) {
        perf_fd = open_perf_event(&opts);
        if (perf_fd < 0) {
            fprintf(stderr,
                    "perf_event_open raw=0x%llx config1=%llu failed: %s\n",
                    (unsigned long long)opts.sample_event,
                    (unsigned long long)opts.sample_config1,
                    strerror(errno));
            munmap(buffer, size_bytes);
            return 5;
        }

        perf_mmap_len = page_size * (1 + 8);
        perf_meta = mmap(NULL, perf_mmap_len, PROT_READ | PROT_WRITE, MAP_SHARED, perf_fd, 0);
        if (perf_meta == MAP_FAILED) {
            fprintf(stderr, "mmap perf ring failed: %s\n", strerror(errno));
            close(perf_fd);
            munmap(buffer, size_bytes);
            return 6;
        }
        if (ioctl(perf_fd, PERF_EVENT_IOC_RESET, 0) != 0 ||
            ioctl(perf_fd, PERF_EVENT_IOC_ENABLE, 0) != 0) {
            fprintf(stderr, "perf enable failed: %s\n", strerror(errno));
            munmap(perf_meta, perf_mmap_len);
            close(perf_fd);
            munmap(buffer, size_bytes);
            return 7;
        }
    }

    double end_time = monotonic_now_sec() + (double)opts.duration_sec;
    uint64_t passes = 0;
    while (monotonic_now_sec() < end_time) {
        for (size_t off = 0; off < size_bytes; off += opts.stride_bytes) {
            sink += (unsigned char)buffer[off];
        }
        passes++;
    }

    if (opts.sample_enabled && ioctl(perf_fd, PERF_EVENT_IOC_DISABLE, 0) != 0) {
        fprintf(stderr, "perf disable failed: %s\n", strerror(errno));
    }

    int end_page_node = query_page_node(buffer);
    struct sample_stats stats;
    memset(&stats, 0, sizeof(stats));
    if (opts.sample_enabled) {
        count_samples(perf_meta,
                      (uintptr_t)buffer,
                      (uintptr_t)buffer + size_bytes,
                      &stats);
    }

    printf("cpu=%d size_mb=%zu duration_sec=%u stride=%zu start_page_node=%d end_page_node=%d "
           "passes=%llu raw_event=0x%llx config1=%llu sample_period=%llu samples=%llu "
           "buffer_hits=%llu first_addr=0x%llx last_addr=0x%llx sink=%llu\n",
           opts.cpu,
           opts.size_mb,
           opts.duration_sec,
           opts.stride_bytes,
           start_page_node,
           end_page_node,
           (unsigned long long)passes,
           (unsigned long long)opts.sample_event,
           (unsigned long long)opts.sample_config1,
           (unsigned long long)opts.sample_period,
           (unsigned long long)stats.sample_count,
           (unsigned long long)stats.buffer_hits,
           (unsigned long long)stats.first_addr,
           (unsigned long long)stats.last_addr,
           (unsigned long long)sink);

    if (perf_meta != NULL && perf_meta != MAP_FAILED) {
        munmap(perf_meta, perf_mmap_len);
    }
    if (perf_fd >= 0) {
        close(perf_fd);
    }
    munmap(buffer, size_bytes);
    return 0;
}
