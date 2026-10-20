# Specyfikacja języka Fih (wersja 0.3)

Ten plik opisuje dokładnie, jak działa język Fih i jego implementacja `fih`.
Jest napisany tak, żeby człowiek albo model AI mógł go przeczytać i znać
zachowanie każdej konstrukcji bez uruchamiania kodu. Wszystkie przykłady
i komunikaty pochodzą z działającej implementacji. Wzorcowa implementacja
w Pythonie, z którą testy porównują `fih`, jest w `tests/fuzz/oracle.py`.

## 1. Czym jest Fih

- Fih to mały język imperatywny: zmienne całkowite, `if`/`else`, pętla
  `while`, `break`/`continue`, wypisywanie napisów i liczb, wczytywanie
  liczb i znaków ze standardowego wejścia.
- Implementacja (`fih`) jest napisana w czystym assembly x86-64 (NASM),
  bez libc, wyłącznie na syscallach Linuksa. Działa tylko na Linuksie x86-64.
- `fih` jest kompilatorem: program zawsze jest tłumaczony na kod maszynowy
  x86-64. `fih program.fh` uruchamia go od razu z pamięci (JIT),
  `fih build program.fh` zapisuje go jako samodzielny plik ELF.
- Pliki źródłowe mają rozszerzenie `.fh`.

## 2. Przykład

```
# liczby pierwsze mniejsze od 30
n = 2
while n < 30 {
    d = 2
    pierwsza = 1
    while d * d <= n {
        if n % d == 0 {
            pierwsza = 0
            break
        }
        d += 1
    }
    if pierwsza {
        calc(n)
    }
    n += 1
}
print("koniec")
```

Wyjście: liczby `2 3 5 7 11 13 17 19 23 29`, każda w osobnej linii, potem `koniec`.

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
- Wcięcia nie mają znaczenia. Bloki wyznaczają klamry: `{` na końcu linii
  `if`/`while`, `}` na początku osobnej linii.
- `#` wewnątrz napisu nie jest komentarzem: `print("# to nie komentarz")`.
- Znak BOM UTF-8 na początku pliku nie jest obsługiwany (błąd „nieoczekiwany
  znak na początku instrukcji”).

## 4. Gramatyka (EBNF)

```ebnf
program     = { linia } ;
linia       = [ odstęp ] [ instrukcja [ odstęp ] ] [ komentarz ] [ "\r" ] "\n" ;
instrukcja  = print | write | calc | przypisanie | if | while | koniec_bloku
            | "break" | "continue" | import ;      (* import: punkt 8 *)

print       = "print" [ odstęp ] "(" [ odstęp ] napis [ odstęp ] ")" ;
write       = "write" [ odstęp ] "(" [ odstęp ] ( napis | wyrażenie ) [ odstęp ] ")" ;
calc        = "calc" [ odstęp ] "(" [ odstęp ] ( napis | wyrażenie ) [ odstęp ] ")" ;
przypisanie = nazwa [ odstęp ] ( "=" | "+=" | "-=" | "*=" | "/=" | "%=" ) wyrażenie ;
if          = "if" wyrażenie "{" ;
while       = "while" wyrażenie "{" ;
koniec_bloku= "}" [ "else" ( "{" | "if" wyrażenie "{" ) ] ;

napis       = '"' { znak | ucieczka } '"' ;          (* w jednej linii *)
znak        = dowolny bajt oprócz '"', '\' i nowej linii ;
ucieczka    = "\n" | "\t" | "\\" | '\"' ;
komentarz   = "#" { dowolny bajt oprócz nowej linii } ;
odstęp      = ( " " | "\t" ) { " " | "\t" } ;

(* wyrażenia, od najniższego priorytetu *)
wyrażenie   = and { "or" and } ;
and         = not { "and" not } ;
not         = "not" not | porównanie ;
porównanie  = suma { ( "==" | "!=" | "<" | "<=" | ">" | ">=" ) suma } ;
suma        = iloczyn { ( "+" | "-" ) iloczyn } ;
iloczyn     = unarny { ( "*" | "/" | "%" ) unarny } ;
unarny      = ( "-" | "+" ) unarny | prosty ;
prosty      = liczba | znak_lit | nazwa | funkcja | "(" wyrażenie ")" ;
funkcja     = ( "input" | "inputchar" | "inputok" | "eof" ) [ odstęp ] "(" [ odstęp ] ")" ;
znak_lit    = "'" ( drukowalny | "\n" | "\t" | "\\" | "\'" ) "'" ;  (* kod znaku *)
drukowalny  = bajt 32..126 oprócz "'" ;
liczba      = cyfra { cyfra } ;                     (* tylko dziesiętne *)
nazwa       = ( litera | "_" ) { litera | cyfra | "_" } ;   (* litery ASCII *)
```

