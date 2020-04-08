from collections import deque
from .chunk import Chunk, Memory


# TODO what other types of pools to put here ?
# TODO freelist for Chunks...


class Pool:
    def get_chunk(self, size):
        raise NotImplementedError() # pragma: no cover

    def return_memory(self, memory):
        raise NotImplementedError() # pragma: no cover


class UnboundedPool(Pool):
    __slots__ = '_memory'

    def __init__(self):
        self._memory = {}

    def get_chunk(self, size):
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


global_pool = UnboundedPool()
