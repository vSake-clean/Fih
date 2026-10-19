# Fih 🐟

Język programowania z interpreterem napisanym w czystym assembly x86-64 (NASM),
bez libc — tylko syscalle Linuksa.

## Budowanie

```sh
sudo apt install nasm
make            # tworzy ./fih
make test       # testy (oba tryby, przypadki graniczne)
make fuzz       # losowe programy (małe i > 512 KB) porównane z wzorcową implementacją
make bench      # benchmark vs C, C++, Python (wymaga gcc, g++, python3, hyperfine)
                # FULL=1 make bench mierzy też od nowa kompilację C/C++ (~10 min)
make charts     # wykresy SVG w docs/ z wyników bench/*.csv
```

## Użycie

Fih ma dwa tryby:

```sh
./fih program.fh                    # interpretacja: uruchamia od razu, jak Python
./fih build program.fh              # kompilacja: tworzy plik wykonywalny ./program
./fih build program.fh -o nazwa     # ... o wybranej nazwie
```

**Interpretacja** czyta plik i wykonuje go linia po linii. Gdy w linii jest błąd,
wcześniejsze linie zdążą się wykonać.

**Kompilacja** sprawdza i wylicza cały program przed uruchomieniem, a potem zapisuje
gotowy plik ELF x86-64: statyczny, bez bibliotek, uruchamiany bez Fih. Jeśli w
programie jest błąd, kompilacja kończy się komunikatem i plik wynikowy nie powstaje.
Wyrażenia `calc` są liczone już podczas kompilacji, więc skompilowany program
tylko wypisuje gotowy wynik.

Duże programy (od 512 KB) są wykonywane na wszystkich rdzeniach. Plik jest dzielony na
kawałki na granicach linii, każdy kawałek liczy osobny proces, a wyniki są wypisywane
po kolei. Wyjście i komunikaty błędów (z numerem linii) są dokładnie takie jak przy
wykonaniu po kolei. Gdy proces potomny trafi na błąd albo nie da się go uruchomić
(np. limit procesów lub pamięci), reszta programu jest wykonywana po kolei.

Program można też podać przez potok: `echo 'calc("6*7")' | ./fih /dev/stdin`.

## Język (wersja 0.1)

Jedna instrukcja na linię, komentarze od `#` do końca linii.

```
# komentarz
print("2 + 3")        # wypisuje dosłownie: 2 + 3
calc("2 + 2")         # liczy i wypisuje: 4
calc("(1 + 2) * -3")  # -9
```

| Instrukcja      | Działanie |
|-----------------|-----------|
| `print("...")`  | wypisuje napis i znak nowej linii; sekwencje `\n` `\t` `\\` `\"` |
| `calc("...")`   | liczy wyrażenie całkowite 64-bit i wypisuje wynik |

Wyrażenia w `calc`: liczby całkowite, `+ - * / %`, nawiasy, unarny `-` i `+`,
spacje i tabulatory dowolnie.
Priorytety jak w matematyce. `/` obcina w stronę zera, `%` ma znak dzielnej
(jak w C). Przepełnienie (wynik spoza zakresu 64-bitowego, np.
`9223372036854775807 + 1`) to błąd, a nie cicho zła liczba. Dzielenie przez
zero też kończy program błędem z numerem linii:

```
fih: błąd w linii 2: dzielenie przez zero
```

Bardzo głęboko zagnieżdżone wyrażenia (powyżej limitu dopasowanego do `ulimit -s`)
kończą się błędem `wyrażenie zbyt głęboko zagnieżdżone`, a nie awarią.

## Stabilność

Fih nigdy nie powinien skończyć się awarią. Każda sytuacja kończy się komunikatem `fih: błąd...` i kodem 1:

- błędy w programie (z numerem linii), w tym dzielenie przez zero, przepełnienie
  i za duża liczba w kodzie;
- bardzo głębokie nawiasy: limit jest dopasowany do `ulimit -s`;
- plik źródłowy skrócony w trakcie wykonania (`SIGBUS` jest obsługiwany);
- pełny dysk, `/dev/full`, zamknięty potok; przy `build` niepełny plik wynikowy jest usuwany;
- brak pamięci albo limit procesów: tryb wielordzeniowy przechodzi wtedy na wykonanie po kolei.

Sprawdzają to `make test` (98 testów w obu trybach) i `make fuzz`:

- `tests/fuzz/fuzz.py`: losowe programy porównane z niezależną implementacją w Pythonie
  (wyjście, komunikat błędu, numer linii, kod wyjścia);
- `tests/fuzz/par_fuzz.py`: to samo dla dużych programów dzielonych na rdzenie;
- `tests/fuzz/gcc_oracle.py`: wyrażenia skompilowane przez gcc (`-fwrapv`) jako druga,
  niezależna wyrocznia arytmetyki;
- `tests/fuzz/crash_fuzz.py`: losowe bajty i mutacje bez wyroczni; dozwolone są tylko
  kody 0 i 1, nigdy sygnał;
- `tests/truncate.sh`: plik skrócony w trakcie wykonania.

