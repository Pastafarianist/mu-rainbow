import unittest, logging

import pyximport
pyximport.install()

from utils import moves_cache, score_change_cache

logging.basicConfig(level=logging.DEBUG, format='[%(asctime)-15s] %(module)s %(levelname)s: %(message)s')


class TestScores(unittest.TestCase):
    def test_scores(self):
        for hand, moves in moves_cache.items():
            self.assertTrue(all(move.param & hand == move.param for move in moves))

            moves_remove = [move for move in moves if move.action == 0]
            moves_deal = [move for move in moves if move.action == 1]

            self.assertTrue(all(move.score_change == 0 for move in moves_remove))
            self.assertTrue(all(1 <= move.score_change <= 10 for move in moves_deal))

    def test_score_changes(self):
        for hand, score_change in score_change_cache.items():
            self.assertLessEqual(score_change, 10)
            self.assertGreaterEqual(score_change, 0)


if __name__ == '__main__':
    unittest.main()