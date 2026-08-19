#!/usr/bin/env python3

"""
Generate a compact cross-distro header -> package database.

The database contains only headers which have a provider in ALL THREE:

    Debian
    Arch Linux
    FreeBSD

Debian:
    Only packages whose names end in "-dev" are considered.

Arch:
    Any package containing a public C/C++ header is considered.

FreeBSD:
    Any package containing a public C/C++ header is considered.

The script downloads repository metadata directly from the distro
archives, plus the pkg-provides file database for FreeBSD:

    Debian:  Contents-amd64.gz from deb.debian.org
    Arch:    <repo>.files archives from a pkgbuild.com mirror
    FreeBSD: provides.db.xz from pkg-provides.osorio.me

Dependencies:
    python3 -m pip install zstandard
    a C compiler (cc) to build the provides.db decoder

Example:

    ./generate_headers_db.py

    ./generate_headers_db.py \
        --debian-suite stable \
        --debian-arch amd64 \
        --freebsd-abi FreeBSD:15:amd64 \
        --output headers.db

Query:

    sqlite3 headers.db \
        "SELECT d.name, p.name, d.include_prefix || h.include_name
         FROM header h
         JOIN provider pr ON pr.header_id = h.id
         JOIN package p ON p.id = pr.package_id
         JOIN distro d ON d.id = p.distro_id
         WHERE h.include_name='gphoto2/gphoto2.h';"
"""

from __future__ import annotations

import argparse
import gzip
import io
import os
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from collections import defaultdict
from typing import Iterable

try:
    import zstandard
except ImportError:
    print(
        "error: install zstandard first:\n"
        "  python3 -m pip install zstandard",
        file=sys.stderr,
    )
    raise SystemExit(2)


USER_AGENT = "Build.app-header-db-generator/1.0"

DEBIAN_MIRROR = "https://deb.debian.org/debian"

ARCH_MIRROR = "https://geo.mirror.pkgbuild.com"

# pkg-provides (https://pkg-provides.osorio.me) publishes a database
# of every file installed by every package in the FreeBSD official
# repositories, per FreeBSD release/architecture.  It is generated
# daily by pkg-provides from the FreeBSD repos.
PROVIDES_MIRROR = "https://pkg-provides.osorio.me"
PROVIDES_DB_VERSION = "v3"


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_DEBIAN_SUITE = "stable"
DEFAULT_DEBIAN_ARCH = "amd64"

DEFAULT_ARCH_REPOSITORIES = (
    "core",
    "extra",
    "multilib",
)

DEFAULT_ARCH_ARCH = "x86_64"

DEFAULT_FREEBSD_ABI = "FreeBSD:15:amd64"


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def download(url: str) -> bytes:
    print(f"  GET {url}")

    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept-Encoding": "gzip",
        },
    )

    with urllib.request.urlopen(request, timeout=180) as response:
        return response.read()


# ---------------------------------------------------------------------------
# Header classification
# ---------------------------------------------------------------------------

HEADER_SUFFIXES = (
    ".h",
    ".hh",
    ".hpp",
    ".hxx",
    ".h++",
    ".inl",
)


def normalize_path(path: str) -> str:
    path = path.strip()

    while path.startswith("./"):
        path = path[2:]

    path = path.lstrip("/")

    return path


def is_public_header(path: str) -> bool:
    """
    Return True for public-ish C/C++ headers.

    We deliberately restrict this to normal include directories.

    Examples accepted:

        usr/include/foo.h
        usr/include/foo/bar.h
        usr/local/include/foo.h

    Examples rejected:

        usr/share/foo/foo.h
        usr/lib/foo/internal.h
    """

    path = normalize_path(path)
    lower = path.lower()

    if not lower.endswith(HEADER_SUFFIXES):
        return False

    prefixes = (
        "usr/include/",
        "usr/local/include/",
        "include/",
    )

    return lower.startswith(prefixes)


