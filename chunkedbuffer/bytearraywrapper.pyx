cdef extern from "Python.h":
    ctypedef struct PyVarObject:
        Py_ssize_t ob_size

    ctypedef struct PyByteArrayObject:
        Py_ssize_t ob_alloc
        char *ob_bytes
        char *ob_start


# If you have a better idea on how to expose stringlib, feel free to open an issue...
cdef class ByteArrayWrapper:
    cdef:
        bytearray tmp_bytearray
        char *orig_ptr
        char *real_memory
        size_t real_length

    def __cinit__(self):
        self.tmp_bytearray = bytearray(b'tmp_bytearray')
        self.orig_ptr = (<PyByteArrayObject *>self.tmp_bytearray).ob_bytes

    def _resolve(self, const unsigned char [::1] data, str attr, *args, **kwargs):
        # While we do ob_alloc == ob_size, this shouldn't matter since all stringlib functionality uses ob_size
        (<PyVarObject *>self.tmp_bytearray).ob_size = len(data)
        (<PyByteArrayObject *>self.tmp_bytearray).ob_alloc = len(data)
        (<PyByteArrayObject *>self.tmp_bytearray).ob_bytes = <char *>&data[0]
        (<PyByteArrayObject *>self.tmp_bytearray).ob_start = <char *>&data[0]
        try:
            return getattr(self.tmp_bytearray, attr)(*args, **kwargs)
        finally:
            (<PyVarObject *>self.tmp_bytearray).ob_size = 13
            (<PyByteArrayObject *>self.tmp_bytearray).ob_alloc = 14
            (<PyByteArrayObject *>self.tmp_bytearray).ob_bytes = self.orig_ptr
            (<PyByteArrayObject *>self.tmp_bytearray).ob_start = self.orig_ptr

    def equals(self, first, second):
        return self._resolve(first, '__eq__', second)
