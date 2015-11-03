import json, logging
from collections import namedtuple

# ---------------- Bit operations ----------------

cpdef int num_ones(int n):
    cdef int res = 0
    while n:
        if n & 1:
            res += 1
        n >>= 1
    return res

cpdef int list_to_binary(alist):
    cdef int res = 0
    cdef int elem
    for elem in alist:
        res |= (1 << elem)
    return res

cpdef binary_to_list(int binary):
    res = []
    cdef int curr = 0
    while binary:
        if binary & 1:
            res.append(curr)
        curr += 1
        binary >>= 1
    return res

# ---------------- Datatypes ----------------

# 0..39, bitmask of length 24, bitmask of length 24
State = namedtuple("State", "score hand deck")
# 0/1 (remove/deal), bitmask of selected cards, int
Move = namedtuple("Move", "action param score_change")
# absolute or relative path, offset in total bytes / bytes per record, size in total bytes / bytes per record
Location = namedtuple("Location", "path offset size")
Handle = namedtuple("Handle", "fileobj mmapobj")

# ---------------- Prettification ----------------

def card_to_str(card):
    q, r = divmod(card, 8)
    return "%d %s" % (r + 1, ["red", "blu", "yel"][q])

def cardset_to_str(hand):
    return ', '.join(card_to_str(card) for card in binary_to_list(hand))

def state_to_str(state):
    if isinstance(state, State):
        return str(State(state.score, cardset_to_str(state.hand), cardset_to_str(state.deck)))
    elif isinstance(state, tuple):
        assert len(state) == 2
        return (cardset_to_str(state[0]), cardset_to_str(state[1]))
    else:
        raise TypeError("Unrecognized type: %s" % type(state))

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
