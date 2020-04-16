## What?
This library provides an API for stream processing with emphesis on minimizing memory allocations and copying.

Please note that this project is currently alpha quality and the API is not finalized. Please provide feedback if you think the API is convenient enough or not. A permissive license will be chosen once the API will be more mature for wide spread consumption.

## Usage
A typical use case would be to create a Buffer instance and writing data to it with get_chunk()/chunk_written() methods for API which provide an readinto like method or with the extend() method for any bytes like object.

You can then call the find() method to find a given delimiter in the stream or call take()/peek() methods to read bytes from the stream.

Those methods return a new Buffer which points only to that specific data.

You can then pass the Buffer instance to any method which accepts a bytes like object or call bytearray like operations on it such as split(), strip(), etc....

At the bottom of the document there are technical notes for those who want to understand the inner-workings of this library.

## Roadmap
- [ ] API Finalization
- [ ] Choose license
- [ ] Resolve all TODO in code
- [ ] More test coverage
- [ ] A pure python version for PyPy
- [ ] Windows support ?
- [ ] Support for holding generic bytes like objects inside the buffer for optimizing APIs such as scatter I/O

## Installing
For now you can install this via this github repository by pip installing or adding to your requirements.txt file:

```
git+git://github.com/tzickel/chunkedbuffer@master#egg=chunkedbuffer
```

Replace master with the specific branch or version tag you want.

## Example
```python
from chunkedbuffer import Buffer

if __name__ == "__main__":
    buffer = Buffer()
    # We can use here the default value -1, if our writing implmentation can handle arbitrary sizes (like socket.recv_into can)
    buff = pipe.get_buffer(4)
    # Because the returned buffer might be bigger than 4, and this is an example code, we need to write it like this
    buff[:4] = b'test'
    buffer.buffer_written(4)
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
    read(nbytes=-1)
    readexact(nbytes)
    readuntil(seperator, skip_seperator=False)

    findbyte(byte, start=0, end=None)
    find(s, start=0, end=None)

    peek(nbytes=-1)
    peakexact(nbytes)

    skip(nbytes=-1)
    skipexact(nbytes)

    __len__()
    reached_eof()
    closed()

    # Zero copy API (This functions return the original data as a memoryview via an generator)
    read_zerocopy(nbytes=-1)
    readexact_zerocopy(nbytes)
    readuntil_zerocopy(seperator, skip_seperator=False)


# An exception that is thrown when the stream has reached EOF but the ammount of data requested is bigger than present in the buffer
PartialReadError()
    # The remaining data left in the buffer before EOF has been reached
    leftover
```

## How ?
The Buffer class defines write API for providing buffers to be written to with data from a stream.

The Buffer class provides read API which allows for reading, reading until seperator, skiping, peeking and finding.

The read API has both zero copy and one copy (convert to bytes) commands.

The data is held inside the Buffer by a series of non contiguous list of buffers which are called Chunks.

The Chunks are re-used by a pool to minimize allocation and improve performance especially in concurrent scenarios.