W wyrażeniu spacje i tabulatory mogą stać między dowolnymi elementami.
Słowa `and`, `or`, `not` muszą być osobnymi słowami (`x or y`, ale `xory` to nazwa).
Wyrażenie bez cudzysłowu kończy się na `#` (komentarz) albo na końcu linii;
`'#'` (literał znakowy) nie zaczyna komentarza.

## 5. Instrukcje

### `print("napis")`

Wypisuje napis i znak nowej linii. Napis jest wypisywany dosłownie: nic nie
jest liczone ani podstawiane (`print("2 + 3")` wypisuje `2 + 3`, `print("x")`
wypisuje `x`, nie wartość zmiennej).

| zapis | znaczenie |
|-------|-----------|
| `\n`  | nowa linia |
| `\t`  | tabulator |
| `\\`  | backslash |
| `\"`  | cudzysłów |

Każda inna sekwencja (np. `\q`) to błąd. Surowy tabulator w napisie jest dozwolony.
`print("")` wypisuje pustą linię. `print` nie przyjmuje wyrażeń: `print(2)` to błąd.

### `write("napis")` i `write(wyrażenie)`

Jak `print` i `calc`, ale bez znaku nowej linii na końcu: `write("Wynik: ")`
i potem `calc(w)` dają jedną linię `Wynik: 42`. Uwaga: `write("2 + 3")`
wypisuje tekst `2 + 3` (napis), a nie wynik — do liczb służy `write(2 + 3)`.

### `calc(wyrażenie)` i `calc("wyrażenie")`

Liczy wyrażenie i wypisuje wynik dziesiętnie oraz znak nowej linii. Oba
zapisy są równoważne: `calc(x * 2)` i `calc("x * 2")` (zapis z cudzysłowem
pochodzi z wersji 0.1). W zapisie z cudzysłowem całe wnętrze napisu musi być
jednym wyrażeniem.

### Przypisanie

```
x = 2 + 3      # nowa zmienna albo nowa wartość
x += 1         # x = x + 1; podobnie -= *= /= %=
```

- `x op= e` liczy najpierw `x`, potem `e`, potem `x op e` — z tymi samymi
  regułami błędów co zwykłe działanie (przepełnienie, dzielenie przez zero).
- Wartość przypisuje się dopiero po policzeniu wyrażenia, więc `x = x + 1`
  wymaga, żeby `x` miała już wartość.

### `if` / `else if` / `else`

```
if warunek {
    ...
} else if inny_warunek {
    ...
} else {
    ...
}
```

Warunek jest prawdziwy, gdy jego wartość jest różna od 0. `else` musi stać
w tej samej linii co `}` zamykające poprzednią gałąź. Gałęzi `else if` może
być dowolnie wiele, `else` najwyżej jedno (na końcu).

### `while`

```
while warunek {
    ...
}
```

Warunek jest liczony przed każdym obrotem. `break` kończy najbliższą pętlę,
`continue` przechodzi do następnego obrotu (do sprawdzenia warunku).
`break` i `continue` poza pętlą to błąd. Pętla bez końca (`while 1 { }`)
działa, dopóki program nie zostanie przerwany.

