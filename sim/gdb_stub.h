/**
 * @file gdb_stub.h
 * @brief GDB Remote Serial Protocol stub for the KV32 functional simulator.
 *
 * Provides hardware breakpoints, watchpoints, register/memory access via
 * the GDB remote protocol over a TCP socket.  Used by kv32sim.cpp to
 * enable GDB-based debugging of bare-metal firmware.
 * @defgroup gdb GDB Stub
 * @{
 */
// GDB Remote Serial Protocol Stub for KV32 Simulator
// Provides debugging capabilities through GDB remote protocol

#ifndef GDB_STUB_H
#define GDB_STUB_H

#include <stdint.h>
#include <stdbool.h>

#define GDB_BUFFER_SIZE 4096

/** @brief State for one GDB remote connection. */
typedef struct {
    int socket_fd;   /**< Listening socket file descriptor. */
    int client_fd;   /**< Connected client file descriptor (-1 if none). */
    uint16_t port;   /**< TCP port number. */
    bool connected;  /**< True when a GDB client is attached. */
    bool enabled;    /**< Stub enabled flag. */
    char packet_buffer[GDB_BUFFER_SIZE]; /**< Packet reassembly buffer. */
    int packet_size; /**< Number of valid bytes in packet_buffer. */
} gdb_stub_t;

/** @brief Software breakpoint record. */
typedef struct {
    uint32_t addr; /**< Breakpoint address. */
    bool enabled;  /**< Active flag. */
} breakpoint_t;

/** @brief Watchpoint categories (GDB Z-packet type codes). */
typedef enum {
    WATCHPOINT_WRITE  = 2,  /**< Z2: write watchpoint */
    WATCHPOINT_READ   = 3,  /**< Z3: read watchpoint */
    WATCHPOINT_ACCESS = 4   /**< Z4: access (read+write) watchpoint */
} watchpoint_type_t;

/** @brief Watchpoint record. */
typedef struct {
    uint32_t addr;          /**< Watchpoint address. */
    uint32_t len;           /**< Range length in bytes. */
    watchpoint_type_t type; /**< Read/write/access. */
    bool enabled;           /**< Active flag. */
} watchpoint_t;

#define MAX_BREAKPOINTS 64
#define MAX_WATCHPOINTS 32

/** @brief Top-level GDB stub context (passed to all gdb_stub_* functions). */
typedef struct {
    gdb_stub_t stub;
    breakpoint_t breakpoints[MAX_BREAKPOINTS];
    int breakpoint_count;
    watchpoint_t watchpoints[MAX_WATCHPOINTS];
    int watchpoint_count;
    bool single_step;              /**< Single-step mode active. */
    bool should_stop;              /**< Stop flag checked by the run loop. */
    uint32_t last_watchpoint_addr; /**< Address of the last triggered watchpoint. */
    int last_stop_signal;          /**< Last stop signal sent to GDB. */
    bool breakpoint_hit;           /**< Set when a breakpoint match is detected. */
    uint32_t current_thread_id;    /**< Selected thread for register operations. */
    uint32_t resume_thread_id;     /**< Selected thread for resume operations. */
} gdb_context_t;

/** @brief Simulator callback table for GDB stub memory/register access. */
typedef struct {
    uint32_t (*read_reg)(void *sim, int reg_num);    /**< Read integer register. */
    void     (*write_reg)(void *sim, int reg_num, uint32_t value); /**< Write integer register. */
    uint32_t (*read_mem)(void *sim, uint32_t addr, int size);      /**< Read memory. */
    void     (*write_mem)(void *sim, uint32_t addr, uint32_t value, int size); /**< Write memory. */
    uint32_t (*get_pc)(void *sim);         /**< Get program counter. */
    void     (*set_pc)(void *sim, uint32_t pc);    /**< Set program counter. */
    void     (*single_step)(void *sim);    /**< Execute one instruction. */
    bool     (*is_running)(void *sim);     /**< True if CPU is running. */
    void     (*reset)(void *sim);          /**< Optional: reset simulator state. */
    void     (*resume)(void *sim);         /**< Optional: clear halted flag. */
    int      (*get_thread_list)(void *sim, uint32_t *thread_ids, int max_threads,
                                uint32_t *current_thread_id); /**< Optional: enumerate threads. */
    int      (*get_thread_extra_info)(void *sim, uint32_t thread_id, char *buf,
                                      int buf_size); /**< Optional: per-thread description. */
} gdb_callbacks_t;

