#include <iostream>
int main() {
    long long ile = 0, suma = 0;
    for (long long n = 2; n < 300000; n++) {
        bool pierwsza = true;
        for (long long d = 2; d * d <= n; d++) {
            if (n % d == 0) { pierwsza = false; break; }
        }
        if (pierwsza) { ile++; suma += n; }
    }
    std::cout << ile << '\n' << suma << '\n';
    return 0;
}