def include_name_from_path(path: str) -> str:
    """
    Convert an installed path to an #include name.

        usr/include/gphoto2/gphoto2.h
        ->
        gphoto2/gphoto2.h

        usr/local/include/foo/bar.h
        ->
        foo/bar.h
    """

    path = normalize_path(path)

    prefixes = (
        "usr/include/",
        "usr/local/include/",
        "include/",
    )

    for prefix in prefixes:
        if path.startswith(prefix):
            return path[len(prefix):]

    return path


# ---------------------------------------------------------------------------
# Debian
# ---------------------------------------------------------------------------

def parse_debian_contents(
    data: bytes,
) -> Iterable[tuple[str, str]]:
    """
    Yield:

        package_name, path

    from a Debian Contents-ARCH.gz file.
    """

    with gzip.GzipFile(fileobj=io.BytesIO(data)) as stream:
        for raw_line in stream:

            line = raw_line.decode(
                "utf-8",
                errors="replace",
            ).rstrip("\n")

            if not line:
                continue

            if line.startswith("FILE"):
                continue

            parts = line.split(None, 1)

            if len(parts) != 2:
                continue

            path, locations = parts

            if not is_public_header(path):
                continue

            for location in locations.split(","):

                location = location.strip()

                if not location:
                    continue

                # Current Debian Contents records are qualified as:
                #
                #   main/libfoo-dev
                #
                # or:
                #
                #   main/devel/libfoo-dev
                #
                package = location.rsplit("/", 1)[-1]

                if not package.endswith("-dev"):
                    continue

                yield package, normalize_path(path)


def load_debian(
    suite: str,
    architecture: str,
) -> dict[str, set[tuple[str, str]]]:
    """
    Return:

        include_name -> {(package, path), ...}
    """

    print()
    print("=== Debian ===")
    print(f"Suite: {suite}")
    print(f"Architecture: {architecture}")

    result: dict[str, set[tuple[str, str]]] = defaultdict(set)

    components = (
        "main",
        "contrib",
        "non-free",
        "non-free-firmware",
    )

    for component in components:

        url = (
            f"{DEBIAN_MIRROR}/dists/"
            f"{suite}/{component}/"
            f"Contents-{architecture}.gz"
        )

        try:
            data = download(url)
        except Exception as exc:
            print(
                f"  warning: {exc}",
                file=sys.stderr,
            )
            continue

        count = 0

        for package, path in parse_debian_contents(data):

            include_name = include_name_from_path(path)

            result[include_name].add(
                (package, path)
            )

            count += 1

        print(
            f"  {component}: "
            f"{count:,} header/package entries"
        )

    print(
        f"  unique Debian headers: "
        f"{len(result):,}"
    )

    return result


# ---------------------------------------------------------------------------
# Arch
# ---------------------------------------------------------------------------

def parse_alpm_desc(
    data: bytes,
) -> dict[str, list[str]]:
    """
    Parse an Arch ALPM desc/files file.
    """

    result: dict[str, list[str]] = {}

    section: str | None = None

    for raw_line in data.splitlines():

        line = raw_line.decode(
            "utf-8",
            errors="replace",
        ).rstrip()

        if line.startswith("%") and line.endswith("%"):
            section = line
            result[section] = []
            continue

        if section is not None and line:
            result[section].append(line)

    return result


def open_compressed(
    data: bytes,
) -> object:
    """
    Return a readable file-like object for a compressed payload,
    chosen by magic bytes. Mirrors do not agree on the compression
    used for Arch .files / FreeBSD catalogues, so sniff instead
    of assuming a single format.
    """

    if data[:4] == b"\x28\xb5\x2f\xfd":
        return zstandard.ZstdDecompressor().stream_reader(
            io.BytesIO(data)
        )

    if data[:2] == b"\x1f\x8b":
        return gzip.GzipFile(fileobj=io.BytesIO(data))

    if data[:6] == b"\xfd7zXZ\x00":
        import lzma

        return io.BytesIO(lzma.decompress(data))

    if data[:3] == b"BZh":
        import bz2

        return io.BytesIO(bz2.decompress(data))

    return io.BytesIO(data)


