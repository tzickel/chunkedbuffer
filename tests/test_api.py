import pytest

from chunkedbuffer import Pipe, PartialReadError
from chunkedbuffer.chunk import Chunk


# TODO all tests should have both on regular minimum_size and on very short one


def test_chunk():
    chunk = Chunk(1024)
    assert chunk.size() == 1024
    assert chunk.free() == 1024
    assert chunk.length() == 0
    chunk.writable()[:4] = b'test'
    chunk.written(4)
    assert chunk.free() == 1020
    assert chunk.length() == 4
    assert chunk.readable().tobytes() == b'test'
    assert chunk.readable(2).tobytes() == b'te'
    assert chunk.readable(0).tobytes() == b''
    assert chunk.find(b't') == 0
    assert chunk.find(b't', 2) == 3
    chunk.consume(2)
    assert chunk.free() == 1020
    assert chunk.length() == 2
    assert chunk.readable().tobytes() == b'st'
    assert chunk.readable(2).tobytes() == b'st'
    assert chunk.readable(0).tobytes() == b''
    assert chunk.find(b't') == 1
    assert chunk.find(b't', 2) == -1
    chunk.reset()
    assert chunk.free() == 1024
    assert chunk.length() == 0
    assert chunk.readable().tobytes() == b''
    assert chunk.readable(2).tobytes() == b''
    assert chunk.find(b't') == -1
    assert chunk.find(b't', 2) == -1


# Helper methods for testing
def write(pipe, data):
    buff = pipe.get_buffer()
    buff_len = len(buff)
    write_len = min(buff_len, len(data))
    buff[:write_len] = data[:write_len]
    pipe.buffer_written(write_len)
    return write_len


def write_all(pipe, data):
    while data:
        ret = write(pipe, data)
        data = data[ret:]


def write_exact(pipe, data):
    l = len(data)
    buff = pipe.get_buffer(l)
    buff[:l] = data
    pipe.buffer_written(l)


def flatten_zero_copy(result):
    if result is None:
        return None
    items = list(result)
    if items == [None]:
        return None
    return b''.join([x.tobytes() for x in items])


def test_pipe_closed():
    pipe = Pipe()
    assert pipe.closed() == False
    pipe.eof()
    assert pipe.closed() == True

    pipe = Pipe()
    exp = Exception('testing')
    pipe.eof(exp)
    assert pipe.closed() == exp


def test_pipe_reached_eof():
    pipe = Pipe()
    assert pipe.reached_eof() == False
    write_all(pipe, b'testing')
    assert pipe.reached_eof() == False
    pipe.eof()
    assert pipe.reached_eof() == False
    assert pipe.readexact(7) == b'testing'
    assert pipe.reached_eof() == True
    assert pipe.read(1) == b''
    assert pipe.reached_eof() == True


def test_pipe_len():
    pipe = Pipe()
    write_all(pipe, b'testing')
    assert len(pipe) == 7
    assert pipe.readexact(4) == b'test'
    assert len(pipe) == 3
    assert pipe.readexact(3) == b'ing'
    assert len(pipe) == 0


def test_pipe_peek():
    pipe = Pipe()
    assert pipe.peek(0) == b''
    assert pipe.peek(10) == None
    write_all(pipe, b'blah')
    assert pipe.peek(0) == b''
    assert pipe.peek(10) == b'blah'
    assert pipe.peek(3) == b'bla'
    assert pipe.peek(4) == b'blah'


def test_pipe_peekexact():
    pipe = Pipe()
    assert pipe.peekexact(0) == b''
    assert pipe.peekexact(10) == None
    write_all(pipe, b'blah')
    assert pipe.peekexact(0) == b''
    assert pipe.peekexact(10) == None
    assert pipe.peekexact(3) == b'bla'
    assert pipe.peekexact(4) == b'blah'


def test_pipe_readexact_eof_normal():
    pipe = Pipe()
    write_all(pipe, b'testing')
    pipe.eof()
    assert pipe.readexact(4) == b'test'
    assert pipe.readexact(1) == b'i'
    with pytest.raises(PartialReadError) as e:
        pipe.readexact(4)
    assert str(e.value) == 'Requested 4 bytes but encountered EOF'
    assert e.value.leftover == b'ng'
    assert pipe.readexact(4) == b''


