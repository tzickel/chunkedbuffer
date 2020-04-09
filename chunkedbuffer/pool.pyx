from collections import deque
cimport cython


cdef class Pool:
    cdef Chunk get_chunk(self, Py_ssize_t size):
        raise NotImplementedError()

    cdef void return_memory(self, Memory memory):
        raise NotImplementedError()


# TODO (cython) implment dealloc
@cython.final
cdef class SameSizePool:
    def __cinit__(self, Py_ssize_t size):
        self._size = size
        self._queue = deque()
        self._queue_append = self._queue.append
        self._queue_pop = self._queue.pop
        self._length = 0

    cdef Chunk get_chunk(self, Py_ssize_t size):
        if self._length:
            self._length -= 1
            return Chunk(self._queue_pop())
        return Chunk(Memory(self._size, self))
    
    cdef void return_memory(self, Memory memory):
        self._length += 1
        self._queue_append(memory)


@cython.final
cdef class UnboundedPool:
    def __cinit__(self):
        self._memory = {}

    cdef Chunk get_chunk(self, Py_ssize_t size):
        size = 1 << (size - 1).bit_length()
        memory = self._memory.get(size)

        if not memory:
            return Chunk(Memory(size, self))
        else:
            return Chunk(memory.pop())

    cdef void return_memory(self, Memory memory):
        self._memory.setdefault(memory.size, deque()).append(memory)

    def reset(self):
        # TODO is this sufficient ?
        self._memory = {}


#global_pool = UnboundedPool()
global_pool = SameSizePool(2**14)
