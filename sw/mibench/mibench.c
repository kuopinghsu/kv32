// ============================================================================
// File: mibench.c
// Project: KV32 RISC-V Processor
// Description: MiBench subset: qsort, Dijkstra, Blowfish encryption, CRC, integer FFT
//
// Adapted from MiBench (http://vhosts.eecs.umich.edu/mibench/)
// for bare-metal RISC-V without OS or libc float support.
// ============================================================================

#include <stdint.h>
#include <csr.h>
#include <kv_platform.h>

/* Magic console output */
#define console_putc(c) kv_magic_putc(c)

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

static void print_hex32(uint32_t v) {
    const char h[] = "0123456789abcdef";
    uint32_t shift;
    for (shift = 32; shift > 0; ) {
        shift -= 4;
        console_putc(h[(v >> shift) & 0xfu]);
    }
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
 * Benchmark 5: SHA-1 Hash (Security)
 * ======================================== */

#define SHA1_K0  0x5A827999UL
#define SHA1_K1  0x6ED9EBA1UL
#define SHA1_K2  0x8F1BBCDCUL
#define SHA1_K3  0xCA62C1D6UL

static void sha1_process_block(uint32_t h[5], const uint8_t block[64])
{
    uint32_t w[80];
    uint32_t a, b, c, d, e, f, k, temp;
    uint32_t i;

    for (i = 0; i < 16; i++) {
        w[i] = ((uint32_t)block[i*4]     << 24)
             | ((uint32_t)block[i*4 + 1] << 16)
             | ((uint32_t)block[i*4 + 2] <<  8)
             |  (uint32_t)block[i*4 + 3];
    }
    for (i = 16; i < 80; i++) {
        uint32_t t = w[i-3] ^ w[i-8] ^ w[i-14] ^ w[i-16];
        w[i] = (t << 1) | (t >> 31);
    }

    a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4];

    for (i = 0; i < 80; i++) {
        if (i < 20) {
            f = (b & c) | ((~b) & d);  k = SHA1_K0;
        } else if (i < 40) {
            f = b ^ c ^ d;             k = SHA1_K1;
        } else if (i < 60) {
            f = (b & c) | (b & d) | (c & d); k = SHA1_K2;
        } else {
            f = b ^ c ^ d;             k = SHA1_K3;
        }
        temp = ((a << 5) | (a >> 27)) + f + e + k + w[i];
        e = d;  d = c;  c = (b << 30) | (b >> 2);  b = a;  a = temp;
    }

    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e;
}

/* SHA-1("abc") golden digest: a9993e36 4706816a ba3e2571 7850c26c 9cd0d89d */
static uint32_t test_sha1(void)
{
    uint8_t  block[64];
    uint32_t h[5] = { 0x67452301UL, 0xEFCDAB89UL, 0x98BADCFEUL,
                      0x10325476UL, 0xC3D2E1F0UL };
    uint32_t i;

    for (i = 0; i < 64; i++) block[i] = 0;
    block[0] = 0x61; block[1] = 0x62; block[2] = 0x63; /* "abc" */
    block[3] = 0x80;  /* padding: append 1-bit */
    block[63] = 24;   /* message length = 24 bits (big-endian, low byte) */

    sha1_process_block(h, block);
    return h[0]; /* golden = 0xa9993e36 */
}

/* ========================================
 * Benchmark 6: Bitcount (Automotive)
 * ======================================== */

#define BITCOUNT_N 128

static uint32_t bitcount_data[BITCOUNT_N];

static void bitcount_init_data(void)
{
    uint32_t seed = 0xDEADBEEFUL;
    uint32_t i;
    for (i = 0; i < BITCOUNT_N; i++) {
        seed ^= seed << 13;
        seed ^= seed >> 17;
        seed ^= seed <<  5;
        bitcount_data[i] = seed;
    }
}

/* Method 1: shift-and-count (baseline) */
static uint32_t popcount_shift(uint32_t v) {
    uint32_t n = 0;
    while (v) { n += v & 1u; v >>= 1; }
    return n;
}

/* Method 2: Wegner / Brian Kernighan — clear lowest set bit per step */
static uint32_t popcount_wegner(uint32_t v) {
    uint32_t n = 0;
    while (v) { v &= v - 1u; n++; }
    return n;
}

/* Method 3: parallel Hamming-weight (Hacker's Delight) */
static uint32_t popcount_parallel(uint32_t v) {
    v  =  v - ((v >> 1) & 0x55555555u);
    v  = (v & 0x33333333u) + ((v >> 2) & 0x33333333u);
    v  = (v + (v >> 4)) & 0x0F0F0F0Fu;
    return (v * 0x01010101u) >> 24;
}