def test_pipe_readexact_eof_exception():
    pipe = Pipe()
    write_all(pipe, b'testing')
    pipe.eof(Exception('test'))
    assert pipe.readexact(4) == b'test'
    assert pipe.readexact(1) == b'i'
    with pytest.raises(PartialReadError) as e:
        pipe.readexact(4)
    assert str(e.value) == 'Requested 4 bytes but encountered EOF'
    assert e.value.leftover == b'ng'
    with pytest.raises(Exception) as e:
        pipe.readexact(4)
    assert str(e.value) == 'test'


def test_pipe_readexact_zerocopy_eof_exception():
    pipe = Pipe()
    write_all(pipe, b'testing')
    pipe.eof(Exception('test'))
    assert flatten_zero_copy(pipe.readexact_zerocopy(4)) == b'test'
    assert flatten_zero_copy(pipe.readexact_zerocopy(1)) == b'i'
    with pytest.raises(PartialReadError) as e:
        flatten_zero_copy(pipe.readexact_zerocopy(4))
    assert str(e.value) == 'Requested 4 bytes but encountered EOF'
    assert e.value.leftover == b'ng'
    with pytest.raises(Exception) as e:
        flatten_zero_copy(pipe.readexact_zerocopy(4))
    assert str(e.value) == 'test'


def test_pipe_readuntil():
    pipe = Pipe()
    write_all(pipe, b'test\r\ning\r\n')
    assert pipe.readuntil(b'\r\n', skip_seperator=True) == b'test'
    assert pipe.readuntil(b'notfound') == None
    assert pipe.readuntil(b'\r\n') == b'ing\r\n'
    assert pipe.readuntil(b'\r\n') == None
    write_all(pipe, b'blah')
    assert pipe.readuntil(b'a') == b'bla'
    assert len(pipe) == 1
    assert pipe.readuntil(ord(b'h')) == b'h'
    assert len(pipe) == 0


def test_pipe_readuntil_zerocopy():
    pipe = Pipe()
    write_all(pipe, b'test\r\ning\r\n')
    assert flatten_zero_copy(pipe.readuntil_zerocopy(b'\r\n', skip_seperator=True)) == b'test'
    assert flatten_zero_copy(pipe.readuntil_zerocopy(b'notfound')) == None
    assert flatten_zero_copy(pipe.readuntil_zerocopy(b'\r\n')) == b'ing\r\n'
    assert flatten_zero_copy(pipe.readuntil_zerocopy(b'\r\n')) == None
    write_all(pipe, b'blah')
    assert flatten_zero_copy(pipe.readuntil_zerocopy(b'a')) == b'bla'
    assert len(pipe) == 1
    assert flatten_zero_copy(pipe.readuntil_zerocopy(ord(b'h'))) == b'h'
    assert len(pipe) == 0


# TODO add test for end in mid chunk in multiple chunks
def test_pipe_findbyte():
    pipe = Pipe()
    write_exact(pipe, b'test')
    with pytest.raises(ValueError):
        pipe.findbyte(b'b', -1)
    with pytest.raises(ValueError):
        pipe.findbyte(b'b', 0, -1)
    write_exact(pipe, b'ing')
    assert pipe.findbyte(b'n', 4) == 5
    assert pipe.findbyte(b'n', 0, 4) == -1
    assert pipe.findbyte(b'n', 0, 5) == -1
    assert pipe.findbyte(b'n', 0, 6) == 5
    assert pipe.find(b'n', 0, 6) == 5
    assert pipe.find(b'ng', 0, 6) == 5


def test_pipe_get_buffer():
    pipe = Pipe()
    write_exact(pipe, b'testing')
    write(pipe, b'1')


