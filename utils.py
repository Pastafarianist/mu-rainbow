import json
from collections import namedtuple

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

# ---------------- Domain-specific stuff ----------------

def are_valid_values(hand_values):
    for v in range(8):
        if hand_values.count(v) > 3:
            return False
    return True

def categorize_values(values):
    val_cnt = [0] * 8

    for v in values:
        val_cnt[v] += 1

    val_cnt.sort(reverse=True)

    if val_cnt[0] == 3:
        if val_cnt[1] == 2:
            return 0  # 00011
        elif val_cnt[1] == 1:
            return 1  # 00012
    elif val_cnt[0] == 2:
        if val_cnt[1] == 2:
            return 2  # 01122
        else:
            return 3  # 01233
    else:
        return 4  # 01234

masks = ((1 << 8) - 1, ((1 << 8) - 1) << 8, ((1 << 8) - 1) << 16)

def apply_permutation(num, perm):
    new_num = (num & masks[perm[0]]) >> (perm[0] * 8)
    new_num |= (((num & masks[perm[1]]) >> (perm[1] * 8)) << 8)
    new_num |= (((num & masks[perm[2]]) >> (perm[2] * 8)) << 16)
    return new_num

def equiv_class(state):
    return ((apply_permutation(state.hand, p), apply_permutation(state.deck, p)) for p in (
        (0, 1, 2),
        (0, 2, 1),
        (1, 0, 2),
        (1, 2, 0),
        (2, 0, 1),
        (2, 1, 0)
    ))

def canonicalize(state):
    canonical = min(equiv_class(state))
    return State(state.score, canonical[0], canonical[1])

def expand_deck(hand, deck):
    res = 0
    i = 0
    while deck:
        if not (hand & 1):
            res |= ((deck & 1) << i)
            deck >>= 1
        hand >>= 1
        i += 1
    return res

def compactify_deck(hand, deck):
    res = 0
    i = 0
    while deck:
        if not (hand & 1):
            res |= ((deck & 1) << i)
            i += 1
        else:
            assert not (deck & 1)
        deck >>= 1
        hand >>= 1
    return res

# meanings of card numbers:
# 0-7 = red cards 1-8
# 8-15 = blue cards 1-8
# 16-24 = yellow cards 1-8

def score_combination(combo):
    rem = sorted(v % 8 for v in combo)
    if combo[0] // 8 == combo[1] // 8 == combo[2] // 8 and rem[0] == rem[1] - 1 == rem[2] - 2:
        # same color, consecutive
        return (rem[0]) * 10 + 50
    elif rem[0] == rem[1] == rem[2]:
        # same numbers
        return (rem[0]) * 10 + 20
    elif rem[0] == rem[1] - 1 == rem[2] - 2:
        # different colors, consecutive
        return (rem[0]) * 10 + 10
    assert False, cardset_to_str(combo)

def card_combinations(hand):

    v2c = [[] for _ in range(8)]
    for card in hand:
        v2c[card % 8].append(card // 8)

    # different colors, consecutive
    for v in range(6):
        if v2c[v] and v2c[v + 1] and v2c[v + 2]:
            for col1 in v2c[v]:
                for col2 in v2c[v + 1]:
                    for col3 in v2c[v + 2]:
                        if col1 == col2 == col3:
                            score = v * 10 + 50
                        else:
                            score = v * 10 + 10
                        combo = (v + col1 * 8, v + 1 + col2 * 8, v + 2 + col3 * 8)
                        assert score_combination(combo) == score, 'combo: %r, score: %d, score_combination(combo): %d' % (combo, score, score_combination(combo))
                        yield score, combo

    # same numbers
    for v, colors in enumerate(v2c):
        if len(colors) == 3:
            score = v * 10 + 20
            combo = (v + colors[0] * 8, v + colors[1] * 8, v + colors[2] * 8)
            assert score_combination(combo) == score, 'combo: %r, score: %d, score_combination(combo): %d' % (combo, score, score_combination(combo))
            yield score, combo

def moves_from_hand(hand):
    hand_as_list = binary_to_list(hand)
    remove_moves = [Move(0, (1 << i), 0) for i in hand_as_list]
    deal_moves = [Move(1, list_to_binary(combo), score) for score, combo in card_combinations(hand_as_list)]
    return remove_moves + deal_moves

def best_move_score(hand):
    hand_as_list = binary_to_list(hand)
    best_score = 0
    for score, _ in card_combinations(hand_as_list):
        best_score = max(best_score, score)
    return best_score

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

