# distutils: define_macros=CYTHON_TRACE_NOGIL=1
# cython: language_level=3, boundscheck=False, wraparound=False, initializedcheck=False, always_allow_keywords=False

include "consts.pxi"

cimport cython

# TODO (speed) we can initilize it only when Buffer has multiple chunks
from collections import deque
from .chunk cimport Chunk, Memory
from .pool cimport global_pool, Pool
from .bytearraywrapper cimport ByteArrayWrapper
from libc.string cimport memcpy, memcmp
# TODO this is bad, remove it and use a proper pointer arithemetic cast
from libc.stdint cimport uintptr_t
# TODO nogil ? really ?
cdef extern from "string.h" nogil:
    # TODO (windows) we can use bytearray.find instead of this (do benchmark between them)
    void *memmem(const void *, Py_ssize_t, const void *, Py_ssize_t)

cdef extern from "alloca.h":
    void *alloca(size_t size)

from cpython cimport buffer, Py_buffer
from cpython.buffer cimport PyBuffer_FillInfo
from cpython.bytes cimport PyBytes_AS_STRING


# TODO make sure there is close api for everything
# TODO how much defensive should we on general exceptions happening?
# TODO document that the code is async safe but not thread safe
# TODO text encoding per read ?
# TODO (api) should commands have an optional start index ?
# TODO set a maximum chunk size for buffer ?
# TODO have api to get the chunks buffer sfor stuff like writev !


# TODO any other way to return a zero length bytes ?
cdef bytes _empty_byte = bytes(b'')


