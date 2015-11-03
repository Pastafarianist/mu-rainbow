import unittest, time
import itertools, array
from collections import Counter

import generator as gen
from gamecalc import canonicalize

class TestFactorization(unittest.TestCase):
    def test_density_of_allocation(self):
        sz = 3715948544
        used = array.array('b', itertools.repeat(0, sz))

        storage = gen.Storage(gen.factorization_path, gen.allocation_path)

        time_start = time.time()

        for i, hand in enumerate(gen.hands5):
            for compact_deck in range(2**19):
                deck = gen.expand_deck(hand, compact_deck)
                state = gen.State(0, hand, deck)
                cstate = canonicalize(state)
                offset = storage._get_offset(cstate)

                used[offset] += 1

            elapsed = time.time() - time_start
            average = elapsed / (i + 1)
            remaining_hands = len(gen.hands5) - (i + 1)
            if remaining_hands:
                print("Done %d / %d hands in %.2f seconds (%.2f minutes), %.2f sec/hand. %.2f seconds (%.2f minutes) remaining." % 
                    (i + 1, len(gen.hands5), elapsed, elapsed / 60, average, average * remaining_hands, average * remaining_hands / 60))
            if i == 6:
                break

        cnt = Counter(used)
        print(cnt)
        self.assertTrue(len(cnt) == 2)
        self.assertTrue(3 in cnt)
        self.assertTrue(6 in cnt)


if __name__ == '__main__':
    unittest.main()