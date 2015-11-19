cdef class State:
    cdef readonly int score, hand, deck

cdef class Location:
    cdef readonly str path
    cdef readonly long offset, extra
    cdef readonly int in_memory  # this is actually a bool, but Cython does not recognize that as a type

cdef int compactify_deck(int hand, int deck) except -1
cdef State canonicalize(State state)
