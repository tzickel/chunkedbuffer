from .pool cimport Pool


cdef class Memory:
    cdef:
        public Py_ssize_t size
        Py_ssize_t _reference
        char *_buffer
        Pool _pool

    cdef inline void increase(self)
    cdef inline void decrease(self)


# TODO (cython) will is be faster to make the * args as non * ?
cdef class Chunk:
    cdef:
        Memory _memory
        Py_ssize_t _start, _end
        bint _writable

    cdef inline void close(self)
    cdef inline object writable(self)
    cdef inline void written(self, Py_ssize_t nbytes)
    cdef inline Py_ssize_t size(self)
    cdef inline Py_ssize_t free(self)
    cdef inline Py_ssize_t length(self)
    cdef inline object readable(self)
    cdef inline object readable_partial(self, Py_ssize_t end)
    cdef inline void consume(self, Py_ssize_t nbytes)
    cdef inline Py_ssize_t find(self, char *s, Py_ssize_t start=*, Py_ssize_t end=*)
    cdef inline Chunk clone(self)
    cdef inline Chunk clone_partial(self, Py_ssize_t end)
