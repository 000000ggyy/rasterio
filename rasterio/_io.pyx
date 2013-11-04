import logging
import numpy as np
cimport numpy as np

ctypedef np.uint8_t DTYPE_UBYTE_t

from rasterio cimport _gdal

cdef int registered = 0

cdef void register():
    _gdal.GDALAllRegister()
    registered = 1

cdef class RasterReader:
    
    cdef void *_hds
    cdef int _count
    
    cdef readonly object name
    cdef readonly object width, height
    cdef readonly object shape
    cdef public object _closed

    def __cinit__(self, path):
        self.name = path
        self._hds = NULL
        self._count = 0
        self._closed = True
    
    def __dealloc__(self):
        self.stop()
    
    def __repr__(self):
        return "<%s RasterReader '%s' at %s>" % (
            self.closed and 'closed' or 'open', 
            self.name, 
            hex(id(self)))

    def start(self):
        if not registered:
            register()
        cdef const char *fname = self.name
        self._hds = _gdal.GDALOpen(fname, 0)
        self._count = _gdal.GDALGetRasterCount(self._hds)
        self.width = _gdal.GDALGetRasterXSize(self._hds)
        self.height = _gdal.GDALGetRasterYSize(self._hds)
        self.shape = (self.height, self.width)
        self._closed = False

    def stop(self):
        if self._hds is not NULL:
            _gdal.GDALClose(self._hds)
        self._hds = NULL
    
    def close(self):
        self.stop()
        self._closed = True
    
    @property
    def count(self):
        if self._hds is not NULL:
            self._count = _gdal.GDALGetRasterCount(self._hds)
        return self._count
    
    @property
    def closed(self):
        return self._closed

    def __enter__(self):
        return self

    def __exit__(self, type, value, traceback):
        self.close()

    def read_band(self, i, out=None):
        """Read the ith band into an `out` array if provided, otherwise
        return a new array."""
        cdef void *hband = _gdal.GDALGetRasterBand(self._hds, i+1)
        if out is None:
            out = np.zeros(self.shape, np.ubyte)
        cdef np.ndarray[DTYPE_UBYTE_t, ndim=2, mode="c"] im = out
        _gdal.GDALRasterIO(
            hband, 0, 0, 0, self.width, self.height,
            &im[0, 0], self.width, self.height, 1, 0, 0)
        return out

cdef class RasterUpdateSession:
    pass


