import itertools
from utils import (
    State, Move,
    cardset_to_str, binary_to_list, list_to_binary, num_ones
)

# meanings of card numbers:
# 0-7 = red cards 1-8
# 8-15 = blue cards 1-8
# 16-24 = yellow cards 1-8

hands5 = [list_to_binary(combo) for combo in itertools.combinations(range(24), 5)]
hands5_rev = {v : i for i, v in enumerate(hands5)}

hands4 = [list_to_binary(combo) for combo in itertools.combinations(range(24), 4)]
hands3 = [list_to_binary(combo) for combo in itertools.combinations(range(24), 3)]

cpdef int expand_deck(int hand, int deck):
    cdef int res = 0
    cdef int i = 0
    while deck:
        if not (hand & 1):
            res |= ((deck & 1) << i)
            deck >>= 1
        hand >>= 1
        i += 1
    return res

cpdef int compactify_deck(int hand, int deck):
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

cdef int[3] masks = ((1 << 8) - 1, ((1 << 8) - 1) << 8, ((1 << 8) - 1) << 16)

cpdef int apply_permutation(int num, int p1, int p2, int p3):
    return (
        ((num & masks[p1]) >> (p1 * 8)) |
        (((num & masks[p2]) >> (p2 * 8)) << 8) |
        (((num & masks[p3]) >> (p3 * 8)) << 16)
    )

cdef int[5][3] permutations = [
    (0, 2, 1),
    (1, 0, 2),
    (1, 2, 0),
    (2, 0, 1),
    (2, 1, 0)
]

def equiv_class(state):
    yield (state.hand, state.deck)
    for p1, p2, p3 in permutations:
        yield (apply_permutation(state.hand, p1, p2, p3), apply_permutation(state.deck, p1, p2, p3))

cpdef canonicalize(state):
    cdef int chand = state.hand
    cdef int cdeck = state.deck
    cdef int nhand, ndeck, p1, p2, p3
    for p1, p2, p3 in permutations:
        nhand = apply_permutation(state.hand, p1, p2, p3)
        ndeck = apply_permutation(state.deck, p1, p2, p3)
        chand, cdeck = min((chand, cdeck), (nhand, ndeck))
    return State(state.score, chand, cdeck)

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

# (full hand as a bitmask) -> (list of Move objects)
moves_cache = {hand : moves_from_hand(hand) for hand in hands5}
def moves(state):
    assert state.deck
    return moves_cache[state.hand]

def outcomes(state, move):
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

score_change_cache = {hand: best_move_score(hand) for hand in itertools.chain(hands5, hands4, hands3)}
def winning_probability(state, storage):
    if state.score >= 40:
        return 1.0
    elif not state.deck:
        # Here loading from disk cache will probably be slower than a direct calculation.
        # Nevertheless, I want to abstain from hacky optimizations, so while I don't
        # use the data I retrieve from the cache, I still store it there.
        if state.score < 30:
            prob = 0.0
        else:
            score_change = score_change_cache[state.hand]
            prob = 1.0 if state.score + score_change >= 40 else 0.0

        if num_ones(state.hand) == 5:
            # The disk cache only contains entries for full hands.
            if storage.retrieve(state) is None:
                storage.store(state, prob)

        return prob
    else:
        prob = storage.retrieve(state)
        if prob is None:
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
        return prob