#ifdef __cplusplus
extern "C" {
#endif

/** @brief Initialise the GDB stub and start listening on @p port.
 * @param ctx GDB context to initialise.
 * @param port TCP port number (default ::GDB_DEFAULT_PORT).
 * @return 0 on success, -1 on error. */
int gdb_stub_init(gdb_context_t *ctx, uint16_t port);

/** @brief Accept an incoming GDB client connection (non-blocking).
 * @return 1 if connected, 0 if no client yet, -1 on error. */
int gdb_stub_accept(gdb_context_t *ctx);

/** @brief Process pending GDB commands from the connected client.
 * @param ctx GDB context.
 * @param simulator Opaque pointer passed through to callbacks.
 * @param callbacks Function table for simulator access.
 * @return 0 on success, -1 if the client disconnected. */
int gdb_stub_process(gdb_context_t *ctx, void *simulator,
                     const gdb_callbacks_t *callbacks);

/** @brief Return true if execution should stop at @p pc.
 * @param ctx GDB context.
 * @param pc Current program counter.
 * @return true if a breakpoint or single-step trip fires. */
bool gdb_stub_check_breakpoint(gdb_context_t *ctx, uint32_t pc);

/** @brief Close the GDB stub socket. */
void gdb_stub_close(gdb_context_t *ctx);

/** @brief Add a breakpoint at @p addr.
 * @return 0 on success, -1 if the breakpoint table is full. */
int gdb_stub_add_breakpoint(gdb_context_t *ctx, uint32_t addr);
/** @brief Remove the breakpoint at @p addr.
 * @return 0 if found and removed, -1 if not found. */
int gdb_stub_remove_breakpoint(gdb_context_t *ctx, uint32_t addr);
/** @brief Remove all breakpoints. */
void gdb_stub_clear_breakpoints(gdb_context_t *ctx);

/** @brief Add a watchpoint covering [@p addr, @p addr + @p len).
 * @return 0 on success, -1 if full. */
int gdb_stub_add_watchpoint(gdb_context_t *ctx, uint32_t addr, uint32_t len, watchpoint_type_t type);
/** @brief Remove a watchpoint.
 * @return 0 if found and removed, -1 if not found. */
int gdb_stub_remove_watchpoint(gdb_context_t *ctx, uint32_t addr, uint32_t len, watchpoint_type_t type);
/** @brief Return true if a read to [@p addr, @p addr+@p len) trips a watchpoint. */
bool gdb_stub_check_watchpoint_read(gdb_context_t *ctx, uint32_t addr, uint32_t len);
/** @brief Return true if a write to [@p addr, @p addr+@p len) trips a watchpoint. */
bool gdb_stub_check_watchpoint_write(gdb_context_t *ctx, uint32_t addr, uint32_t len);
/** @brief Remove all watchpoints. */
void gdb_stub_clear_watchpoints(gdb_context_t *ctx);

/** @brief Send a GDB stop signal (@p signal) to the connected client.
 * @return 0 on success, -1 on error. */
int gdb_stub_send_stop_signal(gdb_context_t *ctx, int signal);

/** @brief Send an enhanced stop-reason packet including @p addr.
 * @return 0 on success, -1 on error. */
int gdb_stub_send_stop_reason(gdb_context_t *ctx, int signal, uint32_t addr);

#ifdef __cplusplus
}
#endif

/** @} */ /* end group gdb */

#endif // GDB_STUB_H
