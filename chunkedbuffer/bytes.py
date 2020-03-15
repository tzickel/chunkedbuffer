import ctypes


_PyBytes_FromStringAndSize = ctypes.pythonapi.PyBytes_FromStringAndSize
_PyBytes_FromStringAndSize.restype = ctypes.py_object
_PyBytes_FromStringAndSize.argtypes = ctypes.c_void_p, ctypes.c_ssize_t
_PyBytes_AsString = ctypes.pythonapi.PyBytes_AsString
_PyBytes_AsString.restype = ctypes.c_void_p
_PyBytes_AsString.argtypes = ctypes.py_object, 
_PyByteArray_AsString = ctypes.pythonapi.PyByteArray_AsString
_PyByteArray_AsString.restype = ctypes.c_void_p
_PyByteArray_AsString.argtypes = ctypes.py_object,


# TODO do I need to manually put a NULL in the end ?
class CreateBytes:
    def __init__(self, size):
        self._data = _PyBytes_FromStringAndSize(None, size)
        self._ptr = _PyBytes_AsString(self._data)

    def append(self, chunk, length=None):
        data, start, end = chunk.raw()
        dataptr = _PyByteArray_AsString(data)
        if length is None:
            length = end - start
        p = self._ptr
        ctypes.memmove(p, dataptr + start, length)
        self._ptr = p + length

    def materialize(self):
        # TODO is reference counting ok ?
        ret = self._data
        self._data = None
        return ret
