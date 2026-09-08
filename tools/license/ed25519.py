"""Pure-python Ed25519 (RFC 8032) sign/verify — no third-party deps.

Used by keygen.py / gen_license.py (license issuer tools) and the same
verify-only core is embedded in docker-web.py.
"""
import hashlib

_p = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_d = -121665 * pow(121666, _p - 2, _p) % _p
_I = pow(2, (_p - 1) // 4, _p)


def _xrecover(y):
    xx = (y * y - 1) * pow(_d * y * y + 1, _p - 2, _p)
    x = pow(xx, (_p + 3) // 8, _p)
    if (x * x - xx) % _p != 0:
        x = (x * _I) % _p
    if (x * x - xx) % _p != 0:
        raise ValueError("point not on curve")
    if x % 2 != 0:
        x = _p - x
    return x


_By = 4 * pow(5, _p - 2, _p) % _p  # base point y = 4/5
_Bx = _xrecover(_By)
_B = (_Bx % _p, _By % _p, 1, (_Bx * _By) % _p)
_IDENT = (0, 1, 1, 0)


def _edwards_add(P, Q):
    x1, y1, z1, t1 = P
    x2, y2, z2, t2 = Q
    a = (y1 - x1) * (y2 - x2) % _p
    b = (y1 + x1) * (y2 + x2) % _p
    c = t1 * 2 * _d * t2 % _p
    dd = z1 * 2 * z2 % _p
    e = b - a
    f = dd - c
    g = dd + c
    h = b + a
    return (e * f % _p, g * h % _p, f * g % _p, e * h % _p)


def _scalarmult(P, e):
    Q = _IDENT
    while e > 0:
        if e & 1:
            Q = _edwards_add(Q, P)
        P = _edwards_add(P, P)
        e >>= 1
    return Q


def _point_equal(P, Q):
    x1, y1, z1 = P[0], P[1], P[2]
    x2, y2, z2 = Q[0], Q[1], Q[2]
    return (x1 * z2 - x2 * z1) % _p == 0 and (y1 * z2 - y2 * z1) % _p == 0


def _point_compress(P):
    x, y, z, _ = P
    zi = pow(z, _p - 2, _p)
    x = x * zi % _p
    y = y * zi % _p
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _point_decompress(s):
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    if y >= _p:
        return None
    x = _xrecover(y)
    if x & 1 != sign:
        x = _p - x
    P = (x, y, 1, x * y % _p)
    if not _point_on_curve(P):
        return None
    return P


def _point_on_curve(P):
    x, y, z, t = P
    # ed25519: -x^2 + y^2 = 1 + d*x^2*y^2  →  y^2 - x^2 - z^2 - d*t^2 == 0 (extended)
    return (z % _p != 0 and x * y % _p == z * t % _p and
            (y * y - x * x - z * z - _d * t * t) % _p == 0)


def _secret_expand(seed):
    if len(seed) != 32:
        raise ValueError("seed must be 32 bytes")
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def publickey(seed):
    a, _ = _secret_expand(seed)
    return _point_compress(_scalarmult(_B, a))


def sign(seed, msg):
    a, prefix = _secret_expand(seed)
    A = _point_compress(_scalarmult(_B, a))
    r = int.from_bytes(hashlib.sha512(prefix + msg).digest(), "little") % _L
    R = _point_compress(_scalarmult(_B, r))
    k = int.from_bytes(hashlib.sha512(R + A + msg).digest(), "little") % _L
    S = (r + k * a) % _L
    return R + int.to_bytes(S, 32, "little")


def verify(pub, msg, sig):
    if len(sig) != 64 or len(pub) != 32:
        return False
    A = _point_decompress(pub)
    if A is None:
        return False
    Rs = sig[:32]
    R = _point_decompress(Rs)
    if R is None:
        return False
    S = int.from_bytes(sig[32:], "little")
    if S >= _L:
        return False
    h = int.from_bytes(hashlib.sha512(Rs + pub + msg).digest(), "little") % _L
    sB = _scalarmult(_B, S)
    hA = _scalarmult(A, h)
    RhA = _edwards_add(R, hA)
    return _point_equal(sB, RhA)
