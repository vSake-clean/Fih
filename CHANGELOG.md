# Zmiany

Format oparty na [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/).
Wersje: `0.MINOR.PATCH` (patrz [CONTRIBUTING.md](CONTRIBUTING.md#wersje)).

## [Niewydane] — 0.4 w budowie

### Dodane
- Importy i uprawnienia: `import math`, `import files [folder] [only ...]`,
  `import commands [only ...]`, `import net [domena] [only ...]`. Program bez
  importu nie ma dostępu do plików, sieci ani poleceń. Importy są sprawdzane
  przed uruchomieniem (nieznany moduł, funkcja, folder poza programem itd.).
- Blokady jądra na starcie każdego skompilowanego programu (JIT i `fih build`):
  Landlock (pliki według `import files`, TCP bez `import net`), limity
  zasobów (bez importów: żadnych nowych plików, gniazd ani procesów) i seccomp
  (gdy potrzebny). Koszt startu: ok. 14 µs.
- `tests/sandbox.sh`: sprawdza w gdb, że jądro odmawia tego, czego program nie
  zaimportował.
- Teksty w zmiennych: `t = "Ala"`, łączenie `+` (także z liczbą:
  `"Wynik: " + n`), dopisywanie `t += ...`, porównania `==` `!=`, `len(t)`
  (liczba znaków UTF-8), `t[i]`, wycinki `t[a:b]` (jak w Pythonie),
  `inputtext()` (cała linia z wejścia). Rodzaj zmiennej (liczba/tekst) ustala
  pierwsze przypisanie; pomyłki są błędami przed uruchomieniem.
- `print(wyrażenie)`: `print(2 + 3)` wypisuje `5`.
- `tests/fuzz/text_fuzz.py`: losowe programy na tekstach porównywane z Pythonem.

### Zmienione
- `print(2)` nie jest już błędem (komunikat `oczekiwano napisu w cudzysłowie`
  zniknął).

## [0.3.1] - 2026-10-19

### Zmienione (wydajność — Fih szybszy od C we wszystkich pomiarach)
- Dzielenie i reszta przez zmienną: instrukcja 32-bitowa, gdy obie liczby
  mieszczą się w 32 bitach (pętle z liczbami pierwszymi: 1,9× szybciej niż C).
- Wyjście zapisywane przez wskaźnik zapisu; gorący kod interpretera
  ułożony na początku programu i wyrównany (program print/calc: szybszy niż C
  także na jednym rdzeniu).

## [0.3.0] - 2026-10-19

### Dodane
- Wczytywanie ze standardowego wejścia: `input()` (liczba z linii),
  `inputchar()` (kod pierwszego znaku linii), `inputok()` (czy wpis był
  poprawny), `eof()` (koniec wejścia). Przed odczytem wyjście jest opróżniane,
  więc pytanie jest widoczne przed wpisem.
- `write("napis")` i `write(wyrażenie)`: wypisywanie bez nowej linii.
- Literały znakowe: `'+'`, `'a'`, `'\n'` — wartością jest kod znaku.
- Przykład `examples/kalkulator.fh`: liczba, działanie, liczba, wynik;
  powtarza pytanie przy złym wpisie, nie kończy się błędem przy dzieleniu
  przez zero ani przepełnieniu.

### Zmienione
- Nowe słowa zarezerwowane: `write`, `input`, `inputchar`, `inputok`, `eof`.

## [0.2.0] - 2026-10-19

### Dodane
- Zmienne całkowite 64-bit: `x = wyrażenie`, `+=` `-=` `*=` `/=` `%=`.
- `if` / `else if` / `else` i pętla `while` z blokami `{ }`, `break`, `continue`.
- Porównania `== != < <= > >=` (wynik 1/0, łańcuchy `0 < x < 10`),
  `and`, `or`, `not` liczone tylko w razie potrzeby.
- `calc(wyrażenie)` bez cudzysłowu (zapis `calc("...")` nadal działa).
- Kompilator do kodu maszynowego x86-64 (`src/comp.asm`): `fih program.fh`
  uruchamia kod z pamięci (JIT), `fih build` zapisuje go jako plik ELF.
  Stałe są liczone przy kompilacji, dzielenie przez stałą zamieniane na mnożenie.
- Błędy: `nieznana zmienna 'x'` (przed uruchomieniem), `zmienna 'x' nie ma
  jeszcze wartości` (w trakcie), błędy bloków (`brak '}'`, `else bez if`,
  `break poza pętlą` ...).
- Wzorcowa implementacja w Pythonie (`tests/fuzz/oracle.py`) i fuzzer
  programów 0.2 (`tests/fuzz/fuzz2.py`); benchmark pętli (liczby pierwsze).

### Zmienione
- Cały plik jest sprawdzany przed uruchomieniem: przy błędzie składni program
  nie wypisuje niczego (w 0.1 wcześniejsze linie zdążyły się wykonać).
- `fih build` przyjmuje programy z błędem w trakcie działania (np. dzielenie
  przez zero); błąd zgłasza skompilowany program, tak samo jak `fih program.fh`.
- `calc("2 + x")` zgłasza `nieznana zmienna 'x'`; `calc(2 + 2)` jest poprawne.

Każdy poprawny program 0.1 działa tak samo.

## [0.1.1] - 2026-10-19

### Dodane
- `fih --help` i `fih -h`: opis użycia na stdout, kod wyjścia 0.
- `fih --version`: wypisuje `fih 0.1.1`.
- CI w GitHub Actions: `make test` i krótki fuzzing przy każdym pushu.
- Wydania na GitHubie z gotową binarką `fih-linux-x86_64`.
- `SPEC.md`, `CHANGELOG.md`, `ROADMAP.md`, `CONTRIBUTING.md`.

Język się nie zmienił: każdy program 0.1.0 działa tak samo.

## [0.1.0] - 2026-10-19

Pierwsza wersja.

- Instrukcje `print("...")` i `calc("...")`, komentarze `#`.
- Arytmetyka całkowita 64-bit z wykrywaniem przepełnienia i dzielenia przez zero.
- Interpretacja (`fih program.fh`) i kompilacja do statycznego ELF (`fih build`).
- Duże programy (od 512 KB) na wszystkich rdzeniach.

[0.3.1]: https://github.com/vSake-clean/Fih/releases/tag/v0.3.1
[0.3.0]: https://github.com/vSake-clean/Fih/releases/tag/v0.3.0
[0.2.0]: https://github.com/vSake-clean/Fih/releases/tag/v0.2.0
[0.1.1]: https://github.com/vSake-clean/Fih/releases/tag/v0.1.1
[0.1.0]: https://github.com/vSake-clean/Fih/commit/f2f6a23
