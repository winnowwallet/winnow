#!/usr/bin/env python3
"""Generate public-data fixtures with Python integers and two pinned lift_x oracles.

Usage: python3 Tools/generate_vectors.py /path/to/bips /path/to/secp256k1 /path/to/xonly_oracle
Writes deterministic JSON only; does not call the Swift implementation.
"""
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

BIPS_REVISION = "927b6de9915c9262615a6399de51b200f81e5aa4"
SECP_REVISION = "1a53f4961f337b4d166c25fce72ef0dc88806618"
P = 2**256 - 2**32 - 977


def check_revision(path, expected):
    actual = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    if actual != expected:
        raise RuntimeError(f"revision mismatch: {path}: {actual}")
    if subprocess.check_output(["git", "-C", str(path), "status", "--porcelain", "--untracked-files=no"], text=True):
        raise RuntimeError(f"tracked files modified: {path}")


def h(value):
    return value.to_bytes(32, "big").hex()


def derived(domain, index):
    # Stable synthetic PUBLIC integers, not an entropy source for secrets.
    return int.from_bytes(hashlib.sha256(f"winnow-public-field-v1/{domain}/{index}".encode("ascii")).digest(), "big")


def main():
    bips, secp, oracle = map(Path, sys.argv[1:])
    check_revision(bips, BIPS_REVISION)
    check_revision(secp, SECP_REVISION)
    spec = importlib.util.spec_from_file_location("bip340_reference", bips / "bip-0340/reference.py")
    reference = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reference)
    assert reference.p == P

    # Full Cartesian product crosses every word boundary with 0, 1, p-1 and
    # alternating limbs; expected arithmetic uses Python's arbitrary integers.
    edges = [0, 1, 2, 7, 976, 977, 978, P-1, P-2, P-977,
             int("aaaaaaaa" * 8, 16), int("55555555" * 8, 16)]
    for bit in range(32, 256, 32):
        edges += [2**bit-1, 2**bit, 2**bit+1, P-2**bit]
    edges = sorted(set(edges))
    pairs = [(a, b) for a in edges for b in edges]
    pairs += [(derived("a", i) % P, derived("b", i) % P) for i in range(1024)]
    arithmetic = [dict(a=h(a), b=h(b), sum=h((a+b) % P), product=h((a*b) % P), negation=h((-a) % P)) for a, b in pairs]

    roots = []
    for value in edges + [derived("root", i) % P for i in range(128)]:
        root = pow(value, (P+1)//4, P)
        valid = root * root % P == value
        even = (P-root if root & 1 else root) if valid else None
        roots.append(dict(value=h(value), evenRoot=None if even is None else h(even)))

    # These are key-validation cases extracted from the public-key column.
    # An invalid signature may still contain a valid key: NEVER copy the CSV's
    # signature-verification boolean as the key-validation expected answer.
    cases = []
    with (bips / "bip-0340/test-vectors.csv").open(newline="") as source:
        for row in csv.DictReader(source):
            cases.append((f"bip340-key-{row['index']}", int(row["public key"], 16)))
    cases += [(f"boundary-{i}", x) for i, x in enumerate(edges + [P, P+1, 2**256-1])]
    cases += [(f"synthetic-{i}", derived("xonly", i)) for i in range(256)]
    inputs = "".join(h(x) + "\n" for _, x in cases)
    answers = subprocess.check_output([str(oracle.resolve())], input=inputs, text=True).splitlines()
    if len(answers) != len(cases):
        raise RuntimeError("oracle output count mismatch")
    xonly = []
    for (name, x), c_result in zip(cases, answers):
        point = reference.lift_x(x)
        expected = "invalid" if point is None else h(point[1])
        if c_result != expected:
            raise RuntimeError(f"independent oracles disagree for {name}")
        xonly.append(dict(name=name, x=h(x), evenY=None if point is None else h(point[1])))

    output = Path(__file__).resolve().parents[3] / "Tests/BitcoinCoreTests/Vectors/native-secp256k1"
    for name, value in [("field-arithmetic", arithmetic), ("field-roots", roots), ("xonly-validation", xonly)]:
        (output / f"{name}.json").write_text(json.dumps(value, indent=2) + "\n")
    print(json.dumps(dict(arithmeticPairs=len(arithmetic), squareRoots=len(roots), xOnlyCases=len(xonly),
                          validXOnly=sum(v["evenY"] is not None for v in xonly),
                          invalidXOnly=sum(v["evenY"] is None for v in xonly),
                          bips=BIPS_REVISION, secp256k1=SECP_REVISION), indent=2))


if __name__ == "__main__":
    main()
