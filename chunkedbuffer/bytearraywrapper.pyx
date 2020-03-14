# distutils: define_macros=CYTHON_TRACE_NOGIL=1
# cython: language_level=3, boundscheck=False, wraparound=False, initializedcheck=False, always_allow_keywords=False

include "consts.pxi"

cimport cython


# This works with Python 3 defintion only (ob_start) altough a Python 2 compatible version can be done.
cdef extern from "Python.h":
    ctypedef struct PyVarObject:
        Py_ssize_t ob_size

    ctypedef struct PyByteArrayObject:
        Py_ssize_t ob_alloc
        char *ob_bytes
        char *ob_start


@cython.final
@cython.freelist(_FREELIST_SIZE)
# If you use this for your project, do not allow modifing commands to be used.
cdef class ByteArrayWrapper(bytearray):
    def __dealloc__(self):
        (<PyVarObject *>self).ob_size = 0
        (<PyByteArrayObject *>self).ob_alloc = 0
        (<PyByteArrayObject *>self).ob_bytes = NULL
        (<PyByteArrayObject *>self).ob_start = NULL

    cdef inline void _unsafe_set_memory_from_pointer(self, char *ptr, Py_ssize_t length):
        (<PyVarObject *>self).ob_size = length
        (<PyByteArrayObject *>self).ob_alloc = length
        (<PyByteArrayObject *>self).ob_bytes = ptr
        (<PyByteArrayObject *>self).ob_start = ptr
