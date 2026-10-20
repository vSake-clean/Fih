NASM      := nasm
NASMFLAGS := -f elf64 -g -F dwarf -w+all -w-reloc-rel-dword -I src/
LD        := ld

# gorący kod szybkiego interpretera na początku pliku (ułożenie w pamięci ma znaczenie)
OBJ := $(patsubst %,build/%.o,expr interp io par main elf comp imp rt)

fih: $(OBJ)
	$(LD) -o $@ $(OBJ)

build/%.o: src/%.asm src/fih.inc | build
	$(NASM) $(NASMFLAGS) -o $@ $<

build/rt.o: src/rt_flt.inc src/flt_tab.inc src/rt_dec.inc src/rt_math.inc src/trig_tab.inc
build/comp.o: src/comp_flt.inc

build:
	mkdir -p build

test: fih
	./tests/run.sh
	./tests/sandbox.sh

fuzz: fih
	python3 tests/fuzz/fuzz2.py 5000
	python3 tests/fuzz/fuzz.py 5000
	python3 tests/fuzz/text_fuzz.py 3000
	python3 tests/fuzz/flt_fuzz.py 3000
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
