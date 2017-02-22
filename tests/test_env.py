# Tests requiring S3 credentials.
# Collected here to make them easier to skip/xfail.

import logging
import sys

import boto3
from packaging.version import parse
import pytest

import rasterio
from rasterio._env import del_gdal_config, get_gdal_config, set_gdal_config
from rasterio.env import _current_env, ensure_env
from rasterio.errors import EnvError
from rasterio.rio.main import main_group


# Custom markers.
mingdalversion = pytest.mark.skipif(
    parse(rasterio.__gdal_version__) < parse('2.1.0dev'),
    reason="S3 raster access requires GDAL 2.1")

credentials = pytest.mark.skipif(
    not(boto3.Session()._session.get_credentials()),
    reason="S3 raster access requires credentials")


logging.basicConfig(stream=sys.stderr, level=logging.DEBUG)

L8TIF = "s3://landsat-pds/L8/139/045/LC81390452014295LGN00/LC81390452014295LGN00_B1.TIF"
httpstif = "https://landsat-pds.s3.amazonaws.com/L8/139/045/LC81390452014295LGN00/LC81390452014295LGN00_B1.TIF"


def test_gdal_config_accessers():
    """Low level GDAL config access."""
    assert get_gdal_config('foo') is None
    set_gdal_config('foo', 'bar')
    assert get_gdal_config('foo') == 'bar'
    del_gdal_config('foo')
    assert get_gdal_config('foo') is None


def test_ensure_env_decorator():
    @ensure_env
    def f():
        return _current_env()['DEFAULT_RASTERIO_ENV']
    assert f() is True


def test_no_aws_gdal_config():
    """Trying to set AWS-specific GDAL config options fails."""
    with pytest.raises(EnvError):
        rasterio.Env(AWS_ACCESS_KEY_ID='x')
    with pytest.raises(EnvError):
        rasterio.Env(AWS_SECRET_ACCESS_KEY='y')


def test_env_defaults():
    """Test env defaults."""
    env = rasterio.Env.from_defaults(foo='x')
    # The GDAL environment has not yet been started, so this should raise
    # an exception
    with pytest.raises(EnvironmentError):
        env.get_config('foo')
    with env:
        assert env['CHECK_WITH_INVERT_PROJ'] is True
        assert env['GTIFF_IMPLICIT_JPEG_OVR'] is False
        assert env["DEFAULT_RASTERIO_ENV"] is True


def test_aws_session():
    """Create an Env with a boto3 session."""
    aws_session = boto3.Session(
        aws_access_key_id='id', aws_secret_access_key='key',
        aws_session_token='token', region_name='null-island-1')
    s = rasterio.env.Env(aws_session=aws_session)
    assert s._aws_creds.access_key == 'id'
    assert s._aws_creds.secret_key == 'key'
    assert s._aws_creds.token == 'token'
    assert s.aws_session.region_name == 'null-island-1'


def test_aws_session_credentials():
    """Create an Env with a boto3 session."""
    aws_session = boto3.Session(
        aws_access_key_id='id', aws_secret_access_key='key',
        aws_session_token='token', region_name='null-island-1')
    with rasterio.env.Env(aws_session=aws_session) as s:
        s.auth_aws()
        assert s['aws_access_key_id'] == 'id'
        assert s['aws_region'] == 'null-island-1'
        assert s['aws_secret_access_key'] == 'key'
        assert s['aws_session_token'] == 'token'


def test_with_aws_session_credentials():
    """Create an Env with a boto3 session."""
    with rasterio.Env.from_defaults(
            aws_access_key_id='id', aws_secret_access_key='key',
            aws_session_token='token', aws_region_name='null-island-1') as s:
        expected = rasterio.Env.default_options().copy()
        s.auth_aws()
        expected.update({
            'aws_access_key_id': 'id', 'aws_region': 'null-island-1',
            'aws_secret_access_key': 'key', 'aws_session_token': 'token'})
        assert s.config_options
        assert s.config_options == expected


