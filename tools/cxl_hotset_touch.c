#define _GNU_SOURCE

#include <errno.h>
#include <linux/mempolicy.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

static long move_pages_sys(pid_t pid,
                           unsigned long count,
                           void **pages,
                           const int *nodes,
                           int *status,
                           int flags) {
    return syscall(__NR_move_pages, pid, count, pages, nodes, status, flags);
}

static int count_numa_nodes(void) {
    int count = 0;

    for (;;) {
        char path[128];
        FILE *f;

        snprintf(path, sizeof(path), "/sys/devices/system/node/node%d", count);
        f = fopen(path, "r");
        if (!f) {
            break;
        }
        fclose(f);
        count++;
    }

    if (count == 0) {
        return 8;
    }
    return count;
}

static void print_sampled_distribution(const char *label,
                                       char *buf,
                                       size_t size_bytes,
                                       size_t sample_step_bytes) {
    size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
    size_t sample_count = (size_bytes + sample_step_bytes - 1) / sample_step_bytes;
    void **pages = NULL;
    int *status = NULL;
    size_t counts_capacity = 0;
    unsigned long long unknown = 0;
    int num_nodes;

    if (sample_step_bytes < page_size) {
        sample_step_bytes = page_size;
    }

    pages = calloc(sample_count, sizeof(*pages));
    status = calloc(sample_count, sizeof(*status));
    if (!pages || !status) {
        fprintf(stderr, "%s: allocation failed for %zu sampled pages\n", label, sample_count);
        goto out;
    }

    for (size_t i = 0; i < sample_count; ++i) {
        size_t off = i * sample_step_bytes;
        if (off >= size_bytes) {
            off = size_bytes - 1;
        }
        pages[i] = buf + off;
        status[i] = -1;
    }

    if (move_pages_sys(0, sample_count, pages, NULL, status, 0) != 0) {
        fprintf(stderr, "%s: move_pages(status) failed: %s\n", label, strerror(errno));
        goto out;
    }

    num_nodes = count_numa_nodes();
    counts_capacity = (size_t)(num_nodes > 0 ? num_nodes : 8);
    unsigned long long *counts = calloc(counts_capacity, sizeof(*counts));
    if (!counts) {
        fprintf(stderr, "%s: counts allocation failed\n", label);
        goto out;
    }

    for (size_t i = 0; i < sample_count; ++i) {
        if (status[i] >= 0 && (size_t)status[i] < counts_capacity) {
            counts[status[i]]++;
        } else {
            unknown++;
        }
    }

    printf("%s sampled_pages=%zu", label, sample_count);
    for (size_t node = 0; node < counts_capacity; ++node) {
        if (counts[node] > 0) {
            printf(" node%zu=%llu", node, counts[node]);
        }
    }
    if (unknown > 0) {
        printf(" unknown=%llu", unknown);
    }
    printf("\n");
    free(counts);

out:
    free(pages);
    free(status);
}

int main(int argc, char **argv) {
    size_t arena_mb;
    size_t hot_mb;
    int passes;
    size_t stride_bytes;
    int final_sleep_ms;
    size_t arena_bytes;
    size_t hot_bytes;
    size_t page_size;
    size_t sample_step_bytes = 2UL * 1024UL * 1024UL;
    char *buf;
    volatile uint64_t sink = 0;

    if (argc != 6) {
        fprintf(stderr,
                "usage: %s <arena_mb> <hot_mb> <passes> <stride_bytes> <final_sleep_ms>\n",
                argv[0]);
        return 2;
    }

    arena_mb = strtoull(argv[1], NULL, 0);
    hot_mb = strtoull(argv[2], NULL, 0);
    passes = atoi(argv[3]);
    stride_bytes = strtoull(argv[4], NULL, 0);
    final_sleep_ms = atoi(argv[5]);

    if (arena_mb == 0 || hot_mb == 0 || passes <= 0 || stride_bytes == 0 || final_sleep_ms < 0) {
        fprintf(stderr, "all arguments must be positive, except final_sleep_ms may be 0\n");
        return 3;
    }

    arena_bytes = arena_mb * 1024UL * 1024UL;
    hot_bytes = hot_mb * 1024UL * 1024UL;
    if (hot_bytes > arena_bytes) {
        hot_bytes = arena_bytes;
    }

    page_size = (size_t)sysconf(_SC_PAGESIZE);
    if (sample_step_bytes < page_size) {
        sample_step_bytes = page_size;
    }

    buf = mmap(NULL,
               arena_bytes,
               PROT_READ | PROT_WRITE,
               MAP_PRIVATE | MAP_ANONYMOUS,
               -1,
               0);
    if (buf == MAP_FAILED) {
        fprintf(stderr, "mmap(%zu bytes) failed: %s\n", arena_bytes, strerror(errno));
        return 4;
    }

    madvise(buf, arena_bytes, MADV_HUGEPAGE);

    for (size_t off = 0; off < arena_bytes; off += page_size) {
        buf[off] = (char)(off / page_size);
    }

    printf("arena_mb=%zu hot_mb=%zu passes=%d stride_bytes=%zu final_sleep_ms=%d\n",
           arena_mb, hot_mb, passes, stride_bytes, final_sleep_ms);
    print_sampled_distribution("initial_node_sample", buf, arena_bytes, sample_step_bytes);

    for (int pass = 0; pass < passes; ++pass) {
        for (size_t off = 0; off < hot_bytes; off += stride_bytes) {
            sink += (unsigned char)buf[off];
        }
    }

    if (final_sleep_ms > 0) {
        usleep((useconds_t)final_sleep_ms * 1000U);
    }

    print_sampled_distribution("final_node_sample", buf, arena_bytes, sample_step_bytes);
    printf("sink=%llu\n", (unsigned long long)sink);

    munmap(buf, arena_bytes);
    return 0;
}
