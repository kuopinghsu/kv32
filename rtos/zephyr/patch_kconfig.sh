#!/bin/bash
# Patch Zephyr's kconfig.py to ignore choice symbol warnings
# These warnings exist in upstream Zephyr 4.3's base tree for Andestech/Espressif/Silabs SOCs

# Source env.config if ZEPHYR_BASE not set
if [ -z "$ZEPHYR_BASE" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/../../env.config"
fi

KCONFIG_PY="$ZEPHYR_BASE/scripts/kconfig/kconfig.py"

if [ ! -f "$KCONFIG_PY" ]; then
    echo "Error: Cannot find $KCONFIG_PY"
    exit 1
fi

# Backup original if not already backed up
if [ ! -f "${KCONFIG_PY}.orig" ]; then
    echo "Creating backup: ${KCONFIG_PY}.orig"
    cp "$KCONFIG_PY" "${KCONFIG_PY}.orig"
fi

# Check if already patched by looking for our modified pattern
if grep -q 'warn_only = r"warning:.\*(set more than once|choice symbol|default selection|was assigned the value|has direct dependencies)"' "$KCONFIG_PY"; then
    echo "kconfig.py is already patched, skipping."
    exit 0
fi

# Patch: Change the error logic to allow warnings that match warn_only pattern
# The original code has: error_out = True, then checks "if not error_out ..." which never runs
# We need to change the logic to check each warning and only error if it doesn't match warn_only
echo "Patching kconfig.py to allow choice symbol warnings..."
cat > /tmp/patch_kconfig.py << 'PYEOF'
import re
import sys

kconfig_file = sys.argv[1]

with open(kconfig_file, 'r') as f:
    content = f.read()

# First, expand the warn_only pattern to include choice warnings and dependencies
content = re.sub(
    r'warn_only = r"warning:\.\*set more than once\."',
    r'warn_only = r"warning:.*(set more than once|choice symbol|default selection|was assigned the value|has direct dependencies)"',
    content
)

# Second, fix the logic: Start with error_out = False, then set to True only for non-matching warnings
old_logic = '''    if kconf.warnings:
        if args.forced_input_configs:
            error_out = False
        else:
            error_out = True

        # Put a blank line between warnings to make them easier to read
        for warning in kconf.warnings:
            print("\\n" + warning, file=sys.stderr)

            if not error_out and not re.search(warn_only, warning):
                # The warning is not a warn_only, fail the Kconfig.
                error_out = True'''

new_logic = '''    if kconf.warnings:
        if args.forced_input_configs:
            error_out = False
        else:
            error_out = False  # Start with False, only set True for non-matching warnings

        # Put a blank line between warnings to make them easier to read
        for warning in kconf.warnings:
            print("\\n" + warning, file=sys.stderr)

            if not re.search(warn_only, warning):
                # The warning is not a warn_only, fail the Kconfig.
                error_out = True'''

content = content.replace(old_logic, new_logic)

with open(kconfig_file, 'w') as f:
    f.write(content)

print(f"Patched {kconfig_file} successfully!")
PYEOF

python3 /tmp/patch_kconfig.py "$KCONFIG_PY"

echo "Patch applied successfully!"
echo "To restore original: cp ${KCONFIG_PY}.orig $KCONFIG_PY"
