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

    def __dealloc__(self):
        if self._buffer is not NULL:
            free(self._buffer)

    cdef inline void decrease(self):
        self.reference -= 1
        # TODO reference counting should take care of this, but if no pool, we can just free the memory now.
        if self.reference == 0 and self._pool is not None:
            self._pool.return_memory(self)


# TODO (cython) move no_gc_clear to Buffer ?
@cython.no_gc_clear
@cython.final
# TODO is freelist faster or slower than alloc ?
@cython.freelist(_FREELIST_SIZE)
cdef class Chunk:
    cdef inline void _init(self, Memory memory):
        self._memory = memory
        self.size = memory.size
        self._buffer = memory._buffer
        memory.reference += 1
        self._strides[0] = 1

    def __dealloc__(self):
        self._memory.decrease()

    cdef inline Chunk clone(self):
        cdef:
            Chunk ret

        ret = Chunk()
        ret._init(self._memory)
        ret._start = self._start
        ret._end = self._end
        ret._readonly = True
        return ret

    cdef inline Chunk clone_partial(self, Py_ssize_t length):
        cdef:
            Chunk ret

        ret = Chunk()
        ret._init(self._memory)
        ret._start = self._start
        ret._end = self._start + length
        ret._readonly = True
        return ret

    cdef inline Py_ssize_t copy_to(self, void *dest, Py_ssize_t start, Py_ssize_t length):
        if start < 0:
            start = self._end + start
            start = max(start, self._start)
        else:
            start += self._start
            start = min(start, self._end)
        length = min(self._end - start, length)
        memcpy(dest, self._buffer + start, length)
        return length

    # TODO we can do better flags checking
    def __getbuffer__(self, Py_buffer *buffer, int flags):
        if self._readonly:
            buffer.buf = &(self._buffer[self._start])
            buffer.len = self._end - self._start
            buffer.readonly = 1
        else:
            if self._memoryview_taken > 0:
                raise BufferError("Please release previous buffer taken")
            buffer.buf = &(self._buffer[self._end])
            buffer.len = self.size - self._end
            buffer.readonly = 0
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
        if self._readonly:
            return self._end - self._start
        else:
            return self.size - self._end
