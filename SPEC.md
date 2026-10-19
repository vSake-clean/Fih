# Specyfikacja języka Fih (wersja 0.1)

Ten plik opisuje dokładnie, jak działa język Fih i jego implementacja `fih`.
Jest napisany tak, żeby człowiek albo model AI mógł go przeczytać i znać
zachowanie każdej konstrukcji bez uruchamiania kodu. Wszystkie przykłady
i komunikaty pochodzą z działającej implementacji.

## 1. Czym jest Fih

- Fih to celowo minimalny język: w wersji 0.1 ma dokładnie dwie instrukcje,
  `print` i `calc`.
- Implementacja (`fih`) jest napisana w czystym assembly x86-64 (NASM), bez libc,
  wyłącznie na syscallach Linuksa. Działa tylko na Linuksie x86-64.
- Ten sam program można uruchomić od razu (interpretacja) albo skompilować
  do samodzielnego pliku ELF (`fih build`).
- Pliki źródłowe mają rozszerzenie `.fh`.

## 2. Przykład

```
# komentarz
print("Witaj, świecie!")
calc("2 + 2")             # 4
calc("(1 + 2) * -3")      # -9
print("2 + 3")            # wypisuje dosłownie: 2 + 3
```

Wyjście:

```
Witaj, świecie!
4
-9
2 + 3
```

## 3. Budowa pliku

- Plik to ciąg bajtów w UTF-8 (napisy są przepisywane bajt po bajcie, więc
  działa każdy tekst: `zażółć gęślą jaźń 🐟`).
- Linie są rozdzielone `\n`. Końce linii `\r\n` (Windows) są akceptowane.
  Ostatnia linia nie musi kończyć się znakiem nowej linii.
- **Jedna instrukcja na linię.** Nie ma średników ani łączenia instrukcji.
- Linia może być:
  - pusta albo zawierać tylko spacje, tabulatory i `\r`,
  - komentarzem: `#` i wszystko do końca linii,
  - jedną instrukcją, po której opcjonalnie stoją spacje/tabulatory i komentarz.
- Białe znaki (spacja, tabulator) są dozwolone: na początku linii, między nazwą
  instrukcji a `(`, między `(` a napisem, między napisem a `)` i po `)`.
- `#` wewnątrz napisu nie jest komentarzem: `print("# to nie komentarz")`.
- Znak BOM UTF-8 na początku pliku nie jest obsługiwany (błąd „nieoczekiwany
  znak na początku instrukcji”).

## 4. Gramatyka (EBNF)

```ebnf
program     = { linia } ;
linia       = [ odstęp ] [ instrukcja [ odstęp ] ] [ komentarz ] [ "\r" ] "\n" ;
instrukcja  = nazwa [ odstęp ] "(" [ odstęp ] napis [ odstęp ] ")" ;
nazwa       = "print" | "calc" ;                    (* wielkość liter ma znaczenie *)
napis       = '"' { znak | ucieczka } '"' ;          (* w jednej linii *)
znak        = dowolny bajt oprócz '"', '\' i nowej linii ;
ucieczka    = "\n" | "\t" | "\\" | '\"' ;
komentarz   = "#" { dowolny bajt oprócz nowej linii } ;
odstęp      = ( " " | "\t" ) { " " | "\t" } ;

(* wnętrze napisu w calc *)
wyrażenie   = składnik { ( "+" | "-" ) składnik } ;
składnik    = czynnik { ( "*" | "/" | "%" ) czynnik } ;
czynnik     = ( "-" | "+" ) czynnik | liczba | "(" wyrażenie ")" ;
liczba      = cyfra { cyfra } ;                     (* tylko dziesiętne *)
cyfra       = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;
```

W wyrażeniu spacje i tabulatory mogą stać między dowolnymi elementami.

## 5. Instrukcje

### `print("napis")`

