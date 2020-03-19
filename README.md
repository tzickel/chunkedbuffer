## What?
An attempt to make a more efficient bytearray (for buffered usage) and Buffered I/O replacement including asynchronous for Python.

Please note that this project is currently alpha quality and the API is not finalized. Please provide feedback if you think the API is convenient enough or not. A permissive license will be chosen once the API will be more mature for wide spread consumption.

## How ?
The API handles allocating the buffer and providing it to the writer.

The data is copied only once, when consumed by the reader.

The buffers are re-used by a pool to improve performence, especially in concurrent scenarios.

## Roadmap
- [ ] API Finalization
- [ ] Choose license
- [ ] Resolve all TODO in code
- [ ] More test coverage

## Installing
For now you can install this via this github repository by pip installing or adding to your requirements.txt file:

```
git+git://github.com/tzickel/chunkedbuffer@master#egg=chunkedbuffer
```

Replace master with the specific branch or version tag you want.

## Example
```python
from chunkedbuffer import Pipe

if __name__ == "__main__":
    pipe = Pipe()
    # We can use here -1, if our writing implmentation can handle arbitrary sizes (like socket.recv_into can)
    buffer = pipe.get_buffer(4)
    buffer[:4] = b'test'
    pipe.buffer_written(4)
    # The functions return None when there is not enough data to return
    assert pipe.readline() == None
    # You must request a buffer each time you want to write new information
    buffer = pipe.get_buffer(2)
    buffer[:2] = b'\r\n'
    # You must tell the Pipe how much data has been written
    pipe.buffer_written(2)
    assert pipe.readline() == b'test\r\n'
```

## API
```python
# on_new_data, a function which accepts the Pipe and is called after any write operation.
# pool, by default a global memory Pool for the chunks.
Pipe(on_new_data=None, pool=None)
    # Write API

    # Must be called each time data is ready to be written.
    # The returned buffer will hold space for atleast sizehint (unless it's -1, which it will have space for atleast 1 byte).
    get_buffer(sizehint=-1)
    # Must be called after each get_buffer and data that's written with the number of bytes written.
    buffer_written(nbytes)
    # Needs to be called after the stream is closed.
    eof(exception=None)

    # Read API
    readline(with_ending=True)
    readbytes(nbytes)
    readatmostbytes(nbytes=-1)
    readuntil(seperator, with_seperator=True))

    findbyte(byte, start=0, end=-1)
    find(s, start=0, end=-1)

    peek(nbytes)

    __len__()
    closed()
```


```python
ChunkedBufferStream(limit=2**16, pool=None, newline=b'\n')
    create_connection(*args, **kwargs)
    create_unix_connection(*args, **kwargs)

    peername
    socket

    async awrite(data)
    async awritelines(stream)
    async aclose_write()
    async aclose()

    async readline()
    async readuntil(seperator, with_sepeartor=True)
    async read(n=-1)
    async readexactly(n)
    __aiter__()
    async __anext__()
```

## Partially inspired by
The .NET library [System.IO.Pipelines](https://docs.microsoft.com/en-us/dotnet/standard/io/pipelines)
