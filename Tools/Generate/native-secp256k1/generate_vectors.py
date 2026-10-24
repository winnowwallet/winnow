#!/usr/bin/env python3
"""Generate public-data fixtures with Python integers and two pinned oracles.

Usage: python3 generate_vectors.py /path/to/bips /path/to/secp256k1 /path/to/xonly_oracle /path/to/differential_oracle
Writes deterministic JSON only; does not call the Swift implementation.

Field answers come from Python integer arithmetic. Every curve answer (x-only
validity, keys, tweaks, BIP340 signatures and verdicts) is computed twice, by
the BIP340 reference implementation and by a C probe over libsecp256k1, and
the two must agree exactly before it is written.
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
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

# Hand-picked edge cases carry the fixtures; a few seeded samples per file keep
# a spread of ordinary values. Broad random coverage is the fuzz harness's job
# (its native-secp256k1 target checks the module's own algebra on every run).
SAMPLES = 8


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


def derived_bytes(domain, index, length):
    # The same public domain, stretched to any length for messages.
    out = b""
    counter = 0
    while len(out) < length:
        out += hashlib.sha256(f"winnow-public-field-v1/{domain}/{index}/{counter}".encode("ascii")).digest()
        counter += 1
    return out[:length]


def token(data):
    return data.hex() if data else "-"


def oracle_answers(oracle, requests):
    answers = subprocess.check_output([str(oracle.resolve())], input="".join(r + "\n" for r in requests),
                                      text=True).splitlines()
    if len(answers) != len(requests):
        raise RuntimeError("oracle output count mismatch")
    return answers


def agree(name, c_answer, python_answer):
    if c_answer != python_answer:
        raise RuntimeError(f"independent oracles disagree for {name}: C {c_answer!r}, Python {python_answer!r}")
    return python_answer


# --- Python reference answers, from the BIP340 reference implementation -------

def compressed(point):
    return ("03" if point[1] & 1 else "02") + h(point[0])


def python_private_key(reference, secret):
    if len(secret) != 32:
        return "invalid"
    d = int.from_bytes(secret, "big")
    if not 1 <= d <= N - 1:
        return "invalid"
    point = reference.point_mul(reference.G, d)
    return f"{compressed(point)} {h(point[0])} {point[1] & 1}"


def python_public_key(reference, data):
    if len(data) != 33 or data[0] not in (2, 3):
        return "invalid"
    point = reference.lift_x(int.from_bytes(data[1:], "big"))
    return "invalid" if point is None else data.hex()


def python_tweaks(reference, d, t):
    """seckey_tweak, xonly_seckey_tweak, pubkey_tweak and xonly_tweak_secret answers."""
    if t >= N:
        return ["invalid"] * 4
    point = reference.point_mul(reference.G, d)
    plain = (d + t) % N
    even_d = d if reference.has_even_y(point) else N - d
    xonly_plain = (even_d + t) % N
    tweak_point = reference.point_mul(reference.G, t)
    public = reference.point_add(point, tweak_point)
    xonly_public = reference.point_add(reference.lift_x(point[0]), tweak_point)
    return [h(plain) if plain else "invalid",
            h(xonly_plain) if xonly_plain else "invalid",
            compressed(public) if public is not None else "invalid",
            f"{h(xonly_public[0])} {xonly_public[1] & 1}" if xonly_public is not None else "invalid"]


def python_xonly_tweak(reference, x, t):
    point = reference.lift_x(x)
    if point is None or t >= N:
        return "invalid"
    result = reference.point_add(point, reference.point_mul(reference.G, t))
    return "invalid" if result is None else f"{h(result[0])} {result[1] & 1}"


def python_verify(reference, signature, key, message):
    try:
        return "valid" if reference.schnorr_verify(message, key, signature) else "invalid"
    except ValueError:
        return "invalid"


# --- Fixtures -----------------------------------------------------------------

def key_fixtures(reference, oracle):
    boundary = [("zero", bytes(32)), ("one", (1).to_bytes(32, "big")), ("order-minus-one", (N - 1).to_bytes(32, "big")),
                ("order", N.to_bytes(32, "big")), ("order-plus-one", (N + 1).to_bytes(32, "big")),
                ("all-ones", bytes([0xFF] * 32)), ("empty", b""), ("short-31", bytes([1] * 31)), ("long-33", bytes([1] * 33))]
    secrets = boundary + [(f"derived-{i}", derived("seckey", i).to_bytes(32, "big")) for i in range(SAMPLES)]
    # The library takes exactly 32 bytes; other lengths are invalid by shape.
    sized = [(name, secret) for name, secret in secrets if len(secret) == 32]
    answers = dict(zip([name for name, _ in sized], oracle_answers(oracle, [f"seckey {s.hex()}" for _, s in sized])))
    private = []
    for name, secret in secrets:
        answer = agree(name, answers.get(name, "invalid"), python_private_key(reference, secret))
        if answer == "invalid":
            private.append(dict(name=name, secret=secret.hex(), publicKey=None, xOnly=None, parity=None))
        else:
            public, x, parity = answer.split()
            private.append(dict(name=name, secret=secret.hex(), publicKey=public, xOnly=x, parity=parity == "1"))

    inputs = []
    for i in range(SAMPLES):
        x = derived("pubkey-x", i).to_bytes(32, "big")
        inputs += [(f"derived-{i}-prefix-{prefix:02x}", bytes([prefix]) + x) for prefix in (0x00, 0x02, 0x03, 0x04, 0xFF)]
    for name, value in [("zero", 0), ("one", 1), ("order-minus-one", N - 1), ("order", N), ("order-plus-one", N + 1),
                        ("all-ones", 2**256 - 1)]:
        inputs += [(f"{name}-prefix-{prefix:02x}", bytes([prefix]) + value.to_bytes(32, "big")) for prefix in (0x02, 0x03)]
    inputs += [("empty", b""), ("prefix-only", b"\x02"), ("long-34", b"\x02" + bytes(33))]
    public = []
    for (name, data), c_answer in zip(inputs, oracle_answers(oracle, [f"pubkey {token(d)}" for _, d in inputs])):
        answer = agree(name, c_answer, python_public_key(reference, data))
        public.append(dict(name=name, input=data.hex(), compressed=None if answer == "invalid" else answer))
    return private, public


def tweak_fixtures(reference, oracle):
    cases = []
    for i in range(SAMPLES):
        d = derived("tweak-secret", i)
        assert 1 <= d <= N - 1
        for label, t in [("derived", derived("tweak", i)), ("zero", 0), ("one", 1), ("order-minus-one", N - 1),
                         ("order", N), ("order-minus-secret", N - d)]:
            cases.append((f"derived-{i}-{label}", d, t))
    for i in range(SAMPLES // 2):
        d = derived("infinity-secret", i)
        assert 1 <= d <= N - 1
        point = reference.point_mul(reference.G, d)
        # The negation of lift_x(x)'s discrete log: the x-only sum is infinity.
        cases.append((f"infinity-{i}", d, N - (d if reference.has_even_y(point) else N - d)))
    requests = []
    for _, d, t in cases:
        requests += [f"{op} {h(d)} {h(t)}" for op in ("seckey_tweak", "xonly_seckey_tweak", "pubkey_tweak", "xonly_tweak_secret")]
    answers = oracle_answers(oracle, requests)
    tweaks = []
    for index, (name, d, t) in enumerate(cases):
        c_answers = answers[4 * index: 4 * index + 4]
        plain, xonly_plain, public, xonly_public = [agree(f"{name} {op}", c, py) for op, c, py in
                                                    zip(("seckey_tweak", "xonly_seckey_tweak", "pubkey_tweak", "xonly_tweak_secret"),
                                                        c_answers, python_tweaks(reference, d, t))]
        tweaks.append(dict(name=name, secret=h(d), tweak=h(t),
                           privateTweak=None if plain == "invalid" else plain,
                           xOnlyPrivateTweak=None if xonly_plain == "invalid" else xonly_plain,
                           publicTweak=None if public == "invalid" else public,
                           xOnlyPublicTweak=parse_xonly(xonly_public)))
    return tweaks


def parse_xonly(answer):
    if answer == "invalid":
        return None
    x, parity = answer.split()
    return dict(x=x, parity=parity == "1")


def xonly_tweak_fixtures(reference, oracle, xonly_cases):
    xs = [(name, x) for name, x in xonly_cases]
    for i in range(SAMPLES):
        xs.append((f"derived-key-{i}", reference.point_mul(reference.G, derived("xonly-secret", i))[0]))
    xs += [("prime", P), ("prime-plus-one", P + 1), ("all-ones", 2**256 - 1)]
    requests, labels = [], []
    for index, (name, x) in enumerate(xs):
        tweaks = [derived("xonly-tweak", index), 0, 1, N - 1, N]
        labels.append(tweaks)
        requests += [f"xonly_tweak {h(x)} {h(t)}" for t in tweaks]
    answers = oracle_answers(oracle, requests)
    fixtures = []
    for index, (name, x) in enumerate(xs):
        results = []
        for offset, t in enumerate(labels[index]):
            answer = agree(f"{name} tweak {offset}", answers[5 * index + offset], python_xonly_tweak(reference, x, t))
            result = parse_xonly(answer) or dict(x=None, parity=None)
            results.append(dict(tweak=h(t), **result))
        fixtures.append(dict(name=name, x=h(x), results=results))
    return fixtures


LENGTHS = [32, 32, 0, 1, 17, 100]


def signature_fixtures(reference, oracle):
    cases = []
    for i in range(2 * len(LENGTHS)):
        secret = derived("sign-secret", i).to_bytes(32, "big")
        message = derived_bytes("sign-message", i, LENGTHS[i % len(LENGTHS)])
        aux = bytes(32) if i % 2 == 0 else derived_bytes("sign-aux", i, 32)
        cases.append((f"derived-{i}", secret, message, aux))
    answers = oracle_answers(oracle, [f"sign {s.hex()} {a.hex()} {token(m)}" for _, s, m, a in cases])
    fixtures = []
    for (name, secret, message, aux), c_answer in zip(cases, answers):
        signature = agree(name, c_answer, reference.schnorr_sign(message, secret, aux).hex())
        fixtures.append(dict(name=name, secret=secret.hex(), message=message.hex(), auxiliaryRand=aux.hex(),
                             signature=signature))
    return fixtures


def verification_fixtures(reference, oracle):
    bases = []
    for i in range(len(LENGTHS)):
        secret = derived("verify-secret", i).to_bytes(32, "big")
        message = derived_bytes("verify-message", i, LENGTHS[i % len(LENGTHS)])
        aux = derived_bytes("verify-aux", i, 32)
        bases.append((i, secret, message, aux))
    signatures = oracle_answers(oracle, [f"sign {s.hex()} {a.hex()} {token(m)}" for _, s, m, a in bases])
    candidates = []
    for (i, secret, message, aux), c_signature in zip(bases, signatures):
        signature = bytes.fromhex(agree(f"base-{i}", c_signature, reference.schnorr_sign(message, secret, aux).hex()))
        key = reference.pubkey_gen(secret)
        candidates.append((f"derived-{i}-valid", signature, message, key))
        for byte in (0, 17, 31, 32, 50, 63):
            mutated = bytearray(signature)
            mutated[byte] ^= 1 << (i % 8)
            candidates.append((f"derived-{i}-signature-bit-{byte}", bytes(mutated), message, key))
        flipped_message = bytearray(message)
        if flipped_message:
            flipped_message[i % len(flipped_message)] ^= 0x80
        candidates.append((f"derived-{i}-message-flipped", signature, bytes(flipped_message), key))
        flipped_key = bytearray(key)
        flipped_key[i % 32] ^= 0x01
        candidates.append((f"derived-{i}-key-flipped", signature, message, bytes(flipped_key)))
        candidates.append((f"derived-{i}-r-is-prime", P.to_bytes(32, "big") + signature[32:], message, key))
        candidates.append((f"derived-{i}-s-is-order", signature[:32] + N.to_bytes(32, "big"), message, key))
        candidates.append((f"derived-{i}-halves-swapped", signature[32:] + signature[:32], message, key))
        candidates.append((f"derived-{i}-signature-63", signature[:63], message, key))
        candidates.append((f"derived-{i}-signature-65", signature + b"\x00", message, key))
        candidates.append((f"derived-{i}-other-key", signature, message, derived_bytes("verify-other-key", i, 32)))
        candidates.append((f"derived-{i}-key-31", signature, message, bytes(31)))
        candidates.append((f"derived-{i}-message-extended", signature, message + b"\x00", key))
    answers = oracle_answers(oracle, [f"verify {token(s)} {token(k)} {token(m)}" for _, s, m, k in candidates])
    fixtures = []
    for (name, signature, message, key), c_answer in zip(candidates, answers):
        verdict = agree(name, c_answer, python_verify(reference, signature, key, message))
        fixtures.append(dict(name=name, signature=signature.hex(), message=message.hex(), publicKey=key.hex(),
                             valid=verdict == "valid"))
    return fixtures


def main():
    bips, secp, oracle, differential = map(Path, sys.argv[1:])
    check_revision(bips, BIPS_REVISION)
    check_revision(secp, SECP_REVISION)
    spec = importlib.util.spec_from_file_location("bip340_reference", bips / "bip-0340/reference.py")
    reference = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reference)
    assert reference.p == P
    assert reference.n == N

    # Full Cartesian product crosses every word boundary with 0, 1, p-1 and
    # alternating limbs; expected arithmetic uses Python's arbitrary integers.
    edges = [0, 1, 2, 7, 976, 977, 978, P-1, P-2, P-977,
             int("aaaaaaaa" * 8, 16), int("55555555" * 8, 16)]
    for bit in range(32, 256, 32):
        edges += [2**bit-1, 2**bit, 2**bit+1, P-2**bit]
    edges = sorted(set(edges))
    # Every edge value squared and against six partners that stress the
    # carries and the fold: zero, one, 977, a full low word, p - 2^32 and p - 1.
    partners = [0, 1, 977, 2**64 - 1, P - 2**32, P - 1]
    pairs = [(a, b) for a in edges for b in partners]
    pairs += [(a, a) for a in edges if a not in partners]
    pairs += [(derived("a", i) % P, derived("b", i) % P) for i in range(2 * SAMPLES)]
    arithmetic = [dict(a=h(a), b=h(b), sum=h((a+b) % P), product=h((a*b) % P), negation=h((-a) % P)) for a, b in pairs]

    roots = []
    for value in edges + [derived("root", i) % P for i in range(2 * SAMPLES)]:
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
    cases += [(f"synthetic-{i}", derived("xonly", i)) for i in range(2 * SAMPLES)]
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

    private, public = key_fixtures(reference, differential)
    tweaks = tweak_fixtures(reference, differential)
    xonly_tweaks = xonly_tweak_fixtures(reference, differential, cases)
    signatures = signature_fixtures(reference, differential)
    verification = verification_fixtures(reference, differential)

    output = Path(__file__).resolve().parents[3] / "Tests/BitcoinCoreTests/Vectors/native-secp256k1"
    for name, value in [("field-arithmetic", arithmetic), ("field-roots", roots), ("xonly-validation", xonly),
                        ("private-keys", private), ("public-keys", public), ("tweaks", tweaks),
                        ("xonly-tweaks", xonly_tweaks), ("schnorr-signatures", signatures),
                        ("schnorr-verification", verification)]:
        (output / f"{name}.json").write_text(
            "[\n" + ",\n".join(json.dumps(case, separators=(",", ":")) for case in value) + "\n]\n")
    print(json.dumps(dict(arithmeticPairs=len(arithmetic), squareRoots=len(roots), xOnlyCases=len(xonly),
                          validXOnly=sum(v["evenY"] is not None for v in xonly),
                          invalidXOnly=sum(v["evenY"] is None for v in xonly),
                          privateKeys=len(private), validPrivateKeys=sum(v["publicKey"] is not None for v in private),
                          publicKeys=len(public), validPublicKeys=sum(v["compressed"] is not None for v in public),
                          tweaks=len(tweaks),
                          validPrivateTweaks=sum(v["privateTweak"] is not None for v in tweaks),
                          validXOnlyPrivateTweaks=sum(v["xOnlyPrivateTweak"] is not None for v in tweaks),
                          validPublicTweaks=sum(v["publicTweak"] is not None for v in tweaks),
                          validXOnlyPublicTweaks=sum(v["xOnlyPublicTweak"] is not None for v in tweaks),
                          xOnlyTweakKeys=len(xonly_tweaks),
                          validXOnlyTweaks=sum(r["x"] is not None for v in xonly_tweaks for r in v["results"]),
                          signatures=len(signatures), verifications=len(verification),
                          validVerifications=sum(v["valid"] for v in verification),
                          bips=BIPS_REVISION, secp256k1=SECP_REVISION), indent=2))


if __name__ == "__main__":
    main()
