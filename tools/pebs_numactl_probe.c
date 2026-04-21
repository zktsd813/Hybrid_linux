#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <linux/perf_event.h>
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

struct perf_sample_record {
    struct perf_event_header header;
    uint32_t pid;
    uint32_t tid;
    uint64_t addr;
};

struct event_desc {
    const char *name;
    uint64_t config;
    uint64_t config1;
};

static long perf_event_open_sys(struct perf_event_attr *attr,
                                pid_t pid,
                                int cpu,
                                int group_fd,
                                unsigned long flags)
{
    return syscall(__NR_perf_event_open, attr, pid, cpu, group_fd, flags);
}

static const struct event_desc *find_event(const char *name)
{
    static const struct event_desc events[] = {
        { "local-dram", 0x1d3, 0 },
        { "remote-dram", 0x2d3, 0 },
        { "mem-loads", 0x1cd, 3 },
    };
    size_t i;

    for (i = 0; i < sizeof(events) / sizeof(events[0]); ++i) {
        if (strcmp(name, events[i].name) == 0)
            return &events[i];
    }
    return NULL;
}

static int sample_page_nodes(void *base,
                             size_t size_bytes,
                             int expected_node,
                             size_t sample_pages)
{
    size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
    size_t total_pages = size_bytes / page_size;
    void **pages;
    int *status;
    size_t i;
    int counts[8] = {0};
    int other = 0;

    if (sample_pages == 0 || total_pages == 0)
        return 0;
    if (sample_pages > total_pages)
        sample_pages = total_pages;

    pages = calloc(sample_pages, sizeof(*pages));
    status = calloc(sample_pages, sizeof(*status));
    if (!pages || !status) {
        fprintf(stderr, "allocation failure while sampling page nodes\n");
        free(pages);
        free(status);
        return -1;
    }

    for (i = 0; i < sample_pages; ++i) {
        size_t page_idx = (i * total_pages) / sample_pages;
        pages[i] = (char *)base + page_idx * page_size;
    }

    if (move_pages(0, sample_pages, pages, NULL, status, 0) != 0) {
        fprintf(stderr, "move_pages failed while sampling page nodes: %s\n", strerror(errno));
        free(pages);
        free(status);
        return -1;
    }

    for (i = 0; i < sample_pages; ++i) {
        if (status[i] >= 0 && status[i] < (int)(sizeof(counts) / sizeof(counts[0])))
            counts[status[i]]++;
        else
            other++;
    }

    printf("page_nodes expected=%d samples=%zu", expected_node, sample_pages);
    for (i = 0; i < sizeof(counts) / sizeof(counts[0]); ++i) {
        if (counts[i] > 0)
            printf(" N%zu=%d", i, counts[i]);
    }
    if (other > 0)
        printf(" other=%d", other);
    printf("\n");

    free(pages);
    free(status);
    return counts[expected_node] > 0 ? 0 : -1;
}

static uint64_t drain_samples(struct perf_event_mmap_page *meta,
                              uint64_t buffer_start,
                              uint64_t buffer_end,
                              uint64_t *buffer_hits)
{
    char *data;
    uint64_t count = 0;

    *buffer_hits = 0;
    if (!meta)
        return 0;

    data = ((char *)meta) + meta->data_offset;
    __sync_synchronize();
    while (meta->data_tail != meta->data_head) {
        struct perf_event_header *header =
            (struct perf_event_header *)(data + (meta->data_tail % meta->data_size));
        if (header->type == PERF_RECORD_SAMPLE) {
            struct perf_sample_record *sample = (struct perf_sample_record *)header;
            if (sample->addr >= buffer_start && sample->addr < buffer_end)
                (*buffer_hits)++;
            count++;
        }
        meta->data_tail += header->size;
    }
    __sync_synchronize();
    return count;
}

static void touch_buffer(uint8_t *buf, size_t size_bytes, int passes)
{
    volatile uint64_t sink = 0;
    size_t lines = size_bytes / 64;
    int pass;

    for (pass = 0; pass < passes; ++pass) {
        size_t start = ((size_t)pass * 1315423911u) % (lines ? lines : 1);
        size_t i;
        for (i = 0; i < lines; ++i) {
            size_t idx = (start + i * 9973u) % lines;
            sink += buf[idx * 64];
        }
    }

    if (sink == 0xdeadbeefULL)
        fprintf(stderr, "impossible sink\n");
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "usage: %s <event-name> <expected-node> <size-mb> <sample-period> <passes>\n"
            "  event-name: local-dram | remote-dram | mem-loads\n",
            prog);
}

