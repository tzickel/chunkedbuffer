## What?
An attempt at making an efficient API for streaming binary I/O implmentations with emphasis on minimizing allocations and copying.

An (currently only asyncio) asynchronous stream like wrapper using above code.

Please note that this project is currently alpha quality and the API is not finalized. Please provide feedback if you think the API is convenient enough or not. A permissive license will be chosen once the API will be more mature for wide spread consumption.

## How ?
The Pipe class defines API for providing buffers to be written to with data, and methods to read the data with normal buffered I/O such as readbytes, readuntil, etc...

The buffers the Pipe holds the data in are called Chunks, and are re-used by a pool to improve performence especially in concurrent senarios and minimize allocations.

The data is only copiy once, when it's ready to be consumed from the reading API.

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
    # We can use here the default value -1, if our writing implmentation can handle arbitrary sizes (like socket.recv_into can)
    buffer = pipe.get_buffer(4)
    # Because the returned buffer might be bigger than 4, and this is an example code, we need to write it like this
    buffer[:4] = b'test'
    pipe.buffer_written(4)
    # The functions return None when there is not enough data to return
    assert pipe.readuntil(b'\r\n') == None
    # You must request a buffer each time you want to write new data
    buffer = pipe.get_buffer(2)
    buffer[:2] = b'\r\n'
    # You must tell the Pipe how much data has been written
    pipe.buffer_written(2)
    assert pipe.readuntil(b'\r\n') == b'test\r\n'
```

## API
```python
# pool, by default a global memory Pool for the chunks
Pipe(pool=None)
    # Write API

    # Must be called each time data is ready to be written
    # The returned buffer will hold space for atleast sizehint (unless it's -1, which it will have space for atleast 1 byte)
    get_buffer(sizehint=-1)
    # Must be called after each get_buffer and data that's written with the number of bytes written
    buffer_written(nbytes)
    # Needs to be called after the stream is closed
    eof(exception=None)

    # Read API
    readbytes(nbytes)
    readatmostbytes(nbytes=-1)
    readuntil(seperator, skip_seperator=False)

    findbyte(byte, start=0, end=-1)
    find(s, start=0, end=-1)

    peek(nbytes)

    __len__()
    closed()


# An exception that is thrown when the stream has reached EOF but the ammount of data requested is bigger than present in the buffer
PartialReadError()
    # The remaining data left in the buffer before EOF has been reached
    leftover
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