## 6. Wyrażenia

Wszystkie wartości to liczby całkowite 64-bitowe ze znakiem: od
`-9223372036854775808` do `9223372036854775807`.

Priorytety (od najwyższego):

| poziom | operatory | łączność |
|--------|-----------|----------|
| 1 | unarne `-` `+` | wiązane z najbliższym argumentem |
| 2 | `*` `/` `%` | lewostronna |
| 3 | `+` `-` | lewostronna |
| 4 | `==` `!=` `<` `<=` `>` `>=` | łańcuch (jak w Pythonie) |
| 5 | `not` | prawostronna |
| 6 | `and` | lewostronna |
| 7 | `or` | lewostronna |

- Literały: tylko nieujemne liczby dziesiętne, zera wiodące są dozwolone (`007` = 7).
  Największy literał to `9223372036854775807`. Najmniejszą liczbę zapisuje się
  jako `-9223372036854775807 - 1`. Brak liczb ułamkowych, `1e3`, zapisu szesnastkowego.
- Unarne minusy i plusy można łączyć: `--5` = 5, `- 5` = -5, `2*-3` = -6.
  Minus wiąże tylko najbliższy argument: `-2 * 3` to `(-2) * 3`.
- `/` obcina w stronę zera: `-7 / 2` = -3. `%` ma znak dzielnej:
  `-7 % 2` = -1, `7 % -2` = 1 (jak w C). Dzielenie i reszta przez zero to błąd.
- Przepełnienie to błąd, a nie zawinięcie: `9223372036854775807 + 1`,
  `4294967296 * 4294967296`, `-(-9223372036854775807 - 1)`,
  `(-9223372036854775807 - 1) / -1`. Wyjątek: `(-9223372036854775807 - 1) % -1` = 0.
- Porównanie daje 1 (prawda) albo 0 (fałsz). Łańcuch `a < b < c` znaczy
  `a < b and b < c`, przy czym `b` jest liczone raz, a `c` tylko wtedy,
  gdy `a < b` jest prawdą. Można mieszać operatory: `1 < 2 > 0` = 1.
- `and` i `or` dają 1 albo 0 i liczą prawy argument tylko w razie potrzeby:
  `0 and 1 / 0` = 0 i `1 or 1 / 0` = 1 (bez błędu).
- `not x` daje 1, gdy `x` = 0, inaczej 0. `not` ma niższy priorytet niż
  porównania: `not x == 5` znaczy `not (x == 5)`. `not` może stać tylko na
  początku wyrażenia, po `and`/`or`, po innym `not` albo po `(`:
  `1 + not 0` to błąd, `1 + (not 0)` = 2.
- Kolejność liczenia: od lewej do prawej. Pierwszy błąd w tej kolejności
  kończy program.

### Literały znakowe

`'c'` to kod znaku `c` (ASCII): `'+'` = 43, `'a'` = 97, `'0'` = 48. Dozwolone są
znaki drukowalne ASCII (kody 32–126) oraz `'\n'` (10), `'\t'` (9), `'\\'`
(92), `'\''` (39). Inne zapisy, np. `'ab'` albo `'ł'`, to błąd
`zły zapis znaku (przykład: '+')`.

### Funkcje wejścia

Program czyta standardowe wejście linia po linii. Linia kończy się `\n`
(ostatnia może nie mieć `\n`). Spacje, tabulatory i `\r` na początku i na
końcu linii są pomijane. Przed każdym odczytem program wypisuje wszystko, co
czeka w buforze wyjścia — pytanie z `write` jest widoczne, zanim użytkownik
zacznie pisać.

| funkcja | wynik |
|---|---|
| `input()` | czyta linię; gdy to liczba całkowita (`[+-]cyfry`, w zakresie 64 bitów), zwraca ją, inaczej 0 |
| `inputchar()` | czyta linię i zwraca kod jej pierwszego znaku (bez spacji); pusta linia: 0; koniec wejścia: -1 |
| `inputok()` | 1, gdy ostatnie `input()` przeczytało poprawną liczbę albo `inputchar()` niepustą linię; inaczej 0 (także przed pierwszym odczytem) |
| `eof()` | 1, gdy któryś odczyt trafił na koniec wejścia (Ctrl+D, koniec pliku); inaczej 0 |

