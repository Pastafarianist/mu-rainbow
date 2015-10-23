import random
import itertools
from collections import defaultdict, Counter, namedtuple
from utils import score_combination, moves, outcomes, combinations_cache


call_counter = Counter()

def solve_game(hand, deck, score, depth=2):
    whatever = ('any', None)

    def solve_game_internal(hand, deck, score, depth):
        call_counter[depth] += 1
        if call_counter[0] % 1000000 == 0:
            print(call_counter)
        

        if score >= 400:
            return (1, whatever)
        elif ((len(hand) <= 2 and score < 400) or 
                (len(hand) + len(deck) < 15 and score == 0)):
            return (-1, whatever)
        elif depth == 0:
            # guessing
            extra_scores = [score for score, combo in combinations_cache[tuple(hand)]]
            extra = max(extra_scores) if extra_scores else 0
            guess = ((score + extra) / 400) * 2 - 1
            return (guess, whatever)
        else:
            m = list(moves(hand, bool(deck)))
            if not m:
                # nothing to do, nowhere to go
                return (-1, whatever)

            best_weight = -1
            best_move = whatever
            for action, parameter, score_change in m:
                sum_weight, num_outcomes = 0, 0
                for new_hand, new_deck, new_score in outcomes(hand, deck, score, action, parameter, score_change):
                    weight, _ = solve_game_internal(new_hand, new_deck, new_score, depth - 1)
                    sum_weight += weight
                    num_outcomes += 1
                average_weight = sum_weight / num_outcomes
                if average_weight > best_weight:
                    best_weight = average_weight
                    best_move = (action, parameter)
            return best_weight, best_move

    return solve_game_internal(hand, deck, score, depth)[1]

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

def num_ones(n):
    res = 0
    while n:
        if n & 1:
            res += 1
        n >>= 1
    return res

State = namedtuple("State", "score hand deck")
Move = namedtuple("Move", "action param score_change")

# These are always constant
binom5_to_binary = [list_to_binary(combo) for combo in itertools.combinations(range(24), 5)]
binom4_to_binary = [list_to_binary(combo) for combo in itertools.combinations(range(24), 4)]
binom3_to_binary = [list_to_binary(combo) for combo in itertools.combinations(range(24), 3)]

binary_to_binom = {val : i for i, val in enumerate(binom5_to_binary)}
binary_to_binom.update({val : i for i, val in enumerate(binom4_to_binary, len(binom5_to_binary))})
binary_to_binom.update({val : i for i, val in enumerate(binom3_to_binary, len(binom5_to_binary) + len(binom4_to_binary))})

def hand_binary_to_score_change(hand_binary):
    hand_tuple = tuple(binary_to_list(hand_binary))
    combos = combinations_cache[hand_tuple]
    if combos:
        return max(score for score, combo in combos) // 10
    else:
        return 0

dp5 = [hand_binary_to_score_change(binary) for binary in binom5_to_binary] # hand5 -> score_change
dp4 = [hand_binary_to_score_change(binary) for binary in binom4_to_binary] # hand4 -> score_change
dp3 = [hand_binary_to_score_change(binary) for binary in binom3_to_binary] # hand3 -> score_change

def hand_binary_to_list_of_moves(hand_binary):
    hand_tuple = tuple(binary_to_list(hand_binary))
    res = [Move(0, 1 << card, 0) for card in hand_tuple]
    res.extend(Move(1, list_to_binary(combo), score) for score, combo in combinations_cache[hand_tuple])
    return res

moves_cache = [hand_binary_to_list_of_moves(hand_binary) for hand_binary in binom5_to_binary]

