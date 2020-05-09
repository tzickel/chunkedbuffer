from .chunk cimport MemoryBySize, Chunk
cimport cython


cdef class Pool:
    cdef Chunk get_chunk(self, size)
    cdef void return_memory(self, MemoryBySize memory)


cdef class SameSizePool(Pool):
    cdef:
        Py_ssize_t _size
        object _queue
        object _queue_append
        object _queue_pop
        Py_ssize_t _length

    cdef Chunk get_chunk(self, size)
    cdef void return_memory(self, MemoryBySize memory)


cdef class UnboundedPool(Pool):
    cdef:
        dict _memory

    cdef Chunk get_chunk(self, size)
    cdef void return_memory(self, MemoryBySize memory)


cdef Pool global_pool
