import unittest, time, random
from collections import defaultdict
import generator as gen
from utils import *


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

def are_valid_values(hand_values):
    for v in range(8):
        if hand_values.count(v) > 3:
            return False
    return True

class TestFactorization(unittest.TestCase):
    def run_for_values(self, hand_values):
        num_states = 0
        used = set()
        mapping = defaultdict(list)
        for colors_i in range(int('100000', 3)):
            colors = [int(v) for v in to_base(colors_i, 3, zfill=5)]

            hand = 0
            for v, c in zip(hand_values, colors):
                hand |= (1 << (v + c * 8))

            if num_ones(hand) != 5:
                continue

            if hand in used:
                continue
            else:
                used.add(hand)

            print("With colors: %r hand %r becomes: %s" % (colors, hand_values, cardset_to_str(hand)))

            for compact_deck in range(1 << 19):
                deck = gen.expand_deck(hand, compact_deck)
                self.assertFalse(hand & deck)
                state = gen.State(0, hand, deck)
                num_states += 1
                cstate = gen.canonicalize(state)
                mapping[(cstate.hand, cstate.deck)].append((hand, deck))

        return mapping, num_states

    def test_all(self):
        done = set()
        total = int('100000', 8)
        for hand_v in range(total):
            hand_values = tuple(sorted(int(v) for v in to_base(hand_v, 8, zfill=5)))
            assert len(hand_values) == 5, hand_values

            if hand_v % 10 == 0 and hand_v > 0:
                elapsed = time.time() - time_start
                speed = elapsed / i
                remaining = (total - hands_v) / (speed * 60)
                print('%d/%d hands processed in %.1fs. Current: %r. %.2f s/hand. %.1f minutes remaining.' % 
                    (hand_v, total, elapsed, hand_values, speed, remaining))

            if hand_values in done:
                continue
            else:
                done.add(hand_values)

            if not are_valid_values(hand_values):
                continue

            print("Processing hand values: %r" % (hand_values, ))

            mapping, num_states = self.run_for_values(hand_values)

            import pickle
            with open("/home/pastafarianist/mu_roomy_data/mapping.pickle", 'wb') as f:
                pickle.dump(mapping, f)

            error = "Hand values: %r, num_states: %d" % (hand_values, num_states)
            random_cstate, random_states = next(iter(mapping.items()))
            # print("Example mapping: %s -> %r" %
            #       (state_to_str(random_cstate), [state_to_str(state) for state in random_states]))
            self.assertEqual(len(mapping), num_states // 6, error)


if __name__ == '__main__':
    unittest.main()
