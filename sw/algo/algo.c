/*
 * Algorithm Test Program
 * Demonstrates complex data operations on various data types
 * Includes: QuickSort, FFT, Matrix operations, Statistics
 */

#include <stdio.h>
#include <stdint.h>
#include <math.h>

// Math constants
#define PI 3.14159265358979323846
#define ARRAY_SIZE 16

// ============================================================================
// QuickSort Implementation (Integer)
// ============================================================================

void swap_int(int* a, int* b) {
    int temp = *a;
    *a = *b;
    *b = temp;
}

int partition_int(int arr[], int low, int high) {
    int pivot = arr[high];
    int i = low - 1;

    for (int j = low; j < high; j++) {
        if (arr[j] < pivot) {
            i++;
            swap_int(&arr[i], &arr[j]);
        }
    }
    swap_int(&arr[i + 1], &arr[high]);
    return i + 1;
}

void quicksort_int(int arr[], int low, int high) {
    if (low < high) {
        int pi = partition_int(arr, low, high);
        quicksort_int(arr, low, pi - 1);
        quicksort_int(arr, pi + 1, high);
    }
}

// ============================================================================
// QuickSort Implementation (Float)
// ============================================================================

void swap_float(float* a, float* b) {
    float temp = *a;
    *a = *b;
    *b = temp;
}

int partition_float(float arr[], int low, int high) {
    float pivot = arr[high];
    int i = low - 1;

    for (int j = low; j < high; j++) {
        if (arr[j] < pivot) {
            i++;
            swap_float(&arr[i], &arr[j]);
        }
    }
    swap_float(&arr[i + 1], &arr[high]);
    return i + 1;
}

void quicksort_float(float arr[], int low, int high) {
    if (low < high) {
        int pi = partition_float(arr, low, high);
        quicksort_float(arr, low, pi - 1);
        quicksort_float(arr, pi + 1, high);
    }
}

// ============================================================================
// FFT Implementation (Radix-2 Decimation-in-Time)
// ============================================================================

typedef struct {
    double real;
    double imag;
} Complex;

Complex complex_add(Complex a, Complex b) {
    Complex result;
    result.real = a.real + b.real;
    result.imag = a.imag + b.imag;
    return result;
}

Complex complex_sub(Complex a, Complex b) {
    Complex result;
    result.real = a.real - b.real;
    result.imag = a.imag - b.imag;
    return result;
}

Complex complex_mul(Complex a, Complex b) {
    Complex result;
    result.real = a.real * b.real - a.imag * b.imag;
    result.imag = a.real * b.imag + a.imag * b.real;
    return result;
}

double complex_mag(Complex c) {
    return sqrt(c.real * c.real + c.imag * c.imag);
}

// Bit reversal for FFT
unsigned int reverse_bits(unsigned int x, int n) {
    unsigned int result = 0;
    for (int i = 0; i < n; i++) {
        result = (result << 1) | (x & 1);
        x >>= 1;
    }
    return result;
}

// FFT with N = power of 2
void fft(Complex* data, int n) {
    int bits = 0;
    int temp = n;
    while (temp > 1) {
        temp >>= 1;
        bits++;
    }

    // Bit reversal
    for (unsigned int i = 0; i < (unsigned int)n; i++) {
        unsigned int j = reverse_bits(i, bits);
        if (j > i) {
            Complex tmp = data[i];
            data[i] = data[j];
            data[j] = tmp;
        }
    }

    // FFT computation
    for (int s = 1; s <= bits; s++) {
        int m = 1 << s;
        int m2 = m >> 1;

        Complex w;
        w.real = cos(-2.0 * PI / m);
        w.imag = sin(-2.0 * PI / m);

        for (int k = 0; k < n; k += m) {
            Complex wn;
            wn.real = 1.0;
            wn.imag = 0.0;

            for (int j = 0; j < m2; j++) {
                Complex t = complex_mul(wn, data[k + j + m2]);
                Complex u = data[k + j];
                data[k + j] = complex_add(u, t);
                data[k + j + m2] = complex_sub(u, t);
                wn = complex_mul(wn, w);
            }
        }
    }
}

