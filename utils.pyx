# cython: profile=True

import json
from collections import namedtuple

# ---------------- Bit operations ----------------

cdef int num_ones(int n) except -1:
    cdef int res = 0
    while n:
        if n & 1:
            res += 1
        n >>= 1
    return res

cdef int list_to_binary(alist) except -1:
    cdef int res = 0
    cdef int elem
    for elem in alist:
        res |= (1 << elem)
    return res

cdef binary_to_list(int binary):
    res = []
    cdef int curr = 0
    while binary:
        if binary & 1:
            res.append(curr)
        curr += 1
        binary >>= 1
    return res

# ---------------- Datatypes ----------------

# absolute or relative path, offset in total bytes / bytes per record, size in total bytes / bytes per record
Location = namedtuple("Location", "path offset size")

Handle = namedtuple("Handle", "fileobj mmapobj")

# ---------------- Prettification ----------------

def card_to_str(card):
    q, r = divmod(card, 8)
    return "%d %s" % (r + 1, ["red", "blu", "yel"][q])

def cardset_to_str(hand):
    return ', '.join(card_to_str(card) for card in binary_to_list(hand))

# ---------------- Persistence and caching ----------------

def dump(obj, f):
    json.dump(obj, f, separators=(',',':'), sort_keys=True)

def load(f):
    return json.load(f)

# ---------------- Miscellaneous ----------------

def to_base(a, base, zfill=None):
    if a == 0:
        res = '0'
    else:
        digits = []
        while a:
            m, r = divmod(a, base)
            digits.append(r)
            a = m
        res = ''.join(str(v) for v in reversed(digits))
    if zfill is None:
        return res
    else:
        return res.zfill(zfill)
