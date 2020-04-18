import pytest

from chunkedbuffer import Buffer

# Helper methods for testing (should I put them in the buffer?)
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


# Tests
def test_simple():
    b = Buffer()
    b.extend(b'test')
    assert b.take() == b'test'
    assert b.take() == b''
    b.extend(b'test')
    b.extend(b'ing')
    assert b.peek() == b'testing'
    assert bytes(b.peek()) == b'testing'
    assert b.take() == b'testing'
    assert b.take() == b''


def test_buffer_bytes():
    b = Buffer(minimum_chunk_size=4)
    b.extend(b'test')
    assert b == b'test'
    b.extend(b'ing')
    assert b == b'testing'


def test_buffer_len():
    b = Buffer()
    assert len(b) == 0
    b.extend(b'test')
    assert len(b) == 4
    assert b.peek() == b'test'
    assert len(b) == 4
    assert b.take() == b'test'
    assert len(b) == 0


def test_buffer_find():
    b = Buffer()
    with pytest.raises(ValueError):
        b.find(b'', start=-1)
    with pytest.raises(ValueError):
        b.find(b'', end=-2)
    assert b.find(b'') == 0
    assert b.find(b'a') == -1
    assert b.find(b'', 1) == -1

    b.extend(b'test')
    assert b.find(b'') == 0
    assert b.find(b'a') == -1
    assert b.find(b'', 1) == 1
    assert b.find(b'', 2) == 2
    assert b.find(b'', 4) == 4
    assert b.find(b'', 5) == -1

    assert b.find(b't') == 0
    assert b.find(b't', 0) == 0
    assert b.find(b't', 1) == 3
    assert b.find(b't', 2) == 3
    assert b.find(b't', 3) == 3
    assert b.find(b't', 4) == -1
    assert b.find(b't', 5) == -1

    b = Buffer(minimum_chunk_size=4)
    b.extend(b'test')
    b.extend(b'ing')
    b.find(b'i') == 4
    b.find(b'i', 4) == 4
    b.find(b'n', 3, 4) == -1

    b = Buffer(minimum_chunk_size=2048)
    b.extend(b'a' * 2047)
    b.extend(b'\r')
    b.extend(b'\n')
    b.extend(b'a' * 2047)
    assert b.find(b'\r\n') == 2047

    b = Buffer(minimum_chunk_size=2048)
    b.extend(b'a' * 2048)
    b.extend(b'\r\n')
    b.extend(b'a' * 2046)
    assert b.find(b'\r\n') == 2048

    b = Buffer(minimum_chunk_size=2048)
    b.extend(b'a' * 2046)
    b.extend(b'te')
    b.extend(b'st')
    b.extend(b'a' * 2046)
    assert b.find(b'\r\n') == -1
    assert b.find(b'test') == 2046
    assert b.find(b'es') == 2047
    assert b.find(b'tes') == 2046
    assert b.find(b'est') == 2047
    assert b.find(b'te') == 2046
    assert b.find(b'st') == 2048

    b = Buffer(minimum_chunk_size=2048)
    b.extend(b'a' * 2046)
    b.extend(b'te')
    b.extend(b'st')
    b.extend(b'a' * 2046)
    b.skip(2046)
    assert b.find(b'\r\n') == -1
    print(bytes(b.peek()))
    print(b._debug())
    print('---')
    assert b.find(b'test') == 0
    b.skip(1)
    assert b.find(b'test') == -1


def test_buffer_takeuntil():
    b = Buffer()
    b.extend(b'test')
    assert b.takeuntil(b'\r\n') == None
    b.extend(b'\r\ning')
    assert b.takeuntil(b'\r\n') == b'test'
    assert b.takeuntil(b'\r\n') == None
    assert b.take() == b'ing'


def test_buffer_getchunks():
    b = Buffer(minimum_chunk_size=4)
    with pytest.raises(ValueError):
        b.get_chunks()
    b.extend(b'test')
    b.extend(b'ing')
    with pytest.raises(ValueError):
        b.get_chunks()
    a = b.take()
    assert len(a.get_chunks()) == 2
    assert b''.join(a.get_chunks()) == b'testing'
