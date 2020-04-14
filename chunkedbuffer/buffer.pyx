# distutils: define_macros=CYTHON_TRACE_NOGIL=1


from collections import deque
from .chunk cimport Chunk
from .pool cimport global_pool, Pool
cimport cython
from libc.string cimport memcpy
from cpython.mem cimport PyMem_Malloc, PyMem_Free
from libc.stdint cimport uintptr_t
# TODO nogil ? really ?
cdef extern from "string.h" nogil:
    # TODO (cython) what to do on platforms where this does not exist....
    void *memmem(const void *, Py_ssize_t, const void *, Py_ssize_t)

cdef extern from "alloca.h":
    void *alloca(size_t size)

from cpython cimport buffer, Py_buffer
from cpython.bytes cimport PyBytes_AS_STRING, PyBytes_FromStringAndSize

# TODO consistent function naming
# TODO make sure there is close api for everything
# TODO how much defensive should we on general exceptions happening ?
# TODO document that the code is async safe but not thread safe
# TODO text encoding per read ?
# TODO should commands have an optional start index ?
# TODO set a maximum chunk size for buffer ?

# TODO is this a good default size ?
_DEFAULT_CHUNK_SIZE = 2048


@cython.no_gc_clear
@cython.final
# TODO (cython) what is a good value to put here ?
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
        Py_ssize_t _minimum_buffer_size, _current_buffer_size
        Py_ssize_t _number_of_lower_than_expected
        Chunk _last

    # TODO maybe call buffer inside, get_chunk, and minimum_chunk_size
    def __cinit__(self, Py_ssize_t minimum_buffer_size=_DEFAULT_CHUNK_SIZE, Pool pool=global_pool):
        self._minimum_buffer_size = minimum_buffer_size
        self._current_buffer_size = minimum_buffer_size
        self._number_of_lower_than_expected = 0
        self._pool = pool
        chunk = deque()
        # TODO (cython) do I need to hold this refernece at all ?
        self._chunks = chunk
        self._chunks_append = chunk.append
        self._chunks_popleft = chunk.popleft
        self._chunks_clear = chunk.clear

    # TODO (cython) is there a circular reference here ? If so so I need no_gc_clear ?
    # TODO (cython) is this still called using the freelist or do we need to put this in __del__ ?
    def __dealloc__(self):
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

    cdef inline void close(self):
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

    # TODO (api) should we add __bytes__ as well ?
    def bytes(self):
        cdef:
            Chunk chunk
            bytes ret
            char *buf
            Py_ssize_t length

        if self._chunks_length == 1:
            ret = PyBytes_FromStringAndSize(NULL, self._length)
            if ret:
                self._last.memcpy(PyBytes_AS_STRING(ret), 0, self._length)
            return ret
        elif self._chunks_length == 0:
            return b''
        else:
            ret = PyBytes_FromStringAndSize(NULL, self._length)
            if ret:
                buf = PyBytes_AS_STRING(ret)
                for chunk in self._chunks:
                    length = chunk.length()
                    chunk.memcpy(buf, 0, length)
                    buf += length
            return ret

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
    def find(self, const unsigned char [:] s, Py_ssize_t start=0, Py_ssize_t end=-1):
        cdef:
            Chunk chunk, prev_chunk
            Py_ssize_t chunk_length, prev_chunk_length, res_idx, idx, len_s
            unsigned char* tmp
            uintptr_t ret

        len_s = len(s)

        if start < 0 or end < -1:
            raise ValueError("Not supporting negative indexes")
        if end == -1:
            end = self._length

        if self._chunks_length == 0:
            if len_s == 0 and start == 0:
                return 0
            return -1
        elif self._chunks_length == 1:
            return self._last.find(s, start, end)
        else:
            if len_s == 1:
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
                    idx = chunk.find(s, start, end)
                    if idx == -1:
                        res_idx += chunk_length
                        start = 0
                        end -= chunk_length
                    else:
                        res_idx += idx
                        return res_idx
                return -1
            else:
                tmp = <unsigned char*>alloca((len_s - 1) * 2)
                if not tmp:
                    raise MemoryError()
                prev_chunk = None
                prev_chunk_length = 0
                res_idx = 0
                for chunk in self._chunks:
                    chunk_length = chunk.length()
                    if prev_chunk:
                        # To simplify this code, we will fail if chunk_length is shorter than the string we are looking for
                        # TODO we need to be carefull here that both prev_chunk and chunk can hold this search string, or abort with an error !
                        #copy_from_first = 
                        #memcpy(tmp, <const void *>prev_chunk.__raw_address_end() - len_s + 1, len_s - 1)
                        #memcpy(tmp + len_s - 1, <const void *>chunk.__raw_address_start(), len_s - 1)
                        #chunk.memcpy(tmp, )
                        ret = <uintptr_t>memmem(tmp, (len_s - 1) * 2, <const void *>&s[0], len_s)
                        if ret:
                            ret = ret - (<uintptr_t>tmp) + res_idx - len_s + 1
                            return ret
                    if start >= chunk_length:
                        res_idx += chunk_length
                        start -= chunk_length
                        end -= chunk_length
                        prev_chunk = chunk
                        prev_chunk_length = chunk_length
                        continue
                    if end <= 0:
                        break
                    idx = chunk.find(s, start, end)
                    if idx == -1:
                        res_idx += chunk_length
                        start = 0
                        end -= chunk_length
                    else:
                        res_idx += idx
                        return res_idx
                    prev_chunk = chunk
                    prev_chunk_length = chunk_length
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
            return Buffer(self._minimum_buffer_size, self._pool)
        elif self._chunks_length == 1:
            ret = Buffer(self._minimum_buffer_size, self._pool)
            ret._add_chunk(self._last.clone_partial(nbytes))
            return ret
        else:
            ret = Buffer(self._minimum_buffer_size, self._pool)
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
            return self._last.readable_partial(nbytes).tobytes()
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
            return Buffer(self._minimum_buffer_size, self._pool)
        elif self._chunks_length == 1:
            ret = Buffer(self._minimum_buffer_size, self._pool)
            last = self._last
            last_length = last.length()
            if nbytes == last_length:
                # We don't give it back here for optimization
                # TODO add it to the multi chunk part as well
                if last.free() != 0:
                    ret._add_chunk(last.clone())
                    last.consume(nbytes)
                else:
                    ret._add_chunk(last)
                    self._chunks_clear()
                    self._chunks_length = 0
                    self._last = None
                """ret._add_chunk(last)
                self._chunks_clear()
                self._chunks_length = 0
                self._last = None"""
            else:
                ret._add_chunk(last.clone_partial(nbytes))
                last.consume(nbytes)
            return ret
        else:
            ret = Buffer(self._minimum_buffer_size, self._pool)
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
            nbytes = self._length
        else:
            nbytes = min(nbytes, self._length)

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

    def take_split(self, const unsigned char [:] sep, Py_ssize_t max=-1):
        cdef:
            list ret
            Py_ssize_t idx, took

        ret = []
        sep_length = len(sep)
        took = 0
        while True:
            idx = self.find(sep)
            if idx == -1 or (max >= 0 and took == max):
                break
            else:
                ret.append(self.take(idx))
                self.skip(sep_length)
        return ret

    def take_split_bytes(self, const unsigned char [:] sep, Py_ssize_t max=-1):
        cdef:
            list ret
            Py_ssize_t idx, took

        ret = []
        sep_length = len(sep)
        took = 0
        while True:
            idx = self.find(sep)
            if idx == -1 or (max >= 0 and took == max):
                break
            else:
                ret.append(self.take_bytes(idx))
                self.skip(sep_length)
        return ret

    def debug(self):
        cdef:
            Chunk chunk
            list ret

        ret = []
        for chunk in self._chunks:
            ret.append((chunk._start, chunk._end, chunk._writable, chunk._memory, chunk._memory._reference))
        return ret

    # Write API
    # TODO (document) we ignore sizehint for now...
    # TODO check if last chunk is not writable, then take a new one!
    def get_buffer(self, Py_ssize_t sizehint=-1):
        cdef:
            Chunk chunk

        if not self._last or self._last.free() == 0:
            chunk = self._pool.get_chunk(self._current_buffer_size)
            self._add_chunk_without_length(chunk)
            return chunk
        else:
            return self._last

    def buffer_written(self, Py_ssize_t nbytes):
        cdef:
            Chunk last
            Py_ssize_t last_size

        last = self._last
        last.written(nbytes)
        last_size = last.size
        self._length += nbytes
        if nbytes == last_size:
            self._current_buffer_size <<= 1
            self._number_of_lower_than_expected = 0
        elif self._current_buffer_size > self._minimum_buffer_size and nbytes < (last_size >> 1):
            self._number_of_lower_than_expected += 1
            if self._number_of_lower_than_expected > 10:
                self._number_of_lower_than_expected = 0
            self._current_buffer_size >>= 1

    # TODO we can optimize here to skip the memoryview at all
    def extend(self, const unsigned char [:] data):
        cdef:
            Chunk chunk
            Py_ssize_t size, leftover, start
            Py_buffer buf            

        leftover = len(data)
        start = 0
        while leftover:
            chunk = self.get_buffer()
            buffer.PyObject_GetBuffer(chunk, &buf, buffer.PyBUF_SIMPLE)
            size = min(buf.len, leftover)
            memcpy(buf.buf, <const void *>&data[0] + start, size)
            buffer.PyBuffer_Release(&buf)
            self.buffer_written(size)
            leftover -= size
            start += size

    # TODO (api) allow to specify here the new_pool / minimum_size ?
    @staticmethod
    def merge(buffers):
        cdef:
            Buffer ret, buffer
            Chunk chunk

        ret = Buffer()
        for buffer in buffers:
            for chunk in buffer._chunks:
                ret._add_chunk(chunk.clone())
        return ret

    @staticmethod
    def merge_bytes(buffers):
        cdef:
            list tmp
            Buffer buffer
            Chunk chunk

        tmp = []
        for buffer in buffers:
            for chunk in buffer._chunks:
                tmp.append(chunk.readable())
        return b''.join(tmp)
