# This is purely internal API so no negative values checking
# What about __del__ and ref-counting ?


class Memory:
    __slots__ = 'size', '_pool', '_buffer', 'memview', '_reference'

    def __init__(self, size, pool=None):
        self.size = size
        self._pool = pool
        self._buffer = bytearray(size)
        self.memview = memoryview(self._buffer)
        self._reference = 0

    def increase(self):
        self._reference += 1

    def decrease(self):
        self._reference -= 1
        if self._reference == 0:
            if self._pool:
                self._pool.return_memory(self)
            else:
                self._buffer = None
                self.memview = None


# TODO create freelist of this ?
class Chunk:
    __slots__ = '_memory', '_start', '_end', '_writable', '_memory', '_size', '_memview'

    def __init__(self, memory):
        self._memory = memory
        self._start = 0
        self._end = 0
        self._writable = True
        self._memory.increase()
        self._size = self._memory.size
        self._memview = self._memory.memview
    
    def __del__(self):
        self.close()

    def close(self):
        if self._memory:
            self._memory.decrease()
            self._memory = None

    def writable(self):
        if not self._writable:
            raise RuntimeError('This chunk is a view into another chunk and is readonly')
        return self._memview[self._end:]

    def written(self, nbytes):
        if not self._writable:
            raise RuntimeError('This chunk is a view into another chunk and is readonly')
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

    def part(self, start=0, end=None):
        if end is None:
            end = self._end
        else:
            end = min(self._start + end, self._end)
        ret = Chunk(self._memory)
        ret._start = self._start + start
        ret._end = end
        ret._writable = False
        return ret
