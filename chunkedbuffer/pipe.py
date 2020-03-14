from collections import deque

from .pool import global_pool

# TODO consistent _ and space naming
# TODO close api for all
# TODO how much defensive should we on general exceptions happening ?
# TODO document that the code is async safe but not thread safe
# TODO text encoding per read ?
# TODO should some of the commands (such as peek) have optional start, end ?
# TODO set a maximum chunk size for buffer ?

# TODO is this a good default size ?
_DEFAULT_CHUNK_SIZE = 2048


class PartialReadError(Exception):
    def __init__(self, message, leftover):
        super(PartialReadError, self).__init__(message)
        self.leftover = leftover


class Pipe:
    __slots__ =  '_pool', '_current_size', '_minimum_size', '_chunks', '_last', '_bytes_unconsumed', '_ended', '_number_of_lower_than_expected'

    def __init__(self, minimum_size=_DEFAULT_CHUNK_SIZE, pool=None):
        self._pool = pool or global_pool
        self._current_size = self._minimum_size = _DEFAULT_CHUNK_SIZE
        self._chunks = deque()
        self._last = None
        self._bytes_unconsumed = 0
        self._ended = False
        self._number_of_lower_than_expected = 0

    def __del__(self):
        self.close()

    def close(self):
        if self._pool:
            self._last = None
            for chunk in self._chunks:
                self._pool.return_chunk(chunk)
            self._ended = True
            self._bytes_unconsumed = 0
            self._pool = None

    # Write API
    def get_buffer(self, sizehint=-1):
        if sizehint == -1:
            sizehint = self._current_size
        #elif sizehint < self._minimum_size:
            #sizehint = self._minimum_size
        if not self._last or self._last.free() == 0:
            self._last = self._pool.get_chunk(sizehint)
            self._chunks.append(self._last)
        return self._last.writable()

    def buffer_written(self, nbytes):
        # Tradeoff between memory usage and speed
        if nbytes == self._last.size():
            self._number_of_lower_than_expected = 0
            self._current_size <<= 1
        # TODO (optimization) >> 2 ?
        elif nbytes < (self._last.size() >> 1):
            self._number_of_lower_than_expected += 1
            if self._number_of_lower_than_expected > 10:
                self._number_of_lower_than_expected = 0
                self._current_size = max(self._current_size >> 1, self._minimum_size)
        self._last.written(nbytes)
        self._bytes_unconsumed += nbytes

    def eof(self, exception=None):
        if exception is None:
            exception = True
        self._ended = exception

    # Read API
    def findbyte(self, byte, start=0, end=None):
        if start < 0:
            raise ValueError("Not supporting negative indexes")
        if end is None:
            end = self._bytes_unconsumed
        elif end < 0:
            raise ValueError("Not supporting negative indexes")

        if len(self._chunks) == 1:
            return self._last.find(byte, start, end)

        res_idx = 0
        for chunk in self._chunks:
            chunk_length = chunk.length()
            if start >= chunk_length:
                res_idx += chunk_length
                start -= chunk_length
                end -= chunk_length
                continue
            if end <= 0:
                break
            idx = chunk.find(byte, start, end)
            if idx == -1:
                res_idx += chunk_length
                start = 0
                end -= chunk_length
            else:
                res_idx += idx
                return res_idx
        return -1

    # TODO optimize for finding same thing from last known position
    def find(self, s, start=0, end=None):
        if len(self._chunks) == 1 or isinstance(s, int) or len(s) == 1:
            return self.findbyte(s, start, end)

        # TODO we can optimize for end - length of s
        other_s = s[1:]
        other_s_len = len(other_s)
        last_tried_position = start
        while True:
            # TODO (correctness) if end is limited, don't scan past it (in the code after this)
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

    def closed(self):
        return self._ended

    def reached_eof(self):
        return self._ended and self._bytes_unconsumed == 0

    def __len__(self):
        return self._bytes_unconsumed

    def _check_eof(self):
        if self._ended:
            if self._ended is True:
                return b''
            else:
                raise self._ended # pylint: disable=raising-bad-type
        else:
            return None

    def _fullfill_or_error(self, msg):
        if self._bytes_unconsumed == 0:
            return self._check_eof()
        elif self._ended:
            raise PartialReadError(msg, self.read())
        return None

    def _take(self, nbytes=-1, peek=False):
        if nbytes == 0:
            return b''
        if self._bytes_unconsumed == 0:
            return self._check_eof()
        if nbytes < 0:
            nbytes = self._bytes_unconsumed
        else:
            nbytes = min(nbytes, self._bytes_unconsumed)

        if not peek:
            self._bytes_unconsumed -= nbytes

        if len(self._chunks) == 1:
            ret = None
            last = self._last
            last_length = last.length()
            if nbytes == last_length:
                ret = last.readable().tobytes()
                if peek == False:
                    self._chunks.clear()
                    self._last = None
                    self._pool.return_chunk(last)
                return ret
            else:
                ret = last.readable(nbytes).tobytes()
                if peek == False:
                    last.consume(nbytes)
                return ret

        ret_data = []
        to_remove = 0
        for chunk in self._chunks:
            chunk_length = chunk.length()
            if nbytes >= chunk_length:
                ret_data.append(chunk.readable())
                to_remove += 1
                nbytes -= chunk_length
            else:
                ret_data.append(chunk.readable(nbytes))
                chunk.consume(nbytes)
                break

        if not peek:
            while to_remove:
                self._pool.return_chunk(self._chunks.popleft())
                to_remove -= 1
            if not self._chunks:
                self._last = None

        # If we got here ret_data cannot be empty an thus this will not return b''
        ret = b''.join(ret_data)
        return ret

    # TODO handle if exception happened, still cleanup to pool
    def _take_zero_copy(self, nbytes=-1, peek=False):
        if nbytes == 0:
            return b''
        if self._bytes_unconsumed == 0:
            return self._check_eof()
        if nbytes < 0:
            nbytes = self._bytes_unconsumed
        else:
            nbytes = min(nbytes, self._bytes_unconsumed)

        if not peek:
            self._bytes_unconsumed -= nbytes

        if len(self._chunks) == 1:
            ret = None
            last = self._last
            last_length = last.length()
            if nbytes == last_length:
                ret = last.readable()
                if peek == False:
                    self._chunks.clear()
                    self._last = None
                    self._pool.return_chunk(last)
                yield ret
            else:
                ret = last.readable(nbytes)
                if peek == False:
                    last.consume(nbytes)
                yield ret
            return

        ret_data = []
        to_remove = 0
        for chunk in self._chunks:
            chunk_length = chunk.length()
            if nbytes >= chunk_length:
                ret_data.append(chunk.readable())
                to_remove += 1
                nbytes -= chunk_length
            else:
                ret_data.append(chunk.readable(nbytes))
                chunk.consume(nbytes)
                break

        for readable in ret_data:
            yield readable

        if not peek:
            while to_remove:
                self._pool.return_chunk(self._chunks.popleft())
                to_remove -= 1
            if not self._chunks:
                self._last = None

    def _skip(self, nbytes):
        if nbytes == 0:
            return 0
        if self._bytes_unconsumed == 0:
            ret = self._check_eof()
            if ret is not None:
                return 0
        if nbytes < 0:
            nbytes = self._bytes_unconsumed
        else:
            nbytes = min(nbytes, self._bytes_unconsumed)

        self._bytes_unconsumed -= nbytes

        if len(self._chunks) == 1:
            last = self._last
            last_length = last.length()
            if nbytes == last_length:
                self._chunks.clear()
                self._last = None
                self._pool.return_chunk(last)
            else:
                last.consume(nbytes)
            return nbytes

        to_remove = 0
        for chunk in self._chunks:
            chunk_length = chunk.length()
            if nbytes >= chunk_length:
                to_remove += 1
                nbytes -= chunk_length
            else:
                chunk.consume(nbytes)
                break

        while to_remove:
            self._pool.return_chunk(self._chunks.popleft())
            to_remove -= 1
        if not self._chunks:
            self._last = None

        return nbytes

    def peek(self, nbytes=-1):
        return self._take(nbytes, True)

    def peek_zerocopy(self, nbytes=-1):
        return self._take_zero_copy(nbytes, True)

    def peekexact(self, nbytes):
        if self._bytes_unconsumed < nbytes:
            return self._fullfill_or_error("Requested %d bytes but encountered EOF" % nbytes)
        return self._take(nbytes, True)

    def peekexact_zerocopy(self, nbytes):
        if self._bytes_unconsumed < nbytes:
            return self._fullfill_or_error("Requested %d bytes but encountered EOF" % nbytes)
        return self._take_zero_copy(nbytes, True)

    def skip(self, nbytes=-1):
        return self._skip(nbytes)

    def skipexact(self, nbytes):
        if self._bytes_unconsumed < nbytes:
            return self._fullfill_or_error("Requested %d bytes but encountered EOF" % nbytes)
        return self._skip(nbytes)

    def read(self, nbytes=-1):
        return self._take(nbytes)

    def read_zerocopy(self, nbytes=-1):
        return self._take_zero_copy(nbytes)

    def readexact(self, nbytes):
        if self._bytes_unconsumed < nbytes:
            return self._fullfill_or_error("Requested %d bytes but encountered EOF" % nbytes)
        return self._take(nbytes)

    def readexact_zerocopy(self, nbytes):
        if self._bytes_unconsumed < nbytes:
            return self._fullfill_or_error("Requested %d bytes but encountered EOF" % nbytes)
        return self._take_zero_copy(nbytes)

    def readuntil(self, seperator, skip_seperator=False):
        if isinstance(seperator, int) or len(seperator) == 1:
            length = 1
            idx = self.findbyte(seperator)
        else:
            length = len(seperator)
            idx = self.find(seperator)
        if idx == -1:
            return self._fullfill_or_error("Requested to readuntil %s but encountered EOF" % seperator)
        if skip_seperator:
            ret = self._take(idx)
            self._skip(length)
            return ret
        else:
            return self._take(idx + length)

    def readuntil_zerocopy(self, seperator, skip_seperator=False):
        if isinstance(seperator, int) or len(seperator) == 1:
            length = 1
            idx = self.findbyte(seperator)
        else:
            length = len(seperator)
            idx = self.find(seperator)
        if idx == -1:
            return self._fullfill_or_error("Requested to readuntil %s but encountered EOF" % seperator)
        if skip_seperator:
            for chunk in self._take_zero_copy(idx):
                yield chunk
            self._skip(length)
        else:
            return self._take(idx + length)
