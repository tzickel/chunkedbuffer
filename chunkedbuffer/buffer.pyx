# distutils: define_macros=CYTHON_TRACE_NOGIL=1
# cython: language_level=3, boundscheck=False, wraparound=False, initializedcheck=False, always_allow_keywords=False

include "consts.pxi"

cimport cython

from collections import deque
from .chunk cimport Chunk, Memory
from .pool cimport global_pool, Pool
from .bytearraywrapper cimport ByteArrayWrapper
from libc.string cimport memcpy, memcmp

# TODO in windows I need malloc.h ?
cdef extern from "alloca.h":
    void *alloca(size_t size)

from cpython cimport buffer, Py_buffer
from cpython.buffer cimport PyBuffer_FillInfo
from cpython.bytes cimport PyBytes_AS_STRING

# TODO how much defensive should we on general exceptions happening?
# TODO document that the code is async safe but not thread safe
# TODO text encoding per read ?
# TODO (api) should commands have an optional start index ?
# TODO we can invalidate cache on BAW and on takeuntil


# TODO any other way to return a zero length bytes ?
cdef bytes _empty_byte = bytes(b'')


# TODO (cython) is there a circular reference here ? If so so I need no_gc_clear ?
@cython.no_gc_clear
@cython.final
@cython.freelist(_FREELIST_SIZE)
cdef class Buffer:
    cdef:
        Pool _pool
        object _chunks, _chunks_append, _chunks_popleft, _chunks_clear
        Py_ssize_t _chunks_length
        Py_ssize_t _length
        Py_ssize_t _minimum_chunk_size, _current_chunk_size
        Py_ssize_t _number_of_lower_than_expected
        Chunk _last
        ByteArrayWrapper _bytearraywrapper
        bint _release_fast_to_pool
        object _takeuntil_cache_object
        Py_ssize_t _takeuntil_cache_index
        bint _not_origin

    # There is allot of lazy initilization of stuff because this class needs to be fast for the common usecase.
    # TODO add maximum_chunk_size here as well
    def __cinit__(self, bint release_fast_to_pool=False, Py_ssize_t minimum_chunk_size=_DEFAULT_CHUNK_SIZE, Pool pool=global_pool):
        self._minimum_chunk_size = minimum_chunk_size
        self._current_chunk_size = minimum_chunk_size
        self._pool = pool
        self._release_fast_to_pool = release_fast_to_pool

    # TODO (misc) add counters for how much compact has been done
    cdef bint _compact(self) except False:
        cdef:
            Memory memory
            Chunk chunk, new_chunk
            char *buf
            Py_ssize_t length

        # TODO maybe for small chunks we can use PyMem_Malloc...
        if self._chunks_length > 1:
            # TODO should we put it in the pool (it's size may be too wonky, we can ofcourse take a larger portion and limit it)
            memory = Memory(self._length, None)
            new_chunk = Chunk()
            new_chunk._init(memory)
            buf = memory._buffer
            for chunk in self._chunks:
                length = chunk._end - chunk._start
                chunk.copy_to(buf, 0, length)
                buf += length
            new_chunk._end = self._length
            with cython.optimize.unpack_method_calls(False):
                self._chunks_clear()
                self._chunks_append(new_chunk)
            self._chunks_length = 1
            self._last = new_chunk
        return True

    def __getbuffer__(self, Py_buffer *buffer, int flags):
        if self._chunks_length > 1:
            self._compact()
        if self._chunks_length == 1:
            PyBuffer_FillInfo(buffer, self, <void *>(self._last._buffer + self._last._start), self._length, 1, flags)
        elif self._chunks_length == 0:
            PyBuffer_FillInfo(buffer, self, <void *>PyBytes_AS_STRING(_empty_byte), 0, 1, flags)

    def __len__(self):
        return self._length

    # TODO (cython) validate that bint except False is ok
    cdef inline bint _initialize_chunks(self) except False:
        with cython.optimize.unpack_method_calls(False):
            chunk = deque()
        self._chunks = chunk
        self._chunks_append = chunk.append
        self._chunks_popleft = chunk.popleft
        self._chunks_clear = chunk.clear
        if self._last is not None:
            with cython.optimize.unpack_method_calls(False):
                self._chunks_append(self._last)
        return True

    cdef inline bint _add_chunk(self, Chunk chunk) except False:
        self._not_origin = True
        chunk._readonly = True
        if self._chunks_length == 1 and self._chunks is None:
            self._initialize_chunks()
        if self._chunks_append is not None:
            with cython.optimize.unpack_method_calls(False):
                self._chunks_append(chunk)
        self._chunks_length += 1
        self._length += chunk._end - chunk._start
        self._last = chunk
        return True

    cdef inline bint _add_chunk_without_length(self, Chunk chunk) except False:
        if self._chunks_length == 1 and self._chunks is None:
            self._initialize_chunks()
        if self._chunks_append is not None:
            with cython.optimize.unpack_method_calls(False):
                self._chunks_append(chunk)
        self._chunks_length += 1
        self._last = chunk
        return True

    # Read API
    # TODO (optimization) cache last check
    # TODO It's much simpler to search for \n and return till that, so for now we are doing that (no include_seperator option)
    """def takeline(self):
        cdef:
            Py_ssize_t idx, res_idx
            Buffer ret
            int prev_chunk_ends_with_cr

        if self._chunks_length == 0:
            return None
        elif self._chunks_length == 1:
            idx = self.bytearraywrapper().find(b'\n')
            if idx == -1:
                return None
            return self.take(idx + 1)
            if include_seperator:
                return self.take(idx + 1)
            else:
                if idx == 0:
                    self.skip(1)
                    return Buffer()
                else:
                    if self._last._buffer[idx - 1] == 13:
                        ret = self.take(idx - 1)
                        self.skip(2)
                    else:
                        ret = self.take(idx)
                        self.skip(1)
                    return ret
        else:
            res_idx = 0
            prev_chunk_ends_with_cr = 0 # First chunk
            for chunk in self._chunks:
                chunk_length = chunk.length()
                idx = self.bytearraywrapper_with_address_and_length(<char *>chunk._buffer + chunk._start, chunk_length).find(b'\n')
                if idx == -1:
                    if chunk._buffer[chunk._start + chunk_length] == 13:
                        prev_chunk_ends_with_cr = 1 # Yes
                    else:
                        prev_chunk_ends_with_cr = 2 # No
                    res_idx += chunk_length
                else:
                    res_idx += idx
                    return res_idx
            return -1"""

    cpdef Py_ssize_t find(self, object s, Py_ssize_t start=0, Py_ssize_t end=-1) except -2:
        cdef:
            Py_buffer buf_s
            Py_ssize_t res_idx, idx, chunk_length, prev_chunk_length, how_much, how_much1, how_much2
            Chunk chunk, prev_chunk
            unsigned char* tmp
            ByteArrayWrapper baw

        if start < 0 or end < -1:
            raise ValueError("Not supporting negative indexes")
        if end == -1:
            end = self._length

        if self._chunks_length == 0:
            if len(s) == 0 and start == 0:
                return 0
            return -1
        elif self._chunks_length == 1:
            return self.bytearraywrapper().find(s, start, end)
        else:
            buffer.PyObject_GetBuffer(s, &buf_s, buffer.PyBUF_SIMPLE)
            try:
                if buf_s.len == 1:
                    res_idx = 0
                    for chunk in self._chunks:
                        chunk_length = chunk._end - chunk._start
                        if start >= chunk_length:
                            res_idx += chunk_length
                            start -= chunk_length
                            end -= chunk_length
                            continue
                        if end <= 0:
                            break
                        idx = self.bytearraywrapper_with_address_and_length(<char *>chunk._buffer + chunk._start, chunk_length).find(s, start, end)
                        if idx == -1:
                            res_idx += chunk_length
                            start = 0
                            end -= chunk_length
                        else:
                            res_idx += idx
                            return res_idx
                    return -1
                else:
                    # TODO we use alloca here for speed, maybe if the delimiter is too big, use malloc instead ?
                    # TODO if buf_s.len is more than minimum_chunk_size, then just abort now (or simply run compact and normal find)
                    tmp = <unsigned char*>alloca((buf_s.len - 1) * 2)
                    res_idx = 0
                    prev_chunk = None
                    for chunk in self._chunks:
                        chunk_length = chunk._end - chunk._start
                        if prev_chunk is not None:
                            how_much1 = prev_chunk.copy_to(tmp, -buf_s.len + 1, buf_s.len - 1)
                            how_much2 = chunk.copy_to(tmp + how_much1, 0, buf_s.len - 1)
                            how_much = how_much1 + how_much2
                            if how_much < buf_s.len:
                                # TODO is or == ?
                                if chunk is self._last:
                                    return -1
                                else:
                                    # We rather bug out then miss, this should not happen in real use where s < minimum_chunk_size?
                                    raise NotImplementedError()
                            idx = self.bytearraywrapper_with_address_and_length(<char *>tmp, how_much).find(s)
                            if idx != -1:
                                return res_idx + idx - how_much1
                        if start >= chunk_length:
                            res_idx += chunk_length
                            start -= chunk_length
                            end -= chunk_length
                            prev_chunk = chunk
                            prev_chunk_length = chunk_length
                            continue
                        if end <= 0:
                            break
                        idx = self.bytearraywrapper_with_address_and_length(chunk._buffer + chunk._start, chunk_length).find(s, start, end)
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
            finally:
                buffer.PyBuffer_Release(&buf_s)

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
                chunk_length = chunk._end - chunk._start
                if nbytes < chunk_length:
                    if nbytes:
                        ret._add_chunk(chunk.clone_partial(nbytes))
                    break
                else:
                    nbytes -= chunk_length
                    ret._add_chunk(chunk.clone())
            return ret

    cpdef Buffer take(self, Py_ssize_t nbytes=-1):
        cdef:
            Buffer ret
            Chunk last, chunk
            Py_ssize_t last_length, chunk_length, to_remove

        # TODO we could optimize the index instead
        self._takeuntil_cache_object = None
        
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
            last_length = last._end - last._start
            if nbytes == last_length:
                # TODO add it to the multi chunk part as well
                # We don't give it back here for optimization
                """ret._add_chunk(last)
                if self._chunks is not None:
                    self._chunks_clear()
                self._chunks_length = 0
                self._last = None"""
                # Is there any better place for optimization here?
                if last.size - last._end != 0:
                    ret._add_chunk(last.clone())
                    last._start += nbytes
                else:
                    ret._add_chunk(last)
                    if self._chunks is not None:
                        with cython.optimize.unpack_method_calls(False):
                            self._chunks_clear()
                    self._chunks_length = 0
                    self._last = None
            else:
                ret._add_chunk(last.clone_partial(nbytes))
                last._start += nbytes
            return ret
        else:
            ret = Buffer()
            to_remove = 0
            for chunk in self._chunks:
                chunk_length = chunk._end - chunk._start
                if nbytes < chunk_length:
                    if nbytes:
                        ret._add_chunk(chunk.clone_partial(nbytes))
                        chunk._start += nbytes
                    break
                else:
                    nbytes -= chunk_length
                    ret._add_chunk(chunk)
                    to_remove += 1

            if to_remove == self._chunks_length:
                with cython.optimize.unpack_method_calls(False):
                    self._chunks_clear()
                self._chunks_length = 0
                self._last = None
            else:
                while to_remove:
                    with cython.optimize.unpack_method_calls(False):
                        self._chunks_popleft()
                    self._chunks_length -= 1
                    to_remove -= 1

            return ret

    cpdef Py_ssize_t skip(self, Py_ssize_t nbytes=-1):
        cdef:
            Chunk last, chunk
            Py_ssize_t last_length, to_remove, chunk_length, ret

        # TODO we can optimize this
        self._takeuntil_cache_object = None

        if nbytes < 0:
            nbytes = self._length
        else:
            nbytes = min(nbytes, self._length)

        self._length -= nbytes

        if nbytes == 0 or self._chunks_length == 0:
            return 0
        elif self._chunks_length == 1:
            last = self._last
            last_length = last._end - last._start
            if nbytes == last_length:
                if last._memory.reference == 1:
                    last._start = 0
                    last._end = 0
                else:
                    if self._chunks is not None:
                        with cython.optimize.unpack_method_calls(False):
                            self._chunks_clear()
                    self._chunks_length = 0
                    self._last = None
            else:
                last._start += nbytes
            return nbytes
        else:
            ret = 0
            to_remove = 0
            for chunk in self._chunks:
                chunk_length = chunk._end - chunk._start
                if nbytes < chunk_length:
                    if nbytes:
                        ret += nbytes
                        chunk._start += nbytes
                    break
                else:
                    nbytes -= chunk_length
                    ret += chunk_length
                    to_remove += 1

            if to_remove == self._chunks_length:
                with cython.optimize.unpack_method_calls(False):
                    self._chunks_clear()
                self._chunks_length = 0
                self._last = None
            else:
                while to_remove:
                    with cython.optimize.unpack_method_calls(False):
                        self._chunks_popleft()
                    self._chunks_length -= 1
                    to_remove -= 1

            return ret

    # TODO this requires len(s) for now
    def takeuntil(self, s, bint include_s=False):
        cdef:
            Py_ssize_t idx

        if self._takeuntil_cache_object == s:
            idx = self.find(s, self._takeuntil_cache_index)
        else:
            self._takeuntil_cache_object = None
            idx = self.find(s)
        if idx == -1:
            self._takeuntil_cache_object = s
            self._takeuntil_cache_index = max(0, self._length - len(s) + 1)
            return None
        self._takeuntil_cache_object = None
        if include_s:
            return self.take(idx + len(s))
        else:
            ret = self.take(idx)
            self.skip(len(s))
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
    # buffer.pyx:475:25: Exception clause not allowed for function returning Python object ??
    cpdef Chunk get_chunk(self, Py_ssize_t sizehint=-1):
        cdef:
            Chunk chunk
            bint can_reuse

        can_reuse = False
        chunk = self._last
        if chunk is not None:
            # If we are the only users of this Chunk we can simply reset it.
            if chunk._memory.reference == 1 and self._length == 0:
                chunk._start = 0
                chunk._end = 0
                can_reuse = True
            elif chunk.size - chunk._end != 0:
                can_reuse = True
    
        # The chunk will be writable as long as we created it (and this is not a subview)
        if can_reuse and chunk._readonly is False:
            return chunk
        else:
            chunk = self._pool.get_chunk(self._current_chunk_size)
            #self._number_of_lower_than_expected = 0
            self._add_chunk_without_length(chunk)
            return chunk

    # TODO (safety) make sure that get_chunk was called !
    cpdef bint chunk_written(self, Py_ssize_t nbytes) except False:
        cdef:
            Chunk last
            Py_ssize_t last_size

        if nbytes == 0:
            return True
        last = self._last
        last_size = last.size
        # TODO throw error here if writing past end ?
        nbytes = min(nbytes, last_size - last._end)
        last._end += nbytes
        self._length += nbytes
        if nbytes == last_size:
            self._current_chunk_size <<= 1
            self._number_of_lower_than_expected = 0
        elif self._current_chunk_size > self._minimum_chunk_size and nbytes < (last_size >> 1):
            self._number_of_lower_than_expected += 1
            if self._number_of_lower_than_expected > 10:
                self._number_of_lower_than_expected = 0
                self._current_chunk_size >>= 1
        return True

    def extend(self, data):
        cdef:
            Chunk chunk
            Py_ssize_t size, leftover, start
            Py_buffer buf, buf_data

        buffer.PyObject_GetBuffer(data, &buf_data, buffer.PyBUF_SIMPLE)
        # TODO this is annoying, but my only way around this is to bypass the except -1 in PyObject_GetBuffer defintion and handle it myself...
        try:
            leftover = buf_data.len
            start = 0
            while leftover:
                chunk = self.get_chunk()
                # TODO refactor this to memcpy other side ?
                buffer.PyObject_GetBuffer(chunk, &buf, buffer.PyBUF_SIMPLE)
                size = min(buf.len, leftover)
                memcpy(buf.buf, <const char *>buf_data.buf + start, size)
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

    cdef inline ByteArrayWrapper bytearraywrapper_with_address_and_length(self, char *addr, Py_ssize_t length):
        cdef:
            ByteArrayWrapper baw

        if self._bytearraywrapper is None:
            baw = ByteArrayWrapper()
            self._bytearraywrapper = baw
        else:
            baw = self._bytearraywrapper
        baw._unsafe_set_memory_from_pointer(addr, length)
        return baw

    def chunks(self):
        # TODO do a better blocking behaviour of running .chunks() on a writable buffer (there should be a buffer distinction of readable and writable buffers as a whole)
        if not self._last._readonly:
            self._last._readonly = True
        if not self._not_origin:
            raise ValueError('Cannot get chunks of writable Buffer, .take() the data first')
        if self._chunks is not None:
            # TODO can we modify while the iter is given ?
            return iter(self._chunks)
        elif self._chunks_length == 1:
            return [self._last]
        else:
            return []

    # TODO (api) do we want to support all other comparisons as well ?
    def __eq__(self, other):
        cdef:
            Py_buffer buf
            void *ptr
            Py_ssize_t length
            Chunk chunk

        buffer.PyObject_GetBuffer(other, &buf, buffer.PyBUF_SIMPLE)
        try:
            if self._length != buf.len:
                return False
            if self._chunks_length == 1:
                return memcmp(self._unsafe_get_my_pointer(), buf.buf, self._length) == 0
            elif self._chunks_length == 0:
                return True
            else:
                ptr = buf.buf
                for chunk in self._chunks:
                    length = chunk._end - chunk._start
                    if memcmp(ptr, chunk._buffer + chunk._start, length) != 0:
                        return False
                    ptr += length
                return True
        finally:
            buffer.PyBuffer_Release(&buf)

    # TODO (api) which stringlib commands to support?
    def split(self, sep=None, maxsplit=-1):
        return self.bytearraywrapper().split(sep, maxsplit)

    def strip(self, bytes=None):
        return self.bytearraywrapper().strip(bytes)