def parse_arch_files_database(
    data: bytes,
) -> Iterable[tuple[str, str]]:
    """
    Yield:

        package, path

    Each package directory in the .files archive contains a
    `desc` member (with %NAME%) and a `files` member (with
    %FILES%). Correlate them by directory name.
    """

    with open_compressed(data) as reader:

        with tarfile.open(
            fileobj=reader,
            mode="r|",
        ) as archive:

            descs = {}

            for member in archive:

                if not member.isfile():
                    continue

                parts = member.name.split("/")

                if len(parts) != 2:
                    continue

                directory, member_name = parts

                if member_name not in ("desc", "files"):
                    continue

                fileobj = archive.extractfile(member)

                if fileobj is None:
                    continue

                contents = fileobj.read()

                sections = parse_alpm_desc(
                    contents
                )

                if member_name == "desc":
                    descs[directory] = sections
                    continue

                names = sections.get(
                    "%NAME%",
                    [],
                )

                desc = descs.get(
                    directory,
                    {},
                )

                if not names:
                    names = desc.get(
                        "%NAME%",
                        [],
                    )

                if not names:
                    continue

                package = names[0]

                files = sections.get(
                    "%FILES%",
                    [],
                )

                for path in files:

                    path = normalize_path(path)

                    if not is_public_header(path):
                        continue

                    yield (
                        package,
                        path,
                    )


def load_arch(
    repositories: tuple[str, ...],
    architecture: str,
) -> dict[str, set[tuple[str, str]]]:
    """
    Return:

        include_name ->
            {(package, path), ...}
    """

    print()
    print("=== Arch Linux ===")
    print(f"Architecture: {architecture}")

    result = defaultdict(set)

    for repository in repositories:

        url = (
            f"{ARCH_MIRROR}/"
            f"{repository}/os/"
            f"{architecture}/"
            f"{repository}.files"
        )

        try:
            data = download(url)
        except Exception as exc:
            print(
                f"  warning: {exc}",
                file=sys.stderr,
            )
            continue

        count = 0

        for package, path in parse_arch_files_database(
            data
        ):

            include_name = include_name_from_path(
                path
            )

            result[include_name].add(
                (
                    package,
                    path,
                )
            )

            count += 1

        print(
            f"  {repository}: "
            f"{count:,} header/package entries"
        )

    print(
        f"  unique Arch headers: "
        f"{len(result):,}"
    )

    return result


# ---------------------------------------------------------------------------
# FreeBSD
# ---------------------------------------------------------------------------

def freebsd_provides_url(
    abi: str,
) -> str:
    """
    Build the pkg-provides database URL for a FreeBSD ABI.

        FreeBSD:15:amd64
        ->
        https://pkg-provides.osorio.me/v3/FreeBSD/15:amd64/provides.db.xz

    pkg-provides publishes one database per release/architecture
    (there is no latest/quarterly distinction).
    """

    osname, osver, arch = abi.split(":", 2)

    return (
        f"{PROVIDES_MIRROR}/"
        f"{PROVIDES_DB_VERSION}/"
        f"{osname}/{osver}:{arch}/"
        "provides.db.xz"
    )