- Linia długości 64 KB lub więcej jest pomijana jak zły wpis (`input()` = 0,
  `inputok()` = 0).
- `input()` po końcu wejścia zwraca 0, a `inputok()` = 0 i `eof()` = 1.
- Funkcje wymagają nawiasów: `input` bez `()` to błąd
  `oczekiwano '()' po nazwie funkcji`. Wywołanie nie może być osobną
  instrukcją (`input()` w osobnej linii to błąd) — wynik trzeba przypisać
  albo użyć w wyrażeniu.
- Kolejność odczytów to kolejność liczenia (od lewej do prawej), a `and`/`or`
  nie wywołują prawej strony, gdy nie trzeba.

Przykład (kalkulator: `examples/kalkulator.fh`):

```
write("Podaj liczbę: ")
a = input()
while not inputok() and not eof() {
    print("To nie jest liczba, spróbuj jeszcze raz.")
    write("Podaj liczbę: ")
    a = input()
}
write("Działanie: ")
op = inputchar()
if op == '*' {
    write("Wynik: ")
    calc(a * a)
}
```

Przykłady:

| wyrażenie | wynik |
|-----------|-------|
| `2 + 3 * 4` | 14 |
| `(2 + 3) * 4` | 20 |
| `10 - 4 - 3` | 3 |
| `5 - - 5` | 10 |
| `0 < 5 < 10` | 1 |
| `3 >= 3 > 2 <= 2` | 1 |
| `not 0 or 0 and 1` | 1 |
| `-(1 < 2)` | -1 |

## 7. Zmienne

- Nazwa: litery ASCII, cyfry i `_`, nie zaczyna się od cyfry. Wielkość liter
  ma znaczenie (`x` i `X` to różne zmienne).
- Słowa zarezerwowane: `print`, `write`, `calc`, `if`, `else`, `while`,
  `break`, `continue`, `and`, `or`, `not`, `input`, `inputchar`, `inputok`, `eof`.
- Jedna przestrzeń nazw na cały program (bloki nie tworzą nowych zmiennych).
  Zmienna przypisana wewnątrz `if` istnieje też po nim.
- Zmienna musi dostać wartość, zanim zostanie użyta:
  - gdy w tekście programu przed użyciem nie ma żadnego przypisania tej
    zmiennej, program jest odrzucany przed uruchomieniem:
    `nieznana zmienna 'x'`;
  - gdy przypisanie jest wcześniej w tekście, ale się nie wykonało (np. było
    w pominiętej gałęzi `if`), program kończy się w trakcie:
    `zmienna 'x' nie ma jeszcze wartości`.
- Najwyżej 65 536 różnych zmiennych.

## 8. Importy i uprawnienia (0.4, w budowie)

Program bez importów nie ma żadnych uprawnień poza wypisywaniem na ekran
i czytaniem z klawiatury: nie czyta i nie zapisuje plików, nie łączy się
z siecią, nie uruchamia poleceń. Każdą z tych możliwości włącza import:

```
import math                                 # funkcje matematyczne
import files                                # wszystkie pliki
import files ./dane                         # tylko <folder programu>/dane
import files ./dane only read, write        # tylko te funkcje, tylko w ./dane
import files only read                      # tylko odczyt, wszędzie
import commands                             # wszystkie polecenia systemu
import commands only ls, git                # tylko te polecenia
import net                                  # cała sieć
import net example.com                      # tylko ten adres
import net example.com only get             # tylko get, tylko ten adres
import net only get, post                   # tylko te funkcje
import net only example.com, localhost      # domeny można podać też w only
```

