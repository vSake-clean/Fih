NASM      := nasm
NASMFLAGS := -f elf64 -g -F dwarf -w+all -w-reloc-rel-dword -I src/
LD        := ld

SRC := $(wildcard src/*.asm)
OBJ := $(SRC:src/%.asm=build/%.o)

fih: $(OBJ)
	$(LD) -o $@ $(OBJ)

build/%.o: src/%.asm src/fih.inc | build
	$(NASM) $(NASMFLAGS) -o $@ $<

build:
	mkdir -p build

test: fih
	./tests/run.sh

fuzz: fih
	python3 tests/fuzz/fuzz.py 5000
	python3 tests/fuzz/par_fuzz.py 10
	./tests/truncate.sh
	python3 tests/fuzz/gcc_oracle.py 20000
	python3 tests/fuzz/crash_fuzz.py 3000

bench: fih
	./bench/run.sh

stability: fih
	python3 bench/stability.py

charts:
	python3 bench/charts.py

clean:
	rm -rf build fih

.PHONY: test fuzz bench stability charts clean
