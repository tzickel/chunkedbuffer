from setuptools import setup
from Cython.Build import cythonize
import os

#os.environ['CFLAGS'] = '- -Wall'
setup(ext_modules=cythonize("chunkedbuffer/*.pyx", compiler_directives={'language_level' : "3"}))
#setup()