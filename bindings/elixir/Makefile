# Builds the NIF into the application's priv directory (elixir_make sets
# MIX_APP_PATH and ERTS_INCLUDE_DIR).
PRIV_DIR = $(MIX_APP_PATH)/priv
NIF = $(PRIV_DIR)/keynub_licdongle_nif.so
SRC = c_src/keynub_licdongle_nif.c

ifeq ($(OS),Windows_NT)
$(error On Windows the NIF is built by nmake from Makefile.win; unset MAKE so that elixir_make picks nmake)
endif

CFLAGS ?= -O2
CFLAGS += -std=c99 -fPIC -Wall -Wextra -I"$(ERTS_INCLUDE_DIR)"

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
LDFLAGS += -dynamiclib -undefined dynamic_lookup
else
LDFLAGS += -shared
LIBS += -ldl
endif

all: $(NIF)

$(NIF): $(SRC)
	@mkdir -p "$(PRIV_DIR)"
	$(CC) $(CFLAGS) $(LDFLAGS) -o "$@" $(SRC) $(LIBS)

clean:
	rm -f "$(NIF)"

.PHONY: all clean
