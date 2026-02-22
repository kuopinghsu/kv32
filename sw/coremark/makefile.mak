PORT_CFLAGS += -O3 -DITERATIONS=4 -DPERFORMANCE_RUN=1

PORT_CFLAGS += -fno-common -funroll-loops -finline-functions -falign-functions=16
PORT_CFLAGS += -falign-jumps=4 -falign-loops=4 -finline-limit=1000
#PORT_CFLAGS += -fno-if-conversion2 -fselective-scheduling -fno-tree-dominator-opts
#PORT_CFLAGS += -fno-reg-struct-return -fno-rename-registers
#PORT_CFLAGS += --param case-values-threshold=8 -fno-crossjumping
PORT_CFLAGS += -freorder-blocks-and-partition -fno-tree-loop-if-convert
PORT_CFLAGS += -fno-tree-sink -fgcse-sm -fno-strict-overflow

FLAGS_STR    = "$(PORT_CFLAGS)"
CFLAGS      += $(PORT_CFLAGS) -DFLAGS_STR=\"$(FLAGS_STR)\"