def compile_provides_decoder(
    source: str,
) -> str:
    """
    Compile the small C program that decodes a pkg-provides
    provides.db (locate bigram format).

    The binary is cached in the system temp directory and
    rebuilt whenever the source is newer.
    """

    binary = os.path.join(
        tempfile.gettempdir(),
        "decode-provides-db",
    )

    if os.path.exists(binary):
        if os.path.getmtime(binary) >= os.path.getmtime(source):
            return binary

    compiler = os.environ.get("CC", "cc")

    try:
        subprocess.run(
            [compiler, "-O2", "-o", binary, source],
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise RuntimeError(
            f"Unable to build the pkg-provides decoder "
            f"({source}): {exc}"
        ) from exc

    return binary


def parse_provides_db(
    decoder: str,
    data: bytes,
) -> Iterable[tuple[str, str]]:
    """
    Decode provides.db and yield:

        package, path

    The database is the sorted output of "package*path" lines
    encoded with the FreeBSD locate bigram algorithm.  The
    bundled C program expands it.
    """

    with tempfile.NamedTemporaryFile(
        prefix="provides-db-",
    ) as tmp:

        tmp.write(data)
        tmp.flush()

        with open(tmp.name, "rb") as source:

            process = subprocess.Popen(
                [decoder],
                stdin=source,
                stdout=subprocess.PIPE,
            )

            for raw_line in process.stdout:

                line = raw_line.decode(
                    "utf-8",
                    errors="replace",
                ).strip()

                package, sep, path = line.partition("*")

                if not sep:
                    continue

                path = normalize_path(path)

                if not is_public_header(path):
                    continue

                yield package, path

            process.wait()

            if process.returncode != 0:
                raise RuntimeError(
                    "pkg-provides decoder failed"
                )


def load_freebsd(
    abi: str,
) -> dict[str, set[tuple[str, str]]]:
    """
    Return:

        include_name -> {(package, path), ...}

    Sources the file list from the pkg-provides database, which
    is rebuilt daily from the FreeBSD official repositories.
    """

    print()
    print("=== FreeBSD ===")
    print(f"ABI: {abi}")

    url = freebsd_provides_url(abi)

    print(f"  database: {url}")

    try:
        archive_data = download(url)
    except Exception as exc:
        raise RuntimeError(
            f"Unable to download the pkg-provides database "
            f"{url}: {exc}"
        ) from exc

    print(
        f"  downloaded: "
        f"{len(archive_data):,} bytes"
    )

    try:
        import lzma

        data = lzma.decompress(archive_data)
    except Exception as exc:
        raise RuntimeError(
            f"Unable to decompress the pkg-provides database: "
            f"{exc}"
        ) from exc

    source = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "decode-provides-db.c",
    )

    decoder = compile_provides_decoder(source)

    print(
        f"  decompressed: "
        f"{len(data):,} bytes"
    )

    result = defaultdict(set)

    count = 0

    for package, path in parse_provides_db(
        decoder,
        data,
    ):

        include_name = include_name_from_path(
            path
        )

        result[include_name].add(
            (package, path)
        )

        count += 1

    print(
        f"  header/package entries: "
        f"{count:,}"
    )

    print(
        f"  unique FreeBSD headers: "
        f"{len(result):,}"
    )

    return result


# ---------------------------------------------------------------------------
# Intersection
# ---------------------------------------------------------------------------

def common_headers(
    debian,
    arch,
    freebsd,
):
    """
    Keep only include names present in all three databases.
    """

    common = (
        set(debian)
        & set(arch)
        & set(freebsd)
    )

    print()
    print("=== Intersection ===")
    print(
        f"Debian headers:   {len(debian):,}"
    )
    print(
        f"Arch headers:     {len(arch):,}"
    )
    print(
        f"FreeBSD headers:  {len(freebsd):,}"
    )
    print(
        f"COMMON headers:   {len(common):,}"
    )

    return common


# ---------------------------------------------------------------------------
# SQLite
# ---------------------------------------------------------------------------

