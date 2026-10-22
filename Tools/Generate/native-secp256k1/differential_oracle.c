/* Public-input differential oracle over libsecp256k1 for the key, tweak and
 * BIP340 operations of the native Swift module; not part of the Swift product.
 *
 * One request per stdin line, one answer per stdout line. Byte strings are
 * lower-case hex; "-" is the empty string. A malformed request exits non-zero
 * so a broken generator can never pass as an oracle disagreement.
 *
 *   seckey <sk>                -> invalid | <compressed33> <x32> <parity>
 *   pubkey <bytes>             -> invalid | <compressed33>
 *   seckey_tweak <sk> <t>      -> invalid | <sk32>        (ec_seckey_tweak_add)
 *   xonly_seckey_tweak <sk> <t>-> invalid | <sk32>        (keypair_xonly_tweak_add)
 *   pubkey_tweak <sk> <t>      -> invalid | <compressed33> (ec_pubkey_tweak_add on sk·G)
 *   xonly_tweak_secret <sk> <t>-> invalid | <x32> <parity> (xonly_pubkey_tweak_add on sk·G)
 *   xonly_tweak <x> <t>        -> invalid | <x32> <parity> (xonly_pubkey_tweak_add)
 *   sign <sk> <aux32> <msg>    -> <sig64>                 (schnorrsig_sign_custom)
 *   verify <sig> <x> <msg>     -> valid | invalid         (schnorrsig_verify)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "secp256k1.h"
#include "secp256k1_extrakeys.h"
#include "secp256k1_schnorrsig.h"

#define MAX_BYTES 4096

static int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

/* Decodes a hex token into out; returns the byte count or -1. */
static int decode(const char *hex, unsigned char *out, size_t capacity) {
    if (hex == NULL) return -1;
    if (strcmp(hex, "-") == 0) return 0;
    size_t length = strlen(hex);
    if (length % 2 != 0 || length / 2 > capacity) return -1;
    for (size_t i = 0; i < length / 2; i++) {
        int a = nibble(hex[2 * i]), b = nibble(hex[2 * i + 1]);
        if (a < 0 || b < 0) return -1;
        out[i] = (unsigned char)((a << 4) | b);
    }
    return (int)(length / 2);
}

/* A token that must decode to exactly `expected` bytes. */
static void decode_exact(const char *hex, unsigned char *out, int expected, int failure) {
    if (decode(hex, out, (size_t)expected) != expected) exit(failure);
}

static void print_hex(const unsigned char *bytes, size_t length) {
    for (size_t i = 0; i < length; i++) printf("%02x", bytes[i]);
}

static void print_compressed(const secp256k1_context *ctx, const secp256k1_pubkey *pubkey) {
    unsigned char out[33];
    size_t length = sizeof(out);
    if (!secp256k1_ec_pubkey_serialize(ctx, out, &length, pubkey, SECP256K1_EC_COMPRESSED) || length != 33) exit(10);
    print_hex(out, 33);
}

static void print_xonly(const secp256k1_context *ctx, const secp256k1_pubkey *pubkey) {
    secp256k1_xonly_pubkey xonly;
    unsigned char out[32];
    int parity;
    if (!secp256k1_xonly_pubkey_from_pubkey(ctx, &xonly, &parity, pubkey)) exit(11);
    if (!secp256k1_xonly_pubkey_serialize(ctx, out, &xonly)) exit(12);
    print_hex(out, 32);
    printf(" %d", parity);
}

