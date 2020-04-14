from .pool cimport Pool


cdef class Memory:
    cdef:
        public Py_ssize_t size
        Py_ssize_t _reference
        char *_buffer
        Pool _pool

    cdef inline void increase(self)
    cdef inline void decrease(self)


cdef class Chunk:
    cdef:
        Memory _memory
        public Py_ssize_t size
        Py_ssize_t _start, _end, _memoryview_taken
        bint _writable
        char *_buffer
        Py_ssize_t _shape[1]
        Py_ssize_t _strides[1]

    cdef inline void close(self)
    cdef inline void written(self, Py_ssize_t nbytes)
    cdef inline Py_ssize_t free(self)
    cdef inline Py_ssize_t length(self)
    cdef inline object readable(self)
    cdef inline object readable_partial(self, Py_ssize_t length)
    cdef inline void consume(self, Py_ssize_t nbytes)
    cdef inline Py_ssize_t find(self, const unsigned char [:] s, Py_ssize_t start=0, Py_ssize_t end=-1)
    cdef inline Chunk clone(self)
    cdef inline Chunk clone_partial(self, Py_ssize_t length)
    cdef inline Py_ssize_t memcpy(self, void *dest, Py_ssize_t start, Py_ssize_t length)