def solve_game_dp(hand, deck, score):

    whatever = Move(2, None, 0)

    dp = {sc : defaultdict(dict) for sc in range(score, 40)}

    def moves_dp(hand):
        assert hand < len(moves_cache), '%d, %d, ' % (hand, len(moves_cache), )
        return moves_cache[hand]

    def outcomes_dp(state, move):
        assert state.deck
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

    def get(state):
        if 39 in dp:
            cache_size = len(dp[39])
            if cache_size % 10000 == 0 and cache_size > 0:
                print([len(d) for d in dp.values()])

        score, hand, deck = state
        hand_binom = binary_to_binom[hand]
        if score >= 40:
            return 1.0, whatever
        elif not deck:
            if score < 30:
                return 0.0, whatever
            else:
                if hand_binom < len(binom5_to_binary):
                    score_change = dp5[hand_binom]
                else:
                    hand_binom -= len(binom5_to_binary)
                    if hand_binom < len(binom4_to_binary):
                        score_change = dp4[hand_binom]
                    else:
                        hand_binom -= len(binom4_to_binary)
                        score_change = dp3[hand_binom]
                return (1.0 if score + score_change >= 40 else 0.0), whatever
        elif hand_binom in dp[state.score] and state.deck in dp[state.score][hand_binom]:
            return dp[state.score][hand_binom][state.deck], whatever
        else:
            # assert state.hand < len(binom5_to_binary), '%d %r' % (state.hand - len(binom5_to_binary), binary_to_list(deck))
            best_move = whatever
            best_weight = 0.0
            for move in moves_dp(hand_binom):
                total_weight = 0.0
                num_outcomes = 0
                for outcome in outcomes_dp(state, move):
                    weight, _ = get(outcome)
                    total_weight += weight
                    num_outcomes += 1
                assert num_outcomes > 0
                average_weight = total_weight / num_outcomes
                if average_weight > best_weight:
                    best_weight = average_weight
                    best_move = move
            dp[state.score][hand_binom][state.deck] = best_weight
            return best_weight, best_move

    weight, move = get(State(score, list_to_binary(hand), list_to_binary(deck)))
    action = ['remove', 'deal', 'any'][move.action]
    param = tuple(binary_to_list(move.param))
    if action == 'remove':
        param = param[0]

    return action, param

def simulate_game(algo, hand=None, deck=None):
    if hand is None and deck is None:
        cards = list(range(24))
        random.shuffle(cards)
        hand, deck = sorted(cards[:5]), cards[5:]
    assert hand is not None and deck is not None
    score = 0
    while len(hand) >= 3:
        print("New turn. Hand: %r, deck: %r, score: %d." % (hand, deck, score))
        action, parameter = algo(hand, deck, score)
        if action == 'remove':
            print(" Removing card %d from hand." % parameter)
            del hand[hand.index(parameter)]
            if deck:
                hand.append(deck[0])
                deck = deck[1:]
            hand.sort()
            # no score change
        elif action == 'deal':
            score_change = score_combination(parameter)
            print(" Dealing combination %r for %d points." % (parameter, score_change))
            for card in parameter:
                del hand[hand.index(card)]
            if len(deck) >= 3:
                hand.extend(deck[:3])
                deck = deck[3:]
            else:
                hand.extend(deck)
                deck = []
            hand.sort()
            score += score_change
        else:
            assert action == 'any'
            print(" The algorithm says all moves are equal.")
            if deck:
                print(" WARNING: this may be a bug.")
            # done
            return score
    return score

# results_counter = Counter()
# for i in range(100):
#     print("{0} Iteration {1} {0}".format('#' * 32, i + 1))
#     results_counter[simulate_game(solve_game_dp)] += 1
#     print(results_counter.most_common())

simulate_game(solve_game_dp, hand=[2, 7, 11, 15, 19], deck=[18, 23, 20, 16, 9, 4, 3, 17, 21])

# nums = random.sample(range(24), 12)
# hand = sorted(nums[:5])
# deck = sorted(nums[5:])

# print([pretty_name(card) for card in hand])
# print([pretty_name(card) for card in deck])
# print(solve_game(hand, deck, 230, 5))

# cnt = Counter()
# for hand, mv in combinations_cache.items():
#     cnt[len(mv)] += 1
# print(cnt)
# print(sum(k * v for k, v in cnt.items()) / sum(v for v in cnt.values()))

# for score, cards in card_combinations(hand):
#     print(score, [pretty_name(card) for card in cards])