# cython: boundscheck=False, c_string_type=unicode, c_string_encoding=utf8

"""Numpy-free base classes."""

from __future__ import absolute_import

import logging
import math
import os
import sys
import warnings

from libc.stdlib cimport malloc, free

from rasterio cimport _gdal, _ogr
from rasterio.crs import CRS
from rasterio._err import (
    CPLErrors, GDALError, CPLE_IllegalArgError, CPLE_OpenFailedError,
    CPLE_NotSupportedError)
from rasterio import dtypes
from rasterio.coords import BoundingBox
from rasterio.enums import (
    ColorInterp, Compression, Interleaving, PhotometricInterp)
from rasterio.env import Env
from rasterio.errors import RasterioIOError, CRSError, DriverRegistrationError
from rasterio.transform import Affine
from rasterio.vfs import parse_path, vsi_path

include "gdal.pxi"


log = logging.getLogger(__name__)



def check_gdal_version(major, minor):
    """Return True if the major and minor versions match."""
    return bool(_gdal.GDALCheckVersion(int(major), int(minor), NULL))


def gdal_version():
    """Return the version as a major.minor.patchlevel string."""
    return _gdal.GDALVersionInfo("RELEASE_NAME")


cdef get_driver_name(GDALDriverH driver):
    """Return Python name of the driver"""
    return _gdal.GDALGetDriverShortName(driver)


def get_dataset_driver(path):
    """Return the name of the driver that would be used to open the
    dataset at the given path."""
    cdef GDALDatasetH dataset = NULL
    cdef GDALDriverH driver = NULL

    path, archive, scheme = parse_path(path)
    path = vsi_path(path, archive, scheme)
    path = path.encode('utf-8')

    try:
        with CPLErrors() as cple:
            dataset = _gdal.GDALOpen(<const char *>path, 0)
            cple.check()
    except CPLE_OpenFailedError as exc:
        if dataset != NULL:
            _gdal.GDALClose(dataset)
        raise RasterioIOError(str(exc))

    driver = _gdal.GDALGetDatasetDriver(dataset)
    drivername = get_driver_name(driver)

    _gdal.GDALClose(dataset)

    return drivername


def driver_supports_mode(drivername, creation_mode):
    """Return True if the driver supports the mode"""
    cdef GDALDriverH driver = NULL
    cdef char **metadata = NULL

    drivername = drivername.encode('utf-8')
    creation_mode = creation_mode.encode('utf-8')

    driver = _gdal.GDALGetDriverByName(<const char *>drivername)
    if driver == NULL:
        raise DriverRegistrationError(
            "No such driver registered: %s", drivername)

    metadata = _gdal.GDALGetMetadata(driver, NULL)
    if metadata == NULL:
        raise ValueError("Driver has no metadata")

    return bool(
        _gdal.CSLFetchBoolean(metadata, <const char *>creation_mode, 0))


def driver_can_create(drivername):
    """Return True if the driver has CREATE capability"""
    return driver_supports_mode(drivername, 'DCAP_CREATE')


def driver_can_create_copy(drivername):
    """Return True if the driver has CREATE_COPY capability"""
    return driver_supports_mode(drivername, 'DCAP_CREATECOPY')


