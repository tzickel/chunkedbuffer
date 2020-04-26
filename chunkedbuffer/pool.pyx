# distutils: define_macros=CYTHON_TRACE_NOGIL=1
# cython: language_level=3, boundscheck=False, wraparound=False, initializedcheck=False, always_allow_keywords=False

include "consts.pxi"

from collections import deque
cimport cython


cdef class Pool:
    cdef Chunk get_chunk(self, size):
        raise NotImplementedError()

    cdef void return_memory(self, Memory memory):
        raise NotImplementedError()


"""
# TODO update to new lean syntax
@cython.final
cdef class SameSizePool:
    def __cinit__(self, Py_ssize_t size):
        self._size = size
        self._queue = deque()
        self._queue_append = self._queue.append
        self._queue_pop = self._queue.pop
        self._length = 0

    cdef Chunk get_chunk(self, size):
        if self._length:
            self._length -= 1
            return Chunk()._init(self._queue_pop())
        return Chunk()._init(Memory(self._size, self))
    
    cdef void return_memory(self, Memory memory):
        self._length += 1
        self._queue_append(memory)
"""


@cython.final
cdef class UnboundedPool:
    def __cinit__(self):
        self._memory = {}

    cdef Chunk get_chunk(self, size):
        cdef:
            Chunk chunk
        # TODO implment fast power of 2 calculation
        #size = 1 << (size - 1).bit_length()
        memory = self._memory.get(size)

        chunk = Chunk()
        if memory:
            chunk._init(memory.pop())
        else:
            chunk._init(Memory(size, self))
        return chunk

    cdef void return_memory(self, Memory memory):
        self._memory.setdefault(memory.size, deque()).append(memory)

    def reset(self):
        self._memory = {}

    def _debug(self):
        return self._memory


global_pool = UnboundedPool()
#global_pool = SameSizePool(2**14)
