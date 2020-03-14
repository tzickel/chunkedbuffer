# This is purely internal API so no negative values checking

class Chunk:
    __slots__ = '_size', '_buffer', '_memview', '_start', '_end', '__weakref__'

    def __init__(self, size):
        self._size = size
        self._buffer = bytearray(size)
        self._memview = memoryview(self._buffer)
        self._start = 0
        self._end = 0

    def reset(self):
        self._start = 0
        self._end = 0

    def writable(self):
        return self._memview[self._end:]

    def written(self, nbytes):
        self._end += nbytes

    def size(self):
        return self._size

    def free(self):
        return self._size - self._end

    def length(self):
        return self._end - self._start

    def readable(self, nbytes=None):
        if nbytes is None:
            end = self._end
        else:
            end = min(self._start + nbytes, self._end)
        return self._memview[self._start:end]

    def consume(self, nbytes):
        self._start += nbytes

    def find(self, s, start=0, end=None):
        if end is None:
            end = self._end
        else:
            end = min(self._start + end, self._end)
        ret = self._buffer.find(s, self._start + start, end)
        if ret == -1:
            return -1
        return ret - self._start