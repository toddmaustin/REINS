#!/usr/bin/env python3
"""Fetch the pinned doctest header/license with TLS and SHA-256 verification."""
import hashlib
import io
from pathlib import Path
import ssl
import sys
import tarfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
URL = "https://codeload.github.com/doctest/doctest/tar.gz/refs/tags/v2.4.12"
ARCHIVE_HASH = "73381c7aa4dee704bd935609668cf41880ea7f19fa0504a200e13b74999c2d70"
FILES = {
    "doctest/doctest.h": "94029a7d32da24a56249658147dbd2b33ff0b9ed665295cbbaf19aafff5b0ced",
    "LICENSE.txt": "0fe0b331fa1513dcce8604ff1fa925f32d1cea17d8aeb1c2471fad40d291adc5",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


class DownloadError(RuntimeError):
    """An actionable dependency download failure for the command-line caller."""


def download_archive(url):
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            return response.read()
    except urllib.error.URLError as error:
        if isinstance(error.reason, ssl.SSLCertVerificationError):
            paths = ssl.get_default_verify_paths()
            raise DownloadError(
                f"HTTPS certificate verification failed while downloading doctest from {url}.\n"
                "Python could not validate the server's certificate chain or hostname.\n"
                "On Debian/Ubuntu, repair the system trust store:\n"
                "  sudo apt-get install --reinstall ca-certificates\n"
                "  sudo update-ca-certificates\n"
                "If Python looks elsewhere, explicitly select that existing system bundle:\n"
                "  SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt make build\n"
                "If your network uses an organization CA, obtain its trusted PEM bundle\n"
                "from your administrator and retry with:\n"
                "  SSL_CERT_FILE=/absolute/path/to/trusted-ca-bundle.pem make build\n"
                "SSL_CERT_FILE is honored even with Python -E.\n"
                f"Python CA paths: cafile={paths.cafile!r}, capath={paths.capath!r}.\n"
                f"Verification detail: {error.reason}"
            ) from error
        raise DownloadError(f"Could not download doctest from {url}: {error.reason}") from error


def main():
    destination = ROOT / ".deps/doctest-2.4.12"
    if all((destination / name).is_file() for name in FILES):
        for name, expected in FILES.items():
            if digest((destination / name).read_bytes()) != expected:
                raise ValueError(f"modified dependency: {name}; inspect it before make clean-deps")
        return
    archive_path = ROOT / ".deps/downloads/doctest-v2.4.12.tar.gz"
    if archive_path.exists():
        data = archive_path.read_bytes()
    else:
        data = download_archive(URL)
    if digest(data) != ARCHIVE_HASH:
        raise ValueError("doctest archive checksum mismatch; dependency was not installed")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        contents = {}
        for name, expected in FILES.items():
            member = archive.getmember("doctest-2.4.12/" + name)
            if not member.isfile():
                raise ValueError(f"unexpected archive member: {name}")
            contents[name] = archive.extractfile(member).read()
            if digest(contents[name]) != expected:
                raise ValueError(f"doctest member checksum mismatch: {name}")
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    archive_path.write_bytes(data)
    for name, contents in contents.items():
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents)
    print("Verified doctest 2.4.12 header, license and archive SHA-256.")


def cli():
    try:
        main()
    except DownloadError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(cli())
