# Spike MMIO Plugins for KV32 SoC

This directory contains MMIO (Memory-Mapped I/O) plugin implementations for the Spike RISC-V ISA Simulator. These plugins emulate the peripheral devices used in the KV32 SoC, allowing firmware to run on Spike with the same MMIO interface as the RTL.

## Plugins

The following plugins are provided:

- **spike_plugin_magic.so** - Magic device for console output and exit control
- **spike_plugin_plic.so** - Platform-Level Interrupt Controller (PLIC)
- **spike_plugin_clint.so** - Core-Local Interrupt Controller (CLINT)
- **spike_plugin_uart.so** - UART peripheral
- **spike_plugin_spi.so** - SPI controller
- **spike_plugin_i2c.so** - I2C controller
- **spike_plugin_dma.so** - DMA controller

## Building

Build all plugins:
```bash
make -C spike BUILD_DIR=../build
```

Or from the project root:
```bash
make build-spike-plugins
```

## Usage

Run a test with Spike + plugins:
```bash
make plugin-spike-<test>
```

For example:
```bash
make plugin-spike-uart
make plugin-spike-dma
```

## Platform Support

### Linux
Plugins should work correctly on Linux with a standard Spike installation.

### macOS
**Known Issue**: Spike plugins have limited support on macOS due to symbol visibility restrictions. The standard Spike binary does not export the `register_mmio_plugin` symbol, which prevents plugins from loading.

#### Error Message
```
Unable to load extlib 'spike_plugin_magic.so':
symbol not found in flat namespace '_register_mmio_plugin'
```

#### Workaround Options

1. **Use RTL Simulation** (Recommended)
   ```bash
   make rtl-<test>    # e.g., make rtl-dma
   ```

2. **Use Software Simulator**
   ```bash
   make sim-<test>    # e.g., make sim-dma
   ```

3. **Rebuild Spike with Symbol Exports** (Advanced)

   To enable plugin support, Spike must be rebuilt with symbol exports enabled:

   ```bash
   # In Spike source directory
   git clone https://github.com/riscv-software-src/riscv-isa-sim.git
   cd riscv-isa-sim
   mkdir build && cd build

   # Configure with explicit linker flags
   LDFLAGS="-Wl,-export_dynamic" ../configure --prefix=/opt/spike
   make -j$(nproc)
   sudo make install
   ```

   **Note**: On macOS, `-Wl,-export_dynamic` may not fully work due to the two-level namespace model used by the macOS dynamic linker. You may need to modify Spike's build system or use additional linker flags.

## Architecture

### Plugin Interface

Each plugin implements the `mmio_plugin_t` interface defined in `mmio_plugin_api.h`:

```c
typedef struct {
    void* (*alloc)(const char* args);
    void  (*dealloc)(void* dev);
    bool  (*access)(void* dev, reg_t addr, size_t len,
                    uint8_t* bytes, bool store);
} mmio_plugin_t;
```

### Register Map

The plugins use register definitions from `../sw/include/kv_platform.h`, ensuring consistency between firmware and simulation:

- **Magic Device**: `0xFFFF_0000` - `0xFFFF_FFFF`
- **PLIC**: `0x0C00_0000` - `0x0FFF_FFFF`
- **CLINT**: `0x0200_0000` - `0x02FF_FFFF`
- **UART**: `0x2000_0000` - `0x2000_0FFF`
- **I2C**: `0x2001_0000` - `0x2001_0FFF`
- **SPI**: `0x2002_0000` - `0x2002_0FFF`
- **DMA**: `0x2003_0000` - `0x2003_0FFF`

### Inter-Plugin Communication

The PLIC plugin exports a `plic_set_pending()` function that other plugins can call to assert/deassert interrupt sources. This is resolved dynamically via `dlsym()` at runtime.

## Troubleshooting

### Compilation Issues

**Warning about KV_REG32 macro redefinition:**
- This has been fixed in `mmio_plugin_api.h` by properly ordering the include and macro definitions.

**Linker error on macOS about undefined symbols:**
- This is expected during compilation. The `-undefined dynamic_lookup` flag allows the plugin to compile, deferring symbol resolution to runtime.

### Runtime Issues

**Plugins fail to load:**
- Check that Spike supports the `--extlib` flag: `spike --help | grep extlib`
- Verify plugins are in the correct location: `ls -la build/spike_plugin_*.so`
- On macOS, see workarounds above

**Device not responding:**
- Verify the device address is loaded correctly: use `TRACE=1` to enable instruction trace
- Check that the `--device` flag specifies the correct base address

## Development

### Adding a New Plugin

1. Create `plugin_<name>.cc` in this directory
2. Implement the `mmio_plugin_t` interface
3. Add `plugin_init()` function to register the plugin
4. Add the plugin to `PLUGINS` in `Makefile`
5. Define device base address and registers in `../sw/include/kv_platform.h`

### Testing

Test plugins by running:
```bash
make plugin-spike-<test> TRACE=1
```

This generates an instruction trace in `build/spike_plugin_trace.txt` for debugging.

## References

- [Spike ISA Simulator](https://github.com/riscv-software-src/riscv-isa-sim)
- [RISC-V MMIO Plugin API](https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/mmio_plugin.h)
- KV32 SoC Register Map: `../sw/include/kv_platform.h`