Wypisuje napis i znak nowej linii. Napis jest wypisywany dosłownie: nic nie
jest liczone ani podstawiane (`print("2 + 3")` wypisuje `2 + 3`).

Sekwencje ucieczki:

| zapis | znaczenie |
|-------|-----------|
| `\n`  | nowa linia |
| `\t`  | tabulator |
| `\\`  | backslash |
| `\"`  | cudzysłów |

Każda inna sekwencja (np. `\q`) to błąd. Surowy tabulator w napisie jest dozwolony.
`print("")` wypisuje pustą linię.

### `calc("wyrażenie")`

Liczy wyrażenie na liczbach całkowitych 64-bitowych ze znakiem i wypisuje wynik
dziesiętnie oraz znak nowej linii.

- Zakres: od `-9223372036854775808` do `9223372036854775807`.
- Literały: tylko nieujemne liczby dziesiętne, zera wiodące są dozwolone (`007` = 7).
  Największy literał to `9223372036854775807`. Najmniejszą liczbę zapisuje się
  jako `-9223372036854775807 - 1`.
- Brak liczb ułamkowych, zapisu `1e3`, szesnastkowego, zmiennych i funkcji.
- Operatory i priorytety (od najwyższego):
  1. unarne `-` i `+` (można je łączyć: `--5` = 5, `- 5` = -5, `2*-3` = -6),
  2. `*`, `/`, `%` (łączność lewostronna),
  3. `+`, `-` (łączność lewostronna: `10 - 4 - 3` = 3).
- Nawiasy `( )` zmieniają kolejność i można je dowolnie zagnieżdżać
  (do limitu, patrz punkt 8).
- `/` obcina w stronę zera: `-7 / 2` = -3.
- `%` ma znak dzielnej: `-7 % 2` = -1, `7 % -2` = 1 (jak w C).
- Dzielenie i reszta przez zero to błąd.
- Przepełnienie to błąd, a nie zawinięcie: `9223372036854775807 + 1`,
  `4294967296 * 4294967296`, `-(-9223372036854775807 - 1)`,
  `(-9223372036854775807 - 1) / -1`.
  Wyjątek: `(-9223372036854775807 - 1) % -1` = 0.

Przykłady:

| wyrażenie | wynik |
|-----------|-------|
| `2 + 3 * 4` | 14 |
| `(2 + 3) * 4` | 20 |
| `100 / 10 / 5` | 2 |
| `-(3 - 10)` | 7 |
| `5 - - 5` | 10 |
| `  1+2   ` | 3 |
| `((((((1))))))` | 1 |

## 6. Błędy

Każdy błąd kończy program komunikatem na stderr i kodem wyjścia 1. Błędy
w programie mają numer linii (liczony od 1, wliczając puste linie i komentarze):

```
fih: błąd w linii 2: dzielenie przez zero
```

Pełna lista komunikatów błędów w programie:

| komunikat | przykład |
|-----------|----------|
| `nieznana instrukcja (znane: print, calc)` | `pisz("x")`, `Print("x")`, `PRINT("x")` |
| `nieoczekiwany znak na początku instrukcji` | `5print("a")` |
| `oczekiwano '(' po nazwie instrukcji` | `print "x"` |
| `oczekiwano napisu w cudzysłowie` | `calc(2 + 2)` |
| `oczekiwano ')' po napisie` | `print("abc"` |
| `niezamknięty napis` | `print("abc)` |
| `nieznana sekwencja ucieczki (znane: \n \t \\ \")` | `print("a\qb")` |
| `nieoczekiwane znaki po instrukcji` | `print("a") print("b")`, `print("x");` |
| `niekompletne wyrażenie` | `calc("")`, `calc("2 *")` |
| `nieoczekiwany znak w wyrażeniu` | `calc("2 + x")`, `calc("2 3")`, `calc("2 + 3)")`, `calc("1e3")` |
| `brak ')' w wyrażeniu` | `calc("(2 + 3")` |
| `dzielenie przez zero` | `calc("1 / 0")`, `calc("5 % (2 - 2)")` |
| `liczba za duża (max 9223372036854775807)` | `calc("9223372036854775808")` |
| `przepełnienie: wynik poza zakresem liczb 64-bitowych` | `calc("9223372036854775807 + 1")` |
| `wyrażenie zbyt głęboko zagnieżdżone` | bardzo dużo nawiasów (patrz punkt 8) |

