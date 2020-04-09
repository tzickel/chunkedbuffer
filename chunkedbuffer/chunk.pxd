from .pool cimport Pool


cdef class Memory:
    cdef:
        public size_t size
        size_t _reference
        char *_buffer
        Pool _pool

    cdef inline void increase(self)
    cdef inline void decrease(self)


cdef class Chunk:
    cdef:
        Memory _memory
        size_t _start, _end
        bint _writable

    cdef void close(self)
    cdef inline object writable(self)
    cdef inline void written(self, size_t nbytes)
    cdef inline size_t size(self)
    cdef inline size_t free(self)
    cdef inline size_t length(self)
    cdef inline object readable(self, size_t nbytes=*)
    cdef inline void consume(self, size_t nbytes)
    cdef inline size_t find(self, char *s, size_t start=*, size_t end=*)
    cdef inline Chunk part(self, size_t start=*, size_t end=*)
