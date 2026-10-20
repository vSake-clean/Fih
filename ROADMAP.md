# Plan rozwoju

## 0.1: kalkulator (gotowe)

`print` i `calc`, interpretacja i kompilacja, stabilność, wydajność.

## 0.2: zmienne i sterowanie (gotowe)

- Zmienne całkowite, `=` i `+=` `-=` `*=` `/=` `%=`.
- `if` / `else if` / `else`, `while`, `break`, `continue`.
- Porównania (także łańcuchy `0 < x < 10`), `and`, `or`, `not`.
- Kompilator do kodu maszynowego: JIT (`fih program.fh`) i plik ELF (`fih build`).
- Cały plik sprawdzany przed uruchomieniem.

## 0.3: wczytywanie danych (gotowe)

- `input()`, `inputchar()`, `inputok()`, `eof()`, `write`, literały znakowe `'+'`.
- Przykład: kalkulator (`examples/kalkulator.fh`).

## 0.4: uprawnienia, teksty, ułamki (w budowie)

- Importy z uprawnieniami (`import math`, `files`, `commands`, `net`, `only`)
  i blokady jądra (Landlock, limity, seccomp) — gotowe.
- Teksty w zmiennych, łączenie, `len`, indeksy, wycinki, `inputtext()` — gotowe.
- Ułamki, `/` (ułamek) i `//` (całkowite), moduł `math` — gotowe.
- Funkcje modułów `files`, `commands`, `net` — dalej.

Szczegóły: [SPEC.md](SPEC.md), [CHANGELOG.md](CHANGELOG.md).

## Później (pomysły, bez kolejności i obietnic)

- funkcje,
- tablice,
- argumenty wiersza poleceń, wczytywanie napisów,
- zmienne w rejestrach procesora (szybsze pętle),
- podświetlanie składni (VS Code, Vim),
- inne platformy (ARM64).