W wersji w budowie działają same importy (sprawdzanie składni i blokady
systemu). Funkcje modułów (`math.sqrt`, `files.read`, ...) dochodzą w kolejnych
krokach wersji 0.4.

```ebnf
import      = "import" odstęp moduł [ odstęp miejsce ] [ odstęp "only" odstęp lista ] ;
moduł       = "math" | "files" | "commands" | "net" ;
miejsce     = folder | domena ;          (* folder: files, domena: net *)
lista       = element { [ odstęp ] "," [ odstęp ] element } ;
```

- Importy stoją na początku pliku: przed nimi mogą być tylko puste linie
  i komentarze. Import po innej instrukcji to błąd.
- Kilka importów tego samego modułu sumuje uprawnienia
  (`import files ./a` i `import files ./b` dają dostęp do obu folderów).
- Folder jest względny wobec folderu, w którym leży plik `.fh` (w programie
  po `fih build`: folderu pliku wykonywalnego). Nie może zaczynać się od `/`
  ani zawierać `..`. `import files .` to cały folder programu. Folder, którego
  nie ma przy starcie programu, nie daje żadnego dostępu.
- Funkcje w `only`:
  - `files`: `read`, `write`, `append`, `exists`, `delete`, `rename`, `mkdir`, `list`;
  - `net`: `get`, `post`, `download`, `tcp` oraz domeny (słowo z kropką albo `localhost`);
  - `math`: `abs`, `min`, `max`, `pow`, `sqrt`, `floor`, `ceil`, `round`, `sin`,
    `cos`, `tan`, `log`, `exp`, `random`;
  - `commands`: nazwy poleceń (litery, cyfry, `_ . + -`).
- `import = 5` (bez nazwy modułu za słowem) to nadal zwykłe przypisanie do
  zmiennej `import`, więc programy 0.3 działają bez zmian.

**Blokady systemu.** Oprócz sprawdzania programu przed uruchomieniem każdy
program skompilowany przez `fih` (także po `fih build`) na starcie prosi jądro
Linuksa o odebranie sobie uprawnień, których nie zaimportował:

- Landlock (Linux 5.13+): dostęp do plików tylko według `import files`
  (folder i funkcje); bez `import net` brak połączeń TCP (Linux 6.7+);
  sygnały i gniazda abstrakcyjne tylko w obrębie programu (Linux 6.12+),
- seccomp: bez `import net` brak gniazd sieciowych, bez `import commands` brak
  uruchamiania programów i tworzenia procesów, zawsze brak `io_uring` i `ptrace`.

Blokad nie da się zdjąć w trakcie działania. Dotyczą też poleceń uruchomionych
przez `commands`. Na jądrze bez Landlock zostaje seccomp i sprawdzanie przed
uruchomieniem.

## 9. Błędy

Każdy błąd kończy program komunikatem na stderr i kodem wyjścia 1:

```
fih: błąd w linii 2: dzielenie przez zero
```

Numer linii liczy się od 1, wliczając puste linie i komentarze.

### Błędy wykrywane przed uruchomieniem

Cały plik jest sprawdzany, zanim program zacznie działać. Przy takim błędzie
program nie wypisuje niczego, a `fih build` nie tworzy pliku wynikowego.
Zgłaszany jest pierwszy błąd w pliku.

