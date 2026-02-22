# C++ Test

This test demonstrates C++ features in the embedded environment:

## Features Tested

1. **Global Constructors** - Two global objects (`global_obj1`, `global_obj2`) with constructors that execute before `main()`
2. **Static Local Objects** - Function-local static object with guard variable for one-time initialization
3. **C++ Class Features** - Constructor initialization lists, member functions

## Output

When run successfully, you should see:
```
Constructor called for: GlobalObject1
Constructor called for: GlobalObject2

=== C++ Test Program ===

Global constructors executed before main():
Object: GlobalObject1, Value: 42
Object: GlobalObject2, Value: 99

Creating local object:
Constructor called for: LocalObject
Object: LocalObject, Value: 123

Accessing static local object (guard variable test):
Constructor called for: StaticObject
Object: StaticObject, Value: 777

Calling again (should not reconstruct):
Object: StaticObject, Value: 777

=== C++ Test Complete ===
```

## Implementation Notes

- Uses `-fno-exceptions -fno-rtti` flags for embedded environment
- Does not use iostream (not available in freestanding mode)
- Uses `_write()` syscall directly for output
- Requires `.init_array` constructors to be called in `start.S`
- Demonstrates that C++ works in the minimal embedded environment

## Known Issues

- iostream (`std::cout`) is not available in freestanding mode
- C++ standard library functions that require hosted environment won't work
- Global constructors from newlib (stdio initialization) may cause issues

## Building

```bash
make sw TEST=cpp       # Build C++ test
make rtl TEST=cpp      # Run on RTL simulation
./build/rv32sim build/test.elf  # Run on software simulator
```
