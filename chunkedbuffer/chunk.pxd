from .pool cimport SameSizePool


cdef class Memory:
    cdef public size_t size
    cdef size_t _reference
    cdef char *_buffer
    cdef SameSizePool _pool

    cdef increase(self)
    cdef decrease(self)


cdef class Chunk:
    cdef Memory _memory
    cdef size_t _start, _end
    cdef bint _writable
