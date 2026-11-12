#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Diagnostic only: retain three original SDK outputs without changing them."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import selectors
import stat
import struct
import subprocess
import sys
import time

ROOTS = {
    "openssl097": "/nix/store/01sh2l23n9ff9h9j5k80mxw98c4516l9-openssl-0.9.7m",
    "ruby183": "/nix/store/wzxr0hmqmwwrbcps64l0scwif6kyij6q-ruby-1.8.3",
    "json113": "/nix/store/h3wfzy3v0jqrzm5az20r0njidrs0lljj-ruby183-gem095-bundler031-bundler-0.3.1-json113",
}
ROOT_LIMIT = 64 * 1024 * 1024
TOTAL_LIMIT = 256 * 1024 * 1024
FILE_LIMIT = 16 * 1024 * 1024
ENTRY_LIMIT = 6000
sha = lambda raw: hashlib.sha256(raw).hexdigest()


def safe_link(target):
    parts = PurePosixPath(target)
    return bool(target) and len(target.encode()) <= 4096 and not parts.is_absolute() and ".." not in parts.parts and "\0" not in target


def inventory(root, tick):
    """Use directory FDs throughout; never open a symlink or intermediate link."""
    rows = []
    total = 0
    if str(root) not in ROOTS.values() or root.resolve() != root:
        raise ValueError("unexpected or noncanonical immutable root")
    if not stat.S_ISDIR(root.lstat().st_mode):
        raise ValueError("root is not an original directory")

    def walk(fd, relative, depth):
        nonlocal total
        tick()
        if depth > 64 or len(rows) >= ENTRY_LIMIT:
            raise ValueError("tree depth/entry limit")
        current = os.fstat(fd)
        rows.append(dict(path=relative, type="directory", mode=stat.S_IMODE(current.st_mode)))
        for name in sorted(os.listdir(fd), key=os.fsencode):
            tick()
            if name in ("", ".", "..") or "/" in name or len(os.fsencode(name)) > 4096:
                raise ValueError("unsafe entry name")
            path = name if relative == "." else relative + "/" + name
            observed = os.stat(name, dir_fd=fd, follow_symlinks=False)
            mode = observed.st_mode
            if len(rows) >= ENTRY_LIMIT:
                raise ValueError("tree entry limit")
            row = dict(path=path, mode=stat.S_IMODE(mode))
            if stat.S_ISDIR(mode):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    actual = os.fstat(child)
                    if (actual.st_dev, actual.st_ino) != (observed.st_dev, observed.st_ino):
                        raise ValueError("directory inode changed")
                    walk(child, path, depth + 1)
                finally:
                    os.close(child)
                continue
            if stat.S_ISLNK(mode):
                target = os.readlink(name, dir_fd=fd)
                if not safe_link(target):
                    raise ValueError("escaping or invalid leaf symlink")
                row.update(type="symlink", target=target)
            elif stat.S_ISREG(mode):
                if observed.st_size > FILE_LIMIT:
                    raise ValueError("file byte limit")
                total += observed.st_size
                if total > ROOT_LIMIT:
                    raise ValueError("root byte limit")
                child = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
                with os.fdopen(child, "rb") as source:
                    actual = os.fstat(source.fileno())
                    if (actual.st_dev, actual.st_ino, actual.st_size) != (observed.st_dev, observed.st_ino, observed.st_size):
                        raise ValueError("file inode changed")
                    raw = source.read(FILE_LIMIT + 1)
                if len(raw) != observed.st_size:
                    raise ValueError("file changed during read")
                row.update(type="file", size=len(raw), executable=bool(mode & 0o111), sha256=sha(raw))
            else:
                raise ValueError("unsupported special file")
            rows.append(row)
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        walk(fd, ".", 0)
    finally:
        os.close(fd)
    return dict(root=str(root), entries=sorted(rows, key=lambda row: row["path"]), totalFileBytes=total)