int main(int argc, char **argv)
{
    const struct event_desc *event;
    int expected_node;
    size_t size_mb;
    uint64_t sample_period;
    int passes;
    size_t size_bytes;
    uint8_t *buf;
    struct perf_event_attr pe;
    int fd;
    size_t page_size;
    size_t mmap_len;
    struct perf_event_mmap_page *meta;
    uint64_t total_samples;
    uint64_t buffer_hits;

    if (argc != 6) {
        usage(argv[0]);
        return 2;
    }

    event = find_event(argv[1]);
    if (!event) {
        usage(argv[0]);
        return 2;
    }

    expected_node = atoi(argv[2]);
    size_mb = strtoull(argv[3], NULL, 0);
    sample_period = strtoull(argv[4], NULL, 0);
    passes = atoi(argv[5]);
    size_bytes = size_mb * 1024UL * 1024UL;

    page_size = (size_t)sysconf(_SC_PAGESIZE);
    buf = mmap(NULL,
               size_bytes,
               PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS,
               -1,
               0);
    if (buf == MAP_FAILED) {
        fprintf(stderr, "mmap failed: %s\n", strerror(errno));
        return 3;
    }

    if (madvise(buf, size_bytes, MADV_NOHUGEPAGE) != 0)
        perror("madvise(MADV_NOHUGEPAGE)");

    memset(buf, 1, size_bytes);
    if (sample_page_nodes(buf, size_bytes, expected_node, 256) != 0) {
        fprintf(stderr, "buffer pages are not landing on expected node %d\n", expected_node);
        munmap(buf, size_bytes);
        return 4;
    }

    memset(&pe, 0, sizeof(pe));
    pe.type = PERF_TYPE_RAW;
    pe.size = sizeof(pe);
    pe.config = event->config;
    pe.config1 = event->config1;
    pe.sample_type = PERF_SAMPLE_TID | PERF_SAMPLE_ADDR;
    pe.sample_period = sample_period;
    pe.wakeup_events = 1;
    pe.disabled = 1;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;
    pe.precise_ip = 1;

    fd = (int)perf_event_open_sys(&pe, 0, -1, -1, 0);
    if (fd < 0) {
        fprintf(stderr,
                "perf_event_open event=%s config=0x%" PRIx64 " failed: %s\n",
                event->name,
                event->config,
                strerror(errno));
        munmap(buf, size_bytes);
        return 5;
    }

    mmap_len = page_size * (1 + 8);
    meta = mmap(NULL, mmap_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (meta == MAP_FAILED) {
        fprintf(stderr, "perf mmap failed: %s\n", strerror(errno));
        close(fd);
        munmap(buf, size_bytes);
        return 6;
    }

    if (ioctl(fd, PERF_EVENT_IOC_RESET, 0) != 0 ||
        ioctl(fd, PERF_EVENT_IOC_ENABLE, 0) != 0) {
        fprintf(stderr, "perf enable failed: %s\n", strerror(errno));
        munmap(meta, mmap_len);
        close(fd);
        munmap(buf, size_bytes);
        return 7;
    }

    touch_buffer(buf, size_bytes, passes);

    if (ioctl(fd, PERF_EVENT_IOC_DISABLE, 0) != 0)
        fprintf(stderr, "perf disable failed: %s\n", strerror(errno));

    total_samples = drain_samples(meta,
                                  (uint64_t)(uintptr_t)buf,
                                  (uint64_t)(uintptr_t)buf + size_bytes,
                                  &buffer_hits);

    printf("event=%s expected_node=%d size_mb=%zu sample_period=%" PRIu64
           " passes=%d samples=%" PRIu64 " buffer_hits=%" PRIu64
           " current_cpu=%d buffer=[0x%llx,0x%llx)\n",
           event->name,
           expected_node,
           size_mb,
           sample_period,
           passes,
           total_samples,
           buffer_hits,
           sched_getcpu(),
           (unsigned long long)(uintptr_t)buf,
           (unsigned long long)((uintptr_t)buf + size_bytes));

    munmap(meta, mmap_len);
    close(fd);
    munmap(buf, size_bytes);

    return buffer_hits > 0 ? 0 : 8;
}
