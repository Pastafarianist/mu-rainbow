# cython: profile=True

import os, logging, warnings
import struct, mmap, platform
import datetime, csv
from collections import Counter

from sparsehash cimport SparseHashMap
from utils cimport compactify_deck, canonicalize, State, Location
from utils import hands5_factor_rev, hands5_factor, expand_deck, Handle, load, dump


total_scores = 40
bytes_per_entry = 2
prob_format = '>H'
prob_range = 65534
usage_filename = 'usage.json'
usage_total_key = 'total'
usage_memory_key = 'memory'

dense_ext = 'dat'
sparse_ext = 'shash'

config_filename = 'config.json'
history_filename = 'history.csv'

memory_usage_threshold = 701000000

history_report_period = 10000
small_report_period = 100000
large_report_period = 1000000
save_period = 50000000


def posix_fallocate(path, size):
    with open(path, 'wb') as f:
        os.posix_fallocate(f.fileno(), 0, size)

def win_fallocate(path, size):
    # I haven't tested this.
    with open(path, 'wb') as f:
        f.seek(size - 1)
        f.write(b'\x00')

def posix_fadvise_willneed(fileno):
    os.posix_fadvise(fileno, 0, 0, os.POSIX_FADV_WILLNEED)

def posix_fadvise_dontneed(fileno):
    os.posix_fadvise(fileno, 0, 0, os.POSIX_FADV_DONTNEED)

def win_fadvise_willneed(fileno):
    pass

def win_fadvise_dontneed(fileno):
    pass

if platform.system() == 'Linux':
    fallocate = posix_fallocate
    fadvise_willneed = posix_fadvise_willneed
    fadvise_dontneed = posix_fadvise_dontneed
elif platform.system() == 'Windows':
    logging.warning("Windows file interaction functions are untested.")
    fallocate = win_fallocate
    fadvise_willneed = win_fadvise_willneed
    fadvise_dontneed = win_fadvise_dontneed


