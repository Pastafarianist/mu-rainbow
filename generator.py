import logging
logging.basicConfig(level=logging.DEBUG, format='[%(asctime)-15s] %(module)s %(levelname)s: %(message)s')

import pyximport
pyximport.install()

from diskstorage import Storage
from utils import State, hands5, expand_deck, winning_probability


state_dirs = ['/home/pastafarianist/mu_roomy_states', '/home/pastafarianist/temp/pastafarianist/mu_roomy_states/']


def main():
    logging.info("Starting.")
    with Storage(state_dirs) as storage:
        for i, hand in enumerate(hands5):
            compact_deck = (1 << 19) - 1
            deck = expand_deck(hand, compact_deck)
            state = State(0, hand, deck)
            winning_probability(state, storage)
            logging.info("%d/%d hands processed." % (i + 1, len(hands5)))

if __name__ == '__main__':
    main()