| komunikat | przykład |
|-----------|----------|
| `nieoczekiwany znak na początku instrukcji` | `5print("a")`, `and = 1` |
| `nieznana instrukcja (znane: print, calc)` | `pisz("x")`, `Print("x")` |
| `oczekiwano '(' po nazwie instrukcji` | `print "x"`, `print = 5` |
| `oczekiwano napisu w cudzysłowie` | `print(2)` |
| `oczekiwano ')' po napisie` | `print("abc"` |
| `oczekiwano ')' po wyrażeniu` | `calc(1 + 2` |
| `niezamknięty napis` | `print("abc)` |
| `nieznana sekwencja ucieczki (znane: \n \t \\ \")` | `print("a\qb")` |
| `nieoczekiwane znaki po instrukcji` | `print("a") print("b")`, `if 1 { x = 1` |
| `oczekiwano '=' po nazwie zmiennej` | `x == 1`, `x` |
| `oczekiwano '{' na końcu linii` | `if x > 0`, `} else x` |
| `'}' bez otwartego bloku` | `}` na początku programu |
| `niezamknięty blok: brak '}'` | `if 1 {` bez `}` (numer linii otwarcia bloku) |
| `else bez if` | `else {`, `} else {` po `while` albo po `else` |
| `break poza pętlą` / `continue poza pętlą` | `break` poza `while` |
| `nieznana zmienna 'x'` | `calc(x)` bez wcześniejszego `x = ...` |
| `niekompletne wyrażenie` | `calc("")`, `x = 2 *` |
| `nieoczekiwany znak w wyrażeniu` | `calc(2 3)`, `calc(1e3)`, `calc(1 + not 0)` |
| `brak ')' w wyrażeniu` | `calc((2 + 3)` |
| `liczba za duża (max 9223372036854775807)` | `calc(9223372036854775808)` |
| `wyrażenie zbyt głęboko zagnieżdżone` | bardzo dużo nawiasów (punkt 11) |
| `oczekiwano '()' po nazwie funkcji` | `x = input`, `x = input(5)` |
| `zły zapis znaku (przykład: '+')` | `'ab'`, `'ł'`, `'a` |
| `za dużo zmiennych (max 65536)` | 65 537. nowa zmienna |
| `bloki zbyt głęboko zagnieżdżone (max 65536)` | 65 537 bloków jeden w drugim |
| `nieznany moduł 'x' (znane: math, files, commands, net)` | `import foo` |
| `oczekiwano nazwy modułu po import (znane: math, files, commands, net)` | `import` |
| `import musi być na początku pliku, przed innymi instrukcjami` | `x = 1`, potem `import math` |
| `nieznana funkcja 'x' w module files (znane: ...)` | `import files only rm` |
| `po only podaj listę, np. only read, write` | `import files only` |
| `oczekiwano 'only' albo końca linii` | `import files ./a ./b` |
| `ten moduł nie przyjmuje folderu ani adresu (tylko files i net)` | `import math ./x` |
| `folder musi być względny wobec folderu programu, np. ./dane` | `import files /etc` |
| `folder nie może wychodzić poza folder programu ('..')` | `import files ../x` |
| `zły adres (przykład: example.com)` | `import net zly` |
| `niedozwolony znak w imporcie` | bajt sterujący w folderze |

### Błędy w trakcie działania

Program wypisuje wszystko, co policzył przed błędem, potem komunikat.
`fih build` tworzy plik wynikowy, a skompilowany program kończy się tym samym
wyjściem, komunikatem i kodem co `fih program.fh`.

| komunikat | przykład |
|-----------|----------|
| `dzielenie przez zero` | `calc(1 / 0)`, `x %= 0` |
| `przepełnienie: wynik poza zakresem liczb 64-bitowych` | `calc(9223372036854775807 + 1)` |
| `zmienna 'x' nie ma jeszcze wartości` | `if 0 {` … `x = 1` … `}`, potem `calc(x)` |

### Błędy bez numeru linii

`fih: błąd: ...`: `nie można otworzyć pliku`, `nie można wczytać pliku`,
`nie można zapisać wyjścia` (np. pełny dysk, zamknięte stdout), `brak pamięci`,
`plik źródłowy zmienił się (skrócił) podczas wykonania`, `nie można zapisać
pliku wynikowego`, `plik wynikowy nadpisałby plik źródłowy`, `plik nie ma
rozszerzenia .fh — podaj nazwę wyniku: -o nazwa`, `za długa ścieżka`.
Skompilowany program też zgłasza `nie można zapisać wyjścia` z kodem 1.

Implementacja nigdy nie kończy się awarią (sygnałem). Każda sytuacja kończy się
wynikiem albo komunikatem `fih: błąd...`. Wyjątek: zamknięty potok (np.
`fih p.fh | head -1`) kończy program sygnałem SIGPIPE, jak każdy program w Linuksie.

