# Compiler
CC      := gcc

# Common flags
CFLAGS  := -O3 -Wall -Wextra -fPIC -D_GNU_SOURCE
LDFLAGS := -lpthread

# Targets
LIB     := libFuncC.so
OBJ     := libFuncC.o
SRC     := libFuncC.c

# Default target
all: $(LIB) $(OBJ)

# Build shared library (.so)
$(LIB): $(SRC)
	$(CC) $(CFLAGS) -shared -o $@ $< $(LDFLAGS)

# Build object file
$(OBJ): $(SRC)
	$(CC) $(CFLAGS) -c -o $@ $<

# Clean build artifacts
clean:
	rm -f $(LIB) $(OBJ)

.PHONY: all clean
