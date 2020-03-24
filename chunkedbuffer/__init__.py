from .api import Pool, Pipe, PartialReadError

__all__ = ['Pool', 'Pipe', 'PartialReadError']

try:
    from .streams import ChunkedBufferStream
    __all__.append('ChunkedBufferStream')
except ImportError:
    pass

__version__ = '0.0.1a1'
