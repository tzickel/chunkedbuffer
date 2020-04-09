from collections import deque
from .chunk cimport Chunk
from .pool cimport global_pool, Pool
cimport cython

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


@cython.no_gc_clear
@cython.final
@cython.freelist(1000)
cdef class Buffer:
    cdef:
        Pool _pool
        object _chunks
        object _chunks_append
        object _chunks_popleft
        object _chunks_clear
        size_t _chunks_length
        size_t _length
        cdef Chunk _last

    def __cinit__(self, Pool pool=None):
        self._pool = pool or global_pool
        chunk = deque()
        self._chunks = chunk
        self._chunks_append = chunk.append
        self._chunks_popleft = chunk.popleft
        self._chunks_clear = chunk.clear
        self._chunks_length = 0
        self._length = 0
        self._last = None

    # TODO circular reference ? is this a problem ?
    # TODO _cython) __dealloc__ ?
    def __del__(self):
        self.close()

    cdef inline void close(self):
        cdef:
            Chunk chunk

        if self._chunks is not None:
            for chunk in self._chunks:
                chunk.close()
            self._chunks_clear.clear()
            self._chunks = None
            self._chunks_append = None
            self._chunks_popleft = None
            self._chunks_clear = None
            # TODO (cython) can you be Chunk or None more optimized ?
            self._last = None

    def __bytes__(self):
        if self._chunks_length == 0:
            return b''
        elif self._chunks_length == 1:
            return self._last.readable().tobytes()
        else:
            return b''.join([x.readable() for x in self._chunks])

    def __len__(self):
        return self._length

    cdef inline void _add_chunk(self, Chunk chunk):
        self._chunks_append(chunk)
        self._chunks_length += 1
        self._length += chunk.length()
        self._last = chunk

    # Read API
    # TODO fix this
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

    # If you ask for more, you'll get what we have, it's your responsbility to check length before
    def peek(self, size_t nbytes=-1):
        cdef:
            Chunk chunk
            Buffer ret
            size_t chunk_length

        if nbytes < 0:
            nbytes = self._length
        else:
            nbytes = min(nbytes, self._length)

        if nbytes == 0 or self._length == 0:
            return Buffer()
        elif self._chunks_length == 1:
            ret = Buffer()
            ret._add_chunk(self._last.part(0, nbytes))
            return ret
        else:
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

    def take(self, size_t nbytes=-1):
        cdef:
            Buffer ret
            Chunk last, chunk
            size_t last_length, chunk_length, to_remove
        
        if nbytes < 0:
            nbytes = self._length
        else:
            nbytes = min(nbytes, self._length)
        
        self._length -= nbytes

        if nbytes == 0 or self._length == 0:
            return Buffer()
        elif self._chunks_length == 1:
            ret = Buffer()
            last = self._last
            last_length = last.length()
            if nbytes == last_length:
                ret._add_chunk(last)
                self._chunks_clear()
                self._chunks_length = 0
                self._last = None
            else:
                ret._add_chunk(last.part(0, nbytes))
                last.consume(nbytes)
            return ret
        else:
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
                self._chunks_popleft()
                self._chunks_length -= 1
            if self._chunks_length == 0:
                self._last = None

            return ret

    # TODO fix/optimize
    def skip(self, nbytes=-1):
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
    def get_buffer(self, size_t sizehint=-1):
        cdef:
            Chunk chunk

        #if sizehint == -1:
            #sizehint = self._current_size
        if not self._last or self._last.free() == 0:
            chunk = self._pool.get_chunk(2048)
            self._add_chunk(chunk)
            return chunk.writable()
        else:
            return self._last.writable()

    def buffer_written(self, size_t nbytes):
        self._last.written(nbytes)
        self._length += nbytes
