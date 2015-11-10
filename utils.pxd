cdef class State:
    cdef readonly int score, hand, deck

cdef class Location:
    cdef readonly str path
    cdef readonly long offset, size

cdef int compactify_deck(int hand, int deck) except -1
cdef State canonicalize(State state)
