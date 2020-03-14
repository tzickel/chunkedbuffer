from collections import deque


# TODO optional extra optimization, return something like a memoryview over multiple chunks instead of materializing them as an bytearray
# TODO for those who need it, return a bytes instead of a bytearray (requires some c-api hacking)
# TODO add async module API with backpresure blocking
# TODO handle EOF/error
# TODO consistent _ and space naming
# TODO close api for all
# TODO on exception close everything?
# TODO async safe but not thread safe ?
# TODO text encoding ?


DEFAULT_CHUNK_SIZE = 2**14


class Chunk:
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

    def readable(self, howmuch=None):
        if howmuch is not None and howmuch < 0:
            raise NotImplementedError()
        if howmuch is None:
            end = self._end
        else:
            end = min(self._start + howmuch, self._end)
        return self._memview[self._start:end]

    def consume(self, nbytes):
        self._start += nbytes

    def findbyte(self, byte, start=0, end=None):
        if len(byte) > 1:
            raise Exception('Can only find one byte')
        if start < 0:
            raise NotImplementedError()
        if end is None or end == -1:
            end = self._end
        if end < -1:
            raise NotImplementedError()
        # TODO make sure this is sane
        end = min(self._start + end, self._end)
        ret = self._buffer.find(byte, self._start + start, end)
        return ret if ret == -1 else (ret - self._start)


# TODO do some memory cleaning on memory limit
class Pool:
    def __init__(self):
        self._chunks = {}

    def get_chunk(self, size):
        size = 1 << (size - 1).bit_length()
        chunks = self._chunks.get(size)
        if not chunks:
            return Chunk(size)
        else:
            ret = chunks.popleft()
            ret.reset()
            return ret

    def return_chunk(self, chunk):
        self._chunks.setdefault(chunk.size(), deque()).append(chunk)


class Pipe:
    def __init__(self, on_new_data=None, pool=None):
        self._on_new_data = on_new_data
        self._pool = pool or global_pool
        self._chunks = deque()
        self._last = None
        self._bytes_unconsumed = 0
        self._ended = False

    # Write API
    def get_buffer(self, sizehint=-1):
        if sizehint == -1:
            if self._last:
                sizehint = self._last.free() or -1
            if sizehint == -1:
                sizehint = DEFAULT_CHUNK_SIZE
        if not self._last or self._last.free() < sizehint:
            self._last = self._pool.get_chunk(sizehint)
            self._chunks.append(self._last)
        return self._last.writable()

    def buffer_written(self, nbytes):
        self._last.written(nbytes)
        self._bytes_unconsumed += nbytes
        if self._on_new_data:
            self._on_new_data(self)
    
    def eof(self, exception=None):
        if exception is None:
            exception = True
        self._last = None
        self._ended = exception
        if self._on_new_data:
            self._on_new_data(self)

    # Read API
    # TODO support negative indexes for start and end ?
    # TODO work hard and make it able to find more than one byte ?
    def findbyte(self, byte, start=0, end=-1):
        if start < 0:
            raise NotImplementedError()
        if end < -1:
            raise NotImplementedError()
        res_idx = 0
        found = False
        for chunk in self._chunks:
            chunk_length = chunk.length()
            if start > chunk_length:
                res_idx += chunk_length
                start -= chunk_length
                if end != -1:
                    end -= chunk_length
                continue
            idx = chunk.findbyte(byte, start, end)
            if idx == -1:
                res_idx += chunk_length
            else:
                found = True
                res_idx += idx
                break
        return res_idx if found else -1

    # TODO don't always scan from the start
    # TODO don't return the newline ?
    # TODO abstract this API to a general find ?
    # TODO support readline of '\n' and '\r\n' (and returning them or not)
    def readline(self):
        if self._bytes_unconsumed == 0:
            return None
        idx_r = self.findbyte(b'\r')
        if idx_r == -1:
            return None
        while True:
            idx_n = self.findbyte(b'\n', idx_r + 1, idx_r + 2)
            if idx_n != -1:
                return self.readatmostbytes(idx_n + 1)
            idx_r = self.findbyte(b'\r', idx_r + 1)
            if idx_r == -1:
                return None

    def readbytes(self, nbytes):
        if self._bytes_unconsumed < nbytes:
            return None
        return self.readatmostbytes(nbytes)

    # TODO error on 0 length ?
    def readatmostbytes(self, nbytes=-1):
        if nbytes == -1:
            nbytes = self._bytes_unconsumed
        if self._bytes_unconsumed == 0:
            return None
        # TODO hack a way to return bytes instead of bytearray with ctypes ? :)
        ret = bytearray(nbytes)
        retpos = 0
        to_remove = 0
        self._bytes_unconsumed -= nbytes
        for chunk in self._chunks:
            chunk_length = chunk.length()
            # TODO if it's not yet full, we can still use it (only if it's the last chunk...)
            if nbytes >= chunk_length:
                ret[retpos:retpos + chunk_length] = chunk.readable()
                retpos += chunk_length
                to_remove += 1
                self._pool.return_chunk(chunk)
                if self._last == chunk:
                    self._last = None
                nbytes -= chunk_length
            else:
                ret[retpos:retpos + nbytes] = chunk.readable(nbytes)
                chunk.consume(nbytes)
                break
        while to_remove:
            self._chunks.popleft()
            to_remove -= 1
        return ret

    def closed(self):
        return self._ended


global_pool = Pool()


if __name__ == "__main__":
    pipe = Pipe()
    buff = pipe.get_buffer()
    buff[:5] = b'testi'
    pipe.buffer_written(5)
    assert pipe.readbytes(100) == None
    assert pipe.readbytes(4) == b'test'
    buff = pipe.get_buffer()
    buff[:5] = b'ng\r\nx'
    pipe.buffer_written(5)
    print(pipe.readline())
