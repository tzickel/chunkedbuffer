import pytest

from chunkedbuffer import Buffer, PartialReadError
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
def write(buffer, data):
    buff = buffer.get_buffer()
    buff_len = len(buff)
    write_len = min(buff_len, len(data))
    buff[:write_len] = data[:write_len]
    buffer.buffer_written(write_len)
    return write_len


def write_all(buffer, data):
    while data:
        ret = write(buffer, data)
        data = data[ret:]


def write_exact(buffer, data):
    l = len(data)
    buff = buffer.get_buffer(l)
    buff[:l] = data
    buffer.buffer_written(l)


def flatten_zero_copy(result):
    if result is None:
        return None
    items = list(result)
    if items == [None]:
        return None
    return b''.join([x.tobytes() for x in items])


def test_buffer_closed():
    buffer = Buffer()
    assert buffer.closed() == False
    buffer.eof()
    assert buffer.closed() == True

    buffer = Buffer()
    exp = Exception('testing')
    buffer.eof(exp)
    assert buffer.closed() == exp


def test_buffer_reached_eof():
    buffer = Buffer()
    assert buffer.reached_eof() == False
    write_all(buffer, b'testing')
    assert buffer.reached_eof() == False
    buffer.eof()
    assert buffer.reached_eof() == False
    assert buffer.readexact(7) == b'testing'
    assert buffer.reached_eof() == True
    assert buffer.read(1) == b''
    assert buffer.reached_eof() == True


def test_buffer_len():
    buffer = Buffer()
    write_all(buffer, b'testing')
    assert len(buffer) == 7
    assert buffer.readexact(4) == b'test'
    assert len(buffer) == 3
    assert buffer.readexact(3) == b'ing'
    assert len(buffer) == 0


def test_buffer_peek():
    buffer = Buffer()
    assert buffer.peek(0) == b''
    assert buffer.peek(10) == None
    write_all(buffer, b'blah')
    assert buffer.peek(0) == b''
    assert buffer.peek(10) == b'blah'
    assert buffer.peek(3) == b'bla'
    assert buffer.peek(4) == b'blah'


def test_buffer_peekexact():
    buffer = Buffer()
    assert buffer.peekexact(0) == b''
    assert buffer.peekexact(10) == None
    write_all(buffer, b'blah')
    assert buffer.peekexact(0) == b''
    assert buffer.peekexact(10) == None
    assert buffer.peekexact(3) == b'bla'
    assert buffer.peekexact(4) == b'blah'


def test_buffer_readexact_eof_normal():
    buffer = Buffer()
    write_all(buffer, b'testing')
    buffer.eof()
    assert buffer.readexact(4) == b'test'
    assert buffer.readexact(1) == b'i'
    with pytest.raises(PartialReadError) as e:
        buffer.readexact(4)
    assert str(e.value) == 'Requested 4 bytes but encountered EOF'
    assert e.value.leftover == b'ng'
    assert buffer.readexact(4) == b''


def test_buffer_readexact_eof_exception():
    buffer = Buffer()
    write_all(buffer, b'testing')
    buffer.eof(Exception('test'))
    assert buffer.readexact(4) == b'test'
    assert buffer.readexact(1) == b'i'
    with pytest.raises(PartialReadError) as e:
        buffer.readexact(4)
    assert str(e.value) == 'Requested 4 bytes but encountered EOF'
    assert e.value.leftover == b'ng'
    with pytest.raises(Exception) as e:
        buffer.readexact(4)
    assert str(e.value) == 'test'


def test_buffer_readexact_zerocopy_eof_exception():
    buffer = Buffer()
    write_all(buffer, b'testing')
    buffer.eof(Exception('test'))
    assert flatten_zero_copy(buffer.readexact_zerocopy(4)) == b'test'
    assert flatten_zero_copy(buffer.readexact_zerocopy(1)) == b'i'
    with pytest.raises(PartialReadError) as e:
        flatten_zero_copy(buffer.readexact_zerocopy(4))
    assert str(e.value) == 'Requested 4 bytes but encountered EOF'
    assert e.value.leftover == b'ng'
    with pytest.raises(Exception) as e:
        flatten_zero_copy(buffer.readexact_zerocopy(4))
    assert str(e.value) == 'test'


def test_buffer_readuntil():
    buffer = Buffer()
    write_all(buffer, b'test\r\ning\r\n')
    assert buffer.readuntil(b'\r\n', skip_seperator=True) == b'test'
    assert buffer.readuntil(b'notfound') == None
    assert buffer.readuntil(b'\r\n') == b'ing\r\n'
    assert buffer.readuntil(b'\r\n') == None
    write_all(buffer, b'blah')
    assert buffer.readuntil(b'a') == b'bla'
    assert len(buffer) == 1
    assert buffer.readuntil(ord(b'h')) == b'h'
    assert len(buffer) == 0


def test_buffer_readuntil_zerocopy():
    buffer = Buffer()
    write_all(buffer, b'test\r\ning\r\n')
    assert flatten_zero_copy(buffer.readuntil_zerocopy(b'\r\n', skip_seperator=True)) == b'test'
    assert flatten_zero_copy(buffer.readuntil_zerocopy(b'notfound')) == None
    assert flatten_zero_copy(buffer.readuntil_zerocopy(b'\r\n')) == b'ing\r\n'
    assert flatten_zero_copy(buffer.readuntil_zerocopy(b'\r\n')) == None
    write_all(buffer, b'blah')
    assert flatten_zero_copy(buffer.readuntil_zerocopy(b'a')) == b'bla'
    assert len(buffer) == 1
    assert flatten_zero_copy(buffer.readuntil_zerocopy(ord(b'h'))) == b'h'
    assert len(buffer) == 0