SCHEMA = """
PRAGMA journal_mode = DELETE;
PRAGMA foreign_keys = ON;

CREATE TABLE distro (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    include_prefix TEXT NOT NULL
);

CREATE TABLE header (
    id INTEGER PRIMARY KEY,
    include_name TEXT NOT NULL UNIQUE,
    basename TEXT NOT NULL
);

CREATE TABLE package (
    id INTEGER PRIMARY KEY,
    distro_id INTEGER NOT NULL,
    name TEXT NOT NULL,

    UNIQUE(distro_id, name),

    FOREIGN KEY(distro_id)
        REFERENCES distro(id)
);

-- An installed path is always include_prefix || include_name,
-- where include_prefix is fixed per distro
-- (usr/include/ on Debian and Arch, usr/local/include/ on
-- FreeBSD).  Storing the path per provider row would repeat
-- it hundreds of thousands of times, so we drop it and
-- reconstruct on query.
CREATE TABLE provider (
    header_id INTEGER NOT NULL,
    package_id INTEGER NOT NULL,

    PRIMARY KEY(header_id, package_id),

    FOREIGN KEY(header_id)
        REFERENCES header(id),

    FOREIGN KEY(package_id)
        REFERENCES package(id)
);

CREATE INDEX idx_header_include_name
    ON header(include_name);

CREATE INDEX idx_header_basename
    ON header(basename);

CREATE INDEX idx_provider_package
    ON provider(package_id);
"""


def create_database(
    filename: str,
    common,
    debian,
    arch,
    freebsd,
):
    if os.path.exists(filename):
        os.unlink(filename)

    db = sqlite3.connect(filename)

    db.executescript(SCHEMA)

    distro_ids = {}

    distro_prefixes = {
        "debian": "usr/include/",
        "arch": "usr/include/",
        "freebsd": "usr/local/include/",
    }

    for name in (
        "debian",
        "arch",
        "freebsd",
    ):

        cursor = db.execute(
            """
            INSERT INTO distro(name, include_prefix)
            VALUES (?, ?)
            """,
            (
                name,
                distro_prefixes[name],
            ),
        )

        distro_ids[name] = cursor.lastrowid

    package_ids = {}

    def get_package(
        distro: str,
        package: str,
    ) -> int:

        key = (
            distro,
            package,
        )

        if key in package_ids:
            return package_ids[key]

        cursor = db.execute(
            """
            INSERT OR IGNORE INTO package
                (distro_id, name)
            VALUES (?, ?)
            """,
            (
                distro_ids[distro],
                package,
            ),
        )

        row = db.execute(
            """
            SELECT p.id
            FROM package p
            JOIN distro d
                ON d.id = p.distro_id
            WHERE d.name = ?
              AND p.name = ?
            """,
            key,
        ).fetchone()

        if row is None:
            raise RuntimeError(
                f"Could not insert package {key}"
            )

        package_ids[key] = row[0]

        return row[0]

    header_ids = {}

    for include_name in sorted(common):

        basename = include_name.rsplit(
            "/",
            1,
        )[-1]

        cursor = db.execute(
            """
            INSERT INTO header
                (include_name, basename)
            VALUES (?, ?)
            """,
            (
                include_name,
                basename,
            ),
        )

        header_id = cursor.lastrowid

        header_ids[include_name] = header_id

    def add_provider(
        include_name: str,
        distro: str,
        package: str,
    ):

        package_id = get_package(
            distro,
            package,
        )

        db.execute(
            """
            INSERT OR IGNORE INTO provider
                (header_id, package_id)
            VALUES (?, ?)
            """,
            (
                header_ids[include_name],
                package_id,
            ),
        )

    # Debian
    for include_name in common:

        for package, path in debian[
            include_name
        ]:

            add_provider(
                include_name,
                "debian",
                package,
            )

    # Arch
    for include_name in common:

        for package, path in arch[
            include_name
        ]:

            add_provider(
                include_name,
                "arch",
                package,
            )

    # FreeBSD
    for include_name in common:

        for package, path in freebsd[
            include_name
        ]:

            add_provider(
                include_name,
                "freebsd",
                package,
            )

    db.commit()

    # Analyze after the bulk insert.
    db.execute("ANALYZE")

    db.close()


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

