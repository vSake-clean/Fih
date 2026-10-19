ile = 0
suma = 0
n = 2
while n < 300000:
    d = 2
    pierwsza = True
    while d * d <= n:
        if n % d == 0:
            pierwsza = False
            break
        d += 1
    if pierwsza:
        ile += 1
        suma += n
    n += 1
print(ile)
print(suma)
