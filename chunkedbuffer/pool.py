from collections import deque
from .chunk import Chunk


# TODO what other types of pools to put here ?


class Pool:
    def get_chunk(self, size):
        raise NotImplementedError() # pragma: no cover

    def return_chunk(self, chunk):
        raise NotImplementedError() # pragma: no cover


class UnboundedPool(Pool):
    __slots__ = '_chunks'

    def __init__(self):
        self._chunks = {}

    def get_chunk(self, size):
        size = 1 << (size - 1).bit_length()
        chunks = self._chunks.get(size)

        if not chunks:
            return Chunk(size)
        else:
            ret = chunks.pop()
            ret.reset()
            return ret

    def return_chunk(self, chunk):
        self._chunks.setdefault(chunk.size(), deque()).append(chunk)


global_pool = UnboundedPool()
