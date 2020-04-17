## What?
This library provides an API for stream processing with emphesis on minimizing memory allocations and copying.

Please note that this project is currently alpha quality and the API is not finalized. Please provide feedback if you think the API is convenient enough or not. A permissive license will be chosen once the API will be more mature for wide spread consumption.

## Usage
A typical use case would be to create a Buffer instance and writing data to it with get_chunk()/chunk_written() methods for API which provide an readinto like method or with the extend() method for any bytes like object.

```python
from chunkedbuffer import buffer

b = Buffer()
b.extend(b'test\r\n')
```

You can then call the find() method to find a given delimiter in the stream or call take()/peek() methods to read bytes from the stream.

```python
idx = b.find(b'\r\n')
if idx != -1:
    msg = b.take(idx) # This is not a copy, but a pointer
    b.skip(2) # We don't need \r\n
```

or the same:

```python
msg = b.takeuntil(b'\r\n') # Will be None if not found
```

Those methods return a new Buffer which points only to that specific data.

You can then pass the Buffer instance to any method which accepts a bytes like object or call bytearray like operations on it such as split(), strip(), etc....

```python
assert msg.strip(b't') == b'es'
```

At the bottom of the document there are technical notes for those who want to understand the inner-workings of this library.

## Roadmap
- [ ] API Finalization
- [ ] Choose license
- [ ] Resolve all TODO in code
- [ ] More test coverage
- [ ] A pure python version for PyPy
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
    msg = b"9\r\nLet's try\r\n6\r\n to pa\r\n7\r\nrse an \r\n5\r\nchunk\r\n2\r\ned\r\n6\r\n messa\r\n7\r\nge like\r\n7\r\n redis \r\n24\r\nor HTTP chunked encoding\r\n4\r\n use\r\n"
    
    # This is a toy chunked message parser to demonstrate some of the API
    buffer = Buffer()
    # Since we aren't reading from I/O let's just copy the message inside
    buffer.extend(msg)
    # We will keep the pointers to the message contents in a list
    chunks = []
    # length will be None when we need to read the length of the chunk or the number of bytes left to read in a chunk
    length = None
    while True:
        # We have length bytes to read from the message
        if length is not None:
            # In network I/O there might be less to read than length bytes so we do it inside a loop
            chunk = buffer.take(length)
            chunk_length = len(chunk)
            if chunk_length:
                # Save a pointer to this part of the message for later retreival
                chunks.append(chunk)
                length -= chunk_length
            if length == 0:
                # We don't need the ending \r\n
                buffer.skip(2)
                # We've finished reading this part of the message
                length = None
        # Read how many bytes the next part of the message is
        if length is None:
            # When the buffer is empty, stop parsing
            if not buffer:
                break
            # Look for the next delimiter
            idx = buffer.find(b"\r\n")
            if idx == -1:
                break
            # We also read the \r\n after the length, since int parsing can handle it
            length = int(buffer.take(idx + 2))
    # We create one big Buffer that points to all of the message parts
    buffer = Buffer.merge(chunks)
    # We can check the value inside the newly created Buffer from all the previous pointers
    assert buffer == b"Let's try to parse an chunked message like redis or HTTP chunked encoding use"
    # An Buffer is not hashable, so if you want to use it as a bytes replacment, cast it to bytes explicitly
    print(bytes(buffer))
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
    # Zero memory copy (unless more than one chunk, and then just copies length of s*2 from each chunk)
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
    # Combines find() and take() returning None if s was not found. include_s=True will include it, otherwise skip it
    takeuntil(s, include_s=False)
    # Compares the contents of the buffer with another bytes like object
    # Zero memory copy if data is in one chunk, or a one-time memory copy if not
    __eq__(other)

    # This functions behave just like they do in bytearray (more functions can be added)
    # Zero memory copy if data is in one chunk, or a one-time memory copy if not.
    # Currently the result of all of this functions is a new copy, it's wise to use them when the outcome will produce small enough allocations that can fit the python allocator cache (less than 512 bytes).
    split(sep=None, maxsplit=-1)
    strip(bytes=None)
```

## How ?
TBD