def validate_nar(raw, manifest):
    """Validate canonical NAR framing and every retained payload, without extraction."""
    if len(raw) > ROOT_LIMIT:
        raise ValueError("NAR byte limit")
    position = 0
    expected = {row["path"]: row for row in manifest["entries"]}
    if len(expected) != len(manifest["entries"]):
        raise ValueError("duplicate manifest paths")
    seen = set()

    def string(maximum=128):
        nonlocal position
        if position + 8 > len(raw):
            raise ValueError("truncated NAR length")
        size = struct.unpack_from("<Q", raw, position)[0]
        position += 8
        if size > maximum or position + size + (-size % 8) > len(raw):
            raise ValueError("invalid NAR string length")
        value = raw[position:position + size]
        position += size
        padding = -size % 8
        if raw[position:position + padding] != b"\0" * padding:
            raise ValueError("noncanonical NAR padding")
        position += padding
        return value

    def take(value):
        if string() != value:
            raise ValueError("unexpected NAR token")

    def node(path, depth=0):
        if depth > 64 or path not in expected or path in seen or len(seen) >= ENTRY_LIMIT:
            raise ValueError("unexpected NAR path/depth/duplicate")
        seen.add(path)
        row = expected[path]
        take(b"("); take(b"type")
        kind = string()
        if kind == b"directory" and row["type"] == "directory":
            previous = None
            token = string()
            while token == b"entry":
                take(b"("); take(b"name")
                name = string(4096)
                if not name or name in (b".", b"..") or b"/" in name or b"\0" in name or (previous is not None and name <= previous):
                    raise ValueError("unsafe/unsorted NAR entry")
                previous = name
                take(b"node")
                node(os.fsdecode(name) if path == "." else path + "/" + os.fsdecode(name), depth + 1)
                take(b")")
                token = string()
            if token != b")":
                raise ValueError("invalid directory terminator")
            return
        if kind == b"regular" and row["type"] == "file":
            token = string()
            executable = token == b"executable"
            if executable:
                take(b""); token = string()
            if token != b"contents":
                raise ValueError("invalid regular NAR")
            content = string(FILE_LIMIT)
            if len(content) != row["size"] or sha(content) != row["sha256"] or executable != row["executable"]:
                raise ValueError("NAR payload differs from no-follow inventory")
        elif kind == b"symlink" and row["type"] == "symlink":
            take(b"target")
            if string(4096) != os.fsencode(row["target"]):
                raise ValueError("NAR link target differs")
        else:
            raise ValueError("NAR type differs from inventory")
        take(b")")

    take(b"nix-archive-1"); node(".")
    if position != len(raw) or seen != set(expected):
        raise ValueError("NAR trailing bytes or missing paths")
    return sha(raw)


