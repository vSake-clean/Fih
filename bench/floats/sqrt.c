/* suma pierwiastków liczb 0 .. 2 999 999 (sqrt), wynik obcięty do całości */
#include <math.h>
#include <stdio.h>
int main(void) {
    double s = 0.0;
    for (long i = 0; i < 3000000; i++) s = s + sqrt((double)i);
    printf("%ld\n", (long)floor(s));
    return 0;
}