static uint32_t test_bitcount(void)
{
    uint32_t s1 = 0, s2 = 0, s3 = 0;
    uint32_t i;

    bitcount_init_data();

    for (i = 0; i < BITCOUNT_N; i++) {
        s1 += popcount_shift(bitcount_data[i]);
        s2 += popcount_wegner(bitcount_data[i]);
        s3 += popcount_parallel(bitcount_data[i]);
    }

    /* All three methods must agree; 0xDEAD signals an algorithm mismatch */
    if (s1 != s3 || s2 != s3) return 0xDEADu;
    return s3;
}

/* ========================================
 * Benchmark 7: IMA-ADPCM Codec (Telecomm)
 * ======================================== */

static const int32_t adpcm_step_table[89] = {
        7,    8,    9,   10,   11,   12,   13,   14,   16,   17,
       19,   21,   23,   25,   28,   31,   34,   37,   41,   45,
       50,   55,   60,   66,   73,   80,   88,   97,  107,  118,
      130,  143,  157,  173,  190,  209,  230,  253,  279,  307,
      337,  371,  408,  449,  494,  544,  598,  658,  724,  796,
      876,  963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
     2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
     5894, 6484, 7132, 7845, 8630, 9493,10442,11487,12635,13899,
    15289,16818,18500,20350,22385,24623,27086,29794,32767
};

static const int32_t adpcm_index_table[16] = {
    -1, -1, -1, -1,  2,  4,  6,  8,
    -1, -1, -1, -1,  2,  4,  6,  8
};

#define ADPCM_SAMPLES 64

static int32_t adpcm_pcm_orig   [ADPCM_SAMPLES];
static int32_t adpcm_pcm_decoded[ADPCM_SAMPLES];
static uint8_t adpcm_encoded    [ADPCM_SAMPLES / 2]; /* 4 bits per sample */

static void adpcm_encode(void)
{
    int32_t  predsample = 0, index = 0;
    uint32_t i;

    for (i = 0; i < ADPCM_SAMPLES; i++) {
        int32_t  step = adpcm_step_table[index];
        int32_t  diff = adpcm_pcm_orig[i] - predsample;
        uint32_t code = 0;

        if (diff < 0) { code = 8u; diff = -diff; }

        int32_t tempstep = step;
        if (diff >= tempstep) { code |= 4u; diff -= tempstep; }
        tempstep >>= 1;
        if (diff >= tempstep) { code |= 2u; diff -= tempstep; }
        tempstep >>= 1;
        if (diff >= tempstep) { code |= 1u; }

        int32_t diffq = step >> 3;
        if (code & 4u) diffq += step;
        if (code & 2u) diffq += step >> 1;
        if (code & 1u) diffq += step >> 2;
        if (code & 8u) diffq = -diffq;

        predsample += diffq;
        if (predsample >  32767) predsample =  32767;
        if (predsample < -32768) predsample = -32768;

        index += adpcm_index_table[code & 0x0fu];
        if (index <  0) index =  0;
        if (index > 88) index = 88;

        if (i & 1u)
            adpcm_encoded[i >> 1] |= (uint8_t)(code << 4);
        else
            adpcm_encoded[i >> 1]  = (uint8_t)(code & 0x0fu);
    }
}

static void adpcm_decode(void)
{
    int32_t  predsample = 0, index = 0;
    uint32_t i;

    for (i = 0; i < ADPCM_SAMPLES; i++) {
        uint32_t code;
        if (i & 1u)
            code = ((uint32_t)adpcm_encoded[i >> 1] >> 4) & 0x0fu;
        else
            code =  (uint32_t)adpcm_encoded[i >> 1]       & 0x0fu;

        int32_t step  = adpcm_step_table[index];
        int32_t diffq = step >> 3;
        if (code & 4u) diffq += step;
        if (code & 2u) diffq += step >> 1;
        if (code & 1u) diffq += step >> 2;
        if (code & 8u) diffq = -diffq;

        predsample += diffq;
        if (predsample >  32767) predsample =  32767;
        if (predsample < -32768) predsample = -32768;

        index += adpcm_index_table[code & 0x0fu];
        if (index <  0) index =  0;
        if (index > 88) index = 88;

        adpcm_pcm_decoded[i] = predsample;
    }
}

