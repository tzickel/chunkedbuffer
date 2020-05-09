# distutils: define_macros=CYTHON_TRACE_NOGIL=1
# cython: language_level=3, boundscheck=False, wraparound=False, initializedcheck=False, always_allow_keywords=False

include "consts.pxi"

from libc.stdlib cimport malloc, free
from libc.string cimport memcpy
from cpython cimport Py_buffer, PyBuffer_FillInfo, buffer
cimport cython


# TODO (cython) move no_gc_clear to Buffer ?
# TODO (cython) how to signify our size has the malloc size as well (like in bytearray)?
@cython.no_gc_clear
cdef class Memory:
    cdef void decrease(self):
        pass


cdef class MemoryBySize(Memory):
    def __cinit__(self, Py_ssize_t size, Pool pool):
        self.size = size
        self._buffer = <char *>malloc(size)
        if self._buffer is NULL:
            raise MemoryError()
        self._pool = pool

    def __dealloc__(self):
        free(self._buffer)

    cdef void decrease(self):
        self.reference -= 1
        if self.reference == 0 and self._pool is not None:
            self._pool.return_memory(self)


cdef class MemoryByBufferObject(Memory):
    cdef inline void _init(self, Py_buffer buffer):
        self._obj_buffer = buffer
        self.size = buffer.len
        self._buffer = <char *>buffer.buf

    def __dealloc__(self):
        buffer.PyBuffer_Release(&self._obj_buffer)

    cdef void decrease(self):
        self.reference -= 1


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

    def __getbuffer__(self, Py_buffer *buffer, int flags):
        if self._readonly:
            PyBuffer_FillInfo(buffer, self, <void *>(self._buffer + self._start), self._end - self._start, 1, flags)
        else:
            PyBuffer_FillInfo(buffer, self, <void *>(self._buffer + self._end), self.size - self._end, 0, flags)
            if self._memoryview_taken > 0:
                raise BufferError("Please release previous buffer taken")
        self._memoryview_taken += 1

    def __releasebuffer__(self, Py_buffer *buffer):
        self._memoryview_taken -= 1

    # This is a hack fix to make SSL recv_into work..... this is the length of leftover writable.
    def __len__(self):
        if self._readonly:
            return self._end - self._start
        else:
            return self.size - self._end
