# cython: profile=True

import os, logging
import struct, mmap, io
import itertools
from collections import Counter

from gamecalc import compactify_deck, canonicalize, hands5_factor_rev
from utils import Location, Handle, load, dump

bytes_per_entry = 2
prob_format = '>H'
prob_max = 65534
usage_filename = 'usage.json'
usage_total_key = 'total'


class Storage(object):
    def __init__(self, states_dir):
        self.states_dir = states_dir
        self.storage_handles = {}

        self.usage_path = os.path.join(states_dir, usage_filename)
        if os.path.exists(self.usage_path):
            with open(self.usage_path, 'r') as f:
                self.storage_usage = Counter(load(f))
        else:
            self.storage_usage = Counter()

        logging.info("Current storage usage: %r" % self.storage_usage)

        self.path_cache = [
            os.path.join(self.states_dir, '%02d.dat' % score) for score in range(40)
        ]

        # In case the generator is aborted, I want to do at least something to preserve consistency.
        # When I/O is performed, this variable stores the current I/O action.
        # There are 2 types of actions available: writing values in existing files and creating new files.
        # 0 = writing value
        # 1 = creating file
        # I'm missing Haskell's algebraic data types.
        self.curr_action = None

        self.curr_value = None
        self.curr_offset = None
        self.curr_path = None

    def _get_path(self, state):
        return self.path_cache[state.score]

    def _get_offset(self, cstate):
        hand_offset = hands5_factor_rev[cstate.hand]
        deck_offset = compactify_deck(cstate.hand, cstate.deck)
        offset = hand_offset * (1 << 19) + deck_offset
        return offset

    def _reset_storage(self, loc):
        # assumes that the path exists but the file doesn't
        # http://stackoverflow.com/a/33436946/1214547

        fill = b'\xFF'
        file_size = loc.size * bytes_per_entry
        block_size = io.DEFAULT_BUFFER_SIZE
        assert file_size % block_size == 0

        logging.info("Creating a new table at %s for %d entries (%d bytes). Using block size of %d bytes." %
                     (loc.path, loc.size, file_size, block_size))

        fill_str = fill * block_size
        fill_iter = file_size // block_size

        self.curr_action = 1
        self.curr_path = loc.path

        with open(loc.path, 'wb') as f:
            f.writelines(itertools.repeat(fill_str, fill_iter))

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
        mmapobj = mmap.mmap(fileobj.fileno(), loc.size * bytes_per_entry)

        self.storage_handles[loc.path] = Handle(fileobj, mmapobj)

    def _get_location(self, state):
        cstate = canonicalize(state)
        path = self._get_path(cstate)
        offset = self._get_offset(cstate)
        # 7448 is the number of hands after factorization
        size = 7448 * 2**19
        return Location(path, offset, size)

    def store(self, state, prob):
        # assuming that prob is a floating-point number in 0..1
        prob_int = round(prob * prob_max)
        prob_bin = struct.pack(prob_format, prob_int)

        loc = self._get_location(state)

        # No values are supposed to be overwritten.
        prob_int = self.retrieve_direct_raw(loc)
        assert prob_int > prob_max  # means that the value is unused

        self._ensure_initialized(loc)

        byte_offset = loc.offset * bytes_per_entry

        self.curr_path = loc.path
        self.curr_value = prob_bin
        self.curr_offset = byte_offset
        # Now that everything is copied in the memory, we may flag that we're performing I/O.
        self.curr_action = 0

        # If the generator is interrupted somewhere within these lines, it will end up in an inconsistent
        # state. This is not serious, since the second line is only for monitoring progress, but
        # how to mitigate it anyway?
        self.storage_handles[loc.path].mmapobj[byte_offset:byte_offset+bytes_per_entry] = prob_bin
        self.storage_usage[loc.path] += 1  # Earlier we've checked that it is a new value.
        self.storage_usage[usage_total_key] += 1

        self.curr_action = None
        self.curr_path = None
        self.curr_value = None
        self.curr_offset = None

        if self.storage_usage[usage_total_key] % 1000000 == 0:
            logging.info("Currently using %d entries in the table" % self.storage_usage[usage_total_key])
            self.save_usage()

    def retrieve_direct_raw(self, loc):
        if loc.path not in self.storage_handles:
            if not os.path.exists(loc.path):
                return prob_max + 1
            else:
                self._ensure_initialized(loc)

        byte_offset = loc.offset * bytes_per_entry
        prob_bin = self.storage_handles[loc.path].mmapobj[byte_offset:byte_offset+bytes_per_entry]
        assert len(prob_bin) == 2

        return struct.unpack(prob_format, prob_bin)[0]

    def retrieve(self, state):
        loc = self._get_location(state)
        prob_int = self.retrieve_direct_raw(loc)
        if prob_int > prob_max:
            # 65535
            assert prob_int == prob_max + 1
            return None
        else:
            return prob_int / prob_max

    def save_usage(self):
        with open(self.usage_path, 'w') as f:
            dump(self.storage_usage, f)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.curr_action is not None:
            logging.warning("Generator was interrupted while doing I/O.")
            if self.curr_action == 1 and self.curr_path is not None and os.path.exists(self.curr_path):
                # The 2nd and 3rd checks are necessary because the exit could occur
                # after I set the flag `curr_action`, but before I set the other values or start I/O.
                logging.info("Removing a half-created table at %s." % self.curr_path)
                os.remove(self.curr_path)
            elif (self.curr_action == 0 and self.curr_path is not None and
                          self.curr_value is not None and self.curr_offset is not None):
                # Cleanup: write down that value
                logging.info("Flushing value %d at offset %d in %s." % (self.curr_value, self.curr_offset, self.curr_path))
                self.storage_handles[self.curr_path].mmapobj[self.curr_offset:self.curr_offset+bytes_per_entry] = self.curr_value
                # At this point, we don't know whether storage_usage was updated or not, but this is not very important.
        else:
            logging.info("Generator was interrupted.")

        for handle in self.storage_handles.values():
            handle.mmapobj.close()
            handle.fileobj.close()

        self.save_usage()