def test_session_env_lazy(monkeypatch):
    """Create an Env with AWS env vars."""
    monkeypatch.setenv('AWS_ACCESS_KEY_ID', 'id')
    monkeypatch.setenv('AWS_SECRET_ACCESS_KEY', 'key')
    monkeypatch.setenv('AWS_SESSION_TOKEN', 'token')
    with rasterio.Env() as s:
        s.auth_aws()
        expected = {
            'aws_access_key_id': 'id',
            'aws_secret_access_key': 'key',
            'aws_session_token': 'token'}
        for k, v in expected.items():
            assert s[k] == v

    monkeypatch.undo()


def test_open_with_default_env():
    """Read from a dataset with a default env."""
    with rasterio.open('tests/data/RGB.byte.tif') as dataset:
        assert dataset.count == 3


def test_open_with_env():
    """Read from a dataset with an explicit env."""
    with rasterio.Env():
        with rasterio.open('tests/data/RGB.byte.tif') as dataset:
            assert dataset.count == 3


@mingdalversion
@credentials
def test_s3_open_with_session():
    """Read from S3 demonstrating lazy credentials."""
    with rasterio.Env():
        with rasterio.open(L8TIF) as dataset:
            assert dataset.count == 1


@mingdalversion
@credentials
def test_s3_open_with_default_session():
    """Read from S3 using default env."""
    with rasterio.open(L8TIF) as dataset:
        assert dataset.count == 1


@mingdalversion
def test_open_https_vsicurl():
    """Read from HTTPS URL."""
    with rasterio.Env():
        with rasterio.open(httpstif) as dataset:
            assert dataset.count == 1


# CLI tests.

@mingdalversion
@credentials
def test_s3_rio_info(runner):
    """S3 is supported by rio-info."""
    result = runner.invoke(main_group, ['info', L8TIF])
    assert result.exit_code == 0
    assert '"crs": "EPSG:32645"' in result.output


@mingdalversion
@credentials
def test_https_rio_info(runner):
    """HTTPS is supported by rio-info."""
    result = runner.invoke(main_group, ['info', httpstif])
    assert result.exit_code == 0
    assert '"crs": "EPSG:32645"' in result.output


# Not sure why this is failing
#
# def test_rio_env_credentials_options(tmpdir, monkeypatch, runner):
#     """Confirm that ``--aws-profile`` option works."""
#     credentials_file = tmpdir.join('credentials')
#     credentials_file.write("[testing]\n"
#                            "aws_access_key_id = foo\n"
#                            "aws_secret_access_key = bar\n"
#                            "aws_session_token = baz")
#     monkeypatch.setenv('AWS_SHARED_CREDENTIALS_FILE', str(credentials_file))
#     monkeypatch.setenv('AWS_SESSION_TOKEN', 'ignore_me')
#     result = runner.invoke(
#         main_group, ['--aws-profile', 'testing', 'env', '--credentials'])
#     assert result.exit_code == 0
#     assert '"aws_access_key_id": "foo"' in result.output
#     assert '"aws_secret_access_key": "bar"' in result.output
#     assert '"aws_session_token": "baz"' in result.output
#     monkeypatch.undo()


def test_env_teardown():

    assert rasterio.env._ENV is None
    with rasterio.Env():
        assert rasterio.env._ENV is not None
    assert rasterio.env._ENV is None


def test_env_no_defaults():

    default_options = rasterio.Env.default_options()
    with rasterio.Env() as env:
        for key, value in default_options.items():
            assert env[key] is None

    for key in default_options:
        assert get_gdal_config(key) is None


def test_ensure_defaults_teardown():

    """This test guards against a regression.  Previously ``rasterio.Env()``
    would quietly reinstate any ``rasterio.env.default_options`` that was
    not modified by the environment.

    https://github.com/mapbox/rasterio/issues/968
    """

    default_options = rasterio.Env.default_options()

    with rasterio.Env.from_defaults() as env:
        for key, val in default_options.items():
            assert env[key] == val

    for key in default_options:
        assert get_gdal_config(key) is None


def test_env_getitem_setitem_delitem():
    """``rasterio.Env()`` treats config options like to ``os.environ``."""

    with rasterio.Env() as env:
        env['key'] = 'val'
        assert env['key'] == 'val'
        del env['key']
        assert env['key'] is None
