import pytest

from chunkedbuffer import Buffer

# Tests
def test_simple():
    b = Buffer()
    assert bytes(b) == b''
    b.append(b'test')
    assert b.take() == b'test'
    assert b.take() == b''
    b.append(b'test')
    b.append(b'ing')
    assert b.peek() == b'testing'
    assert b.peek(3) == b'tes'
    assert b.peek(300) == b'testing'
    assert b.peek() == b'testing'
    assert b.take() == b'testing'
    assert b.take() == b''
    assert b.peek() == b''


def test_buffer_bytes():
    b = Buffer(minimum_chunk_size=4)
    b.append(b'test')
    assert b == b'test'
    b.append(b'ing')
    assert b == b'testing'
    assert b.peek(3) == b'tes'


def test_buffer_len():
    b = Buffer()
    assert len(b) == 0
    b.append(b'test')
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

    b.append(b'test')
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
    b.append(b'test')
    b.append(b'ing')
    b.find(b'i') == 4
    b.find(b'i', 4) == 4
    b.find(b'n', 3, 4) == -1

    b = Buffer(minimum_chunk_size=2048)
    b.append(b'a' * 2047)
    b.append(b'\r')
    b.append(b'\n')
    b.append(b'a' * 2047)
    assert b.find(b'\r\n') == 2047

    b = Buffer(minimum_chunk_size=2048)
    b.append(b'a' * 2048)
    b.append(b'\r\n')
    b.append(b'a' * 2046)
    assert b.find(b'\r\n') == 2048

    b = Buffer(minimum_chunk_size=2048)
    b.append(b'a' * 2046)
    b.append(b'te')
    b.append(b'st')
    b.append(b'a' * 2046)
    assert b.find(b'\r\n') == -1
    assert b.find(b'test') == 2046
    assert b.find(b'es') == 2047
    assert b.find(b'tes') == 2046
    assert b.find(b'est') == 2047
    assert b.find(b'te') == 2046
    assert b.find(b'st') == 2048

    b = Buffer(minimum_chunk_size=2048)
    b.append(b'a' * 2046)
    b.append(b'te')
    b.append(b'st')
    b.append(b'a' * 2046)
    b.skip(2046)
    assert b.find(b'\r\n') == -1
    assert b.find(b'test') == 0
    b.skip(1)
    assert b.find(b'test') == -1


def test_buffer_takeuntil():
    b = Buffer()
    b.append(b'test')
    assert b.takeuntil(b'\r\n') == None
    b.append(b'\r\ning')
    assert b.takeuntil(b'\r\n') == b'test'
    assert b.takeuntil(b'\r\n') == None
    assert b.takeuntil(b'ing', True) == b'ing'
    assert b.take() == b''


def test_buffer_chunks():
    b = Buffer(minimum_chunk_size=4)
    with pytest.raises(ValueError):
        b.chunks()
    b.append(b'test')
    b.append(b'ing')
    with pytest.raises(ValueError):
        b.chunks()
    a = b.take()
    assert len(list(a.chunks())) == 2
    assert b''.join(a.chunks()) == b'testing'
