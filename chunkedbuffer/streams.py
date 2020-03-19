from asyncio import Semaphore, Event, Lock, get_event_loop, ensure_future

from .api import Pipe

try:
    from asyncio import BufferedProtocol as BaseProtocol
except ImportError:
    from asyncio import Protocol as BaseProtocol


# TODO add support for servers
# TODO add support for other transports (non pausable ? read only ? write only ?)


# TODO use this...
def writelines(transport, lines):
    sock = transport._sock
    sendmsg = getattr(sock, "sendmsg", False)
    if sendmsg and not transport._buffer:
        try:
            sendmsg(lines)
        except:
            transport.write(b''.join(lines))
    else:
        transport.write(b''.join(lines))


class ChunkedBufferStream(BaseProtocol):
    __slots__ = '_limit', '_pipe', '_newline', '_transport', '_write_drained', '_has_data', '_paused'

    @classmethod
    async def create_connection(cls, *args, **kwargs):
        limit = kwargs.pop('limit', 2**16)
        pool = kwargs.pop('pool', None)
        newline = kwargs.pop('newline', b'\n')
        _, protocol = await get_event_loop().create_connection(lambda: cls(limit, pool, newline), *args, **kwargs)
        return protocol

    @classmethod
    async def create_unix_connection(cls, *args, **kwargs):
        limit = kwargs.pop('limit', 2**16)
        pool = kwargs.pop('pool', None)
        newline = kwargs.pop('newline', b'\n')
        _, protocol = await get_event_loop().create_unix_connection(lambda: cls(limit, pool, newline), *args, **kwargs)
        return protocol

    def __init__(self, limit=2**16, pool=None, newline=b'\n'):
        self._limit = limit
        self._pipe = Pipe(pool)
        self._newline = newline
        self._transport = None
        self._write_drained = Event()
        self._write_drained.set()
        self._has_data = Event()
        self._paused = False

    def connection_made(self, transport):
        self._transport = transport

    def connection_lost(self, exc):
        self._pipe.eof(exc)
        self._has_data.set()

    def _got_data(self):
        if not self._paused and len(self._pipe) > self._limit:
            self._transport.pause_reading()
            self._paused = True
        self._has_data.set()

    # Python 3.7+ support
    def get_buffer(self, sizehint):
        return self._pipe.get_buffer(sizehint)

    def buffer_updated(self, nbytes):
        self._pipe.buffer_written(nbytes)
        self._got_data()

    # Python 3.6 support
    def data_received(self, data):
        l = len(data)
        buffer = self._pipe.get_buffer(l)
        buffer[:l] = data
        self._pipe.buffer_written(l)
        self._got_data()

    @property
    def peername(self):
        return self._transport.get_extra_info('peername')

    @property
    def socket(self):
        return self._transport.get_extra_info('socket')

    # Write API
    def pause_writing(self):
        self._write_drained.clear()

    def resume_writing(self):
        self._write_drained.set()

    async def awrite(self, data):
        self._transport.write(data)
        await self._write_drained.wait()

    async def awritelines(self, stream):
        for item in stream:
            self._transport.write(item)
        await self._write_drained.wait()

    async def aclose_write(self):
        self._transport.write_eof()

    async def aclose(self):
        self._transport.close()
        while not self._pipe.closed:
            await self._wait_for_data()

    # Read API
    async def _wait_for_data(self):
        self._has_data.clear()
        if self._paused:
            self._transport.resume_reading()
            self._paused = False
        await self._has_data.wait()
    
    def _maybe_resume_reading(self):
        if self._paused and len(self._pipe) <= self._limit:
            self._transport.resume_reading()
            self._paused = False

    async def readline(self):
        return await self.readuntil(self._newline)

    async def readuntil(self, seperator, with_sepeartor=True):
        ret = self._pipe.readuntil(sepeartor, with_seperator)
        while ret is None:
            await self._wait_for_data()
            ret = self._pipe.readuntil(sepeartor, with_seperator)
        self._maybe_resume_reading()
        return ret

    async def read(self, n=-1):
        if n == -1:
            while not self._pipe.closed():
                await self._wait_for_data()
        ret = self._pipe.readatmostbytes(n)
        if ret is None:
            await self._wait_for_data()
            ret = self._pipe.readatmostbytes(n)
        self._maybe_resume_reading()
        return ret        

    # I think it's better to return b'' on EOF instead of raise an exception, but who knows...
    async def readexactly(self, n):
        ret = self._pipe.readbytes(n)
        while ret is None:
            await self._wait_for_data()
            ret = self._pipe.readbytes(n)
        self._maybe_resume_reading()
        return ret

    def __aiter__(self):
        return self

    async def __anext__(self):
        ret = await self.readline()
        if ret == b'':
            raise StopAsyncIteration
        return ret
