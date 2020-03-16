from collections import deque


# TODO optional extra optimization, return something like a memoryview over multiple chunks instead of materializing them as an bytearray
# TODO add async module API with backpresure blocking
# TODO handle EOF/error
# TODO consistent _ and space naming
# TODO close api for all
# TODO on exception close everything?
# TODO async safe but not thread safe ?
# TODO text encoding per read ?


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
        if howmuch is None:
            end = self._end
        else:
            if howmuch < 0:
                raise NotImplementedError()
            end = min(self._start + howmuch, self._end)
        return self._memview[self._start:end]

    def consume(self, nbytes):
        self._start += nbytes

    def findbyte(self, byte, start=0, end=None):
        # TODO move this check to the parent
        if not isinstance(byte, int) and len(byte) > 1:
            raise Exception('Can only find one byte')
        if start < 0:
            raise NotImplementedError()
        if end is None or end == -1:
            end = self._end
        if end < -1:
            raise NotImplementedError()
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
    # TODO abstract this API to a general find ?
    # TODO support readline of '\n' and '\r\n' (and returning them or not)
    def readline(self, with_ending=True):
        if self._bytes_unconsumed == 0:
            # TODO if it was an exception, propogate that ?
            if self._ended:
                return b''
            else:
                return None
            return None
        idx_r = self.findbyte(b'\r')
        if idx_r == -1:
            if self._ended:
                return b''
            else:
                return None
        while True:
            idx_n = self.findbyte(b'\n', idx_r + 1, idx_r + 2)
            if idx_n != -1:
                if with_ending:
                    return self.readatmostbytes(idx_n + 1)
                else:
                    ret = self.readatmostbytes(idx_n - 1)
                    # TODO (optimize) don't materialize this
                    self.readatmostbytes(2)
                    return ret
            idx_r = self.findbyte(b'\r', idx_r + 1)
            if idx_r == -1:
                if self._ended:
                    return b''
                else:
                    return None

    def readbytes(self, nbytes):
        if self._bytes_unconsumed < nbytes:
            # TODO is this the correct behaviour ?
            if self._ended:
                return b''
            else:
                return None
        return self.readatmostbytes(nbytes)

    # TODO error on 0 length ?
    def readatmostbytes(self, nbytes=-1, _take=True):
        if nbytes == -1:
            nbytes = self._bytes_unconsumed
        if self._bytes_unconsumed == 0:
            if self._ended:
                # TODO if it was an exception, propogate that ?
                return b''
            else:
                return None
        ret_data = []
        to_remove = 0
        nbytes = min(nbytes, self._bytes_unconsumed)
        if _take:
            self._bytes_unconsumed -= nbytes
        for chunk in self._chunks:
            chunk_length = chunk.length()
            # TODO if it's not yet full, we can still use it (only if it's the last chunk...)
            if nbytes >= chunk_length:
                ret_data.append(chunk.readable())
                if _take:
                    to_remove += 1
                    if self._last == chunk:
                        self._last = None
                nbytes -= chunk_length
            else:
                ret_data.append(chunk.readable(nbytes))
                if _take:
                    chunk.consume(nbytes)
                break
        while to_remove:
            self._pool.return_chunk(self._chunks.popleft())
            to_remove -= 1
        ret = b''.join(ret_data)
        return ret

    def closed(self):
        return self._ended

    def __len__(self):
        return self._bytes_unconsumed

    # TODO maybe add start, end ?
    def peek(self, nbytes):
        return self.readatmostbytes(nbytes, _take=False)

    def find(self, s, start=0, end=-1):
        # we can optimize for end - length of s
        other_s = s[1:]
        other_s_len = len(other_s)
        last_tried_position = start
        while True:
            start_idx = self.findbyte(s[0], last_tried_position, end)
            if start_idx == -1:
                return -1
            curr_idx = start_idx
            for letter in other_s:
                if self.findbyte(letter, curr_idx + 1, curr_idx + 2) == -1:
                    break
                curr_idx += 1
            if other_s_len == curr_idx - start_idx:
                return start_idx
            last_tried_position += 1


global_pool = Pool()


if __name__ == "__main__":
    pipe = Pipe()
    buff = pipe.get_buffer()
    buff[:5] = b'testi'
    pipe.buffer_written(5)
    assert pipe.readbytes(100) == None
    assert pipe.readbytes(4) == b'test'
    buff = pipe.get_buffer()
    buff[:5] = b'ng\r\nt'
    pipe.buffer_written(5)
    assert pipe.readline() == b'ing\r\n'
    buff = pipe.get_buffer(8)
    buff[:8] = b'esting\r\n'
    pipe.buffer_written(8)
    assert pipe.peek(7) == b'testing'
    assert pipe.readline(with_ending=False) == b'testing'