def test_pipe_skip():
    pipe = Pipe()
    write_exact(pipe, b'blah')
    assert len(pipe) == 4
    assert pipe.skip(0) == 0
    assert pipe.skip(2) == 2
    assert len(pipe) == 2
    assert pipe.readexact(2) == b'ah'
    write_exact(pipe, b'blah')
    assert len(pipe) == 4
    assert pipe.skip(5) == 4
    assert len(pipe) == 0
    # TODO hmm... should we return here b'' or PartialReadError?
    assert pipe.read(2) == None
    write_exact(pipe, b'blah')
    assert len(pipe) == 4
    assert pipe.skip() == 4
    assert len(pipe) == 0
    assert pipe.skip() == 0
    assert len(pipe) == 0
    pipe.eof()
    assert pipe.skip() == 0


def test_pipe_skipexact():
    pipe = Pipe()
    write_exact(pipe, b'blah')
    assert len(pipe) == 4
    assert pipe.skipexact(2) == 2
    assert len(pipe) == 2
    assert pipe.skipexact(4) == None
    assert pipe.readexact(2) == b'ah'
    assert pipe.skipexact(4) == None
    pipe.eof()
    # TODO hmm... should we return here b'' or PartialReadError?
    assert pipe.skipexact(4) == b''


def test_pipe_buffer_resize():
    pipe = Pipe()
    original_size = pipe._current_size
    for _ in range(2048):
        write_all(pipe, b'a' * 5)
    assert original_size == pipe._current_size
    for _ in range(2048):
        write_all(pipe, b'a' * 5000)
    assert original_size != pipe._current_size
    for _ in range(2048):
        write_all(pipe, b'a' * 5)
    assert original_size == pipe._current_size


def test_pipe_take_multiple():
    pipe = Pipe(minimum_size=1)
    pipe.get_buffer(4)[:4] = b'test'
    pipe.buffer_written(4)
    pipe.get_buffer(3)[:3] = b'ing'
    pipe.buffer_written(3)
    assert pipe.readexact(7) == b'testing'
    pipe.get_buffer(4)[:4] = b'test'
    pipe.buffer_written(4)
    pipe.get_buffer(3)[:3] = b'ing'
    pipe.buffer_written(3)
    assert pipe.readexact(6) == b'testin'
    assert pipe.readexact(1) == b'g'


def test_pipe_take_zero_copy_multiple():
    pipe = Pipe(minimum_size=1)
    pipe.get_buffer(4)[:4] = b'test'
    pipe.buffer_written(4)
    pipe.get_buffer(3)[:3] = b'ing'
    pipe.buffer_written(3)
    assert flatten_zero_copy(pipe.readexact_zerocopy(7)) == b'testing'
    pipe.get_buffer(4)[:4] = b'test'
    pipe.buffer_written(4)
    pipe.get_buffer(3)[:3] = b'ing'
    pipe.buffer_written(3)
    assert flatten_zero_copy(pipe.readexact_zerocopy(6)) == b'testin'
    assert flatten_zero_copy(pipe.readexact_zerocopy(1)) == b'g'
    assert flatten_zero_copy(pipe.readexact_zerocopy(0)) == b''


def test_pipe_skip_multiple():
    pipe = Pipe(minimum_size=1)
    pipe.get_buffer(4)[:4] = b'test'
    pipe.buffer_written(4)
    pipe.get_buffer(3)[:3] = b'ing'
    pipe.buffer_written(3)
    assert pipe.readexact(3) == b'tes'
    assert pipe.skip(2) == 2
    assert pipe.readexact(2) == b'ng'

    pipe = Pipe(minimum_size=1)
    pipe.get_buffer(4)[:4] = b'test'
    pipe.buffer_written(4)
    pipe.get_buffer(3)[:3] = b'ing'
    pipe.buffer_written(3)
    assert pipe.readexact(3) == b'tes'
    assert pipe.skip(4) == 4
    assert len(pipe) == 0


def test_pipe_readzerocopy():
    pipe = Pipe()
    assert flatten_zero_copy(pipe.read_zerocopy()) == None
    assert flatten_zero_copy(pipe.read_zerocopy(2)) == None
    write_all(pipe, b'testing\r\n')
    assert flatten_zero_copy(pipe.read_zerocopy(2)) == b'te'
    assert flatten_zero_copy(pipe.read_zerocopy()) == b'sting\r\n'
    assert flatten_zero_copy(pipe.read_zerocopy()) == None
