from .chunk cimport Memory, Chunk
cimport cython

cdef class Pool:
    cdef Chunk get_chunk(self, size_t size)
    cdef void return_memory(self, Memory memory)


cdef class SameSizePool(Pool):
    cdef:
        size_t _size
        object _queue
        object _queue_append
        object _queue_pop
        size_t _length

    cdef Chunk get_chunk(self, size_t size)
    cdef void return_memory(self, Memory memory)


cdef class UnboundedPool(Pool):
    cdef:
        size_t _size
        object _queue
        object _append
        object _pop

    cdef Chunk get_chunk(self, size_t size)
    cdef void return_memory(self, Memory memory)


cdef Pool global_pool