`make stability` (`bench/stability.py`) uruchamia te same złośliwe przypadki w 9 implementacjach.
Przypadek jest zaliczony, gdy nie ma awarii (sygnału, awarii kompilatora, zawieszenia),
błąd daje kod wyjścia różny od 0, dane nie giną po cichu, a wynik arytmetyki jest
dokładny albo zgłoszony jako błąd:

![Stabilność](docs/stability.svg)

| | Fih | Fih (build) | C | C++ | Python | Node.js | Perl | Lua | bc |
|---|---|---|---|---|---|---|---|---|---|
| 200 tys. nawiasów | ✔ | ✔ | ✘ awaria kompilatora | ✘ awaria kompilatora | ✔ | ✔ | ✔ | ✔ | ✔ |
| 2 mln nawiasów | ✔ | ✔ | ✘ awaria kompilatora | ✘ zawieszenie | ✔ | ✔ | ✔ | ✔ | ✔ |
| mały stos + 3000 nawiasów | ✔ | ✔ | ✘ awaria kompilatora | ✘ awaria kompilatora | ✘ sygnał 11 | ✘ sygnał 11 | ✔ | ✔ | ✔ |
| dzielenie przez zero | ✔ | ✔ | ✘ sygnał 8 | ✘ sygnał 8 | ✔ | ✘ kod 0 | ✔ | ✔ | ✘ kod 0 |
| zapis na pełny dysk | ✔ | ✔ | ✘ kod 0 | ✘ kod 0 | ✘ kod 0 | ✘ kod 0 | ✔ | ✘ kod 0 | ✔ |
| zamknięte stdout | ✔ | ✔ | ✘ kod 0 | ✘ kod 0 | ✘ kod 0 | ✘ kod 0 | ✔ | ✘ kod 0 | ✔ |
| losowe bajty jako kod | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| liczba o 500 cyfrach | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| napis 20 MB | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ |
| `9223372036854775807 + 1` | ✔ | ✔ | ✘ zły wynik | ✘ zły wynik | ✔ | ✘ zły wynik | ✔ | ✘ zły wynik | ✔ |
| `9223372036854775807 * 3` | ✔ | ✔ | ✘ zły wynik | ✘ zły wynik | ✔ | ✘ zły wynik | ✘ zły wynik | ✘ zły wynik | ✔ |
| limit pamięci 300 MB | ✔ | ✔ | ✔ | ✔ | ✔ | ✘ sygnał 5 | ✔ | ✔ | ✔ |
| **razem** | **12/12** | **12/12** | 4/12 | 4/12 | 9/12 | 5/12 | 11/12 | 8/12 | 11/12 |

## Wydajność

Program testowy ma 100 000 linii `print`/`calc`. Pomiar na Celeronie 1005M, im więcej, tym lepiej:

![Wykonanie gotowego programu](docs/exec.svg)
![Od kodu źródłowego do wyniku](docs/source.svg)
![Hello World](docs/startup.svg)
![Wykonanie na jednym rdzeniu](docs/exec1.svg)

| | Fih | Fih (build) | C (gcc -O2) | C++ (g++ -O2) | Python 3.13 |
|---|---|---|---|---|---|
| wykonanie, linii/s | **12,3 mln** (2 rdzenie) | **323 mln** | 7,9 mln | 6,7 mln | 41 tys. |
| wykonanie na 1 rdzeniu, linii/s | **8,2 mln** | | 7,4 mln | | |
| od źródła do wyniku, linii/s | **12,3 mln** | 7,4 mln | 2,9 tys. | 977 | 41 tys. |
| Hello World, uruchomień/s | 2,8 tys. | **3,3 tys.** | 1,0 tys. | 436 | 39 |

Na jednym rdzeniu (300 uruchomień, 95% przedział ufności średniej): Fih 12,33 ± 0,12 ms,
C 13,47 ± 0,04 ms.

Interpreter jest zoptymalizowany ręcznie: skanowanie napisów SSE2, parsowanie
liczb SWAR (8 cyfr naraz, osobne ścieżki dla krótkich liczb), wypisywanie liczb
po 2 cyfry bez dzielenia, wyrażenia liczone w jednym przejściu bez rekurencji
(poza nawiasami), kod ułożony tak, żeby typowa ścieżka nie zawierała skoków
(rzadkie przypadki w osobnej sekcji), proste ścieżki dla `calc("…")` i
`print("…")` bez spacji, duże programy na wszystkich rdzeniach.

## Struktura

```
src/main.asm    start programu, wczytanie pliku (open/fstat/mmap)
src/interp.asm  wykonywanie linii, print
src/expr.asm    parser i ewaluator wyrażeń dla calc
src/io.asm      buforowane wyjście (stdout albo pamięć), liczby, błędy
src/elf.asm     zapis skompilowanego programu jako plik ELF
src/par.asm     wykonanie dużych programów na wielu rdzeniach
tests/          tests/ok (oczekiwane stdout), tests/err (oczekiwane błędy),
                tests/fuzz (fuzzer z wyrocznią), tests/numbers.py
bench/          generator programów testowych, benchmark, wykresy (charts.py)
docs/           wykresy kolumnowe SVG
```

## Licencja

[MIT](LICENSE) © 2026 vSake. Kod Fih można dowolnie używać, zmieniać i rozpowszechniać,
także komercyjnie, pod warunkiem zachowania informacji o autorze i treści licencji.
