# cython: profile=True

import os, logging
import struct, mmap, io
import itertools
from collections import Counter

from utils cimport compactify_deck, canonicalize, State, Location
from utils import hands5_factor_rev, Handle, load, dump

bytes_per_entry = 2
prob_format = '>H'
prob_range = 65534
usage_filename = 'usage.json'
usage_total_key = 'total'
report_period = 100000

cdef class Storage:
    cdef str states_dir, usage_path, curr_path, last_path
    cdef list path_cache
    cdef bytes curr_value
    cdef dict storage_handles
    cdef object storage_usage
    cdef int curr_action
    cdef long curr_offset
    def __init__(self, states_dir):
        self.states_dir = states_dir
        self.storage_handles = {}

        self.usage_path = os.path.join(states_dir, usage_filename)
        if os.path.exists(self.usage_path):
            with open(self.usage_path, 'r') as f:
                self.storage_usage = Counter(load(f))
        else:
            self.storage_usage = Counter()

        logging.info("Currently using %d entries in the table" % self.storage_usage[usage_total_key])
        self.report_breakdown()

        self.path_cache = [
            os.path.join(self.states_dir, '%02d.dat' % score) for score in range(40)
        ]

        # In case the generator is aborted, I want to do at least something to preserve consistency.
        # When I/O is performed, this variable stores the current I/O action.
        # There are 2 types of actions available: writing values in existing files and creating new files.
        # -1 = nothing
        # 0 = writing value
        # 1 = creating file
        # I'm missing Haskell's algebraic data types.
        self.curr_action = -1

        self.curr_value = None
        self.curr_offset = -1
        self.curr_path = None

        # Before accessing each file I call os.posix_fadvise to load the whole file in memory.
        # Since I don't want to do that every time I store or retrieve data, I save the last
        # accessed file and only call os.posix_fadvise when it changes.
        self.last_path = None

    cdef _get_path(self, State state):
        return self.path_cache[state.score]

    cdef long _get_offset(self, State cstate) except -1:
        cdef long hand_offset, deck_offset, offset
        hand_offset = hands5_factor_rev[cstate.hand]
        deck_offset = compactify_deck(cstate.hand, cstate.deck)

        # Multiplication by 2**19. Note: without the parentheses
        # this is interpreted as `offset = hand_offset << (19 + deck_offset)`
        offset = (hand_offset << 19) + deck_offset

        return offset

    cdef _reset_storage(self, loc):
        # assumes that the path exists but the file doesn't

        file_size = loc.size * bytes_per_entry
        logging.info("Creating a new table at %s for %d entries (%d bytes)." % (loc.path, loc.size, file_size))

        self.curr_action = 1
        self.curr_path = loc.path

        with open(loc.path, 'wb') as f:
            os.posix_fallocate(f.fileno(), 0, file_size)

        self.curr_action = -1
        self.curr_path = None

        logging.info("Done.")

    cdef _ensure_initialized(self, loc):
        if loc.path not in self.storage_handles:
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

        if loc.path != self.last_path:
            # os.posix_fadvise tells the kernel to prefetch the whole file in memory.
            # API reference: https://docs.python.org/3/library/os.html#os.posix_fadvise
            # According to http://linux.die.net/man/2/posix_fadvise , len=0 (3rd argument)
            # indicates the intention to access the whole file.
            if self.last_path is not None:
                # logging.debug("Telling the kernel that %s will be used instead of %s..." % (loc.path, self.last_path))
                os.posix_fadvise(self.storage_handles[self.last_path].fileobj.fileno(),
                                 0, 0, os.POSIX_FADV_DONTNEED)
            else:
                # logging.debug("Telling the kernel that %s will be used henceforth..." % loc.path)
                pass
            os.posix_fadvise(self.storage_handles[loc.path].fileobj.fileno(),
                             0, 0, os.POSIX_FADV_WILLNEED)
            self.last_path = loc.path

    cdef Location _get_location(self, State state):
        cdef State cstate
        cdef str path
        cdef long offset
        cdef long size
        cstate = canonicalize(state)
        path = self._get_path(cstate)
        offset = self._get_offset(cstate)
        # 7448 is the number of hands after factorization
        size = 7448 * 2**19
        return Location(path, offset, size)

    cpdef store(self, state, prob):
        # assuming that prob is a floating-point number in 0..1
        prob_int = round(prob * prob_range) + 1
        assert 1 <= prob_int <= prob_range + 1

        prob_bin = struct.pack(prob_format, prob_int)

        loc = self._get_location(state)

        # No values are supposed to be overwritten, but this assertion is expensive.
        # prob_int = self.retrieve_direct_raw(loc)
        # assert prob_int == 0  # means that the value is unused

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
        self.storage_usage[loc.path] += 1  # Values are never overwritten.
        self.storage_usage[usage_total_key] += 1

        self.curr_action = -1
        self.curr_path = None
        self.curr_value = None
        self.curr_offset = -1

        if self.storage_usage[usage_total_key] % report_period == 0:
            self.report_and_save_usage()

    cpdef retrieve_direct_raw(self, loc):
        if loc.path not in self.storage_handles:
            if not os.path.exists(loc.path):
                return 0
            else:
                self._ensure_initialized(loc)

        byte_offset = loc.offset * bytes_per_entry
        prob_bin = self.storage_handles[loc.path].mmapobj[byte_offset:byte_offset+bytes_per_entry]
        assert len(prob_bin) == 2

        prob_int = struct.unpack(prob_format, prob_bin)[0]
        assert 0 <= prob_int <= prob_range + 1

        return prob_int

    cpdef retrieve(self, state):
        loc = self._get_location(state)
        prob_int = self.retrieve_direct_raw(loc)
        # At this point, we're already confident that the value is in the correct range (0..prob_range+1)

        if prob_int == 0:
            return None
        else:
            return (prob_int - 1) / prob_range

    cdef report_and_save_usage(self):
        logging.info("Currently using %d entries in the table" % self.storage_usage[usage_total_key])
        with open(self.usage_path, 'w') as f:
            dump(self.storage_usage, f)

    cdef report_breakdown(self):
        logging.info("Usage breakdown: \n%s" %
                     '\n'.join('    %s: %d' % (key, value)
                               for key, value in sorted(self.storage_usage.items())))

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if self.curr_action != -1:
            logging.warning("Generator was interrupted while doing I/O.")
            if (self.curr_action == 0 and self.curr_path is not None and
                          self.curr_value is not None and self.curr_offset != -1):
                # Cleanup: write down that value
                logging.info("Flushing value %d at offset %d in %s." % (self.curr_value, self.curr_offset, self.curr_path))
                self.storage_handles[self.curr_path].mmapobj[self.curr_offset:self.curr_offset+bytes_per_entry] = self.curr_value
                # At this point, we don't know whether storage_usage was updated or not, but this is not very important.
            elif self.curr_action == 1 and self.curr_path is not None and os.path.exists(self.curr_path):
                # The 2nd and 3rd checks are necessary because the exit could occur
                # after I set the flag `curr_action`, but before I set the other values or start I/O.
                logging.info("Removing a half-created table at %s." % self.curr_path)
                os.remove(self.curr_path)
        else:
            logging.info("Generator was interrupted.")

        for handle in self.storage_handles.values():
            handle.mmapobj.close()
            handle.fileobj.close()

        self.report_and_save_usage()
        self.report_breakdown()