def worker(out, nix):
    if not out.is_absolute() or out.resolve() != out or not stat.S_ISDIR(out.lstat().st_mode):
        raise ValueError("canonical diagnostic output directory required")
    deadline = time.monotonic() + 75
    receipt = dict(complete=False, scope="Read-only original SDK diagnostic; no builds or fixes", roots={}, commands=[], limits=dict(rootBytes=ROOT_LIMIT, aggregateBytes=TOTAL_LIMIT, fileBytes=FILE_LIMIT, entries=ENTRY_LIMIT, workerSeconds=75, ownerSeconds=90))
    receipt["collectorSha256"] = sha(Path(__file__).read_bytes())
    receipt["helperSha256"] = sha(Path(__file__).with_name("diagnostic_bounded.py").read_bytes())
    used = 0

    def tick():
        value = deadline - time.monotonic()
        if value <= 0:
            raise TimeoutError("diagnostic worker deadline")
        return value

    def budget(amount):
        nonlocal used
        used += amount
        if used > TOTAL_LIMIT:
            raise ValueError("aggregate diagnostic byte limit")

    def save():
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")

    def run(label, argv, limit=1024 * 1024, output_name=None):
        tick()
        if len(receipt["commands"]) >= 32:
            raise ValueError("diagnostic command count limit")
        # The worker owns one group; descendants stay in that group. The outer
        # reviewed helper kills the whole group even when inherited pipes persist.
        child = subprocess.Popen(list(map(str, argv)), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        selector = selectors.DefaultSelector()
        streams = [out / (output_name or label + ".stdout"), out / (label + ".stderr")]
        files = [p.open("xb") for p in streams]
        hashes = [hashlib.sha256(), hashlib.sha256()]
        sizes = [0, 0]
        bounds = [limit, 1024 * 1024]
        record = dict(label=label, argv=list(map(str, argv)), exit=None)
        receipt["commands"].append(record)
        try:
            for i, stream in enumerate((child.stdout, child.stderr)):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, i)
            command_deadline = time.monotonic() + min(20, tick())
            while selector.get_map() or child.poll() is None:
                wait = min(tick(), command_deadline - time.monotonic())
                if wait <= 0:
                    raise TimeoutError("diagnostic command/pipe deadline")
                for key, _ in selector.select(min(wait, .05)):
                    i = key.data
                    raw = os.read(key.fileobj.fileno(), min(65536, bounds[i] - sizes[i] + 1))
                    if not raw:
                        selector.unregister(key.fileobj)
                        continue
                    kept = raw[:bounds[i] - sizes[i]]
                    budget(len(kept)); files[i].write(kept); hashes[i].update(kept); sizes[i] += len(kept)
                    if len(kept) != len(raw):
                        record["truncatedAtLimit"] = True
                        raise ValueError("diagnostic stream byte limit")
            record["exit"] = child.returncode
            if child.returncode != 0:
                raise RuntimeError("diagnostic command failed")
        except Exception as error:
            record["failure"] = dict(type=type(error).__name__, message=str(error))
            raise
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
            selector.close()
            child.stdout.close(); child.stderr.close()
            for i, file in enumerate(files):
                file.close()
                record[("stdout", "stderr")[i]] = dict(path=streams[i].name, size=sizes[i], sha256=hashes[i].hexdigest())
            save()
        return streams[0].read_bytes()

    def immutable_file(path, limit=1024 * 1024):
        path = Path(path)
        if not re.fullmatch(r"/nix/store/[a-z0-9]{32}-[^/]+", str(path)) or path.resolve() != path:
            raise ValueError("invalid immutable provenance file")
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise ValueError("provenance file type/size")
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as source:
            after = os.fstat(source.fileno())
            if (before.st_dev, before.st_ino, before.st_size) != (after.st_dev, after.st_ino, after.st_size):
                raise ValueError("provenance inode changed")
            raw = source.read(limit + 1)
        if len(raw) != before.st_size:
            raise ValueError("provenance changed")
        budget(len(raw))
        return raw

    try:
        # Validate ALL three original roots before asking any subprocess to read
        # their content. No caller-supplied root or allowlist expansion exists.
        inventories = {role: inventory(Path(path), tick) for role, path in ROOTS.items()}
        if sum(len(m["entries"]) for m in inventories.values()) > ENTRY_LIMIT:
            raise ValueError("aggregate entry limit")
        budget(sum(m["totalFileBytes"] for m in inventories.values()))
        if not re.fullmatch(r"/nix/store/[a-z0-9]{32}-[^/]+/bin/nix", str(nix)) or nix.resolve() != nix or not stat.S_ISREG(nix.lstat().st_mode) or nix.lstat().st_size > FILE_LIMIT:
            raise ValueError("explicit canonical Nix executable required")
        receipt["nix"] = dict(path=str(nix), sha256=sha(nix.read_bytes()))
        run("nix-version", [nix, "--version"])
        run("openssl-version", [Path(ROOTS["openssl097"]) / "bin/openssl", "version", "-a"])
        run("ruby-version", [Path(ROOTS["ruby183"]) / "bin/ruby", "-v"])
        run("ruby-config", [Path(ROOTS["ruby183"]) / "bin/ruby", "-rrbconfig", "-e", 'Config::CONFIG.keys.sort.each{|k|puts k+"="+Config::CONFIG[k].to_s}'])
        receipt["rubyInterpreterSha256"] = sha((Path(ROOTS["ruby183"]) / "bin/ruby").read_bytes())
        receipt["bootstrapArchives"] = {}
        for name, archive, expected in [
            ("bundler031", "/nix/store/fnwl80qdn32b303mx0s8v89vngvfab8y-bundler-0.3.1.gem", "sha256-Ru5Nqt2nlsHpQztFAV/0P2fqR8jPEObyJP9dhxJtMwI="),
            ("json113", "/nix/store/8sqrfzc756q87fydl42zq6xsk2sqlm95-json-1.1.3.gem", "sha256-N5hS1KiOaLWGBaP7rVxtfDKaTn6RsiGj1LB3xjzcZP4="),
        ]:
            import base64
            raw = immutable_file(archive, ROOT_LIMIT)
            if "sha256-" + base64.b64encode(hashlib.sha256(raw).digest()).decode() != expected:
                raise ValueError("original bootstrap archive hash differs")
            receipt["bootstrapArchives"][name] = dict(path=archive, sha256=sha(raw), expected=expected)
        receipt["recipes"] = {name: sha((Path(__file__).resolve().parents[2] / "tests" / name).read_bytes()) for name in ["openssl097.nix", "ruby183-runtime.nix", "ruby095-sdk-parts.nix", "ruby183-gem095-bundler031-sdk.nix"]}
        receipt["environment"] = {key: os.environ.get(key) for key in ["SOURCE_DATE_EPOCH", "TZ", "LANG", "LC_ALL", "NIX_BUILD_CORES"]}
        for role, root in ROOTS.items():
            manifest = inventories[role]
            nar = run(role + "-nar", [nix, "--extra-experimental-features", "nix-command", "store", "dump-path", root], ROOT_LIMIT, role + ".nar")
            digest = validate_nar(nar, manifest)
            if len(nar) + manifest["totalFileBytes"] > ROOT_LIMIT:
                raise ValueError("root retained byte limit")
            physical = run(role + "-physical", [nix, "--extra-experimental-features", "nix-command", "hash", "path", "--type", "sha256", "--sri", root]).decode().strip()
            import base64
            if physical != "sha256-" + base64.b64encode(bytes.fromhex(digest)).decode():
                raise ValueError("physical NAR hash differs from retained canonical bytes")
            deriver = run(role + "-deriver", [nix.parent / "nix-store", "--query", "--deriver", root]).decode().strip()
            if not deriver.endswith(".drv"):
                raise ValueError("missing immutable original derivation")
            aterm = immutable_file(deriver)
            (out / (role + ".aterm")).write_bytes(aterm)
            derivation = run(role + "-derivation", [nix, "--extra-experimental-features", "nix-command", "derivation", "show", deriver])
            parsed = json.loads(derivation)
            values = parsed.get("derivations", parsed)
            if len(values) != 1:
                raise ValueError("unexpected derivation count")
            drv = next(iter(values.values()))
            source = drv.get("env", {}).get("src")
            source_fact = None
            if source:
                source_fact = dict(path=source, sha256=sha(immutable_file(source, ROOT_LIMIT)))
            manifest_path = out / (role + "-manifest.json")
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
            receipt["roots"][role] = dict(path=root, manifest=manifest_path.name, manifestSha256=sha(manifest_path.read_bytes()), narFile=role + ".nar", narBytes=len(nar), narSha256=digest, physicalNar=physical, aterm=role + ".aterm", atermSha256=sha(aterm), source=source_fact)
            save()
        receipt.update(complete=True, accountedBytes=used, totalEntries=sum(len(m["entries"]) for m in inventories.values()), symlinks="Relative leaf target bytes recorded only; never followed or extracted", qualification="Diagnostic bytes from this run only; do not attribute original CI differences until original remote NARs are retained and compared")
        save()
    except Exception as error:
        receipt["failure"] = dict(type=type(error).__name__, message=str(error))
        save()
        raise


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "--worker" and sys.argv[4] == "owned":
        worker(Path(sys.argv[2]), Path(sys.argv[3]))
        return
    if len(sys.argv) != 3:
        raise ValueError("usage: collect-sdk-bytes.py OUTPUT CANONICAL_NIX")
    out, nix = map(Path, sys.argv[1:])
    if not out.is_absolute() or out.resolve() != out or out.exists():
        raise ValueError("new canonical output directory required")
    out.mkdir()
    from diagnostic_bounded import run_recorded
    record = dict(label="owned-worker")
    def save():
        (out / "owner-receipt.json").write_text(json.dumps(record, indent=2) + "\n")
    result = run_recorded([sys.executable, "-B", __file__, "--worker", str(out), str(nix), "owned"], record=record, logs=out, save=save, timeout=90, output_limit=1024 * 1024)
    if result.returncode != 0:
        raise RuntimeError("diagnostic worker failed; retained receipt and raw logs identify the failure")


if __name__ == "__main__":
    main()
