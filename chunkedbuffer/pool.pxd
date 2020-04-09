from .chunk cimport Memory, Chunk


cdef class Pool:
    cdef Chunk get_chunk(self, size_t size)
    cdef void return_memory(self, Memory memory)


cdef class SameSizePool(Pool):
    cdef size_t _size
    cdef object _queue

    cdef Chunk get_chunk(self, size_t size)
    cdef void return_memory(self, Memory memory)


cdef SameSizePool global_pool
