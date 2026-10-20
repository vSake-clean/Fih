# Fih 🐟

[![CI](https://github.com/vSake-clean/Fih/actions/workflows/ci.yml/badge.svg)](https://github.com/vSake-clean/Fih/actions/workflows/ci.yml)

Mały język programowania z kompilatorem napisanym w czystym assembly x86-64
(NASM), bez libc — tylko syscalle Linuksa. Program jest tłumaczony na kod
maszynowy: uruchamiany od razu z pamięci (JIT) albo zapisywany jako
samodzielny plik ELF.

```
# FizzBuzz w Fih
i = 1
while i <= 15 {
    if i % 15 == 0 {
        print("FizzBuzz")
    } else if i % 3 == 0 {
        print("Fizz")
    } else if i % 5 == 0 {
        print("Buzz")
    } else {
        calc(i)
    }
    i += 1
}
```

**Fih 0.3** ma zmienne całkowite, `if`/`else if`/`else`, pętlę `while`,
`break`/`continue`, porównania (także łańcuchy `0 < x < 10`), `and`/`or`/`not`,
wypisywanie (`print`, `write`, `calc`) i wczytywanie liczb oraz znaków
(`input()`, `inputchar()`). Nie ma jeszcze funkcji, tablic ani napisów
w zmiennych ([ROADMAP.md](ROADMAP.md)).

Przykład programu interaktywnego — kalkulator
([examples/kalkulator.fh](examples/kalkulator.fh)):

```
$ fih examples/kalkulator.fh
Kalkulator Fih
Działania: + - * / %   (q zamiast działania kończy)

Podaj pierwszą liczbę: 6
Działanie (+ - * / %): *
Podaj drugą liczbę: 7
Wynik: 42

Podaj pierwszą liczbę: abc
To nie jest liczba, spróbuj jeszcze raz (koniec: Ctrl+D).
Podaj pierwszą liczbę: 1
Działanie (+ - * / %): /
Podaj drugą liczbę: 0
Nie można dzielić przez zero.
```

| Dokument | Zawartość |
|---|---|
| [SPEC.md](SPEC.md) | pełna specyfikacja języka: gramatyka, semantyka, błędy, limity |
| [ROADMAP.md](ROADMAP.md) | plan kolejnych wersji |
| [CHANGELOG.md](CHANGELOG.md) | zmiany w kolejnych wersjach |
| [CONTRIBUTING.md](CONTRIBUTING.md) | zgłaszanie błędów, testy, styl kodu, wersjonowanie |

## Instalacja

Gotowa binarka (Linux x86-64) jest w [wydaniach](https://github.com/vSake-clean/Fih/releases/latest):

```sh
curl -LO https://github.com/vSake-clean/Fih/releases/latest/download/fih-linux-x86_64
chmod +x fih-linux-x86_64 && sudo mv fih-linux-x86_64 /usr/local/bin/fih
fih --version
```

## Budowanie

Wymagania: Linux x86-64, NASM 2.15+, GNU ld.

```sh
sudo apt install nasm
make            # tworzy ./fih
make test       # testy (oba tryby, przypadki graniczne)
make fuzz       # losowe programy porównane z wzorcową implementacją (tests/fuzz/oracle.py)
make bench      # benchmark vs C, C++, Python (wymaga gcc, g++, python3, hyperfine)
                # FULL=1 make bench mierzy też od nowa kompilację C/C++ (~10 min)
make charts     # wykresy SVG w docs/ z wyników bench/*.csv
```

## Użycie

```sh
./fih program.fh                    # uruchomienie: kompilacja w pamięci (JIT) i start
./fih build program.fh              # kompilacja: tworzy plik wykonywalny ./program
./fih build program.fh -o nazwa     # ... o wybranej nazwie
./fih --help                        # opis użycia
./fih --version                     # wersja
```

Cały plik jest sprawdzany przed uruchomieniem: przy błędzie składni program nie
wypisuje niczego, a `build` nie tworzy pliku. Błędy w trakcie (dzielenie przez
zero, przepełnienie) zgłasza działający program — po wypisaniu tego, co zdążył
policzyć. Oba tryby dają identyczne wyjście, komunikaty i kody wyjścia.

`fih build` tworzy statyczny plik ELF x86-64 bez bibliotek, uruchamiany bez Fih.
Programy, które mają tylko `print` i `calc` ze stałymi, są wyliczane od razu
(build zapisuje gotowy wynik), a duże (od 512 KB) — na wszystkich rdzeniach.

Program można też podać przez potok: `echo 'calc(6*7)' | ./fih /dev/stdin`.

## Język (wersja 0.3)

Pełna specyfikacja (gramatyka, semantyka, wszystkie błędy, limity) jest w
[SPEC.md](SPEC.md). Ten plik można dać modelowi AI do przeczytania.

Jedna instrukcja na linię, komentarze od `#` do końca linii.

| Instrukcja | Działanie |
|---|---|
| `print("...")` | wypisuje napis i znak nowej linii; sekwencje `\n` `\t` `\\` `\"` |
| `write("...")`, `write(wyrażenie)` | jak `print`/`calc`, ale bez nowej linii |
| `calc(wyrażenie)` | wypisuje wartość wyrażenia (także `calc("wyrażenie")`, jak w 0.1) |
| `x = wyrażenie` | przypisanie; także `+=` `-=` `*=` `//=` `%=` (`/=` z `import math`) |
| `if w {` … `} else if w {` … `} else {` … `}` | warunek (prawda = różne od 0) |
| `while w {` … `}` | pętla; `break` i `continue` |
| `input()`, `inputchar()` | (w wyrażeniu) liczba / kod znaku z linii wejścia; `inputok()`, `eof()` |

Wyrażenia: liczby całkowite 64-bit, zmienne, `+ - * // %`, nawiasy, unarny `-`,
porównania `== != < <= > >=` (wynik 1 albo 0, łańcuchy jak w Pythonie:
`0 < x < 10`), `and`, `or`, `not` (liczone tylko w razie potrzeby), literały
znakowe `'+'` (kod znaku).
`//` obcina w stronę zera, `%` ma znak dzielnej (jak w C). Przepełnienie (np.
`9223372036854775807 + 1`) i dzielenie przez zero to błędy z numerem linii,
a nie cicho zła liczba:

```
fih: błąd w linii 2: dzielenie przez zero
```

Z `import math` dochodzą ułamki (`2.5`, `7 / 2` = 3.5, wypisywane jak w
Pythonie) i funkcje `math.sqrt`, `math.sin`, `math.floor`, `math.round`,
`math.pow`, `math.random`, `math.pi`... (pełna lista w [SPEC.md](SPEC.md)):

```
import math
r = 2.5
print("pole koła: " + math.pi * r * r)    # pole koła: 19.634954084936208
print(math.floor(7 / 2))                  # 3
```

Zmienna użyta przed przypisaniem to błąd: `nieznana zmienna 'x'` (przed
uruchomieniem) albo `zmienna 'x' nie ma jeszcze wartości` (gdy przypisanie się
nie wykonało).

## Stabilność

Fih nigdy nie powinien skończyć się awarią. Każda sytuacja kończy się komunikatem `fih: błąd...` i kodem 1:

- błędy w programie (z numerem linii), w tym dzielenie przez zero, przepełnienie,
  za duża liczba w kodzie i zmienna bez wartości;
- bardzo głębokie nawiasy: limit jest dopasowany do `ulimit -s`; 65 536 zmiennych
  i 65 536 zagnieżdżonych bloków;
- plik źródłowy skrócony w trakcie wykonania (`SIGBUS` jest obsługiwany);
- pełny dysk, `/dev/full`, zamknięty potok; przy `build` niepełny plik wynikowy jest usuwany;
- brak pamięci albo limit procesów: tryb wielordzeniowy przechodzi wtedy na wykonanie po kolei.

Sprawdzają to `make test` (295 testów, programy w obu trybach) i `make fuzz`:

- `tests/fuzz/oracle.py`: niezależna implementacja Fih w Pythonie (wyrocznia);
- `tests/fuzz/fuzz2.py`: losowe programy 0.2 (zmienne, `if`, `while`, `break`,
  łańcuchy porównań, błędy) porównane z wyrocznią: wyjście, komunikat błędu,
  numer linii, kod wyjścia, w obu trybach;
- `tests/fuzz/fuzz.py`: to samo dla programów `print`/`calc`;
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

## Wydajność

Pomiar na Celeronie 1005M (2 rdzenie), im więcej, tym lepiej. Na liczbach
całkowitych Fih jest szybszy od C (gcc -O2) we wszystkich pomiarach; na
ułamkach jest 2–2,5 razy wolniejszy od C i ponad 20 razy szybszy od Pythona.

**Pętle** — liczby pierwsze mniejsze od 300 000 sprawdzane dzieleniem próbnym
(`while`, `if`, `%`, `break`), ten sam algorytm w każdym języku
(`bench/primes/`):

![Pętle: liczby pierwsze](docs/loops.svg)

**Program `print`/`calc`** — 100 000 linii ze stałymi wyrażeniami:

![Wykonanie gotowego programu](docs/exec.svg)
![Od kodu źródłowego do wyniku](docs/source.svg)
![Hello World](docs/startup.svg)
![Wykonanie na jednym rdzeniu](docs/exec1.svg)

**Ułamki** (`import math`) — zbiór Mandelbrota 600 × 400 punktów, do 100 kroków
(`bench/floats/mandel.*`), i suma `math.sqrt(i)` dla i < 3 000 000
(`bench/floats/sqrt.*`):

![Ułamki: zbiór Mandelbrota](docs/floats.svg)
![math.sqrt w pętli](docs/math.svg)

| | Fih | Fih (build) | C (gcc -O2) | C++ (g++ -O2) | Python 3.13 |
|---|---|---|---|---|---|
| pętle, liczb/s | **2,5 mln** | **2,5 mln** | 1,4 mln | 1,4 mln | 59 tys. |
| program print/calc, linii/s | **13,3 mln** (2 rdzenie) | **367 mln** | 8,3 mln | 6,9 mln | 42 tys. |
| ten sam na 1 rdzeniu, linii/s | **8,0 mln** | | 7,7 mln | | |
| od źródła do wyniku, linii/s | **13,3 mln** | 9,0 mln | 2,9 tys. | 977 | 42 tys. |
| Hello World, uruchomień/s | 3,1 tys. | **3,7 tys.** | 1,2 tys. | 495 | 40 |
| Mandelbrot, punktów/s | 3,1 mln | 3,2 mln | **7,8 mln** | 7,6 mln | 58 tys. |
| math.sqrt, pierwiastków/s | 58 mln | 61 mln | 113 mln | **123 mln** | 2,6 mln |

W pętlach Fih jest 1,9 razy szybszy od C i 43 razy szybszy od Pythona.
Kompilator zamienia dzielenie przez stałą na mnożenie, porównania w warunkach
na pojedyncze skoki, a dzielenie przez zmienną wykonuje instrukcją 32-bitową,
gdy obie liczby mieszczą się w 32 bitach (2–3 razy szybszą od 64-bitowej,
której używa gcc). „Fih” (bez build) wlicza kompilację do pamięci przy każdym
uruchomieniu.

Programy `print`/`calc` ze stałymi liczy ręcznie zoptymalizowany interpreter:
skanowanie napisów SSE2, parsowanie liczb SWAR (8 cyfr naraz), wypisywanie liczb
po 2 cyfry bez dzielenia, wyrażenia w jednym przejściu, typowa ścieżka bez
skoków, duże programy na wszystkich rdzeniach. `fih build` liczy taki program
już podczas kompilacji, więc plik wynikowy tylko wypisuje gotowy wynik.

Ułamki liczą instrukcje SSE2 (dodawanie, mnożenie, pierwiastek), a funkcje
przestępne koprocesor x87. C wygrywa, bo trzyma zmienne w rejestrach
procesora; Fih trzyma je w pamięci (to plan na później, [ROADMAP.md](ROADMAP.md)).

## Struktura

```
src/main.asm    start programu, wczytanie pliku, wybór silnika
src/comp.asm    kompilator 0.2: parser, generator kodu x86-64, JIT, zapis ELF
src/rt.asm      środowisko uruchomieniowe skompilowanych programów (wyjście, błędy,
                ułamki: rt_flt.inc, rt_dec.inc; funkcje math: rt_math.inc)
src/imp.asm     importy i uprawnienia (Landlock, limity, seccomp)
src/interp.asm  szybki interpreter programów print/calc
src/expr.asm    parser i ewaluator wyrażeń stałych dla calc
src/io.asm      wyjście (stdout albo pamięć), liczby, błędy
src/elf.asm     zapis gotowego wyniku jako plik ELF
src/par.asm     wykonanie dużych programów print/calc na wielu rdzeniach
tests/          tests/ok (oczekiwane stdout), tests/err (oczekiwane błędy),
                tests/fuzz (wyrocznia i fuzzery), tests/*.py
bench/          generator programów testowych, benchmark, wykresy (charts.py)
docs/           wykresy kolumnowe SVG
```

## Licencja

[MIT](LICENSE) © 2026 vSake. Kod Fih można dowolnie używać, zmieniać i rozpowszechniać,
także komercyjnie, pod warunkiem zachowania informacji o autorze i treści licencji.
