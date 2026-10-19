"""Wzorcowa implementacja Fih 0.2 w Pythonie (wyrocznia dla fuzzerów i testów).

run(src) -> (stdout, stderr, kod, rodzaj), gdzie rodzaj to:
  None       program zakończył się poprawnie,
  "static"   błąd wykryty przed uruchomieniem (build go odrzuca, nic nie jest wypisane),
  "runtime"  błąd w trakcie (build się udaje, skompilowany program kończy się tym błędem).

Cały plik jest najpierw parsowany (pierwszy błąd wygrywa), potem wykonywany.
Kolejność sprawdzeń odwzorowuje kompilator w assembly (src/comp.asm).
"""
I64_MIN, I64_MAX = -(1 << 63), (1 << 63) - 1
MAX_VARS = 65536
MAX_BLOCKS = 65536


def max_paren_depth(stack_limit=8 << 20):
    """limit zagnieżdżenia nawiasów: budżet = min(1 MB, ulimit -s / 4)"""
    budget = min(1 << 20, stack_limit // 4)
    return (budget - 16) // 48 + 1


MSG = {
    "char": "nieoczekiwany znak na początku instrukcji",
    "lparen": "oczekiwano '(' po nazwie instrukcji",
    "string": "oczekiwano napisu w cudzysłowie",
    "unterminated": "niezamknięty napis",
    "rparen": "oczekiwano ')' po napisie",
    "rparen_expr": "oczekiwano ')' po wyrażeniu",
    "trailing": "nieoczekiwane znaki po instrukcji",
    "unknown": "nieznana instrukcja (znane: print, calc)",
    "escape": "nieznana sekwencja ucieczki (znane: \\n \\t \\\\ \\\")",
    "assign": "oczekiwano '=' po nazwie zmiennej",
    "lbrace": "oczekiwano '{' na końcu linii",
    "rbrace": "'}' bez otwartego bloku",
    "unclosed": "niezamknięty blok: brak '}'",
    "else": "else bez if",
    "break": "break poza pętlą",
    "continue": "continue poza pętlą",
    "too_many_vars": "za dużo zmiennych (max 65536)",
    "too_many_blocks": "bloki zbyt głęboko zagnieżdżone (max 65536)",
    "e_unexpected": "nieoczekiwany znak w wyrażeniu",
    "e_incomplete": "niekompletne wyrażenie",
    "e_rparen": "brak ')' w wyrażeniu",
    "e_div0": "dzielenie przez zero",
    "e_big": "liczba za duża (max 9223372036854775807)",
    "e_ovf": "przepełnienie: wynik poza zakresem liczb 64-bitowych",
    "e_deep": "wyrażenie zbyt głęboko zagnieżdżone",
    "func": "oczekiwano '()' po nazwie funkcji",
    "char_lit": "zły zapis znaku (przykład: '+')",
}
FUNCS = (b"input", b"inputchar", b"inputok", b"eof")
LINE_MAX = 65536            # linia wejścia od tej długości jest za długa
RUNTIME = {"e_div0", "e_ovf", "no_value"}


class FihError(Exception):
    def __init__(self, kind, line, name=None):
        self.kind, self.line, self.name = kind, line, name

    def text(self):
        if self.kind == "unknown_var":
            m = "nieznana zmienna '" + self.name.decode() + "'"
        elif self.kind == "no_value":
            m = "zmienna '" + self.name.decode() + "' nie ma jeszcze wartości"
        else:
            m = MSG[self.kind]
        return f"fih: błąd w linii {self.line}: {m}\n".encode()


def ident_start(c): return c == 95 or 65 <= c <= 90 or 97 <= c <= 122
def ident_char(c): return ident_start(c) or 48 <= c <= 57


# poziomy priorytetu operatorów dwuargumentowych
PREC = {"or": 1, "and": 2, "==": 4, "!=": 4, "<": 4, "<=": 4, ">": 4, ">=": 4,
        "+": 5, "-": 5, "*": 6, "/": 6, "%": 6}
P_NOT, P_CMP = 3, 4


class Parser:
    def __init__(self, src, max_depth):
        self.src, self.n = src, len(src)
        self.max_depth = max_depth
        self.line = 1
        self.assigned = set()       # zmienne przypisane we wcześniejszych instrukcjach

    def err(self, kind, name=None):
        raise FihError(kind, self.line, name)

    # ---------- wyrażenia w [p, bound) ----------
    def ws(self):
        while self.p < self.bound and self.src[self.p] in b" \t": self.p += 1

    def word(self):
        q = self.p
        if q < self.bound and ident_start(self.src[q]):
            while q < self.bound and ident_char(self.src[q]): q += 1
        return self.src[self.p:q]

    def binop(self):
        """operator dwuargumentowy w p (bez przesuwania) albo None"""
        w = self.word()
        if w in (b"and", b"or"): return w.decode()
        s = self.src[self.p:min(self.p + 2, self.bound)]
        if s in (b"==", b"!=", b"<=", b">="): return s.decode()
        c = s[:1]
        if c and c in b"<>+-*/%": return c.decode()
        return None

    def expr(self, minp, depth):
        """wspinaczka po priorytetach; zwraca drzewo"""
        lhs = self.unary(minp, depth)
        while True:
            self.ws()
            op = self.binop()
            if op is None or PREC[op] < minp: return lhs
            self.p += len(op)
            if PREC[op] == P_CMP:
                ops, rest = [op], [self.expr(P_CMP + 1, depth)]
                while True:
                    self.ws()
                    op2 = self.binop()
                    if op2 is None or PREC[op2] != P_CMP: break
                    self.p += len(op2)
                    ops.append(op2); rest.append(self.expr(P_CMP + 1, depth))
                lhs = ("cmp", lhs, ops, rest)
            else:
                lhs = (op, lhs, self.expr(PREC[op] + 1, depth))

    def unary(self, minp, depth):
        self.ws()
        if self.word() == b"not" and minp <= P_NOT:
            k = 0
            while self.word() == b"not":
                self.p += 3; k += 1; self.ws()
            e = self.expr(P_CMP, depth)
            return ("not", e) if k % 2 else ("bool", e)
        neg = 0
        while True:
            self.ws()
            c = self.src[self.p] if self.p < self.bound else None
            if c == 45: neg ^= 1; self.p += 1; continue
            if c == 43: self.p += 1; continue
            break
        e = self.primary(depth)
        return ("neg", e) if neg else e

    def primary(self, depth):
        if self.p >= self.bound: self.err("e_incomplete")
        c = self.src[self.p]
        if c == 40:
            if depth >= self.max_depth: self.err("e_deep")
            self.p += 1
            e = self.expr(0, depth + 1)
            self.ws()
            if self.p >= self.bound or self.src[self.p] != 41: self.err("e_rparen")
            self.p += 1
            return e
        if 48 <= c <= 57:
            v = 0
            while self.p < self.bound and 48 <= self.src[self.p] <= 57:
                v = v * 10 + self.src[self.p] - 48
                if v > I64_MAX: self.err("e_big")
                self.p += 1
            return ("num", v)
        if c == 39:                                   # 'c'
            if self.p + 2 >= self.bound: self.err("char_lit")
            ch = self.src[self.p + 1]
            if ch == 92:
                if self.p + 3 >= self.bound or self.src[self.p + 3] != 39: self.err("char_lit")
                e = self.src[self.p + 2]
                v = {110: 10, 116: 9, 92: 92, 39: 39}.get(e)
                if v is None: self.err("char_lit")
                self.p += 4
                return ("num", v)
            if ch == 39 or not 32 <= ch <= 126 or self.src[self.p + 2] != 39: self.err("char_lit")
            self.p += 3
            return ("num", ch)
        if ident_start(c):
            name = self.word()
            if name in FUNCS:
                self.p += len(name)
                self.ws()
                if self.p >= self.bound or self.src[self.p] != 40: self.err("func")
                self.p += 1
                self.ws()
                if self.p >= self.bound or self.src[self.p] != 41: self.err("func")
                self.p += 1
                return ("call", name)
            if name in (b"and", b"or", b"not", b"write"): self.err("e_unexpected")
            if name not in self.assigned: self.err("unknown_var", name)
            self.p += len(name)
            return ("var", name)
        self.err("e_unexpected")

    def parse_expr(self, start, bound):
        self.p, self.bound = start, bound
        e = self.expr(0, 0)
        self.ws()
        return e

    # ---------- linie: kursor q, koniec linii eol ----------
    def blank(self):
        while self.q < self.eol and self.src[self.q] in b" \t\r": self.q += 1

    def at(self, ch):
        return self.q < self.eol and self.src[self.q] == ch

    def end_check(self):
        self.blank()
        if self.q < self.eol and self.src[self.q] != 35: self.err("trailing")

    def bare_bound(self):
        """koniec wyrażenia bez cudzysłowu: '#' (poza literałem '#') albo koniec linii"""
        i = self.q
        while i < self.eol:
            c = self.src[i]
            if c == 35: return i
            i += 1
            if c == 39:
                if i >= self.eol: return self.eol
                i += 2 if self.src[i] == 92 else 1
                if i >= self.eol: return self.eol
                if self.src[i] == 39: i += 1
        return self.eol

    def bare_expr(self):
        """wyrażenie bez cudzysłowu: do '#' albo końca linii"""
        e = self.parse_expr(self.q, self.bare_bound())
        self.q = self.p
        return e

    def ident(self):
        q = self.q
        while q < self.eol and ident_char(self.src[q]): q += 1
        name = self.src[self.q:q]
        self.q = q
        return name

    def string(self):
        """kursor tuż za otwierającym '"' -> (początek, koniec) treści"""
        s0 = self.q
        while True:
            if self.q >= self.eol: self.err("unterminated")
            ch = self.src[self.q]
            if ch == 34: break
            self.q += 1
            if ch == 92:
                if self.q >= self.eol: self.err("unterminated")
                self.q += 1
        s1 = self.q
        self.q += 1
        return s0, s1

    def lbrace(self):
        self.blank()
        if not self.at(123): self.err("lbrace")
        self.q += 1
        self.end_check()

    def parse(self):
        top = []
        # stos bloków: [rodzaj ("if"/"else"/"while"), lista instrukcji, linia otwarcia, węzeł if]
        self.stack = []
        pos = 0
        while pos < self.n:
            e = self.src.find(b"\n", pos)
            self.eol = self.n if e < 0 else e
            self.q = pos
            self.statement(self.stack[-1][1] if self.stack else top)
            pos = self.eol + 1
            self.line += 1
        if self.stack:
            self.line = self.stack[-1][2]
            self.err("unclosed")
        return top

    def open_block(self, kind, body, node):
        if len(self.stack) >= MAX_BLOCKS: self.err("too_many_blocks")
        self.stack.append([kind, body, self.line, node])

    def statement(self, out):
        self.blank()
        if self.q >= self.eol or self.at(35): return
        line = self.line
        c = self.src[self.q]
        if c == 125:                                    # '}'
            if not self.stack: self.err("rbrace")
            self.q += 1
            self.blank()
            if self.q >= self.eol or self.at(35):
                self.stack.pop()
                return
            if self.ident() != b"else": self.err("trailing")
            top = self.stack[-1]
            if top[0] != "if": self.err("else")
            self.blank()
            if self.at(123):                            # } else {
                self.q += 1
                self.end_check()
                body = []
                top[3][4] = body
                top[0], top[1], top[2] = "else", body, line
                return
            if self.ident() != b"if": self.err("lbrace")
            cond = self.bare_expr()                     # } else if warunek {
            self.lbrace()
            body = []
            node = ["if", line, cond, body, None]
            top[3][4] = node
            top[1], top[2], top[3] = body, line, node
            return
        if not ident_start(c): self.err("char")
        name = self.ident()
        if name in (b"print", b"calc", b"write"):
            self.blank()
            if not self.at(40): self.err("lparen")
            self.q += 1
            self.blank()
            if name == b"write" and self.at(34):
                self.q += 1
                s0, s1 = self.string()
                self.blank()
                if not self.at(41): self.err("rparen")
                self.q += 1
                self.end_check()
                out.append(("print", line, self.unescape(self.src[s0:s1])[:-1]))
                return
            if name == b"print" or self.at(34):
                if not self.at(34): self.err("string")
                self.q += 1
                s0, s1 = self.string()
                self.blank()
                if not self.at(41): self.err("rparen")
                self.q += 1
                self.end_check()
                if name == b"print":
                    out.append(("print", line, self.unescape(self.src[s0:s1])))
                else:
                    e = self.parse_expr(s0, s1)
                    if self.p < s1: self.err("e_unexpected")
                    out.append(("calc", line, e))
                return
            e = self.bare_expr()
            self.blank()
            if not self.at(41): self.err("rparen_expr")
            self.q += 1
            self.end_check()
            out.append(("calc" if name == b"calc" else "write", line, e))
            return
        if name in (b"if", b"while"):
            cond = self.bare_expr()
            self.lbrace()
            body = []
            if name == b"if":
                node = ["if", line, cond, body, None]
                out.append(node)
                self.open_block("if", body, node)
            else:
                out.append(("while", line, cond, body))
                self.open_block("while", body, None)
            return
        if name == b"else": self.err("else")
        if name in (b"break", b"continue"):
            self.end_check()
            if not any(b[0] == "while" for b in self.stack): self.err(name.decode())
            out.append((name.decode(), line))
            return
        if name in (b"and", b"or", b"not") or name in FUNCS: self.err("char")
        self.blank()
        if self.at(40): self.err("unknown")
        if self.at(61) and self.src[self.q + 1:self.q + 2] != b"=":
            op = "="
            self.q += 1
        elif self.q + 1 < self.eol and self.src[self.q] in b"+-*/%" and self.src[self.q + 1] == 61:
            op = chr(self.src[self.q])
            self.q += 2
        else:
            self.err("assign")
        if op != "=" and name not in self.assigned: self.err("unknown_var", name)
        if name not in self.assigned and len(self.assigned) >= MAX_VARS: self.err("too_many_vars")
        e = self.bare_expr()
        self.end_check()
        out.append(("set", line, name, op, e))
        self.assigned.add(name)

    def unescape(self, body):
        out = bytearray()
        i = 0
        while i < len(body):
            if body[i] == 92:
                e = body[i + 1]
                if e == 110: out += b"\n"
                elif e == 116: out += b"\t"
                elif e in b'\\"': out.append(e)
                else: self.err("escape")
                i += 2
            else:
                out.append(body[i])
                i += 1
        return bytes(out) + b"\n"


# ---------- wykonanie ----------
class Break(Exception): pass
class Continue(Exception): pass
class Steps(Exception): pass


def chk(v, line):
    if not I64_MIN <= v <= I64_MAX: raise FihError("e_ovf", line)
    return v


def arith(op, a, b, line):
    if op == "+": return chk(a + b, line)
    if op == "-": return chk(a - b, line)
    if op == "*": return chk(a * b, line)
    if b == 0: raise FihError("e_div0", line)
    if b == -1:
        return chk(-a, line) if op == "/" else 0
    q = abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1)
    return q if op == "/" else a - q * b


