# Zmiany

Format oparty na [Keep a Changelog](https://keepachangelog.com/pl/1.1.0/).
Wersje: `0.MINOR.PATCH` (patrz [CONTRIBUTING.md](CONTRIBUTING.md#wersje)).

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

[0.1.1]: https://github.com/vSake-clean/Fih/releases/tag/v0.1.1
[0.1.0]: https://github.com/vSake-clean/Fih/commit/f2f6a23