Błędy bez numeru linii (`fih: błąd: ...`): `nie można otworzyć pliku`,
`nie można wczytać pliku`, `nie można zapisać wyjścia` (np. pełny dysk,
zamknięty potok), `brak pamięci`, `plik źródłowy zmienił się (skrócił) podczas
wykonania`, `nie można zapisać pliku wynikowego`, `plik wynikowy nadpisałby
plik źródłowy`, `plik nie ma rozszerzenia .fh — podaj nazwę wyniku: -o nazwa`,
`za długa ścieżka`.

Implementacja nigdy nie kończy się awarią (sygnałem). Każda sytuacja kończy się
wynikiem albo komunikatem `fih: błąd...`.

## 7. Uruchamianie

```sh
./fih program.fh                  # interpretacja
./fih build program.fh            # kompilacja do ./program
./fih build program.fh -o nazwa   # kompilacja do ./nazwa
echo 'calc("6*7")' | ./fih /dev/stdin
```

Kody wyjścia: `0` sukces, `1` błąd, `2` złe argumenty (wypisuje sposób użycia).
Nie ma opcji `--help` ani `--version`.

### Interpretacja

Program jest wykonywany linia po linii. Gdy w linii jest błąd, wyjście
wcześniejszych linii zostaje wypisane, potem pojawia się komunikat błędu.

### Kompilacja (`build`)

- Cały program jest sprawdzany i wyliczany w czasie kompilacji. Wyniki `calc`
  są liczone wtedy, a skompilowany program tylko wypisuje gotowy tekst.
- Gdy w programie jest jakikolwiek błąd, kompilacja kończy się tym samym
  komunikatem co interpretacja (z numerem linii) i plik wynikowy nie powstaje.
  Niepełny plik wynikowy (np. przy pełnym dysku) jest usuwany.
- Wynik to statyczny plik ELF x86-64 bez bibliotek, uruchamiany bez `fih`.

### Duże programy

Pliki od 512 KB są wykonywane na wszystkich rdzeniach: plik jest dzielony na
granicach linii, każdy kawałek liczy osobny proces, a wyniki są wypisywane po
kolei. Wyjście i komunikaty błędów są identyczne jak przy wykonaniu po kolei.
Gdy nie da się utworzyć procesów (limit procesów, pamięci), program jest
wykonywany po kolei.

## 8. Limity

- Liczby: 64 bity ze znakiem (punkt 5).
- Głębokość nawiasów w `calc`: nawiasy mogą zużyć najwyżej 1/4 limitu stosu
  (`ulimit -s`). Przy domyślnym stosie 8 MB to 21 845 poziomów. Ponad limit
  pojawia się błąd `wyrażenie zbyt głęboko zagnieżdżone`, a nie awaria.
- Długość linii i napisów: bez stałego limitu (testowane z napisem 20 MB).
- Plik źródłowy jest mapowany do pamięci (`mmap`). Skrócenie pliku w trakcie
  wykonania daje błąd, a nie awarię.

## 9. Czego nie ma w wersji 0.1

Fih 0.1 nie ma: zmiennych, typów innych niż liczba całkowita i napis, porównań
i operatorów logicznych, `if`/`else`, pętli, funkcji, tablic, operacji na
napisach, wejścia (stdin, argumenty), importu innych plików, komentarzy
blokowych, opcji `--help`/`--version`. Program w Fih to ciąg niezależnych
instrukcji `print` i `calc` wykonywanych od góry do dołu.