// ============================================================================
// Matrix Operations (Double precision)
// ============================================================================

#define MATRIX_SIZE 4

void matrix_multiply(double a[MATRIX_SIZE][MATRIX_SIZE],
                     double b[MATRIX_SIZE][MATRIX_SIZE],
                     double result[MATRIX_SIZE][MATRIX_SIZE]) {
    for (int i = 0; i < MATRIX_SIZE; i++) {
        for (int j = 0; j < MATRIX_SIZE; j++) {
            result[i][j] = 0.0;
            for (int k = 0; k < MATRIX_SIZE; k++) {
                result[i][j] += a[i][k] * b[k][j];
            }
        }
    }
}

void matrix_transpose(double matrix[MATRIX_SIZE][MATRIX_SIZE],
                     double result[MATRIX_SIZE][MATRIX_SIZE]) {
    for (int i = 0; i < MATRIX_SIZE; i++) {
        for (int j = 0; j < MATRIX_SIZE; j++) {
            result[j][i] = matrix[i][j];
        }
    }
}

// ============================================================================
// Statistics (Mixed precision)
// ============================================================================

double mean_double(double* data, int n) {
    double sum = 0.0;
    for (int i = 0; i < n; i++) {
        sum += data[i];
    }
    return sum / n;
}

double variance_double(double* data, int n) {
    double m = mean_double(data, n);
    double sum_sq = 0.0;
    for (int i = 0; i < n; i++) {
        double diff = data[i] - m;
        sum_sq += diff * diff;
    }
    return sum_sq / n;
}

float mean_float(float* data, int n) {
    float sum = 0.0f;
    for (int i = 0; i < n; i++) {
        sum += data[i];
    }
    return sum / n;
}

// ============================================================================
// Data Type Operations
// ============================================================================

long long factorial(int n) {
    long long result = 1;
    for (int i = 2; i <= n; i++) {
        result *= i;
    }
    return result;
}

int sum_bytes(char* data, int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) {
        sum += (unsigned char)data[i];
    }
    return sum;
}

long long sum_shorts(short* data, int n) {
    long long sum = 0;
    for (int i = 0; i < n; i++) {
        sum += data[i];
    }
    return sum;
}

// ============================================================================
// Main Test Program
// ============================================================================

