#include <stdio.h>
int main(void) {
    long long ile = 0, suma = 0;
    for (long long n = 2; n < 300000; n++) {
        int pierwsza = 1;
        for (long long d = 2; d * d <= n; d++) {
            if (n % d == 0) { pierwsza = 0; break; }
        }
        if (pierwsza) { ile++; suma += n; }
    }
    printf("%lld\n%lld\n", ile, suma);
    return 0;
}
