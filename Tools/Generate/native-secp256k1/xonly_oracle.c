/* Public-input differential oracle, not part of the Swift product. */
#include <stdio.h>
#include <string.h>
#include "secp256k1.h"
#include "secp256k1_extrakeys.h"

static int nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

int main(void) {
    char line[128];
    while (fgets(line, sizeof(line), stdin)) {
        if (strlen(line) != 65 || line[64] != '\n') return 2;
        unsigned char compressed[33] = {2}, serialized[65];
        for (int i = 0; i < 32; i++) {
            int a = nibble(line[2*i]), b = nibble(line[2*i+1]);
            if (a < 0 || b < 0) return 3;
            compressed[i+1] = (unsigned char)((a << 4) | b);
        }
        secp256k1_xonly_pubkey xonly;
        secp256k1_pubkey full;
        int a = secp256k1_xonly_pubkey_parse(secp256k1_context_static, &xonly, compressed + 1);
        int b = secp256k1_ec_pubkey_parse(secp256k1_context_static, &full, compressed, sizeof(compressed));
        if (a != b) return 4;
        if (!a) { puts("invalid"); continue; }
        size_t length = sizeof(serialized);
        if (!secp256k1_ec_pubkey_serialize(secp256k1_context_static, serialized, &length, &full, SECP256K1_EC_UNCOMPRESSED)) return 5;
        if (length != 65 || serialized[0] != 4 || (serialized[64] & 1)) return 6;
        for (int i = 33; i < 65; i++) printf("%02x", serialized[i]);
        putchar('\n');
    }
    return ferror(stdin) ? 7 : 0;
}
