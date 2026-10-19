# Jak pomóc

## Błędy i pomysły

Zgłoś [issue](https://github.com/vSake-clean/Fih/issues). Przy błędzie podaj:
najmniejszy program `.fh`, który go pokazuje, polecenie (`fih x.fh` czy
`fih build`), wyjście, kod wyjścia i `fih --version`.

Każda awaria (sygnał, np. `Segmentation fault`) to błąd: Fih zawsze powinien
kończyć się wynikiem albo komunikatem `fih: błąd...`.

## Budowanie i testy

Wymagania: Linux x86-64, NASM 2.15+, GNU ld, Python 3, gcc (wyrocznia w fuzzerze),
`hyperfine` (tylko benchmarki).

```sh
make            # ./fih
make test       # testy w obu trybach (interpretacja i build)
make fuzz       # długi fuzzing
```

Wzorcowa implementacja języka w Pythonie to `tests/fuzz/oracle.py`. Fuzzery
porównują z nią `fih` (wyjście, komunikat, numer linii, kod wyjścia, oba tryby).
Zmiana w języku wymaga tej samej zmiany w wyroczni.

Każda zmiana zachowania potrzebuje testu:

- `tests/ok/X.fh` + `X.out`: oczekiwane stdout, kod 0,
- `tests/err/X.fh` + `X.err`: oczekiwany komunikat błędu, kod 1; przy błędzie
  w trakcie działania opcjonalnie `X.out` z wyjściem przed błędem,
- pozostałe przypadki w `tests/run.sh`.

`tests/run.sh` uruchamia każdy plik w obu trybach. Wynik musi być identyczny.

## Styl kodu

- Wyłącznie assembly x86-64 (NASM), bez libc, tylko syscalle Linuksa.
- Komentarze po polsku. Każda funkcja ma nagłówek
  `; nazwa(rdi=..., rsi=...) -> rax = ...` z opisem.
- `default rel`, wspólne stałe w `src/fih.inc`.
- Błędy w programie przez makro `ERR etykieta, "komunikat"`, komunikaty
  małą literą, po polsku.
- Szybka ścieżka bez skoków, rzadkie przypadki w osobnej sekcji.
- Optymalizacja tylko z pomiarem (`make bench`) przed i po.

Zmiana w języku wymaga też aktualizacji `SPEC.md` i `CHANGELOG.md`.

## Wersje

Numer `0.MINOR.PATCH`, zgodny z [SemVer](https://semver.org/lang/pl/):

- PATCH (0.1.0 → 0.1.1): poprawki i drobne dodatki, język bez zmian.
- MINOR (0.1 → 0.2): nowe możliwości języka. Dotychczasowe poprawne programy
  powinny działać tak samo. Każde odstępstwo jest opisane w `CHANGELOG.md`.
- 1.0: składnia ustabilizowana. Od tego momentu zmiany łamiące zgodność
  tylko w nowej wersji głównej.

Wydanie: zmiana `FIH_VERSION` w `src/fih.inc`, wpis w `CHANGELOG.md`, tag `vX.Y.Z`.
GitHub Actions buduje i publikuje binarkę.