## 10. Uruchamianie

```sh
./fih program.fh                  # uruchomienie
./fih build program.fh            # kompilacja do ./program
./fih build program.fh -o nazwa   # kompilacja do ./nazwa
echo 'calc(6*7)' | ./fih /dev/stdin
./fih --help                      # opis użycia na stdout (także -h)
./fih --version                   # wypisuje: fih 0.3.1
./fih examples/kalkulator.fh      # program czytający z klawiatury
```

Kody wyjścia: `0` sukces, `1` błąd, `2` złe argumenty (sposób użycia na stderr).

- `fih program.fh` kompiluje program do kodu maszynowego w pamięci i od razu
  go uruchamia (JIT). Nie powstaje żaden plik.
- `fih build` zapisuje ten sam kod jako statyczny plik ELF x86-64 bez
  bibliotek, uruchamiany bez `fih`. Oba tryby dają identyczne wyjście,
  komunikaty i kody wyjścia.
- Programy, które mają tylko `print` i `calc` ze stałymi (jak w wersji 0.1),
  są wyliczane od razu przez szybki interpreter, a `fih build` zapisuje gotowy
  wynik. Pliki takich programów od 512 KB są liczone na wszystkich rdzeniach.
  Wynik jest ten sam co w zwykłym trybie.
- Kod maszynowy: zmienne leżą w pamięci; dzielenie przez stałą jest
  zamieniane na mnożenie; stałe wyrażenia są liczone podczas kompilacji.

## 11. Limity

- Liczby: 64 bity ze znakiem (punkt 6).
- Głębokość nawiasów: nawiasy mogą zużyć najwyżej 1/4 limitu stosu
  (`ulimit -s`). Przy domyślnym stosie 8 MB to 21 846 poziomów. Ponad limit
  pojawia się błąd `wyrażenie zbyt głęboko zagnieżdżone`, a nie awaria.
  W bardzo złożonych wyrażeniach (wiele poziomów priorytetu w każdym
  nawiasie) limit może być mniejszy.
- Zmienne: 65 536. Zagnieżdżenie bloków: 65 536.
- Długość linii, napisów i programu: bez stałego limitu (testowane z napisem
  20 MB i programem 3 MB).
- Plik źródłowy jest mapowany do pamięci (`mmap`). Skrócenie pliku w trakcie
  kompilacji daje błąd, a nie awarię.

## 12. Czego nie ma w wersji 0.3

Fih 0.3 nie ma: napisów w zmiennych (`print` przyjmuje tylko napis w
cudzysłowie, a z wejścia można czytać tylko liczby i pojedyncze znaki),
funkcji definiowanych przez użytkownika, tablic, operacji na napisach,
argumentów wiersza poleceń, importu innych plików, komentarzy blokowych,
pętli `for`.
Plan dalszych wersji: [ROADMAP.md](ROADMAP.md).

## 13. Zmiany wobec wcześniejszych wersji

0.3: nowe słowa zarezerwowane (`write`, `input`, `inputchar`, `inputok`,
`eof`) — program 0.2 ze zmienną o takiej nazwie trzeba poprawić. Poza tym
programy 0.2 działają tak samo.

0.2 wobec 0.1: każdy poprawny program 0.1 działa tak samo. Zmieniło się zachowanie
programów z błędami:

- Błąd składni jest zgłaszany przed uruchomieniem, więc wcześniejsze linie
  niczego już nie wypisują (w 0.1 wypisywały).
- `fih build` przyjmuje programy z błędem w trakcie działania (np.
  `calc("1/0")`); błąd zgłasza skompilowany program (w 0.1 kompilacja się
  nie udawała).
- `calc("2 + x")` zgłasza `nieznana zmienna 'x'` zamiast
  `nieoczekiwany znak w wyrażeniu`; `calc(2 + 2)` jest poprawne (wypisuje 4).