CMP = {"==": lambda a, b: a == b, "!=": lambda a, b: a != b, "<": lambda a, b: a < b,
       "<=": lambda a, b: a <= b, ">": lambda a, b: a > b, ">=": lambda a, b: a >= b}


class Input:
    """stan standardowego wejścia programu"""
    def __init__(self, data):
        self.data, self.pos, self.ok, self.eof = data, 0, 0, 0

    def line(self):
        """-> linia bez '\\n' (obcięta), b"..." za długa = None, koniec = False"""
        if self.pos >= len(self.data): return False
        i = self.data.find(b"\n", self.pos)
        if i < 0: i = len(self.data)
        raw = self.data[self.pos:i]
        self.pos = i + 1
        if len(raw) >= LINE_MAX: return None
        return raw.strip(b" \t\r")

    def input(self):
        l = self.line()
        if l is False:
            self.eof, self.ok = 1, 0
            return 0
        self.ok = 0
        if not l: return 0
        body = l[1:] if l[:1] in (b"+", b"-") else l
        if not body or not body.isdigit() or not body.isascii(): return 0
        if len(body.lstrip(b"0")) > 19: return 0       # na pewno poza zakresem
        v = int(l[:1] + body.lstrip(b"0") if l[:1] in (b"+", b"-") else body.lstrip(b"0") or b"0") if body.lstrip(b"0") else 0
        if not I64_MIN <= v <= I64_MAX: return 0
        self.ok = 1
        return v

    def inputchar(self):
        l = self.line()
        if l is False:
            self.eof, self.ok = 1, 0
            return -1
        self.ok = 0
        if not l: return 0
        self.ok = 1
        return l[0]