cdef class Storage:
    cdef str usage_path, history_path, config_path, curr_path, last_path
    cdef list state_dirs, storage_path, memory_storage, history
    cdef bytes curr_value
    cdef dict storage_handles, config
    cdef object storage_usage
    cdef int curr_action
    cdef long curr_offset
    def __init__(self, state_dirs):
        if len(state_dirs) == 1:
            warnings.warn("It is inefficient to use only one storage drive. Add another one.")

        self.state_dirs = state_dirs
        self.storage_handles = {}

        self.usage_path = os.path.join(state_dirs[0], usage_filename)
        if os.path.exists(self.usage_path):
            with open(self.usage_path, 'r') as f:
                self.storage_usage = Counter(load(f))
        else:
            self.storage_usage = Counter()

        logging.info("Currently using %d entries in the table" % self.storage_usage[usage_total_key])
        self.report_breakdown()

        self.config_path = os.path.join(state_dirs[0], config_filename)
        if os.path.exists(self.config_path):
            with open(self.config_path, 'r') as f:
                self.config = load(f)
        else:
            self.config = {
                'in_memory': [True] * total_scores
            }

        self.storage_path = [
            os.path.join(self.state_dirs[score % len(state_dirs)],
                         '%02d.%s' % (score, sparse_ext if self.config['in_memory'][score] else dense_ext))
            for score in range(total_scores)
        ]

        self.history_path = os.path.join(state_dirs[0], history_filename)
        self.history = []
        self.register_history('startup')

        # In case the generator is aborted, I want to do at least something to preserve consistency.
        # When I/O is performed, this variable stores the current I/O action.
        # There are 2 types of actions available: writing values in existing files and creating new files.
        # -1 = nothing
        # 0 = writing value
        # 1 = creating file
        # 2 = transferring data from memory storage to disk
        # I'm missing Haskell's algebraic data types.
        self.curr_action = -1

        self.curr_value = None
        self.curr_offset = -1
        self.curr_path = None

        # Before accessing each file I call os.posix_fadvise to load the whole file in memory.
        # Since I don't want to do that every time I store or retrieve data, I save the last
        # accessed file and only call os.posix_fadvise when it changes.
        self.last_path = None

        # This is the storage for the data that resides in memory.
        self.memory_storage = [None] * total_scores

    cdef long _get_offset(self, State cstate) except -1:
        cdef long hand_offset, deck_offset, offset
        hand_offset = hands5_factor_rev[cstate.hand]
        deck_offset = compactify_deck(cstate.hand, cstate.deck)

        # Multiplication by 2**19. Note: without the parentheses
        # this is interpreted as `offset = hand_offset << (19 + deck_offset)`
        offset = (hand_offset << 19) + deck_offset

        return offset

    cdef _unpack_offset(self, offset):
        # bottom 19 bits: compactified deck
        # the rest: hands5_factor index
        hand_idx = offset >> 19
        compact_deck = offset & ((1 << 19) - 1)
        hand = hands5_factor[hand_idx]
        deck = expand_deck(hand, compact_deck)
        return hand, deck

    cdef int _state_is_in_memory(self, State cstate) except -1:
        return self.config['in_memory'][cstate.score]

    cdef int _do_prefetch(self, Location loc) except -1:
        # TODO: this is ugly, but is there a better way?
        return loc.path == self.storage_path[0]

    cdef _reset_storage(self, loc):
        # assumes that the path exists but the file doesn't

        file_size = loc.size * bytes_per_entry
        logging.info("Creating a new table at %s for %d entries (%d bytes)." % (loc.path, loc.size, file_size))

        self.curr_action = 1
        self.curr_path = loc.path

        fallocate(loc.path, file_size)

        self.curr_action = -1
        self.curr_path = None

        logging.info("Done.")

    cdef _ensure_usable(self, path):
        directory = os.path.dirname(path)
        if not os.path.exists(directory):
            os.makedirs(directory)
        elif not os.path.isdir(directory):
            raise RuntimeError("%s exists but is not a directory" % directory)

    cdef _ensure_initialized(self, Location loc):
        if loc.in_memory:
            if self.memory_storage[loc.idx] is None:
                self._ensure_usable(loc.path)

                if os.path.exists(loc.path):
                    logging.debug("Loading %s from disk to memory..." % loc.path)
                    # Loading from on-disk storage
                    with open(loc.path, 'rb') as f:
                        self.memory_storage[loc.idx] = SparseHashMap(f)
                    assert self.storage_usage[loc.path] == len(self.memory_storage[loc.idx])
                else:
                    self.memory_storage[loc.idx] = SparseHashMap()
        else:

            if loc.path not in self.storage_handles:
                self._ensure_usable(loc.path)

                if not os.path.exists(loc.path):
                    self._reset_storage(loc)

                assert loc.path not in self.storage_handles

                fileobj = open(loc.path, 'r+b')
                mmapobj = mmap.mmap(fileobj.fileno(), loc.size * bytes_per_entry)

                self.storage_handles[loc.path] = Handle(fileobj, mmapobj)

            if loc.path != self.last_path and self._do_prefetch(loc):
                # os.posix_fadvise tells the kernel to prefetch the whole file in memory.
                # API reference: https://docs.python.org/3/library/os.html#os.posix_fadvise
                # According to http://linux.die.net/man/2/posix_fadvise , len=0 (3rd argument)
                # indicates the intention to access the whole file.
                if self.last_path is not None:
                    logging.debug("Telling the kernel that %s will be used instead of %s..." % (loc.path, self.last_path))
                    fadvise_dontneed(self.storage_handles[self.last_path].fileobj.fileno())
                else:
                    logging.debug("Telling the kernel that %s will be used henceforth..." % loc.path)
                    # pass
                fadvise_willneed(self.storage_handles[loc.path].fileobj.fileno())
                self.last_path = loc.path

    cdef Location _get_location(self, State state):
        cdef State cstate
        cdef str path
        cdef long offset, size
        cdef int in_memory, idx
        cstate = canonicalize(state)
        idx = cstate.score
        path = self.storage_path[state.score]
        offset = self._get_offset(cstate)
        # 7448 is the number of hands after factorization
        size = 7448 * 2**19
        in_memory = self._state_is_in_memory(cstate)
        return Location(idx, path, offset, size, in_memory)

    cpdef store(self, state, prob):
        # assuming that prob is a floating-point number in 0..1
        prob_int = round(prob * prob_range) + 1
        assert 1 <= prob_int <= prob_range + 1

        loc = self._get_location(state)
        self._ensure_initialized(loc)

        if loc.in_memory:
            # By this moment, _ensure_initialized has already ensured that memory_storage[loc.idx] is not None.
            assert loc.offset not in self.memory_storage[loc.idx], (loc.path, loc.offset, prob)
            self.memory_storage[loc.idx][loc.offset] = prob_int

            # Cannot deduplicate this code because down below it is surrounded with a Ctrl+C protector.
            self.storage_usage[loc.path] += 1
            self.storage_usage[usage_total_key] += 1
            self.storage_usage[usage_memory_key] += 1

            # WARNING: The following assert is dangerous. It is NOT guaranteed with the current
            # implementation that it will never be triggered.
            assert len(self.memory_storage[loc.idx]) == self.storage_usage[loc.path]

            if self.storage_usage[usage_memory_key] >= memory_usage_threshold:
                # Need to dump some of the data onto disk and continue.
                # Cython fails to compile max(key=lambda ...), so
                heaviest_score = None
                max_score_usage = 0
                for score in range(total_scores):
                    if self.config['in_memory'][score] and self.storage_usage[self.storage_path[score]] > max_score_usage:
                        max_score_usage = self.storage_usage[self.storage_path[score]]
                        heaviest_score = score
                # TODO: the heaviest score has been calculated, but since I'm using lazy loading,
                # it may be not initialized. I have to call _ensure_initialized on the respective
                # storage. This hasn't blown up yet, but it may. I have an assert for that in
                # _transfer_memory_to_disk, so no data corruption will occur, only a crash.
                self._transfer_memory_to_disk(heaviest_score)
        else:

            # No values are supposed to be overwritten, but this assertion is expensive.
            # prob_int = self.retrieve_direct_raw(loc)
            # assert prob_int == 0  # means that the value is unused

            prob_bin = struct.pack(prob_format, prob_int)

            byte_offset = loc.offset * bytes_per_entry

            self.curr_path = loc.path
            self.curr_value = prob_bin
            self.curr_offset = byte_offset
            # Now that everything is copied in the memory, we may flag that we're performing I/O.
            self.curr_action = 0

            # If the generator is interrupted somewhere within these lines, it will end up in an inconsistent
            # state. This is not serious, since all lines but the first one are only for monitoring progress, but
            # how to mitigate it anyway?
            self.storage_handles[loc.path].mmapobj[byte_offset:byte_offset+bytes_per_entry] = prob_bin
            self.storage_usage[loc.path] += 1  # Values are never overwritten.
            self.storage_usage[usage_total_key] += 1

            self.curr_action = -1
            self.curr_path = None
            self.curr_value = None
            self.curr_offset = -1

        total_used = self.storage_usage[usage_total_key]

        # WARNING: this optimization uses the fact that currently all smaller periods divide larger periods.
        if total_used % history_report_period == 0:
            self.register_history()

            if total_used % small_report_period == 0:
                self.report_and_save_stats()

                if total_used % large_report_period == 0:
                    self.report_breakdown()

                    if total_used % save_period == 0:
                        self.save_memory_storage()

    cdef _transfer_memory_to_disk(self, score):
        logging.info("Transferring data for score %d from memory to disk..." % score)

        assert bool(self.memory_storage[score]), score

        logging.info("Saving a copy of the latest version of data in sparse format...")
        self._ensure_usable(self.storage_path[score])

        with open(self.storage_path[score], 'wb') as f:
            self.memory_storage[score].save(f)

        # _get_location will return different results based on this value.
        # TODO: this is pretty ugly state manipulation. Any way to get rid of it?
        self.config['in_memory'][score] = False
        # TODO: extract path manipulation?
        sparse_path = self.storage_path[score]
        dense_path = os.path.splitext(sparse_path)[0] + dense_ext
        self.storage_path[score] = dense_path

        logging.debug("Old path: %s" % sparse_path)
        logging.debug("New path: %s" % dense_path)

        # We want to call _ensure_initialized. Hence, we need some Location.
        offset = next(iter(self.memory_storage[score].keys()))
        some_hand, some_deck = self._unpack_offset(offset)
        some_state = State(score, some_hand, some_deck)

        # At this moment `loc` already has `in_memory == False` and loc.path points to *.dat
        loc = self._get_location(some_state)
        assert not loc.in_memory
        assert loc.path == dense_path

        self._ensure_initialized(loc)

        logging.info("Writing data in dense format...")

        self.curr_path = loc.path
        self.curr_offset = loc.idx  # because I don't want to introduce another variable
        self.curr_action = 2

        for offset in self.memory_storage[score].ordered_keys():
            prob_int = self.memory_storage[score][offset]
            # Basically, the following code is a lightweight store().
            # Offsets in the memory storage and on the disk are equal.
            # TODO: the following 3 lines are copy-pasted from store(). Maybe extract them?
            byte_offset = offset * bytes_per_entry
            prob_bin = struct.pack(prob_format, prob_int)
            self.storage_handles[dense_path].mmapobj[byte_offset:byte_offset+bytes_per_entry] = prob_bin

        was_using = self.storage_usage[sparse_path]
        assert was_using == len(self.memory_storage[score]), (was_using, len(self.memory_storage[score]))

        self.storage_usage[usage_memory_key] -= was_using
        self.storage_usage[dense_path] = was_using
        del self.storage_usage[sparse_path]
        self.memory_storage[score] = None

        self.curr_action = -1
        self.curr_path = None
        self.curr_offset = -1

        logging.info("Transfer completed.")

    cpdef int retrieve_direct_raw(self, Location loc) except -1:
        cdef SparseHashMap d
        cdef int prob_int
        if loc.in_memory:
            d = self.memory_storage[loc.idx]

            if d is None:
                if not os.path.exists(loc.path):
                    return 0
                else:
                    self._ensure_initialized(loc)
                    d = self.memory_storage[loc.idx]
            
            prob_int = d.get(loc.offset, 0)
        else:
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
        cdef Location loc = self._get_location(state)
        cdef int prob_int = self.retrieve_direct_raw(loc)
        # At this point, we're already confident that the value is in the correct range (0..prob_range+1)

        if prob_int == 0:
            return None
        else:
            return (prob_int - 1) / prob_range

    cdef save_memory_storage(self):
        logging.debug("Saving in-memory storage to disk...")
        for idx, blob in enumerate(self.memory_storage):
            if blob is None:
                continue
            path = self.storage_path[idx]
            self._ensure_usable(path)

            temp_path = path + '.tmp'

            with open(temp_path, 'wb') as f:
                blob.save(f)

            os.rename(temp_path, path)
        logging.debug("Done.")

    cdef register_history(self, flag='regular'):
        row = [datetime.datetime.now().isoformat(), str(self.storage_usage[usage_total_key])]
        row.extend(str(self.storage_usage[path]) for path in self.storage_path)
        row.append(flag)
        self.history.append(row)

    cdef report_and_save_stats(self):
        logging.info("Currently using %d entries in the table. %d are in memory."
                     % (self.storage_usage[usage_total_key], self.storage_usage[usage_memory_key]))

        with open(self.usage_path, 'w') as f:
            dump(self.storage_usage, f)

        with open(self.history_path, 'a') as f:
            csvwriter = csv.writer(f)
            csvwriter.writerows(self.history)
        self.history.clear()

    cdef report_breakdown(self):
        if self.storage_usage:
            special_keys = (usage_memory_key, usage_total_key)
            report = [(k, v) for (k, v) in self.storage_usage.items() if k not in special_keys]
            # Support for tuple unpacking from arguments was removed in Python 3.
            report.sort(key=lambda item: item[1], reverse=True)
            report.extend((key, self.storage_usage[key]) for key in special_keys)
            format_str = '    {:>%d}: {:>10}' % max(len(path) for path in self.storage_usage.keys())
            logging.info("Usage breakdown: \n%s" %
                         '\n'.join(format_str.format(key, value) for key, value in report))

    cdef save_config(self):
        with open(self.config_path, 'w') as f:
            dump(self.config, f)

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
            elif self.curr_action == 2 and self.curr_path is not None and os.path.exists(self.curr_path):
                logging.info("Removing a half-transferred table at %s." % self.curr_path)
                idx = self.curr_offset
                self.config['in_memory'][idx] = idx
                self.storage_path[idx] = os.path.splitext(self.storage_path[idx])[0] + sparse_ext
                # TODO: review this.
                self.storage_handles[self.curr_path].mmapobj.close()
                self.storage_handles[self.curr_path].fileobj.close()
                os.remove(self.curr_path)
                del self.storage_handles[self.curr_path]
        else:
            logging.info("Generator was interrupted.")

        logging.debug("Closing mmapped files...")
        for handle in self.storage_handles.values():
            handle.mmapobj.close()
            handle.fileobj.close()

        self.save_memory_storage()

        self.save_config()

        self.register_history('shutdown')
        self.report_and_save_stats()
        self.report_breakdown()

        # The following assert is dangerous. The code in its current state is not 100% proof against
        # triggering it. Hence, it would be unwise to move it higher.
        # Furthermore, if it crashes, it hides the traceback from above.

        #logging.debug("Final sanity check...")
        #for score in range(total_scores):
        #    expected = self.storage_usage[self.storage_path[score]]
        #    actual = len(self.memory_storage[score]) if self.memory_storage[score] is not None else 0
        #    assert actual == expected, (score, expected, actual)

        logging.debug("Exiting.")
