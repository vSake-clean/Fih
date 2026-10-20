/* suma pierwiastków liczb 0 .. 2 999 999 (sqrt), wynik obcięty do całości */
#include <cmath>
#include <iostream>
int main(void) {
    double s = 0.0;
    for (long i = 0; i < 3000000; i++) s = s + sqrt((double)i);
    std::cout << (long)std::floor(s) << "\n";
    return 0;
}
