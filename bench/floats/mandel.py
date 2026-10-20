# zbiór Mandelbrota 600 × 400, do 100 kroków: ile punktów należy do zbioru
ile = 0
y = 0
while y < 400:
    ci = y * 3.0 / 400 - 1.5
    x = 0
    while x < 600:
        cr = x * 3.5 / 600 - 2.5
        zr = 0.0
        zi = 0.0
        i = 0
        while i < 100 and zr * zr + zi * zi <= 4.0:
            t = zr * zr - zi * zi + cr
            zi = 2.0 * zr * zi + ci
            zr = t
            i += 1
        if i == 100:
            ile += 1
        x += 1
    y += 1
print(ile)