# TODO (cython) is there a circular reference here ? If so so I need no_gc_clear ?
@cython.no_gc_clear
@cython.final
@cython.freelist(_FREELIST_SIZE)
cdef class Buffer:
    cdef:
        Pool _pool
        object _chunks
        object _chunks_append
        object _chunks_popleft
        object _chunks_clear
        Py_ssize_t _chunks_length
        Py_ssize_t _length
        Py_ssize_t _minimum_chunk_size, _current_chunk_size
        Py_ssize_t _number_of_lower_than_expected
        Chunk _last
        ByteArrayWrapper _bytearraywrapper
        bint _release_fast_to_pool

    # There is allot of lazy initilization of stuff because this class needs to be fast for the common usecase.
    def __cinit__(self, bint release_fast_to_pool=False, Py_ssize_t minimum_chunk_size=_DEFAULT_CHUNK_SIZE, Pool pool=global_pool):
        self._minimum_chunk_size = minimum_chunk_size
        self._current_chunk_size = minimum_chunk_size
        self._pool = pool
        self._release_fast_to_pool = release_fast_to_pool

    # TODO (misc) add counters for how much compact has been done
    cdef void _compact(self):
        cdef:
            Memory memory
            Chunk chunk, new_chunk
            char *buf
            Py_ssize_t length

        # TODO maybe for small chunks we can use PyMem_Malloc...
        if self._chunks_length > 1:
            # TODO should we put it in the pool (it's size may be too wonky, we can ofcourse take a larger portion and limit it)
            memory = Memory(self._length, None)
            new_chunk = Chunk(memory)
            buf = memory._buffer
            for chunk in self._chunks:
                length = chunk.length()
                chunk.memcpy(buf, 0, length)
                buf += length
                chunk.close()
            new_chunk._end = self._length
            self._chunks_clear()
            self._chunks_append(new_chunk)
            self._chunks_length = 1
            self._last = new_chunk

    def __getbuffer__(self, Py_buffer *buffer, int flags):
        if self._chunks_length > 1:
            self._compact()
        if self._chunks_length == 1:
            PyBuffer_FillInfo(buffer, self, <void *>(self._last._buffer + self._last._start), self._length, 1, flags)
        elif self._chunks_length == 0:
            PyBuffer_FillInfo(buffer, self, <void *>PyBytes_AS_STRING(_empty_byte), 0, 1, flags)

    def __len__(self):
        return self._length

    cdef inline bint _initialize_chunks(self):
        if self._chunks_length == 1 and self._chunks is None:
            # TODO (cython) can this fail ? do we need except ?
            chunk = deque()
            self._chunks = chunk
            self._chunks_append = chunk.append
            self._chunks_popleft = chunk.popleft
            self._chunks_clear = chunk.clear
            if self._last:
                self._chunks_append(self._last)
        return True

    cdef inline void _add_chunk(self, Chunk chunk):
        self._initialize_chunks()
        if self._chunks is not None:
            self._chunks_append(chunk)
        self._chunks_length += 1
        self._length += chunk.length()
        self._last = chunk

    cdef inline void _add_chunk_without_length(self, Chunk chunk):
        self._initialize_chunks()
        if self._chunks is not None:
            self._chunks_append(chunk)
        self._chunks_length += 1
        self._last = chunk

    # Read API
    # TODO (fix this to work properly) also benchmark if it's better to use bytearray's find instead (then it will be portable instead of memmem as well)
    def find(self, const unsigned char [::1] s, Py_ssize_t start=0, Py_ssize_t end=-1):
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
            #return self.bytearraywrapper().find(s, start, end)
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
                # TODO add it to the multi chunk part as well
                # We don't give it back here for optimization
                """ret._add_chunk(last)
                if self._chunks is not None:
                    self._chunks_clear()
                self._chunks_length = 0
                self._last = None"""
                # Is there any better place for optimization ere?
                if last.free() != 0:
                    ret._add_chunk(last.clone())
                    last.consume(nbytes)
                else:
                    ret._add_chunk(last)
                    if self._chunks is not None:
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
                if self._chunks is not None:
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

    def _debug(self):
        cdef:
            Chunk chunk
            list chunks
            dict ret

        chunks = []
        chunksiter = []
        if self._chunks_length == 1:
            chunksiter = [self._last]
        elif self._chunks_length > 1:
            chunksiter = self._chunks
        for chunk in chunksiter:
            chunks.append((chunk._start, chunk._end, chunk._writable, chunk._memory, chunk._memory.size, chunk._memory.reference))
        ret = {'chunks': chunks, 'current_chunk_size': self._current_chunk_size}
        return ret

    # Write API
    # TODO (document) we ignore sizehint for now...
    cpdef Chunk get_chunk(self, Py_ssize_t sizehint=-1):
        cdef:
            Chunk chunk
            bint can_reuse

        can_reuse = False
        if self._last:
            chunk = self._last
            # If we are the only users of this Chunk we can simply reset it.
            if chunk._memory.reference == 1:
                chunk._start = 0
                chunk._end = 0
                can_reuse = True
            elif chunk.free() != 0:
                can_reuse = True
    
        # The chunk will be writable as long as we created it (and this is not a subview)
        if can_reuse and chunk._writable:
            return chunk
        else:
            chunk = self._pool.get_chunk(self._current_chunk_size)
            #self._number_of_lower_than_expected = 0
            self._add_chunk_without_length(chunk)
            return chunk

    # TODO (safety) make sure that get_chunk was called !
    cpdef void chunk_written(self, Py_ssize_t nbytes):
        cdef:
            Chunk last
            Py_ssize_t last_size

        if nbytes == 0:
            return
        last = self._last
        last.written(nbytes)
        last_size = last.size
        self._length += nbytes
        if nbytes == last_size:
            self._current_chunk_size <<= 1
            self._number_of_lower_than_expected = 0
        elif self._current_chunk_size > self._minimum_chunk_size and nbytes < (last_size >> 1):
            self._number_of_lower_than_expected += 1
            if self._number_of_lower_than_expected > 10:
                self._number_of_lower_than_expected = 0
                self._current_chunk_size >>= 1

    def extend(self, data):
        cdef:
            Chunk chunk
            Py_ssize_t size, leftover, start
            Py_buffer buf, buf_data

        # TODO do I need to ask for buffer.PyBUF_C_CONTIGUOUS
        buffer.PyObject_GetBuffer(data, &buf_data, buffer.PyBUF_SIMPLE)
        # TODO this is annoying, but my only way around this is to bypass the except -1 in PyObject_GetBuffer defintion and handle it myself...
        try:
            leftover = buf_data.len
            start = 0
            while leftover:
                chunk = self.get_chunk()
                # TODO refactor this to memcpy other side ?
                buffer.PyObject_GetBuffer(chunk, &buf, buffer.PyBUF_SIMPLE | buffer.PyBUF_C_CONTIGUOUS)
                size = min(buf.len, leftover)
                memcpy(buf.buf, <const void *>&buf_data.buf[0] + start, size)
                buffer.PyBuffer_Release(&buf)
                self.chunk_written(size)
                leftover -= size
                start += size
        finally:
            buffer.PyBuffer_Release(&buf_data)

    # TODO (api) allow to specify here the new_pool / minimum_size ?
    @staticmethod
    def merge(buffers):
        cdef:
            Buffer ret, buffer
            Chunk chunk

        ret = Buffer()
        for buffer in buffers:
            if buffer._chunks_length == 1:
                ret._add_chunk(buffer._last.clone())
            elif buffer._chunks_length > 1:
                for chunk in buffer._chunks:
                    ret._add_chunk(chunk.clone())
        return ret

    cdef inline char *_unsafe_get_my_pointer(self):
        if self._chunks_length > 1:
            self._compact()
        if self._chunks_length == 1:
            return self._last._buffer + self._last._start
        elif self._chunks_length == 0:
            return PyBytes_AS_STRING(_empty_byte)

    cdef inline ByteArrayWrapper bytearraywrapper(self):
        cdef:
            ByteArrayWrapper baw

        if self._bytearraywrapper is None:
            baw = ByteArrayWrapper()
            self._bytearraywrapper = baw
        else:
            baw = self._bytearraywrapper
        baw._unsafe_set_memory_from_pointer(self._unsafe_get_my_pointer(), self._length)
        return baw

    # TODO (api) do we want to support all other comparisons as well ?
    def __eq__(self, other):
        return self.bytearraywrapper().__eq__(other)

    # TODO (api) which stringlib commands to support?
    def split(self, sep=None, maxsplit=-1):
        return self.bytearraywrapper().split(sep, maxsplit)

    def strip(self, bytes=None):
        return self.bytearraywrapper().strip(bytes)