cdef class DatasetBase(object):
    """Dataset base class."""

    def __init__(self, path, options=None):
        self.name = path
        self.mode = 'r'
        self.options = options or {}
        self._hds = NULL
        self._count = 0
        self._closed = True
        self._dtypes = []
        self._block_shapes = None
        self._nodatavals = []
        self._crs = None
        self._read = False
    
    def __repr__(self):
        return "<%s RasterReader name='%s' mode='%s'>" % (
            self.closed and 'closed' or 'open', 
            self.name,
            self.mode)

    def start(self):
        """Start of the dataset reader life cycle."""
        cdef GDALDriverH driver

        path, archive, scheme = parse_path(self.name)
        path = vsi_path(path, archive=archive, scheme=scheme)
        path = path.encode('utf-8')

        try:
            with CPLErrors() as cple:
                self._hds = _gdal.GDALOpen(<const char *>path, 0)
                cple.check()
        except CPLE_OpenFailedError as err:
            raise RasterioIOError(err.errmsg)

        driver = _gdal.GDALGetDatasetDriver(self._hds)
        self.driver = get_driver_name(driver)

        self._count = _gdal.GDALGetRasterCount(self._hds)
        self.width = _gdal.GDALGetRasterXSize(self._hds)
        self.height = _gdal.GDALGetRasterYSize(self._hds)
        self.shape = (self.height, self.width)

        self._transform = self.read_transform()
        self._crs = self.read_crs()

        # touch self.meta
        _ = self.meta

        self._closed = False
        log.debug("Dataset %r is started.", self)

    cdef GDALDatasetH handle(self) except NULL:
        """Return the object's GDAL dataset handle"""
        return self._hds

    cdef GDALRasterBandH band(self, int bidx) except NULL:
        """Return a GDAL raster band handle"""
        cdef GDALRasterBandH band = NULL

        try:
            with CPLErrors() as cple:
                band = _gdal.GDALGetRasterBand(self._hds, bidx)
                cple.check()
        except CPLE_IllegalArgError as exc:
            raise IndexError(str(exc))

        if band == NULL:
            raise ValueError("NULL band")

        return band

    def _has_band(self, bidx):
        try:
            return self.band(bidx) != NULL
        except IndexError:
            return False

    def read_crs(self):
        """Return the GDAL dataset's stored CRS"""
        cdef char *proj = NULL
        cdef const char *wkt = NULL
        cdef OGRSpatialReferenceH osr = NULL

        if self._hds == NULL:
            raise ValueError("Null dataset")

        wkt = _gdal.GDALGetProjectionRef(self.handle())
        if wkt is NULL:
            raise ValueError("Unexpected NULL spatial reference")

        crs = CRS()

        # Test that the WKT definition isn't just an empty string, which
        # can happen when the source dataset is not georeferenced.
        wkt_string = wkt
        if len(wkt_string) > 0:

            osr = _gdal.OSRNewSpatialReference(wkt)
            if osr == NULL:
                raise ValueError("Unexpected NULL spatial reference")
            log.debug("Got coordinate system")

            # Try to find an EPSG code in the spatial referencing.
            if _gdal.OSRAutoIdentifyEPSG(osr) == 0:
                key = _gdal.OSRGetAuthorityName(osr, NULL)
                val = _gdal.OSRGetAuthorityCode(osr, NULL)
                log.info("Authority key: %s, value: %s", key, val)
                crs['init'] = u'epsg:' + val
            else:
                log.info("Failed to auto identify EPSG")
                _gdal.OSRExportToProj4(osr, &proj)
                if proj == NULL:
                    raise ValueError("Unexpected Null spatial reference")

                value = proj
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
                        raise ValueError(
                            "Unexpected proj parameter %s" % param)
                    k = k.lstrip("+")
                    crs[k] = v

            _gdal.CPLFree(proj)
            _gdal.OSRDestroySpatialReference(osr)
        else:
            log.debug("GDAL dataset has no projection.")
        return crs

    def read_transform(self):
        """Return the stored GDAL GeoTransform"""
        cdef double gt[6]

        if self._hds == NULL:
            raise ValueError("Null dataset")
        err = _gdal.GDALGetGeoTransform(self._hds, gt)
        if err == GDALError.failure:
            warnings.warn(
                "Dataset has no geotransform set. Default transform "
                "will be applied (Affine.identity())",
                UserWarning
            )

        return [gt[i] for i in range(6)]

    def stop(self):
        """Ends the dataset's life cycle"""
        if self._hds != NULL:
            _gdal.GDALFlushCache(self._hds)
            _gdal.GDALClose(self._hds)
        self._hds = NULL
        log.debug("Dataset %r has been stopped.", self)

    def close(self):
        self.stop()
        self._closed = True
        log.debug("Dataset %r has been closed.", self)

    def __enter__(self):
        log.debug("Entering Dataset %r context.", self)
        return self

    def __exit__(self, type, value, traceback):
        self.close()
        log.debug("Exited Dataset %r context.", self)

    def __dealloc__(self):
        if self._hds != NULL:
            _gdal.GDALClose(self._hds)

    @property
    def closed(self):
        return self._closed

    @property
    def count(self):
        if not self._count:
            if self._hds == NULL:
                raise ValueError("Can't read closed raster file")
            self._count = _gdal.GDALGetRasterCount(self._hds)
        return self._count

    @property
    def indexes(self):
        return tuple(range(1, self.count+1))

    @property
    def dtypes(self):
        """Returns an ordered tuple of all band data types."""
        cdef GDALRasterBandH band = NULL

        if not self._dtypes:
            for i in range(self._count):
                band = self.band(i + 1)
                self._dtypes.append(
                    dtypes.dtype_fwd[_gdal.GDALGetRasterDataType(band)])

        return tuple(self._dtypes)
    
    @property
    def block_shapes(self):
        """Returns an ordered list of block shapes for all bands.
        
        Shapes are tuples and have the same ordering as the dataset's
        shape: (count of image rows, count of image columns).
        """
        cdef GDALRasterBandH band = NULL
        cdef int xsize, ysize

        if self._block_shapes is None:
            self._block_shapes = []

            for i in range(self._count):
                band = self.band(i + 1)
                _gdal.GDALGetBlockSize(band, &xsize, &ysize)
                self._block_shapes.append((ysize, xsize))

        return tuple(self._block_shapes)

    def get_nodatavals(self):
        cdef GDALRasterBandH band = NULL
        cdef double nodataval
        cdef int success = 0

        if not self._nodatavals:

            for i in range(self._count):
                band = self.band(i + 1)
                dtype = dtypes.dtype_fwd[_gdal.GDALGetRasterDataType(band)]
                nodataval = _gdal.GDALGetRasterNoDataValue(band, &success)
                val = nodataval
                # GDALGetRasterNoDataValue() has two ways of telling you that
                # there's no nodata value. The success flag might come back
                # 0 (FALSE). Even if it comes back 1 (TRUE), you still need
                # to check that the return value is within the range of the
                # data type. If so, the band has a nodata value. If not,
                # there's no nodata value.
                if (success == 0 or
                        val < dtypes.dtype_ranges[dtype][0] or
                        val > dtypes.dtype_ranges[dtype][1]):
                    val = None
                log.debug(
                    "Nodata success: %d, Nodata value: %f", success, nodataval)
                self._nodatavals.append(val)

        return tuple(self._nodatavals)

    property nodatavals:
        """Nodata values for each band."""
        def __get__(self):
            return self.get_nodatavals()

    property nodata:
        """The dataset's single nodata value."""
        def __get__(self):
            if self.count == 0:
                return None
            return self.nodatavals[0]

    property mask_flags:
        """Mask flags for each band."""
        def __get__(self):
            cdef GDALRasterBandH band = NULL
            return [_gdal.GDALGetMaskFlags(self.band(j)) for j in self.indexes]

    def block_windows(self, bidx=0):
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
        read() for highly efficient access to raster block data.
        """
        cdef int i, j

        block_shapes = self.block_shapes
        if bidx < 1:
            if len(set(block_shapes)) > 1:
                raise ValueError(
                    "A band index must be provided when band block shapes"
                    "are inhomogeneous")
            bidx = 1
        h, w = block_shapes[bidx-1]
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

    property bounds:
        """Returns the lower left and upper right bounds of the dataset
        in the units of its coordinate reference system.
        
        The returned value is a tuple:
        (lower left x, lower left y, upper right x, upper right y)
        """
        def __get__(self):
            a, b, c, d, e, f, _, _, _ = self.affine
            return BoundingBox(c, f+e*self.height, c+a*self.width, f)
    
    property res:
        """Returns the (width, height) of pixels in the units of its
        coordinate reference system."""
        def __get__(self):
            a, b, c, d, e, f, _, _, _ = self.affine
            if b == d == 0:
                return a, -e
            else:
                return math.sqrt(a*a+d*d), math.sqrt(b*b+e*e)

    def ul(self, row, col):
        """Returns the coordinates (x, y) of the upper left corner of a 
        pixel at `row` and `col` in the units of the dataset's
        coordinate reference system.
        """
        a, b, c, d, e, f, _, _, _ = self.affine
        if col < 0:
            col += self.width
        if row < 0:
            row += self.height
        return c+a*col, f+e*row

    def index(self, x, y, op=math.floor, precision=6):
        """Returns the (row, col) index of the pixel containing (x, y)."""
        return get_index(x, y, self.affine, op=op, precision=precision)

    def window(self, left, bottom, right, top, boundless=False):
        """Returns the window corresponding to the world bounding box.
        If boundless is False, window is limited to extent of this dataset."""
        window = get_window(left, bottom, right, top, self.affine)
        if boundless:
            return window
        else:
            return crop_window(window, self.height, self.width)

    def window_transform(self, window):
        """Returns the affine transform for a dataset window."""
        (r, _), (c, _) = window
        return self.affine * Affine.translation(c or 0, r or 0)

    def window_bounds(self, window):
        """Returns the bounds of a window as x_min, y_min, x_max, y_max."""
        ((row_min, row_max), (col_min, col_max)) = window
        x_min, y_min = self.affine * (col_min, row_max)
        x_max, y_max = self.affine * (col_max, row_min)
        return x_min, y_min, x_max, y_max

    @property
    def meta(self):
        """The basic metadata of this dataset."""
        if self.count == 0:
            dtype = 'float_'
        else:
            dtype = self.dtypes[0]
        m = {
            'driver': self.driver,
            'dtype': dtype,
            'nodata': self.nodata,
            'width': self.width,
            'height': self.height,
            'count': self.count,
            'crs': self.crs,
            'transform': self.affine.to_gdal(),
            'affine': self.affine,
        }
        self._read = True

        return m

    @property
    def compression(self):
        val = self.tags(ns='IMAGE_STRUCTURE').get('COMPRESSION')
        if val:
            # 'YCbCr JPEG' will be normalized to 'JPEG'
            val = val.split(' ')[-1]
            return Compression(val)
        else:
            return None

    @property
    def interleaving(self):
        val = self.tags(ns='IMAGE_STRUCTURE').get('INTERLEAVE')
        if val:
            return Interleaving(val)
        else:
            return None

    @property
    def photometric(self):
        val = self.tags(ns='IMAGE_STRUCTURE').get('SOURCE_COLOR_SPACE')
        if val:
            return PhotometricInterp(val)
        else:
            return None

    @property
    def is_tiled(self):
        if len(self.block_shapes) == 0:
            return False
        return self.block_shapes[0][1] != self.width

    property profile:
        """Basic metadata and creation options of this dataset.

        May be passed as keyword arguments to `rasterio.open()` to
        create a clone of this dataset.
        """
        def __get__(self):
            m = self.meta
            m.update((k, v.lower()) for k, v in self.tags(
                ns='rio_creation_kwds').items())
            if self.is_tiled:
                m.update(
                    blockxsize=self.block_shapes[0][1],
                    blockysize=self.block_shapes[0][0],
                    tiled=True)
            else:
                m.update(tiled=False)
            if self.compression:
                m['compress'] = self.compression.name
            if self.interleaving:
                m['interleave'] = self.interleaving.name
            if self.photometric:
                m['photometric'] = self.photometric.name

            return m

    def lnglat(self):
        w, s, e, n = self.bounds
        cx = (w + e)/2.0
        cy = (s + n)/2.0
        lng, lat = _transform(
                self.crs, {'init': 'epsg:4326'}, [cx], [cy], None)
        return lng.pop(), lat.pop()

    def get_crs(self):
        # _read tells us that the CRS was read before and really is
        # None.
        if not self._read and self._crs is None:
            self._crs = self.read_crs()
        return self._crs

    property crs:
        """A mapping of PROJ.4 coordinate reference system params.
        """
        def __get__(self):
            return self.get_crs()

    def get_transform(self):
        """Returns a GDAL geotransform in its native form."""
        if not self._read and self._transform is None:
            self._transform = self.read_transform()
        return self._transform

    property transform:
        """Coefficients of the affine transformation that maps col,row
        pixel coordinates to x,y coordinates in the specified crs. The
        coefficients of the augmented matrix are shown below.
        
          | x |   | a  b  c | | r |
          | y | = | d  e  f | | c |
          | 1 |   | 0  0  1 | | 1 |
        
        In Rasterio versions before 1.0 the value of this property
        is a list of coefficients ``[c, a, b, f, d, e]``. This form
        is *deprecated* beginning in 0.9 and in version 1.0 this 
        property will be replaced by an instance of ``affine.Affine``,
        which is a namedtuple with coefficients in the order
        ``(a, b, c, d, e, f)``.

        Please see https://github.com/mapbox/rasterio/issues/86
        for more details.
        """
        def __get__(self):
            warnings.warn(
                    "The value of this property will change in version 1.0. "
                    "Please see https://github.com/mapbox/rasterio/issues/86 "
                    "for details.",
                    FutureWarning,
                    stacklevel=2)
            return self.get_transform()

    property affine:
        """An instance of ``affine.Affine``. This property is a
        transitional feature: see the docstring of ``transform``
        (above) for more details.
        """
        def __get__(self):
            return Affine.from_gdal(*self.get_transform())

    def tags(self, bidx=0, ns=None):
        """Returns a dict containing copies of the dataset or band's
        tags.

        Tags are pairs of key and value strings. Tags belong to
        namespaces.  The standard namespaces are: default (None) and
        'IMAGE_STRUCTURE'.  Applications can create their own additional
        namespaces.

        The optional bidx argument can be used to select the tags of
        a specific band. The optional ns argument can be used to select
        a namespace other than the default.
        """
        cdef char *item = NULL
        cdef GDALMajorObjectH obj = NULL
        cdef char **metadata = NULL
        cdef char *domain = NULL

        if bidx > 0:
            obj = self.band(bidx)
        else:
            obj = self.handle()
        if ns:
            ns_bytes = ns.encode('utf-8')
            domain = ns_bytes
        else:
            domain = NULL

        metadata = _gdal.GDALGetMetadata(obj, domain)
        num_items = _gdal.CSLCount(metadata)
        retval = {}

        for i in range(num_items):
            item = metadata[i]
            key, value = item.split('=', 1)
            retval[key] = value

        return retval
    
    def colorinterp(self, bidx):
        """Returns the color interpretation for a band or None."""
        cdef GDALRasterBandH band = NULL
        
        band = self.band(bidx)
        value = _gdal.GDALGetRasterColorInterpretation(band)
        return ColorInterp(value)

    def colormap(self, bidx):
        """Returns a dict containing the colormap for a band or None."""
        cdef GDALRasterBandH band = NULL
        cdef GDALColorTableH colortable = NULL
        cdef GDALColorEntry *color = NULL
        cdef int i

        band = self.band(bidx)
        colortable = _gdal.GDALGetRasterColorTable(band)
        if colortable == NULL:
            raise ValueError("NULL color table")
        retval = {}

        for i in range(_gdal.GDALGetColorEntryCount(colortable)):
            color = _gdal.GDALGetColorEntry(colortable, i)
            if color == NULL:
                log.warn("NULL color at %d, skipping", i)
                continue
            log.info(
                "Color: (%d, %d, %d, %d)",
                color.c1, color.c2, color.c3, color.c4)
            retval[i] = (color.c1, color.c2, color.c3, color.c4)

        return retval

    @property
    def kwds(self):
        return self.tags(ns='rio_creation_kwds')

    # Overviews.
    def overviews(self, bidx):
        cdef GDALRasterBandH ovrband = NULL
        cdef GDALRasterBandH band = NULL

        band = self.band(bidx)
        num_overviews = _gdal.GDALGetOverviewCount(band)
        factors = []

        for i in range(num_overviews):
            ovrband = _gdal.GDALGetOverview(band, i)
            # Compute the overview factor only from the xsize (width).
            xsize = _gdal.GDALGetRasterBandXSize(ovrband)
            factors.append(int(round(float(self.width)/float(xsize))))

        return factors

    def checksum(self, bidx, window=None):
        """Compute an integer checksum for the stored band

        Parameters
        ----------
        bidx : int
            The band's index (1-indexed).
        window: tuple, optional
            A window of the band. Default is the entire extent of the band.

        Returns
        -------
        An int.
        """
        cdef GDALRasterBandH band = NULL
        cdef int xoff, yoff, width, height

        band = self.band(bidx)
        if not window:
            xoff = yoff = 0
            width, height = self.width, self.height
        else:
            window = eval_window(window, self.height, self.width)
            window = crop_window(window, self.height, self.width)
            xoff = window[1][0]
            width = window[1][1] - xoff
            yoff = window[0][0]
            height = window[0][1] - yoff

        return _gdal.GDALChecksumImage(band, xoff, yoff, width, height)


# Window utils
# A window is a 2D ndarray indexer in the form of a tuple:
# ((row_start, row_stop), (col_start, col_stop))

cpdef crop_window(object window, int height, int width):
    """Returns a window cropped to fall within height and width."""
    cdef int r_start, r_stop, c_start, c_stop

    (r_start, r_stop), (c_start, c_stop) = window
    return (
        (min(max(r_start, 0), height), max(0, min(r_stop, height))),
        (min(max(c_start, 0), width), max(0, min(c_stop, width)))
    )


cpdef eval_window(object window, int height, int width):
    """Evaluates a window tuple that might contain negative values
    in the context of a raster height and width."""
    cdef int r_start, r_stop, c_start, c_stop

    try:
        r, c = window
        assert len(r) == 2
        assert len(c) == 2
    except (ValueError, TypeError, AssertionError):
        raise ValueError("invalid window structure; expecting "
                         "((row_start, row_stop), (col_start, col_stop))")
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


def get_index(x, y, affine, op=math.floor, precision=6):
    """
    Returns the (row, col) index of the pixel containing (x, y) given a
    coordinate reference system.

    Parameters
    ----------
    x : float
        x value in coordinate reference system
    y : float
        y value in coordinate reference system
    affine : tuple
        Coefficients mapping pixel coordinates to coordinate reference system.
    op : function
        Function to convert fractional pixels to whole numbers (floor, ceiling,
        round)
    precision : int
        Decimal places of precision in indexing, as in `round()`.

    Returns
    -------
    row : int
        row index
    col : int
        col index
    """
    # Use an epsilon, magnitude determined by the precision parameter
    # and sign determined by the op function: positive for floor, negative
    # for ceil.
    eps = 10.0**-precision * (1.0 - 2.0*op(0.1))
    row = int(op((y - eps - affine[5]) / affine[4]))
    col = int(op((x + eps - affine[2]) / affine[0]))
    return row, col


def get_window(left, bottom, right, top, affine, precision=6):
    """
    Returns a window tuple given coordinate bounds and the coordinate reference
    system.

    Parameters
    ----------
    left : float
        Left edge of window
    bottom : float
        Bottom edge of window
    right : float
        Right edge of window
    top : float
        top edge of window
    affine : tuple
        Coefficients mapping pixel coordinates to coordinate reference system.
    precision : int
        Decimal places of precision in indexing, as in `round()`.
    """
    window_start = get_index(
        left, top, affine, op=math.floor, precision=precision)
    window_stop = get_index(
        right, bottom, affine, op=math.ceil, precision=precision)
    window = tuple(zip(window_start, window_stop))
    return window


def window_shape(window, height=-1, width=-1):
    """Returns shape of a window.

    height and width arguments are optional if there are no negative
    values in the window.
    """
    (a, b), (c, d) = eval_window(window, height, width)
    return b-a, d-c


def window_index(window):
    return tuple(slice(*w) for w in window)


def tastes_like_gdal(t):
    return t[2] == t[4] == 0.0 and t[1] > 0 and t[5] < 0


def _transform(src_crs, dst_crs, xs, ys, zs):
    cdef double *x = NULL
    cdef double *y = NULL
    cdef double *z = NULL
    cdef OGRSpatialReferenceH src = NULL
    cdef OGRSpatialReferenceH dst = NULL
    cdef OGRCoordinateTransformationH transform = NULL
    cdef int i

    assert len(xs) == len(ys)
    assert zs is None or len(xs) == len(zs)

    src = _osr_from_crs(src_crs)
    dst = _osr_from_crs(dst_crs)

    n = len(xs)
    x = <double *>_gdal.CPLMalloc(n*sizeof(double))
    y = <double *>_gdal.CPLMalloc(n*sizeof(double))
    for i in range(n):
        x[i] = xs[i]
        y[i] = ys[i]

    if zs is not None:
        z = <double *>_gdal.CPLMalloc(n*sizeof(double))
        for i in range(n):
            z[i] = zs[i]

    try:
        with CPLErrors() as cple:
            transform = _gdal.OCTNewCoordinateTransformation(src, dst)
            cple.check()
            res = _gdal.OCTTransform(transform, n, x, y, z)
            res_xs = [0]*n
            res_ys = [0]*n
            for i in range(n):
                res_xs[i] = x[i]
                res_ys[i] = y[i]
            if zs is not None:
                res_zs = [0]*n
                for i in range(n):
                    res_zs[i] = z[i]
                retval = (res_xs, res_ys, res_zs)
            else:
                retval = (res_xs, res_ys)
    except CPLE_NotSupportedError as err:
        raise CRSError(err.errmsg)
    finally:
        _gdal.CPLFree(x)
        _gdal.CPLFree(y)
        _gdal.CPLFree(z)
        _gdal.OSRDestroySpatialReference(src)
        _gdal.OSRDestroySpatialReference(dst)

    return retval


cdef OGRSpatialReferenceH _osr_from_crs(object crs) except NULL:
    """Returns a reference to memory that must be deallocated
    by the caller."""

    cdef OGRSpatialReferenceH osr = NULL

    if crs is None:
        raise CRSError('CRS cannot be None')

    osr = _gdal.OSRNewSpatialReference(NULL)

    params = []

    try:
        with CPLErrors() as cple:
            # Normally, we expect a CRS dict.
            if isinstance(crs, dict):
                crs = CRS(crs)
            if isinstance(crs, CRS):
                # EPSG is a special case.
                init = crs.get('init')
                if init:
                    auth, val = init.split(':')
                    if auth.upper() == 'EPSG':
                        _gdal.OSRImportFromEPSG(osr, int(val))
                else:
                    crs['wktext'] = True
                    for k, v in crs.items():
                        if v is True or (k in ('no_defs', 'wktext') and v):
                            params.append("+%s" % k)
                        else:
                            params.append("+%s=%s" % (k, v))
                    proj = " ".join(params)
                    log.debug("PROJ.4 to be imported: %r", proj)
                    proj = proj.encode('utf-8')
                    _gdal.OSRImportFromProj4(osr, <const char *>proj)
            # Fall back for CRS strings like "EPSG:3857."
            else:
                proj = crs.encode('utf-8')
                _gdal.OSRSetFromUserInput(osr, <const char *>proj)
            cple.check()

    except:
        raise CRSError('Invalid CRS')

    return osr


def _can_create_osr(crs):
    """
    Returns True if valid OGRSpatialReference could be created from crs.
    Specifically, it must not be NULL or empty string.

    Parameters
    ----------
    crs: Source coordinate reference system, in rasterio dict format.

    Returns
    -------
    out: bool
        True if source coordinate reference appears valid.

    """

    cdef char *wkt = NULL
    cdef OGRSpatialReferenceH osr = NULL

    try:
        osr = _osr_from_crs(crs)
        if osr == NULL:
            return False

        _gdal.OSRExportToWkt(osr, &wkt)

        # If input was empty, WKT can be too; otherwise the conversion didn't
        # work properly and indicates an error.
        return wkt != NULL and bool(crs) == (wkt[0] != '\0')

    except CRSError:
        return False

    finally:
        _gdal.OSRDestroySpatialReference(osr)
        _gdal.CPLFree(wkt)
