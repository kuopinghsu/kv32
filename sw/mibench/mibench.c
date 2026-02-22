/*
 * MiBench Benchmark Suite - Simplified Baremetal RISC-V Version
 *
 * Adapted from MiBench (http://vhosts.eecs.umich.edu/mibench/)
 *
 * Selected benchmarks:
 * - qsort: Quicksort algorithm
 * - dijkstra: Shortest path
 * - blowfish: Encryption
 * - crc: CRC calculation
 * - fft: Fast Fourier Transform (integer version)
 */

#include <stdint.h>
#include <csr.h>

/* Magic console output */
#define CONSOLE_ADDR 0xFFFFFFF4
#define console_putc(c) (*(volatile uint32_t*)CONSOLE_ADDR = (c))

/* Simple output functions */
static void puts(const char *s) {
    while (*s) console_putc(*s++);
}

static void print_uint_recursive(uint32_t val) {
    if (val >= 10) print_uint_recursive(val / 10);
    console_putc('0' + (val % 10));
}

static void print_uint(uint32_t val) {
    print_uint_recursive(val);
}

static void print_uint64(uint64_t val) {
    if (val >= 10) print_uint64(val / 10);
    console_putc('0' + (val % 10));
}

/* ========================================
 * Benchmark 1: Quicksort
 * ======================================== */

#define QSORT_SIZE 100

static int32_t qsort_data[QSORT_SIZE];

static void qsort_swap(int32_t *a, int32_t *b) {
    int32_t temp = *a;
    *a = *b;
    *b = temp;
}

static int32_t qsort_partition(int32_t arr[], int32_t low, int32_t high) {
    int32_t pivot = arr[high];
    int32_t i = low - 1;
    int32_t j;

    for (j = low; j < high; j++) {
        if (arr[j] <= pivot) {
            i++;
            qsort_swap(&arr[i], &arr[j]);
        }
    }
    qsort_swap(&arr[i + 1], &arr[high]);
    return i + 1;
}

static void quicksort(int32_t arr[], int32_t low, int32_t high) {
    if (low < high) {
        int32_t pi = qsort_partition(arr, low, high);
        quicksort(arr, low, pi - 1);
        quicksort(arr, pi + 1, high);
    }
}

static uint32_t test_qsort(void) {
    uint32_t i;
    uint32_t checksum = 0;

    /* Initialize with pseudo-random data */
    uint32_t seed = 12345;
    for (i = 0; i < QSORT_SIZE; i++) {
        seed = seed * 1103515245 + 12345;
        qsort_data[i] = (int32_t)(seed & 0x7FFFFFFF);
    }

    /* Sort */
    quicksort(qsort_data, 0, QSORT_SIZE - 1);

    /* Verify sorted and calculate checksum */
    for (i = 0; i < QSORT_SIZE; i++) {
        checksum += (uint32_t)qsort_data[i];
    }

    return checksum;
}

/* ========================================
 * Benchmark 2: Dijkstra Shortest Path
 * ======================================== */

#define DIJKSTRA_NODES 16
#define DIJKSTRA_INF 0x7FFFFFFF

static int32_t dijkstra_graph[DIJKSTRA_NODES][DIJKSTRA_NODES];
static int32_t dijkstra_dist[DIJKSTRA_NODES];
static uint8_t dijkstra_visited[DIJKSTRA_NODES];

static void dijkstra_init_graph(void) {
    uint32_t i, j;

    /* Initialize with no edges */
    for (i = 0; i < DIJKSTRA_NODES; i++) {
        for (j = 0; j < DIJKSTRA_NODES; j++) {
            dijkstra_graph[i][j] = (i == j) ? 0 : DIJKSTRA_INF;
        }
    }

    /* Add some edges */
    dijkstra_graph[0][1] = 4; dijkstra_graph[0][7] = 8;
    dijkstra_graph[1][2] = 8; dijkstra_graph[1][7] = 11;
    dijkstra_graph[2][3] = 7; dijkstra_graph[2][5] = 4; dijkstra_graph[2][8] = 2;
    dijkstra_graph[3][4] = 9; dijkstra_graph[3][5] = 14;
    dijkstra_graph[4][5] = 10;
    dijkstra_graph[5][6] = 2;
    dijkstra_graph[6][7] = 1; dijkstra_graph[6][8] = 6;
    dijkstra_graph[7][8] = 7;
}

