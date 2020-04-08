from .chunk cimport Memory


cdef class SameSizePool:
    cdef size_t _size
    cdef object _queue

    cdef return_memory(self, Memory memory)


cdef SameSizePool global_pool
