"""Classes capable of reading and writing datasets

Instances of these classes are called dataset objects.
"""

from rasterio._base import (
    get_dataset_driver, driver_can_create, driver_can_create_copy)
from rasterio._io import (
    DatasetReaderBase, DatasetWriterBase, BufferedDatasetWriterBase)
from rasterio import windows
from rasterio.transform import guard_transform


class WindowMethodsMixin(object):
    """Mixin providing methods for window-related calculations.
    These methods are wrappers for the functionality in
    `rasterio.windows` module.

    A subclass with this mixin MUST provide the following
    properties: `transform`, `height` and `width`
    """

    def window(self, left, bottom, right, top, boundless=False):
        """Get the window corresponding to the bounding coordinates.

        Parameters
        ----------
        left : float
            Left (west) bounding coordinate
        bottom : float
            Bottom (south) bounding coordinate
        right : float
            Right (east) bounding coordinate
        top : float
            Top (north) bounding coordinate
        boundless: boolean, optional
            If boundless is False, window is limited
            to extent of this dataset.

        Returns
        -------
        window: tuple
            ((row_start, row_stop), (col_start, col_stop))
            corresponding to the bounding coordinates

        """

        transform = guard_transform(self.transform)
        return windows.from_bounds(
            left, bottom, right, top, transform=transform,
            height=self.height, width=self.width, boundless=boundless)

    def window_transform(self, window):
        """Get the affine transform for a dataset window.

        Parameters
        ----------
        window: tuple
            Dataset window tuple

        Returns
        -------
        transform: Affine
            The affine transform matrix for the given window
        """

        transform = guard_transform(self.transform)
        return windows.transform(window, transform)

    def window_bounds(self, window):
        """Get the bounds of a window

        Parameters
        ----------
        window: tuple
            Dataset window tuple

        Returns
        -------
        bounds : tuple
            x_min, y_min, x_max, y_max for the given window
        """

        transform = guard_transform(self.transform)
        return windows.bounds(window, transform)


class DatasetReader(DatasetReaderBase, WindowMethodsMixin):
    """An unbuffered data and metadata reader"""

    def __repr__(self):
        return "<{} DatasetReader name='{}' mode='{}'>".format(
            self.closed and 'closed' or 'open', self.name, self.mode)


class DatasetWriter(DatasetWriterBase, WindowMethodsMixin):
    """An unbuffered data and metadata writer. Its methods write data
    directly to disk.
    """

    def __repr__(self):
        return "<{} DatasetWriter name='{}' mode='{}'>".format(
            self.closed and 'closed' or 'open', self.name, self.mode)


class BufferedDatasetWriter(BufferedDatasetWriterBase, WindowMethodsMixin):
    """Maintains data and metadata in a buffer, writing to disk or
    network only when `close()` is called.

    This allows incremental updates to datasets using formats that don't
    otherwise support updates, such as JPEG.
    """

    def __repr__(self):
        return "<{} BufferedDatasetWriter name='{}' mode='{}'>".format(
            self.closed and 'closed' or 'open', self.name, self.mode)


def get_writer_for_driver(driver):
    """Return the writer class appropriate for the specified driver."""
    cls = None
    if driver_can_create(driver):
        cls = DatasetWriter
    elif driver_can_create_copy(driver):  # pragma: no branch
        cls = BufferedDatasetWriter
    return cls


def get_writer_for_path(path):
    """Return the writer class appropriate for the existing dataset."""
    driver = get_dataset_driver(path)
    return get_writer_for_driver(driver)
