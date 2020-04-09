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
# TODO (cython) does this mean we have 
@cython.freelist(254)
cdef class Buffer:
    cdef:
        Pool _pool
        object _chunks
        object _chunks_append
        object _chunks_popleft
        object _chunks_clear
        Py_ssize_t _chunks_length
        Py_ssize_t _length
        Chunk _last

    def __cinit__(self, Pool pool=global_pool):
        self._pool = pool
        chunk = deque()
        self._chunks = chunk
        self._chunks_append = chunk.append
        self._chunks_popleft = chunk.popleft
        self._chunks_clear = chunk.clear

    # TODO circular reference ? is this a problem ?
    def __dealloc__(self):
        self.close()

    cpdef inline void close(self):
        cdef:
            Chunk chunk

        if self._chunks is not None:
            for chunk in self._chunks:
                chunk.close()
            self._chunks_clear()
            self._chunks = None
            self._chunks_append = None
            self._chunks_popleft = None
            self._chunks_clear = None
            # TODO (cython) can you be Chunk or None more optimized ?
            self._last = None
            self._pool = None

    def __bytes__(self):
        if self._chunks_length == 1:
            return self._last.readable().tobytes()
        elif self._chunks_length == 0:
            return b''
        else:
            # TODO (cython) faster to do casting to Chunk ?
            return b''.join([x.readable() for x in self._chunks])

    def __len__(self):
        return self._length

    cdef inline void _add_chunk(self, Chunk chunk):
        self._chunks_append(chunk)
        self._chunks_length += 1
        self._length += chunk.length()
        self._last = chunk

    cdef inline void _add_chunk_without_length(self, Chunk chunk):
        self._chunks_append(chunk)
        self._chunks_length += 1
        self._last = chunk

    # Read API
    def findbyte(self, char *byte, Py_ssize_t start=0, Py_ssize_t end=-1):
        cdef:
            Chunk chunk
            Py_ssize_t chunk_length, res_idx

        if start < 0 or end < -1:
            raise ValueError("Not supporting negative indexes")
        if end == -1:
            end = self._length

        if self._chunks_length == 0:
            return -1
        elif self._chunks_length == 1:
            return self._last.find(byte, start, end)
        else:
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

    def peek(self, Py_ssize_t nbytes=-1):
        cdef:
            Buffer ret
            Chunk chunk
            Py_ssize_t chunk_length

        if nbytes < 0:
            nbytes = self._length
        else:
            nbytes = min(nbytes, self._length)

        if nbytes == 0 or self._length == 0:
            return Buffer()
        elif self._chunks_length == 1:
            ret = Buffer()
            ret._add_chunk(self._last.clone_partial(nbytes))
            return ret
        else:
            ret = Buffer()
            for chunk in self._chunks:
                chunk_length = chunk.length()
                if nbytes < chunk_length:
                    if nbytes:
                        ret._add_chunk(chunk.clone_partial(nbytes))
                    break
                else:
                    nbytes -= chunk_length
                    ret._add_chunk(chunk.clone())
            return ret

    def peek_bytes(self, Py_ssize_t nbytes=-1):
        cdef:
            list ret
            Chunk chunk
            Py_ssize_t chunk_length

        if nbytes < 0:
            nbytes = self._length
        else:
            nbytes = min(nbytes, self._length)

        if nbytes == 0 or self._length == 0:
            return b''
        elif self._chunks_length == 1:
            return self._last.clone_partial(nbytes).tobytes()
        else:
            ret = []
            for chunk in self._chunks:
                chunk_length = chunk.length()
                if nbytes < chunk_length:
                    if nbytes:
                        ret.append(chunk.readable_partial(nbytes))
                    break
                else:
                    nbytes -= chunk_length
                    ret.append(chunk.readable())
            return b''.join(ret)

    def take(self, Py_ssize_t nbytes=-1):
        cdef:
            Buffer ret
            Chunk last, chunk
            Py_ssize_t last_length, chunk_length, to_remove
        
        if nbytes < 0:
            nbytes = self._length
        else:
            nbytes = min(nbytes, self._length)

        self._length -= nbytes

        if nbytes == 0 or self._chunks_length == 0:
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
                ret._add_chunk(last.clone_partial(nbytes))
                last.consume(nbytes)
            return ret
        else:
            ret = Buffer()
            to_remove = 0
            for chunk in self._chunks:
                chunk_length = chunk.length()
                if nbytes < chunk_length:
                    if nbytes:
                        ret._add_chunk(chunk.clone_partial(nbytes))
                        chunk.consume(nbytes)
                    break
                else:
                    nbytes -= chunk_length
                    ret._add_chunk(chunk)
                    to_remove += 1

            if to_remove == self._chunks_length:
                self._chunks_clear()
                self._chunks_length = 0
                self._last = None
            else:
                while to_remove:
                    # We don't call .close() here on chunks because either we still use them, or they have transfered ownership
                    self._chunks_popleft()
                    self._chunks_length -= 1
                    to_remove -= 1

            return ret

    def take_bytes(self, Py_ssize_t nbytes=-1):
        cdef:
            list ret
            object single_return
            Chunk last, chunk
            Py_ssize_t last_length, chunk_length, to_remove
        
        if nbytes < 0:
            nbytes = self._length
        else:
            nbytes = min(nbytes, self._length)

        self._length -= nbytes

        if nbytes == 0 or self._chunks_length == 0:
            return b''
        elif self._chunks_length == 1:
            last = self._last
            last_length = last.length()
            if nbytes == last_length:
                single_return = last.readable().tobytes()
                last.close()
                self._chunks_clear()
                self._chunks_length = 0
                self._last = None
            else:
                single_return = last.readable_partial(nbytes).tobytes()
                last.consume(nbytes)
            return single_return
        else:
            ret = []
            to_remove = 0
            for chunk in self._chunks:
                chunk_length = chunk.length()
                if nbytes < chunk_length:
                    if nbytes:
                        ret.append(chunk.readable_partial(nbytes))
                        chunk.consume(nbytes)
                    break
                else:
                    nbytes -= chunk_length
                    ret.append(chunk.readable())
                    to_remove += 1

            single_return = b''.join(ret)

            while to_remove:
                self._chunks_popleft().close()
                self._chunks_length -= 1
                to_remove -= 1
            if self._chunks_length == 0:
                self._last = None

            return single_return

    def skip(self, Py_ssize_t nbytes=-1):
        cdef:
            Chunk last, chunk
            Py_ssize_t last_length, to_remove, chunk_length, ret

        if nbytes < 0:
            nbytes = len(self)
        else:
            nbytes = min(nbytes, len(self))

        self._length -= nbytes

        if nbytes == 0 or self._chunks_length == 0:
            return 0
        elif self._chunks_length == 1:
            last = self._last
            last_length = last.length()
            if nbytes == last_length:
                self._chunks_clear()
                self._chunks_length = 0
                last.close()
                self._last = None
            else:
                last.consume(nbytes)
            return nbytes
        else:
            ret = 0
            to_remove = 0
            for chunk in self._chunks:
                chunk_length = chunk.length()
                if nbytes < chunk_length:
                    if nbytes:
                        ret += nbytes
                        chunk.consume(nbytes)
                    break
                else:
                    chunk.close()
                    nbytes -= chunk_length
                    ret += chunk_length
                    to_remove += 1

            if to_remove == self._chunks_length:
                self._chunks_clear()
                self._chunks_length = 0
                self._last = None
            else:
                while to_remove:
                    self._chunks_popleft()
                    self._chunks_length -= 1
                    to_remove -= 1

            return ret

    # Write API
    def get_buffer(self, Py_ssize_t sizehint=-1):
        cdef:
            Chunk chunk

        #if sizehint == -1:
            #sizehint = self._current_size
        if not self._last or self._last.free() == 0:
            chunk = self._pool.get_chunk(2048)
            self._add_chunk_without_length(chunk)
            return chunk.writable()
        else:
            return self._last.writable()

    def buffer_written(self, Py_ssize_t nbytes):
        self._last.written(nbytes)
        self._length += nbytes
