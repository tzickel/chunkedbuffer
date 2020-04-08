from libc.stdlib cimport malloc, free
from cpython cimport buffer
cimport cython
from .pool cimport SameSizePool


cdef extern from "Python.h":
    object PyMemoryView_FromMemory(char *mem, Py_ssize_t size, int flags)


cdef extern from "string.h" nogil:
    void *memchr(const void *, int, size_t)


# TODO pool can be the pool return function directly...
@cython.no_gc_clear
@cython.final
cdef class Memory:
    def __cinit__(self, size_t size, SameSizePool pool):
        self.size = size
        self._buffer = <char *>malloc(size)
        self._reference = 0

    def __init__(self, size_t size, SameSizePool pool):
        if not self._buffer:
            raise MemoryError()
        self._pool = pool

    def __dealloc__(self):
        if self._buffer:
            free(self._buffer)

    cdef increase(self):
        self._reference += 1

    cdef decrease(self):
        self._reference -= 1
        if self._reference == 0:
            self._pool.return_memory(self)


@cython.no_gc_clear
@cython.final
@cython.freelist(1000)
cdef class Chunk:
    def __cinit__(self, Memory memory):
        self._start = 0
        self._end = 0
        self._writable = True
        self._memory = memory
        self._memory.increase()

    def __dealloc__(self):
        self.close()

    def close(self):
        if self._memory:
            self._memory.decrease()
            self._memory = None

    def writable(self):
        if not self._writable:
            raise RuntimeError('This chunk is a view into another chunk and is readonly')
        return PyMemoryView_FromMemory(self._memory._buffer + self._end, self._memory.size - self._end, buffer.PyBUF_WRITE)

    def written(self, size_t nbytes):
        if not self._writable:
            raise RuntimeError('This chunk is a view into another chunk and is readonly')
        self._end += nbytes

    def size(self):
        return self._memory.size

    def free(self):
        return self._memory.size - self._end

    def length(self):
        return self._end - self._start

    def readable(self, size_t nbytes=-1):
        cdef size_t end
        if nbytes == -1:
            end = self._end
        else:
            end = min(self._start + nbytes, self._end)
        return PyMemoryView_FromMemory(self._memory._buffer + self._start, end, buffer.PyBUF_READ)

    def consume(self, size_t nbytes):
        self._start += nbytes

    def find(self, char *s, size_t start=0, size_t end=-1):
        cdef char *ret
        if end == -1:
            end = self._end
        else:
            end = min(self._start + end, self._end)
        if len(s) == 1:
            ret = <char *>memchr(self._memory._buffer + self._start + start, s[0], end)
        else:
            raise NotImplementedError()
        if ret == NULL:
            return -1
        return <size_t>(ret - self._memory._buffer - self._start)

    def part(self, size_t start=0, size_t end=-1):
        if end == -1:
            end = self._end
        else:
            end = min(self._start + end, self._end)
        ret = Chunk(self._memory)
        ret._start = self._start + start
        ret._end = end
        ret._writable = False
        return ret
