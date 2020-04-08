from .chunk cimport Memory, Chunk


cdef class SameSizePool:
    cdef size_t _size
    cdef object _queue

    cdef Chunk get_chunk(self, size_t size)
    cdef void return_memory(self, Memory memory)


cdef SameSizePool global_pool
