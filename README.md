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
Buffer(release_fast_to_pool=False, minimum_chunk_size=2048, pool=global_pool)
    # Write API

    # Must be called each time data is ready to be written
    # The returned chunk will have space for 1 or more bytes of data (currently sizehint is ignored, see minimum_chunk_size in constructor)
    # Zero amortized memory allocation (when using the default pool)
    get_chunk(sizehint=-1)
    # Must be called after each get_chunk and data that's written with the number of bytes written
    chunk_written(nbytes)

    # Can be used as an alternative if you already have the data you want to add to the buffer
    # Zero amortized memory allocation (when using the default pool)
    extend(data)

    # Takes multiple Buffers and merges them into one
    # Zero memory copy
    @staticmethod
    merge(buffers)

    # Read API

    # Returns a read-only buffer view of the contents
    # Zero memory copy if data is in one chunk, or a one-time memory copy if not
    __getbuffer__()
    # Returns the length
    # Precomputed
    __len__()
    # Finds the index (-1 if did not find) of s inside start, end indicies in the Buffer (by default checks all the Buffer)
    find(s, start=0, end=-1)
    # Returns a new Buffer which points to at most nbytes bytes (or all current data if nbytes == -1)
    # Zero memory copy
    peek(nbytes=-1)
    # Returns a new Buffer which points to at most nbytes nbytes (or all current data if nbytes == -1) removes data from current Buffer
    # Zero memory copy
    take(nbytes=-1)
    # Returns number of bytes removed (at most nbytes or all current data if nbytes == -1)
    # Zero memory copy
    skip(nbytes=-1)
    # Compares the contents of the buffer with another bytes like object
    # Zero memory copy if data is in one chunk, or a one-time memory copy if not
    __eq__(other)

    # This functions behave just like they do in bytearray
    # Zero memory copy if data is in one chunk, or a one-time memory copy if not.
    # Currently the result of all of this functions is a new copy, it's wise to use them when the outcome will produce small enough allocations that can fit the python allocator cache (less than 512 bytes).
    split(sep=None, maxsplit=-1)
    strip(bytes=None)
```

## How ?
TBD