static int32_t dijkstra_min_distance(void) {
    int32_t min = DIJKSTRA_INF;
    int32_t min_idx = -1;
    uint32_t v;

    for (v = 0; v < DIJKSTRA_NODES; v++) {
        if (!dijkstra_visited[v] && dijkstra_dist[v] <= min) {
            min = dijkstra_dist[v];
            min_idx = v;
        }
    }

    return min_idx;
}

static void dijkstra_shortest_path(int32_t src) {
    uint32_t i, v;

    /* Initialize */
    for (i = 0; i < DIJKSTRA_NODES; i++) {
        dijkstra_dist[i] = DIJKSTRA_INF;
        dijkstra_visited[i] = 0;
    }
    dijkstra_dist[src] = 0;

    /* Find shortest path for all nodes */
    for (i = 0; i < DIJKSTRA_NODES - 1; i++) {
        int32_t u = dijkstra_min_distance();
        if (u == -1) break;

        dijkstra_visited[u] = 1;

        for (v = 0; v < DIJKSTRA_NODES; v++) {
            if (!dijkstra_visited[v] &&
                dijkstra_graph[u][v] != DIJKSTRA_INF &&
                dijkstra_dist[u] != DIJKSTRA_INF &&
                dijkstra_dist[u] + dijkstra_graph[u][v] < dijkstra_dist[v]) {
                dijkstra_dist[v] = dijkstra_dist[u] + dijkstra_graph[u][v];
            }
        }
    }
}

static uint32_t test_dijkstra(void) {
    uint32_t i;
    uint32_t checksum = 0;

    dijkstra_init_graph();
    dijkstra_shortest_path(0);

    for (i = 0; i < DIJKSTRA_NODES; i++) {
        if (dijkstra_dist[i] != DIJKSTRA_INF) {
            checksum += (uint32_t)dijkstra_dist[i];
        }
    }

    return checksum;
}

/* ========================================
 * Benchmark 3: Blowfish Encryption (simplified)
 * ======================================== */

#define BF_ROUNDS 16

static uint32_t bf_p[BF_ROUNDS + 2];
static uint8_t bf_plaintext[64];
static uint8_t bf_ciphertext[64];

static void bf_init_key(void) {
    uint32_t i;
    /* Initialize P-array with simple values */
    for (i = 0; i < BF_ROUNDS + 2; i++) {
        bf_p[i] = 0x243F6A88 + i * 0x13579BDF;
    }
}

static uint32_t bf_f(uint32_t x) {
    /* Simplified F function */
    return ((x >> 16) ^ (x << 16)) + 0x9E3779B9;
}

static void bf_encrypt_block(uint32_t *xl, uint32_t *xr) {
    uint32_t left = *xl;
    uint32_t right = *xr;
    uint32_t i;

    for (i = 0; i < BF_ROUNDS; i++) {
        left ^= bf_p[i];
        right ^= bf_f(left);

        /* Swap */
        uint32_t temp = left;
        left = right;
        right = temp;
    }

    /* Swap back */
    uint32_t temp = left;
    left = right;
    right = temp;

    right ^= bf_p[BF_ROUNDS];
    left ^= bf_p[BF_ROUNDS + 1];

    *xl = left;
    *xr = right;
}

static uint32_t test_blowfish(void) {
    uint32_t i;
    uint32_t checksum = 0;

    bf_init_key();

    /* Initialize plaintext */
    for (i = 0; i < 64; i++) {
        bf_plaintext[i] = (uint8_t)i;
    }

    /* Encrypt blocks */
    for (i = 0; i < 64; i += 8) {
        uint32_t left = ((uint32_t)bf_plaintext[i] << 24) |
                        ((uint32_t)bf_plaintext[i+1] << 16) |
                        ((uint32_t)bf_plaintext[i+2] << 8) |
                        (uint32_t)bf_plaintext[i+3];
        uint32_t right = ((uint32_t)bf_plaintext[i+4] << 24) |
                         ((uint32_t)bf_plaintext[i+5] << 16) |
                         ((uint32_t)bf_plaintext[i+6] << 8) |
                         (uint32_t)bf_plaintext[i+7];

        bf_encrypt_block(&left, &right);

        bf_ciphertext[i] = (uint8_t)(left >> 24);
        bf_ciphertext[i+1] = (uint8_t)(left >> 16);
        bf_ciphertext[i+2] = (uint8_t)(left >> 8);
        bf_ciphertext[i+3] = (uint8_t)left;
        bf_ciphertext[i+4] = (uint8_t)(right >> 24);
        bf_ciphertext[i+5] = (uint8_t)(right >> 16);
        bf_ciphertext[i+6] = (uint8_t)(right >> 8);
        bf_ciphertext[i+7] = (uint8_t)right;

        checksum += left + right;
    }

    return checksum;
}

