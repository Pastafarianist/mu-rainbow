# cython: profile=True

import itertools, json
from collections import namedtuple
import cython

# meanings of card numbers:
# 0-7 = red cards 1-8
# 8-15 = blue cards 1-8
# 16-24 = yellow cards 1-8

# ---------------- Datatypes ----------------

# 0..39, bitmask of length 24, bitmask of length 24
# State = namedtuple("State", "score hand deck")
cdef class State:
    # cdef readonly int score, hand, deck #  this is now in the .pxd
    def __init__(self, score, hand, deck):
        self.score = score
        self.hand = hand
        self.deck = deck

# 0/1 (remove/deal), bitmask of selected cards, int
# Move = namedtuple("Move", "action param score_change")
cdef class Move:
    cdef readonly int action, param, score_change
    def __init__(self, action, param, score_change):
        self.action = action
        self.param = param
        self.score_change = score_change

# absolute or relative path, offset in total bytes / bytes per record, size in total bytes / bytes per record
# Location = namedtuple("Location", "path offset size")
cdef class Location:
    # cdef readonly str path  # moved to .pxd
    # cdef readonly long offset, size
    def __init__(self, path, offset, size):
        self.path = path
        self.offset = offset
        self.size = size

Handle = namedtuple("Handle", "fileobj mmapobj")

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

# ---------------- Deck manipulations ----------------

# It needs to be imported in generator.py, hence cpdef
cpdef int expand_deck(int hand, int deck) except -1:
    cdef int res = 0
    cdef int i = 0
    while deck:
        if not (hand & 1):
            res |= ((deck & 1) << i)
            deck >>= 1
        hand >>= 1
        i += 1
    return res

cdef int compactify_deck(int hand, int deck) except -1:
    cdef int res = 0
    cdef int i = 0
    while deck:
        if not (hand & 1):
            res |= ((deck & 1) << i)
            i += 1
        else:
            assert not (deck & 1)
        deck >>= 1
        hand >>= 1
    return res

# ---------------- State factorization ----------------

cdef int[3] masks = ((1 << 8) - 1, ((1 << 8) - 1) << 8, ((1 << 8) - 1) << 16)

@cython.profile(False)
cdef inline int apply_permutation(int num, int p1, int p2, int p3) except -1:
    # x * 8 == x << 3
    return (
        ((num & masks[p1]) >> (p1 << 3)) |
        (((num & masks[p2]) >> (p2 << 3)) << 8) |
        (((num & masks[p3]) >> (p3 << 3)) << 16)
    )

cdef int[15] permutations = [
    0, 2, 1,
    1, 0, 2,
    1, 2, 0,
    2, 0, 1,
    2, 1, 0
]

cdef State canonicalize(State state):
    cdef int chand = state.hand
    cdef int cdeck = state.deck
    cdef int nhand, ndeck, i, p1, p2, p3
    for i in range(0, 15, 3):
        p1, p2, p3 = permutations[i], permutations[i + 1], permutations[i + 2]
        nhand = apply_permutation(state.hand, p1, p2, p3)
        ndeck = apply_permutation(state.deck, p1, p2, p3)
        # The following `if` is simply this line unrolled:
        # chand, cdeck = min((chand, cdeck), (nhand, ndeck))
        if nhand < chand or (nhand == chand and ndeck < cdeck):
            chand = nhand
            cdeck = ndeck
    return State(state.score, chand, cdeck)

# ---------------- Scoring ----------------

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

# ---------------- Game moves ----------------

def moves_from_hand(hand):
    hand_as_list = binary_to_list(hand)
    remove_moves = [Move(0, (1 << i), 0) for i in hand_as_list]
    deal_moves = [Move(1, list_to_binary(combo), score // 10) for score, combo in card_combinations(hand_as_list)]
    return remove_moves + deal_moves

def best_move_score(hand):
    hand_as_list = binary_to_list(hand)
    best_score = 0
    for score, _ in card_combinations(hand_as_list):
        best_score = max(best_score, score)
    return best_score

cdef moves(State state):
    assert state.deck
    return moves_cache[state.hand]

cdef outcomes(State state, Move move):
    cdef int new_score, new_hand_partial, new_hand, new_deck
    cdef int temp, card
    cdef int mask, replenishment
    assert state.deck, state
    assert state.hand & move.param == move.param, (state, move)
    new_score = state.score + move.score_change
    new_hand_partial = state.hand ^ move.param
    result = []
    if move.action == 0:
        # remove
        temp = state.deck
        card = 0
        while temp:
            if temp & 1:
                new_hand = new_hand_partial | (1 << card)
                new_deck = state.deck ^ (1 << card)
                result.append(State(new_score, new_hand, new_deck))
            card += 1
            temp >>= 1
    else:
        # deal
        # the slow part BEGINS
        deck_list = binary_to_list(state.deck)
        replenishment = min(len(deck_list), 3)
        for combo in itertools.combinations(deck_list, replenishment):
            mask = list_to_binary(combo)
            new_hand = new_hand_partial | mask
            new_deck = state.deck ^ mask
            result.append(State(new_score, new_hand, new_deck))
        # the slow part ENDS
    return result

# ---------------- DP solution ----------------

cpdef double winning_probability(State state, storage) except -1.0:
    cdef int score_change, num_outcomes
    cdef double prob, total_prob, next_prob, average_prob
    if state.score >= 40:
        return 1.0
    elif not state.deck:
        score_change = score_change_cache[state.hand]
        prob = 1.0 if state.score + score_change >= 40 else 0.0

        # I am optimizing away unnecessary requests to disk.
        # if num_ones(state.hand) == 5:
        #     # The disk cache only contains entries for full hands.
        #     if storage.retrieve(state) is None:
        #         storage.store(state, prob)

        return prob
    else:
        sprob = storage.retrieve(state)
        if sprob is None:
            prob = 0.0
            for move in moves(state):
                total_prob = 0.0
                num_outcomes = 0
                for outcome in outcomes(state, move):
                    next_prob = winning_probability(outcome, storage)
                    total_prob += next_prob
                    num_outcomes += 1
                assert num_outcomes > 0
                average_prob = total_prob / num_outcomes
                prob = max(prob, average_prob)
            storage.store(state, prob)
        else:
            prob = sprob
        return prob

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

# ---------------- Cached stuff ----------------

hands5 = [list_to_binary(combo) for combo in itertools.combinations(range(24), 5)]
hands5_rev = {v : i for i, v in enumerate(hands5)}

hands4 = [list_to_binary(combo) for combo in itertools.combinations(range(24), 4)]
hands3 = [list_to_binary(combo) for combo in itertools.combinations(range(24), 3)]

hands5_factor = sorted(list({canonicalize(State(0, hand, 0)).hand for hand in hands5}))
hands5_factor_rev = {hand : i for i, hand in enumerate(hands5_factor)}

# (full hand as a bitmask) -> (list of Move objects)
moves_cache = {hand : moves_from_hand(hand) for hand in hands5}

score_change_cache = {hand: best_move_score(hand) for hand in itertools.chain(hands5, hands4, hands3)}