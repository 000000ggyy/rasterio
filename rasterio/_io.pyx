# cython: profile=True

import logging
import os
import os.path
import numpy as np
cimport numpy as np

ctypedef np.uint8_t DTYPE_UBYTE_t
ctypedef np.uint16_t DTYPE_UINT16_t
ctypedef np.int16_t DTYPE_INT16_t
ctypedef np.uint32_t DTYPE_UINT32_t
ctypedef np.int32_t DTYPE_INT32_t
ctypedef np.float32_t DTYPE_FLOAT32_t
ctypedef np.float64_t DTYPE_FLOAT64_t

from rasterio cimport _gdal
from rasterio import dtypes

log = logging.getLogger('rasterio')
class NullHandler(logging.Handler):
    def emit(self, record):
        pass
log.addHandler(NullHandler())

cdef int registered = 0

cdef void register():
    _gdal.GDALAllRegister()
    registered = 1

cdef int io_ubyte(
        void *hband,
        int mode,
        int xoff,
        int yoff,
        int width, 
        int height, 
        np.ndarray[DTYPE_UBYTE_t, ndim=2, mode='c'] buffer):
    return _gdal.GDALRasterIO(
        hband, mode, xoff, yoff, width, height,
        &buffer[0, 0], buffer.shape[1], buffer.shape[0], 1, 0, 0)

cdef int io_uint16(
        void *hband, 
        int mode,
        int xoff,
        int yoff,
        int width, 
        int height, 
        np.ndarray[DTYPE_UINT16_t, ndim=2, mode='c'] buffer):
    return _gdal.GDALRasterIO(
        hband, mode, xoff, yoff, width, height,
        &buffer[0, 0], buffer.shape[1], buffer.shape[0], 2, 0, 0)

cdef int io_int16(
        void *hband, 
        int mode,
        int xoff,
        int yoff,
        int width, 
        int height, 
        np.ndarray[DTYPE_INT16_t, ndim=2, mode='c'] buffer):
    return _gdal.GDALRasterIO(
        hband, mode, xoff, yoff, width, height,
        &buffer[0, 0], buffer.shape[1], buffer.shape[0], 3, 0, 0)

cdef int io_uint32(
        void *hband, 
        int mode,
        int xoff,
        int yoff,
        int width, 
        int height, 
        np.ndarray[DTYPE_UINT32_t, ndim=2, mode='c'] buffer):
    return _gdal.GDALRasterIO(
        hband, mode, xoff, yoff, width, height,
        &buffer[0, 0], buffer.shape[1], buffer.shape[0], 4, 0, 0)

cdef int io_int32(
        void *hband, 
        int mode,
        int xoff,
        int yoff,
        int width, 
        int height, 
        np.ndarray[DTYPE_INT32_t, ndim=2, mode='c'] buffer):
    return _gdal.GDALRasterIO(
        hband, mode, xoff, yoff, width, height,
        &buffer[0, 0], buffer.shape[1], buffer.shape[0], 5, 0, 0)

cdef int io_float32(
        void *hband, 
        int mode,
        int xoff,
        int yoff,
        int width, 
        int height, 
        np.ndarray[DTYPE_FLOAT32_t, ndim=2, mode='c'] buffer):
    return _gdal.GDALRasterIO(
        hband, mode, xoff, yoff, width, height,
        &buffer[0, 0], buffer.shape[1], buffer.shape[0], 6, 0, 0)

cdef int io_float64(
        void *hband,
        int mode,
        int xoff,
        int yoff,
        int width, 
        int height, 
        np.ndarray[DTYPE_FLOAT64_t, ndim=2, mode='c'] buffer):
    return _gdal.GDALRasterIO(
        hband, mode, xoff, yoff, width, height,
        &buffer[0, 0], buffer.shape[1], buffer.shape[0], 7, 0, 0)

# Window utils
# A window is a 2D ndarray indexer in the form of a tuple:
# ((row_start, row_stop), (col_start, col_stop))

