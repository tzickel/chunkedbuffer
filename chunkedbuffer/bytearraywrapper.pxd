cdef class ByteArrayWrapper(bytearray):
    cdef inline void _unsafe_set_memory_from_pointer(self, char *ptr, Py_ssize_t length)
