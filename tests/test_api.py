from chunkedbuffer import Pipe


def pump(pipe, data):
    buff = pipe.get_buffer()
    buff[:5] = b'testi'
    pipe.buffer_written(5)


def test_basic():
    pipe = Pipe()
    buff = pipe.get_buffer()
    buff[:5] = b'testi'
    pipe.buffer_written(5)
    assert pipe.readbytes(100) == None
    assert pipe.readbytes(4) == b'test'
    buff = pipe.get_buffer()
    buff[:5] = b'ng\r\nt'
    pipe.buffer_written(5)
    assert pipe.readuntil(b'\r\n') == b'ing\r\n'
    buff = pipe.get_buffer(8)
    buff[:8] = b'esting\r\n'
    pipe.buffer_written(8)
    assert pipe.peek(7) == b'testing'
    assert pipe.readuntil(b'\r\n', skip_seperator=True) == b'testing'
