from libc.stdlib cimport malloc, free
from cpython cimport buffer
cimport cython


cdef extern from "Python.h":
    object PyMemoryView_FromMemory(char *mem, Py_ssize_t size, int flags)


cdef extern from "string.h" nogil:
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
        self._reference = 0

    def __dealloc__(self):
        if self._buffer is not NULL:
            free(self._buffer)

    cdef inline void increase(self):
        self._reference += 1

    cdef inline void decrease(self):
        self._reference -= 1
        if self._reference == 0:
            self._pool.return_memory(self)


@cython.no_gc_clear
@cython.final
@cython.freelist(254)
cdef class Chunk:
    def __cinit__(self, Memory memory):
        self._start = 0
        self._end = 0
        self._writable = True
        self._memory = memory
        self._memory.increase()

    def __dealloc__(self):
        if self._memory is not None:
            self._memory.decrease()

    cdef inline void close(self):
        if self._memory is not None:
            self._memory.decrease()
            self._memory = None

    cdef inline object writable(self):
        if not self._writable:
            raise RuntimeError('This chunk is a view into another chunk and is readonly')
        return PyMemoryView_FromMemory(self._memory._buffer + self._end, self._memory.size - self._end, buffer.PyBUF_WRITE)

    # TODO (safety) add sanity check ?
    cdef inline void written(self, Py_ssize_t nbytes):
        self._end += nbytes

    cdef inline Py_ssize_t size(self):
        return self._memory.size

    cdef inline Py_ssize_t free(self):
        return self._memory.size - self._end

    cdef inline Py_ssize_t length(self):
        return self._end - self._start

    # TODO why is this so much slower than the other option ? with bytes(result) instead of result.tobytes()
    #cdef inline const char [:] readable(self):
        #return <const char [:self._end - self._start]>(self._memory._buffer + self._start)

    cdef inline object readable(self):
        return PyMemoryView_FromMemory(self._memory._buffer + self._start, self._end - self._start, buffer.PyBUF_READ)

    cdef inline object readable_partial(self, Py_ssize_t end):
        return PyMemoryView_FromMemory(self._memory._buffer + self._start, end - self._start, buffer.PyBUF_READ)

    cdef inline void consume(self, Py_ssize_t nbytes):
        self._start += nbytes

    cdef inline Py_ssize_t find(self, const unsigned char [:] s, Py_ssize_t start=0, Py_ssize_t end=-1):
        cdef:
            char *ret
            Py_ssize_t s_length

        if end == -1:
            end = self._end
        else:
            end = min(self._start + end, self._end)
        s_length = len(s)
        if s_length == 1:
            ret = <char *>memchr(self._memory._buffer + self._start + start, s[0], end)
        else:
            # TODO is this the correct way to do this ?
            ret = <char *>memmem(self._memory._buffer + self._start + start, end, <const void *>&s[0], s_length)
        if ret == NULL:
            return -1
        return <Py_ssize_t>(ret - self._memory._buffer - self._start)

    cdef inline Chunk clone(self):
        ret = Chunk(self._memory)
        ret._start = self._start
        ret._end = self._end
        ret._writable = False
        return ret

    cdef inline Chunk clone_partial(self, Py_ssize_t end):
        end = min(self._start + end, self._end)
        ret = Chunk(self._memory)
        ret._start = self._start
        ret._end = end
        ret._writable = False
        return ret

    cdef inline uintptr_t __raw_address_start(self):
        return <uintptr_t>(self._memory._buffer + self._start)

    cdef inline uintptr_t __raw_address_end(self):
        return <uintptr_t>(self._memory._buffer + self._end)
