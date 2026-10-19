# Plan rozwoju

## 0.1: kalkulator (gotowe)

`print` i `calc`, interpretacja i kompilacja, stabilność, wydajność.

## 0.2: zmienne i sterowanie (w pracy)

Ustalona składnia:

```
# zmienne: liczby całkowite 64-bit
i = 1
suma = 0

while i <= 10 {
    if i % 2 == 0 and not i == 6 {
        suma = suma + i
    } else {
        print("nieparzysta albo 6")
    }
    i = i + 1
}

calc(suma)        # wyrażenie bez cudzysłowu
calc("suma * 2")  # zapis z 0.1 też działa
```

- Przypisanie `nazwa = wyrażenie`, bez słowa kluczowego. Użycie zmiennej
  przed przypisaniem to błąd.
- Jedyny typ zmiennych: liczba całkowita 64-bit. Porównania `== != < <= > >=`
  dają 1 albo 0. Operatory logiczne `and`, `or`, `not`.
- `if` / `else` i `while` z blokami w klamrach `{ }`.
- `calc(wyrażenie)` przyjmuje wyrażenie z cudzysłowem albo bez.
- Cały plik jest sprawdzany przed uruchomieniem: błąd składni (np. brak `}`)
  jest zgłaszany, zanim program cokolwiek wypisze. Błędy obliczeń (dzielenie
  przez zero, przepełnienie) dalej pojawiają się w trakcie.
- `fih build` generuje prawdziwy kod maszynowy x86-64 (zmienne w pamięci,
  pętle jako skoki), zamiast wyliczać wynik podczas kompilacji.
- Tryb wielordzeniowy zostaje dla programów, które mają tylko `print`/`calc`.
- Zgodność: każdy poprawny program 0.1 działa w 0.2 tak samo.

## Później (pomysły, bez kolejności i obietnic)

- napisy w zmiennych, łączenie napisów, `print` zmiennej,
- funkcje,
- wczytywanie danych (stdin, argumenty),
- podświetlanie składni (VS Code, Vim),
- inne platformy (ARM64).
