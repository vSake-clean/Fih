#!/usr/bin/env python3
"""Generuje src/trig_tab.inc: bity 2/pi do redukcji argumentu sin/cos/tan
(metoda Payne'a-Hanka) i pi/2 w formacie 80-bitowym x87.

rt_2opi: 24 słowa, od najstarszego bitu; bit j ma wagę 2^(63 - j)
(pierwsze 64 bity to zera: część całkowita 2/pi jest zerem).
"""
import os

WORDS = 24
PREC = 64 * WORDS + 128


def arctan_inv(n, bits):
    """arctan(1/n) * 2^bits (szereg Taylora na liczbach całkowitych)."""
    one = 1 << bits
    x = one // n
    total, k, sign, n2 = x, 1, -1, n * n
    while x:
        x //= n2
        total += sign * (x // (2 * k + 1))
        sign, k = -sign, k + 1
    return total


def pi_scaled(bits):
    # Machin: pi = 16 atan(1/5) - 4 atan(1/239), z zapasem 64 bitów
    g = bits + 64
    return (16 * arctan_inv(5, g) - 4 * arctan_inv(239, g)) >> 64


def main():
    pi = pi_scaled(PREC)                        # pi * 2^PREC
    v = (2 << (2 * PREC)) // pi                 # 2/pi * 2^PREC
    v >>= PREC - (64 * WORDS - 64)              # 2/pi * 2^(64*WORDS - 64)
    words = [(v >> (64 * (WORDS - 1 - i))) & ((1 << 64) - 1) for i in range(WORDS)]
    # pi/2 w 80 bitach: mantysa 64 bity (z jawną jedynką), zaokrąglona
    p = pi_scaled(200)                          # pi * 2^200
    m = (p + (1 << (200 - 62 - 1))) >> (200 - 62)   # pi/2 * 2^63, zaokrąglone
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "trig_tab.inc")
    with open(out, "w") as f:
        f.write("; trig_tab.inc — wygenerowane przez tools/trig_tab.py; nie edytować\n")
        f.write("; bity 2/pi (bit j ma wagę 2^(63 - j)) do redukcji argumentu sin/cos/tan\n")
        f.write("align 8\nrt_2opi:\n")
        for i in range(0, WORDS, 2):
            f.write("    dq 0x%016x, 0x%016x\n" % (words[i], words[i + 1]))
        f.write("; pi/2 (80 bitów x87: mantysa, wykładnik 16383)\nrt_pio2:\n")
        f.write("    dq 0x%016x\n    dw 0x3fff\n" % m)


if __name__ == "__main__":
    main()
