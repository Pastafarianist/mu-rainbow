import unittest, time, logging
from collections import Counter

import generator as gen
from utils import moves_from_hand

logging.basicConfig(level=logging.DEBUG, format='[%(asctime)-15s] %(module)s %(levelname)s: %(message)s')

# used = set()
# for hand in gen.hands5:
#     state = gen.State(0, hand, 0)
#     cstate = canonicalize(state)
#     used.add(cstate.hand)
# hands5_factor = sorted(used)
# hands5_factor_rev = {hand : i for i, hand in enumerate(hands5_factor)}

class TestFactorization(unittest.TestCase):
    def _test_density_of_allocation(self):
        sz = 7448 * (2**19)

        logging.info("Allocating an array of length %d" % sz)
        # http://stackoverflow.com/a/33509499/1214547
        # I tried several options to do this. While Numpy can allocate the memory instantly,
        # it is almost twice as slow as bytearray later. array.array is a close second to
        # bytearray. Other options:
        # 
        # used = array.array('B', [0]) * sz
        # used = np.zeros(sz, dtype=np.uint8)
        # 
        used = bytearray(sz)
        logging.info("Done.")

        # storage = gen.Storage(gen.factorization_path, gen.allocation_path, gen.states_dir)

        time_start = time.time()

        for i, hand in enumerate(gen.hands5):
            for compact_deck in range(2**19):
                deck = gen.expand_deck(hand, compact_deck)
                state = gen.State(0, hand, deck)
                cstate = canonicalize(state)
                # offset = storage._get_offset(cstate)
                offset = hands5_factor_rev[cstate.hand] * (2**19) + compactify_deck(cstate.hand, cstate.deck)

                used[offset] += 1

                self.assertLessEqual(used[offset], 6, "Current state: %r, cstate: %r, offset: %d" % (state, cstate, offset))

            elapsed = time.time() - time_start
            average = elapsed / (i + 1)
            remaining_hands = len(gen.hands5) - (i + 1)
            if remaining_hands:
                logging.info("Done %d / %d hands in %.2f seconds (%.2f minutes), %.2f sec/hand. %.2f seconds (%.2f minutes) remaining." % 
                    (i + 1, len(gen.hands5), elapsed, elapsed / 60, average, average * remaining_hands, average * remaining_hands / 60))

        logging.info("Done. Calculating statistics...")

        cnt = Counter(used)
        logging.info("Distribution of frequencies: %r" % (cnt, ))
        self.assertEqual(len(cnt), 3)
        self.assertIn(0, cnt)
        self.assertIn(3, cnt)
        self.assertIn(6, cnt)


class TestScores(unittest.TestCase):
    def test_scores(self):
        hand = 0b11111
        print([(move.action, move.param, move.score_change) for move in moves_from_hand(hand)])


if __name__ == '__main__':
    unittest.main()