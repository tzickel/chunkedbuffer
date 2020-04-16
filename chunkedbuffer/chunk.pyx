# distutils: define_macros=CYTHON_TRACE_NOGIL=1
# cython: language_level=3, boundscheck=False, wraparound=False, initializedcheck=False, always_allow_keywords=False

include "consts.pxi"

from libc.stdlib cimport malloc, free
from libc.string cimport memcpy
from cpython cimport buffer, Py_buffer
cimport cython


cdef extern from "Python.h":
    object PyMemoryView_FromMemory(char *mem, Py_ssize_t size, int flags)


cdef extern from "string.h":
    void *memchr(const void *, int, Py_ssize_t)
    # TODO (cython) what to do on platforms where this does not exist....
    void *memmem(const void *, Py_ssize_t, const void *, Py_ssize_t)


@cython.no_gc_clear
@cython.final
cdef class Memory:
    def __cinit__(self, Py_ssize_t size, Pool pool):
        self.size = size
        self._buffer = <char *>malloc(size)
        if self._buffer is NULL:
            raise MemoryError()
        self._pool = pool
        self.reference = 0

    def __dealloc__(self):
        if self._buffer is not NULL:
            free(self._buffer)

    cdef inline void increase(self):
        self.reference += 1

    cdef inline void decrease(self):
        self.reference -= 1
        # TODO ref counting should take care, but if no pool, we can just free the memory now.
        if self.reference == 0 and self._pool is not None:
            self._pool.return_memory(self)


@cython.no_gc_clear
@cython.final
@cython.freelist(_FREELIST_SIZE)
cdef class Chunk:
    def __cinit__(self, Memory memory):
        self._memory = memory
        self.size = memory.size
        self._buffer = memory._buffer
        self._start = 0
        self._end = 0
        self._writable = True
        self._memory.increase()
        self._strides[0] = 1

    def __dealloc__(self):
        if self._memory is not None:
            self._memory.decrease()
            self._memory = None

    cdef inline void close(self):
        if self._memory is not None:
            self._memory.decrease()
            self._memory = None

    cdef inline bint written(self, Py_ssize_t nbytes) except 0:
        if nbytes < 0 or nbytes > (self.size - self._end):
            raise ValueError('Tried to write an invalid length %d' % nbytes)
        self._end += nbytes
        return 1

    cdef inline Py_ssize_t free(self):
        return self.size - self._end

    cdef inline Py_ssize_t length(self):
        return self._end - self._start

    # TODO why is this so much slower than the other option ? with bytes(result) instead of result.tobytes()
    #cdef inline const char [:] readable(self):
        #return <const char [:self._end - self._start]>(self._buffer + self._start)

    cdef inline object readable(self):
        return PyMemoryView_FromMemory(<char *>self._buffer + self._start, self._end - self._start, buffer.PyBUF_READ)

    cdef inline object readable_partial(self, Py_ssize_t length):
        return PyMemoryView_FromMemory(<char *>self._buffer + self._start, length, buffer.PyBUF_READ)

    cdef inline void consume(self, Py_ssize_t nbytes):
        self._start += nbytes

    cdef inline Py_ssize_t find(self, const unsigned char [::1] s, Py_ssize_t start=0, Py_ssize_t end=-1):
        cdef:
            char *ret
            Py_ssize_t s_length

        if end == -1:
            end = self._end
        else:
            end = min(self._start + end, self._end)
        s_length = len(s)
        if s_length == 1:
            ret = <char *>memchr(self._buffer + self._start + start, s[0], end)
        elif s_length != 0:
            # TODO is this the correct way to do this ?
            ret = <char *>memmem(self._buffer + self._start + start, end, <const void *>&s[0], s_length)
        else:
            # TODO is this ok ?
            if start <= end:
                return self._start + start
            else:
                return -1
        if ret == NULL:
            return -1
        return <Py_ssize_t>(ret - self._buffer - self._start)

    cdef inline Chunk clone(self):
        cdef:
            Chunk ret

        ret = Chunk(self._memory)
        ret._start = self._start
        ret._end = self._end
        ret._writable = False
        return ret

    cdef inline Chunk clone_partial(self, Py_ssize_t length):
        cdef:
            Chunk ret

        ret = Chunk(self._memory)
        ret._start = self._start
        ret._end = self._start + length
        ret._writable = False
        return ret

    cdef inline Py_ssize_t memcpy(self, void *dest, Py_ssize_t start, Py_ssize_t length):
        if start < 0:
            start = self._end - start + 1
            if start < self._start:
                return 0
        else:
            start += self._start
        length = min(self._end - start, length)
        memcpy(dest, self._buffer + start, length)
        return length

    # TODO use buffer.PyBuffer_FillInfo
    def __getbuffer__(self, Py_buffer *buffer, int flags):
        if self._memoryview_taken > 0:
            raise BufferError("Please release previous buffer taken")
        if self._writable == False:
            raise BufferError("This piece of chunk is readonly")
        buffer.buf = &(self._buffer[self._end])
        buffer.format = 'B'
        buffer.internal = NULL
        buffer.itemsize = 1
        buffer.len = self.size - self._end
        buffer.ndim = 1
        buffer.obj = self
        buffer.readonly = 0
        self._shape[0] = self.size - self._end
        buffer.shape = self._shape
        buffer.strides = self._strides
        buffer.suboffsets = NULL
        self._memoryview_taken += 1

    def __releasebuffer__(self, Py_buffer *buffer):
        self._memoryview_taken -= 1

    # This is a hack fix to make SSL recv_into work..... this is the length of leftover writable.
    def __len__(self):
        return self.size - self._end
