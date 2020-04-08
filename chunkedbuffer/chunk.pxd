from .pool cimport SameSizePool


cdef class Memory:
    cdef public size_t size
    cdef size_t _reference
    cdef char *_buffer
    cdef SameSizePool _pool

    cdef void increase(self)
    cdef void decrease(self)


cdef class Chunk:
    cdef Memory _memory
    cdef size_t _start, _end
    cdef bint _writable

    cdef void close(self)
    cdef object writable(self)
    cdef void written(self, size_t nbytes)
    cdef size_t size(self)
    cdef size_t free(self)
    cdef size_t length(self)
    cdef object readable(self, size_t nbytes=*)
    cdef void consume(self, size_t nbytes)
    cdef size_t find(self, char *s, size_t start=*, size_t end=*)
    cdef Chunk part(self, size_t start=*, size_t end=*)
