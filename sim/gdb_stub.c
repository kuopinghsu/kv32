// GDB Remote Serial Protocol Stub Implementation
// Based on GDB Remote Serial Protocol specification

#include "gdb_stub.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <ctype.h>

// Forward declarations for static functions
static void handle_query(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_read_registers(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_write_registers(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_read_memory(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_write_memory(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_breakpoint(gdb_context_t *ctx, bool insert);
static void handle_read_single_register(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_write_single_register(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_write_memory_binary(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_reset(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_set_thread(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_thread_alive(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_halt_reason(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static void handle_search_memory(gdb_context_t *ctx, void *simulator, const gdb_callbacks_t *callbacks);
static int send_packet(gdb_stub_t *stub, const char *data);
static int receive_packet(gdb_stub_t *stub);

// Protocol helpers
static uint8_t hex_to_int(char c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return 0;
}

static char int_to_hex(uint8_t val) {
    return val < 10 ? '0' + val : 'a' + (val - 10);
}

static uint32_t parse_hex(const char *str, int len) {
    uint32_t value = 0;
    for (int i = 0; i < len && str[i]; i++) {
        value = (value << 4) | hex_to_int(str[i]);
    }
    return value;
}

static void encode_hex(char *buf, uint32_t value, int bytes) {
    // Encode in little-endian byte order (LSB first) for RISC-V
    for (int i = 0; i < bytes; i++) {
        uint8_t byte = (value >> (i * 8)) & 0xFF;
        *buf++ = int_to_hex(byte >> 4);
        *buf++ = int_to_hex(byte & 0xF);
    }
}

static uint8_t calculate_checksum(const char *data, int len) {
    uint8_t sum = 0;
    for (int i = 0; i < len; i++) {
        sum += (uint8_t)data[i];
    }
    return sum;
}

// Send a packet to GDB
static int send_packet(gdb_stub_t *stub, const char *data) {
    char buffer[GDB_BUFFER_SIZE];
    int len = strlen(data);
    uint8_t checksum = calculate_checksum(data, len);

    snprintf(buffer, sizeof(buffer), "$%s#%02x", data, checksum);
    int sent = write(stub->client_fd, buffer, strlen(buffer));
    return sent > 0 ? 0 : -1;
}

// Receive a packet from GDB
static int receive_packet(gdb_stub_t *stub) {
    char c;
    int state = 0; // 0: wait for $, 1: read data, 2: read checksum
    int index = 0;
    uint8_t checksum_expected = 0;
    uint8_t checksum_received = 0;

    while (1) {
        if (read(stub->client_fd, &c, 1) != 1) {
            return -1;
        }

        switch (state) {
        case 0: // Wait for '$'
            if (c == '$') {
                state = 1;
                index = 0;
            } else if (c == 0x03) { // Ctrl-C
                stub->packet_buffer[0] = 0x03;
                stub->packet_size = 1;
                return 0;
            }
            break;

        case 1: // Read data
            if (c == '#') {
                stub->packet_buffer[index] = '\0';
                stub->packet_size = index;
                checksum_expected = calculate_checksum(stub->packet_buffer, index);
                state = 2;
                index = 0;
            } else {
                if (index < GDB_BUFFER_SIZE - 1) {
                    stub->packet_buffer[index++] = c;
                }
            }
            break;

        case 2: // Read checksum (2 hex digits)
            checksum_received = (checksum_received << 4) | hex_to_int(c);
            if (++index == 2) {
                // Send ACK/NACK
                c = (checksum_received == checksum_expected) ? '+' : '-';
                write(stub->client_fd, &c, 1);

                if (checksum_received == checksum_expected) {
                    return 0;
                } else {
                    return -1;
                }
            }
            break;
        }
    }
}

// Initialize GDB stub
int gdb_stub_init(gdb_context_t *ctx, uint16_t port) {
    memset(ctx, 0, sizeof(*ctx));
    ctx->stub.port = port;

    // Create socket
    ctx->stub.socket_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (ctx->stub.socket_fd < 0) {
        perror("socket");
        return -1;
    }

    // Allow reuse of address
    int opt = 1;
    setsockopt(ctx->stub.socket_fd, SOL_SOCKET, SO_REUSEADDR, &opt,
               sizeof(opt));

    // Bind to port
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(ctx->stub.socket_fd, (struct sockaddr *)&addr, sizeof(addr)) <
        0) {
        perror("bind");
        close(ctx->stub.socket_fd);
        return -1;
    }

    // Listen for connections
    if (listen(ctx->stub.socket_fd, 1) < 0) {
        perror("listen");
        close(ctx->stub.socket_fd);
        return -1;
    }

    ctx->stub.enabled = true;
    printf("GDB stub listening on port %d\n", port);
    return 0;
}

// Accept client connection
int gdb_stub_accept(gdb_context_t *ctx) {
    struct sockaddr_in client_addr;
    socklen_t client_len = sizeof(client_addr);

    printf("Waiting for GDB connection...\n");
    ctx->stub.client_fd =
        accept(ctx->stub.socket_fd, (struct sockaddr *)&client_addr,
               &client_len);

    if (ctx->stub.client_fd < 0) {
        perror("accept");
        return -1;
    }

    ctx->stub.connected = true;
    printf("GDB connected from %s:%d\n", inet_ntoa(client_addr.sin_addr),
           ntohs(client_addr.sin_port));

    return 0;
}

// Handle query commands
static void handle_query(gdb_context_t *ctx, void *simulator,
                         const gdb_callbacks_t *callbacks) {
    char *packet = ctx->stub.packet_buffer;

    if (strncmp(packet, "qSupported", 10) == 0) {
        send_packet(&ctx->stub, "PacketSize=4096;qXfer:features:read+");
    } else if (strncmp(packet, "qAttached", 9) == 0) {
        send_packet(&ctx->stub, "1");
    } else if (strncmp(packet, "qC", 2) == 0) {
        send_packet(&ctx->stub, "QC1");
    } else if (strncmp(packet, "qfThreadInfo", 12) == 0) {
        send_packet(&ctx->stub, "m1");
    } else if (strncmp(packet, "qsThreadInfo", 12) == 0) {
        send_packet(&ctx->stub, "l");
    } else if (strncmp(packet, "qXfer:features:read:target.xml", 30) == 0) {
        const char *xml = "l<?xml version=\"1.0\"?>"
                          "<!DOCTYPE target SYSTEM \"gdb-target.dtd\">"
                          "<target version=\"1.0\">"
                          "<architecture>riscv:kv32</architecture>"
                          "</target>";
        send_packet(&ctx->stub, xml);
    } else if (strncmp(packet, "qOffsets", 8) == 0) {
        send_packet(&ctx->stub, "Text=0;Data=0;Bss=0");
    } else if (strncmp(packet, "qTStatus", 8) == 0) {
        send_packet(&ctx->stub, "T0;tnotrun:0");
    } else if (strncmp(packet, "qSearch:memory:", 15) == 0) {
        handle_search_memory(ctx, simulator, callbacks);
    } else {
        send_packet(&ctx->stub, "");
    }
}

// Read registers (g command)
static void handle_read_registers(gdb_context_t *ctx, void *simulator,
                                   const gdb_callbacks_t *callbacks) {
    char response[GDB_BUFFER_SIZE];
    char *p = response;

    // Send 33 registers (x0-x31 + pc)
    for (int i = 0; i < 32; i++) {
        uint32_t value = callbacks->read_reg(simulator, i);
        encode_hex(p, value, 4);
        p += 8;
    }

    // Add PC
    uint32_t pc = callbacks->get_pc(simulator);
    encode_hex(p, pc, 4);
    p += 8;
    *p = '\0';

    send_packet(&ctx->stub, response);
}

// Write registers (G command)
static void handle_write_registers(gdb_context_t *ctx, void *simulator,
                                    const gdb_callbacks_t *callbacks) {
    char *data = ctx->stub.packet_buffer + 1;

    for (int i = 0; i < 32; i++) {
        uint32_t value = parse_hex(data + i * 8, 8);
        callbacks->write_reg(simulator, i, value);
    }

    // Write PC
    uint32_t pc = parse_hex(data + 32 * 8, 8);
    callbacks->set_pc(simulator, pc);

    send_packet(&ctx->stub, "OK");
}

// Read memory (m command)
static void handle_read_memory(gdb_context_t *ctx, void *simulator,
                                const gdb_callbacks_t *callbacks) {
    char *packet = ctx->stub.packet_buffer + 1;
    char *comma = strchr(packet, ',');
    if (!comma) {
        send_packet(&ctx->stub, "E01");
        return;
    }

    *comma = '\0';
    uint32_t addr = parse_hex(packet, comma - packet);
    uint32_t len = parse_hex(comma + 1, strlen(comma + 1));

    if (len > GDB_BUFFER_SIZE / 2) {
        send_packet(&ctx->stub, "E02");
        return;
    }

    char response[GDB_BUFFER_SIZE];
    char *p = response;

    for (uint32_t i = 0; i < len; i++) {
        uint8_t byte = callbacks->read_mem(simulator, addr + i, 1) & 0xFF;
        *p++ = int_to_hex(byte >> 4);
        *p++ = int_to_hex(byte & 0xF);
    }
    *p = '\0';

    send_packet(&ctx->stub, response);
}

// Write memory (M command)
static void handle_write_memory(gdb_context_t *ctx, void *simulator,
                                 const gdb_callbacks_t *callbacks) {
    char *packet = ctx->stub.packet_buffer + 1;
    char *comma = strchr(packet, ',');
    char *colon = strchr(packet, ':');

    if (!comma || !colon) {
        send_packet(&ctx->stub, "E01");
        return;
    }

    *comma = '\0';
    *colon = '\0';

    uint32_t addr = parse_hex(packet, comma - packet);
    uint32_t len = parse_hex(comma + 1, colon - comma - 1);
    char *data = colon + 1;

    for (uint32_t i = 0; i < len; i++) {
        uint8_t byte = (hex_to_int(data[i * 2]) << 4) | hex_to_int(data[i * 2 + 1]);
        callbacks->write_mem(simulator, addr + i, byte, 1);
    }

    send_packet(&ctx->stub, "OK");
}

// Handle breakpoint commands (Z/z)
static void handle_breakpoint(gdb_context_t *ctx, bool insert) {
    char *packet = ctx->stub.packet_buffer + 1;
    char *comma1 = strchr(packet, ',');
    char *comma2 = comma1 ? strchr(comma1 + 1, ',') : NULL;

    if (!comma1 || !comma2) {
        send_packet(&ctx->stub, "E01");
        return;
    }

    *comma1 = '\0';
    *comma2 = '\0';

    int type = parse_hex(packet, comma1 - packet);
    uint32_t addr = parse_hex(comma1 + 1, comma2 - comma1 - 1);
    uint32_t len = parse_hex(comma2 + 1, strlen(comma2 + 1));

    int result = 0;

    // Handle breakpoints (type 0, 1) and watchpoints (type 2, 3, 4)
    if (type == 0 || type == 1) {
        // Software (0) and hardware (1) breakpoints
        if (insert) {
            result = gdb_stub_add_breakpoint(ctx, addr);
        } else {
            result = gdb_stub_remove_breakpoint(ctx, addr);
        }
    } else if (type >= 2 && type <= 4) {
        // Watchpoints: 2=write, 3=read, 4=access
        if (insert) {
            result = gdb_stub_add_watchpoint(ctx, addr, len, (watchpoint_type_t)type);
        } else {
            result = gdb_stub_remove_watchpoint(ctx, addr, len, (watchpoint_type_t)type);
        }
    } else {
        // Unsupported type
        send_packet(&ctx->stub, "");
        return;
    }

    send_packet(&ctx->stub, result == 0 ? "OK" : "E01");
}

// Read single register (p command)
static void handle_read_single_register(gdb_context_t *ctx, void *simulator,
                                       const gdb_callbacks_t *callbacks) {
    char *packet = ctx->stub.packet_buffer + 1;
    int reg_num = (int)parse_hex(packet, strlen(packet));

    if (reg_num < 0 || reg_num > 32) {
        send_packet(&ctx->stub, "E01");
        return;
    }

    char response[16];
    uint32_t value;

    if (reg_num < 32) {
        value = callbacks->read_reg(simulator, reg_num);
    } else if (reg_num == 32) {
        value = callbacks->get_pc(simulator);
    } else {
        send_packet(&ctx->stub, "E01");
        return;
    }

    encode_hex(response, value, 4);
    response[8] = '\0';
    send_packet(&ctx->stub, response);
}

// Write single register (P command)
static void handle_write_single_register(gdb_context_t *ctx, void *simulator,
                                        const gdb_callbacks_t *callbacks) {
    char *packet = ctx->stub.packet_buffer + 1;
    char *equals = strchr(packet, '=');

    if (!equals) {
        send_packet(&ctx->stub, "E01");
        return;
    }

    *equals = '\0';
    int reg_num = (int)parse_hex(packet, equals - packet);
    uint32_t value = parse_hex(equals + 1, strlen(equals + 1));

    if (reg_num < 0 || reg_num > 32) {
        send_packet(&ctx->stub, "E01");
        return;
    }

    if (reg_num < 32) {
        callbacks->write_reg(simulator, reg_num, value);
    } else if (reg_num == 32) {
        callbacks->set_pc(simulator, value);
    } else {
        send_packet(&ctx->stub, "E01");
        return;
    }

    send_packet(&ctx->stub, "OK");
}

// Write memory with binary data (X command)
static void handle_write_memory_binary(gdb_context_t *ctx, void *simulator,
                                      const gdb_callbacks_t *callbacks) {
    char *packet = ctx->stub.packet_buffer + 1;
    char *comma = strchr(packet, ',');
    char *colon = strchr(packet, ':');

    if (!comma || !colon) {
        send_packet(&ctx->stub, "E01");
        return;
    }

    *comma = '\0';
    *colon = '\0';

    uint32_t addr = parse_hex(packet, comma - packet);
    uint32_t len = parse_hex(comma + 1, colon - comma - 1);
    char *data = colon + 1;

    // For simplicity, treat binary data as hex-encoded for now
    // In a full implementation, this would handle raw binary data
    for (uint32_t i = 0; i < len && i * 2 < strlen(data); i++) {
        uint8_t byte = (hex_to_int(data[i * 2]) << 4) | hex_to_int(data[i * 2 + 1]);
        callbacks->write_mem(simulator, addr + i, byte, 1);
    }

    send_packet(&ctx->stub, "OK");
}

// Reset/restart target (R command)
static void handle_reset(gdb_context_t *ctx, void *simulator,
                        const gdb_callbacks_t *callbacks) {
    // Use simulator-specific reset if available
    if (callbacks->reset) {
        callbacks->reset(simulator);
    } else {
        // Default reset behavior
        // Reset PC to 0 (typical reset vector for RISC-V)
        callbacks->set_pc(simulator, 0);

        // Clear all registers (x1-x31, keep x0 as zero)
        for (int i = 1; i < 32; i++) {
            callbacks->write_reg(simulator, i, 0);
        }
    }

    // Clear breakpoints and watchpoints on reset
    gdb_stub_clear_breakpoints(ctx);
    gdb_stub_clear_watchpoints(ctx);

    ctx->should_stop = true;
    ctx->single_step = false;
    ctx->last_stop_signal = 5; // SIGTRAP
    ctx->breakpoint_hit = false;

    send_packet(&ctx->stub, "OK");
}

// Set thread for subsequent operations (H command)
static void handle_set_thread(gdb_context_t *ctx, void *simulator,
                             const gdb_callbacks_t *callbacks) {
    (void)simulator;  // Unused in single-threaded implementation
    (void)callbacks;  // Unused in single-threaded implementation
    char *packet = ctx->stub.packet_buffer + 1;

    // Simple single-threaded implementation
    // Format: Hg<thread-id> or Hc<thread-id>
    if (packet[0] == 'g' || packet[0] == 'c') {
        // For single-threaded system, accept thread ID 0, 1, or -1
        send_packet(&ctx->stub, "OK");
    } else {
        send_packet(&ctx->stub, "E01");
    }
}

// Check if thread is alive (T command)
static void handle_thread_alive(gdb_context_t *ctx, void *simulator,
                               const gdb_callbacks_t *callbacks) {
    (void)simulator;  // Unused in single-threaded implementation
    (void)callbacks;  // Unused in single-threaded implementation
    char *packet = ctx->stub.packet_buffer + 1;
    int thread_id = (int)parse_hex(packet, strlen(packet));

    // For single-threaded system, only thread 1 is alive
    if (thread_id == 1 || thread_id == 0) {
        send_packet(&ctx->stub, "OK");
    } else {
        send_packet(&ctx->stub, "E01");
    }
}

// Enhanced halt reason reporting
static void handle_halt_reason(gdb_context_t *ctx, void *simulator,
                              const gdb_callbacks_t *callbacks) {
    char response[64];

    if (ctx->single_step) {
        // Single step completed
        snprintf(response, sizeof(response), "S05");
    } else if (ctx->last_watchpoint_addr != 0) {
        // Watchpoint hit
        snprintf(response, sizeof(response), "T05watch:%08x;", ctx->last_watchpoint_addr);
        ctx->last_watchpoint_addr = 0; // Clear after reporting
    } else {
        // Breakpoint or interrupt
        uint32_t pc = callbacks->get_pc(simulator);
        if (gdb_stub_check_breakpoint(ctx, pc)) {
            // Use simple signal format instead of T packet for compatibility
            snprintf(response, sizeof(response), "S05");
        } else {
            snprintf(response, sizeof(response), "S05"); // Generic stop
        }
    }

    send_packet(&ctx->stub, response);
}

// Search memory for pattern (qSearch:memory command)
static void handle_search_memory(gdb_context_t *ctx, void *simulator,
                                const gdb_callbacks_t *callbacks) {
    char *packet = ctx->stub.packet_buffer + 15; // Skip "qSearch:memory:"
    char *colon1 = strchr(packet, ':');
    char *colon2 = colon1 ? strchr(colon1 + 1, ':') : NULL;

    if (!colon1 || !colon2) {
        send_packet(&ctx->stub, "E01");
        return;
    }

    *colon1 = '\0';
    *colon2 = '\0';

    uint32_t start_addr = parse_hex(packet, colon1 - packet);
    uint32_t search_len = parse_hex(colon1 + 1, colon2 - colon1 - 1);
    char *pattern = colon2 + 1;

    int pattern_len = strlen(pattern) / 2; // Hex encoded pattern

    // Simple linear search implementation
    for (uint32_t addr = start_addr; addr < start_addr + search_len - pattern_len; addr++) {
        bool match = true;
        for (int i = 0; i < pattern_len; i++) {
            uint8_t pattern_byte = (hex_to_int(pattern[i * 2]) << 4) | hex_to_int(pattern[i * 2 + 1]);
            uint8_t mem_byte = callbacks->read_mem(simulator, addr + i, 1) & 0xFF;
            if (pattern_byte != mem_byte) {
                match = false;
                break;
            }
        }
        if (match) {
            char response[32];
            snprintf(response, sizeof(response), "1,%08x", addr);
            send_packet(&ctx->stub, response);
            return;
        }
    }

    send_packet(&ctx->stub, "0"); // Not found
}

// Process GDB commands
int gdb_stub_process(gdb_context_t *ctx, void *simulator,
                     const gdb_callbacks_t *callbacks) {
    if (!ctx->stub.connected) {
        return -1;
    }

    if (receive_packet(&ctx->stub) < 0) {
        return -1;
    }

    char cmd = ctx->stub.packet_buffer[0];

    switch (cmd) {
    case 0x03: // Ctrl-C (interrupt)
        ctx->should_stop = true;
        send_packet(&ctx->stub, "S05");
        break;

    case '?': // Halt reason
        handle_halt_reason(ctx, simulator, callbacks);
        break;

    case 'q': // Query
        handle_query(ctx, simulator, callbacks);
        break;

    case 'g': // Read registers
        handle_read_registers(ctx, simulator, callbacks);
        break;

    case 'G': // Write registers
        handle_write_registers(ctx, simulator, callbacks);
        break;

    case 'm': // Read memory
        handle_read_memory(ctx, simulator, callbacks);
        break;

    case 'M': // Write memory
        handle_write_memory(ctx, simulator, callbacks);
        break;

    case 'p': // Read single register
        handle_read_single_register(ctx, simulator, callbacks);
        break;

    case 'P': // Write single register
        handle_write_single_register(ctx, simulator, callbacks);
        break;

    case 'X': // Write memory (binary)
        handle_write_memory_binary(ctx, simulator, callbacks);
        break;

    case 'R': // Reset/restart
        handle_reset(ctx, simulator, callbacks);
        break;

    case 'H': // Set thread
        handle_set_thread(ctx, simulator, callbacks);
        break;

    case 'T': // Thread alive
        handle_thread_alive(ctx, simulator, callbacks);
        break;

    case 'c': // Continue
        ctx->should_stop = false;
        ctx->single_step = false;
        if (callbacks->resume) {
            callbacks->resume(simulator);  // Clear halted flag
        }
        return 1; // Signal to continue execution
        break;

    case 's': // Single step
        ctx->should_stop = false;
        ctx->single_step = true;
        if (callbacks->resume) {
            callbacks->resume(simulator);  // Clear halted flag
        }
        return 1; // Signal to execute one instruction
        break;

    case 'Z': // Insert breakpoint
        handle_breakpoint(ctx, true);
        break;

    case 'z': // Remove breakpoint
        handle_breakpoint(ctx, false);
        break;

    case 'k': // Kill
        return -1;
        break;

    case 'D': // Detach
        send_packet(&ctx->stub, "OK");
        ctx->stub.connected = false;
        return -1;
        break;

    default:
        send_packet(&ctx->stub, ""); // Not supported
        break;
    }

    return 0;
}

// Breakpoint management
int gdb_stub_add_breakpoint(gdb_context_t *ctx, uint32_t addr) {
    if (ctx->breakpoint_count >= MAX_BREAKPOINTS) {
        return -1;
    }

    // Check if already exists
    for (int i = 0; i < ctx->breakpoint_count; i++) {
        if (ctx->breakpoints[i].addr == addr) {
            ctx->breakpoints[i].enabled = true;
            return 0;
        }
    }

    ctx->breakpoints[ctx->breakpoint_count].addr = addr;
    ctx->breakpoints[ctx->breakpoint_count].enabled = true;
    ctx->breakpoint_count++;
    return 0;
}

int gdb_stub_remove_breakpoint(gdb_context_t *ctx, uint32_t addr) {
    for (int i = 0; i < ctx->breakpoint_count; i++) {
        if (ctx->breakpoints[i].addr == addr) {
            ctx->breakpoints[i].enabled = false;
            return 0;
        }
    }
    return -1;
}

void gdb_stub_clear_breakpoints(gdb_context_t *ctx) {
    ctx->breakpoint_count = 0;
}

bool gdb_stub_check_breakpoint(gdb_context_t *ctx, uint32_t pc) {
    for (int i = 0; i < ctx->breakpoint_count; i++) {
        if (ctx->breakpoints[i].enabled && ctx->breakpoints[i].addr == pc) {
            ctx->breakpoint_hit = true;
            return true;
        }
    }
    return false;
}

// Watchpoint management
int gdb_stub_add_watchpoint(gdb_context_t *ctx, uint32_t addr, uint32_t len, watchpoint_type_t type) {
    if (ctx->watchpoint_count >= MAX_WATCHPOINTS) {
        return -1;
    }

    // Check if already exists
    for (int i = 0; i < ctx->watchpoint_count; i++) {
        if (ctx->watchpoints[i].addr == addr &&
            ctx->watchpoints[i].len == len &&
            ctx->watchpoints[i].type == type) {
            ctx->watchpoints[i].enabled = true;
            return 0;
        }
    }

    ctx->watchpoints[ctx->watchpoint_count].addr = addr;
    ctx->watchpoints[ctx->watchpoint_count].len = len;
    ctx->watchpoints[ctx->watchpoint_count].type = type;
    ctx->watchpoints[ctx->watchpoint_count].enabled = true;
    ctx->watchpoint_count++;
    return 0;
}

int gdb_stub_remove_watchpoint(gdb_context_t *ctx, uint32_t addr, uint32_t len, watchpoint_type_t type) {
    for (int i = 0; i < ctx->watchpoint_count; i++) {
        if (ctx->watchpoints[i].addr == addr &&
            ctx->watchpoints[i].len == len &&
            ctx->watchpoints[i].type == type) {
            ctx->watchpoints[i].enabled = false;
            return 0;
        }
    }
    return -1;
}

void gdb_stub_clear_watchpoints(gdb_context_t *ctx) {
    ctx->watchpoint_count = 0;
}

// Check if memory read triggers a watchpoint
bool gdb_stub_check_watchpoint_read(gdb_context_t *ctx, uint32_t addr, uint32_t len) {
    for (int i = 0; i < ctx->watchpoint_count; i++) {
        if (!ctx->watchpoints[i].enabled) continue;

        watchpoint_t *wp = &ctx->watchpoints[i];
        if (wp->type != WATCHPOINT_READ && wp->type != WATCHPOINT_ACCESS) continue;

        // Check if ranges overlap
        uint32_t wp_end = wp->addr + wp->len;
        uint32_t access_end = addr + len;

        if (addr < wp_end && access_end > wp->addr) {
            ctx->last_watchpoint_addr = wp->addr;
            return true;
        }
    }
    return false;
}

// Check if memory write triggers a watchpoint
bool gdb_stub_check_watchpoint_write(gdb_context_t *ctx, uint32_t addr, uint32_t len) {
    for (int i = 0; i < ctx->watchpoint_count; i++) {
        if (!ctx->watchpoints[i].enabled) continue;

        watchpoint_t *wp = &ctx->watchpoints[i];
        if (wp->type != WATCHPOINT_WRITE && wp->type != WATCHPOINT_ACCESS) continue;

        // Check if ranges overlap
        uint32_t wp_end = wp->addr + wp->len;
        uint32_t access_end = addr + len;

        if (addr < wp_end && access_end > wp->addr) {
            ctx->last_watchpoint_addr = wp->addr;
            return true;
        }
    }
    return false;
}

void gdb_stub_close(gdb_context_t *ctx) {
    if (ctx->stub.client_fd >= 0) {
        close(ctx->stub.client_fd);
        ctx->stub.client_fd = -1;
    }
    if (ctx->stub.socket_fd >= 0) {
        close(ctx->stub.socket_fd);
        ctx->stub.socket_fd = -1;
    }
    ctx->stub.connected = false;
    ctx->stub.enabled = false;
}

int gdb_stub_send_stop_signal(gdb_context_t *ctx, int signal) {
    char response[32];
    snprintf(response, sizeof(response), "S%02x", signal & 0xFF);
    return send_packet(&ctx->stub, response);
}

int gdb_stub_send_stop_reason(gdb_context_t *ctx, int signal, uint32_t addr) {
    char response[128];

    if (ctx->breakpoint_hit) {
        // Use simple signal format instead of hwbreak for compatibility
        snprintf(response, sizeof(response), "S%02x", signal & 0xFF);
        ctx->breakpoint_hit = false;
    } else if (ctx->last_watchpoint_addr != 0) {
        snprintf(response, sizeof(response), "T%02xwatch:%08x;", signal & 0xFF, ctx->last_watchpoint_addr);
        ctx->last_watchpoint_addr = 0;
    } else if (addr != 0) {
        snprintf(response, sizeof(response), "T%02x20:%08x;", signal & 0xFF, addr); // PC register (20 in hex)
    } else {
        snprintf(response, sizeof(response), "S%02x", signal & 0xFF);
    }

    return send_packet(&ctx->stub, response);
}