IN = [None]


def ev(e, env, line):
    k = e[0]
    if k == "num": return e[1]
    if k == "call":
        inp = IN[0]
        if e[1] == b"input": return inp.input()
        if e[1] == b"inputchar": return inp.inputchar()
        if e[1] == b"inputok": return inp.ok
        return inp.eof
    if k == "var":
        if e[1] not in env: raise FihError("no_value", line, e[1])
        return env[e[1]]
    if k == "neg": return chk(-ev(e[1], env, line), line)
    if k == "not": return int(ev(e[1], env, line) == 0)
    if k == "bool": return int(ev(e[1], env, line) != 0)
    if k == "and": return int(ev(e[1], env, line) != 0 and ev(e[2], env, line) != 0)
    if k == "or": return int(ev(e[1], env, line) != 0 or ev(e[2], env, line) != 0)
    if k == "cmp":
        a = ev(e[1], env, line)
        for op, r in zip(e[2], e[3]):
            b = ev(r, env, line)
            if not CMP[op](a, b): return 0
            a = b
        return 1
    return arith(k, ev(e[1], env, line), ev(e[2], env, line), line)


def execute(stmts, env, out, steps):
    for s in stmts:
        steps[0] -= 1
        if steps[0] < 0: raise Steps
        k = s[0]
        if k == "print":
            out += s[2]
        elif k == "calc":
            out += str(ev(s[2], env, s[1])).encode() + b"\n"
        elif k == "write":
            out += str(ev(s[2], env, s[1])).encode()
        elif k == "set":
            _, line, name, op, e = s
            if op == "=":
                env[name] = ev(e, env, line)
            else:
                if name not in env: raise FihError("no_value", line, name)
                a = env[name]
                env[name] = arith(op, a, ev(e, env, line), line)
        elif k == "if":
            node = s
            while True:
                _, line, cond, body, els = node
                if ev(cond, env, line):
                    execute(body, env, out, steps)
                    break
                if isinstance(els, list) and els and els[0] == "if":   # else if
                    node = els
                    continue
                if els is not None:
                    execute(els, env, out, steps)
                break
        elif k == "while":
            _, line, cond, body = s
            while ev(cond, env, line):
                steps[0] -= 1
                if steps[0] < 0: raise Steps
                try:
                    execute(body, env, out, steps)
                except Break:
                    break
                except Continue:
                    pass
        elif k == "break":
            raise Break
        elif k == "continue":
            raise Continue


def run(src, max_depth=None, steps=1_000_000, stdin=b""):
    """-> (stdout, stderr, kod, rodzaj); wyjątek Steps, gdy program liczy za długo"""
    p = Parser(src, max_depth or max_paren_depth())
    try:
        prog = p.parse()
    except FihError as e:
        return b"", e.text(), 1, "static"
    out = bytearray()
    IN[0] = Input(stdin)
    try:
        execute(prog, {}, out, [steps])
    except FihError as e:
        return bytes(out), e.text(), 1, "runtime"
    return bytes(out), b"", 0, None
