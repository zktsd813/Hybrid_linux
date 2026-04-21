#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <numa.h>
#include <numaif.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

struct perf_sample {
    struct perf_event_header header;
    uint32_t pid;
    uint32_t tid;
    uint64_t addr;
};

static long perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
                            int cpu, int group_fd, unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
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
    if (move_pages(0, 1, pages, NULL, status, 0) != 0) {
        return -1;
    }
    return status[0];
}

static uint64_t count_samples(struct perf_event_mmap_page *meta,
                              uint64_t buffer_start,
                              uint64_t buffer_end,
                              uint64_t *first_addr,
                              uint64_t *last_addr,
                              uint64_t *buffer_hits) {
    char *data;
    uint64_t count = 0;

    if (!meta) {
        return 0;
    }

    data = ((char *)meta) + meta->data_offset;
    *first_addr = 0;
    *last_addr = 0;
    *buffer_hits = 0;

    __sync_synchronize();
    while (meta->data_tail != meta->data_head) {
        struct perf_event_header *header =
            (struct perf_event_header *)(data + (meta->data_tail % meta->data_size));
        if (header->type == PERF_RECORD_SAMPLE) {
            struct perf_sample *sample = (struct perf_sample *)header;
            if (count == 0) {
                *first_addr = sample->addr;
            }
            *last_addr = sample->addr;
            if (buffer_start <= sample->addr && sample->addr < buffer_end) {
                (*buffer_hits)++;
            }
            count++;
        }
        meta->data_tail += header->size;
    }
    __sync_synchronize();
    return count;
}

int main(int argc, char **argv) {
    uint64_t raw_event;
    int cpu;
    int mem_node;
    size_t size_mb;
    uint64_t sample_period;
    int passes;
    size_t size_bytes;
    char *buf;
    volatile uint64_t sink = 0;
    int first_page_node;
    struct perf_event_attr pe;
    int fd;
    size_t page_size;
    size_t mmap_pages;
    size_t mmap_len;
    struct perf_event_mmap_page *meta;
    uint64_t first_addr = 0;
    uint64_t last_addr = 0;
    uint64_t buffer_hits = 0;
    uint64_t sample_count;
    int pass;

    if (argc != 7) {
        fprintf(stderr,
                "usage: %s <raw_event_hex> <cpu> <mem_node> <size_mb> <sample_period> <passes>\n",
                argv[0]);
        return 2;
    }

    raw_event = strtoull(argv[1], NULL, 0);
    cpu = atoi(argv[2]);
    mem_node = atoi(argv[3]);
    size_mb = strtoull(argv[4], NULL, 0);
    sample_period = strtoull(argv[5], NULL, 0);
    passes = atoi(argv[6]);

    if (numa_available() < 0) {
        fprintf(stderr, "NUMA not available\n");
        return 3;
    }
    if (pin_to_cpu(cpu) != 0) {
        fprintf(stderr, "sched_setaffinity cpu %d failed: %s\n", cpu, strerror(errno));
        return 4;
    }

    size_bytes = size_mb * 1024UL * 1024UL;
    buf = numa_alloc_onnode(size_bytes, mem_node);
    if (!buf) {
        fprintf(stderr, "numa_alloc_onnode failed for node %d size %zuMB\n", mem_node, size_mb);
        return 5;
    }

    memset(buf, 1, size_bytes);
    for (size_t off = 0; off < size_bytes; off += 64) {
        sink += buf[off];
    }

    first_page_node = query_page_node(buf);

    memset(&pe, 0, sizeof(pe));
    pe.type = PERF_TYPE_RAW;
    pe.size = sizeof(pe);
    pe.config = raw_event;
    if (raw_event == 0x1cd) {
        pe.config1 = 3;
    }
    pe.disabled = 1;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;
    pe.precise_ip = 1;
    pe.inherit = 0;
    pe.sample_type = PERF_SAMPLE_TID | PERF_SAMPLE_ADDR;
    pe.sample_period = sample_period;
    pe.wakeup_events = 1;

    fd = perf_event_open(&pe, 0, -1, -1, 0);
    if (fd < 0) {
        fprintf(stderr, "perf_event_open raw=0x%llx failed: %s\n",
                (unsigned long long)raw_event, strerror(errno));
        numa_free(buf, size_bytes);
        return 6;
    }

    page_size = sysconf(_SC_PAGESIZE);
    mmap_pages = 1 + 8;
    mmap_len = page_size * mmap_pages;
    meta = mmap(NULL, mmap_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (meta == MAP_FAILED) {
        fprintf(stderr, "mmap perf ring failed: %s\n", strerror(errno));
        close(fd);
        numa_free(buf, size_bytes);
        return 7;
    }

    if (ioctl(fd, PERF_EVENT_IOC_RESET, 0) != 0 ||
        ioctl(fd, PERF_EVENT_IOC_ENABLE, 0) != 0) {
        fprintf(stderr, "enable perf failed: %s\n", strerror(errno));
        munmap(meta, mmap_len);
        close(fd);
        numa_free(buf, size_bytes);
        return 8;
    }

    for (pass = 0; pass < passes; ++pass) {
        for (size_t off = 0; off < size_bytes; off += 64) {
            sink += buf[off];
        }
    }

    if (ioctl(fd, PERF_EVENT_IOC_DISABLE, 0) != 0) {
        fprintf(stderr, "disable perf failed: %s\n", strerror(errno));
    }

    sample_count =
        count_samples(meta,
                      (uint64_t)buf,
                      (uint64_t)buf + size_bytes,
                      &first_addr,
                      &last_addr,
                      &buffer_hits);

    printf("raw=0x%llx cpu=%d mem_node=%d size_mb=%zu sample_period=%llu passes=%d first_page_node=%d samples=%llu buffer_hits=%llu first_addr=0x%llx last_addr=0x%llx sink=%llu\n",
           (unsigned long long)raw_event,
           cpu,
           mem_node,
           size_mb,
           (unsigned long long)sample_period,
           passes,
           first_page_node,
           (unsigned long long)sample_count,
           (unsigned long long)buffer_hits,
           (unsigned long long)first_addr,
           (unsigned long long)last_addr,
           (unsigned long long)sink);

    munmap(meta, mmap_len);
    close(fd);
    numa_free(buf, size_bytes);
    return 0;
}
