# This works with Python 3 defintion only (ob_start) altough a Python 2 compatible version can be done.
cdef extern from "Python.h":
    ctypedef struct PyVarObject:
        Py_ssize_t ob_size

    ctypedef struct PyByteArrayObject:
        Py_ssize_t ob_alloc
        char *ob_bytes
        char *ob_start


# TODO if you plan on using this, do not allow for modifing commands to be run on it.
cdef class ByteArrayWrapper(bytearray):
    def __dealloc__(self):
        (<PyVarObject *>self).ob_size = 0
        (<PyByteArrayObject *>self).ob_alloc = 0
        (<PyByteArrayObject *>self).ob_bytes = NULL
        (<PyByteArrayObject *>self).ob_start = NULL

    cdef void _unsafe_set_memory_from_pointer(self, char *ptr, Py_ssize_t length):
        (<PyVarObject *>self).ob_size = length
        (<PyByteArrayObject *>self).ob_alloc = length
        (<PyByteArrayObject *>self).ob_bytes = ptr
        (<PyByteArrayObject *>self).ob_start = ptr