def show_statistics(filename: str):

    db = sqlite3.connect(filename)

    print()
    print("=== Database ===")

    for table in (
        "distro",
        "header",
        "package",
        "provider",
    ):

        count = db.execute(
            f"SELECT COUNT(*) FROM {table}"
        ).fetchone()[0]

        print(
            f"{table:12} {count:12,}"
        )

    print()
    print("=== Sample: gphoto2/gphoto2.h ===")

    # The installed path is not stored; it is reconstructed
    # as include_prefix || include_name.
    rows = db.execute(
        """
        SELECT
            d.name,
            p.name,
            d.include_prefix || h.include_name
        FROM header h
        JOIN provider pr
            ON pr.header_id = h.id
        JOIN package p
            ON p.id = pr.package_id
        JOIN distro d
            ON d.id = p.distro_id
        WHERE h.include_name = ?
        ORDER BY d.name, p.name
        """,
        ("gphoto2/gphoto2.h",),
    ).fetchall()

    if not rows:
        print("No gphoto2/gphoto2.h mapping found.")
    else:
        for row in rows:
            print(
                f"{row[0]:8} "
                f"{row[1]:35} "
                f"{row[2]}"
            )

    print()
    print("=== Cross-distro header counts ===")

    rows = db.execute(
        """
        SELECT
            d.name,
            COUNT(DISTINCT pr.header_id)
        FROM distro d
        JOIN package p
            ON p.distro_id = d.id
        JOIN provider pr
            ON pr.package_id = p.id
        GROUP BY d.name
        ORDER BY d.name
        """
    ).fetchall()

    for distro, count in rows:
        print(
            f"{distro:8} {count:,}"
        )

    db.close()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:

    parser = argparse.ArgumentParser(
        description=(
            "Generate a compact database of C/C++ "
            "headers common to Debian, Arch Linux "
            "and FreeBSD."
        )
    )

    parser.add_argument(
        "--output",
        default="headers.db",
        help="Output SQLite database",
    )

    parser.add_argument(
        "--debian-suite",
        default=DEFAULT_DEBIAN_SUITE,
        help=(
            "Debian suite, e.g. stable, testing, "
            "or unstable"
        ),
    )

    parser.add_argument(
        "--debian-arch",
        default=DEFAULT_DEBIAN_ARCH,
        help="Debian architecture",
    )

    parser.add_argument(
        "--arch-arch",
        default=DEFAULT_ARCH_ARCH,
        help="Arch architecture",
    )

    parser.add_argument(
        "--arch-repository",
        action="append",
        dest="arch_repositories",
        default=None,
        help=(
            "Arch repository to import. "
            "Can be specified more than once."
        ),
    )

    parser.add_argument(
        "--freebsd-abi",
        default=DEFAULT_FREEBSD_ABI,
        help=(
            "FreeBSD repository ABI, e.g. "
            "FreeBSD:15:amd64"
        ),
    )

    args = parser.parse_args()

    arch_repositories = tuple(
        args.arch_repositories
        or DEFAULT_ARCH_REPOSITORIES
    )

    print("Build.app header database generator")
    print("-----------------------------------")

    print()
    print("Configuration:")
    print(
        f"  Debian:   {args.debian_suite} "
        f"{args.debian_arch}"
    )
    print(
        f"  Arch:     {args.arch_arch} "
        f"{', '.join(arch_repositories)}"
    )
    print(
        f"  FreeBSD:  {args.freebsd_abi}"
    )
    print(
        f"  Output:   {args.output}"
    )

    debian = load_debian(
        suite=args.debian_suite,
        architecture=args.debian_arch,
    )

    arch = load_arch(
        repositories=arch_repositories,
        architecture=args.arch_arch,
    )

    freebsd = load_freebsd(
        abi=args.freebsd_abi,
    )

    common = common_headers(
        debian,
        arch,
        freebsd,
    )

    if not common:
        print()
        print(
            "ERROR: no common headers found.",
            file=sys.stderr,
        )
        return 1

    print()
    print(
        f"Writing {len(common):,} "
        f"common headers..."
    )

    create_database(
        filename=args.output,
        common=common,
        debian=debian,
        arch=arch,
        freebsd=freebsd,
    )

    show_statistics(args.output)

    size = os.path.getsize(
        args.output
    )

    print()
    print(
        f"Created {args.output} "
        f"({size:,} bytes)"
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())