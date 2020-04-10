from chunkedbuffer import Buffer


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


def test_simple():
    b = Buffer()
    write_exact(b, b'test')
    assert bytes(b.take()) == b'test'
    assert bytes(b.take()) == b''
    write_exact(b, b'test')
    write_exact(b, b'ing')
    assert bytes(b.peek()) == b'testing'
    assert bytes(b.take()) == b'testing'
    assert bytes(b.take()) == b''


def test_buffer_close():
    b = Buffer()
    write_exact(b, b'test')
    b.close()


def test_buffer_len():
    b = Buffer()
    assert len(b) == 0
    write_exact(b, b'test')
    assert len(b) == 4
    assert bytes(b.peek()) == b'test'
    assert len(b) == 4
    assert bytes(b.take()) == b'test'
    assert len(b) == 0