cpdef eval_window(object window, int height, int width):
    """Evaluates a window tuple that might contain negative values
    in the context of a raster height and width."""
    cdef int r_start, r_stop, c_start, c_stop
    r, c = window
    r_start = r[0] or 0
    if r_start < 0:
        if height < 0:
            raise ValueError("invalid height: %d" % height)
        r_start += height
    r_stop = r[1] or height
    if r_stop < 0:
        if height < 0:
            raise ValueError("invalid height: %d" % height)
        r_stop += height
    if not r_stop >= r_start:
        raise ValueError(
            "invalid window: row range (%d, %d)" % (r_start, r_stop))
    c_start = c[0] or 0
    if c_start < 0:
        if width < 0:
            raise ValueError("invalid width: %d" % width)
        c_start += width
    c_stop = c[1] or width
    if c_stop < 0:
        if width < 0:
            raise ValueError("invalid width: %d" % width)
        c_stop += width
    if not c_stop >= c_start:
        raise ValueError(
            "invalid window: col range (%d, %d)" % (c_start, c_stop))
    return (r_start, r_stop), (c_start, c_stop)

def window_shape(window, height=-1, width=-1):
    """Returns shape of a window.

    height and width arguments are optional if there are no negative
    values in the window.
    """
    (a, b), (c, d) = eval_window(window, height, width)
    return b-a, d-c

def window_index(window):
    return tuple(slice(*w) for w in window)