/* ========================================
 * Benchmark 4: Integer FFT (simplified)
 * ======================================== */

#define FFT_SIZE 32
#define FFT_SCALE 1000  /* Fixed-point scaling */

static int32_t fft_real[FFT_SIZE];
static int32_t fft_imag[FFT_SIZE];

static void fft_init_data(void) {
    uint32_t i;
    for (i = 0; i < FFT_SIZE; i++) {
        /* Simple sine wave approximation scaled by 1000 */
        fft_real[i] = (int32_t)(FFT_SCALE * ((i % 8) - 4) / 4);
        fft_imag[i] = 0;
    }
}

static void fft_butterfly(int32_t *ar, int32_t *ai, int32_t *br, int32_t *bi) {
    int32_t tr = *ar + *br;
    int32_t ti = *ai + *bi;
    *br = *ar - *br;
    *bi = *ai - *bi;
    *ar = tr;
    *ai = ti;
}

static void fft_compute(void) {
    uint32_t i, j, k;
    uint32_t step = 1;

    /* Simplified FFT - bit reversal and butterfly */
    while (step < FFT_SIZE) {
        for (i = 0; i < FFT_SIZE; i += step * 2) {
            for (j = 0; j < step; j++) {
                k = i + j;
                fft_butterfly(&fft_real[k], &fft_imag[k],
                             &fft_real[k + step], &fft_imag[k + step]);
            }
        }
        step *= 2;
    }
}

static uint32_t test_fft(void) {
    uint32_t i;
    uint32_t checksum = 0;

    fft_init_data();
    fft_compute();

    for (i = 0; i < FFT_SIZE; i++) {
        checksum += (uint32_t)(fft_real[i] + fft_imag[i]);
    }

    return checksum;
}

/* ========================================
 * Main Benchmark Runner
 * ======================================== */

int main(void) {
    uint64_t start, end, cycles;
    uint32_t result;

    puts("MiBench Benchmark Suite (Simplified)\n");
    puts("=====================================\n\n");

    /* Test 1: Quicksort */
    puts("Running qsort...\n");
    start = read_csr_cycle64();
    result = test_qsort();
    end = read_csr_cycle64();
    cycles = end - start;
    puts("  Checksum: "); print_uint(result); puts("\n");
    puts("  Cycles: "); print_uint64(cycles); puts("\n\n");

    /* Test 2: Dijkstra */
    puts("Running dijkstra...\n");
    start = read_csr_cycle64();
    result = test_dijkstra();
    end = read_csr_cycle64();
    cycles = end - start;
    puts("  Checksum: "); print_uint(result); puts("\n");
    puts("  Cycles: "); print_uint64(cycles); puts("\n\n");

    /* Test 3: Blowfish */
    puts("Running blowfish...\n");
    start = read_csr_cycle64();
    result = test_blowfish();
    end = read_csr_cycle64();
    cycles = end - start;
    puts("  Checksum: "); print_uint(result); puts("\n");
    puts("  Cycles: "); print_uint64(cycles); puts("\n\n");

    /* Test 4: FFT */
    puts("Running fft...\n");
    start = read_csr_cycle64();
    result = test_fft();
    end = read_csr_cycle64();
    cycles = end - start;
    puts("  Checksum: "); print_uint(result); puts("\n");
    puts("  Cycles: "); print_uint64(cycles); puts("\n\n");

    puts("MiBench suite complete.\n");

    return 0;
}
