from setuptools import setup
from distutils.core import Extension


setup(ext_modules=[
    Extension(
        "chunkedbuffer.chunk",
        sources=[
            "chunkedbuffer/cchunk.c"
        ],
    )
])
