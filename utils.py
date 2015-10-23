import pickle
from collections import namedtuple

# ---------------- Datatypes ----------------

# 0..39, bitmask of length 24, bitmask of length 24
State = namedtuple("State", "score hand deck")

# ---------------- Prettification ----------------

def card_to_str(card):
    q, r = divmod(card, 8)
    return "%d %s" % (r + 1, ["red", "blue", "yellow"][q])

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

# def default(obj):
#     if isinstance(obj, State):
#         return [obj.score, obj.hand, obj.deck]

# class StateDecoder(json.JSONDecoder):
#     def JSONArray(self, s_and_end, scan_once, **kwargs):
#         values, end = json.decoder.JSONArray(s_and_end, scan_once, **kwargs)
#         return State(values), end

def dump(obj, f):
    # if isinstance(obj, dict) and obj and isinstance(obj.keys()[0], State):
    #     obj = [(key, value) for key, value in obj.items()]
    # json.dump(obj, f, separators=(',', ':'), default=default)
    pickle.dump(obj, f)

def load(f):
    # obj = json.load(f, cls=StateDecoder)
    # if isinstance(obj, list) and obj and isinstance(obj[0], list) and isinstance(obj[0][0], list):
    #     obj = 
    return pickle.load(f)

# ---------------- Bit operations ----------------

def num_ones(n):
    res = 0
    while n:
        if n & 1:
            res += 1
        n >>= 1
    return res

def list_to_binary(alist):
    res = 0
    for elem in alist:
        res |= (1 << elem)
    return res

def binary_to_list(binary):
    res = []
    curr = 0
    while binary:
        if binary & 1:
            res.append(curr)
        curr += 1
        binary >>= 1
    return res
