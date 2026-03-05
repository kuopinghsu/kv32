"""
sitecustomize.py – copied into syn/.venv by 'make openram-setup'.

Patches openram.tech for PDKs (e.g. freepdk45) that are missing
lef_rom_interconnect, which is required by openram/compiler/modules/rom_bank.py
but only defined in scn4m_subm and sky130 tech files.

The OpenRAM source tree is NEVER modified – the patch is applied at runtime
by intercepting the moment openram.tech is inserted into sys.modules.
"""
import sys

class _PatchingModules(dict):
    """sys.modules drop-in that patches openram.tech whenever it is set."""

    def __setitem__(self, key, module):
        super().__setitem__(key, module)
        if key == "openram.tech" and module is not None:
            if not hasattr(module, "lef_rom_interconnect"):
                # Derive interconnect layers from the tech's own layer_names dict.
                # FreePDK45 uses names "metal1"/"metal2"/"metal3" mapped to m1/m2/m3.
                ln = getattr(module, "layer_names", {})
                module.lef_rom_interconnect = [
                    ln.get("m1", "metal1"),
                    ln.get("m2", "metal2"),
                    ln.get("m3", "metal3"),
                ]

# Replace sys.modules once; Python's import machinery respects the substitution.
# Existing modules are preserved; only future assignments are intercepted.
sys.modules = _PatchingModules(sys.modules)
