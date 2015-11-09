import logging
logging.basicConfig(level=logging.DEBUG, format='[%(asctime)-15s] %(module)s %(levelname)s: %(message)s')

import pyximport
pyximport.install()

from diskstorage import Storage
from gamecalc import State, hands5, expand_deck, winning_probability


states_dir = '/home/pastafarianist/mu_roomy_states'


def main():
    logging.info("Starting.")
    with Storage(states_dir) as storage:
        for i, hand in enumerate(hands5):
            for compact_deck in range(2**19):
                deck = expand_deck(hand, compact_deck)
                state = State(39, hand, deck)
                winning_probability(state, storage)
            logging.info("%d/%d hands processed." % (i + 1, len(hands5)))

if __name__ == '__main__':
    main()