# TODO add test for end in mid chunk in multiple chunks
def test_buffer_findbyte():
    buffer = Buffer()
    write_exact(buffer, b'test')
    with pytest.raises(ValueError):
        buffer.findbyte(b'b', -1)
    with pytest.raises(ValueError):
        buffer.findbyte(b'b', 0, -1)
    write_exact(buffer, b'ing')
    assert buffer.findbyte(b'n', 4) == 5
    assert buffer.findbyte(b'n', 0, 4) == -1
    assert buffer.findbyte(b'n', 0, 5) == -1
    assert buffer.findbyte(b'n', 0, 6) == 5
    assert buffer.find(b'n', 0, 6) == 5
    assert buffer.find(b'ng', 0, 6) == 5


def test_buffer_get_buffer():
    buffer = Buffer()
    write_exact(buffer, b'testing')
    write(buffer, b'1')


def test_buffer_skip():
    buffer = Buffer()
    write_exact(buffer, b'blah')
    assert len(buffer) == 4
    assert buffer.skip(0) == 0
    assert buffer.skip(2) == 2
    assert len(buffer) == 2
    assert buffer.readexact(2) == b'ah'
    write_exact(buffer, b'blah')
    assert len(buffer) == 4
    assert buffer.skip(5) == 4
    assert len(buffer) == 0
    # TODO hmm... should we return here b'' or PartialReadError?
    assert buffer.read(2) == None
    write_exact(buffer, b'blah')
    assert len(buffer) == 4
    assert buffer.skip() == 4
    assert len(buffer) == 0
    assert buffer.skip() == 0
    assert len(buffer) == 0
    buffer.eof()
    assert buffer.skip() == 0


def test_buffer_skipexact():
    buffer = Buffer()
    write_exact(buffer, b'blah')
    assert len(buffer) == 4
    assert buffer.skipexact(2) == 2
    assert len(buffer) == 2
    assert buffer.skipexact(4) == None
    assert buffer.readexact(2) == b'ah'
    assert buffer.skipexact(4) == None
    buffer.eof()
    # TODO hmm... should we return here b'' or PartialReadError?
    assert buffer.skipexact(4) == b''


def test_buffer_buffer_resize():
    buffer = Buffer()
    original_size = buffer._current_size
    for _ in range(2048):
        write_all(buffer, b'a' * 5)
    assert original_size == buffer._current_size
    for _ in range(2048):
        write_all(buffer, b'a' * 5000)
    assert original_size != buffer._current_size
    for _ in range(2048):
        write_all(buffer, b'a' * 5)
    assert original_size == buffer._current_size


def test_buffer_take_multiple():
    buffer = Buffer(minimum_size=1)
    buffer.get_buffer(4)[:4] = b'test'
    buffer.buffer_written(4)
    buffer.get_buffer(3)[:3] = b'ing'
    buffer.buffer_written(3)
    assert buffer.readexact(7) == b'testing'
    buffer.get_buffer(4)[:4] = b'test'
    buffer.buffer_written(4)
    buffer.get_buffer(3)[:3] = b'ing'
    buffer.buffer_written(3)
    assert buffer.readexact(6) == b'testin'
    assert buffer.readexact(1) == b'g'


def test_buffer_take_zero_copy_multiple():
    buffer = Buffer(minimum_size=1)
    buffer.get_buffer(4)[:4] = b'test'
    buffer.buffer_written(4)
    buffer.get_buffer(3)[:3] = b'ing'
    buffer.buffer_written(3)
    assert flatten_zero_copy(buffer.readexact_zerocopy(7)) == b'testing'
    buffer.get_buffer(4)[:4] = b'test'
    buffer.buffer_written(4)
    buffer.get_buffer(3)[:3] = b'ing'
    buffer.buffer_written(3)
    assert flatten_zero_copy(buffer.readexact_zerocopy(6)) == b'testin'
    assert flatten_zero_copy(buffer.readexact_zerocopy(1)) == b'g'
    assert flatten_zero_copy(buffer.readexact_zerocopy(0)) == b''


def test_buffer_skip_multiple():
    buffer = Buffer(minimum_size=1)
    buffer.get_buffer(4)[:4] = b'test'
    buffer.buffer_written(4)
    buffer.get_buffer(3)[:3] = b'ing'
    buffer.buffer_written(3)
    assert buffer.readexact(3) == b'tes'
    assert buffer.skip(2) == 2
    assert buffer.readexact(2) == b'ng'

    buffer = Buffer(minimum_size=1)
    buffer.get_buffer(4)[:4] = b'test'
    buffer.buffer_written(4)
    buffer.get_buffer(3)[:3] = b'ing'
    buffer.buffer_written(3)
    assert buffer.readexact(3) == b'tes'
    assert buffer.skip(4) == 4
    assert len(buffer) == 0


def test_buffer_readzerocopy():
    buffer = Buffer()
    assert flatten_zero_copy(buffer.read_zerocopy()) == None
    assert flatten_zero_copy(buffer.read_zerocopy(2)) == None
    write_all(buffer, b'testing\r\n')
    assert flatten_zero_copy(buffer.read_zerocopy(2)) == b'te'
    assert flatten_zero_copy(buffer.read_zerocopy()) == b'sting\r\n'
    assert flatten_zero_copy(buffer.read_zerocopy()) == None
