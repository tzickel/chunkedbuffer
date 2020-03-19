from .api import Pool, Pipe

__all__ = ['Pool', 'Pipe']

try:
    from .streams import ChunkedBufferStream
except ImportError:
    __all__.append('ChunkedBufferStream')

__version__ = '0.0.1a1'
