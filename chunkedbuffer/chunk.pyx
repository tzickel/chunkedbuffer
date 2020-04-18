# distutils: define_macros=CYTHON_TRACE_NOGIL=1
# cython: language_level=3, boundscheck=False, wraparound=False, initializedcheck=False, always_allow_keywords=False

include "consts.pxi"

from libc.stdlib cimport malloc, free
from libc.string cimport memcpy
from cpython cimport buffer, Py_buffer
cimport cython


# TODO (cython) move no_gc_clear to Buffer ?
# TODO (cython) how to signify our size has the malloc size as well (like in bytearray)?
@cython.no_gc_clear
@cython.final
cdef class Memory:
    def __cinit__(self, Py_ssize_t size, Pool pool):
        self.size = size
        self._buffer = <char *>malloc(size)
        if self._buffer is NULL:
            raise MemoryError()
        self._pool = pool
        self.reference = 0

    def __dealloc__(self):
        if self._buffer is not NULL:
            free(self._buffer)

    cdef inline void increase(self):
        self.reference += 1

    cdef inline void decrease(self):
        self.reference -= 1
        # TODO reference counting should take care of this, but if no pool, we can just free the memory now.
        if self.reference == 0 and self._pool is not None:
            self._pool.return_memory(self)


# TODO (cython) move no_gc_clear to Buffer ?
@cython.no_gc_clear
@cython.final
@cython.freelist(_FREELIST_SIZE)
cdef class Chunk:
    def __cinit__(self, Memory memory):
        self._memory = memory
        self.size = memory.size
        self._buffer = memory._buffer
        self._start = 0
        self._end = 0
        self._writable = True
        self._memory.increase()
        self._strides[0] = 1

    def __dealloc__(self):
        self._memory.decrease()

    cdef void readonly(self):
        self._writable = False

    cdef inline bint written(self, Py_ssize_t nbytes) except 0:
        if nbytes < 0 or nbytes > (self.size - self._end):
            raise ValueError('Tried to write an invalid length %d' % nbytes)
        self._end += nbytes
        return 1

    cdef inline Py_ssize_t free(self):
        return self.size - self._end

    cdef inline Py_ssize_t length(self):
        return self._end - self._start

    cdef inline void consume(self, Py_ssize_t nbytes):
        self._start += nbytes

    cdef inline Chunk clone(self):
        cdef:
            Chunk ret

        ret = Chunk(self._memory)
        ret._start = self._start
        ret._end = self._end
        ret._writable = False
        return ret

    cdef inline Chunk clone_partial(self, Py_ssize_t length):
        cdef:
            Chunk ret

        ret = Chunk(self._memory)
        ret._start = self._start
        ret._end = self._start + length
        ret._writable = False
        return ret

    cdef inline Py_ssize_t copy_to(self, void *dest, Py_ssize_t start, Py_ssize_t length):
        if start < 0:
            start = self._end + start
        else:
            start += self._start
        start = max(start, self._start)
        length = min(self._end - start, length)
        memcpy(dest, self._buffer + start, length)
        return length

    # TODO we can do better flags checking
    def __getbuffer__(self, Py_buffer *buffer, int flags):
        if self._writable:
            if self._memoryview_taken > 0:
                raise BufferError("Please release previous buffer taken")
            buffer.buf = &(self._buffer[self._end])
            buffer.len = self.size - self._end
            buffer.readonly = 0
        else:
            buffer.buf = &(self._buffer[self._start])
            buffer.len = self._end - self._start
            buffer.readonly = 1
        buffer.format = 'B'
        buffer.internal = NULL
        buffer.itemsize = 1
        buffer.ndim = 1
        # TODO how to do this properly ?
        buffer.obj = self
        self._shape[0] = buffer.len
        buffer.shape = self._shape
        buffer.strides = self._strides
        buffer.suboffsets = NULL
        self._memoryview_taken += 1

    def __releasebuffer__(self, Py_buffer *buffer):
        self._memoryview_taken -= 1

    # This is a hack fix to make SSL recv_into work..... this is the length of leftover writable.
    def __len__(self):
        if self._writable:
            return self.size - self._end
        else:
            return self._end - self._start
