from collections import deque
from .chunk cimport Chunk, Memory


cdef class SameSizePool:
    def __cinit__(self, size_t size):
        self._size = size
    
    def __init__(self, size_t size):
        self._queue = deque()

    def get_chunk(self, size):
        if self._queue:
            return Chunk(self._queue.pop())
        return Chunk(Memory(self._size, self))
    
    cdef return_memory(self, Memory memory):
        self._queue.append(memory)


class UnboundedPool:
    __slots__ = '_memory'

    def __init__(self):
        self._memory = {}

    def get_chunk(self, size_t size):
        size = 1 << (size - 1).bit_length()
        memory = self._memory.get(size)

        if not memory:
            return Chunk(Memory(size, self))
        else:
            return Chunk(memory.pop())

    def return_memory(self, memory):
        self._memory.setdefault(memory.size, deque()).append(memory)

    def reset(self):
        # TODO is this sufficient ?
        self._memory = {}


#global_pool = UnboundedPool()
global_pool = SameSizePool(2**14)
