from setuptools import setup
from Cython.Build import cythonize
setup(ext_modules=cythonize("chunkedbuffer/*.pyx", compiler_directives={"language_level" : "3"}))
# TODO (cythonize) validate all code for this
#setup(ext_modules=cythonize("chunkedbuffer/*.pyx", compiler_directives={"language_level" : "3", "boundscheck": False, "wraparound": False, "initializedcheck": False}))
