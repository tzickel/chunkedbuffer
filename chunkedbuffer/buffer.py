from collections import deque

from .pool import global_pool

# TODO consistent _ and space naming
# TODO close api for all
# TODO how much defensive should we on general exceptions happening ?
# TODO document that the code is async safe but not thread safe
# TODO text encoding per read ?
# TODO should some of the commands (such as peek) have optional start, end ?
# TODO set a maximum chunk size for buffer ?
# TODO remove exact API ?
# TODO set maximum size for pool item

# TODO new take setup _last correctly

# TODO is this a good default size ?
_DEFAULT_CHUNK_SIZE = 2048


class Buffer:
    def __init__(self, pool=None):
        self._pool = pool or global_pool
        self._chunks = deque()
        self._last = None

    # TODO circular reference ? is this a problem ?
    def __del__(self):
        self.close()

    def close(self):
        if self._chunks is not None:
            for chunk in self._chunks:
                chunk.close()
            self._chunks.clear()
            self._chunks = None
            self._last = None

    def __bytes__(self):
        if len(self._chunks) == 1:
            return self._last.readable().tobytes()
        return b''.join([x.readable() for x in self._chunks])

    def __len__(self):
        if len(self._chunks) == 1:
            return self._last.length()
        return sum([x.length() for x in self._chunks])

    def _add_chunk(self, chunk):
        self._chunks.append(chunk)
        self._last = chunk

    # Read API
    def findbyte(self, byte, start=0, end=None):
        if start < 0:
            raise ValueError("Not supporting negative indexes")
        if end is None:
            end = len(self)
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

    # If you ask for more, you'll get what we have, it's your responsbility to check length before
    def peek(self, nbytes=-1):
        if nbytes == 0 or len(self) == 0:
            return EmptyBuffer()
        elif nbytes < 0:
            nbytes = len(self)
        else:
            nbytes = min(nbytes, len(self))
        
        if len(self._chunks) == 1:
            ret = Buffer()
            ret._add_chunk(self._last.part(0, nbytes))
            return ret
        
        ret = Buffer()
        for chunk in self._chunks:
            chunk_length = chunk.length()
            if nbytes < chunk_length:
                ret._add_chunk(self._last.part(0, nbytes))
                break
            else:
                nbytes -= chunk_length
                ret._add_chunk(self._last.part())
        return ret

    def take(self, nbytes=-1):
        if nbytes == 0 or len(self) == 0:
            return EmptyBuffer()
        elif nbytes < 0:
            nbytes = len(self)
        else:
            nbytes = min(nbytes, len(self))
        
        if len(self._chunks) == 1:
            ret = Buffer()
            last = self._last
            last_length = last.length()
            if nbytes == last_length:
                ret._add_chunk(last)
                self._chunks.clear()
                self._last = None
            else:
                ret._add_chunk(last.part(0, nbytes))
                last.consume(nbytes)
            return ret
        
        ret = Buffer()
        to_remove = 0
        # TODO make sure we don't make zero chunk in the end !!!
        for chunk in self._chunks:
            chunk_length = chunk.length()
            if nbytes < chunk_length:
                ret._add_chunk(chunk.part(0, nbytes))
                chunk.consume(nbytes)
                break
            else:
                nbytes -= chunk_length
                ret._add_chunk(chunk)
                to_remove += 1

        while to_remove:
            # TODO would be nice to explicitly call .close on chunks here but we don't know if partial or not, for now __del__ should do it.
            self._chunks.popleft()
            if not self._chunks:
                self._last = None

        return ret

    def skip(self, nbytes=-1):
        # TODO just like take, just return number of items skipped
        if nbytes == 0 or len(self) == 0:
            return 0
        elif nbytes < 0:
            nbytes = len(self)
        else:
            nbytes = min(nbytes, len(self))
        
        if len(self._chunks) == 1:
            last = self._last
            last_length = last.length()
            if nbytes == last_length:
                self._chunks.clear()
                self._last = None
            else:
                last.consume(nbytes)
            return nbytes

        ret = 0
        to_remove = 0
        # TODO make sure we don't make zero chunk in the end !!!
        for chunk in self._chunks:
            chunk_length = chunk.length()
            if nbytes < chunk_length:
                ret += nbytes
                chunk.consume(nbytes)
                break
            else:
                nbytes -= chunk_length
                ret += chunk_length
                to_remove += 1

        while to_remove:
            # TODO would be nice to explicitly call .close on chunks here but we don't know if partial or not, for now __del__ should do it.
            self._chunks.popleft()
            if not self._chunks:
                self._last = None

        return ret

    # Write API
    def get_buffer(self, sizehint=-1):
        #if sizehint == -1:
            #sizehint = self._current_size
        if not self._last or self._last.free() == 0:
            chunk = self._pool.get_chunk(2048)
            self._add_chunk(chunk)
            return chunk.writable()
        return self._last.writable()

    def buffer_written(self, nbytes):
        self._last.written(nbytes)
