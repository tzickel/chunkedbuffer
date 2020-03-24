import pytest

from chunkedbuffer import Pipe, PartialReadError


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


def test_pipe_closed():
    pipe = Pipe()
    assert pipe.closed() == False
    pipe.eof()
    assert pipe.closed() == True

    pipe = Pipe()
    exp = Exception('testing')
    pipe.eof(exp)
    assert pipe.closed() == exp


def test_pipe_len():
    pipe = Pipe()
    write_all(pipe, b'testing')
    assert len(pipe) == 7
    assert pipe.readbytes(4) == b'test'
    assert len(pipe) == 3
    assert pipe.readbytes(3) == b'ing'
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


def test_pipe_readbytes_eof_normal():
    pipe = Pipe()
    write_all(pipe, b'testing')
    pipe.eof()
    assert pipe.readbytes(4) == b'test'
    assert pipe.readbytes(1) == b'i'
    with pytest.raises(PartialReadError) as e:
        pipe.readbytes(4)
    assert str(e.value) == 'Requested 4 bytes but encountered EOF'
    assert e.value.leftover == b'ng'
    assert pipe.readbytes(4) == b''


def test_pipe_readbytes_eof_exception():
    pipe = Pipe()
    write_all(pipe, b'testing')
    pipe.eof(Exception('test'))
    assert pipe.readbytes(4) == b'test'
    assert pipe.readbytes(1) == b'i'
    with pytest.raises(PartialReadError) as e:
        pipe.readbytes(4)
    assert str(e.value) == 'Requested 4 bytes but encountered EOF'
    assert e.value.leftover == b'ng'
    with pytest.raises(Exception) as e:
        pipe.readbytes(4)
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


def test_pipe_findbyte():
    pipe = Pipe()
    write_exact(pipe, b'test')
    with pytest.raises(NotImplementedError):
        pipe.findbyte(b'b', -1)
    write_exact(pipe, b'ing')
    assert pipe.findbyte(b'n', 4) == 5
    import pdb; pdb.set_trace()
    assert pipe.findbyte(b'n', 0, 4) == -1
    assert pipe.findbyte(b'n', 0, 5) == 5


def test_pipe_get_buffer():
    pipe = Pipe()
    write_exact(pipe, b'testing')