cdef class RasterReader:
    # Read-only access to raster data and metadata.
    
    cdef void *_hds
    cdef int _count
    
    cdef readonly object name
    cdef readonly object mode
    cdef readonly object width, height
    cdef readonly object shape
    cdef public object driver
    cdef public object _dtypes
    cdef public object _closed
    cdef public object _crs
    cdef public object _crs_wkt
    cdef public object _transform
    cdef public object _block_shapes
    cdef public object _nodatavals

    def __init__(self, path):
        self.name = path
        self.mode = 'r'
        self._hds = NULL
        self._count = 0
        self._closed = True
        self._dtypes = []
        self._block_shapes = []
        self._nodatavals = []
    
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
        name_b = self.name.encode('utf-8')
        cdef const char *fname = name_b
        self._hds = _gdal.GDALOpen(fname, 0)
        if not self._hds:
            raise ValueError("Null dataset")

        cdef void *drv
        cdef const char *drv_name
        drv = _gdal.GDALGetDatasetDriver(self._hds)
        drv_name = _gdal.GDALGetDriverShortName(drv)
        self.driver = drv_name.decode('utf-8')

        self._count = _gdal.GDALGetRasterCount(self._hds)
        self.width = _gdal.GDALGetRasterXSize(self._hds)
        self.height = _gdal.GDALGetRasterYSize(self._hds)
        self.shape = (self.height, self.width)

        self._transform = self.read_transform()
        self._crs = self.read_crs()
        self._crs_wkt = self.read_crs_wkt()
        
        self._closed = False

    def read_crs(self):
        cdef char *proj_c = NULL
        if self._hds is NULL:
            raise ValueError("Null dataset")
        cdef void *osr = _gdal.OSRNewSpatialReference(
            _gdal.GDALGetProjectionRef(self._hds))
        log.debug("Got coordinate system")
        crs = {}
        if osr is not NULL:
            _gdal.OSRExportToProj4(osr, &proj_c)
            if proj_c is NULL:
                raise ValueError("Null projection")
            proj_b = proj_c
            log.debug("Params: %s", proj_b)
            value = proj_b.decode()
            value = value.strip()
            for param in value.split():
                kv = param.split("=")
                if len(kv) == 2:
                    k, v = kv
                    try:
                        v = float(v)
                        if v % 1 == 0:
                            v = int(v)
                    except ValueError:
                        # Leave v as a string
                        pass
                elif len(kv) == 1:
                    k, v = kv[0], True
                else:
                    raise ValueError("Unexpected proj parameter %s" % param)
                k = k.lstrip("+")
                crs[k] = v
            _gdal.CPLFree(proj_c)
            _gdal.OSRDestroySpatialReference(osr)
        else:
            log.debug("Projection not found (cogr_crs was NULL)")
        return crs

    def read_crs_wkt(self):
        cdef char *proj_c = NULL
        if self._hds is NULL:
            raise ValueError("Null dataset")
        cdef void *osr = _gdal.OSRNewSpatialReference(
            _gdal.GDALGetProjectionRef(self._hds))
        log.debug("Got coordinate system")
        crs = {}
        if osr is not NULL:
            _gdal.OSRExportToWkt(osr, &proj_c)
            if proj_c is NULL:
                raise ValueError("Null projection")
            proj_b = proj_c
            crs_wkt = proj_b.decode('utf-8')
            _gdal.CPLFree(proj_c)
            _gdal.OSRDestroySpatialReference(osr)
        else:
            log.debug("Projection not found (cogr_crs was NULL)")
        return crs_wkt

    def read_transform(self):
        if self._hds is NULL:
            raise ValueError("Null dataset")
        cdef double gt[6]
        _gdal.GDALGetGeoTransform(self._hds, gt)
        transform = [0]*6
        for i in range(6):
            transform[i] = gt[i]
        return transform

    def stop(self):
        if self._hds is not NULL:
            _gdal.GDALClose(self._hds)
        self._hds = NULL
    
    def close(self):
        self.stop()
        self._closed = True
    
    def __enter__(self):
        return self

    def __exit__(self, type, value, traceback):
        self.close()
    
    @property
    def closed(self):
        return self._closed

    @property
    def count(self):
        if not self._count:
            if not self._hds:
                raise ValueError("Can't read closed raster file")
            self._count = _gdal.GDALGetRasterCount(self._hds)
        return self._count

    @property
    def indexes(self):
        return list(range(1, self.count+1))

    @property
    def dtypes(self):
        """Returns an ordered list of all band data types."""
        cdef void *hband = NULL
        if not self._dtypes:
            if not self._hds:
                raise ValueError("can't read closed raster file")
            for i in range(self._count):
                hband = _gdal.GDALGetRasterBand(self._hds, i+1)
                self._dtypes.append(
                    dtypes.dtype_fwd[_gdal.GDALGetRasterDataType(hband)])
        return self._dtypes
    
    @property
    def block_shapes(self):
        """Returns an ordered list of block shapes for all bands.
        
        Shapes are tuples and have the same ordering as the dataset's
        shape: (count of image rows, count of image columns).
        """
        cdef void *hband = NULL
        cdef int xsize, ysize
        if not self._block_shapes:
            if not self._hds:
                raise ValueError("can't read closed raster file")
            for i in range(self._count):
                hband = _gdal.GDALGetRasterBand(self._hds, i+1)
                _gdal.GDALGetBlockSize(hband, &xsize, &ysize)
                self._block_shapes.append((ysize, xsize))
        return self._block_shapes

    @property
    def nodatavals(self):
        """Returns a band-ordered list of nodata values."""
        cdef void *hband = NULL
        cdef double val
        cdef int success
        if not self._nodatavals:
            if not self._hds:
                raise ValueError("can't read closed raster file")
            for i in range(self._count):
                hband = _gdal.GDALGetRasterBand(self._hds, i+1)
                val = _gdal.GDALGetRasterNoDataValue(hband, &success)
                if not success:
                    val = None
                self._nodatavals.append(val)
        return self._nodatavals

    def block_windows(self, bdix):
        """Returns an iterator over a band's block windows and their
        indexes.

        The positional parameter `bidx` takes the index (starting at 1)
        of the desired band. Block windows are tuples

            ((row_start, row_stop), (col_start, col_stop))

        For example, ((0, 2), (0, 2)) defines a 2 x 2 block at the upper
        left corner of the raster dataset.

        This iterator yields blocks "left to right" and "top to bottom"
        and is similar to Python's enumerate() in that it also returns
        indexes.

        The primary use of this function is to obtain windows to pass to
        read_band() for highly efficient access to raster block data.
        """
        cdef int i, j
        h, w = self.block_shapes[bdix-1]
        d, m = divmod(self.height, h)
        nrows = d + int(m>0)
        d, m = divmod(self.width, w)
        ncols = d + int(m>0)
        for j in range(nrows):
            row = j * h
            height = min(h, self.height - row)
            for i in range(ncols):
                col = i * w
                width = min(w, self.width - col)
                yield (j, i), ((row, row+height), (col, col+width))

    @property
    def bounds(self):
        """Returns the lower left and upper right bounds of the dataset
        in the units of its coordinate reference system.
        
        The returned value is a tuple:
        (lower left x, lower left y, upper right x, upper right y)
        """
        t = self.transform
        return (t[0], t[3]+t[5]*self.height, t[0]+t[1]*self.width, t[3])

    def ul(self, row, col):
        """Returns the coordinates (x, y) of the upper left corner of a 
        pixel at `row` and `col` in the units of the dataset's
        coordinate reference system.
        """
        t = self.transform
        return t[0]+t[1]*col, t[3]+t[5]*row

    @property
    def meta(self):
        return {
            'driver': self.driver,
            'width': self.width,
            'height': self.height,
            'count': self.count,
            'crs': self.crs,
            'transform': self.transform }

    def get_crs(self):
        if not self._crs:
            self._crs = self.read_crs()
        return self._crs
    crs = property(get_crs)

    def get_crs_wkt(self):
        if not self._crs_wkt:
            self._crs = self.read_crs_wkt()
        return self._crs_wkt
    crs_wkt = property(get_crs_wkt)

    def get_transform(self):
        """Get an affine transformation that maps pixel row/column
        coordinates to coordinates in the specified crs. The affine
        transformation is represented by a six-element sequence.
        Reference system coordinates can be calculated by the following
        formula

          X = Item 0 + Column * Item 1 + Row * Item 2
          Y = Item 3 + Column * Item 4 + Row * Item 5

        See also this class's ul() method.
        """
        if not self._transform:
            self._transform = self.read_transform()
        return self._transform
    transform = property(get_transform)
    
    def read_band(self, bidx, out=None, window=None):
        """Read the `bidx` band into an `out` array if provided, 
        otherwise return a new array.

        Band indexes begin with 1: read_band(1) returns the first band.

        The optional `window` argument is a 2 item tuple. The first item
        is a tuple containing the indexes of the rows at which the
        window starts and stops and the second is a tuple containing the
        indexes of the columns at which the window starts and stops. For
        example, ((0, 2), (0, 2)) defines a 2x2 window at the upper left
        of the raster dataset.
        """
        if bidx not in self.indexes:
            raise IndexError("band index out of range")
        i = self.indexes.index(bidx)
        if not self._hds:
            raise ValueError("can't read closed raster file")
        if out is not None and out.dtype != self.dtypes[i]:
            raise ValueError("band and output array dtypes do not match")
        
        cdef void *hband = _gdal.GDALGetRasterBand(self._hds, bidx)
        if hband is NULL:
            raise ValueError("NULL band")
        
        dtype = self.dtypes[i]
        if out is None:
            out_shape = (
                window 
                and window_shape(window, self.height, self.width) 
                or self.shape)
            out = np.zeros(out_shape, dtype)
        if window:
            window = eval_window(window, self.height, self.width)
            yoff = window[0][0]
            xoff = window[1][0]
            height = window[0][1] - yoff
            width = window[1][1] - xoff
        else:
            xoff = yoff = 0
            width = self.width
            height = self.height
        if dtype == dtypes.ubyte:
            retval = io_ubyte(
                hband, 0, xoff, yoff, width, height, out)
        elif dtype == dtypes.uint16:
            retval = io_uint16(
                hband, 0, xoff, yoff, width, height, out)
        elif dtype == dtypes.int16:
            retval = io_int16(
                hband, 0, xoff, yoff, width, height, out)
        elif dtype == dtypes.uint32:
            retval = io_uint32(
                hband, 0, xoff, yoff, width, height, out)
        elif dtype == dtypes.int32:
            retval = io_int32(
                hband, 0, xoff, yoff, width, height, out)
        elif dtype == dtypes.float32:
            retval = io_float32(
                hband, 0, xoff, yoff, width, height, out)
        elif dtype == dtypes.float64:
            retval = io_float64(
                hband, 0, xoff, yoff, width, height, out)
        else:
            raise ValueError("Invalid dtype")
        # TODO: handle errors (by retval).
        return out


