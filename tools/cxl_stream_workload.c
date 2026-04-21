#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <numa.h>
#include <numaif.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static int pin_to_cpu(int cpu)
{
    cpu_set_t set;

    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    return sched_setaffinity(0, sizeof(set), &set);
}

static int sample_page_nodes(const char *phase,
                             void *base,
                             size_t size_bytes,
                             size_t sample_pages)
{
    size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
    size_t total_pages = size_bytes / page_size;
    void **pages;
    int *status;
    int counts[8] = {0};
    int other = 0;
    size_t i;

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

    printf("node_sample phase=%s pages=%zu", phase, sample_pages);
    for (i = 0; i < sizeof(counts) / sizeof(counts[0]); ++i) {
        if (counts[i] > 0)
            printf(" N%zu=%d", i, counts[i]);
    }
    if (other > 0)
        printf(" other=%d", other);
    printf("\n");

    free(pages);
    free(status);
    return 0;
}

static void run_stream(uint8_t *buf, size_t size_bytes, int duration_sec)
{
    const uint64_t deadline_ns = (uint64_t)duration_sec * 1000000000ULL;
    struct timespec start;
    struct timespec now;
    volatile uint64_t sum = 0;
    uint64_t passes = 0;
    size_t lines = size_bytes / 64;

    clock_gettime(CLOCK_MONOTONIC, &start);
    while (1) {
        size_t base = ((size_t)passes * 1315423911u) % (lines ? lines : 1);
        size_t i;
        uint64_t elapsed_ns;

        for (i = 0; i < lines; ++i) {
            size_t idx = (base + i * 9973u) % lines;
            sum += buf[idx * 64];
            buf[idx * 64] ^= (uint8_t)(idx + passes);
        }

        passes++;
        clock_gettime(CLOCK_MONOTONIC, &now);
        elapsed_ns = (uint64_t)(now.tv_sec - start.tv_sec) * 1000000000ULL +
                     (uint64_t)(now.tv_nsec - start.tv_nsec);
        if (elapsed_ns >= deadline_ns)
            break;
        if ((passes % 8) == 0)
            printf("progress passes=%" PRIu64 " elapsed_ns=%" PRIu64 "\n", passes, elapsed_ns);
    }

    printf("stream_done passes=%" PRIu64 " checksum=%" PRIu64 "\n", passes, sum);
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "usage: %s --size-mb <mb> --duration-sec <sec> [--cpu <cpu>] "
            "[--alloc-node <nid>] [--sample-pages <n>]\n",
            prog);
}

int main(int argc, char **argv)
{
    int cpu = -1;
    int alloc_node = -1;
    int duration_sec = 20;
    size_t size_mb = 512;
    size_t sample_pages = 512;
    size_t size_bytes;
    uint8_t *buf = NULL;
    int i;

    for (i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--cpu") == 0 && i + 1 < argc) {
            cpu = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--alloc-node") == 0 && i + 1 < argc) {
            alloc_node = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--size-mb") == 0 && i + 1 < argc) {
            size_mb = strtoull(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--duration-sec") == 0 && i + 1 < argc) {
            duration_sec = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--sample-pages") == 0 && i + 1 < argc) {
            sample_pages = strtoull(argv[++i], NULL, 0);
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (cpu >= 0 && pin_to_cpu(cpu) != 0) {
        fprintf(stderr, "sched_setaffinity cpu=%d failed: %s\n", cpu, strerror(errno));
        return 3;
    }

    size_bytes = size_mb * 1024UL * 1024UL;
    if (alloc_node >= 0) {
        if (numa_available() < 0) {
            fprintf(stderr, "NUMA not available\n");
            return 4;
        }
        buf = numa_alloc_onnode(size_bytes, alloc_node);
        if (!buf) {
            fprintf(stderr, "numa_alloc_onnode node=%d size_mb=%zu failed\n", alloc_node, size_mb);
            return 5;
        }
    } else {
        buf = mmap(NULL,
                   size_bytes,
                   PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS,
                   -1,
                   0);
        if (buf == MAP_FAILED) {
            fprintf(stderr, "mmap failed: %s\n", strerror(errno));
            return 6;
        }
    }

    if (madvise(buf, size_bytes, MADV_NOHUGEPAGE) != 0)
        perror("madvise(MADV_NOHUGEPAGE)");

    memset(buf, 1, size_bytes);
    printf("workload_start size_mb=%zu duration_sec=%d cpu=%d alloc_node=%d pid=%d\n",
           size_mb,
           duration_sec,
           cpu,
           alloc_node,
           getpid());
    sample_page_nodes("start", buf, size_bytes, sample_pages);
    run_stream(buf, size_bytes, duration_sec);
    sample_page_nodes("end", buf, size_bytes, sample_pages);

    if (alloc_node >= 0)
        numa_free(buf, size_bytes);
    else
        munmap(buf, size_bytes);
    return 0;
}
