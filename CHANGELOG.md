# Zmiany

Format oparty na [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/).
Wersje: `0.MINOR.PATCH` (patrz [CONTRIBUTING.md](CONTRIBUTING.md#wersje)).

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

[0.3.0]: https://github.com/vSake-clean/Fih/releases/tag/v0.3.0
[0.2.0]: https://github.com/vSake-clean/Fih/releases/tag/v0.2.0
[0.1.1]: https://github.com/vSake-clean/Fih/releases/tag/v0.1.1
[0.1.0]: https://github.com/vSake-clean/Fih/commit/f2f6a23