cdef class RasterUpdater(RasterReader):
    # Read-write access to raster data and metadata.
    # TODO: the r+ mode.
    cdef readonly object _init_dtype, _init_nodata, _options

    def __init__(
            self, path, mode, driver=None,
            width=None, height=None, count=None, 
            crs=None, transform=None, dtype=None,
            nodata=None,
            **kwargs):
        self.name = path
        self.mode = mode
        self.driver = driver
        self.width = width
        self.height = height
        self._count = count
        self._init_dtype = dtype
        self._init_nodata = nodata
        self._hds = NULL
        self._count = count
        self._crs = crs
        self._transform = transform
        self._closed = True
        self._dtypes = []
        self._options = kwargs.copy()
    
    def __repr__(self):
        return "<%s RasterUpdater '%s' at %s>" % (
            self.closed and 'closed' or 'open', 
            self.name, 
            hex(id(self)))

    def start(self):
        cdef const char *drv_name = NULL
        cdef char **options = NULL
        cdef char *key_c, *val_c = NULL
        cdef void *drv = NULL
        cdef void *hband = NULL
        cdef int success
        if not registered:
            register()
        name_b = self.name.encode('utf-8')
        cdef const char *fname = name_b
        
        if self.mode == 'w':
            # GDAL can Create() GTiffs. Many other formats only support
            # CreateCopy(). Rasterio lets you write GTiffs *only* for now.
            if self.driver not in ['GTiff']:
                raise ValueError("only GTiffs can be opened in 'w' mode")

            # Delete existing file, create.
            if os.path.exists(self.name):
                os.unlink(self.name)
            
            driver_b = self.driver.encode('utf-8')
            drv_name = driver_b
            drv = _gdal.GDALGetDriverByName(drv_name)
            if drv is NULL:
                raise ValueError("NULL driver for %s", self.driver)
            
            # Find the equivalent GDAL data type or raise an exception
            # We've mapped numpy scalar types to GDAL types so see
            # if we can crosswalk those.
            if hasattr(self._init_dtype, 'type'):
                tp = self._init_dtype.type
                if tp not in dtypes.dtype_rev:
                    raise ValueError(
                        "Unsupported dtype: %s" % self._init_dtype)
                else:
                    gdal_dtype = dtypes.dtype_rev.get(tp)
            else:
                gdal_dtype = dtypes.dtype_rev.get(self._init_dtype)
            
            # Creation options
            for k, v in self._options.items():
                k, v = k.upper(), v.upper()
                key_b = k.encode('utf-8')
                val_b = v.encode('utf-8')
                key_c = key_b
                val_c = val_b
                options = _gdal.CSLSetNameValue(options, key_c, val_c)
                log.debug("Option: %r\n", (k, v))
            
            self._hds = _gdal.GDALCreate(
                drv, fname, self.width, self.height, self._count,
                gdal_dtype, options)
            
            if self._init_nodata is not None:
                if not self._hds:
                    raise ValueError("can't read closed raster file")
                for i in range(self._count):
                    hband = _gdal.GDALGetRasterBand(self._hds, i+1)
                    success = _gdal.GDALSetRasterNoDataValue(
                                    hband, self._init_nodata)

            if self._transform:
                self.write_transform(self._transform)
            if self._crs:
                self.write_crs(self._crs)
        
        elif self.mode == 'a':
            self._hds = _gdal.GDALOpen(fname, 1)
        
        self._count = _gdal.GDALGetRasterCount(self._hds)
        self.width = _gdal.GDALGetRasterXSize(self._hds)
        self.height = _gdal.GDALGetRasterYSize(self._hds)
        self.shape = (self.height, self.width)
        self._closed = False

        if options:
            _gdal.CSLDestroy(options)

    def get_crs(self):
        if not self._crs:
            self._crs = self.read_crs()
        return self._crs
    
    def write_crs(self, crs):
        if self._hds is NULL:
            raise ValueError("Can't read closed raster file")
        cdef void *osr = _gdal.OSRNewSpatialReference(NULL)
        if osr is NULL:
            raise ValueError("Null spatial reference")
        params = []
        for k, v in crs.items():
            if v is True or (k == 'no_defs' and v):
                params.append("+%s" % k)
            else:
                params.append("+%s=%s" % (k, v))
        proj = " ".join(params)
        proj_b = proj.encode()
        cdef const char *proj_c = proj_b
        _gdal.OSRImportFromProj4(osr, proj_c)
        cdef char *wkt
        _gdal.OSRExportToWkt(osr, &wkt)
        _gdal.GDALSetProjection(self._hds, wkt)
        _gdal.CPLFree(wkt)
        _gdal.OSRDestroySpatialReference(osr)

        self._crs = crs
    
    crs = property(get_crs, write_crs)

    def write_transform(self, transform):
        if self._hds is NULL:
            raise ValueError("Can't read closed raster file")
        cdef double gt[6]
        for i in range(6):
            gt[i] = transform[i]
        retval = _gdal.GDALSetGeoTransform(self._hds, gt)
        self._transform = transform

    def get_transform(self):
        if not self._transform:
            self._transform = self.read_transform()
        return self._transform

    transform = property(get_transform, write_transform)

    def write_band(self, bidx, src, window=None):
        """Write the src array into the `bidx` band.

        Band indexes begin with 1: read_band(1) returns the first band.

        The optional `window` argument takes a tuple like:
        
            ((row_start, row_stop), (col_start, col_stop))
            
        specifying a raster subset to write into.
        """
        if bidx not in self.indexes:
            raise IndexError("band index out of range")
        i = self.indexes.index(bidx)
        if not self._hds:
            raise ValueError("can't read closed raster file")
        if src is not None and src.dtype != self.dtypes[i]:
            raise ValueError("band and srcput array dtypes do not match")
        
        cdef void *hband = _gdal.GDALGetRasterBand(self._hds, bidx)
        if hband is NULL:
            raise ValueError("NULL band")
        
        if window:
            window = eval_window(window, self.height, self.width)
            yoff = window[0][0]
            xoff = window[1][0]
            height = window[0][1] - yoff
            width = window[1][1] - xoff
        else:
            xoff = yoff = 0
            width = self.width
            height = self.height
        dtype = self.dtypes[i]
        if dtype == dtypes.ubyte:
            retval = io_ubyte(
                hband, 1, xoff, yoff, width, height, src)
        elif dtype == dtypes.uint16:
            retval = io_uint16(
                hband, 1, xoff, yoff, width, height, src)
        elif dtype == dtypes.int16:
            retval = io_int16(
                hband, 1, xoff, yoff, width, height, src)
        elif dtype == dtypes.uint32:
            retval = io_uint32(
                hband, 1, xoff, yoff, width, height, src)
        elif dtype == dtypes.int32:
            retval = io_int32(
                hband, 1, xoff, yoff, width, height, src)
        elif dtype == dtypes.float32:
            retval = io_float32(
                hband, 1, xoff, yoff, width, height, src)
        elif dtype == dtypes.float64:
            retval = io_float64(
                hband, 1, xoff, yoff, width, height, src)
        else:
            raise ValueError("Invalid dtype")
        # TODO: handle errors (by retval).

