import os, time, logging
import struct, mmap
import itertools

from utils import *

logging.basicConfig(level=logging.DEBUG, format='[%(asctime)-15s] %(levelname)s: %(message)s')

data_dir = 'data'
states_dir = '/home/pastafarianist/mu_roomy_states'

factorization_filename = 'factorization.json'
factorization_path = os.path.join(data_dir, factorization_filename)

allocation_filename = 'allocation.json'
allocation_path = os.path.join(data_dir, allocation_filename)

bytes_per_entry = 2
prob_format = '>H'
prob_max = 65534

hands5 = [list_to_binary(combo) for combo in itertools.combinations(range(24), 5)]
hands5_rev = {v : i for i, v in enumerate(hands5)}

hands4 = [list_to_binary(combo) for combo in itertools.combinations(range(24), 4)]
hands3 = [list_to_binary(combo) for combo in itertools.combinations(range(24), 3)]


class Storage(object):
    def __init__(self, factorization_path, allocation_path):
        with open(factorization_path, 'r') as f:
            factorization = load(f)
            self.deck_offsets = []
            for factor, _ in factorization:
                l = [v for v in factor.values() if v is not None]
                assert len(l) == 1
                allowed_decks = l[0]
                offsets = [0]
                for b in allowed_decks:
                    offsets.append(offsets[-1] + b)
                self.deck_offsets.append(offsets)

        with open(allocation_path, 'r') as f:
            self.allocation = load(f)

        self.storage_handles = {}

        # In case the generator is aborted, I want to do at least something to preserve consistency.
        # When I/O is performed, this variable stores the current I/O action.
        # There are 2 types of actions available: writing values in existing files and creating new files.
        # 0 = writing value
        # 1 = creating file
        # God, I'm missing Haskell's algebraic data types.
        self.curr_action = None

        self.curr_value = None
        self.curr_offset = None
        self.curr_path = None

    @staticmethod
    def _get_directory(state):
        # return os.path.join(data_dir, '%02d' % state.score)
        return states_dir

    @staticmethod
    def _get_filename(state):
        return '%02d.dat' % state.score

    def _get_path(self, state):
        return os.path.join(self._get_directory(state), self._get_filename(state))

    def _get_offset(self, cstate):
        hand_idx = hands5_rev[cstate.hand]
        hand_offset, hand_type = self.allocation[hand_idx]
        deck_offset = self.deck_offsets[hand_type][compactify_deck(cstate.hand, cstate.deck)]
        return hand_offset + deck_offset

    def _reset_storage(self, loc):
        # assumes that the path exists but the file doesn't
        # TODO: any way to make it better?

        fill = b'\xFF'
        logging.info("Creating a new table at %s for %d entries (%d bytes). Initial value: %r." %
                     (loc.path, loc.size, loc.size * bytes_per_entry, fill))

        self.curr_action = 1
        self.curr_path = loc.path

        with open(loc.path, 'wb') as f:
            # size in bytes
            for _ in range(loc.size * bytes_per_entry):
                f.write(fill)

        self.curr_action = None
        self.curr_path = None

        logging.info("Done.")

    def _ensure_initialized(self, loc):
        if loc.path in self.storage_handles:
            return

        directory = os.path.dirname(loc.path)

        if not os.path.exists(directory):
            os.makedirs(directory)
        elif not os.path.isdir(directory):
            raise RuntimeError("%s exists but is not a directory" % directory)

        if not os.path.exists(loc.path):
            self._reset_storage(loc)

        assert loc.path not in self.storage_handles

        fileobj = open(loc.path, 'r+b')
        mmapobj = mmap.mmap(fileobj.fileno(), loc.size)

        self.storage_handles[loc.path] = Handle(fileobj, mmapobj)

    def _get_location(self, state):
        cstate = canonicalize(state)
        path = self._get_path(cstate)
        offset = self._get_offset(cstate)
        size = 3715948544  # calculated in scratchpad.py
        return Location(path, offset, size)

    def store(self, state, prob):
        # assuming that prob is a floating-point number in 0..1
        prob_int = round(prob * prob_max)
        prob_bin = struct.pack(prob_format, prob_int)

        loc = self._get_location(state)
        self._ensure_initialized(loc)

        byte_offset = loc.offset * bytes_per_entry

        self.curr_action = 0
        self.curr_path = loc.path
        self.curr_value = prob_bin
        self.curr_offset = byte_offset

        self.storage_handles[loc.path].mmapobj[byte_offset:byte_offset+bytes_per_entry] = prob_bin

        self.curr_path = None
        self.curr_action = None
        self.curr_value = None
        self.curr_offset = None

    def retrieve(self, state):
        loc = self._get_location(state)

        if not os.path.exists(loc.path):
            return None

        self._ensure_initialized(loc)
        byte_offset = loc.offset * bytes_per_entry
        prob_bin = self.storage_handles[loc.path].mmapobj[byte_offset:byte_offset+bytes_per_entry]

        prob_int = struct.unpack(prob_format, prob_bin)[0]
        if prob_int > prob_max:
            # 65535
            return None
        else:
            return prob_int / prob_max

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.curr_action is not None:
            logging.warning("Generator was interrupted while doing I/O.")
            if self.curr_action == 0 and self.curr_path is not None and os.path.exists(self.curr_path):
                # The 2nd and 3rd checks are necessary because the exit could occur
                # after I set the flag `curr_action`, but before I set the other values or start I/O.
                # Cleanup: remove half-created file.
                os.remove(self.curr_path)
            elif (self.curr_action == 1 and self.curr_path is not None and
                          self.curr_value is not None and self.curr_offset is not None):
                # Cleanup: write down that value
                self.storage_handles[self.curr_path].mmapobj[self.curr_offset:self.curr_offset+bytes_per_entry] = self.curr_value

        for handle in self.storage_handles.values():
            handle.mmapobj.close()
            handle.fileobj.close()


# (full hand as a bitmask) -> (list of Move objects)
moves_cache = {hand : moves_from_hand(hand) for hand in hands5}
def moves(state):
    assert state.deck
    return moves_cache[state.hand]

def outcomes(state, move):
    assert state.deck
    assert state.hand & move.param == move.param
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
        # retrieve data from the cache, I still store it there.
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

def main():
    with Storage(factorization_path, allocation_path) as storage:
        for i, hand in enumerate(hands5):
            for compact_deck in range(2**19):
                deck = expand_deck(hand, compact_deck)
                state = State(39, hand, deck)
                winning_probability(state, storage)
            logging.info("%d/%d hands processed." % (i + 1, len(hands5)))

if __name__ == '__main__':
    main()
