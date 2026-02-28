// GDB Remote Serial Protocol Stub for KV32 Simulator
// Provides debugging capabilities through GDB remote protocol

#ifndef GDB_STUB_H
#define GDB_STUB_H

#include <stdint.h>
#include <stdbool.h>

#define GDB_BUFFER_SIZE 4096

// GDB stub state
typedef struct {
    int socket_fd;
    int client_fd;
    uint16_t port;
    bool connected;
    bool enabled;
    char packet_buffer[GDB_BUFFER_SIZE];
    int packet_size;
} gdb_stub_t;

// Breakpoint management
typedef struct {
    uint32_t addr;
    bool enabled;
} breakpoint_t;

// Watchpoint types
typedef enum {
    WATCHPOINT_WRITE = 2,  // Z2: write watchpoint
    WATCHPOINT_READ = 3,   // Z3: read watchpoint
    WATCHPOINT_ACCESS = 4  // Z4: access (read+write) watchpoint
} watchpoint_type_t;

// Watchpoint management
typedef struct {
    uint32_t addr;
    uint32_t len;
    watchpoint_type_t type;
    bool enabled;
} watchpoint_t;

#define MAX_BREAKPOINTS 64
#define MAX_WATCHPOINTS 32

// GDB stub interface
typedef struct {
    gdb_stub_t stub;
    breakpoint_t breakpoints[MAX_BREAKPOINTS];
    int breakpoint_count;
    watchpoint_t watchpoints[MAX_WATCHPOINTS];
    int watchpoint_count;
    bool single_step;
    bool should_stop;
    uint32_t last_watchpoint_addr;  // Address of last hit watchpoint
    int last_stop_signal;           // Last stop signal sent
    bool breakpoint_hit;            // Flag indicating breakpoint was hit
} gdb_context_t;

// Callback functions for simulator access
typedef struct {
    uint32_t (*read_reg)(void *sim, int reg_num);
    void (*write_reg)(void *sim, int reg_num, uint32_t value);
    uint32_t (*read_mem)(void *sim, uint32_t addr, int size);
    void (*write_mem)(void *sim, uint32_t addr, uint32_t value, int size);
    uint32_t (*get_pc)(void *sim);
    void (*set_pc)(void *sim, uint32_t pc);
    void (*single_step)(void *sim);
    bool (*is_running)(void *sim);
    void (*reset)(void *sim);  // Optional: reset the simulator state
    void (*resume)(void *sim);  // Optional: resume execution (clear halted flag)
} gdb_callbacks_t;

#ifdef __cplusplus
extern "C" {
#endif

// Initialize GDB stub
int gdb_stub_init(gdb_context_t *ctx, uint16_t port);

// Accept client connection
int gdb_stub_accept(gdb_context_t *ctx);

// Process GDB commands
int gdb_stub_process(gdb_context_t *ctx, void *simulator,
                     const gdb_callbacks_t *callbacks);

// Check if should stop at current PC
bool gdb_stub_check_breakpoint(gdb_context_t *ctx, uint32_t pc);

// Close GDB stub
void gdb_stub_close(gdb_context_t *ctx);

// Helper functions
int gdb_stub_add_breakpoint(gdb_context_t *ctx, uint32_t addr);
int gdb_stub_remove_breakpoint(gdb_context_t *ctx, uint32_t addr);
void gdb_stub_clear_breakpoints(gdb_context_t *ctx);

// Watchpoint functions
int gdb_stub_add_watchpoint(gdb_context_t *ctx, uint32_t addr, uint32_t len, watchpoint_type_t type);
int gdb_stub_remove_watchpoint(gdb_context_t *ctx, uint32_t addr, uint32_t len, watchpoint_type_t type);
bool gdb_stub_check_watchpoint_read(gdb_context_t *ctx, uint32_t addr, uint32_t len);
bool gdb_stub_check_watchpoint_write(gdb_context_t *ctx, uint32_t addr, uint32_t len);
void gdb_stub_clear_watchpoints(gdb_context_t *ctx);

// Send stop signal to GDB
int gdb_stub_send_stop_signal(gdb_context_t *ctx, int signal);

// Enhanced stop reason reporting
int gdb_stub_send_stop_reason(gdb_context_t *ctx, int signal, uint32_t addr);

#ifdef __cplusplus
}
#endif

#endif // GDB_STUB_H
