find . -path "./.git" -prune -o -path "./verif/.venv" -prune -o -path "./verif/riscv-arch-test" -prune -o -path "./build" -prune -path "./verif/riscof_targets/riscof_work" -prune -o -type f ! -name "Makefile" -exec trim {} \;