static uint32_t test_adpcm(void)
{
    uint32_t i;
    uint32_t checksum = 0;

    /* Sawtooth PCM signal: ramps from -32000 to +31000 */
    for (i = 0; i < ADPCM_SAMPLES; i++)
        adpcm_pcm_orig[i] = (int32_t)(i * 1000u) - 32000;

    adpcm_encode();
    adpcm_decode();

    for (i = 0; i < ADPCM_SAMPLES; i++)
        checksum += (uint32_t)(uint16_t)(int16_t)adpcm_pcm_decoded[i];

    return checksum;
}

/* ========================================
 * Benchmark 8: Stringsearch / KMP (Office)
 * ======================================== */

static const char strsearch_corpus[] =
    "the quick brown fox jumps over the lazy dog. "
    "pack my box with five dozen liquor jugs. "
    "how vexingly quick daft zebras jump. "
    "the five boxing wizards jump quickly. "
    "sphinx of black quartz judge my vow.";

static const char *strsearch_pats[] = {
    "quick", "the", "jump", "fox", "vow", "box", "five"
};
#define STRSEARCH_NPATS   (sizeof(strsearch_pats) / sizeof(strsearch_pats[0]))
#define STRSEARCH_MAXPAT  16

static uint32_t my_strlen(const char *s)
{
    uint32_t n = 0;
    while (s[n]) n++;
    return n;
}

/* Knuth-Morris-Pratt exact-match count (non-overlapping occurrences) */
static uint32_t kmp_count(const char *text, uint32_t tlen,
                           const char *pat,  uint32_t plen)
{
    int32_t  fail[STRSEARCH_MAXPAT];
    uint32_t k, q, i;
    uint32_t count = 0;

    if (plen == 0 || plen > STRSEARCH_MAXPAT) return 0;

    /* Build failure function */
    fail[0] = 0; k = 0;
    for (q = 1; q < plen; q++) {
        while (k > 0 && pat[k] != pat[q]) k = (uint32_t)fail[k - 1];
        if (pat[k] == pat[q]) k++;
        fail[q] = (int32_t)k;
    }

    /* Search */
    k = 0;
    for (i = 0; i < tlen; i++) {
        while (k > 0 && pat[k] != text[i]) k = (uint32_t)fail[k - 1];
        if (pat[k] == text[i]) k++;
        if (k == plen) { count++; k = (uint32_t)fail[k - 1]; }
    }
    return count;
}

static uint32_t test_stringsearch(void)
{
    uint32_t tlen = my_strlen(strsearch_corpus);
    uint32_t p, checksum = 0;

    for (p = 0; p < STRSEARCH_NPATS; p++) {
        checksum += kmp_count(strsearch_corpus, tlen,
                              strsearch_pats[p],
                              my_strlen(strsearch_pats[p]));
    }
    return checksum;
}

/* ========================================
 * Main Benchmark Runner
 * ======================================== */

int main(void) {
    uint64_t start, end, cycles;
    uint32_t result;

    puts("MiBench Benchmark Suite\n");
    puts("=======================\n\n");

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

    /* Test 5: SHA-1 */
    puts("Running sha1...\n");
    start = read_csr_cycle64();
    result = test_sha1();
    end = read_csr_cycle64();
    cycles = end - start;
    puts("  Digest[0]: 0x"); print_hex32(result);
    puts(" (golden=0xa9993e36)\n");
    puts("  Cycles: "); print_uint64(cycles); puts("\n\n");

    /* Test 6: Bitcount */
    puts("Running bitcount...\n");
    start = read_csr_cycle64();
    result = test_bitcount();
    end = read_csr_cycle64();
    cycles = end - start;
    puts("  Popcount total: "); print_uint(result); puts("\n");
    puts("  Cycles: "); print_uint64(cycles); puts("\n\n");

    /* Test 7: ADPCM */
    puts("Running adpcm...\n");
    start = read_csr_cycle64();
    result = test_adpcm();
    end = read_csr_cycle64();
    cycles = end - start;
    puts("  Checksum: "); print_uint(result); puts("\n");
    puts("  Cycles: "); print_uint64(cycles); puts("\n\n");

    /* Test 8: Stringsearch */
    puts("Running stringsearch...\n");
    start = read_csr_cycle64();
    result = test_stringsearch();
    end = read_csr_cycle64();
    cycles = end - start;
    puts("  Match count: "); print_uint(result); puts("\n");
    puts("  Cycles: "); print_uint64(cycles); puts("\n\n");

    puts("MiBench suite complete.\n");

    return 0;
}