int main(void) {
    printf("\n========================================\n");
    printf("  Algorithm & Data Type Test\n");
    printf("========================================\n\n");

    // ========== QuickSort Integer Test ==========
    printf("=== QuickSort (Integer) ===\n");
    int int_array[] = {64, 34, 25, 12, 22, 11, 90, 88};
    int int_n = sizeof(int_array) / sizeof(int_array[0]);

    printf("Original: ");
    for (int i = 0; i < int_n; i++) {
        printf("%d ", int_array[i]);
    }
    printf("\n");

    quicksort_int(int_array, 0, int_n - 1);

    printf("Sorted:   ");
    for (int i = 0; i < int_n; i++) {
        printf("%d ", int_array[i]);
    }
    printf("\n\n");

    // ========== QuickSort Float Test ==========
    printf("=== QuickSort (Float) ===\n");
    float float_array[] = {3.14f, 2.71f, 1.41f, 9.81f, 6.28f};
    int float_n = sizeof(float_array) / sizeof(float_array[0]);

    printf("Original: ");
    for (int i = 0; i < float_n; i++) {
        printf("%.2f ", (double)float_array[i]);
    }
    printf("\n");

    quicksort_float(float_array, 0, float_n - 1);

    printf("Sorted:   ");
    for (int i = 0; i < float_n; i++) {
        printf("%.2f ", (double)float_array[i]);
    }
    printf("\n\n");

    // ========== FFT Test ==========
    printf("=== FFT (Complex Double) ===\n");
    Complex fft_data[ARRAY_SIZE];

    // Generate test signal: sum of two sinusoids
    for (int i = 0; i < ARRAY_SIZE; i++) {
        double t = (double)i / ARRAY_SIZE;
        fft_data[i].real = cos(2.0 * PI * 2.0 * t) + 0.5 * cos(2.0 * PI * 5.0 * t);
        fft_data[i].imag = 0.0;
    }

    printf("Input signal (first 8 samples):\n");
    for (int i = 0; i < 8; i++) {
        printf("  [%d] %.3f\n", i, fft_data[i].real);
    }

    fft(fft_data, ARRAY_SIZE);

    printf("FFT Magnitude (first 8 bins):\n");
    for (int i = 0; i < 8; i++) {
        printf("  [%d] %.3f\n", i, complex_mag(fft_data[i]));
    }
    printf("\n");

    // ========== Matrix Operations ==========
    printf("=== Matrix Operations (Double) ===\n");
    double mat_a[MATRIX_SIZE][MATRIX_SIZE] = {
        {1.0, 2.0, 3.0, 4.0},
        {5.0, 6.0, 7.0, 8.0},
        {9.0, 10.0, 11.0, 12.0},
        {13.0, 14.0, 15.0, 16.0}
    };

    double mat_b[MATRIX_SIZE][MATRIX_SIZE] = {
        {1.0, 0.0, 0.0, 0.0},
        {0.0, 1.0, 0.0, 0.0},
        {0.0, 0.0, 1.0, 0.0},
        {0.0, 0.0, 0.0, 1.0}
    };

    double mat_result[MATRIX_SIZE][MATRIX_SIZE];

    matrix_multiply(mat_a, mat_b, mat_result);
    printf("Matrix A * I (first row): ");
    for (int j = 0; j < MATRIX_SIZE; j++) {
        printf("%.1f ", mat_result[0][j]);
    }
    printf("\n");

    matrix_transpose(mat_a, mat_result);
    printf("Transpose (first row):    ");
    for (int j = 0; j < MATRIX_SIZE; j++) {
        printf("%.1f ", mat_result[0][j]);
    }
    printf("\n\n");

    // ========== Statistics Test ==========
    printf("=== Statistics ===\n");
    double double_data[] = {1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0};
    int stats_n = sizeof(double_data) / sizeof(double_data[0]);

    double mean = mean_double(double_data, stats_n);
    double var = variance_double(double_data, stats_n);

    printf("Data: ");
    for (int i = 0; i < stats_n; i++) {
        printf("%.0f ", double_data[i]);
    }
    printf("\n");
    printf("Mean:     %.2f\n", mean);
    printf("Variance: %.2f\n", var);
    printf("Std Dev:  %.2f\n\n", sqrt(var));

    // ========== Data Type Operations ==========
    printf("=== Data Type Operations ===\n");

    // Char operations
    char byte_data[] = {10, 20, 30, 40, 50};
    int byte_sum = sum_bytes(byte_data, 5);
    printf("Byte sum (char):    %d\n", byte_sum);

    // Short operations
    short short_data[] = {1000, 2000, 3000, 4000};
    long long short_sum = sum_shorts(short_data, 4);
    printf("Sum (short):        %lld\n", short_sum);

    // Long long operations
    long long factorial_10 = factorial(10);
    printf("Factorial 10:       %lld\n", factorial_10);

    // Mixed precision
    float float_values[] = {1.1f, 2.2f, 3.3f, 4.4f};
    float float_mean = mean_float(float_values, 4);
    printf("Mean (float):       %.2f\n", (double)float_mean);

    // Type conversions
    int int_val = 12345;
    float float_val = (float)int_val;
    double double_val = (double)int_val;
    printf("Int to Float:       %d -> %.1f\n", int_val, (double)float_val);
    printf("Int to Double:      %d -> %.1f\n", int_val, double_val);

    long long ll_val = 9876543210LL;
    double ll_to_double = (double)ll_val;
    printf("Long Long to Double: %lld -> %.0f\n", ll_val, ll_to_double);

    printf("\n========================================\n");
    printf("  All Algorithm Tests Complete\n");
    printf("========================================\n\n");

    return 0;
}
