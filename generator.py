import logging
logging.basicConfig(level=logging.DEBUG, format='[%(asctime)-15s] %(module)s %(levelname)s: %(message)s')

import pyximport
pyximport.install()

import os

from diskstorage import Storage
from gamecalc import hands5, expand_deck, winning_probability
from utils import State


data_dir = 'data'
states_dir = '/home/pastafarianist/mu_roomy_states'

factorization_filename = 'factorization.json'
factorization_path = os.path.join(data_dir, factorization_filename)

allocation_filename = 'allocation.json'
allocation_path = os.path.join(data_dir, allocation_filename)


def main():
    logging.info("Starting.")
    with Storage(factorization_path, allocation_path, states_dir) as storage:
        for i, hand in enumerate(hands5):
            for compact_deck in range(2**19):
                deck = expand_deck(hand, compact_deck)
                state = State(39, hand, deck)
                winning_probability(state, storage)
            logging.info("%d/%d hands processed." % (i + 1, len(hands5)))

if __name__ == '__main__':
    main()
