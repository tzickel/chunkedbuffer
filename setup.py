from setuptools import setup
from Cython.Build import cythonize
import os


coverage = os.environ.get('CYTHON_COVERAGE', False) in ('1', 'true', '"true"')
if coverage:
    setup(ext_modules=cythonize("chunkedbuffer/*.pyx", language_level=3, force=True, compiler_directives={'linetrace': True}))
else:
    setup(ext_modules=cythonize("chunkedbuffer/*.pyx", language_level=3, force=True, compiler_directives={'boundscheck': False, 'wraparound': False, 'initializedcheck': False, 'always_allow_keywords': False}))