int main(void) {
    static char line[3 * 2 * MAX_BYTES + 64];
    static unsigned char first[MAX_BYTES], second[MAX_BYTES], third[MAX_BYTES];
    secp256k1_context *ctx = secp256k1_context_create(SECP256K1_CONTEXT_NONE);
    if (ctx == NULL) return 1;
    while (fgets(line, sizeof(line), stdin)) {
        size_t length = strlen(line);
        if (length == 0 || line[length - 1] != '\n') return 2;
        line[length - 1] = '\0';
        char *op = strtok(line, " ");
        char *a1 = strtok(NULL, " ");
        char *a2 = strtok(NULL, " ");
        char *a3 = strtok(NULL, " ");
        if (op == NULL || strtok(NULL, " ") != NULL) return 3;

        if (strcmp(op, "seckey") == 0) {
            decode_exact(a1, first, 32, 20);
            if (!secp256k1_ec_seckey_verify(ctx, first)) { puts("invalid"); continue; }
            secp256k1_pubkey pubkey;
            if (!secp256k1_ec_pubkey_create(ctx, &pubkey, first)) return 21;
            print_compressed(ctx, &pubkey);
            putchar(' ');
            print_xonly(ctx, &pubkey);
            putchar('\n');
        } else if (strcmp(op, "pubkey") == 0) {
            int count = decode(a1, first, sizeof(first));
            if (count < 0) return 22;
            secp256k1_pubkey pubkey;
            if (!secp256k1_ec_pubkey_parse(ctx, &pubkey, first, (size_t)count)) { puts("invalid"); continue; }
            print_compressed(ctx, &pubkey);
            putchar('\n');
        } else if (strcmp(op, "seckey_tweak") == 0) {
            decode_exact(a1, first, 32, 23);
            decode_exact(a2, second, 32, 23);
            if (!secp256k1_ec_seckey_tweak_add(ctx, first, second)) { puts("invalid"); continue; }
            print_hex(first, 32);
            putchar('\n');
        } else if (strcmp(op, "xonly_seckey_tweak") == 0) {
            decode_exact(a1, first, 32, 24);
            decode_exact(a2, second, 32, 24);
            secp256k1_keypair keypair;
            if (!secp256k1_keypair_create(ctx, &keypair, first)) return 25;
            if (!secp256k1_keypair_xonly_tweak_add(ctx, &keypair, second)) { puts("invalid"); continue; }
            unsigned char tweaked[32];
            if (!secp256k1_keypair_sec(ctx, tweaked, &keypair)) return 26;
            print_hex(tweaked, 32);
            putchar('\n');
        } else if (strcmp(op, "pubkey_tweak") == 0) {
            decode_exact(a1, first, 32, 27);
            decode_exact(a2, second, 32, 27);
            secp256k1_pubkey pubkey;
            if (!secp256k1_ec_pubkey_create(ctx, &pubkey, first)) return 28;
            if (!secp256k1_ec_pubkey_tweak_add(ctx, &pubkey, second)) { puts("invalid"); continue; }
            print_compressed(ctx, &pubkey);
            putchar('\n');
        } else if (strcmp(op, "xonly_tweak_secret") == 0) {
            decode_exact(a1, first, 32, 29);
            decode_exact(a2, second, 32, 29);
            secp256k1_keypair keypair;
            secp256k1_xonly_pubkey internal;
            secp256k1_pubkey output;
            if (!secp256k1_keypair_create(ctx, &keypair, first)) return 30;
            if (!secp256k1_keypair_xonly_pub(ctx, &internal, NULL, &keypair)) return 31;
            if (!secp256k1_xonly_pubkey_tweak_add(ctx, &output, &internal, second)) { puts("invalid"); continue; }
            print_xonly(ctx, &output);
            putchar('\n');
        } else if (strcmp(op, "xonly_tweak") == 0) {
            decode_exact(a1, first, 32, 32);
            decode_exact(a2, second, 32, 32);
            secp256k1_xonly_pubkey internal;
            secp256k1_pubkey output;
            if (!secp256k1_xonly_pubkey_parse(ctx, &internal, first)) { puts("invalid"); continue; }
            if (!secp256k1_xonly_pubkey_tweak_add(ctx, &output, &internal, second)) { puts("invalid"); continue; }
            print_xonly(ctx, &output);
            putchar('\n');
        } else if (strcmp(op, "sign") == 0) {
            decode_exact(a1, first, 32, 33);
            decode_exact(a2, second, 32, 33);
            int count = decode(a3, third, sizeof(third));
            if (count < 0) return 33;
            secp256k1_keypair keypair;
            if (!secp256k1_keypair_create(ctx, &keypair, first)) return 34;
            secp256k1_schnorrsig_extraparams extra = SECP256K1_SCHNORRSIG_EXTRAPARAMS_INIT;
            extra.ndata = second;
            unsigned char signature[64];
            if (!secp256k1_schnorrsig_sign_custom(ctx, signature, third, (size_t)count, &keypair, &extra)) return 35;
            print_hex(signature, 64);
            putchar('\n');
        } else if (strcmp(op, "verify") == 0) {
            int signature_count = decode(a1, first, sizeof(first));
            int key_count = decode(a2, second, sizeof(second));
            int message_count = decode(a3, third, sizeof(third));
            if (signature_count < 0 || key_count < 0 || message_count < 0) return 36;
            /* BIP340 fixes the signature at 64 bytes and the key at 32; the
             * library's parsers take exactly those sizes. */
            if (signature_count != 64 || key_count != 32) { puts("invalid"); continue; }
            secp256k1_xonly_pubkey pubkey;
            if (!secp256k1_xonly_pubkey_parse(ctx, &pubkey, second)) { puts("invalid"); continue; }
            puts(secp256k1_schnorrsig_verify(ctx, first, third, (size_t)message_count, &pubkey) ? "valid" : "invalid");
        } else {
            return 4;
        }
    }
    secp256k1_context_destroy(ctx);
    return ferror(stdin) ? 7 : 0;
}
