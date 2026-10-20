/* zbiór Mandelbrota 600 × 400, do 100 kroków: ile punktów należy do zbioru */
#include <iostream>
int main(void) {
    long ile = 0;
    for (long y = 0; y < 400; y++) {
        double ci = y * 3.0 / 400 - 1.5;
        for (long x = 0; x < 600; x++) {
            double cr = x * 3.5 / 600 - 2.5, zr = 0.0, zi = 0.0;
            long i = 0;
            while (i < 100 && zr * zr + zi * zi <= 4.0) {
                double t = zr * zr - zi * zi + cr;
                zi = 2.0 * zr * zi + ci;
                zr = t;
                i++;
            }
            if (i == 100) ile++;
        }
    }
    std::cout << ile << "\n";
    return 0;
}
