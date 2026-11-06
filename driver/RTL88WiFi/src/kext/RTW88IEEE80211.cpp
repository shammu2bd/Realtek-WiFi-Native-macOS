/* Modified by X1REN41L on 2026-10-14 for RTL88WiFi 1.0.1; see the repository NOTICE.md. */
/* Modified on 2026-10-23 for RTL88WiFi 1.0.2 (AWDL radio policy, mesh join selection); see NOTICE.md. */
// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
// RTW88IEEE80211.cpp — 802.11 state machine

#include "RTW88IEEE80211.hpp"
#include "RTW88AWDLProtocol.hpp"
#include "RTW88MgmtValidation.hpp"
#include "RTW88PCIDevice.hpp"
#include "RTW88UserClient.hpp"

#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <sys/mbuf.h>
#include <string.h>
#include <sys/random.h>
#include <kern/clock.h>
#include <mach/mach_time.h>

/* Debug stage checkpoint — logs message only (no sleep). */
#define RTW88_STAGE(fmt, ...) IOLog("rtw88: ---- STAGE: " fmt " ----\n", ##__VA_ARGS__)

/* Chain-safe packet mbuf builder (defined below). */
static mbuf_t rtw88_make_packet_mbuf(const void *src, uint32_t len);

extern "C" {
#include "../compat/rtw88_compat.h"

/* Linux driver public API */
int  rtw_core_init(struct rtw_dev *rtwdev);
void rtw_core_deinit(struct rtw_dev *rtwdev);
int  rtw_core_start(struct rtw_dev *rtwdev);
void rtw_core_stop(struct rtw_dev *rtwdev);
void rtw_tx(struct rtw_dev *rtwdev, struct ieee80211_tx_control *control,
            struct sk_buff *skb);

/* PCI probe shim declared in pci.c */
int  rtw_pci_probe(struct pci_dev *pdev, const struct pci_device_id *id);
void rtw_pci_remove(struct pci_dev *pdev);
int  rtw_regd_set_country(struct rtw_dev *rtwdev, const char alpha2[2]);

/* Exported from the compat layer for hooking */
void rtw88_set_hw_callbacks(struct rtw88_hw_callbacks *cbs, void *kext_hw);

/* chip hw_spec structs — driver_data for rtw_pci_probe */
extern const struct rtw_chip_info rtw8822b_hw_spec;
extern const struct rtw_chip_info rtw8822c_hw_spec;
extern const struct rtw_chip_info rtw8821c_hw_spec;

} /* extern "C" */

/* Completion tokens are allocated with the compat slab allocator and must be
 * released with its matching kfree() wrapper. */
static void rtw88_release_skb_tx_completion_token(void *token)
{
    kfree(token);
}

#define IOLog rtw88_candidate_log

/* ------------------------------------------------------------------ */
/*  WPA2 cryptographic functions (SHA1, HMAC-SHA1, PBKDF2, PRF)      */
/* ------------------------------------------------------------------ */

typedef struct {
    uint32_t state[5];
    uint32_t count[2];
    uint8_t buffer[64];
} KERN_SHA1_CTX;

#define rol(value, bits) (((value) << (bits)) | ((value) >> (32 - (bits))))

#define blk0(i) (block->l[i] = (rol(block->l[i], 24) & 0xFF00FF00) | (rol(block->l[i], 8) & 0x00FF00FF))
#define blk(i) (block->l[i & 15] = rol(block->l[(i + 13) & 15] ^ block->l[(i + 8) & 15] ^ block->l[(i + 2) & 15] ^ block->l[i & 15], 1))

#define r0(v,w,x,y,z,i) z += ((w & (x ^ y)) ^ y) + blk0(i) + 0x5A827999 + rol(v, 5); w = rol(w, 30);
#define r1(v,w,x,y,z,i) z += ((w & (x ^ y)) ^ y) + blk(i) + 0x5A827999 + rol(v, 5); w = rol(w, 30);
#define r2(v,w,x,y,z,i) z += (w ^ x ^ y) + blk(i) + 0x6ED9EBA1 + rol(v, 5); w = rol(w, 30);
#define r3(v,w,x,y,z,i) z += (((w | x) & y) | (w & x)) + blk(i) + 0x8F1BBCDC + rol(v, 5); w = rol(w, 30);
#define r4(v,w,x,y,z,i) z += (w ^ x ^ y) + blk(i) + 0xCA62C1D6 + rol(v, 5); w = rol(w, 30);

static void kern_sha1_transform(uint32_t state[5], const uint8_t buffer[64]) {
    uint32_t a, b, c, d, e;
    typedef union {
        uint8_t c[64];
        uint32_t l[16];
    } CHAR64LONG16;
    CHAR64LONG16 block[1];
    memcpy(block, buffer, 64);
    a = state[0]; b = state[1]; c = state[2]; d = state[3]; e = state[4];
    r0(a,b,c,d,e,0);  r0(e,a,b,c,d,1);  r0(d,e,a,b,c,2);  r0(c,d,e,a,b,3);
    r0(b,c,d,e,a,4);  r0(a,b,c,d,e,5);  r0(e,a,b,c,d,6);  r0(d,e,a,b,c,7);
    r0(c,d,e,a,b,8);  r0(b,c,d,e,a,9);  r0(a,b,c,d,e,10); r0(e,a,b,c,d,11);
    r0(d,e,a,b,c,12); r0(c,d,e,a,b,13); r0(b,c,d,e,a,14); r0(a,b,c,d,e,15);
    r1(e,a,b,c,d,16); r1(d,e,a,b,c,17); r1(c,d,e,a,b,18); r1(b,c,d,e,a,19);
    r2(a,b,c,d,e,20); r2(e,a,b,c,d,21); r2(d,e,a,b,c,22); r2(c,d,e,a,b,23);
    r2(b,c,d,e,a,24); r2(a,b,c,d,e,25); r2(e,a,b,c,d,26); r2(d,e,a,b,c,27);
    r2(c,d,e,a,b,28); r2(b,c,d,e,a,29); r2(a,b,c,d,e,30); r2(e,a,b,c,d,31);
    r2(d,e,a,b,c,32); r2(c,d,e,a,b,33); r2(b,c,d,e,a,34); r2(a,b,c,d,e,35);
    r2(e,a,b,c,d,36); r2(d,e,a,b,c,37); r2(c,d,e,a,b,38); r2(b,c,d,e,a,39);
    r3(a,b,c,d,e,40); r3(e,a,b,c,d,41); r3(d,e,a,b,c,42); r3(c,d,e,a,b,43);
    r3(b,c,d,e,a,44); r3(a,b,c,d,e,45); r3(e,a,b,c,d,46); r3(d,e,a,b,c,47);
    r3(c,d,e,a,b,48); r3(b,c,d,e,a,49); r3(a,b,c,d,e,50); r3(e,a,b,c,d,51);
    r3(d,e,a,b,c,52); r3(c,d,e,a,b,53); r3(b,c,d,e,a,54); r3(a,b,c,d,e,55);
    r3(e,a,b,c,d,56); r3(d,e,a,b,c,57); r3(c,d,e,a,b,58); r3(b,c,d,e,a,59);
    r4(a,b,c,d,e,60); r4(e,a,b,c,d,61); r4(d,e,a,b,c,62); r4(c,d,e,a,b,63);
    r4(b,c,d,e,a,64); r4(a,b,c,d,e,65); r4(e,a,b,c,d,66); r4(d,e,a,b,c,67);
    r4(c,d,e,a,b,68); r4(b,c,d,e,a,69); r4(a,b,c,d,e,70); r4(e,a,b,c,d,71);
    r4(d,e,a,b,c,72); r4(c,d,e,a,b,73); r4(b,c,d,e,a,74); r4(a,b,c,d,e,75);
    r4(e,a,b,c,d,76); r4(d,e,a,b,c,77); r4(c,d,e,a,b,78); r4(b,c,d,e,a,79);
    state[0] += a; state[1] += b; state[2] += c; state[3] += d; state[4] += e;
}

static void kern_sha1_init(KERN_SHA1_CTX *context) {
    context->state[0] = 0x67452301;
    context->state[1] = 0xEFCDAB89;
    context->state[2] = 0x98BADCFE;
    context->state[3] = 0x10325476;
    context->state[4] = 0xC3D2E1F0;
    context->count[0] = context->count[1] = 0;
}

static void kern_sha1_update(KERN_SHA1_CTX *context, const uint8_t *data, uint32_t len) {
    uint32_t i, j;
    j = context->count[0];
    if ((context->count[0] += len << 3) < j)
        context->count[1]++;
    context->count[1] += (len >> 29);
    j = (j >> 3) & 63;
    if ((j + len) > 63) {
        memcpy(&context->buffer[j], data, (i = 64 - j));
        kern_sha1_transform(context->state, context->buffer);
        for (; i + 63 < len; i += 64) {
            kern_sha1_transform(context->state, &data[i]);
        }
        j = 0;
    } else {
        i = 0;
    }
    memcpy(&context->buffer[j], &data[i], len - i);
}

static void kern_sha1_final(uint8_t digest[20], KERN_SHA1_CTX *context) {
    unsigned char finalcount[8];
    for (int i = 0; i < 8; i++) {
        finalcount[i] = (unsigned char)((context->count[(i >= 4 ? 0 : 1)] >> ((3 - (i & 3)) * 8)) & 255);
    }
    unsigned char c = 0200;
    kern_sha1_update(context, &c, 1);
    while ((context->count[0] & 504) != 448) {
        c = 0;
        kern_sha1_update(context, &c, 1);
    }
    kern_sha1_update(context, finalcount, 8);
    for (int i = 0; i < 20; i++) {
        digest[i] = (uint8_t)((context->state[i >> 2] >> ((3 - (i & 3)) * 8)) & 255);
    }
}

static void kern_hmac_sha1(const uint8_t *key, size_t key_len,
                           const uint8_t *data, size_t data_len,
                           uint8_t mac[20])
{
    KERN_SHA1_CTX ctx;
    uint8_t k_ipad[64] = {};
    uint8_t k_opad[64] = {};
    uint8_t tmp_key[20];

    if (key_len > 64) {
        kern_sha1_init(&ctx);
        kern_sha1_update(&ctx, key, (uint32_t)key_len);
        kern_sha1_final(tmp_key, &ctx);
        key = tmp_key;
        key_len = 20;
    }

    memcpy(k_ipad, key, key_len);
    memcpy(k_opad, key, key_len);

    for (int i = 0; i < 64; i++) {
        k_ipad[i] ^= 0x36;
        k_opad[i] ^= 0x5c;
    }

    kern_sha1_init(&ctx);
    kern_sha1_update(&ctx, k_ipad, 64);
    kern_sha1_update(&ctx, data, (uint32_t)data_len);
    kern_sha1_final(mac, &ctx);

    kern_sha1_init(&ctx);
    kern_sha1_update(&ctx, k_opad, 64);
    kern_sha1_update(&ctx, mac, 20);
    kern_sha1_final(mac, &ctx);
}

static void derivePMK(const uint8_t *passphrase, const uint8_t *ssid, size_t ssid_len, uint8_t pmk[32])
{
    size_t pass_len = strlen((const char *)passphrase);
    uint8_t salt[128];
    if (ssid_len > 120) ssid_len = 120;
    memcpy(salt, ssid, ssid_len);

    for (int block = 1; block <= 2; block++) {
        salt[ssid_len]     = (uint8_t)((block >> 24) & 0xff);
        salt[ssid_len + 1] = (uint8_t)((block >> 16) & 0xff);
        salt[ssid_len + 2] = (uint8_t)((block >> 8) & 0xff);
        salt[ssid_len + 3] = (uint8_t)(block & 0xff);

        uint8_t u[20];
        uint8_t t[20];
        kern_hmac_sha1(passphrase, pass_len, salt, ssid_len + 4, u);
        memcpy(t, u, 20);

        for (int iter = 1; iter < 4096; iter++) {
            kern_hmac_sha1(passphrase, pass_len, u, 20, u);
            for (int i = 0; i < 20; i++) {
                t[i] ^= u[i];
            }
        }

        if (block == 1) {
            memcpy(pmk, t, 20);
        } else {
            memcpy(pmk + 20, t, 12);
        }
    }
}

static void derivePTK(const uint8_t pmk[32], const uint8_t anonce[32], const uint8_t snonce[32],
                      const uint8_t spa[6], const uint8_t aa[6], uint8_t ptk[64])
{
    uint8_t min_mac[6], max_mac[6];
    if (memcmp(spa, aa, 6) < 0) {
        memcpy(min_mac, spa, 6);
        memcpy(max_mac, aa, 6);
    } else {
        memcpy(min_mac, aa, 6);
        memcpy(max_mac, spa, 6);
    }

    uint8_t min_nonce[32], max_nonce[32];
    if (memcmp(snonce, anonce, 32) < 0) {
        memcpy(min_nonce, snonce, 32);
        memcpy(max_nonce, anonce, 32);
    } else {
        memcpy(min_nonce, anonce, 32);
        memcpy(max_nonce, snonce, 32);
    }

    uint8_t data[100];
    const char *label = "Pairwise key expansion";
    memcpy(data, label, 22);
    data[22] = 0;
    memcpy(data + 23, min_mac, 6);
    memcpy(data + 29, max_mac, 6);
    memcpy(data + 35, min_nonce, 32);
    memcpy(data + 67, max_nonce, 32);
    size_t data_len = 23 + 6 + 6 + 32 + 32;

    uint8_t hash[20];
    for (int i = 0; i < 4; i++) {
        data[data_len] = (uint8_t)i;
        kern_hmac_sha1(pmk, 32, data, data_len + 1, hash);
        if (i < 3) {
            memcpy(ptk + i * 20, hash, 20);
        } else {
            memcpy(ptk + i * 20, hash, 4);
        }
    }
}

static const uint8_t aes_sbox[256] = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};

static const uint8_t aes_rsbox[256] = {
    0x52,0x09,0x6a,0xd5,0x30,0x36,0xa5,0x38,0xbf,0x40,0xa3,0x9e,0x81,0xf3,0xd7,0xfb,
    0x7c,0xe3,0x39,0x82,0x9b,0x2f,0xff,0x87,0x34,0x8e,0x43,0x44,0xc4,0xde,0xe9,0xcb,
    0x54,0x7b,0x94,0x32,0xa6,0xc2,0x23,0x3d,0xee,0x4c,0x95,0x0b,0x42,0xfa,0xc3,0x4e,
    0x08,0x2e,0xa1,0x66,0x28,0xd9,0x24,0xb2,0x76,0x5b,0xa2,0x49,0x6d,0x8b,0xd1,0x25,
    0x72,0xf8,0xf6,0x64,0x86,0x68,0x98,0x16,0xd4,0xa4,0x5c,0xcc,0x5d,0x65,0xb6,0x92,
    0x6c,0x70,0x48,0x50,0xfd,0xed,0xb9,0xda,0x5e,0x15,0x46,0x57,0xa7,0x8d,0x9d,0x84,
    0x90,0xd8,0xab,0x00,0x8c,0xbc,0xd3,0x0a,0xf7,0xe4,0x58,0x05,0xb8,0xb3,0x45,0x06,
    0xd0,0x2c,0x1e,0x8f,0xca,0x3f,0x0f,0x02,0xc1,0xaf,0xbd,0x03,0x01,0x13,0x8a,0x6b,
    0x3a,0x91,0x11,0x41,0x4f,0x67,0xdc,0xea,0x97,0xf2,0xcf,0xce,0xf0,0xb4,0xe6,0x73,
    0x96,0xac,0x74,0x22,0xe7,0xad,0x35,0x85,0xe2,0xf9,0x37,0xe8,0x1c,0x75,0xdf,0x6e,
    0x47,0xf1,0x1a,0x71,0x1d,0x29,0xc5,0x89,0x6f,0xb7,0x62,0x0e,0xaa,0x18,0xbe,0x1b,
    0xfc,0x56,0x3e,0x4b,0xc6,0xd2,0x79,0x20,0x9a,0xdb,0xc0,0xfe,0x78,0xcd,0x5a,0xf4,
    0x1f,0xdd,0xa8,0x33,0x88,0x07,0xc7,0x31,0xb1,0x12,0x10,0x59,0x27,0x80,0xec,0x5f,
    0x60,0x51,0x7f,0xa9,0x19,0xb5,0x4a,0x0d,0x2d,0xe5,0x7a,0x9f,0x93,0xc9,0x9c,0xef,
    0xa0,0xe0,0x3b,0x4d,0xae,0x2a,0xf5,0xb0,0xc8,0xeb,0xbb,0x3c,0x83,0x53,0x99,0x61,
    0x17,0x2b,0x04,0x7e,0xba,0x77,0xd6,0x26,0xe1,0x69,0x14,0x63,0x55,0x21,0x0c,0x7d
};

static uint8_t aes_xtime(uint8_t x)
{
    return (uint8_t)((x << 1) ^ ((x & 0x80) ? 0x1b : 0));
}

static uint8_t aes_mul(uint8_t x, uint8_t y)
{
    uint8_t r = 0;
    while (y) {
        if (y & 1) r ^= x;
        x = aes_xtime(x);
        y >>= 1;
    }
    return r;
}

static void aes128_key_expand(const uint8_t key[16], uint8_t round_key[176])
{
    static const uint8_t rcon[10] = {0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36};
    memcpy(round_key, key, 16);
    for (int bytes = 16, r = 0; bytes < 176; bytes += 4) {
        uint8_t t[4];
        memcpy(t, round_key + bytes - 4, 4);
        if ((bytes & 15) == 0) {
            uint8_t tmp = t[0];
            t[0] = aes_sbox[t[1]] ^ rcon[r++];
            t[1] = aes_sbox[t[2]];
            t[2] = aes_sbox[t[3]];
            t[3] = aes_sbox[tmp];
        }
        for (int i = 0; i < 4; i++)
            round_key[bytes + i] = round_key[bytes - 16 + i] ^ t[i];
    }
}

static void aes_add_round_key(uint8_t state[16], const uint8_t *rk)
{
    for (int i = 0; i < 16; i++) state[i] ^= rk[i];
}

static void aes_inv_shift_rows(uint8_t s[16])
{
    uint8_t t;
    t = s[13]; s[13] = s[9]; s[9] = s[5]; s[5] = s[1]; s[1] = t;
    t = s[2]; s[2] = s[10]; s[10] = t; t = s[6]; s[6] = s[14]; s[14] = t;
    t = s[3]; s[3] = s[7]; s[7] = s[11]; s[11] = s[15]; s[15] = t;
}

static void aes_inv_sub_bytes(uint8_t s[16])
{
    for (int i = 0; i < 16; i++) s[i] = aes_rsbox[s[i]];
}

static void aes_inv_mix_columns(uint8_t s[16])
{
    for (int c = 0; c < 4; c++) {
        uint8_t *p = s + c * 4;
        uint8_t a0 = p[0], a1 = p[1], a2 = p[2], a3 = p[3];
        p[0] = aes_mul(a0, 0x0e) ^ aes_mul(a1, 0x0b) ^ aes_mul(a2, 0x0d) ^ aes_mul(a3, 0x09);
        p[1] = aes_mul(a0, 0x09) ^ aes_mul(a1, 0x0e) ^ aes_mul(a2, 0x0b) ^ aes_mul(a3, 0x0d);
        p[2] = aes_mul(a0, 0x0d) ^ aes_mul(a1, 0x09) ^ aes_mul(a2, 0x0e) ^ aes_mul(a3, 0x0b);
        p[3] = aes_mul(a0, 0x0b) ^ aes_mul(a1, 0x0d) ^ aes_mul(a2, 0x09) ^ aes_mul(a3, 0x0e);
    }
}

static void aes128_decrypt_block(const uint8_t key[16], const uint8_t in[16], uint8_t out[16])
{
    uint8_t rk[176];
    uint8_t s[16];
    aes128_key_expand(key, rk);
    memcpy(s, in, 16);
    aes_add_round_key(s, rk + 160);
    for (int round = 9; round >= 1; round--) {
        aes_inv_shift_rows(s);
        aes_inv_sub_bytes(s);
        aes_add_round_key(s, rk + round * 16);
        aes_inv_mix_columns(s);
    }
    aes_inv_shift_rows(s);
    aes_inv_sub_bytes(s);
    aes_add_round_key(s, rk);
    memcpy(out, s, 16);
}

static bool aes_unwrap_128(const uint8_t kek[16], const uint8_t *in,
                           uint16_t in_len, uint8_t *out, uint16_t *out_len)
{
    if (in_len < 16 || (in_len & 7))
        return false;

    uint8_t a[8];
    uint8_t r[32][8];
    int n = in_len / 8 - 1;
    if (n <= 0 || n > 32)
        return false;

    memcpy(a, in, 8);
    for (int i = 0; i < n; i++)
        memcpy(r[i], in + 8 + i * 8, 8);

    for (int j = 5; j >= 0; j--) {
        for (int i = n - 1; i >= 0; i--) {
            uint8_t block[16], plain[16];
            uint64_t t = (uint64_t)(n * j + i + 1);
            memcpy(block, a, 8);
            for (int k = 7; k >= 0 && t; k--, t >>= 8)
                block[k] ^= (uint8_t)(t & 0xff);
            memcpy(block + 8, r[i], 8);
            aes128_decrypt_block(kek, block, plain);
            memcpy(a, plain, 8);
            memcpy(r[i], plain + 8, 8);
        }
    }

    static const uint8_t iv[8] = {0xa6,0xa6,0xa6,0xa6,0xa6,0xa6,0xa6,0xa6};
    if (memcmp(a, iv, 8) != 0)
        return false;

    for (int i = 0; i < n; i++)
        memcpy(out + i * 8, r[i], 8);
    *out_len = (uint16_t)(n * 8);
    return true;
}

static bool eapol_mic_ok(const uint8_t kck[16], const uint8_t *eapol,
                         uint32_t eapol_len)
{
    if (eapol_len < 99)
        return false;

    uint8_t *tmp = (uint8_t *)IOMalloc(eapol_len);
    if (!tmp)
        return false;

    memcpy(tmp, eapol, eapol_len);
    uint8_t rx_mic[16];
    memcpy(rx_mic, tmp + 81, sizeof(rx_mic));
    memset(tmp + 81, 0, sizeof(rx_mic));

    uint8_t mic[20];
    kern_hmac_sha1(kck, 16, tmp, eapol_len, mic);
    IOFree(tmp, eapol_len);
    return memcmp(rx_mic, mic, sizeof(rx_mic)) == 0;
}

static bool extract_gtk_from_kde(const uint8_t *key_data, uint16_t key_data_len,
                                 uint8_t gtk[32], uint8_t *gtk_len,
                                 uint8_t *gtk_idx)
{
    const uint8_t rsn_gtk_oui[4] = {0x00, 0x0f, 0xac, 0x01};

    for (uint16_t pos = 0; pos + 2 <= key_data_len; ) {
        uint8_t id = key_data[pos];
        uint8_t len = key_data[pos + 1];
        const uint8_t *body = key_data + pos + 2;
        if (pos + 2 + len > key_data_len)
            break;

        if (id == 0xdd && len >= 6 && memcmp(body, rsn_gtk_oui, 4) == 0) {
            uint8_t key_len = (uint8_t)(len - 6);
            if (key_len > 32)
                return false;
            *gtk_idx = body[4] & 0x3;
            *gtk_len = key_len;
            memcpy(gtk, body + 6, key_len);
            return true;
        }
        pos += 2 + len;
    }

    return false;
}

#undef rol
#undef blk0
#undef blk
#undef r0
#undef r1
#undef r2
#undef r3
#undef r4

/* PCI device-ID → chip_info lookup (PCIe chips only) */
struct rtw88_pci_id_entry {
    uint16_t device;
    const struct rtw_chip_info *chip;
};

static const struct rtw88_pci_id_entry rtw88_pci_chip_table[] = {
    { 0xB822, &rtw8822b_hw_spec },  /* RTL8822BE */
    { 0xC822, &rtw8822c_hw_spec },  /* RTL8822CE */
    { 0xC82F, &rtw8822c_hw_spec },  /* RTL8822CE variant */
    { 0xC821, &rtw8821c_hw_spec },  /* RTL8821CE */
    { 0xB821, &rtw8821c_hw_spec },  /* RTL8821CE variant */
    { 0, nullptr }
};

/* Forward declaration of hw_callbacks struct from compat.c */
struct rtw88_hw_callbacks {
    void (*rx_frame)(void *kext_hw, struct sk_buff *skb);
    void (*tx_status)(void *kext_hw, struct sk_buff *skb);
    void (*scan_done)(void *kext_hw, bool aborted);
};

#define super OSObject
OSDefineMetaClassAndStructors(RTW88IEEE80211, OSObject)

/* ------------------------------------------------------------------ */
/*  Static compat callbacks                                             */
/* ------------------------------------------------------------------ */

void RTW88IEEE80211::compat_rx_frame(void *kext_hw, struct sk_buff *skb)
{
    RTW88IEEE80211 *self = (RTW88IEEE80211 *)kext_hw;
    if (self) self->rxFrame(skb);
}

void RTW88IEEE80211::compat_tx_status(void *kext_hw, struct sk_buff *skb)
{
    RTW88IEEE80211 *self = (RTW88IEEE80211 *)kext_hw;
    if (self) self->txStatus(skb);
    kfree_skb(skb);
}

void RTW88IEEE80211::compat_scan_done(void *kext_hw, bool aborted)
{
    RTW88IEEE80211 *self = (RTW88IEEE80211 *)kext_hw;
    if (self) self->scanDone(aborted);
}

/* ------------------------------------------------------------------ */
/*  Factory / init / free                                               */
/* ------------------------------------------------------------------ */

RTW88IEEE80211 *RTW88IEEE80211::create(RTW88PCIDevice *dev, struct pci_dev *pci)
{
    RTW88IEEE80211 *obj = new RTW88IEEE80211;
    if (obj && !obj->init(dev, pci)) {
        obj->release();
        return nullptr;
    }
    return obj;
}

RTW88IEEE80211 *RTW88IEEE80211::createAirport(RTW88RxDelegate *delegate, struct pci_dev *pci)
{
    RTW88IEEE80211 *obj = new RTW88IEEE80211;
    if (obj && !obj->init(delegate, pci)) {
        obj->release();
        return nullptr;
    }
    return obj;
}

bool RTW88IEEE80211::init(RTW88RxDelegate *delegate, struct pci_dev *pci)
{
    if (!super::init()) return false;
    _parent = delegate;
    _pcidev = pci;
    _lock    = IOLockAlloc();
    _bssLock = IOLockAlloc();
    if (!_lock || !_bssLock) return false;
    _joinFail.clear();
    _joinTried.clear();
    _baRecovery.reset();
    _connectTC = thread_call_allocate((thread_call_func_t)RTW88IEEE80211::connectTCFn,
                                       (thread_call_param_t)this);
    _manualScanTC = thread_call_allocate((thread_call_func_t)RTW88IEEE80211::manualScanTCFn,
                                         (thread_call_param_t)this);
    if (!_connectTC || !_manualScanTC) return false;
    /* Install callbacks into compat layer */
    static struct rtw88_hw_callbacks cbs = {
        .rx_frame  = RTW88IEEE80211::compat_rx_frame,
        .tx_status = RTW88IEEE80211::compat_tx_status,
        .scan_done = RTW88IEEE80211::compat_scan_done,
    };
    rtw88_set_hw_callbacks(&cbs, this);
    /* Set up workloop / timer for state machine */
    _wl = IOWorkLoop::workLoop();
    if (!_wl) return false;
    _gate = IOCommandGate::commandGate(this);
    if (!_gate) return false;
    if (_wl->addEventSource(_gate) != kIOReturnSuccess) return false;
    _timer = IOTimerEventSource::timerEventSource(this,
        &RTW88IEEE80211::timerFired);
    if (!_timer) return false;
    if (_wl->addEventSource(_timer) != kIOReturnSuccess) return false;
    /* RX A-MPDU reorder: lock + hole-flush timer.  The timer lives on the
     * RX/interrupt workloop (not _wl) so reorder-released frames and normal RX
     * frames are delivered from the same thread — injectRxFrame's queue+
     * flush is not safe against concurrent callers. */
    _rxBaLock = IOLockAlloc();
    if (!_rxBaLock) return false;
    IOWorkLoop *rxwl = _parent ? _parent->getRxWorkLoop() : nullptr;
    if (!rxwl) return false;
    _reorderTimer = IOTimerEventSource::timerEventSource(this,
        &RTW88IEEE80211::reorderTimerFired);
    if (!_reorderTimer) return false;
    if (rxwl->addEventSource(_reorderTimer) != kIOReturnSuccess) return false;
    IOLog("rtw88: RTW88IEEE80211 initialized\n");
    return true;
}

bool RTW88IEEE80211::init(RTW88PCIDevice *dev, struct pci_dev *pci)
{
    if (!super::init()) return false;
    _parent = dev;
    _pcidev = pci;

    _lock    = IOLockAlloc();
    _bssLock = IOLockAlloc();
    if (!_lock || !_bssLock) return false;

    _connectTC = thread_call_allocate((thread_call_func_t)RTW88IEEE80211::connectTCFn,
                                       (thread_call_param_t)this);
    _manualScanTC = thread_call_allocate((thread_call_func_t)RTW88IEEE80211::manualScanTCFn,
                                          (thread_call_param_t)this);
    if (!_connectTC || !_manualScanTC) return false;

    /* Install callbacks into compat layer */
    static struct rtw88_hw_callbacks cbs = {
        .rx_frame  = RTW88IEEE80211::compat_rx_frame,
        .tx_status = RTW88IEEE80211::compat_tx_status,
        .scan_done = RTW88IEEE80211::compat_scan_done,
    };
    rtw88_set_hw_callbacks(&cbs, this);

    /* Set up workloop / timer for state machine */
    _wl = IOWorkLoop::workLoop();
    if (!_wl) return false;

    _gate = IOCommandGate::commandGate(this);
    if (!_gate) return false;
    if (_wl->addEventSource(_gate) != kIOReturnSuccess) return false;

    _timer = IOTimerEventSource::timerEventSource(this,
        &RTW88IEEE80211::timerFired);
    if (!_timer) return false;
    if (_wl->addEventSource(_timer) != kIOReturnSuccess) return false;

    /* RX A-MPDU reorder: lock + hole-flush timer.  The timer lives on the
     * RX/interrupt workloop (not _wl) so reorder-released frames and normal RX
     * frames are delivered from the same thread — injectRxFrame's queue+flush
     * is not safe against concurrent callers. */
    _rxBaLock = IOLockAlloc();
    if (!_rxBaLock) return false;
    IOWorkLoop *rxwl = _parent ? _parent->getRxWorkLoop() : nullptr;
    if (!rxwl) return false;
    _reorderTimer = IOTimerEventSource::timerEventSource(this,
        &RTW88IEEE80211::reorderTimerFired);
    if (!_reorderTimer) return false;
    if (rxwl->addEventSource(_reorderTimer) != kIOReturnSuccess) return false;

    IOLog("rtw88: RTW88IEEE80211 initialized\n");
    return true;
}

void RTW88IEEE80211::free()
{
    _manualScanAbort = true;
    if (_manualScanTC) { thread_call_cancel_wait(_manualScanTC); thread_call_free(_manualScanTC); _manualScanTC = nullptr; }
    if (_connectTC) { thread_call_cancel_wait(_connectTC); thread_call_free(_connectTC); _connectTC = nullptr; }

    /* The compat layer keeps a raw callback context.  Clear it before this
     * object can disappear so a late RX/TX completion cannot call freed memory. */
    rtw88_set_hw_callbacks(nullptr, nullptr);
    clearKeys();
    releaseSta();
    if (_rxBaLock)
        rxBaTeardownAll();
    if (_reorderTimer) {
        IOWorkLoop *rxwl = _parent ? _parent->getRxWorkLoop() : nullptr;
        if (rxwl) rxwl->removeEventSource(_reorderTimer);
        _reorderTimer->release();
        _reorderTimer = nullptr;
    }
    if (_rxBaLock) { IOLockFree(_rxBaLock); _rxBaLock = nullptr; }
    if (_timer)  { if (_wl) _wl->removeEventSource(_timer); _timer->release(); _timer = nullptr; }
    if (_gate)   { if (_wl) _wl->removeEventSource(_gate); _gate->release(); _gate = nullptr; }
    if (_wl)     { _wl->release();   _wl = nullptr; }
    if (_lock)   { IOLockFree(_lock);    _lock = nullptr; }
    if (_bssLock){ IOLockFree(_bssLock); _bssLock = nullptr; }

    /* Free BSS list */
    RTW88BSS *b = _bssList;
    while (b) {
        RTW88BSS *n = b->next;
        IOFree(b, sizeof(*b));
        b = n;
    }
    _bssList = nullptr;
    if (_scanRequest) { IOFree(_scanRequest, sizeof(*_scanRequest)); _scanRequest = nullptr; }
    super::free();
}

RTW88TxStateGate::MutationLease RTW88IEEE80211::beginTxStateMutation()
{
    /* Only passive control/RX workqueue paths may call this helper. The four
     * WMM callbacks never wait: they use tryEnterTransmit() and drop/retry
     * admission while a writer owns the barrier. IOSleep yields the control
     * thread while a short in-flight synchronous RTW88 ops->tx() call drains. */
    for (;;) {
        RTW88TxStateGate::MutationLease mutation =
            _txStateGate.tryBeginMutation();
        if (mutation) {
            while (!mutation.ready())
                IOSleep(1);
            return mutation;
        }
        IOSleep(1);
    }
}

void RTW88IEEE80211::setRadioState(RTW88State state)
{
    auto mutation = beginTxStateMutation();
    __atomic_store_n(&_state, state, __ATOMIC_RELEASE);
    mutation.finish();
}

void RTW88IEEE80211::clearKeys()
{
    /* Close the controlled port before waiting for existing submitters. EAPOL
     * remains available only through the explicit handshake paths below. */
    __atomic_store_n(&_dataTxBlocked, true, __ATOMIC_RELEASE);
    auto mutation = beginTxStateMutation();

    if (_powered && _hw && _hw->ops && _hw->ops->set_key) {
        if (_ptkConf)
            _hw->ops->set_key(_hw, DISABLE_KEY, _vif, _sta, _ptkConf);
        if (_gtkConf)
            _hw->ops->set_key(_hw, DISABLE_KEY, _vif, nullptr, _gtkConf);
    }

    if (_ptkConf) {
        IOFree(_ptkConf, sizeof(*_ptkConf));
        _ptkConf = nullptr;
    }
    if (_gtkConf) {
        IOFree(_gtkConf, sizeof(*_gtkConf));
        _gtkConf = nullptr;
    }
    memset(_pmk, 0, sizeof(_pmk));
    memset(_password, 0, sizeof(_password));
    _pmkProvided = false;
    __atomic_store_n(&_externalPTKInstalled, false, __ATOMIC_RELEASE);
    __atomic_store_n(&_externalGTKInstalled, false, __ATOMIC_RELEASE);
    memset(_ptk, 0, sizeof(_ptk));
    memset(_gtk, 0, sizeof(_gtk));
    /* Never reset the CCMP PN allocator. Reusing a packet number after a key
     * re-install/reassociation is avoidable and unsafe if stale TX survives. */
    _rxCcmpIvSkipLogged = false;
    _snonceValid = false;
    __atomic_store_n(&_m3KeysInstalled, false, __ATOMIC_RELEASE);
    _handshakePending = false;
    memset(_anonce, 0, sizeof(_anonce));
    memset(_snonce, 0, sizeof(_snonce));
    memset(_replayCtr, 0, sizeof(_replayCtr));
    memset(_installedM3ReplayCtr, 0, sizeof(_installedM3ReplayCtr));
    _txBAState.clear();
    __atomic_store_n(&_associatedVisible, false, __ATOMIC_RELEASE);
    if (_lock) IOLockLock(_lock);
    _txBaPending = false;
    _baRecovery.reset();
    if (_lock) IOLockUnlock(_lock);
    mutation.finish();
}

void RTW88IEEE80211::releaseSta()
{
    __atomic_store_n(&_dataTxBlocked, true, __ATOMIC_RELEASE);

    /* rtw88_unregister_sta() drains RX datapath readers and may sleep. Do it
     * before taking the radio TX mutation lease: an RX callback that needs to
     * mutate radio state must not deadlock behind a writer waiting for NAPI. */
    struct ieee80211_sta *registered = _sta;
    const bool quiesced = registered ? rtw88_unregister_sta(registered) : true;

    auto mutation = beginTxStateMutation();
    if (_lock) IOLockLock(_lock);
    _txBaPending = false;
    _baRecovery.reset();
    if (_lock) IOLockUnlock(_lock);
    if (_sta) {
        if (_hw && _hw->ops && _hw->ops->sta_remove && _vif)
            _hw->ops->sta_remove(_hw, _vif, _sta);

        if (quiesced)
            IOFree(_sta, _staAllocSize ? _staAllocSize : sizeof(struct ieee80211_sta));
        _sta = nullptr;
        _staAllocSize = 0;
    }
    _txBAState.clear();
    /* Sequence counters are monotonic for the lifetime of this radio object.
     * They are deliberately not reset on station/key teardown. */
    rxBaTeardownAll();
    mutation.finish();
}

static const char *rtw88CipherName(uint32_t cipher)
{
    switch (cipher) {
    case WLAN_CIPHER_SUITE_CCMP:
        return "CCMP";
    case WLAN_CIPHER_SUITE_TKIP:
        return "TKIP";
    default:
        return "unknown";
    }
}

bool RTW88IEEE80211::installKey(struct ieee80211_key_conf **slot, bool pairwise,
                                uint8_t keyidx, uint32_t cipher,
                                const uint8_t *tk, uint8_t tk_len)
{
    auto mutation = beginTxStateMutation();
    const bool installed = installKeyUnderMutation(
        slot, pairwise, keyidx, cipher, tk, tk_len, &mutation);
    mutation.finish();
    return installed;
}

bool RTW88IEEE80211::installKeyUnderMutation(
    struct ieee80211_key_conf **slot, bool pairwise,
    uint8_t keyidx, uint32_t cipher, const uint8_t *tk, uint8_t tk_len,
    RTW88TxStateGate::MutationLease *mutation)
{
    if (!mutation || !*mutation || !mutation->ready() ||
        !__atomic_load_n(&_powered, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&_stopping, __ATOMIC_ACQUIRE) ||
        !_hw || !_hw->ops || !_hw->ops->set_key ||
        !slot || !tk || tk_len == 0 || tk_len > 32)
        return false;
    if (cipher != WLAN_CIPHER_SUITE_CCMP && cipher != WLAN_CIPHER_SUITE_TKIP)
        return false;
    if (cipher == WLAN_CIPHER_SUITE_CCMP && tk_len != 16)
        return false;
    if (cipher == WLAN_CIPHER_SUITE_TKIP && tk_len != 32)
        return false;

    struct ieee80211_key_conf *oldKey = *slot;
    if (oldKey && oldKey->cipher == cipher && oldKey->keyidx == keyidx &&
        oldKey->keylen == tk_len && memcmp(oldKey->key, tk, tk_len) == 0) {
        IOLog("rtw88: key reuse %s idx=%u; preserving packet numbers\n",
              pairwise ? "PTK" : "GTK", keyidx);
        return true;
    }

    /* Stage and program the candidate before retiring the working key. A
     * failed SET_KEY leaves the previous software/hardware key object intact.
     * The writer lease excludes every WMM submitter during this handoff. */
    struct ieee80211_key_conf *key =
        (struct ieee80211_key_conf *)IOMallocZero(sizeof(*key));
    if (!key)
        return false;

    key->cipher = cipher;
    key->keyidx = (s8)keyidx;
    key->flags = pairwise ? IEEE80211_KEY_FLAG_PAIRWISE : 0;
    key->keylen = tk_len;
    key->iv_len = 8;
    key->icv_len = (cipher == WLAN_CIPHER_SUITE_TKIP) ? 4 : 8;
    memcpy(key->key, tk, tk_len);

    int ret = _hw->ops->set_key(_hw, SET_KEY, _vif,
                                pairwise ? _sta : nullptr, key);
    if (ret) {
        IOLog("rtw88: failed to install %s %s key ret=%d; previous key retained\n",
              pairwise ? "pairwise" : "group", rtw88CipherName(cipher), ret);
        IOFree(key, sizeof(*key));
        return false;
    }

    /* Only disable the old hardware slot when the new key was assigned a
     * distinct slot. DISABLE_KEY on a reused index would disable the new key. */
    if (oldKey &&
        (oldKey->keyidx != key->keyidx ||
         oldKey->hw_key_idx != key->hw_key_idx)) {
        int disableRet = _hw->ops->set_key(
            _hw, DISABLE_KEY, _vif, pairwise ? _sta : nullptr, oldKey);
        if (disableRet)
            IOLog("rtw88: old %s key slot disable failed ret=%d old_hw_idx=%u new_hw_idx=%u\n",
                  pairwise ? "PTK" : "GTK", disableRet,
                  oldKey->hw_key_idx, key->hw_key_idx);
    }

    *slot = key;
    if (oldKey)
        IOFree(oldKey, sizeof(*oldKey));

    /* CCMP packet numbers are never reset here: this includes rekeys. */
    IOLog("rtw88: installed %s %s key idx=%u hw_idx=%u\n",
          pairwise ? "pairwise" : "group", rtw88CipherName(cipher),
          keyidx, key->hw_key_idx);
    return true;
}

/* ------------------------------------------------------------------ */
/*  start / stop                                                        */
/* ------------------------------------------------------------------ */

IOReturn RTW88IEEE80211::start()
{
    RTW88_STAGE("IEEE80211::start entered");

    /* Look up chip info from PCI device ID */
    const struct rtw_chip_info *chip = nullptr;
    for (int i = 0; rtw88_pci_chip_table[i].device != 0; i++) {
        if (rtw88_pci_chip_table[i].device == _pcidev->device) {
            chip = rtw88_pci_chip_table[i].chip;
            break;
        }
    }
    if (!chip) {
        IOLog("rtw88: unknown PCI device %04x — cannot probe\n", _pcidev->device);
        return kIOReturnUnsupported;
    }
    RTW88_STAGE("chip matched: device=%04x", _pcidev->device);

    const struct pci_device_id fake_id = {
        .vendor      = _pcidev->vendor,
        .device      = _pcidev->device,
        .subvendor   = PCI_ANY_ID,
        .subdevice   = PCI_ANY_ID,
        .driver_data = (unsigned long)chip,
    };

    RTW88_STAGE("calling rtw_pci_probe");
    int ret = rtw_pci_probe(_pcidev, &fake_id);
    RTW88_STAGE("rtw_pci_probe returned %d", ret);
    if (ret != 0) {
        IOLog("rtw88: rtw_pci_probe failed: %d\n", ret);
        return kIOReturnError;
    }

    /* Use the hw pointer that ieee80211_alloc_hw() registered in the compat
     * layer via rtw88_register_hw().  rtw88_get_hw() is the external-linkage
     * accessor for the static g_rtw88_hw variable — avoids both the fragile
     * *(ieee80211_hw **)rtwdev double-dereference and the UB of declaring
     * 'extern' on a static variable from another TU. */
    _hw = rtw88_get_hw();

    /* rtwdev is hw->priv (allocated contiguously after ieee80211_hw in alloc_hw).
     * Note: rtw_pci_probe stores hw (not rtwdev) in pdev->driver_data via pci_set_drvdata(). */
    _rtwdev = _hw ? (struct rtw_dev *)_hw->priv : nullptr;

    RTW88_STAGE("rtwdev=%p hw=%p", (void *)_rtwdev, (void *)_hw);

    if (!_hw || !_rtwdev || !_hw->wiphy || !_hw->ops) {
        IOLog("rtw88: probe returned incomplete hardware state\n");
        goto fail_probe;
    }

    /* Read MAC address — SET_IEEE80211_PERM_ADDR() copies EFuse MAC into
     * hw->wiphy->perm_addr during rtw_register_hw(); read it from there. */
    memcpy(_macAddr, _hw->wiphy->perm_addr, 6);
    memcpy(_permanentMacAddr, _hw->wiphy->perm_addr, 6);
    IOLog("rtw88: MAC address: %02x:%02x:%02x:%02x:%02x:%02x\n",
          _macAddr[0], _macAddr[1], _macAddr[2],
          _macAddr[3], _macAddr[4], _macAddr[5]);

    /* Create virtual interface in the driver.
     * NOTE: _rtwdev must NOT be reassigned here. It has been correctly set from
     * _hw->priv above. */
    RTW88_STAGE("adding STA interface");
    _vifAllocSize = sizeof(struct ieee80211_vif) + (size_t)_hw->vif_data_size;
    _vif = (struct ieee80211_vif *)IOMallocZero(_vifAllocSize);
    if (!_vif) {
        IOLog("rtw88: failed to allocate STA interface\n");
        goto fail_probe;
    }
    _vif->type = NL80211_IFTYPE_STATION;
    memcpy(_vif->addr, _macAddr, 6);
    /* bss_conf.bssid must never be NULL — iterators dereference it
     * for every RX frame even before association. */
    _vif->bss_conf.bssid = _vif->bss_conf.bssid_buf;
    if (!_hw->ops->add_interface) {
        IOLog("rtw88: driver has no add_interface operation\n");
        goto fail_vif;
    }
    if (!_hw->ops->start) {
        IOLog("rtw88: driver has no start operation\n");
        goto fail_vif;
    }
    RTW88_STAGE("calling hw->ops->start");
    ret = _hw->ops->start(_hw);
    RTW88_STAGE("hw->ops->start returned %d", ret);
    if (ret != 0) {
        IOLog("rtw88: hw->ops->start failed: %d\n", ret);
        goto fail_vif;
    }
    {
        auto mutation = beginTxStateMutation();
        __atomic_store_n(&_powered, true, __ATOMIC_RELEASE);
        mutation.finish();
    }

    ret = _hw->ops->add_interface(_hw, _vif);
    if (ret != 0) {
        IOLog("rtw88: add_interface failed: %d\n", ret);
        goto fail_vif;
    }
    rtw88_register_vif(_vif);
    RTW88_STAGE("add_interface done");


    {
        auto mutation = beginTxStateMutation();
        __atomic_store_n(&_state, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        __atomic_store_n(&_associatedVisible, false, __ATOMIC_RELEASE);
        mutation.finish();
    }
    __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
    _scanPartial = false;
    RTW88_STAGE("IEEE80211::start complete — SUCCESS");
    return kIOReturnSuccess;

fail_vif:
    if (_powered && _hw && _hw->ops && _hw->ops->stop) {
        _hw->ops->stop(_hw, false);
        __atomic_store_n(&_powered, false, __ATOMIC_RELEASE);
    }
    if (_vif) {
        IOFree(_vif, _vifAllocSize);
        _vifAllocSize = 0;
        _vif = nullptr;
    }
fail_probe:
    rtw_pci_remove(_pcidev);
    _rtwdev = nullptr;
    _hw = nullptr;
    __atomic_store_n(&_powered, false, __ATOMIC_RELEASE);
    return kIOReturnError;
}

void RTW88IEEE80211::stop()
{
    IOLog("rtw88: IEEE80211 stop\n");
    __atomic_store_n(&_stopping, true, __ATOMIC_RELEASE);
    __atomic_store_n(&_dataTxBlocked, true, __ATOMIC_RELEASE);
    cancelAuthentication();
    _manualScanAbort = true;
    if (_manualScanTC) thread_call_cancel_wait(_manualScanTC);
    if (_connectTC) thread_call_cancel_wait(_connectTC);
    if (_reorderTimer) {
        _reorderTimer->cancelTimeout();
        _reorderTimer->disable();
    }
    if (_timer)
        _timer->cancelTimeout();

    const RTW88State state = __atomic_load_n(&_state, __ATOMIC_ACQUIRE);
    const RTW88State scanReturn =
        __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE);
    if ((state == RTW88_STATE_CONNECTED ||
         (state == RTW88_STATE_SCANNING &&
          scanReturn == RTW88_STATE_CONNECTED)) &&
        __atomic_load_n(&_powered, __ATOMIC_ACQUIRE)) {
        doDisconnect();
    } else {
        clearKeys();
        releaseSta();
    }

    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING &&
        _hw && _hw->ops && _hw->ops->cancel_hw_scan)
        _hw->ops->cancel_hw_scan(_hw, _vif);

    /* powerOff closes admission and sets _powered=false while holding the
     * writer, then calls ops->stop outside it. RTW88 may synchronously drain
     * NAPI/RX workers; those callbacks must be free to acquire the radio gate
     * and observe the powered-off state rather than deadlock behind teardown. */
    powerOff();

    struct ieee80211_hw *hw = nullptr;
    struct ieee80211_vif *vif = nullptr;
    size_t vifSize = 0;
    {
        auto mutation = beginTxStateMutation();
        hw = _hw;
        vif = _vif;
        vifSize = _vifAllocSize;
        if (vif)
            rtw88_unregister_vif();
        mutation.finish();
    }

    /* Interface removal and PCI removal can wait for driver work. They run
     * with TX admission open but _powered=false, so every TX entry point
     * short-circuits before dereferencing these objects. */
    if (hw && vif && hw->ops && hw->ops->remove_interface)
        hw->ops->remove_interface(hw, vif);
    if (vif)
        IOFree(vif, vifSize);

    {
        auto mutation = beginTxStateMutation();
        if (_vif == vif) {
            _vif = nullptr;
            _vifAllocSize = 0;
        }
        mutation.finish();
    }

    if (_pcidev)
        rtw_pci_remove(_pcidev);

    {
        auto mutation = beginTxStateMutation();
        _rtwdev = nullptr;
        _hw = nullptr;
        __atomic_store_n(&_state, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        __atomic_store_n(&_associatedVisible, false, __ATOMIC_RELEASE);
        __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        _scanPartial = false;
        mutation.finish();
    }
}

IOReturn RTW88IEEE80211::setReceiveMulticast(bool active)
{
    if (!_hw || !_hw->ops || !_hw->ops->configure_filter)
        return kIOReturnNotReady;
    _receiveMulticast = active;
    if (_powered) {
        unsigned int flags = (active || _awdlReceiveMode) ? FIF_ALLMULTI : 0;
        _hw->ops->configure_filter(_hw, FIF_ALLMULTI, &flags, 0);
    }
    return kIOReturnSuccess;
}

IOReturn RTW88IEEE80211::setAWDLReceiveMode(bool active)
{
    /* Policy gate (1.0.2): do not enter AWDL receive mode. */
    if (active && !_awdlRadioAllowed) {
        if (!_awdlPolicyLogged) {
            _awdlPolicyLogged = true;
            IOLog("rtw88: AWDL radio disabled by policy (RTL88WiFiAWDLRadio=false); "
                  "radio stays on the infrastructure channel\n");
        }
        return kIOReturnSuccess;
    }

    /* If disabling while off-channel, restore the infrastructure channel
     * before changing receive policy. restoreSTAChannelAfterAWDL owns its own
     * writer and sends the AP null-data notification after releasing it. */
    if (!active)
        restoreSTAChannelAfterAWDL();

    auto mutation = beginTxStateMutation();
    if (!_hw || !_hw->ops || !_hw->ops->configure_filter) {
        mutation.finish();
        return kIOReturnNotReady;
    }

    _awdlReceiveMode = active;
    if (!active) {
        _awdlChannel = 0;
        _awdlPreparedChannel = 0;
        _awdlOffChannel = false;
    }

    unsigned int changed =
        FIF_OTHER_BSS | FIF_ALLMULTI | FIF_BCN_PRBRESP_PROMISC;
    unsigned int flags = active ?
        (FIF_OTHER_BSS | FIF_ALLMULTI | FIF_BCN_PRBRESP_PROMISC) :
        (_receiveMulticast ? FIF_ALLMULTI : 0);
    if (_powered)
        _hw->ops->configure_filter(_hw, changed, &flags, 0);
    mutation.finish();

    IOLog("rtw88: AWDL receive mode %s flags=0x%x\n",
          active ? "enabled" : "disabled", flags);
    return kIOReturnSuccess;
}

void RTW88IEEE80211::setAWDLAddress(const uint8_t *mac)
{
    if (!mac)
        return;
    auto mutation = beginTxStateMutation();
    memcpy(_awdlAddress, mac, sizeof(_awdlAddress));
    mutation.finish();
}

bool RTW88IEEE80211::canTransmitAWDL() const
{
    return _powered && _awdlReceiveMode && _hw && _hw->conf.chandef.chan &&
        _awdlChannel && _hw->conf.chandef.chan->hw_value == _awdlChannel &&
        (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_IDLE || __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED);
}

void RTW88IEEE80211::restoreSTAChannelAfterAWDL()
{
    bool notifyAP = false;
    {
        auto mutation = beginTxStateMutation();
        if (!_awdlOffChannel) {
            mutation.finish();
            return;
        }

        /* Close every submit queue before touching the shared channel
         * definition or the VIF's hardware timeslice state. */
        if (!_powered || !_hw || !_vif || !associatedVisible() ||
            __atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_CONNECTED ||
            !_targetBSS.channel) {
            _awdlOffChannel = false;
            _awdlPreparedChannel = 0;
            mutation.finish();
            return;
        }

        struct ieee80211_channel *home = nullptr;
        for (int b = 0; b < NL80211_NUM_BANDS && !home; ++b) {
            struct ieee80211_supported_band *band =
                _hw->wiphy ? _hw->wiphy->bands[b] : nullptr;
            if (!band) continue;
            for (int i = 0; i < band->n_channels; ++i) {
                if (band->channels[i].hw_value == _targetBSS.channel) {
                    home = &band->channels[i];
                    home->band = band->band;
                    break;
                }
            }
        }
        if (!home) {
            _awdlOffChannel = false;
            _awdlPreparedChannel = 0;
            mutation.finish();
            return;
        }

        setConnectedChandef(home, &mutation);
        rtw88_restore_connected_hw_timeslice(_hw, _vif, _targetBSS.bssid);
        _awdlOffChannel = false;
        _awdlPreparedChannel = 0;
        notifyAP = true;
        mutation.finish();
    }

    /* The AP null-data notification is itself a TX operation, so it happens
     * only after the channel writer releases admission. */
    if (notifyAP)
        (void)txNullFunc(false);
}

IOReturn RTW88IEEE80211::setAWDLChannel(uint16_t channel)
{
    if (!_awdlRadioAllowed)
        return kIOReturnNotReady;
    if (channel == 0)
        return kIOReturnBadArgument;

    struct ieee80211_channel *target = nullptr;
    bool connected = false;
    bool idle = false;
    bool wasOffChannel = false;
    bool alreadyOnTarget = false;
    bool sameAsHome = false;
    bool sentPowerSave = false;

    /* Pin the WCL/radio objects while inspecting the channel table and the
     * currently active timeslice. This lease is dropped before requesting a
     * writer because a connected off-channel switch must first send NullFunc. */
    {
        auto txLease = _txStateGate.tryEnterTransmit();
        if (!txLease)
            return kIOReturnBusy;
        if (!_powered || !_hw || !_hw->wiphy)
            return kIOReturnNotReady;

        for (int b = 0; b < NL80211_NUM_BANDS && !target; ++b) {
            struct ieee80211_supported_band *band = _hw->wiphy->bands[b];
            if (!band) continue;
            for (int i = 0; i < band->n_channels; ++i) {
                if (band->channels[i].hw_value == channel &&
                    !(band->channels[i].flags &
                      (IEEE80211_CHAN_DISABLED | IEEE80211_CHAN_NO_IR |
                       IEEE80211_CHAN_RADAR))) {
                    target = &band->channels[i];
                    target->band = band->band;
                    break;
                }
            }
        }
        if (!target)
            return kIOReturnUnsupported;

        const RTW88State state = __atomic_load_n(&_state, __ATOMIC_ACQUIRE);
        connected = state == RTW88_STATE_CONNECTED && associatedVisible();
        idle = state == RTW88_STATE_IDLE;
        wasOffChannel = _awdlOffChannel;
        sameAsHome = connected && channel == _targetBSS.channel;
        alreadyOnTarget = wasOffChannel && _hw->conf.chandef.chan == target;

        if (!connected && !idle)
            return kIOReturnBusy;

        if (connected && !sameAsHome && !alreadyOnTarget && !wasOffChannel) {
            if (!txNullFunc(true, &txLease))
                return kIOReturnNotReady;
            sentPowerSave = true;
        }
    }

    /* A previous timeslice is returned home first; after that, retry this
     * request so the AP is placed in power-save before the next retune. */
    if (connected && wasOffChannel && !sameAsHome && !alreadyOnTarget) {
        restoreSTAChannelAfterAWDL();
        return setAWDLChannel(channel);
    }

    if (connected && wasOffChannel && sameAsHome)
        restoreSTAChannelAfterAWDL();

    if (connected && sentPowerSave)
        IOSleep(6);

    auto mutation = beginTxStateMutation();
    if (!_powered || !_hw || !_vif || !_hw->wiphy) {
        mutation.finish();
        return kIOReturnNotReady;
    }

    const RTW88State currentState = __atomic_load_n(&_state, __ATOMIC_ACQUIRE);
    const bool currentConnected =
        currentState == RTW88_STATE_CONNECTED && associatedVisible();
    const bool currentIdle = currentState == RTW88_STATE_IDLE;

    if ((connected && !currentConnected) || (idle && !currentIdle)) {
        mutation.finish();
        return kIOReturnBusy;
    }

    /* Re-resolve the channel after obtaining the writer. The Wiphy pointer is
     * now protected against stop/power teardown until this transaction ends. */
    target = nullptr;
    for (int b = 0; b < NL80211_NUM_BANDS && !target; ++b) {
        struct ieee80211_supported_band *band = _hw->wiphy->bands[b];
        if (!band) continue;
        for (int i = 0; i < band->n_channels; ++i) {
            if (band->channels[i].hw_value == channel &&
                !(band->channels[i].flags &
                  (IEEE80211_CHAN_DISABLED | IEEE80211_CHAN_NO_IR |
                   IEEE80211_CHAN_RADAR))) {
                target = &band->channels[i];
                target->band = band->band;
                break;
            }
        }
    }
    if (!target) {
        mutation.finish();
        return kIOReturnUnsupported;
    }

    _awdlChannel = channel;

    if (currentConnected && channel == _targetBSS.channel) {
        const bool home = _hw->conf.chandef.chan &&
                          _hw->conf.chandef.chan->hw_value == channel;
        mutation.finish();
        return home ? kIOReturnSuccess : kIOReturnNotReady;
    }

    if (currentConnected) {
        /* A concurrent scheduler call may have already completed the same
         * retune while this request was yielding to the AP power-save frame. */
        if (_awdlOffChannel && _hw->conf.chandef.chan == target) {
            mutation.finish();
            return kIOReturnSuccess;
        }
        if (_awdlOffChannel) {
            mutation.finish();
            restoreSTAChannelAfterAWDL();
            return setAWDLChannel(channel);
        }

        _hw->conf.chandef.chan = target;
        _hw->conf.chandef.width = NL80211_CHAN_WIDTH_20_NOHT;
        _hw->conf.chandef.center_freq1 = target->center_freq;
        rtw88_awdl_timeslice_switch_channel(_hw);
        _awdlPreparedChannel = channel;
        _awdlOffChannel = true;
        mutation.finish();
        return kIOReturnSuccess;
    }

    if (_awdlPreparedChannel == channel &&
        _hw->conf.chandef.chan == target &&
        _hw->conf.chandef.width == NL80211_CHAN_WIDTH_20_NOHT) {
        mutation.finish();
        return kIOReturnSuccess;
    }

    _hw->conf.chandef.chan = target;
    _hw->conf.chandef.width = NL80211_CHAN_WIDTH_20_NOHT;
    _hw->conf.chandef.center_freq1 = target->center_freq;
    rtw88_awdl_switch_channel(_hw);
    _awdlPreparedChannel = channel;
    _awdlOffChannel = false;
    mutation.finish();
    return kIOReturnSuccess;
}

IOReturn RTW88IEEE80211::powerOn()
{
    IOLog("rtw88: IEEE80211 powerOn\n");
    struct ieee80211_hw *hw = nullptr;
    struct ieee80211_vif *vif = nullptr;
    {
        auto mutation = beginTxStateMutation();
        if (__atomic_load_n(&_stopping, __ATOMIC_ACQUIRE) ||
            __atomic_load_n(&_coreStopping, __ATOMIC_ACQUIRE)) {
            mutation.finish();
            return kIOReturnNotReady;
        }
        if (__atomic_load_n(&_powered, __ATOMIC_ACQUIRE)) {
            mutation.finish();
            return kIOReturnSuccess;
        }
        if (__atomic_load_n(&_coreStarting, __ATOMIC_ACQUIRE)) {
            mutation.finish();
            return kIOReturnBusy;
        }
        hw = _hw;
        vif = _vif;
        if (!hw || !hw->ops || !hw->ops->start || !vif) {
            mutation.finish();
            return kIOReturnNotReady;
        }
        __atomic_store_n(&_coreStarting, true, __ATOMIC_RELEASE);
        mutation.finish();
    }

    /* TX remains closed while firmware/core start and interface restore may
     * schedule work. Never hold the radio writer across these lifecycle calls. */
    int ret = hw->ops->start(hw);
    if (ret) {
        IOLog("rtw88: rtw_core_start failed: %d\n", ret);
        auto mutation = beginTxStateMutation();
        __atomic_store_n(&_coreStarting, false, __ATOMIC_RELEASE);
        mutation.finish();
        return kIOReturnError;
    }

    if (rtw88_restore_interface(hw, vif) != 0) {
        if (hw->ops->stop)
            hw->ops->stop(hw, false);
        auto mutation = beginTxStateMutation();
        __atomic_store_n(&_coreStarting, false, __ATOMIC_RELEASE);
        mutation.finish();
        return kIOReturnError;
    }

    bool abortStart = false;
    {
        auto mutation = beginTxStateMutation();
        abortStart = __atomic_load_n(&_stopping, __ATOMIC_ACQUIRE) ||
                     _hw != hw || _vif != vif;
        if (!abortStart) {
            _awdlPreparedChannel = 0;
            _awdlOffChannel = false;
            __atomic_store_n(&_powered, true, __ATOMIC_RELEASE);
        }
        mutation.finish();
    }

    if (abortStart) {
        if (hw->ops->stop)
            hw->ops->stop(hw, false);
        auto mutation = beginTxStateMutation();
        __atomic_store_n(&_coreStarting, false, __ATOMIC_RELEASE);
        mutation.finish();
        return kIOReturnNotReady;
    }

    {
        auto mutation = beginTxStateMutation();
        __atomic_store_n(&_coreStarting, false, __ATOMIC_RELEASE);
        mutation.finish();
    }

    IOReturn filterResult = _awdlReceiveMode ?
        setAWDLReceiveMode(true) : setReceiveMulticast(_receiveMulticast);
    if (filterResult != kIOReturnSuccess)
        powerOff();
    return filterResult;
}

void RTW88IEEE80211::powerOff()
{
    IOLog("rtw88: IEEE80211 powerOff\n");
    __atomic_store_n(&_dataTxBlocked, true, __ATOMIC_RELEASE);

    /* A concurrent powerOn owns lifecycle start until it publishes either
     * powered=true or a stopped failure result. Wait without holding the TX
     * writer so core/RX work can complete normally. */
    for (;;) {
        while (__atomic_load_n(&_coreStarting, __ATOMIC_ACQUIRE))
            IOSleep(1);

        struct ieee80211_hw *hw = nullptr;
        bool wasPowered = false;
        bool waitForOtherStop = false;
        {
            auto mutation = beginTxStateMutation();
            if (__atomic_load_n(&_coreStarting, __ATOMIC_ACQUIRE)) {
                mutation.finish();
                waitForOtherStop = true;
            } else if (__atomic_load_n(&_coreStopping, __ATOMIC_ACQUIRE)) {
                mutation.finish();
                waitForOtherStop = true;
            } else {
                wasPowered = __atomic_load_n(&_powered, __ATOMIC_ACQUIRE);
                if (!wasPowered) {
                    mutation.finish();
                    return;
                }
                hw = _hw;
                __atomic_store_n(&_coreStopping, true, __ATOMIC_RELEASE);
                __atomic_store_n(&_powered, false, __ATOMIC_RELEASE);
                _awdlPreparedChannel = 0;
                _awdlOffChannel = false;
                mutation.finish();
            }
        }

        if (waitForOtherStop) {
            IOSleep(1);
            continue;
        }

        /* The reader drain above means no TX callback remains inside ops->tx().
         * Late readers observe powered=false and return. ops->stop may drain RX
         * workers that need the radio gate, so it runs outside the writer. */
        if (wasPowered && hw && hw->ops && hw->ops->stop)
            hw->ops->stop(hw, false);

        {
            auto mutation = beginTxStateMutation();
            __atomic_store_n(&_coreStopping, false, __ATOMIC_RELEASE);
            mutation.finish();
        }
        return;
    }
}

/*  Interrupt dispatch                                                  */
/* ------------------------------------------------------------------ */

extern "C" void rtw88_trigger_interrupt(void);

void RTW88IEEE80211::handleInterrupt()
{
    /* Never log every IRQ: console I/O on the RX/TX hot path adds measurable
     * scheduling jitter and can amplify stalls while traffic is heavy. */
    rtw88_trigger_interrupt();
}

/* ------------------------------------------------------------------ */
/*  TX path: Ethernet → 802.11 data frame                              */
/* ------------------------------------------------------------------ */

UInt32 RTW88IEEE80211::outputPacket(mbuf_t m)
{
    return outputPacketWithCompletion(m, nullptr, nullptr, nullptr);
}

UInt32 RTW88IEEE80211::outputPacketWithCompletion(
    mbuf_t m, RTW88TxCompletionCallback callback, void *context, void *cookie,
    uint8_t accessCategory, uint8_t tid)
{
    if (!m) {
        if (callback)
            callback(context, cookie, false);
        return kIOReturnOutputDropped;
    }

    /* Acquire before any association/key/station/VIF read. The lease follows
     * the packet through the synchronous RTW88 ops->tx() descriptor build. */
    auto txLease = _txStateGate.tryEnterTransmit();
    if (!txLease) {
        mbuf_freem(m);
        if (callback)
            callback(context, cookie, false);
        return kIOReturnOutputDropped;
    }

    const bool connected = associatedVisible() && !_awdlOffChannel &&
        ((__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED) ||
         (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING &&
          __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED &&
          (__atomic_load_n(&_manualScanChannelCount, __ATOMIC_ACQUIRE) == 0 ||
           __atomic_load_n(&_manualScanOnHomeChannel, __ATOMIC_ACQUIRE))));
    if (!_powered || !connected || !_rtwdev || !_hw || !_vif || !_sta) {
        mbuf_freem(m);
        if (callback)
            callback(context, cookie, false);
        return kIOReturnOutputDropped;
    }

    const bool submitted = txDataFrame(
        m, callback, context, cookie, accessCategory, tid,
        false, false, &txLease);
    if (!submitted && callback)
        callback(context, cookie, false);
    return submitted ? kIOReturnOutputSuccess : kIOReturnOutputDropped;
}

/*  RX path: sk_buff from driver → mbuf to macOS                       */
/* ------------------------------------------------------------------ */

void RTW88IEEE80211::rxFrame(struct sk_buff *skb)
{
    if (!skb) return;
    if (skb->len < 24) { kfree_skb(skb); return; }

    struct ieee80211_rx_status *rxs = IEEE80211_SKB_RXCB(skb);
    /* A corrupted frame must not change association state, peer clocks, or
     * enter either network interface even if a diagnostic RX filter admits it. */
    if (rxs->flag & RX_FLAG_FAILED_FCS_CRC) {
        kfree_skb(skb);
        return;
    }
    if (rtw88StationSignal(skb->data, skb->len, _macAddr, _targetBSS.bssid,
                          rxs->signal,
                          (rxs->flag & (RX_FLAG_NO_SIGNAL_VAL | RX_FLAG_FAILED_FCS_CRC)) != 0))
        _rssi = rxs->signal;

    struct ieee80211_hdr *hdr = (struct ieee80211_hdr *)skb->data;
    __le16 fc = hdr->frame_control;

    _rxFrameCount++;

    if (ieee80211_is_mgmt(fc)) {
        processRxMgmt(skb);
    } else if (ieee80211_is_data(fc)) {
        /* AWDL data is a direct (no-DS) 802.11 frame and remains valid even
         * when the infrastructure STA is disconnected. Consume it before the
         * normal ToDS/FromDS path applies association-state assumptions. */
        if (!tryDeliverAWDLDataFrame(skb))
            processRxData(skb);
    } else {
        kfree_skb(skb);
    }
}

void RTW88IEEE80211::processRxMgmt(struct sk_buff *skb)
{
    struct ieee80211_hdr *hdr = (struct ieee80211_hdr *)skb->data;
    __le16 fc = hdr->frame_control;
    uint16_t stype = le16_to_cpu(fc) & 0x00f0;

    switch (stype) {
    case 0x0080: /* beacon */
    case 0x0050: /* probe response */
        if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING)
            processScanResult(skb);
        else if (stype == 0x0080 && __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED &&
                 !_curBssTim && skb->len >= sizeof(struct ieee80211_hdr_3addr) &&
                 memcmp(((struct ieee80211_hdr_3addr *)skb->data)->addr3,
                        _targetBSS.bssid, 6) == 0)
            processScanResult(skb);   /* r10: refresh IE list with a TIM */
        else
            kfree_skb(skb);
        break;

    case 0x00B0: /* auth */
        if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_AUTHENTICATING && !authenticationCancelled()) {
            uint16_t status = 0;
            if (rtw88AuthResponse(skb->data, skb->len, _macAddr, _targetBSS.bssid, &status)) {
                if (status == 0) {
                    IOLog("rtw88: auth success, sending assoc\n");
                    doAssociate();
                } else {
                    IOLog("rtw88: auth rejected by AP status=%u\n", status);
                    /* Was: silently drop to IDLE, so macOS never learned the
                     * join failed and retried the same node.  Try the next
                     * node of the SSID, else report the failure. */
                    _timer->cancelTimeout();
                    joinAttemptFailed("auth-rejected");
                }
            }
        }
        kfree_skb(skb);
        break;

    case 0x0010: /* assoc response */
        if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_ASSOCIATING)
            processAssocResponse(skb);
        else
            kfree_skb(skb);
        break;

    case 0x0030: /* reassoc response */
        if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_ASSOCIATING)
            processAssocResponse(skb);
        else
            kfree_skb(skb);
        break;

    case 0x00A0: /* disassoc */
    case 0x00C0: /* deauth */
        /* Both subtypes require the two-byte reason code. A header-only
         * truncated frame must not tear down keys or the Wi-Fi association. */
        if (skb->len < sizeof(struct ieee80211_hdr_3addr) + 2) {
            kfree_skb(skb);
            break;
        }
        if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED ||
            __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_HANDSHAKING ||
            (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING &&
             __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED)) {
            struct ieee80211_hdr_3addr *h3 =
                (struct ieee80211_hdr_3addr *)skb->data;
            bool fromTarget = memcmp(h3->addr3, _targetBSS.bssid, 6) == 0 ||
                              memcmp(h3->addr2, _targetBSS.bssid, 6) == 0;
            bool addressedToUs = memcmp(h3->addr1, _macAddr, 6) == 0 ||
                                 is_broadcast_ether_addr(h3->addr1);
            if (!fromTarget || !addressedToUs) {
                kfree_skb(skb);
                break;
            }
            /* Log which frame and the reason code — the AP's reason for
             * dropping us a few seconds after connect (e.g. excessive retries
             * vs. class-3 violation) is the key diagnostic. */
            {
                const uint8_t *rb = skb->data + sizeof(*h3);
                uint16_t reason = (skb->len >= sizeof(*h3) + 2) ?
                                  (uint16_t)(rb[0] | (rb[1] << 8)) : 0;
                _deauthReason = reason;
                IOLog("rtw88: %s from AP, reason=%u — disconnecting\n",
                      (stype == 0x00C0) ? "deauth" : "disassoc", reason);
            }
            const bool lostLinkDuringConnectedScan =
                (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING &&
                 __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED
            clearKeys();
            rxBaTeardownAll();
            if (lostLinkDuringConnectedScan) {
                /* Keep SCANNING latched until the worker exits.  Resetting the
                 * state here made scanDone() return early while the worker
                 * continued channel-hopping after a deauth. */
                _manualScanAbort = true;
                __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
            } else {
                setRadioState(RTW88_STATE_IDLE);
                __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
                _scanPartial = false;
            }
            if (_parent)
                _parent->setLinkStatus(kIONetworkLinkValid);
            /* IO80211/CoreWiFi needs the asynchronous deauth notification,
             * not only a link-state change.  The reference IO80211 driver forwards the same
             * net80211 event as APPLE80211_M_DEAUTH_RECEIVED. */
            if (_delegate)
                _delegate->rtw88Event(kRTW88EventDeauth, &_deauthReason);
        }
        kfree_skb(skb);
        break;

    case 0x00D0: /* action */
        /* AWDL/P2P action frames are meaningful even while the infrastructure
         * STA is not associated. Give the native virtual interface a copy
         * before handling infrastructure BlockAck actions locally. */
        if (_parent) {
            struct ieee80211_rx_status *rxs = IEEE80211_SKB_RXCB(skb);
            uint16_t rxChannel = 0;
            if (rxs && rxs->band < NL80211_NUM_BANDS && _hw && _hw->wiphy) {
                struct ieee80211_supported_band *band = _hw->wiphy->bands[rxs->band];
                if (band) {
                    /* rx_status::freq is not consistently populated by every
                     * rtw88 path in this port. Prefer the currently tuned
                     * chandef and fall back to the AWDL home channel. */
                    if (_hw->conf.chandef.chan)
                        rxChannel = (uint16_t)_hw->conf.chandef.chan->hw_value;
                    else if (_awdlChannel)
                        rxChannel = _awdlChannel;
                }
            }
            _parent->injectRxActionFrame(skb->data, skb->len,
                                         rxs ? (int8_t)rxs->signal : 0,
                                         rxChannel);
        }

        if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED) {
            struct ieee80211_hdr_3addr *h3 =
                (struct ieee80211_hdr_3addr *)skb->data;
            const uint8_t *b = skb->data + sizeof(*h3);
            uint32_t blen = (skb->len > sizeof(*h3)) ?
                            skb->len - (uint32_t)sizeof(*h3) : 0;
            /* BlockAck (ADDBA/DELBA) action frames from our AP only. */
            if (blen >= 2 && b[0] == WLAN_CATEGORY_BACK &&
                memcmp(h3->addr3, _targetBSS.bssid, 6) == 0)
                handleBackAction(b, blen);
        }
        kfree_skb(skb);
        break;

    default:
        kfree_skb(skb);
        break;
    }
}

static uint32_t rtw88ReadSuite(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void rtw88WriteSuite(uint8_t *p, uint32_t suite)
{
    p[0] = (uint8_t)(suite >> 24);
    p[1] = (uint8_t)(suite >> 16);
    p[2] = (uint8_t)(suite >> 8);
    p[3] = (uint8_t)suite;
}

static bool rtw88RsnSelectCcmpPsk(const uint8_t *rsn, uint8_t len,
                                  uint32_t *pairwise_cipher,
                                  uint32_t *group_cipher,
                                  bool *has_sae_out = nullptr,
                                  bool *pmf_required_out = nullptr)
{
    if (!rsn || len < 8) return false;
    const uint8_t *p = rsn;
    const uint8_t *end = rsn + len;

    if ((size_t)(end - p) < 8)
        return false;

    if (p[0] != 1 || p[1] != 0) return false;
    p += 2; /* RSN version 1 */
    uint32_t group = rtw88ReadSuite(p);
    p += 4;

    if ((size_t)(end - p) < 2)
        return false;
    uint16_t pairwiseCount = (uint16_t)(p[0] | (p[1] << 8));
    p += 2;
    if (pairwiseCount > (size_t)(end - p) / 4)
        return false;

    bool hasCcmp = false;
    for (uint16_t i = 0; i < pairwiseCount; i++, p += 4) {
        if (rtw88ReadSuite(p) == WLAN_CIPHER_SUITE_CCMP)
            hasCcmp = true;
    }

    if ((size_t)(end - p) < 2)
        return false;
    uint16_t akmCount = (uint16_t)(p[0] | (p[1] << 8));
    p += 2;
    if (akmCount > (size_t)(end - p) / 4)
        return false;

    bool hasPsk = false;
    bool hasSae = false;
    for (uint16_t i = 0; i < akmCount; i++, p += 4) {
        const uint32_t akm = rtw88ReadSuite(p);
        if (akm == 0x000FAC02)       /* 00-0f-ac:2 PSK */
            hasPsk = true;
        else if (akm == 0x000FAC08 || /* 00-0f-ac:8 SAE */
                 akm == 0x000FAC09)   /* 00-0f-ac:9 FT-SAE */
            hasSae = true;
    }

    /* RSN Capabilities follows the AKM list. MFPR (bit 6) means the AP
     * requires 802.11w protected management frames. Do not claim WPA2 fallback
     * on such an AP: this driver has no BIP/PMF negotiation or key handling. */
    bool pmfRequired = false;
    if ((size_t)(end - p) >= 2) {
        const uint16_t rsnCaps = (uint16_t)(p[0] | (p[1] << 8));
        pmfRequired = (rsnCaps & (1U << 6)) != 0;
    }
    if (has_sae_out) *has_sae_out = hasSae;
    if (pmf_required_out) *pmf_required_out = pmfRequired;

    if (!hasCcmp || !hasPsk || pmfRequired)
        return false;

    if (group != WLAN_CIPHER_SUITE_CCMP &&
        group != WLAN_CIPHER_SUITE_TKIP)
        return false;

    if (pairwise_cipher)
        *pairwise_cipher = WLAN_CIPHER_SUITE_CCMP;
    if (group_cipher)
        *group_cipher = group;
    return true;
}

static uint16_t rtw88BuildSelectedRsnIe(uint8_t *out, uint32_t group_cipher)
{
    if (group_cipher != WLAN_CIPHER_SUITE_TKIP)
        group_cipher = WLAN_CIPHER_SUITE_CCMP;

    uint8_t *p = out;
    *p++ = WLAN_EID_RSN;
    *p++ = 20;           /* body length */
    *p++ = 1; *p++ = 0;  /* version */
    rtw88WriteSuite(p, group_cipher); p += 4;
    *p++ = 1; *p++ = 0;  /* one pairwise cipher */
    rtw88WriteSuite(p, WLAN_CIPHER_SUITE_CCMP); p += 4;
    *p++ = 1; *p++ = 0;  /* one AKM */
    rtw88WriteSuite(p, 0x000FAC02); p += 4; /* PSK */
    *p++ = 0; *p++ = 0;  /* RSN capabilities */
    return (uint16_t)(p - out);
}

/* An SSID element that is empty or all-zero names no network (hidden AP). */
static bool rtw88SsidIsBlank(const uint8_t *ssid, uint8_t len)
{
    for (uint8_t i = 0; i < len; i++)
        if (ssid[i]) return false;
    return true;
}

/* Final: put the BSS's known name back into its IE list.  CoreWLAN's
 * networkHiddenOrBroadcast() reads APPLE80211_IOC_AP_IE_LIST and reports a
 * network as hidden when the first SSID element is empty or starts with a
 * zero byte (its "SSID IE not found" / "SSID string empty" cases).  One
 * blank-SSID frame from an AP whose beacons are named replaced the cached IE
 * list and flipped the connected network to hidden after a wake. */
/* r10: offset of the first well-formed element `id` in an IE list, or -1. */
static int rtw88IeFind(const uint8_t *ies, uint32_t len, uint8_t id)
{
    for (uint32_t i = 0; i + 2 <= len; ) {
        uint32_t elen = 2u + ies[i + 1];
        if (i + elen > len) break;
        if (ies[i] == id) return (int)i;
        i += elen;
    }
    return -1;
}

static void rtw88RestoreSsidIe(RTW88BSS *bss)
{
    if (!bss->ssid_len || bss->ssid_len > 32) return;
    uint8_t out[sizeof(bss->ies)];
    uint32_t n = 0;
    out[n++] = WLAN_EID_SSID;
    out[n++] = bss->ssid_len;
    memcpy(out + n, bss->ssid, bss->ssid_len);
    n += bss->ssid_len;
    bool replaced = false;
    for (uint32_t i = 0; i + 2 <= bss->ies_len; ) {
        uint32_t elen = 2u + bss->ies[i + 1];
        if (i + elen > bss->ies_len) break;
        if (!replaced && bss->ies[i] == WLAN_EID_SSID)
            replaced = true;
        else if (n + elen < sizeof(out)) {
            memcpy(out + n, bss->ies + i, elen);
            n += elen;
        }
        i += elen;
    }
    memcpy(bss->ies, out, n);
    bss->ies_len = (uint16_t)n;
}

void RTW88IEEE80211::processScanResult(struct sk_buff *skb)
{
    if (!skb || skb->len < sizeof(struct ieee80211_hdr_3addr) + 12) {
        kfree_skb(skb);
        return;
    }

    /* Parse beacon/probe-resp minimal fields */
    const uint8_t *body = skb->data + sizeof(struct ieee80211_hdr_3addr);
    const uint8_t *end  = skb->data + skb->len;
    /* Skip: timestamp(8), beacon_int(2), capability(2) */
    body += 12;

    RTW88BSS *bss = (RTW88BSS *)IOMallocZero(sizeof(RTW88BSS));
    if (!bss) { kfree_skb(skb); return; }

    bss->beacon_interval = skb->data[32] | (uint16_t(skb->data[33]) << 8);
    bss->capabilities = skb->data[34] | (uint16_t(skb->data[35]) << 8);

    /* BSSID is addr3 in a beacon from AP */
    struct ieee80211_hdr *hdr = (struct ieee80211_hdr *)skb->data;
    memcpy(bss->bssid, hdr->addr3, 6);

    bool securityIESeen = false;
    bool iesComplete = true;
    bool ssidIeCopied = false;
    /* Walk IEs */
    while (body + 2 <= end) {
        uint8_t id = body[0];
        uint8_t len = body[1];
        if (body + 2 + len > end) { iesComplete = false; break; }

        if (id == WLAN_EID_SSID && len > 0 && len <= 32 &&
            !rtw88SsidIsBlank(body + 2, len)) {
            memcpy(bss->ssid, body + 2, len);
            bss->ssid_len = len;
        } else if (id == WLAN_EID_DS_PARAMS && len >= 1) {
            bss->channel = body[2];
        } else if (id == WLAN_EID_HT_OPERATION && len >= 1 && bss->channel == 0) {
            bss->channel = body[2];
        } else if (id == WLAN_EID_RSN) {
            securityIESeen = true;
            uint32_t pairwise = 0;
            uint32_t group = 0;
            bool hasSae = false;
            bool pmfRequired = false;
            const bool usablePsk = rtw88RsnSelectCcmpPsk(
                body + 2, len, &pairwise, &group, &hasSae, &pmfRequired);
            bss->rsn_has_sae = hasSae ? 1 : 0;
            bss->rsn_pmf_required = pmfRequired ? 1 : 0;
            if (usablePsk) {
                bss->cipher = pairwise;
                bss->group_cipher = group;
                bss->akm = 0x000FAC02; /* WPA2-PSK fallback */
            }
        } else if (id == WLAN_EID_VENDOR_SPECIFIC &&
                   len >= 8 && body[2] == 0x00 && body[3] == 0x50 &&
                   body[4] == 0xf2 && body[5] == 0x01 &&
                   bss->cipher == 0) {
            /* Legacy WPA IE. Keep this as scan metadata only; association
             * still prefers RSN/WPA2 when the AP advertises it. */
            securityIESeen = true;
            bss->cipher = WLAN_CIPHER_SUITE_TKIP;
            bss->group_cipher = WLAN_CIPHER_SUITE_TKIP;
            bss->akm    = 0x000FAC02; /* PSK */
        }

        /* Copy all IEs, except the padding some APs append to probe
         * responses (seen as a trailing empty vendor element plus empty SSID
         * elements): keep only the first SSID element and drop vendor
         * elements too short to hold an OUI. */
        bool skipIe = (id == WLAN_EID_SSID && ssidIeCopied) ||
                      (id == WLAN_EID_VENDOR_SPECIFIC && len < 3);
        if (id == WLAN_EID_SSID) ssidIeCopied = true;
        uint16_t copy = (uint16_t)(2 + len);
        if (!skipIe && bss->ies_len + copy < sizeof(bss->ies)) {
            memcpy(bss->ies + bss->ies_len, body, copy);
            bss->ies_len += copy;
        }
        body += 2 + len;
    }

    struct ieee80211_rx_status *rxs = IEEE80211_SKB_RXCB(skb);
    bss->rssi = rxs->signal;
    bss->freq = rxs->freq;
    bss->last_seen_scan = _scanGeneration;
    const bool ssidNamed = bss->ssid_len != 0;
    if (ssidNamed && (le16_to_cpu(hdr->frame_control) & 0x00f0) == 0x0080)
        bss->beacon_named = 1;
    
    if (bss->channel == 0 && bss->freq) {
        int f = bss->freq;
        if (f == 2484)
            bss->channel = 14;
        else if (f >= 2412 && f <= 2472)
            bss->channel = (f - 2407) / 5;
        else if (f >= 5000 && f <= 5900)
            bss->channel = (f - 5000) / 5;
    }

    /* Add to BSS list (deduplicate by BSSID) */
    IOLockLock(_bssLock);
    for (RTW88BSS *e = _bssList; e; e = e->next) {
        if (memcmp(e->bssid, bss->bssid, 6) == 0) {
            if (!bss->ssid_len && e->ssid_len) {
                memcpy(bss->ssid, e->ssid, sizeof(bss->ssid));
                bss->ssid_len = e->ssid_len;
            }
            bool privacy = (bss->capabilities & 0x0010) != 0;
            bool wasPrivate = (e->capabilities & 0x0010) != 0;
            if (privacy && wasPrivate && !securityIESeen && !bss->cipher) {
                bss->cipher = e->cipher;
                bss->group_cipher = e->group_cipher;
                bss->akm = e->akm;
                bss->rsn_has_sae = e->rsn_has_sae;
                bss->rsn_pmf_required = e->rsn_pmf_required;
                // Preserve the coherent security/capability IE set only when
                // the new observation was incomplete, not after an open AP.
                if (!iesComplete) {
                    bss->ies_len = e->ies_len;
                    memcpy(bss->ies, e->ies, sizeof(bss->ies));
                }
            }
            bss->beacon_named |= e->beacon_named;
            if (!ssidNamed && bss->beacon_named && bss->ssid_len) {
                static uint32_t sBlankSsidKept;
                uint32_t c = ++sBlankSsidKept;
                rtw88RestoreSsidIe(bss);
                if ((c & (c - 1)) == 0)
                    IOLog("rtw88: scan blank SSID from named BSS %02x:%02x:%02x:%02x:%02x:%02x "
                          "stype=0x%02x; kept known SSID (count=%u)\n",
                          bss->bssid[0], bss->bssid[1], bss->bssid[2], bss->bssid[3],
                          bss->bssid[4], bss->bssid[5],
                          le16_to_cpu(hdr->frame_control) & 0x00f0, c);
            }
            /* A probe response has no TIM. Keep the TIM learned from this
             * BSS's named beacons so the cached list still reads as a beacon.
             * Not for a hidden AP: its name only comes from probe responses. */
            if (bss->beacon_named &&
                rtw88IeFind(bss->ies, bss->ies_len, WLAN_EID_TIM) < 0) {
                int t = rtw88IeFind(e->ies, e->ies_len, WLAN_EID_TIM);
                if (t >= 0) {
                    uint32_t tl = 2u + e->ies[t + 1];
                    if (bss->ies_len + tl < sizeof(bss->ies)) {
                        memcpy(bss->ies + bss->ies_len, e->ies + t, tl);
                        bss->ies_len = (uint16_t)(bss->ies_len + tl);
                    }
                }
            }
            if (memcmp(bss->bssid, _targetBSS.bssid, 6) == 0)
                _curBssTim = rtw88IeFind(bss->ies, bss->ies_len, WLAN_EID_TIM) >= 0;
            struct ieee80211_rx_status *status = IEEE80211_SKB_RXCB(skb);
            if (status->flag & RX_FLAG_NO_SIGNAL_VAL) bss->rssi = e->rssi;
            RTW88BSS *saved_next = e->next;
            memcpy(e, bss, sizeof(*bss));
            e->next = saved_next; /* preserve linkage */
            IOFree(bss, sizeof(*bss));
            IOLockUnlock(_bssLock);
            kfree_skb(skb);
            return;
        }
    }
    if (memcmp(bss->bssid, _targetBSS.bssid, 6) == 0)
        _curBssTim = rtw88IeFind(bss->ies, bss->ies_len, WLAN_EID_TIM) >= 0;
    bss->next = _bssList;
    _bssList  = bss;
    _bssCount++;
    IOLockUnlock(_bssLock);

    kfree_skb(skb);
}

void RTW88IEEE80211::processRxData(struct sk_buff *skb)
{
    bool connected = (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED) ||
                     (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_HANDSHAKING) ||
                     (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING &&
                      __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED
    if (!connected) {
        kfree_skb(skb);
        return;
    }

    /* AWDL receive mode asks the chip to accept frames for an additional
     * virtual MAC. Re-establish the infrastructure address/BSSID filter in
     * software before the legacy Ethernet conversion path. */
    struct ieee80211_hdr *infraHdr = (struct ieee80211_hdr *)skb->data;
    uint16_t infraFc = le16_to_cpu(infraHdr->frame_control);
    bool fromDS = (infraFc & IEEE80211_FCTL_FROMDS) != 0;
    bool toUs = memcmp(infraHdr->addr1, _macAddr, 6) == 0 ||
                is_broadcast_ether_addr(infraHdr->addr1) ||
                is_multicast_ether_addr(infraHdr->addr1);
    bool fromAP = memcmp(infraHdr->addr2, _targetBSS.bssid, 6) == 0;
    if (!fromDS || !toUs || !fromAP) {
        kfree_skb(skb);
        return;
    }

    /* If this TID has an active downlink BlockAck agreement, run the frame
     * through the per-TID reorder buffer so A-MPDU subframes (and frames
     * retransmitted in a later A-MPDU) reach the stack in order.  Delivering
     * out of order collapses TCP and trips CCMP replay drops — that is the RX
     * regression aggregation otherwise causes. */
    struct ieee80211_hdr *hdr = (struct ieee80211_hdr *)skb->data;
    /* r10 (mac80211 ieee80211_rx_reorder_ampdu parity): group-addressed
     * frames use the AP's separate multicast sequence counter and NoAck
     * frames are outside the BlockAck agreement, so neither may move the
     * unicast reorder window or be dropped as "stale" by it. */
    if (ieee80211_is_data_qos(hdr->frame_control) &&
        !is_multicast_ether_addr(hdr->addr1)) {
        uint16_t hdrlen = ieee80211_get_hdrlen_from_skb(skb);
        if (skb->len >= hdrlen &&
            (skb->data[hdrlen - 2] & 0x60) != 0x20) {   /* ack policy != NoAck */
            uint8_t tid = (uint8_t)(skb->data[hdrlen - 2] & 0x0f);
            if (tid < kRxBaNumTid && _rxBa[tid] && _rxBa[tid]->active) {
                uint16_t sn = (uint16_t)
                    ((le16_to_cpu(hdr->seq_ctrl) & 0xFFF0) >> 4);
                rxReorderInput(tid, skb, sn);   /* takes ownership of skb */
                return;
            }
        }
    }

    deliverDataFrame(skb);   /* no active RX BA — deliver immediately */
}

/* Strip the 802.11 header (+ optional CCMP IV), de-aggregate A-MSDU if present,
 * and hand each MSDU to the network stack as Ethernet.  Takes ownership of skb. */
void RTW88IEEE80211::deliverDataFrame(struct sk_buff *skb)
{
    struct ieee80211_hdr *hdr = (struct ieee80211_hdr *)skb->data;
    uint16_t hdrlen = ieee80211_get_hdrlen_from_skb(skb);
    if (skb->len < hdrlen) { kfree_skb(skb); return; }

    bool prot = ieee80211_has_protected(hdr->frame_control);
    bool mcast = is_multicast_ether_addr(hdr->addr1);

    /* A protected frame the hardware did not decrypt is still ciphertext;
     * mac80211 would drop it. Log counts 1, 2, 4, 8, ... */
    if (prot && !(IEEE80211_SKB_RXCB(skb)->flag & RX_FLAG_DECRYPTED)) {
        uint32_t n = ++_rxUndecryptedProtected;
        if ((n & (n - 1)) == 0)
            IOLog("rtw88: RX protected data not HW-decrypted, dropped count=%u "
                  "len=%u mcast=%d\n", n, skb->len, mcast ? 1 : 0);
        kfree_skb(skb);
        return;
    }

    /* rtw88 sets BIT_APP_MIC | BIT_APP_ICV in RCR and reports only
     * RX_FLAG_DECRYPTED, so the CCMP MIC (8) or TKIP Michael MIC + ICV
     * (8 + 4) is still at the end. mac80211 trims it; do the same. */
    if (prot) {
        uint32_t cipher = mcast ? _targetBSS.group_cipher : _targetBSS.cipher;
        uint32_t trailer = (cipher == WLAN_CIPHER_SUITE_TKIP) ? 12 : 8;
        if (skb->len < hdrlen + 8 + trailer) { kfree_skb(skb); return; }
        skb_trim(skb, skb->len - trailer);
    }

    /* Once the pairwise key is installed only EAPOL may arrive in the
     * clear (mac80211 ieee80211_drop_unencrypted). The EAPOL exception is
     * applied below, after the LLC/SNAP header is parsed. */
    bool keyed = __atomic_load_n(&_m3KeysInstalled, __ATOMIC_ACQUIRE) ||
                 __atomic_load_n(&_externalPTKInstalled, __ATOMIC_ACQUIRE);

    bool amsdu = false;
    if (ieee80211_is_data_qos(hdr->frame_control))
        amsdu = (skb->data[hdrlen - 2] & 0x80) != 0;  /* QoS-ctl A-MSDU bit */

    if (amsdu && !prot && keyed) {
        uint32_t n = ++_rxUnprotectedDropped;
        if ((n & (n - 1)) == 0)
            IOLog("rtw88: RX unprotected A-MSDU on keyed link, dropped count=%u\n", n);
        kfree_skb(skb);
        return;
    }

    if (amsdu) {
        /* QoS A-MSDU: header [+ CCMP IV] then a chain of subframes.  rtw88
         * leaves the CCMP IV in the frame (mac80211 would normally strip it). */
        uint32_t off = hdrlen;
        if (ieee80211_has_protected(hdr->frame_control)) {
            if (skb->len < off + 8) { kfree_skb(skb); return; }
            off += 8;
        }
        deAmsdu(skb->data + off, skb->len - off);
        kfree_skb(skb);
        return;
    }

    /* Single MSDU.  Decrypted CCMP frames may still carry the 8-byte CCMP
     * header before the plaintext LLC/SNAP bytes. */
    uint32_t payload_off = hdrlen;
    if (skb->len < payload_off + 8) { kfree_skb(skb); return; }
    const uint8_t *llc = skb->data + payload_off;
    if ((llc[0] != 0xAA || llc[1] != 0xAA || llc[2] != 0x03) &&
        ieee80211_has_protected(hdr->frame_control) &&
        skb->len >= payload_off + 8 + 8) {
        const uint8_t *ccmp_llc = skb->data + payload_off + 8;
        if (ccmp_llc[0] == 0xAA && ccmp_llc[1] == 0xAA && ccmp_llc[2] == 0x03) {
            payload_off += 8;
            llc = ccmp_llc;
            if (!_rxCcmpIvSkipLogged) {
                IOLog("rtw88: rx protected data includes CCMP IV, skipping it\n");
                _rxCcmpIvSkipLogged = true;
            }
        }
    }

    /* LLC SNAP: AA AA 03 00 00 00 ETHERTYPE. Anything else would reach the
     * stack as EtherType 0, so drop it. */
    if (llc[0] != 0xAA || llc[1] != 0xAA || llc[2] != 0x03) {
        uint32_t n = ++_rxNonSnapDropped;
        if ((n & (n - 1)) == 0)
            IOLog("rtw88: RX data without LLC/SNAP dropped count=%u prot=%d len=%u\n",
                  n, prot ? 1 : 0, skb->len);
        kfree_skb(skb);
        return;
    }
    uint16_t ethertype = 0;
    {
        ethertype = (uint16_t)((llc[6] << 8) | llc[7]);

        if (!prot && keyed && ethertype != ETH_P_PAE) {
            uint32_t n = ++_rxUnprotectedDropped;
            if ((n & (n - 1)) == 0)
                IOLog("rtw88: RX unprotected data on keyed link dropped count=%u "
                      "ethertype=0x%04x mcast=%d\n", n, ethertype, mcast ? 1 : 0);
            kfree_skb(skb);
            return;
        }

        if (ethertype == ETH_P_PAE) {
            IOLog("rtw88: EAPOL RX external=%d state=%d len=%u\n",
                  _externalSupplicant, __atomic_load_n(&_state, __ATOMIC_ACQUIRE),
                  skb->len - payload_off - 8);
        }

        /* Check for EAPOL during handshake (never aggregated). */
        if (ethertype == ETH_P_PAE && !_externalSupplicant &&
            (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_HANDSHAKING || __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED ||
             (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING && __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED))) {
            handleEAPOL(llc + 8, skb->len - payload_off - 8);
            kfree_skb(skb);
            return;
        }
    }

    /* DA = addr1 (recipient = us), SA = addr3 (original source via DS) */
    uint32_t paylen = skb->len - payload_off - 8; /* strip 802.11/CCMP/LLC */

    /* One-shot hardware check of the trailer trim: for the first few
     * decrypted unicast IPv4 frames the payload must equal IPv4 total
     * length (extra=0). A negative value would mean over-trimming. */
    if (prot && !mcast && ethertype == ETH_P_IP && paylen >= 20 &&
        _rxTrailerChecks < 4) {
        _rxTrailerChecks++;
        uint32_t iplen = ((uint32_t)llc[8 + 2] << 8) | llc[8 + 3];
        IOLog("rtw88: RX trailer check %u payload=%u ip_total=%u extra=%d\n",
              _rxTrailerChecks, paylen, iplen, (int)paylen - (int)iplen);
    }
    deliverEthernet(hdr->addr1, hdr->addr3, ethertype, llc + 8, paylen);
    kfree_skb(skb);
}

/* Build one Ethernet frame [da][sa][ethertype][payload] and inject it. */
void RTW88IEEE80211::deliverEthernet(const uint8_t *da, const uint8_t *sa,
                                     uint16_t ethertype,
                                     const uint8_t *payload, uint32_t paylen)
{
    /* Allocate via IONetworkController::allocatePacket (through the parent) —
     * NOT mbuf_allocpacket.  allocatePacket sets m_len/pkthdr.len consistently
     * for every segment, which the dlil input validator requires.
     * mbuf_copyback fills the data and is chain-safe. */
    if (!_parent) return;
    mbuf_t m = _parent->allocateInputPacket(14 + paylen);
    if (!m) return;

    uint8_t ehdr[14];
    memcpy(ehdr,     da, 6);
    memcpy(ehdr + 6, sa, 6);
    ehdr[12] = (uint8_t)(ethertype >> 8);
    ehdr[13] = (uint8_t)(ethertype & 0xff);

    if (mbuf_copyback(m, 0, 14, ehdr, MBUF_WAITOK) != 0 ||
        (paylen && mbuf_copyback(m, 14, paylen, payload, MBUF_WAITOK) != 0)) {
        mbuf_freem(m);
        return;
    }
    _parent->injectRxFrame(m);
}

/* Split an A-MSDU payload into its constituent MSDUs and deliver each. */
void RTW88IEEE80211::deAmsdu(const uint8_t *data, uint32_t len)
{
    uint32_t pos = 0;
    /* A-MSDU injection (FragAttacks, CVE-2020-24588): a plain frame whose
     * A-MSDU bit was flipped starts with its LLC/SNAP header where the first
     * subframe DA belongs. mac80211 rejects this DA; do the same. */
    static const uint8_t rfc1042[6] = { 0xAA, 0xAA, 0x03, 0x00, 0x00, 0x00 };
    if (len >= 6 && memcmp(data, rfc1042, 6) == 0) {
        uint32_t n = ++_rxAmsduSpoofDropped;
        if ((n & (n - 1)) == 0)
            IOLog("rtw88: RX A-MSDU with LLC/SNAP first DA dropped count=%u\n", n);
        return;
    }
    /* Subframe: DA(6) SA(6) Length(2, big-endian) | MSDU(Length) | pad to a
     * 4-byte boundary (the last subframe is not padded). */
    while (pos + 14 <= len) {
        const uint8_t *sf = data + pos;
        uint16_t sublen = (uint16_t)((sf[12] << 8) | sf[13]);
        if (sublen < 8 || pos + 14 + sublen > len)
            break;   /* truncated / malformed */
        const uint8_t *msdu = sf + 14;
        if (msdu[0] == 0xAA && msdu[1] == 0xAA && msdu[2] == 0x03) {
            uint16_t ethertype = (uint16_t)((msdu[6] << 8) | msdu[7]);
            deliverEthernet(sf, sf + 6, ethertype, msdu + 8, sublen - 8);
        }
        pos += (14u + sublen + 3u) & ~3u;   /* next subframe (4-byte aligned) */
    }
}

/* ------------------------------------------------------------------ */
/*  RX A-MPDU reorder buffer                                            */
/* ------------------------------------------------------------------ */

void RTW88IEEE80211::rxBaSetup(uint8_t tid, uint16_t ssn, uint16_t bufsize)
{
    if (tid >= kRxBaNumTid) return;
    if (bufsize == 0 || bufsize > kRxBaMaxBuf) bufsize = kRxBaMaxBuf;

    IOLockLock(_rxBaLock);
    RxReorder *r = _rxBa[tid];
    if (!r) {
        r = (RxReorder *)IOMallocZero(sizeof(RxReorder));
        _rxBa[tid] = r;
    } else {
        for (uint32_t i = 0; i < kRxBaMaxBuf; i++)
            if (r->buf[i]) { kfree_skb(r->buf[i]); r->buf[i] = nullptr; }
    }
    if (r) {
        r->active  = true;
        r->headSn  = (uint16_t)(ssn & 0xFFF);
        r->bufSize = bufsize;
        r->stored  = 0;
    }
    IOLockUnlock(_rxBaLock);
}

void RTW88IEEE80211::rxBaTeardown(uint8_t tid)
{
    if (tid >= kRxBaNumTid) return;
    struct sk_buff *freelist[kRxBaMaxBuf];
    uint32_t nf = 0;

    IOLockLock(_rxBaLock);
    RxReorder *r = _rxBa[tid];
    if (r) {
        for (uint32_t i = 0; i < kRxBaMaxBuf; i++)
            if (r->buf[i]) { freelist[nf++] = r->buf[i]; r->buf[i] = nullptr; }
        _rxBa[tid] = nullptr;
    }
    IOLockUnlock(_rxBaLock);

    if (r) {
        IOFree(r, sizeof(RxReorder));
        for (uint32_t i = 0; i < nf; i++)
            kfree_skb(freelist[i]);
    }
}

void RTW88IEEE80211::rxBaTeardownAll()
{
    for (uint8_t tid = 0; tid < kRxBaNumTid; tid++)
        rxBaTeardown(tid);
    /* Deliberately do NOT cancel _reorderTimer here: teardown can run on a
     * different workloop than the timer, and a stray fire is harmless (it finds
     * every TID inactive/empty and does nothing). */
}

void RTW88IEEE80211::rxReorderInput(uint8_t tid, struct sk_buff *skb, uint16_t sn)
{
    struct sk_buff *out[kRxBaMaxBuf];
    uint32_t nout = 0;
    bool needTimer = false;

    IOLockLock(_rxBaLock);
    RxReorder *r = _rxBa[tid];
    if (!r || !r->active) {            /* torn down between dispatch and here */
        IOLockUnlock(_rxBaLock);
        deliverDataFrame(skb);
        return;
    }

    uint16_t rel = (uint16_t)((sn - r->headSn) & 0xFFF);
    if (rel >= 2048) {                 /* before the window: stale / duplicate */
        IOLockUnlock(_rxBaLock);
        kfree_skb(skb);
        return;
    }

    if (rel >= r->bufSize) {
        /* sn is ahead of the window — slide the window up, releasing buffered
         * frames that fall out the bottom (in order; missing ones are lost). */
        uint16_t newHead = (uint16_t)((sn + 1 - r->bufSize) & 0xFFF);
        while (((newHead - r->headSn) & 0xFFF) != 0 &&
               ((newHead - r->headSn) & 0xFFF) < 2048 && nout < kRxBaMaxBuf) {
            uint16_t hidx = r->headSn % kRxBaMaxBuf;
            if (r->buf[hidx]) {
                out[nout++] = r->buf[hidx];
                r->buf[hidx] = nullptr;
                r->stored--;
            }
            r->headSn = (uint16_t)((r->headSn + 1) & 0xFFF);
        }
    }

    uint16_t idx = sn % kRxBaMaxBuf;
    if (r->buf[idx]) {                 /* duplicate within the window */
        kfree_skb(skb);
    } else {
        r->buf[idx] = skb;
        r->stored++;
    }

    /* Release the in-order run starting at head. */
    while (r->stored > 0 && nout < kRxBaMaxBuf) {
        uint16_t hidx = r->headSn % kRxBaMaxBuf;
        if (!r->buf[hidx]) break;
        out[nout++] = r->buf[hidx];
        r->buf[hidx] = nullptr;
        r->stored--;
        r->headSn = (uint16_t)((r->headSn + 1) & 0xFFF);
    }
    needTimer = (r->stored > 0);
    IOLockUnlock(_rxBaLock);

    for (uint32_t i = 0; i < nout; i++)
        deliverDataFrame(out[i]);

    if (needTimer)
        rxReorderArmTimer();
}

void RTW88IEEE80211::rxReorderArmTimer()
{
    /* Preserve the outstanding deadline. Re-arming on every incoming frame
     * can starve delivery indefinitely while a sequence-number hole exists.
     * Both callers and the callback execute on the RX workloop. */
    if (_reorderTimer && !_reorderTimerArmed) {
        _reorderTimerArmed = true;
        _reorderTimer->setTimeoutMS(kReorderTimeoutMs);
    }
}

/* Timer: a hole has persisted past the reorder timeout (the missing frame is
 * not coming).  Force progress by releasing past the first hole on each TID. */
void RTW88IEEE80211::rxReorderFlushStale()
{
    struct sk_buff *out[kRxBaMaxBuf];
    uint32_t nout = 0;
    bool again = false;

    IOLockLock(_rxBaLock);
    for (uint8_t tid = 0; tid < kRxBaNumTid; tid++) {
        RxReorder *r = _rxBa[tid];
        if (!r || !r->active || r->stored == 0) continue;

        /* Skip leading holes (lost frames), then release the next run. */
        uint32_t guard = 0;
        while (r->stored > 0 && guard < 4096) {
            uint16_t hidx = r->headSn % kRxBaMaxBuf;
            if (r->buf[hidx]) break;
            r->headSn = (uint16_t)((r->headSn + 1) & 0xFFF);
            guard++;
        }
        while (r->stored > 0 && nout < kRxBaMaxBuf) {
            uint16_t hidx = r->headSn % kRxBaMaxBuf;
            if (!r->buf[hidx]) break;
            out[nout++] = r->buf[hidx];
            r->buf[hidx] = nullptr;
            r->stored--;
            r->headSn = (uint16_t)((r->headSn + 1) & 0xFFF);
        }
        if (r->stored > 0) again = true;
    }
    IOLockUnlock(_rxBaLock);

    for (uint32_t i = 0; i < nout; i++)
        deliverDataFrame(out[i]);

    if (again)
        rxReorderArmTimer();
}

void RTW88IEEE80211::reorderTimerFired(OSObject *owner, IOTimerEventSource *)
{
    RTW88IEEE80211 *self = OSDynamicCast(RTW88IEEE80211, owner);
    if (self) {
        self->_reorderTimerArmed = false;
        self->rxReorderFlushStale();
    }
}

/* ------------------------------------------------------------------ */
/*  TX status                                                           */
/* ------------------------------------------------------------------ */

void RTW88IEEE80211::txStatus(struct sk_buff *skb)
{
    struct ieee80211_tx_info *info = IEEE80211_SKB_CB(skb);
    const bool transmitted =
        (info->flags & (IEEE80211_TX_STAT_ACK |
                        IEEE80211_TX_STAT_NOACK_TRANSMITTED)) != 0;
    rtw88_skb_tx_completion_report(&skb->tx_completion, transmitted);
    if (!(info->flags & IEEE80211_TX_CTL_REQ_TX_STATUS))
        return;

    const char *frameName = "frame";
    if (skb->len >= sizeof(struct ieee80211_hdr_3addr)) {
        struct ieee80211_hdr *hdr = (struct ieee80211_hdr *)skb->data;
        uint16_t fc = le16_to_cpu(hdr->frame_control);

        if ((fc & IEEE80211_FCTL_FTYPE) == IEEE80211_FTYPE_MGMT) {
            switch (fc & IEEE80211_FCTL_STYPE) {
            case IEEE80211_STYPE_AUTH:       frameName = "authentication"; break;
            case IEEE80211_STYPE_ASSOC_REQ:  frameName = "association request"; break;
            case IEEE80211_STYPE_DEAUTH:     frameName = "deauthentication"; break;
            case IEEE80211_STYPE_ACTION:     frameName = "action"; break;
            default:                         frameName = "management"; break;
            }
        } else if ((fc & IEEE80211_FCTL_FTYPE) == IEEE80211_FTYPE_DATA) {
            uint16_t hdrlen = ieee80211_get_hdrlen_from_skb(skb);
            if (skb->len >= hdrlen + 8) {
                const uint8_t *llc = skb->data + hdrlen;
                uint16_t ethertype = (uint16_t)((llc[6] << 8) | llc[7]);
                if (llc[0] == 0xaa && llc[1] == 0xaa && llc[2] == 0x03 &&
                    ethertype == ETH_P_PAE && skb->len >= hdrlen + 8 + 99) {
                    /* Pairwise M2 carries the RSN IE; M4 has no key data. The
                     * Secure bit cannot distinguish them during a rekey. */
                    const uint8_t *eapol = llc + 8;
                    uint16_t keyDataLen = (uint16_t)((eapol[97] << 8) | eapol[98]);
                    uint16_t keyInfo = (uint16_t)((eapol[5] << 8) | eapol[6]);
                    frameName = !(keyInfo & 0x0008) ? "EAPOL group M2" :
                                keyDataLen ? "EAPOL M2" : "EAPOL M4";
                } else if (fc & IEEE80211_FCTL_PROTECTED) {
                    /* Only management and EAPOL request status, so a protected
                     * data frame here is an encrypted EAPOL during rekey. */
                    frameName = "protected EAPOL";
                } else {
                    frameName = "data";
                }
            }
        }
    }

    IOLog("rtw88: TX status %s: %s\n", frameName,
          (info->flags & IEEE80211_TX_STAT_ACK) ? "ACK" : "NO ACK");
}

/*
 * Pick the operating channel width for the connection and program it into
 * hw->conf.chandef (consumed by rtw_set_channel via connect_hw_setup).
 *
 * We parse the AP's HT Operation (EID 61) and VHT Operation (EID 192) from the
 * cached beacon IEs to learn the BSS width, then cap to what the chip supports
 * (from its band caps).  Without this the link is pinned to 20 MHz — e.g. an
 * 80 MHz VHT AP gives 173 Mbps (20 MHz MCS8) instead of 866 Mbps (80 MHz MCS9).
 * TKIP links stay 20 MHz (HT disallowed — see htAllowed()).
 */
void RTW88IEEE80211::parseBssOperation(const uint8_t *ies, uint16_t ielen, RTW88BssOperation *op)
{
    op->sco = 0;
    op->htStaWidth = false;
    op->vhtWidth = 0;
    op->vhtSeg0 = 0;
    for (uint16_t i = 0; i + 2 <= ielen; ) {
        uint8_t id = ies[i], len = ies[i + 1];
        if ((uint32_t)i + 2 + len > ielen) break;
        const uint8_t *d = ies + i + 2;
        if (id == WLAN_EID_HT_OPERATION && len >= 2) {
            op->sco        = d[1] & 0x03;
            op->htStaWidth = (d[1] & 0x04) != 0;
        } else if (id == WLAN_EID_VHT_OPERATION && len >= 3) {
            op->vhtWidth = d[0];
            op->vhtSeg0  = d[1];
        }
        i += 2 + len;
    }
}

void RTW88IEEE80211::setConnectedChandef(
    struct ieee80211_channel *chan,
    RTW88TxStateGate::MutationLease *existingMutation)
{
    RTW88TxStateGate::MutationLease localMutation;
    if (!existingMutation) {
        localMutation = beginTxStateMutation();
    } else if (!*existingMutation) {
        return;
    }

    _hw->conf.chandef.chan         = chan;
    _hw->conf.chandef.width        = NL80211_CHAN_WIDTH_20_NOHT;
    _hw->conf.chandef.center_freq1 = chan->center_freq;
    _connChanWidth = 20;

    if (!htAllowed())
        return;

    enum nl80211_band bnd =
        (_targetBSS.channel > 14) ? NL80211_BAND_5GHZ : NL80211_BAND_2GHZ;
    struct ieee80211_supported_band *sb =
        (_hw->wiphy) ? _hw->wiphy->bands[bnd] : nullptr;
    if (!sb) return;

    bool chip40 = (sb->ht_cap.cap & IEEE80211_HT_CAP_SUP_WIDTH_20_40) != 0;
    bool chip80 = chip40 && bnd == NL80211_BAND_5GHZ && sb->vht_cap.vht_supported;

    RTW88BssOperation op;
    parseBssOperation(_targetBSS.ies, _targetBSS.ies_len, &op);
    const int sco = op.sco;
    const bool htStaWidth = op.htStaWidth;
    const int vhtWidth = op.vhtWidth;
    const uint8_t vhtSeg0 = op.vhtSeg0;

    if (chip40 && htStaWidth && (sco == 1 || sco == 3)) {
        _connChanWidth = 40;
        _hw->conf.chandef.width = NL80211_CHAN_WIDTH_40;
        _hw->conf.chandef.center_freq1 =
            (uint32_t)((int)chan->center_freq + (sco == 1 ? 10 : -10));
    }

    if (chip80 && vhtWidth == 1 && vhtSeg0 != 0) {
        _connChanWidth = 80;
        _hw->conf.chandef.width = NL80211_CHAN_WIDTH_80;
        _hw->conf.chandef.center_freq1 = (uint32_t)(5000 + 5 * vhtSeg0);
    }
}

/* ------------------------------------------------------------------ */
/*  Scan                                                                */
/* ------------------------------------------------------------------ */

void RTW88IEEE80211::restoreConnectedChannel()
{
    auto mutation = beginTxStateMutation();
    if (__atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) != RTW88_STATE_CONNECTED || !_hw || !_vif) {
        mutation.finish();
        return;
    }

    struct ieee80211_channel *chan = nullptr;
    for (int b = 0; b < NL80211_NUM_BANDS && !chan; b++) {
        struct ieee80211_supported_band *band =
            (_hw->wiphy) ? _hw->wiphy->bands[b] : nullptr;
        if (!band) continue;
        for (int j = 0; j < band->n_channels; j++) {
            if (band->channels[j].hw_value == _targetBSS.channel) {
                chan = &band->channels[j];
                chan->band = band->band;
                break;
            }
        }
    }

    if (chan) {
        setConnectedChandef(chan, &mutation);
    } else {
        IOLog("rtw88: scan restore: ch=%u not in band table\n",
              _targetBSS.channel);
    }

    rtw88_restore_connected_hw(_hw, _vif, _targetBSS.bssid);

    struct ieee80211_bss_conf *bss = &_vif->bss_conf;
    bss->bssid = bss->bssid_buf;
    memcpy(bss->bssid_buf, _targetBSS.bssid, ETH_ALEN);
    bss->assoc = true;
    bss->aid   = _assocAID;
    _vif->cfg.assoc = true;
    _vif->cfg.aid   = _assocAID;
    mutation.finish();
}

bool RTW88IEEE80211::abortActiveScan(bool waitForIdle)
{
    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_SCANNING)
        return true;

    RTW88State returnState = __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE);
    if (__atomic_load_n(&_manualScanChannelCount, __ATOMIC_ACQUIRE)) {
        _manualScanAbort = true;
    } else if (_hw && _hw->ops && _hw->ops->cancel_hw_scan) {
        _hw->ops->cancel_hw_scan(_hw, _vif);
    }

    if (!waitForIdle)
        return true;

    for (int i = 0; i < 40 && __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING; i++)
        IOSleep(50);

    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING) {
        if (__atomic_load_n(&_manualScanChannelCount, __ATOMIC_ACQUIRE))
            return false;
        if (returnState == RTW88_STATE_CONNECTED)
            restoreConnectedChannel();
        setRadioState((returnState == RTW88_STATE_IDLE) ?
            RTW88_STATE_IDLE : returnState);
        __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        _scanPartial = false;
        __atomic_store_n(&_manualScanChannelCount, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&_manualScanOnHomeChannel, false, __ATOMIC_RELEASE);
    }

    return __atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_SCANNING;
}

void RTW88IEEE80211::scanDone(bool aborted)
{
    // A late firmware completion after timeout must not finish a new join.
    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_SCANNING) return;
    if (_timer) _timer->cancelTimeout();
    const bool partialScan = _scanPartial;
    if (!aborted && !partialScan) {
        IOLockLock(_bssLock);
        RTW88BSS **link = &_bssList;
        while (*link) {
            RTW88BSS *b = *link;
            RTW88State effectiveState =
                (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING) ? __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) : __atomic_load_n(&_state, __ATOMIC_ACQUIRE);
            bool isTarget = (effectiveState == RTW88_STATE_CONNECTED ||
                             effectiveState == RTW88_STATE_HANDSHAKING) &&
                            memcmp(b->bssid, _targetBSS.bssid, 6) == 0;
            uint32_t age = _scanGeneration - b->last_seen_scan;

            if (!isTarget && age > 3) {
                *link = b->next;
                IOFree(b, sizeof(*b));
                if (_bssCount)
                    _bssCount--;
                continue;
            }

            link = &b->next;
        }
        IOLockUnlock(_bssLock);
    }

    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING) {
        RTW88State returnState = __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE);
        /* Restore the infrastructure channel for every connected scan, not
         * only the manual fallback.  This keeps STA coherent if hw_scan is
         * available on another RTL88xx backend later. */
        if (returnState == RTW88_STATE_CONNECTED) {
            restoreConnectedChannel();
            txNullFunc(false);
        }
        setRadioState((returnState == RTW88_STATE_IDLE) ?
            RTW88_STATE_IDLE : returnState);
        __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        __atomic_store_n(&_manualScanOnHomeChannel, false, __ATOMIC_RELEASE);
        _scanPartial = false;

        /* A background CoreWiFi scan can leave an unassociated radio on its
         * final scan channel. If AWDL owns the idle PHY, return it to the AWDL
         * home/master channel before notifying IO80211 that scan completed. */
        if (returnState == RTW88_STATE_IDLE && _awdlReceiveMode && _awdlChannel) {
            IOReturn awdlRestore = setAWDLChannel(_awdlChannel);
            if (awdlRestore != kIOReturnSuccess)
                IOLog("rtw88: AWDL channel restore after scan failed 0x%x\n", awdlRestore);
        }
    }

    if (_powered && _awdlReceiveMode)
        (void)setAWDLReceiveMode(true); // scan completion reinstates BSSID filtering

    IOLockLock(_bssLock);
    _lastScanCacheCount = _bssCount;
    IOLockUnlock(_bssLock);

    /* Complete the Apple scan transaction first.  If ASSOCIATE arrived while
     * scanning, start that already-accepted join immediately afterwards. */
    if (_delegate) {
        UInt32 result = aborted ? 1 : 0;
        _delegate->rtw88Event(kRTW88EventScanDone, &result);
    }

    if (_deferredConnectPending && __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_IDLE && _powered) {
        char ssid[sizeof(_deferredSSID)] = {};
        char password[sizeof(_deferredPassword)] = {};
        uint8_t pmk[sizeof(_deferredPMK)] = {};
        uint8_t bssid[sizeof(_deferredBSSID)] = {};
        strlcpy(ssid, _deferredSSID, sizeof(ssid));
        strlcpy(password, _deferredPassword, sizeof(password));
        memcpy(pmk, _deferredPMK, sizeof(pmk));
        memcpy(bssid, _deferredBSSID, sizeof(bssid));
        const bool pmkValid = _deferredPMKValid;
        const bool bssidValid = _deferredBSSIDValid;
        const bool externalSupplicant = _deferredExternalSupplicant;

        _deferredConnectPending = false;
        _deferredPMKValid = false;
        _deferredBSSIDValid = false;
        bzero(_deferredSSID, sizeof(_deferredSSID));
        bzero(_deferredPassword, sizeof(_deferredPassword));
        bzero(_deferredPMK, sizeof(_deferredPMK));
        bzero(_deferredBSSID, sizeof(_deferredBSSID));

        IOReturn joinRet = cmdConnect(ssid, password[0] ? password : nullptr,
                                      pmkValid ? pmk : nullptr,
                                      bssidValid ? bssid : nullptr,
                                      externalSupplicant);
        IOLog("rtw88: deferred ASSOCIATE after scan ret=0x%x ssid=%s\n",
              joinRet, ssid);
        bzero(pmk, sizeof(pmk));
        bzero(password, sizeof(password));
        if (joinRet != kIOReturnSuccess) failJoin("deferred-connect");
    }
}

IOReturn RTW88IEEE80211::cmdAbortScan()
{
    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_SCANNING)
        return kIOReturnSuccess;
    return abortActiveScan(true) ? kIOReturnSuccess : kIOReturnBusy;
}

IOReturn RTW88IEEE80211::cmdScan(const uint16_t *requestedChannels,
                                  uint32_t requestedCount)
{
    {
        auto mutation = beginTxStateMutation();
        _awdlPreparedChannel = 0;
        mutation.finish();
    }
    const bool connectedScan = (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED);
    /* Associated scans are supported only through the bounded software scanner
     * below.  Authentication/association/disconnect transitions remain busy. */
    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_IDLE && !connectedScan) {
        IOLog("rtw88: physical scan busy state=%u\n", (unsigned)__atomic_load_n(&_state, __ATOMIC_ACQUIRE));
        return kIOReturnBusy;
    }
    if (!_powered || !_hw || !_hw->ops || !_hw->wiphy)
        return kIOReturnNotReady;
    if (requestedCount > 128)
        requestedCount = 128;

    uint16_t meshChannels[RTW88RoamScan::kMaxMeshChannels] = {};
    uint32_t meshChannelCount = 0;
    if (connectedScan) {
        const uint16_t homeChannel = _targetBSS.channel;
        /* Prioritize channels on which this ESS was previously observed.  A
         * partial scan can refresh a known mesh BSSID without roaming blindly
         * through the entire band. */
        IOLockLock(_bssLock);
        for (RTW88BSS *b = _bssList;
             b && meshChannelCount < RTW88RoamScan::kMaxMeshChannels;
             b = b->next) {
            if (b->ssid_len != _targetBSS.ssid_len ||
                memcmp(b->ssid, _targetBSS.ssid, _targetBSS.ssid_len) != 0 ||
                memcmp(b->bssid, _targetBSS.bssid, sizeof(b->bssid)) == 0 ||
                (((b->capabilities & 0x10) != 0) !=
                 ((_targetBSS.capabilities & 0x10) != 0)))
                continue;
            const uint32_t age = _scanGeneration - b->last_seen_scan;
            if (age > 3 ||
                !RTW88RoamScan::requestedContains(requestedChannels,
                                                   requestedCount, b->channel))
                continue;
            (void)RTW88RoamScan::appendUnique(meshChannels, &meshChannelCount,
                                               RTW88RoamScan::kMaxMeshChannels,
                                               b->channel, homeChannel);
        }
        IOLockUnlock(_bssLock);

        /* CoreWiFi sometimes supplies channel hints without a BSS result on
         * those channels yet.  Use remaining budget to discover a newly-added
         * mesh node, but never exceed the eight-channel off-channel budget. */
        for (uint32_t i = 0; requestedChannels && i < requestedCount &&
             meshChannelCount < RTW88RoamScan::kMaxMeshChannels; ++i) {
            (void)RTW88RoamScan::appendUnique(meshChannels, &meshChannelCount,
                                               RTW88RoamScan::kMaxMeshChannels,
                                               requestedChannels[i], homeChannel);
        }
        if (meshChannelCount == 0) {
            IOLog("rtw88: connected scan skipped: no alternate ESS channels cached or requested\n");
            return kIOReturnNotReady;
        }
    }

    const RTW88State returnState = __atomic_load_n(&_state, __ATOMIC_ACQUIRE);
    _scanPartial = connectedScan;
    if (!connectedScan) {
        IOLockLock(_bssLock);
        _scanGeneration++;
        if (_scanGeneration == 0) {
            _scanGeneration = 1;
            for (RTW88BSS *b = _bssList; b; b = b->next)
                b->last_seen_scan = 1;
        }
        IOLockUnlock(_bssLock);
    }

    IOLog("rtw88: scan start returnState=%u connected=%u partial=%u\n",
          (unsigned)returnState, connectedScan ? 1U : 0U,
          _scanPartial ? 1U : 0U);
    __atomic_store_n(&_scanReturnState, connectedScan ? RTW88_STATE_CONNECTED : RTW88_STATE_IDLE, __ATOMIC_RELEASE);
    setRadioState(RTW88_STATE_SCANNING);

    // Firmware retains the request until completion; neither object may live on the stack.
    if (!_scanRequest)
        _scanRequest = (ieee80211_scan_request *)IOMallocZero(sizeof(*_scanRequest));
    if (!_scanRequest) {
        setRadioState(returnState);
        __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        _scanPartial = false;
        return kIOReturnNoMemory;
    }
    bzero(_scanRequest, sizeof(*_scanRequest));
    auto &req = *_scanRequest;
    auto *chans = _scanRequestChannels;
    int n_chans = 0;

    if (connectedScan) {
        /* Preserve candidate-channel order from the ESS cache/request list and
         * map only to channels enabled by this regulatory domain. */
        for (uint32_t i = 0; i < meshChannelCount; ++i) {
            bool found = false;
            for (int bandIndex = 0; bandIndex < NL80211_NUM_BANDS && !found; ++bandIndex) {
                struct ieee80211_supported_band *band = _hw->wiphy->bands[bandIndex];
                if (!band) continue;
                for (int j = 0; j < band->n_channels; ++j) {
                    struct ieee80211_channel *channel = &band->channels[j];
                    if (channel->hw_value != meshChannels[i] ||
                        (channel->flags & IEEE80211_CHAN_DISABLED))
                        continue;
                    channel->band = band->band;
                    chans[n_chans++] = channel;
                    found = true;
                    break;
                }
            }
        }
    } else {
        for (int i = 0; i < NL80211_NUM_BANDS; i++) {
            struct ieee80211_supported_band *band = _hw->wiphy->bands[i];
            if (!band) continue;
            for (int j = 0; j < band->n_channels; j++) {
                if (n_chans < 256 &&
                    !(band->channels[j].flags & IEEE80211_CHAN_DISABLED)) {
                    band->channels[j].band = band->band;
                    chans[n_chans++] = &band->channels[j];
                }
            }
        }
    }

    if (n_chans == 0) {
        IOLog("rtw88: scan has no enabled channels\n");
        setRadioState(returnState);
        __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        _scanPartial = false;
        return kIOReturnNotReady;
    }

    const bool firmwareScan = !connectedScan && _hw->ops->hw_scan &&
                              rtw88_hw_scan_supported(_hw);
    _scanEngine = connectedScan ? "software-connected" :
                  (firmwareScan ? "firmware" : "software");
    _lastScanChannelCount = (uint32_t)n_chans;
    _scanVisited2GHz = _scanVisited5GHz = 0;
    if (!firmwareScan) {
        if (!_manualScanTC) {
            setRadioState(returnState);
            __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
            _scanPartial = false;
            return kIOReturnNotReady;
        }

        __atomic_store_n(&_manualScanChannelCount, (uint32_t)n_chans, __ATOMIC_RELEASE);
        for (int i = 0; i < n_chans; i++)
            _manualScanChannels[i] = chans[i];
        _manualScanAbort = false;
        __atomic_store_n(&_manualScanOnHomeChannel, false, __ATOMIC_RELEASE);
        _rxFrameCount = 0;

        if (!_manualScanFallbackLogged || connectedScan) {
            IOLog("rtw88: %s scan using bounded software channel scan (%d channels)\n",
                  connectedScan ? "connected" : "disconnected", n_chans);
            _manualScanFallbackLogged = true;
        }
        thread_call_enter(_manualScanTC);

        _timeoutMs = connectedScan ? 30000 : 12000;
        uint64_t d;
        clock_interval_to_deadline(_timeoutMs, kMillisecondScale, &d);
        _timer->wakeAtTime(d);
        return kIOReturnSuccess;
    }

    req.req.channels = chans;
    req.req.n_channels = n_chans;
    _rxFrameCount = 0;

    int hw_scan_ret = _hw->ops->hw_scan(_hw, _vif, &req);
    if (hw_scan_ret != 0) {
        IOLog("rtw88: hw_scan returned %d -- falling back to passive scan\n",
              hw_scan_ret);
        if (_manualScanTC) {
            _scanEngine = "software-after-fw-error";
            __atomic_store_n(&_manualScanChannelCount, (uint32_t)n_chans, __ATOMIC_RELEASE);
            for (int i = 0; i < n_chans; i++)
                _manualScanChannels[i] = chans[i];
            _manualScanAbort = false;
            __atomic_store_n(&_manualScanOnHomeChannel, false, __ATOMIC_RELEASE);
            _rxFrameCount = 0;
            thread_call_enter(_manualScanTC);

            _timeoutMs = 12000;
            uint64_t d;
            clock_interval_to_deadline(_timeoutMs, kMillisecondScale, &d);
            _timer->wakeAtTime(d);
            return kIOReturnSuccess;
        }
        setRadioState(returnState);
        __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        _scanPartial = false;
        return kIOReturnError;
    }
    /* Timeout: if firmware scan doesn't complete in 10s. */
    _timeoutMs = 10000;
    uint64_t d;
    clock_interval_to_deadline(_timeoutMs, kMillisecondScale, &d);
    _timer->wakeAtTime(d);
    return kIOReturnSuccess;
}

void RTW88IEEE80211::manualScanTCFn(thread_call_param_t self, thread_call_param_t)
{
    ((RTW88IEEE80211 *)self)->runManualScan();
}

void RTW88IEEE80211::runManualScan()
{
    if (!_hw || !_vif) {
        scanDone(true);
        __atomic_store_n(&_manualScanChannelCount, 0, __ATOMIC_RELEASE);
        return;
    }

    uint32_t count = __atomic_load_n(&_manualScanChannelCount, __ATOMIC_ACQUIRE);
    if (count > 256)
        count = 256;
    bool connectedScan = (__atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED);

    rtw88_sw_scan_start(_hw, _vif);

    for (uint32_t i = 0; i < count && !_manualScanAbort; i++) {
        struct ieee80211_channel *chan = _manualScanChannels[i];
        if (!chan)
            continue;

        __atomic_store_n(&_manualScanOnHomeChannel, false, __ATOMIC_RELEASE);

        if (connectedScan) {
            restoreConnectedChannel();
            txNullFunc(true);
            IOSleep(10);
        }

        {
            auto mutation = beginTxStateMutation();
            if (!_powered || !_hw || !_vif || _manualScanAbort) {
                mutation.finish();
                break;
            }
            _hw->conf.chandef.chan = chan;
            _hw->conf.chandef.width = NL80211_CHAN_WIDTH_20_NOHT;
            _hw->conf.chandef.center_freq1 = chan->center_freq;
            rtw88_sw_scan_switch_channel(_hw);
            mutation.finish();
        }

        bool passiveOnly = (chan->flags &
            (IEEE80211_CHAN_NO_IR | IEEE80211_CHAN_RADAR)) != 0;
        if (!passiveOnly)
            txProbeRequest();

        /* Active channels can use a short probe dwell. Passive/DFS channels
         * still need a beacon-listen dwell. */
        IOSleep(connectedScan ? (passiveOnly ? 140 : 35) :
                (passiveOnly ? 140 : 70));
        /* Software dwell completed; this is not proof of successful RF RX. */
        if (chan->band == NL80211_BAND_5GHZ) ++_scanVisited5GHz;
        else if (chan->band == NL80211_BAND_2GHZ) ++_scanVisited2GHz;

        if (connectedScan && !_manualScanAbort) {
            restoreConnectedChannel();
            txNullFunc(false);
            __atomic_store_n(&_manualScanOnHomeChannel, true, __ATOMIC_RELEASE);
            IOSleep(80);
        }
    }

    __atomic_store_n(&_manualScanOnHomeChannel, false, __ATOMIC_RELEASE);
    rtw88_sw_scan_complete(_hw, _vif);
    /* Clear this worker's ownership before scanDone: its deferred-join callback
     * may immediately start a fresh scan.  Clearing these fields afterwards
     * would erase the next scan's channel list / abort state. */
    const bool aborted = _manualScanAbort;
    _manualScanAbort = false;
    __atomic_store_n(&_manualScanChannelCount, 0, __ATOMIC_RELEASE);

    /* scanDone restores/calibrates the home channel and clears AP power-save
     * once, including an aborted scan, before notifying IO80211. */
    scanDone(aborted);
}

/* ------------------------------------------------------------------ */
/*  Connect                                                             */
/* ------------------------------------------------------------------ */

/* ------------------------------------------------------------------ */
/*  1.0.2 multi-BSS (mesh) join selection and fallback                  */
/* ------------------------------------------------------------------ */

static uint64_t rtw88JoinNowUS()
{
    uint64_t ns = 0;
    absolutetime_to_nanoseconds(mach_absolute_time(), &ns);
    return ns / 1000ULL;
}

/* Best BSS for an SSID: strongest and freshest, recently failed nodes last
 * (see RTW88JoinPolicy.hpp).  pinned: only that BSSID.  skipTried: ignore
 * nodes already attempted in this join.  privacyMatch: -1 any, 0 open only,
 * 1 protected only.  Ties keep list order.  Caller holds _bssLock. */
RTW88BSS *RTW88IEEE80211::selectBssLocked(const char *ssid, size_t ssidLen,
                                          const uint8_t *pinned, bool skipTried,
                                          int privacyMatch)
{
    const uint64_t now = rtw88JoinNowUS();
    RTW88BSS *best = nullptr;
    int bestScore = 0;
    for (RTW88BSS *b = _bssList; b; b = b->next) {
        if (b->ssid_len != ssidLen || memcmp(b->ssid, ssid, ssidLen) != 0) continue;
        if (pinned && memcmp(b->bssid, pinned, 6) != 0) continue;
        if (skipTried && _joinTried.contains(b->bssid)) continue;
        if (privacyMatch >= 0 && (((b->capabilities & 0x10) != 0) != (privacyMatch != 0))) continue;
        const int sc = RTW88Join::score(b->rssi, b->channel,
                                        _scanGeneration - b->last_seen_scan,
                                        _joinFail.blocked(b->bssid, now));
        if (!best || sc > bestScore) { best = b; bestScore = sc; }
    }
    return best;
}

/* Pick the BSS for a join request.  Caller holds _bssLock.  A BSSID macOS
 * named is honoured exactly when it is known; cmdConnect performs one full
 * cache refresh before reporting a still-missing BSSID.  The one exception,
 * 1.0.4: if that node is on 2.4 GHz, a same-SSID/security 5 GHz sibling may be
 * selected only when it is fresh, at least -72 dBm, not recently failed, and
 * its score is better.  The requested BSSID is remembered so
 * that a repeated request for it, while this join is in progress, is treated as
 * the same join (see matchesPendingJoin()) rather than restarting it. */
RTW88BSS *RTW88IEEE80211::selectBssForJoinLocked(const char *ssid, size_t ssidLen,
                                                 const uint8_t *pinned, bool *upgraded)
{
    *upgraded = false;
    _joinHasRequested = false;
    RTW88BSS *target = selectBssLocked(ssid, ssidLen, pinned, false, -1);
    if (target && pinned && target->channel <= 14 && _prefer5GHzUpgrade) {
        const uint64_t now = rtw88JoinNowUS();
        const int targetScore = RTW88Join::score(
            target->rssi, target->channel,
            _scanGeneration - target->last_seen_scan,
            _joinFail.blocked(target->bssid, now));
        RTW88BSS *best5 = nullptr;
        int best5Score = targetScore;
        for (RTW88BSS *b = _bssList; b; b = b->next) {
            if (b->ssid_len != ssidLen || memcmp(b->ssid, ssid, ssidLen) != 0 ||
                b->channel <= 14 ||
                (((b->capabilities & 0x10) != 0) !=
                 ((target->capabilities & 0x10) != 0)))
                continue;
            const uint32_t age = _scanGeneration - b->last_seen_scan;
            if (age > 1 || b->rssi < RTW88Join::kUsable5GHzDbm ||
                _joinFail.blocked(b->bssid, now))
                continue;
            const int candidateScore = RTW88Join::score(b->rssi, b->channel,
                                                         age, false);
            if (candidateScore > best5Score) {
                best5 = b;
                best5Score = candidateScore;
            }
        }
        if (best5) {
            memcpy(_joinRequestedBssid, pinned, 6);
            _joinHasRequested = true;
            *upgraded = true;
            return best5;
        }
    }
    return target;
}

/* Is there another node of the current SSID we have not tried yet?  Caller
 * holds _bssLock. */
bool RTW88IEEE80211::hasUntriedAlternativeLocked()
{
    if (_joinTried.count >= RTW88Join::kMaxNodesPerJoin) return false;
    const int privacy = (_targetBSS.capabilities & 0x10) ? 1 : 0;
    return selectBssLocked(_targetBSS.ssid, _targetBSS.ssid_len, nullptr, true, privacy) != nullptr;
}

/* If macOS supplied an association RSN IE that selects CCMP-PSK, that is
 * authoritative for this attempt even when the lightweight beacon parser
 * missed or simplified the AP's AKM/cipher list.  Shared by cmdConnect() and
 * the fallback to another node, which replaces _targetBSS wholesale. */
void RTW88IEEE80211::applyAssocRsnOverride(bool externalSupplicant, bool havePmk, bool havePassword)
{
    if ((externalSupplicant || havePmk || havePassword) && _assocRsnIELen >= 4 &&
        _assocRsnIE[0] == WLAN_EID_RSN &&
        (uint16_t)(_assocRsnIE[1] + 2) <= _assocRsnIELen) {
        uint32_t pairwise = 0, group = 0;
        bool hasSae = false, pmfRequired = false;
        const bool usablePsk = rtw88RsnSelectCcmpPsk(
            _assocRsnIE + 2, _assocRsnIE[1], &pairwise, &group,
            &hasSae, &pmfRequired);
        if (hasSae) _targetBSS.rsn_has_sae = 1;
        if (pmfRequired) _targetBSS.rsn_pmf_required = 1;
        if (usablePsk) {
            _targetBSS.cipher = pairwise;
            _targetBSS.group_cipher = group;
            _targetBSS.akm = 0x000FAC02;
        }
    }
}

/* The current node failed (rejected auth/assoc, or never answered).  Remember
 * it, and if another node of the same SSID is available, restart the join
 * there.  Returns true when a new attempt has been started; false means
 * "nothing left to try" and the caller reports the failure.  Safe to call
 * from the RX path, the timer and the connect worker. */
bool RTW88IEEE80211::retryOtherBss(const char *stage)
{
    if (authenticationCancelled() || !__atomic_load_n(&_powered, __ATOMIC_ACQUIRE))
        return false;

    const uint64_t now = rtw88JoinNowUS();
    uint8_t failed[6] = {};
    RTW88BSS selected = {};
    bool found = false;
    bool externalSupplicant = false;
    bool pmkProvided = false;
    bool hasPassword = false;

    /* Do not let a TX reader or another join observe a partially published
     * target BSS / RSN override. Take the gate before the BSS list lock; never
     * wait for the gate while holding _bssLock. */
    auto mutation = beginTxStateMutation();
    if (!__atomic_load_n(&_powered, __ATOMIC_ACQUIRE) ||
        authenticationCancelled()) {
        mutation.finish();
        return false;
    }

    memcpy(failed, _targetBSS.bssid, sizeof(failed));
    const int privacy = (_targetBSS.capabilities & 0x10) ? 1 : 0;
    IOLockLock(_bssLock);
    _joinFail.note(failed, now, RTW88Join::kFailHoldUS);
    RTW88BSS *cand = nullptr;
    if (_joinTried.count < RTW88Join::kMaxNodesPerJoin)
        cand = selectBssLocked(_targetBSS.ssid, _targetBSS.ssid_len,
                               nullptr, true, privacy);
    if (cand && _joinTried.add(cand->bssid)) {
        memcpy(&selected, cand, sizeof(selected));
        selected.next = nullptr;
        found = true;
    }
    IOLockUnlock(_bssLock);

    if (!found) {
        mutation.finish();
        return false;
    }

    memcpy(&_targetBSS, &selected, sizeof(_targetBSS));
    _curBssTim = false;
    _rssi = (selected.rssi < 0 && selected.rssi >= -127) ? selected.rssi : -100;
    _authAttempts = 0;
    externalSupplicant = _externalSupplicant;
    pmkProvided = _pmkProvided;
    hasPassword = _password[0] != 0;
    applyAssocRsnOverride(externalSupplicant, pmkProvided, hasPassword);
    const RTW88BSS published = _targetBSS;
    mutation.finish();

    IOLog("rtw88: join stage=%s failed on %02x:%02x:%02x:%02x:%02x:%02x -- trying "
          "%02x:%02x:%02x:%02x:%02x:%02x ch=%u rssi=%d\n", stage,
          failed[0], failed[1], failed[2], failed[3], failed[4], failed[5],
          published.bssid[0], published.bssid[1], published.bssid[2],
          published.bssid[3], published.bssid[4], published.bssid[5],
          published.channel, (int)published.rssi);

    if (_timer) _timer->cancelTimeout();
    setRadioState(RTW88_STATE_AUTHENTICATING);
    if (_connectTC) thread_call_enter(_connectTC);
    return true;
}

/* A join attempt failed: try another node, else tell macOS.  A join that was
 * cancelled (host disassociate, sleep) is torn down by its canceller. */
void RTW88IEEE80211::joinAttemptFailed(const char *stage)
{
    if (authenticationCancelled()) return;
    if (!retryOtherBss(stage)) failJoin(stage);
}

bool RTW88IEEE80211::matchesPendingJoin(const char *ssid, const uint8_t *bssid,
                                            const uint8_t *pmk) const
{
    /* While a join is still in progress the driver may already have moved on
     * from the BSSID macOS asked for to another node of the same SSID; a
     * repeat ASSOCIATE for the abandoned one is the same join, not a new one
     * (restarting it would cancel the fallback that is under way). */
    const bool joining = __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_AUTHENTICATING ||
                         __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_ASSOCIATING;
    const bool requested = bssid && _joinHasRequested &&
                           memcmp(bssid, _joinRequestedBssid, 6) == 0;
    return ssid && strcmp(ssid, _targetBSS.ssid) == 0 &&
        (!bssid || memcmp(bssid, _targetBSS.bssid, 6) == 0 ||
         (joining && (_joinTried.contains(bssid) || requested))) &&
        (pmk != nullptr) == _pmkProvided &&
        (!pmk || memcmp(pmk, _pmk, sizeof(_pmk)) == 0);
}

/* May run on the authentication worker: never drain that worker here and
 * never touch RF registers when scan firmware failed to become idle. */
void RTW88IEEE80211::failJoin(const char *stage)
{
    _missingBssRescanAttempted = false;
    IOLog("rtw88: join failed stage=%s attempts=%u\n", stage, _authAttempts);
    __atomic_store_n(&_connectCancelled, true, __ATOMIC_RELEASE);
    if (_timer) _timer->cancelTimeout();
    {
        auto mutation = beginTxStateMutation();
        __atomic_store_n(&_associatedVisible, false, __ATOMIC_RELEASE);
        __atomic_store_n(&_state, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        mutation.finish();
    }
    if (_parent) _parent->setLinkStatus(kIONetworkLinkValid);
    if (_delegate) _delegate->rtw88Event(kRTW88EventDisconnected, nullptr);
}

/* 1.0.2 diagnostic: what the AP advertises and what the driver decided, so a
 * failed join can be explained from the log.  Prints no SSID and no BSSID.
 * The RSN element is dumped (at most 40 bytes) because its AKM list and
 * capability bits show at a glance whether the network is WPA2, WPA3
 * transition or WPA3-only, and whether protected management frames are
 * required. */
static void rtw88LogTargetSecurity(const RTW88BSS &b, bool wpa2, bool havePmk)
{
    static const char hexd[] = "0123456789abcdef";
    char hex[2 * 40 + 1] = {};
    unsigned rsnLen = 0;
    const int rsn = rtw88IeFind(b.ies, b.ies_len, WLAN_EID_RSN);
    if (rsn >= 0) {
        rsnLen = b.ies[rsn + 1];
        const unsigned dump = rsnLen < 40 ? rsnLen : 40;
        for (unsigned i = 0; i < dump; i++) {
            hex[2 * i]     = hexd[b.ies[rsn + 2 + i] >> 4];
            hex[2 * i + 1] = hexd[b.ies[rsn + 2 + i] & 0x0f];
        }
    }
    const bool rsnxe = rtw88IeFind(b.ies, b.ies_len, 244) >= 0;   /* RSN extension (SAE H2E) */
    IOLog("rtw88: connect target ch=%u rssi=%d caps=0x%04x cipher=0x%x group=0x%x akm=0x%x "
          "wpa2=%d pmk=%d rsnLen=%u rsnxe=%d rsn=%s\n",
          b.channel, (int)b.rssi, b.capabilities, b.cipher, b.group_cipher, b.akm,
          wpa2, havePmk, rsnLen, rsnxe, rsn >= 0 ? hex : "none");
}

IOReturn RTW88IEEE80211::cmdConnect(const char *ssid, const char *password, const uint8_t *pmk,
                                      const uint8_t *bssid, bool externalSupplicant)
{
    if (!ssid || !ssid[0] || strnlen(ssid, 33) > 32) return kIOReturnBadArgument;

    /* The reference IO80211 driver accepts ASSOCIATE while net80211 is in SCAN.  Returning
     * EBUSY here made CoreWiFi abort the join and issue DISASSOCIATE while our
     * raw state was still SCANNING. Preserve the request and return success
     * immediately; scanDone() continues
     * the join into AUTH. */
    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING) {
        strlcpy(_deferredSSID, ssid, sizeof(_deferredSSID));
        strlcpy(_deferredPassword, password ? password : "", sizeof(_deferredPassword));
        _deferredPMKValid = pmk != nullptr;
        if (pmk) memcpy(_deferredPMK, pmk, sizeof(_deferredPMK));
        else bzero(_deferredPMK, sizeof(_deferredPMK));
        _deferredBSSIDValid = bssid != nullptr;
        if (bssid) memcpy(_deferredBSSID, bssid, sizeof(_deferredBSSID));
        else bzero(_deferredBSSID, sizeof(_deferredBSSID));
        _deferredExternalSupplicant = externalSupplicant;
        _deferredConnectPending = true;
        if (__atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) == RTW88_STATE_IDLE)
            _missingBssRescanAttempted = true;

        if (__atomic_load_n(&_manualScanChannelCount, __ATOMIC_ACQUIRE)) {
            /* Do not let autojoin to an early 2.4 GHz result truncate the
             * initial software scan before the later 5 GHz channels. The
             * existing scan deadline still bounds this deferred join.
             * Preserve cancellation for a scan returning to a live STA. */
            if (__atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) != RTW88_STATE_IDLE)
                _manualScanAbort = true;
        }
        else if (_hw && _hw->ops && _hw->ops->cancel_hw_scan)
            _hw->ops->cancel_hw_scan(_hw, _vif);

        IOLog("rtw88: ASSOCIATE deferred until active scan completes ssid=%s\n", ssid);
        return kIOReturnSuccess;
    }

    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_IDLE) return kIOReturnBusy;
    if (!_powered || !_connectTC) return kIOReturnNotReady;
    clearKeys();
    releaseSta();
    /* A new join supersedes any previous externally-visible RUN state. */
    /* clearKeys() already published the disconnected latch under the writer gate. */

    /* Find the SSID in our BSS list */
    IOLockLock(_bssLock);
    const size_t wantedLen = strnlen(ssid, sizeof(_targetBSS.ssid));
    _joinTried.clear();
    /* 1.0.2: best node of the SSID rather than the first list entry; 1.0.4:
     * only upgrade a requested 2.4 GHz node to a fresh, usable 5 GHz sibling.
     * A BSSID macOS asks for is honoured exactly when known. If it is missing
     * (for example, before 5 GHz channels were scanned), perform one full
     * refresh and retry that exact BSSID. 1.0.2 substituted another node of
     * the SSID here, which could silently turn a 5 GHz request into 2.4 GHz. */
    bool upgraded = false;
    RTW88BSS *target = selectBssForJoinLocked(ssid, wantedLen, bssid, &upgraded);
    unsigned nodes24 = 0, nodes5 = 0;
    for (RTW88BSS *b = _bssList; b; b = b->next) {
        if (b->ssid_len != wantedLen || memcmp(b->ssid, ssid, wantedLen) != 0) continue;
        if (b->channel > 14) nodes5++; else nodes24++;
    }
    IOLog("rtw88: connect pick pinned=%d nodes24=%u nodes5=%u upgraded=%d -> %s\n",
          bssid != nullptr, nodes24, nodes5, upgraded,
          !target ? "none (not in scan cache)" : target->channel > 14 ? "5 GHz" : "2.4 GHz");
    if (!target) {
        IOLockUnlock(_bssLock);
        if (!_missingBssRescanAttempted) {
            /* The Apple BSSID may have aged out of our cache while the mesh
             * steered, or the 5 GHz BSS may not have been scanned yet.  Refresh
             * all enabled channels once, then retry the exact same SSID/BSSID;
             * never silently substitute a different node for a pinned request. */
            _missingBssRescanAttempted = true;
            strlcpy(_deferredSSID, ssid, sizeof(_deferredSSID));
            strlcpy(_deferredPassword, password ? password : "",
                    sizeof(_deferredPassword));
            _deferredPMKValid = pmk != nullptr;
            if (pmk) memcpy(_deferredPMK, pmk, sizeof(_deferredPMK));
            else bzero(_deferredPMK, sizeof(_deferredPMK));
            _deferredBSSIDValid = bssid != nullptr;
            if (bssid) memcpy(_deferredBSSID, bssid, sizeof(_deferredBSSID));
            else bzero(_deferredBSSID, sizeof(_deferredBSSID));
            _deferredExternalSupplicant = externalSupplicant;
            _deferredConnectPending = true;

            IOReturn scanRet = cmdScan();
            if (scanRet == kIOReturnSuccess) {
                IOLog("rtw88: requested BSS missing from cache; starting one full refresh before join\n");
                return kIOReturnSuccess;
            }
            clearDeferredJoin();
            IOLog("rtw88: missing-BSS refresh could not start ret=0x%x\n", scanRet);
            return scanRet;
        }
        _missingBssRescanAttempted = false;
        return kIOReturnNotFound;
    }
    _missingBssRescanAttempted = false;
    RTW88BSS selected = {};
    memcpy(&selected, target, sizeof(selected));
    selected.next = nullptr;
    _joinTried.add(selected.bssid);
    const int16_t selectedRssi = selected.rssi;
    IOLockUnlock(_bssLock);

    /* Publish the target descriptor and RSN override as one writer
     * transaction so no transmitter can observe a partially updated AP. */
    {
        auto mutation = beginTxStateMutation();
        memcpy(&_targetBSS, &selected, sizeof(_targetBSS));
        _curBssTim = false;
        _rssi = selectedRssi < 0 && selectedRssi >= -127 ? selectedRssi : -100;
        applyAssocRsnOverride(externalSupplicant, pmk != nullptr, password && password[0]);
        mutation.finish();
    }

    if (_targetBSS.rsn_pmf_required) {
        IOLog("rtw88: connect refused: AP requires 802.11w PMF/BIP; this driver cannot negotiate it yet\n");
        return kIOReturnUnsupported;
    }
    if (_targetBSS.rsn_has_sae && _targetBSS.akm != 0x000FAC02) {
        IOLog("rtw88: connect refused: AP advertises SAE without a usable PSK transition path; WPA3-SAE is not implemented\n");
        return kIOReturnUnsupported;
    }
    if (_targetBSS.rsn_has_sae && _targetBSS.akm == 0x000FAC02)
        IOLog("rtw88: WPA2/WPA3 transition BSS: using WPA2-PSK fallback (SAE/PMF not implemented)\n");

    if (externalSupplicant) {
        /* Current Apple-RSN backend supports WPA2/CCMP PSK.  Reject only after
         * considering the association RSN IE, rather than trusting scan-only
         * metadata. */
        if (_targetBSS.cipher != WLAN_CIPHER_SUITE_CCMP ||
            _targetBSS.akm != 0x000FAC02) {
            IOLog("rtw88: connect: requested protected BSS is not CCMP-PSK "
                  "cipher=0x%x akm=0x%x rsnLen=%u\n",
                  _targetBSS.cipher, _targetBSS.akm, _assocRsnIELen);
            return kIOReturnUnsupported;
        }
    } else if ((_targetBSS.capabilities & 0x10) && !pmk && !password) {
        return kIOReturnUnsupported;
    }

    _authAttempts = 0;
    {
        auto mutation = beginTxStateMutation();
        _externalSupplicant = externalSupplicant;
        _pmkProvided = pmk != nullptr;
        if (pmk) memcpy(_pmk, pmk, sizeof(_pmk));
        strlcpy(_password, password ? password : "", sizeof(_password));
        _wpa2 = RTW88Join::useWpa2(externalSupplicant,
                                   _targetBSS.cipher == WLAN_CIPHER_SUITE_CCMP,
                                   pmk != nullptr, _targetBSS.capabilities);
        rtw88LogTargetSecurity(_targetBSS, _wpa2, pmk != nullptr);
        _deauthReason = 0;
        __atomic_store_n(&_connectCancelled, false, __ATOMIC_RELEASE);
        __atomic_store_n(&_state, RTW88_STATE_AUTHENTICATING, __ATOMIC_RELEASE);
        mutation.finish();
    }

    /* Run doAuthenticate on a background thread_call so the IOUserClient
     * call returns immediately.  The connect machinery (channel change,
     * mutex acquisition, TX) must not block the MIG thread. */
    if (_connectTC)
        thread_call_enter(_connectTC);
    return kIOReturnSuccess;
}

void RTW88IEEE80211::connectTCFn(thread_call_param_t self, thread_call_param_t)
{
    ((RTW88IEEE80211 *)self)->doAuthenticate();
}

void RTW88IEEE80211::doAuthenticate()
{
    {
        auto mutation = beginTxStateMutation();
        _awdlPreparedChannel = 0;
        mutation.finish();
    }
    if (authenticationCancelled() || !_powered || !_hw || !_vif) return;
    /* 1.0.2: with another node of this SSID still untried, give up on this one
     * after two silent attempts instead of three, then move on. */
    IOLockLock(_bssLock);
    const bool hasAlternative = hasUntriedAlternativeLocked();
    IOLockUnlock(_bssLock);
    if (++_authAttempts > (hasAlternative ? 2 : 3)) { joinAttemptFailed("auth-retry-limit"); return; }

    IOLog("rtw88: doAuthenticate entry — BSSID %02x:%02x:%02x:%02x:%02x:%02x ch=%u\n",
          _targetBSS.bssid[0], _targetBSS.bssid[1], _targetBSS.bssid[2],
          _targetBSS.bssid[3], _targetBSS.bssid[4], _targetBSS.bssid[5],
          _targetBSS.channel);

    /* Wait for RTW_FLAG_SCANNING to clear.
     * The flag is cleared inside rtw_core_scan_complete() which runs under
     * rtwdev->mutex in the c2h_work thread. */
    for (int i = 0; i < 100; i++) {
        if (authenticationCancelled()) return;
        if (!rtw88_is_scanning()) break;
        IOSleep(50);
    }
    if (authenticationCancelled()) return;
    if (rtw88_is_scanning()) { failJoin("scan-not-idle"); return; }
    IOLog("rtw88: doAuthenticate: scan flag clear\n");

    /* Firmware settle delay.
     *
     * After HW scan the firmware needs ~200-500 ms to fully exit its
     * internal scan-mode critical section before it can safely process
     * channel-switch register writes.  On Linux/FreeBSD this gap is filled
     * naturally by the wpa_supplicant userspace round-trip; we must add it
     * explicitly.  Without this, rtw_set_channel's BB/RF MMIO reads hit the
     * chip while the firmware is still transitioning → PCIe bus hang →
     * system freeze.  500 ms is comfortably below the watch-dog LPS timer
     * (~2 s), so the chip stays awake. */
    IOSleep(500);
    if (authenticationCancelled()) return;
    IOLog("rtw88: doAuthenticate: firmware settled\n");

    /* ----- 1. Channel switch + BSSID (single mutex section) ----- *
     *
     * We call rtw88_connect_hw_setup() instead of ops->config +
     * ops->bss_info_changed because both of those call rtw_leave_lps_deep()
     * → __rtw_fw_leave_lps_check_reg() → polling MMIO reads on REG_TCR.
     * If the chip is slow to respond, those reads stall the calling CPU core
     * indefinitely (PCIe timeout → system freeze).
     *
     * rtw88_connect_hw_setup() holds rtwdev->mutex, calls rtw_set_channel()
     * (MMIO writes) and rtw_vif_port_config(PORT_SET_BSSID) — no reads that
     * can stall, and no LPS wake sequence. */
    struct ieee80211_channel *chan = nullptr;
    for (int b = 0; b < NL80211_NUM_BANDS && !chan; b++) {
        struct ieee80211_supported_band *band =
            (_hw->wiphy) ? _hw->wiphy->bands[b] : nullptr;
        if (!band) continue;
        for (int j = 0; j < band->n_channels; j++) {
            if (band->channels[j].hw_value == _targetBSS.channel) {
                chan = &band->channels[j];
                /* The channel tables omit the per-channel .band field (Linux
                 * fills it in at wiphy_register, which we don't run), so 5GHz
                 * channels otherwise report band 0 == 2GHz.  Backfill it from
                 * the parent band so chandef.chan->band and rx_status->band
                 * are correct. */
                chan->band = band->band;
                break;
            }
        }
    }
    if (chan) {
        auto mutation = beginTxStateMutation();
        setConnectedChandef(chan, &mutation);
        IOLog("rtw88: doAuthenticate: calling connect_hw_setup ch=%u\n",
              _targetBSS.channel);
        rtw88_connect_hw_setup(_hw, _vif, _targetBSS.bssid);
        IOLog("rtw88: doAuthenticate: connect_hw_setup done\n");
        mutation.finish();
    } else {
        failJoin("channel-not-found");
        return;
    }

    if (authenticationCancelled()) return;

    /* Also update the vif bss_conf bssid so any driver-internal code
     * that reads it sees the right value. */
    struct ieee80211_bss_conf *bss = &_vif->bss_conf;
    bss->bssid = bss->bssid_buf;
    memcpy(bss->bssid_buf, _targetBSS.bssid, 6);
    bss->assoc = false;
    bss->aid   = 0;
    _vif->cfg.assoc = false;
    _vif->cfg.aid = 0;
    _assocAID = 0;

    /* ----- 2. Send Authentication frame ----- */
    IOLog("rtw88: doAuthenticate: building auth frame\n");
    uint8_t auth[30] = {};
    uint32_t authlen = 0;
    buildAuthReq(auth, &authlen);
    IOLog("rtw88: doAuthenticate: transmitting auth frame (%u bytes)\n", authlen);
    if (authenticationCancelled()) return;
    if (!txMgmtFrame(auth, authlen)) { failJoin("auth-tx"); return; }
    IOLog("rtw88: doAuthenticate: auth frame sent — waiting for response\n");

    // Do not overwrite a response-driven state transition after transmitting.
    if (authenticationCancelled() || __atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_AUTHENTICATING) return;
    uint64_t d; clock_interval_to_deadline(3000, kMillisecondScale, &d);
    _timer->wakeAtTime(d);
}

void RTW88IEEE80211::doAssociate()
{
    if (!_hw || !_vif) return;

    uint8_t assoc[256] = {};
    uint32_t assoclen  = 0;
    if (authenticationCancelled()) return;
    if (!buildAssocReq(assoc, &assoclen)) { failJoin("assoc-build"); return; }
    // Publish the state before TX: a fast response may arrive during submission.
    setRadioState(RTW88_STATE_ASSOCIATING);
    if (!txMgmtFrame(assoc, assoclen)) {
        failJoin("assoc-tx");
        return;
    }
    if (authenticationCancelled() || __atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_ASSOCIATING) return;
    uint64_t d; clock_interval_to_deadline(3000, kMillisecondScale, &d); _timer->wakeAtTime(d);
}

struct rtw88_peer_caps {
    bool have_ht;
    bool have_vht;
    struct ieee80211_sta_ht_cap ht;
    struct ieee80211_sta_vht_cap vht;
};

/* mac80211 normally supplies rtw88 with the AP's negotiated HT/VHT station
 * capabilities. This port constructs the station itself, so decode the IEs
 * rather than treating our local radio capabilities as peer capabilities. */
static void rtw88_parse_peer_caps(const uint8_t *ies, uint32_t ies_len,
                                  struct rtw88_peer_caps *peer)
{
    for (uint32_t i = 0; ies && i + 2 <= ies_len; ) {
        uint8_t id = ies[i];
        uint8_t len = ies[i + 1];
        if (i + 2u + len > ies_len)
            break;

        const uint8_t *d = ies + i + 2;
        if (id == WLAN_EID_HT_CAPABILITY && len >= 26 && !peer->have_ht) {
            memset(&peer->ht, 0, sizeof(peer->ht));
            peer->ht.ht_supported = true;
            peer->ht.cap = (u16)(d[0] | (d[1] << 8));
            peer->ht.ampdu_factor = d[2] & 0x3;
            peer->ht.ampdu_density = (d[2] >> 2) & 0x7;
            memcpy(peer->ht.mcs.rx_mask, d + 3,
                   sizeof(peer->ht.mcs.rx_mask));
            peer->ht.mcs.rx_highest = (u16)(d[13] | (d[14] << 8));
            peer->ht.mcs.tx_params = d[15];
            peer->have_ht = true;
        } else if (id == WLAN_EID_VHT_CAPABILITY && len >= 12 &&
                   !peer->have_vht) {
            memset(&peer->vht, 0, sizeof(peer->vht));
            peer->vht.vht_supported = true;
            peer->vht.cap = (u32)d[0] | ((u32)d[1] << 8) |
                            ((u32)d[2] << 16) | ((u32)d[3] << 24);
            peer->vht.vht_mcs.rx_mcs_map =
                cpu_to_le16((u16)(d[4] | (d[5] << 8)));
            peer->vht.vht_mcs.rx_highest =
                cpu_to_le16((u16)(d[6] | (d[7] << 8)));
            peer->vht.vht_mcs.tx_mcs_map =
                cpu_to_le16((u16)(d[8] | (d[9] << 8)));
            peer->vht.vht_mcs.tx_highest =
                cpu_to_le16((u16)(d[10] | (d[11] << 8)));
            peer->have_vht = true;
        }
        i += 2u + len;
    }
}

/* Apply mac80211's peer/own capability intersection
 * (ieee80211_ht_cap_ie_to_sta_ht_cap / ieee80211_vht_cap_ie_to_sta_vht_cap).
 * rtw_update_sta_info() turns these bits directly into firmware STBC/LDPC/SGI
 * and MCS masks, so raw AP capabilities must not reach it. */
static void rtw88_restrict_peer_caps(struct rtw88_peer_caps *peer,
                                     const struct ieee80211_supported_band *own)
{
    if (!own || !own->ht_cap.ht_supported) {
        peer->have_ht = false;
        peer->have_vht = false;
        return;
    }

    if (peer->have_ht) {
        const struct ieee80211_sta_ht_cap *oh = &own->ht_cap;
        u16 cap = peer->ht.cap &
            (u16)(oh->cap | ~(IEEE80211_HT_CAP_LDPC_CODING |
                              IEEE80211_HT_CAP_SUP_WIDTH_20_40 |
                              IEEE80211_HT_CAP_GRN_FLD |
                              IEEE80211_HT_CAP_SGI_20 |
                              IEEE80211_HT_CAP_SGI_40 |
                              IEEE80211_HT_CAP_DSSSCCK40));
        if (!(oh->cap & IEEE80211_HT_CAP_TX_STBC))
            cap &= ~(u16)IEEE80211_HT_CAP_RX_STBC;
        if (!(oh->cap & IEEE80211_HT_CAP_RX_STBC))
            cap &= ~(u16)IEEE80211_HT_CAP_TX_STBC;
        peer->ht.cap = cap;

        u8 peer_mask[sizeof(peer->ht.mcs.rx_mask)];
        memcpy(peer_mask, peer->ht.mcs.rx_mask, sizeof(peer_mask));
        memset(peer->ht.mcs.rx_mask, 0, sizeof(peer->ht.mcs.rx_mask));
        if (oh->mcs.tx_params & IEEE80211_HT_MCS_TX_DEFINED) {
            /* rtw88 advertises equal TX/RX streams and no unequal modulation. */
            for (unsigned i = 0; i < 4; i++)
                peer->ht.mcs.rx_mask[i] = oh->mcs.rx_mask[i] & peer_mask[i];
            if (oh->mcs.rx_mask[4] & peer_mask[4] & 1)
                peer->ht.mcs.rx_mask[4] |= 1;
        }
    }

    const struct ieee80211_sta_vht_cap *ov = &own->vht_cap;
    if (!peer->have_ht || !ov->vht_supported)
        peer->have_vht = false;
    if (peer->have_vht) {
        u32 ci = peer->vht.cap;
        u32 cap = ci & (IEEE80211_VHT_CAP_RXLDPC |
                        IEEE80211_VHT_CAP_HTC_VHT |
                        IEEE80211_VHT_CAP_MAX_A_MPDU_LENGTH_EXPONENT_MASK);
        u32 peer_mpdu = ci & 0x3, own_mpdu = ov->cap & 0x3;
        cap |= peer_mpdu < own_mpdu ? peer_mpdu : own_mpdu;
        cap |= ci & ov->cap & (IEEE80211_VHT_CAP_SHORT_GI_80 |
                               IEEE80211_VHT_CAP_SHORT_GI_160);
        if (ov->cap & IEEE80211_VHT_CAP_SU_BEAMFORMEE_CAPABLE)
            cap |= ci & (IEEE80211_VHT_CAP_SU_BEAMFORMER_CAPABLE |
                         IEEE80211_VHT_CAP_SOUNDING_DIMENSIONS_MASK);
        if (ov->cap & IEEE80211_VHT_CAP_SU_BEAMFORMER_CAPABLE)
            cap |= ci & (IEEE80211_VHT_CAP_SU_BEAMFORMEE_CAPABLE |
                         IEEE80211_VHT_CAP_BEAMFORMEE_STS_MASK);
        if (ov->cap & IEEE80211_VHT_CAP_MU_BEAMFORMER_CAPABLE)
            cap |= ci & IEEE80211_VHT_CAP_MU_BEAMFORMEE_CAPABLE;
        if (ov->cap & IEEE80211_VHT_CAP_MU_BEAMFORMEE_CAPABLE)
            cap |= ci & IEEE80211_VHT_CAP_MU_BEAMFORMER_CAPABLE;
        if (ov->cap & IEEE80211_VHT_CAP_TXSTBC)
            cap |= ci & IEEE80211_VHT_CAP_RXSTBC_MASK;
        if (ov->cap & IEEE80211_VHT_CAP_RXSTBC_MASK)
            cap |= ci & IEEE80211_VHT_CAP_TXSTBC;
        peer->vht.cap = cap;

        u16 own_rx = le16_to_cpu(ov->vht_mcs.rx_mcs_map);
        u16 own_tx = le16_to_cpu(ov->vht_mcs.tx_mcs_map);
        u16 prx = le16_to_cpu(peer->vht.vht_mcs.rx_mcs_map);
        u16 ptx = le16_to_cpu(peer->vht.vht_mcs.tx_mcs_map);
        u16 rx = 0, tx = 0;
        for (unsigned i = 0; i < 8; i++) {
            u16 orx = (own_rx >> (i * 2)) & 3, otx = (own_tx >> (i * 2)) & 3;
            u16 r = (prx >> (i * 2)) & 3, t = (ptx >> (i * 2)) & 3;
            if (t != 3) t = (orx == 3) ? 3 : (orx < t ? orx : t);
            if (r != 3) r = (otx == 3) ? 3 : (otx < r ? otx : r);
            rx |= (u16)(r << (i * 2));
            tx |= (u16)(t << (i * 2));
        }
        peer->vht.vht_mcs.rx_mcs_map = cpu_to_le16(rx);
        peer->vht.vht_mcs.tx_mcs_map = cpu_to_le16(tx);
    }
}

void RTW88IEEE80211::processAssocResponse(struct sk_buff *skb)
{
    uint16_t status = 0, aid = 0;
    bool valid = rtw88AssocResponse(skb->data, skb->len, _macAddr,
                                    _targetBSS.bssid, &status, &aid);
    struct rtw88_peer_caps peer = {};
    if (valid && status == 0) {
        rtw88_parse_peer_caps(skb->data + 30, skb->len - 30, &peer);
        rtw88_parse_peer_caps(_targetBSS.ies, _targetBSS.ies_len, &peer);
    }
    kfree_skb(skb);
    if (!valid || authenticationCancelled()) return;

    if (status != 0) {
        IOLog("rtw88: assoc failed status=%u\n", status);
        /* Mesh nodes commonly refuse with 1/12/17/30 while band-steering or
         * full.  Move on to another node, else report the failure (the old
         * code went quietly IDLE). */
        joinAttemptFailed("assoc-rejected");
        return;
    }
    IOLog("rtw88: associated! AID=%u\n", aid);
    IOLockLock(_bssLock);
    _joinFail.forget(_targetBSS.bssid);   /* this node works: no longer suspect */
    IOLockUnlock(_bssLock);
    _assocAID = aid;
    bool staAddFailed = false;
    bool stationReady = false;
    {
        auto mutation = beginTxStateMutation();
        /* Association and station construction are one indivisible control
         * transaction relative to all four WMM transmitters. */
        __atomic_store_n(&_associatedVisible, true, __ATOMIC_RELEASE);
        if (!_sta && _hw->ops && _hw->ops->sta_add) {
            const size_t sta_sz = sizeof(struct ieee80211_sta) + _hw->sta_data_size;
            _sta = (struct ieee80211_sta *)IOMallocZero(sta_sz);
            if (_sta) {
                _staAllocSize = sta_sz;
                memcpy(_sta->addr, _targetBSS.bssid, ETH_ALEN);
                _sta->aid = aid;
                _sta->wme = true;

                /* Populate supported rates so rtw_update_sta_info() builds a
                 * non-empty rate-adaptation mask. */
                _sta->deflink.supp_rates[NL80211_BAND_2GHZ] = 0xFFF;
                _sta->deflink.supp_rates[NL80211_BAND_5GHZ] = 0xFF;
                _sta->deflink.bandwidth =
                    (_connChanWidth == 80) ? IEEE80211_STA_RX_BW_80 :
                    (_connChanWidth == 40) ? IEEE80211_STA_RX_BW_40 :
                                             IEEE80211_STA_RX_BW_20;

                enum nl80211_band sta_band =
                    (_targetBSS.channel > 14) ? NL80211_BAND_5GHZ :
                                                NL80211_BAND_2GHZ;
                rtw88_restrict_peer_caps(&peer,
                    (_hw->wiphy) ? _hw->wiphy->bands[sta_band] : nullptr);
                if (htAllowed() && peer.have_ht) {
                    _sta->deflink.ht_cap = peer.ht;
                    if (_connChanWidth < 40)
                        _sta->deflink.ht_cap.cap &=
                            ~(uint16_t)(IEEE80211_HT_CAP_SUP_WIDTH_20_40 |
                                        IEEE80211_HT_CAP_SGI_40 |
                                        IEEE80211_HT_CAP_DSSSCCK40);
                    if (_targetBSS.channel > 14 && peer.have_vht)
                        _sta->deflink.vht_cap = peer.vht;
                }

                IOLog("rtw88: peer HT=%d VHT=%d width=%u rx_mcs0=0x%02x ht_cap=0x%04x vht_cap=0x%08x vht_rx=0x%04x\n",
                      _sta->deflink.ht_cap.ht_supported,
                      _sta->deflink.vht_cap.vht_supported, _connChanWidth,
                      _sta->deflink.ht_cap.mcs.rx_mask[0],
                      _sta->deflink.ht_cap.cap, _sta->deflink.vht_cap.cap,
                      le16_to_cpu(_sta->deflink.vht_cap.vht_mcs.rx_mcs_map));

                const int staRet = _hw->ops->sta_add(_hw, _vif, _sta);
                if (staRet) {
                    IOLog("rtw88: sta_add failed ret=%d\n", staRet);
                    IOFree(_sta, _staAllocSize);
                    _sta = nullptr;
                    _staAllocSize = 0;
                    staAddFailed = true;
                } else {
                    rtw88_register_sta(_vif, _sta);
                }
            }
        }
        stationReady = _sta != nullptr;
        mutation.finish();
    }

    if (staAddFailed) {
        failJoin("sta-add");
        return;
    }
    if (!stationReady) {
        failJoin("sta-allocation");
        return;
    }

    /* ----- 2. Notify driver of full association ----- */
    if (_hw->ops && _hw->ops->bss_info_changed) {
        struct ieee80211_bss_conf *bss = &_vif->bss_conf;
        bss->assoc = true;
        bss->aid   = aid;
        bss->qos   = true;
        bss->bssid = bss->bssid_buf;
        memcpy(bss->bssid_buf, _targetBSS.bssid, ETH_ALEN);
        _vif->cfg.assoc = true;
        _vif->cfg.aid   = aid;
        _hw->ops->bss_info_changed(_hw, _vif, bss,
            BSS_CHANGED_ASSOC | BSS_CHANGED_QOS);
    }

    /* Notify WCL at the raw 802.11 association boundary. For the internal
     * WPA2 path this precedes the four-way handshake; Connected is emitted
     * only after M3 installs keys and the controlled port becomes usable. */
    if (_delegate)
        _delegate->rtw88Event(kRTW88EventAssocDone, nullptr);

    if (_wpa2 && !_externalSupplicant) {
        setRadioState(RTW88_STATE_HANDSHAKING);
        IOLog("rtw88: WPA2 — waiting for EAPOL M1\n");
        /* Derive PMK from passphrase now */
        if (!_pmkProvided) derivePMK((uint8_t *)_password, (uint8_t *)_targetBSS.ssid,
                  _targetBSS.ssid_len, _pmk);
        uint64_t d;
        clock_interval_to_deadline(8000, kMillisecondScale, &d);
        _timer->wakeAtTime(d);
    } else {
        /* Apple RSN Supplicant needs the station in RUN so its EAPOL socket can
         * receive the AP's handshake frames.  The link becomes usable only after
         * CIPHER_KEY installs the PTK/GTK, but exposing RUN here mirrors
         * the reference IO80211 driver's net80211 flow. */
        {
            auto mutation = beginTxStateMutation();
            __atomic_store_n(&_state, RTW88_STATE_CONNECTED, __ATOMIC_RELEASE);
            if (!_wpa2)
                __atomic_store_n(&_dataTxBlocked, false, __ATOMIC_RELEASE);
            mutation.finish();
        }
        /* Our Apple-RSN path injects EAPOL through the normal BSD Ethernet
         * interface, unlike the reference IO80211 driver's net80211 path.  The interface must
         * therefore be LINK_UP for EAPOLController to receive/send 0x888e.
         * The TX gate below still drops ordinary traffic until PTK+GTK exist,
         * so exposing LINK_UP here does not leak unprotected IP traffic.  This
         * restores the association state that previously reached EAPOL on the
         * RTL8822BE while keeping controlled-port semantics in our own path. */
        if (_parent)
            _parent->setLinkStatus(kIONetworkLinkActive | kIONetworkLinkValid);
        if (!_wpa2)
            startTxAggregation();
        _timer->cancelTimeout();
        if (_externalSupplicant) {
            IOLog("rtw88: associated — Apple RSN active; waiting for PTK/GTK before link-up\n");
        } else if (!_wpa2 && _delegate) {
            /* Native WCL consumes a complete-connect event, not an external
             * supplicant's raw association event. Open networks are ready as
             * soon as the backend enters CONNECTED. */
            _delegate->rtw88Event(kRTW88EventConnected, nullptr);
        }
    }

    /* The native WCL interface receives ASSOC_DONE above for both open and
     * protected networks. The separate CONNECTED event follows when the
     * controlled port is actually ready. */
}

bool RTW88IEEE80211::buildAuthReq(uint8_t *buf, uint32_t *len)
{
    /* 802.11 Authentication frame (open system, seq 1) */
    struct ieee80211_hdr_3addr *hdr = (struct ieee80211_hdr_3addr *)buf;
    hdr->frame_control = cpu_to_le16(IEEE80211_FTYPE_MGMT | IEEE80211_STYPE_AUTH);
    hdr->duration_id   = 0;
    memcpy(hdr->addr1, _targetBSS.bssid, 6);
    memcpy(hdr->addr2, _macAddr, 6);
    memcpy(hdr->addr3, _targetBSS.bssid, 6);
    hdr->seq_ctrl = cpu_to_le16((uint16_t)(nextTxSequence() << 4));

    uint8_t *body = buf + sizeof(*hdr);
    /* Algorithm: 0 (Open), Transaction: 1, Status: 0 */
    body[0] = 0; body[1] = 0; /* algorithm */
    body[2] = 1; body[3] = 0; /* transaction seq */
    body[4] = 0; body[5] = 0; /* status code */
    *len = sizeof(*hdr) + 6;
    return true;
}

bool RTW88IEEE80211::buildAssocReq(uint8_t *buf, uint32_t *len)
{
    struct ieee80211_hdr_3addr *hdr = (struct ieee80211_hdr_3addr *)buf;
    hdr->frame_control = cpu_to_le16(IEEE80211_FTYPE_MGMT | IEEE80211_STYPE_ASSOC_REQ);
    hdr->duration_id   = 0;
    memcpy(hdr->addr1, _targetBSS.bssid, 6);
    memcpy(hdr->addr2, _macAddr, 6);
    memcpy(hdr->addr3, _targetBSS.bssid, 6);
    hdr->seq_ctrl = cpu_to_le16((uint16_t)(nextTxSequence() << 4));

    uint8_t *body = buf + sizeof(*hdr);
    /* Privacy is clear for open networks and set only for WPA2-protected
     * associations.  0x0431 accidentally included bit 4 in the base value,
     * making every supposedly open association look protected to the AP. */
    uint16_t cap = RTW88Join::associationCapability(_wpa2);
    body[0] = (uint8_t)(cap & 0xff);
    body[1] = (uint8_t)(cap >> 8);
    /* Listen interval: 10 */
    body[2] = 10; body[3] = 0;
    body += 4;

    /* SSID IE */
    body[0] = WLAN_EID_SSID;
    body[1] = (uint8_t)_targetBSS.ssid_len;
    memcpy(body + 2, _targetBSS.ssid, _targetBSS.ssid_len);
    body += 2 + _targetBSS.ssid_len;

    /* Supported rates. */
    static const uint8_t rates_2g[] = {
        0x82, 0x84, 0x8b, 0x96, 0x0c, 0x12, 0x18, 0x24
    };
    static const uint8_t rates_5g[] = {
        0x8c, 0x12, 0x98, 0x24, 0x30, 0x48, 0x60, 0x6c
    };
    static const uint8_t ext_rates_2g[] = {
        0x30, 0x48, 0x60, 0x6c
    };
    const uint8_t *rates =
        (_targetBSS.channel > 14) ? rates_5g : rates_2g;
    uint8_t rates_len =
        (_targetBSS.channel > 14) ? sizeof(rates_5g) : sizeof(rates_2g);

    body[0] = WLAN_EID_SUPP_RATES;
    body[1] = rates_len;
    memcpy(body + 2, rates, rates_len);
    body += 2 + rates_len;

    if (_targetBSS.channel <= 14) {
        body[0] = WLAN_EID_EXT_SUPP_RATES;
        body[1] = sizeof(ext_rates_2g);
        memcpy(body + 2, ext_rates_2g, sizeof(ext_rates_2g));
        body += 2 + sizeof(ext_rates_2g);
    }

    /*
     * HT/VHT Capabilities — advertise 802.11n/ac so the AP associates us as a
     * high-throughput station (high MCS rates) and is willing to set up A-MPDU
     * BlockAck aggregation.  Without these IEs the AP treats us as legacy a/g
     * (<=54 Mbps, no aggregation), which is the root cause of the ~13 Mbps cap.
     *
     * We copy directly from the chip's own band capabilities (filled by
     * rtw_init_ht_cap/rtw_init_vht_cap during rtw_register_hw) so we never
     * claim more than the hardware supports.  The 40/80 MHz channel-width bits
     * are cleared because the PHY stays on a 20 MHz channel this pass — wider
     * operation needs HT/VHT Operation parsing + a re-tune (future work).
     */
    enum nl80211_band band =
        (_targetBSS.channel > 14) ? NL80211_BAND_5GHZ : NL80211_BAND_2GHZ;
    struct ieee80211_supported_band *sband =
        (_hw && _hw->wiphy) ? _hw->wiphy->bands[band] : nullptr;

    if (htAllowed() && sband && sband->ht_cap.ht_supported) {
        const struct ieee80211_sta_ht_cap *ht = &sband->ht_cap;
        body[0] = WLAN_EID_HT_CAPABILITY;
        body[1] = 26;
        uint8_t *p = body + 2;
        /* HT Capabilities Info (2 bytes, LE).  Advertise 40 MHz only when we
         * actually operate at >=40 MHz; otherwise clear the width bits to keep
         * the AP at 20 MHz. */
        uint16_t htcap = ht->cap;
        if (_connChanWidth < 40)
            htcap &= ~(uint16_t)(IEEE80211_HT_CAP_SUP_WIDTH_20_40 |
                                 IEEE80211_HT_CAP_SGI_40 |
                                 IEEE80211_HT_CAP_DSSSCCK40);
        p[0] = (uint8_t)(htcap & 0xff);
        p[1] = (uint8_t)(htcap >> 8);
        /* A-MPDU Parameters: max-length exponent (bits 1:0) | density (4:2). */
        p[2] = (uint8_t)((ht->ampdu_factor & 0x3) |
                         ((ht->ampdu_density & 0x7) << 2));
        /* Supported MCS Set (16 bytes): rx_mask[10], rx_highest(2),
         * tx_params(1), 3 reserved. */
        memcpy(p + 3, ht->mcs.rx_mask, 10);
        p[13] = (uint8_t)(ht->mcs.rx_highest & 0xff);
        p[14] = (uint8_t)((ht->mcs.rx_highest >> 8) & 0xff);
        p[15] = (uint8_t)(ht->mcs.tx_params & 0xff);
        /* p[16..25]: MCS-set reserved (3) + HT-ext (2) + TxBF (4) + ASEL (1). */
        memset(p + 16, 0, 10);
        body += 2 + 26;
    }

    if (htAllowed() && band == NL80211_BAND_5GHZ &&
        sband && sband->vht_cap.vht_supported) {
        const struct ieee80211_sta_vht_cap *vht = &sband->vht_cap;
        body[0] = WLAN_EID_VHT_CAPABILITY;
        body[1] = 12;
        uint8_t *p = body + 2;
        /* VHT Capabilities Info (4 bytes, LE).  The Supported Channel Width
         * Set subfield (bits 2:3) stays 0 (<=80 MHz capable); actual operation
         * is held to 20 MHz by the HT cap above. */
        uint32_t vcap = vht->cap;
        p[0] = (uint8_t)(vcap & 0xff);
        p[1] = (uint8_t)((vcap >> 8) & 0xff);
        p[2] = (uint8_t)((vcap >> 16) & 0xff);
        p[3] = (uint8_t)((vcap >> 24) & 0xff);
        /* Supported VHT-MCS and NSS Set (8 bytes). */
        uint16_t rxmap = (uint16_t)le32_to_cpu(vht->vht_mcs.rx_mcs_map);
        uint16_t rxhi  = le16_to_cpu(vht->vht_mcs.rx_highest);
        uint16_t txmap = (uint16_t)le32_to_cpu(vht->vht_mcs.tx_mcs_map);
        uint16_t txhi  = le16_to_cpu(vht->vht_mcs.tx_highest);
        p[4] = (uint8_t)(rxmap & 0xff); p[5] = (uint8_t)(rxmap >> 8);
        p[6] = (uint8_t)(rxhi & 0xff);  p[7] = (uint8_t)(rxhi >> 8);
        p[8] = (uint8_t)(txmap & 0xff); p[9] = (uint8_t)(txmap >> 8);
        p[10] = (uint8_t)(txhi & 0xff); p[11] = (uint8_t)(txhi >> 8);
        body += 2 + 12;
    }

    /* WME information element. We later notify rtw88 that QoS is enabled, so
     * advertise WME to the AP as well, especially for stricter 5GHz networks. */
    static const uint8_t wme_info[] = {
        0xdd, 0x07, 0x00, 0x50, 0xf2, 0x02, 0x00, 0x01, 0x00
    };
    memcpy(body, wme_info, sizeof(wme_info));
    body += sizeof(wme_info);

    /* Advertise the cipher choice we actually implement: pairwise CCMP/AES
     * with the AP's selected group cipher.  Mixed TKIP+AES APs often list
     * both pairwise ciphers; copying that raw IE can make the AP pick a path
     * we do not want. */
    if (_wpa2) {
        if (_externalSupplicant && _assocRsnIELen >= 2 && _assocRsnIELen <= sizeof(_assocRsnIE) &&
            _assocRsnIE[0] == 48 && (uint16_t)(_assocRsnIE[1] + 2) == _assocRsnIELen) {
            memcpy(body, _assocRsnIE, _assocRsnIELen);
            body += _assocRsnIELen;
        } else {
            uint16_t rsn_len = rtw88BuildSelectedRsnIe(body, _targetBSS.group_cipher);
            body += rsn_len;
        }
    }

    *len = (uint32_t)(body - buf);
    return true;
}

IOReturn RTW88IEEE80211::cmdSetAssocRsnIE(const uint8_t *ie, uint16_t len)
{
    if (!ie || len < 2 || len > sizeof(_assocRsnIE) || ie[0] != 48 ||
        (uint16_t)(ie[1] + 2) != len)
        return kIOReturnBadArgument;
    memcpy(_assocRsnIE, ie, len);
    if (len < sizeof(_assocRsnIE))
        bzero(_assocRsnIE + len, sizeof(_assocRsnIE) - len);
    _assocRsnIELen = len;
    return kIOReturnSuccess;
}

void RTW88IEEE80211::clearAssocRsnIE()
{
    bzero(_assocRsnIE, sizeof(_assocRsnIE));
    _assocRsnIELen = 0;
}

IOReturn RTW88IEEE80211::copyTargetIEs(uint8_t *out, uint32_t capacity, uint32_t *len) const
{
    if (!len) return kIOReturnBadArgument;
    uint32_t need = _targetBSS.ies_len > sizeof(_targetBSS.ies) ? sizeof(_targetBSS.ies) : _targetBSS.ies_len;
    if (!out || capacity < need) {
        *len = need;
        return need ? kIOReturnNoSpace : kIOReturnNotReady;
    }
    if (!need) return kIOReturnNotReady;
    memcpy(out, _targetBSS.ies, need);
    *len = need;
    return kIOReturnSuccess;
}

IOReturn RTW88IEEE80211::copyTargetRsnIE(uint8_t *out, uint16_t capacity, uint16_t *len) const
{
    if (!out || !len) return kIOReturnBadArgument;
    if (_assocRsnIELen >= 2) {
        if (capacity < _assocRsnIELen) return kIOReturnNoSpace;
        memcpy(out, _assocRsnIE, _assocRsnIELen);
        *len = _assocRsnIELen;
        return kIOReturnSuccess;
    }
    uint32_t total = _targetBSS.ies_len > sizeof(_targetBSS.ies) ? sizeof(_targetBSS.ies) : _targetBSS.ies_len;
    for (uint32_t pos = 0; pos + 2 <= total;) {
        uint32_t n = (uint32_t)_targetBSS.ies[pos + 1] + 2;
        if (n > total - pos) break;
        if (_targetBSS.ies[pos] == 48) {
            if (n > capacity) return kIOReturnNoSpace;
            memcpy(out, _targetBSS.ies + pos, n);
            *len = (uint16_t)n;
            return kIOReturnSuccess;
        }
        pos += n;
    }
    return kIOReturnNotFound;
}

IOReturn RTW88IEEE80211::cmdInstallExternalKey(bool pairwise, uint8_t keyidx, uint32_t cipher,
                                                const uint8_t *key, uint8_t key_len)
{
    if (!key || !key_len)
        return kIOReturnBadArgument;

    auto mutation = beginTxStateMutation();
    if (!_externalSupplicant || !_wpa2 || !associatedVisible() ||
        (pairwise && !_sta)) {
        mutation.finish();
        return kIOReturnNotReady;
    }

    struct ieee80211_key_conf **slot = pairwise ? &_ptkConf : &_gtkConf;
    if (!installKeyUnderMutation(slot, pairwise, keyidx, cipher, key, key_len,
                                 &mutation)) {
        mutation.finish();
        return kIOReturnUnsupported;
    }

    if (pairwise)
        __atomic_store_n(&_externalPTKInstalled, true, __ATOMIC_RELEASE);
    else
        __atomic_store_n(&_externalGTKInstalled, true, __ATOMIC_RELEASE);

    const bool keysReady =
        __atomic_load_n(&_externalPTKInstalled, __ATOMIC_ACQUIRE) &&
        __atomic_load_n(&_externalGTKInstalled, __ATOMIC_ACQUIRE);
    if (keysReady)
        __atomic_store_n(&_dataTxBlocked, false, __ATOMIC_RELEASE);
    mutation.finish();

    IOLog("rtw88: Apple RSN key installed type=%s ptk=%d gtk=%d\n",
          pairwise ? "pairwise" : "group",
          __atomic_load_n(&_externalPTKInstalled, __ATOMIC_ACQUIRE),
          __atomic_load_n(&_externalGTKInstalled, __ATOMIC_ACQUIRE));

    if (keysReady) {
        if (_parent)
            _parent->setLinkStatus(kIONetworkLinkActive | kIONetworkLinkValid);
        startTxAggregation();
    }
    return kIOReturnSuccess;
}
/* ------------------------------------------------------------------ */
/*  Disconnect                                                          */
/* ------------------------------------------------------------------ */

void RTW88IEEE80211::clearDeferredJoin()
{
    _deferredConnectPending = false;
    _missingBssRescanAttempted = false;
    _deferredPMKValid = false;
    _deferredBSSIDValid = false;
    _deferredExternalSupplicant = false;
    bzero(_deferredSSID, sizeof(_deferredSSID));
    bzero(_deferredPassword, sizeof(_deferredPassword));
    bzero(_deferredPMK, sizeof(_deferredPMK));
    bzero(_deferredBSSID, sizeof(_deferredBSSID));
}

void RTW88IEEE80211::cancelAuthentication()
{
    __atomic_store_n(&_connectCancelled, true, __ATOMIC_RELEASE);
    if (_timer) _timer->cancelTimeout();
    // All authentication retries use this call, so draining it also drains retries.
    if (_connectTC) thread_call_cancel_wait(_connectTC);
}

IOReturn RTW88IEEE80211::cmdDisconnect()
{
    clearDeferredJoin();
    /* A disconnected SCANNING state is not an association that can be torn
     * down.  The reference IO80211 driver's net80211 stays in SCAN here; it does not emit a
     * spurious link-disconnected event.  Cancel any queued join but preserve
     * the scan transaction so CoreWiFi can receive SCAN_DONE cleanly. */
    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING && !associatedVisible() &&
        __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) == RTW88_STATE_IDLE) {
        IOLog("rtw88: DISASSOCIATE acknowledged during disconnected scan (no link teardown)\n");
        return kIOReturnSuccess;
    }

    /* v52: a background scan deliberately changes the implementation state
     * from CONNECTED to SCANNING while associatedVisible() keeps IO80211 in
     * RUN.  Tearing down the station without first terminating that scan lets
     * scanDone() race the new association and can resurrect stale channel/BSS
     * state.  That is exactly the shape of the issue #3 network-transition
     * failure.  Drain the connected scan synchronously before disassociation. */
    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING && associatedVisible() &&
        __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED) {
        IOLog("rtw88: DISASSOCIATE aborting connected background scan before teardown\n");
        if (!abortActiveScan(true))
            return kIOReturnBusy;
    }

    cancelAuthentication();
    /* r7: a host-requested disassociation is voluntary.  Report
     * APPLE80211_REASON_ASSOC_LEAVING (8) as the link-down/DEAUTH reason, as
     * the reference IO80211 driver's setDISASSOCIATE does.  A zero reason made airportd log
     * "Unexpected link down" and start auto-join, which then tore down the
     * user's new join.  cmdConnect resets the reason to 0. */
    _deauthReason = 8;
    /* End the RUN latch atomically with TX admission. */
    {
        auto mutation = beginTxStateMutation();
        __atomic_store_n(&_associatedVisible, false, __ATOMIC_RELEASE);
        mutation.finish();
    }
    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_IDLE) return kIOReturnSuccess;
    doDisconnect();
    return kIOReturnSuccess;
}

IOReturn RTW88IEEE80211::suspendForSystemSleep()
{
    /* System sleep/hibernate is stronger than an ordinary Wi-Fi toggle.  Do
     * not wait for a background scan timeout: stop its worker synchronously,
     * restore the infrastructure channel, and then reuse the normal power-off
     * cleanup.  The resumed kernel image must not carry a logical CONNECTED
     * state into freshly-reset firmware. */
    clearDeferredJoin();
    cancelAuthentication();

    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING) {
        const RTW88State returnState = __atomic_load_n(&_scanReturnState, __ATOMIC_ACQUIRE);
        (void)abortActiveScan(false);
        _manualScanAbort = true;
        if (_manualScanTC)
            thread_call_cancel_wait(_manualScanTC);
        if (returnState == RTW88_STATE_CONNECTED)
            restoreConnectedChannel();
        setRadioState(returnState == RTW88_STATE_IDLE ? RTW88_STATE_IDLE : returnState);
        __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        _scanPartial = false;
        __atomic_store_n(&_manualScanChannelCount, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&_manualScanOnHomeChannel, false, __ATOMIC_RELEASE);
    }

    if (_awdlOffChannel)
        restoreSTAChannelAfterAWDL();

    return cmdPowerOff();
}

IOReturn RTW88IEEE80211::cmdPowerOn()
{
    IOReturn ret = powerOn();
    if (ret == kIOReturnSuccess && __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_DISCONNECTING)
        setRadioState(RTW88_STATE_IDLE);
    return ret;
}

IOReturn RTW88IEEE80211::cmdPowerOff()
{
    /* abortActiveScan may synchronously deliver scanDone while still powered.
     * Remove its queued association before draining either worker. */
    clearDeferredJoin();
    cancelAuthentication();
    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_SCANNING && !abortActiveScan(true))
        return kIOReturnBusy;

    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED ||
        __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_AUTHENTICATING ||
        __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_ASSOCIATING ||
        __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_HANDSHAKING) {
        /* Final: Wi-Fi off and system sleep are voluntary, like r7's
         * DISASSOCIATE.  Reason 0 made airportd log "Dropped Connection:
         * reason=0" on wake and add the network to its "potentially
         * problematic" list.  cmdConnect resets the reason to 0. */
        _deauthReason = 8;
        doDisconnect();
    } else {
        clearKeys();
        releaseSta();
    }

    powerOff();
    clearAssocRsnIE();
    {
        auto mutation = beginTxStateMutation();
        __atomic_store_n(&_state, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        __atomic_store_n(&_associatedVisible, false, __ATOMIC_RELEASE);
        mutation.finish();
    }
    __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
    _scanPartial = false;
    if (_parent)
        _parent->setLinkStatus(kIONetworkLinkValid);
    return kIOReturnSuccess;
}

void RTW88IEEE80211::doDisconnect()
{
    /* A deauth must be transmitted on the infrastructure channel.  AWDL may
     * currently own the single PHY, so hand it back before tearing down the
     * association or clearing the visibility latch used by the restore path. */
    if (_awdlOffChannel)
        restoreSTAChannelAfterAWDL();

    if (!_hw || !_vif) {
        auto mutation = beginTxStateMutation();
        __atomic_store_n(&_state, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        __atomic_store_n(&_associatedVisible, false, __ATOMIC_RELEASE);
        __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
        _scanPartial = false;
        mutation.finish();
        return;
    }
    clearKeys();
    clearAssocRsnIE();

    /* Send deauth frame */
    uint8_t deauth[28] = {};
    struct ieee80211_hdr_3addr *hdr = (struct ieee80211_hdr_3addr *)deauth;
    hdr->frame_control = cpu_to_le16(IEEE80211_FTYPE_MGMT | IEEE80211_STYPE_DEAUTH);
    memcpy(hdr->addr1, _targetBSS.bssid, 6);
    memcpy(hdr->addr2, _macAddr, 6);
    memcpy(hdr->addr3, _targetBSS.bssid, 6);
    uint8_t *body = deauth + sizeof(*hdr);
    body[0] = WLAN_REASON_DEAUTH_LEAVING; body[1] = 0;
    txMgmtFrame(deauth, sizeof(*hdr) + 2);

    /* Notify driver */
    struct ieee80211_bss_conf *bss = &_vif->bss_conf;
    bss->assoc = false;
    bss->aid = 0;
    /* rtw_ops_bss_info_changed uses cfg.assoc, not the legacy bss field.
     * Clear both BEFORE the callback, otherwise disconnect re-enters the
     * firmware association path with the previous AP's AID. */
    _vif->cfg.assoc = false;
    _vif->cfg.aid = 0;
    _assocAID = 0;
    if (_hw->ops && _hw->ops->bss_info_changed)
        _hw->ops->bss_info_changed(_hw, _vif, bss, BSS_CHANGED_ASSOC);
    releaseSta();

    setRadioState(RTW88_STATE_IDLE);
    __atomic_store_n(&_scanReturnState, RTW88_STATE_IDLE, __ATOMIC_RELEASE);
    _scanPartial = false;
    _timer->cancelTimeout();
    if (_parent)
        _parent->setLinkStatus(kIONetworkLinkValid);
    if (_delegate)
        _delegate->rtw88Event(kRTW88EventDisconnected, nullptr);
}

/* ------------------------------------------------------------------ */
/*  WPA2 4-way handshake                                                */
/* ------------------------------------------------------------------ */

void RTW88IEEE80211::handleEAPOL(const uint8_t *data, uint32_t len)
{
    if (!__atomic_load_n(&_powered, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&_stopping, __ATOMIC_ACQUIRE) ||
        !data || len < 99 || data[1] != 3)
        return;

    uint16_t eapol_body_len = (uint16_t)((data[2] << 8) | data[3]);
    uint32_t eapol_len = 4 + eapol_body_len;
    if (eapol_len > len || eapol_len < 99)
        return;

    uint16_t key_info = (uint16_t)((data[5] << 8) | data[6]);
    if (data[4] != 2 || (key_info & 7) != 2 || (key_info & 0x0c00)) {
        IOLog("rtw88: unsupported EAPOL descriptor/flags ki=0x%04x\n", key_info);
        return;
    }
    bool is_m1 = (key_info & 0x0088) == 0x0088 && !(key_info & 0x0100);
    bool is_m3 = (key_info & 0x01c8) == 0x01c8;
    bool is_g1 = !(key_info & 0x0008) && (key_info & 0x13c0) == 0x1380;
    uint16_t key_data_len = (uint16_t)((data[97] << 8) | data[98]);

    IOLog("rtw88: EAPOL key_info=0x%04x key_data_len=%u M1=%d M3=%d G1=%d\n",
          key_info, key_data_len, is_m1, is_m3, is_g1);

    if (is_g1) {
        uint8_t replayCopy[8] = {};
        RTW88TxStateGate::TransmitLease txLease;
        {
            /* PTK, GTK, replay and handshake flags share one snapshot. Keep
             * WMM submissions out until G1 has been authenticated and GTK
             * installation is complete. */
            auto mutation = beginTxStateMutation();
            if (!__atomic_load_n(&_powered, __ATOMIC_ACQUIRE) ||
                __atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_CONNECTED ||
                !__atomic_load_n(&_m3KeysInstalled, __ATOMIC_ACQUIRE) || _handshakePending || !_ptkConf) {
                IOLog("rtw88: group M1 dropped: no established PTK state=%d\n",
                      (int)__atomic_load_n(&_state, __ATOMIC_ACQUIRE));
                return;
            }

            int ctr = memcmp(data + 9, _replayCtr, 8);
            if (ctr < 0) {
                IOLog("rtw88: stale group M1 dropped\n");
                return;
            }
            if (!eapol_mic_ok(_ptk, data, eapol_len)) {
                IOLog("rtw88: EAPOL group M1 MIC check failed\n");
                return;
            }
            if (!key_data_len || 99 + key_data_len > eapol_len) {
                IOLog("rtw88: EAPOL group M1 key data missing/truncated\n");
                return;
            }

            uint8_t unwrapped[256] = {};
            uint16_t unwrapped_len = 0;
            if (key_data_len > sizeof(unwrapped) + 8 ||
                !aes_unwrap_128(_ptk + 16, data + 99, key_data_len,
                                unwrapped, &unwrapped_len)) {
                IOLog("rtw88: failed to unwrap group M1 key data\n");
                return;
            }
            uint8_t gtk[32] = {};
            uint8_t gtk_len = 0;
            uint8_t gtk_idx = 0;
            if (!extract_gtk_from_kde(unwrapped, unwrapped_len,
                                      gtk, &gtk_len, &gtk_idx) || !gtk_len) {
                IOLog("rtw88: no GTK KDE found in group M1 key data\n");
                return;
            }

            if (ctr == 0 && (!_gtkConf || _gtkConf->keyidx != gtk_idx ||
                _gtkConf->keylen != gtk_len ||
                memcmp(_gtkConf->key, gtk, gtk_len) != 0)) {
                IOLog("rtw88: group M1 duplicate counter with different GTK; rejected\n");
                return;
            }

            uint32_t groupCipher =
                (_targetBSS.group_cipher == WLAN_CIPHER_SUITE_TKIP) ?
                WLAN_CIPHER_SUITE_TKIP : WLAN_CIPHER_SUITE_CCMP;
            if (!installKeyUnderMutation(&_gtkConf, false, gtk_idx,
                                         groupCipher, gtk, gtk_len, &mutation)) {
                IOLog("rtw88: group key install failed idx=%u len=%u\n",
                      gtk_idx, gtk_len);
                return;
            }

            memcpy(_replayCtr, data + 9, 8);
            memcpy(replayCopy, _replayCtr, sizeof(replayCopy));
            txLease = mutation.downgrade();
        }

        if (!txLease)
            return;
        bool sent = sendEAPOLKey(5, replayCopy, false, false, true, &txLease);
        IOLog("rtw88: group key handshake gtk response submission=%d\n", sent);
        return;
    }

    if (!is_m1 && !is_m3) {
        IOLog("rtw88: unsupported EAPOL key exchange ki=0x%04x\n", key_info);
        return;
    }

    if (is_m1) {
        uint8_t replayCopy[8] = {};
        RTW88TxStateGate::TransmitLease txLease;
        {
            /* Derive and publish the next PTK generation while all four WMM
             * submitters are excluded. The downgraded lease below keeps M2
             * tied to this exact SNonce/PTK/replay snapshot. */
            auto mutation = beginTxStateMutation();
            if (!__atomic_load_n(&_powered, __ATOMIC_ACQUIRE) ||
                (_snonceValid && memcmp(data + 9, _replayCtr, 8) < 0) ||
                (__atomic_load_n(&_m3KeysInstalled, __ATOMIC_ACQUIRE) &&
                 memcmp(data + 9, _installedM3ReplayCtr, 8) <= 0)) {
                IOLog("rtw88: stale M1 dropped\n");
                return;
            }

            bool fresh = !_snonceValid || memcmp(_anonce, data + 17, 32) != 0;
            if (fresh)
                read_random(_snonce, 32);
            memcpy(_anonce, data + 17, 32);
            _snonceValid = true;
            _handshakePending = true;
            derivePTK(_pmk, _anonce, _snonce, _macAddr, _targetBSS.bssid, _ptk);
            memcpy(_replayCtr, data + 9, 8);
            memcpy(replayCopy, _replayCtr, sizeof(replayCopy));
            __atomic_store_n(&_state, RTW88_STATE_HANDSHAKING, __ATOMIC_RELEASE);
            IOLog("rtw88: M1 fresh=%d rekey=%d\n", fresh, __atomic_load_n(&_m3KeysInstalled, __ATOMIC_ACQUIRE));
            txLease = mutation.downgrade();
        }

        if (!txLease)
            return;
        if (!sendEAPOLKey(2, replayCopy, false, false, true, &txLease))
            IOLog("rtw88: M2 submission failed; waiting for AP retry\n");
        uint64_t d;
        clock_interval_to_deadline(5000, kMillisecondScale, &d);
        _timer->wakeAtTime(d);
        return;
    }

    if (is_m3) {
        uint8_t replayCopy[8] = {};
        bool duplicate = false;
        RTW88TxStateGate::TransmitLease txLease;
        {
            /* Validate M3, verify its MIC, unwrap the GTK and install both
             * hardware keys while the writer side owns the entire key state.
             * No TX caller can see a mixed PTK/GTK generation. */
            auto mutation = beginTxStateMutation();
            if (!__atomic_load_n(&_powered, __ATOMIC_ACQUIRE) ||
                !_snonceValid || memcmp(data + 17, _anonce, 32) != 0 ||
                memcmp(data + 9, _replayCtr, 8) < 0 ||
                (!_handshakePending && !__atomic_load_n(&_m3KeysInstalled, __ATOMIC_ACQUIRE))) {
                IOLog("rtw88: M3 dropped: nonce/replay/handshake mismatch\n");
                return;
            }
            if (!eapol_mic_ok(_ptk, data, eapol_len)) {
                IOLog("rtw88: EAPOL M3 MIC check failed\n");
                return;
            }
            if (99 + key_data_len > eapol_len) {
                IOLog("rtw88: EAPOL M3 key data truncated\n");
                return;
            }

            uint8_t gtk[32] = {};
            uint8_t gtk_len = 0;
            uint8_t gtk_idx = 0;
            const uint8_t *key_data = data + 99;
            uint8_t unwrapped[256] = {};
            uint16_t unwrapped_len = 0;

            if (key_data_len) {
                if (key_info & 0x1000) {
                    if (key_data_len > sizeof(unwrapped) + 8) {
                        IOLog("rtw88: M3 wrapped data exceeds buffer\n");
                        return;
                    }
                    if (!aes_unwrap_128(_ptk + 16, key_data, key_data_len,
                                        unwrapped, &unwrapped_len)) {
                        IOLog("rtw88: failed to unwrap GTK key data\n");
                        return;
                    }
                    key_data = unwrapped;
                    key_data_len = unwrapped_len;
                }

                if (!extract_gtk_from_kde(key_data, key_data_len,
                                          gtk, &gtk_len, &gtk_idx))
                    IOLog("rtw88: no GTK KDE found in M3 key data\n");
            }

            duplicate = __atomic_load_n(&_m3KeysInstalled, __ATOMIC_ACQUIRE) && !_handshakePending;
            if (duplicate &&
                (!_ptkConf || memcmp(_ptkConf->key, _ptk + 32, 16) != 0 ||
                 (gtk_len && (!_gtkConf || _gtkConf->keyidx != gtk_idx ||
                  _gtkConf->keylen != gtk_len ||
                  memcmp(_gtkConf->key, gtk, gtk_len) != 0)))) {
                IOLog("rtw88: M3 retry changed key material without M1; rejected\n");
                return;
            }

            if (!installKeyUnderMutation(&_ptkConf, true, 0,
                                         WLAN_CIPHER_SUITE_CCMP,
                                         _ptk + 32, 16, &mutation)) {
                IOLog("rtw88: pairwise key install failed\n");
                return;
            }
            uint32_t groupCipher =
                (_targetBSS.group_cipher == WLAN_CIPHER_SUITE_TKIP) ?
                WLAN_CIPHER_SUITE_TKIP : WLAN_CIPHER_SUITE_CCMP;
            if (gtk_len &&
                !installKeyUnderMutation(&_gtkConf, false, gtk_idx,
                                         groupCipher, gtk, gtk_len,
                                         &mutation)) {
                IOLog("rtw88: group key install failed during M3\n");
                return;
            }

            memcpy(_replayCtr, data + 9, 8);
            memcpy(_installedM3ReplayCtr, _replayCtr, 8);
            __atomic_store_n(&_m3KeysInstalled, true, __ATOMIC_RELEASE);
            _handshakePending = false;
            memcpy(replayCopy, _replayCtr, sizeof(replayCopy));
            txLease = mutation.downgrade();
        }

        if (!txLease)
            return;
        if (!sendEAPOLKey(4, replayCopy, false, false, true, &txLease)) {
            IOLog("rtw88: M4 submission failed; awaiting M3 retry\n");
            return;
        }
        txLease.reset();

        {
            auto mutation = beginTxStateMutation();
            __atomic_store_n(&_associatedVisible, true, __ATOMIC_RELEASE);
            __atomic_store_n(&_state, RTW88_STATE_CONNECTED, __ATOMIC_RELEASE);
            __atomic_store_n(&_dataTxBlocked, false, __ATOMIC_RELEASE);
            mutation.finish();
        }
        _timer->cancelTimeout();
        if (_parent)
            _parent->setLinkStatus(kIONetworkLinkActive | kIONetworkLinkValid);
        if (!duplicate)
            startTxAggregation();
        IOLog("rtw88: WPA2 connected! gtk_len=%u gtk_idx=%u\n", gtk_len, gtk_idx);
        if (!_externalSupplicant && _delegate)
            _delegate->rtw88Event(kRTW88EventConnected, nullptr);
    }
}

bool RTW88IEEE80211::sendEAPOLKey(
    int step, const uint8_t *replay_counter, bool install, bool ack, bool mic,
    RTW88TxStateGate::TransmitLease *existingLease)
{
    /* Hold a reader from key/nonce snapshot through the synchronous RTW88
     * submission. A caller may pass the reader produced by writer downgrade
     * to preserve one exact handshake generation without an admission gap. */
    RTW88TxStateGate::TransmitLease localLease;
    if (!existingLease) {
        localLease = _txStateGate.tryEnterTransmit();
        if (!localLease)
            return false;
        existingLease = &localLease;
    } else if (!*existingLease) {
        return false;
    }

    uint8_t frame[512] = {};
    uint8_t *eth = frame;
    memcpy(eth,     _targetBSS.bssid, 6);
    memcpy(eth + 6, _macAddr, 6);
    eth[12] = 0x88; eth[13] = 0x8e;

    uint8_t *eapol = eth + 14;
    eapol[0] = 2;
    eapol[1] = 3;

    uint8_t *key = eapol + 4;
    key[0] = 2;
    uint16_t ki = (step == 5) ? 0x0002 : 0x000A;
    if (mic)     ki |= 0x0100;
    if (install) ki |= 0x0040;
    if (ack)     ki |= 0x0080;
    if (step == 4 || step == 5) ki |= 0x0200;
    key[1] = (uint8_t)(ki >> 8);
    key[2] = (uint8_t)(ki & 0xff);
    key[3] = 0; key[4] = 0;
    memcpy(key + 5, replay_counter, 8);
    if (step == 2) memcpy(key + 13, _snonce, 32);

    uint16_t key_data_len = 0;
    if (step == 2) {
        key_data_len = rtw88BuildSelectedRsnIe(eapol + 99, _targetBSS.group_cipher);
        if (99 + key_data_len > sizeof(frame) - 14)
            key_data_len = 0;
    }

    key[93] = (uint8_t)(key_data_len >> 8);
    key[94] = (uint8_t)(key_data_len & 0xff);

    uint16_t eapol_key_len = (uint16_t)(95 + key_data_len);
    uint32_t eapol_total = 4 + eapol_key_len;
    eapol[2] = (uint8_t)(eapol_key_len >> 8);
    eapol[3] = (uint8_t)(eapol_key_len & 0xff);

    if (mic) {
        uint8_t mic_buf[20];
        kern_hmac_sha1(_ptk, 16, eapol, eapol_total, mic_buf);
        memcpy(key + 77, mic_buf, 16);
    }

    uint32_t ethlen = 14 + eapol_total;
    mbuf_t m = rtw88_make_packet_mbuf(frame, ethlen);
    if (!m) return false;

    /* Protection is a per-frame property. Group M2 is protected with the PTK;
     * other handshake steps keep the established path. */
    const bool protectEapol = (step == 5);
    bool submitted = txDataFrame(m, nullptr, nullptr, nullptr, 2, 0,
                                 protectEapol, true, existingLease);
    IOLog("rtw88: EAPOL %s%d submission=%d len=%u\n", step == 5 ? "G" : "M",
          step == 5 ? 2 : step, submitted, ethlen);
    return submitted;
}

/*  Frame TX helpers                                                    */
/* ------------------------------------------------------------------ */

bool RTW88IEEE80211::txRawManagementFrame(const uint8_t *frame, uint32_t len)
{
    auto txLease = _txStateGate.tryEnterTransmit();
    if (!txLease || !frame || len < 24 || len > 4096)
        return false;

    uint16_t fc = (uint16_t)frame[0] | ((uint16_t)frame[1] << 8);
    if ((fc & 0x000c) != 0x0000)
        return false;

    if (len >= 40 && RTW88AWDL::actionHeader(frame + 24, len - 24) && !canTransmitAWDL())
        return false;
    return txMgmtFrame(frame, len, &txLease);
}

bool RTW88IEEE80211::txMgmtFrame(
    const uint8_t *frame, uint32_t len,
    RTW88TxStateGate::TransmitLease *existingLease)
{
    RTW88TxStateGate::TransmitLease localLease;
    if (!existingLease) {
        localLease = _txStateGate.tryEnterTransmit();
        if (!localLease)
            return false;
    } else if (!*existingLease) {
        return false;
    }

    if (!_powered || !frame || len < 24 || len > 4096 ||
        !_hw || !_hw->ops || !_hw->ops->tx || !_vif)
        return false;

    struct sk_buff *skb = alloc_skb(len + 128, GFP_ATOMIC);
    if (!skb) return false;
    skb_reserve(skb, 128);
    skb_put_data(skb, frame, len);

    struct ieee80211_tx_info *info = IEEE80211_SKB_CB(skb);
    memset(info, 0, sizeof(*info));
    info->flags = IEEE80211_TX_CTL_FIRST_FRAGMENT;
    if (frame[4] & 1) info->flags |= IEEE80211_TX_CTL_NO_ACK;
    else info->flags |= IEEE80211_TX_CTL_REQ_TX_STATUS;
    info->control.vif = _vif;

    struct ieee80211_tx_control ctrl = { .sta = nullptr };
    _hw->ops->tx(_hw, &ctrl, skb);
    return true;
}

/*  A-MPDU BlockAck negotiation                                          */
/*                                                                      */
/*  802.11n/ac throughput depends on A-MPDU aggregation, which requires */
/*  a per-TID BlockAck agreement negotiated over the air with ADDBA     */
/*  action frames (category 3 = BACK).  mac80211 normally does this; we  */
/*  bypass mac80211, so the MLME drives it here:                         */
/*    - TX (uplink) agg: we send an ADDBA Request and, on a successful   */
/*      ADDBA Response, tag our data frames with IEEE80211_TX_CTL_AMPDU. */
/*    - RX (downlink) agg: we answer the AP's ADDBA Request; Realtek HW  */
/*      then auto-generates the RX BlockAck and de-aggregates for us     */
/*      (rtw88's ampdu_action is a no-op for RX_START/STOP).             */
/* ------------------------------------------------------------------ */

void RTW88IEEE80211::sendAddbaRequest(
    uint8_t tid, RTW88TxStateGate::TransmitLease *existingLease)
{
    RTW88TxStateGate::TransmitLease localLease;
    if (!existingLease) {
        localLease = _txStateGate.tryEnterTransmit();
        if (!localLease)
            return;
        existingLease = &localLease;
    } else if (!*existingLease) {
        return;
    }

    uint8_t dialog = 0;
    if (_lock) IOLockLock(_lock);
    if (_txBaPending) {
        if (_lock) IOLockUnlock(_lock);
        return;
    }
    dialog = static_cast<uint8_t>(_baDialog + 1U);
    if (dialog == 0) dialog = 1;
    _baDialog = dialog;
    _txBaPending = true;
    _baRecovery.onRequestSent(rtw88JoinNowUS());
    if (_lock) IOLockUnlock(_lock);

    uint8_t f[24 + 9] = {};
    struct ieee80211_hdr_3addr *h = (struct ieee80211_hdr_3addr *)f;
    h->frame_control = cpu_to_le16(IEEE80211_FTYPE_MGMT | IEEE80211_STYPE_ACTION);
    h->duration_id   = 0;
    memcpy(h->addr1, _targetBSS.bssid, 6);
    memcpy(h->addr2, _macAddr, 6);
    memcpy(h->addr3, _targetBSS.bssid, 6);
    h->seq_ctrl = cpu_to_le16((uint16_t)(nextTxSequence() & 0xFFF) << 4);

    uint8_t *b = f + 24;
    b[0] = WLAN_CATEGORY_BACK;
    b[1] = WLAN_ACTION_ADDBA_REQ;
    b[2] = dialog;
    uint16_t param = (uint16_t)((1u << 1) |
                                ((unsigned)(tid & 0xf) << 2) |
                                ((unsigned)(_baBufSize & 0x3ff) << 6));
    b[3] = (uint8_t)(param & 0xff);
    b[4] = (uint8_t)(param >> 8);
    b[5] = 0; b[6] = 0;
    uint16_t ssc = (uint16_t)((uint16_t)(currentDataSequence(tid) & 0xFFF) << 4);
    b[7] = (uint8_t)(ssc & 0xff);
    b[8] = (uint8_t)(ssc >> 8);

    const bool submitted = txMgmtFrame(f, sizeof(f), existingLease);
    if (_lock) IOLockLock(_lock);
    if (!submitted && _txBaPending && _baDialog == dialog) {
        _txBaPending = false;
        _baRecovery.onFailed(rtw88JoinNowUS());
    }
    if (_lock) IOLockUnlock(_lock);
}

void RTW88IEEE80211::sendAddbaResponse(uint8_t tid, uint8_t dialog,
                                       uint16_t req_param, uint16_t ba_timeout,
                                       uint16_t status)
{
    auto txLease = _txStateGate.tryEnterTransmit();
    if (!txLease)
        return;
    uint8_t f[24 + 9] = {};
    struct ieee80211_hdr_3addr *h = (struct ieee80211_hdr_3addr *)f;
    h->frame_control = cpu_to_le16(IEEE80211_FTYPE_MGMT | IEEE80211_STYPE_ACTION);
    h->duration_id   = 0;
    memcpy(h->addr1, _targetBSS.bssid, 6);
    memcpy(h->addr2, _macAddr, 6);
    memcpy(h->addr3, _targetBSS.bssid, 6);
    h->seq_ctrl = cpu_to_le16((uint16_t)(nextTxSequence() & 0xFFF) << 4);

    uint8_t *b = f + 24;
    b[0] = WLAN_CATEGORY_BACK;
    b[1] = WLAN_ACTION_ADDBA_RESP;
    b[2] = dialog;
    b[3] = (uint8_t)(status & 0xff);
    b[4] = (uint8_t)(status >> 8);
    uint16_t param = (uint16_t)((unsigned)(req_param & 0x0001u) |
                                (1u << 1) |
                                ((unsigned)(tid & 0xf) << 2) |
                                ((unsigned)(_baBufSize & 0x3ff) << 6));
    b[5] = (uint8_t)(param & 0xff);
    b[6] = (uint8_t)(param >> 8);
    b[7] = (uint8_t)(ba_timeout & 0xff);
    b[8] = (uint8_t)(ba_timeout >> 8);

    txMgmtFrame(f, sizeof(f), &txLease);
}

/* The HT restriction applies to the pairwise cipher. A mixed WPA/WPA2 AP
 * may use TKIP for group traffic while this station negotiates CCMP for
 * unicast. Do not disable HT/VHT and unicast A-MPDU for that combination. */
bool RTW88IEEE80211::htAllowed() const
{
    /* Only the supported open/CCMP pairwise paths may use HT. Unknown and
     * legacy pairwise ciphers fail closed; the group key remains unchanged. */
    return _targetBSS.cipher == 0 ||
           _targetBSS.cipher == WLAN_CIPHER_SUITE_CCMP;
}

void RTW88IEEE80211::startTxAggregation()
{
    auto txLease = _txStateGate.tryEnterTransmit();
    if (!txLease)
        return;
    if (_txBAState.active())
        return;
    if (!htAllowed() || !_sta || !_sta->deflink.ht_cap.ht_supported) {
        if (_lock) IOLockLock(_lock);
        _baRecovery.cancel();
        if (_lock) IOLockUnlock(_lock);
        return;
    }

    if (_lock) IOLockLock(_lock);
    const bool alreadyPending = _txBaPending;
    if (_lock) IOLockUnlock(_lock);
    if (alreadyPending)
        return;

    IOLog("rtw88: starting TX A-MPDU — sending ADDBA request (tid=%u)\n", _baTid);
    sendAddbaRequest(_baTid, &txLease);
}

/* Called about every 5 s while the radio is up.  Re-negotiates the uplink Block
 * Ack agreement after the AP declined it, never answered, or tore it down.
 * Idempotent and safe to skip: a missed tick only delays the next attempt. */
void RTW88IEEE80211::housekeeping()
{
    auto txLease = _txStateGate.tryEnterTransmit();
    if (!txLease || __atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_CONNECTED ||
        !associatedVisible() || !_sta || _handshakePending)
        return;

    const uint64_t now = rtw88JoinNowUS();
    bool retry = false;
    if (_lock) IOLockLock(_lock);
    if (_txBaPending && _baRecovery.responseOverdue(now)) {
        _txBaPending = false;
        _baRecovery.onFailed(now);
        IOLog("rtw88: TX ADDBA response timed out; will retry\n");
    }
    retry = !_txBAState.active() && !_txBaPending && _baRecovery.due(now);
    if (_lock) IOLockUnlock(_lock);

    if (retry)
        startTxAggregation();
}

void RTW88IEEE80211::handleBackAction(const uint8_t *b, uint32_t len)
{
    if (len < 2) return;
    switch (b[1]) {   /* BlockAck action field */
    case WLAN_ACTION_ADDBA_REQ: {
        /* AP wants to aggregate downlink traffic to us — accept it and stand
         * up an RX reorder buffer for the TID so we deliver in order. */
        if (len < 9) return;
        uint8_t  dialog    = b[2];
        uint16_t req_param = (uint16_t)(b[3] | (b[4] << 8));
        uint16_t ba_to     = (uint16_t)(b[5] | (b[6] << 8));
        uint16_t ssc       = (uint16_t)(b[7] | (b[8] << 8));
        uint8_t  tid       = (uint8_t)((req_param >> 2) & 0xf);
        uint16_t bufsz     = (uint16_t)((req_param >> 6) & 0x3ff);
        uint16_t ssn       = (uint16_t)(ssc >> 4);
        /* The RX reorder table only tracks QoS TIDs 0..7 (rxBaSetup ignores
         * the rest). Decline other TIDs instead of acknowledging an
         * agreement that has no reorder state behind it. */
        if (tid >= kRxBaNumTid) {
            sendAddbaResponse(tid, dialog, req_param, ba_to,
                              37 /* WLAN_STATUS_REQUEST_DECLINED */);
            IOLog("rtw88: RX ADDBA request (tid=%u buf=%u) — declined, "
                  "unsupported TID\n", tid, bufsz);
            break;
        }
        rxBaSetup(tid, ssn, bufsz);
        sendAddbaResponse(tid, dialog, req_param, ba_to);
        IOLog("rtw88: RX ADDBA request (tid=%u ssn=%u buf=%u) — accepted, "
              "downlink A-MPDU on\n", tid, ssn, bufsz);
        break;
    }
    case WLAN_ACTION_ADDBA_RESP: {
        /* Response to our TX ADDBA request. */
        if (len < 9) return;
        uint16_t status = (uint16_t)(b[3] | (b[4] << 8));
        uint16_t param  = (uint16_t)(b[5] | (b[6] << 8));
        uint8_t  tid    = (uint8_t)((param >> 2) & 0xf);
        bool matched = false;
        bool accepted = false;
        auto mutation = beginTxStateMutation();
        if (_lock) IOLockLock(_lock);
        if (_txBaPending && b[2] == _baDialog && tid == _baTid) {
            matched = true;
            _txBaPending = false;
            accepted = status == 0 && (param & (1u << 1));
            if (accepted) {
                _txBAState.activate(tid);
                _baRecovery.onAccepted(rtw88JoinNowUS());
            } else {
                _baRecovery.onFailed(rtw88JoinNowUS());
            }
        }
        if (_lock) IOLockUnlock(_lock);
        mutation.finish();
        if (!matched) break;
        if (accepted)
            IOLog("rtw88: TX ADDBA accepted (tid=%u) — uplink A-MPDU on\n", tid);
        else
            IOLog("rtw88: TX ADDBA rejected status=%u tid=%u; will retry\n", status, tid);
        break;
    }
    case WLAN_ACTION_DELBA: {
        if (len < 6) return;
        uint16_t del_param = (uint16_t)(b[2] | (b[3] << 8));
        uint8_t  tid       = (uint8_t)((del_param >> 12) & 0xf);
        bool     initiator = (del_param & (1u << 11)) != 0;
        /* initiator=0: AP is the recipient of the agreement it is tearing down
         * — our uplink TX BA, so stop aggregating.  initiator=1: AP is the
         * originator — its downlink BA, so drop our RX reorder buffer. */
        const uint16_t reason = (uint16_t)(b[4] | (b[5] << 8));   /* 37 declined, 38 unknown BA, 39 timeout */
        bool tore = false;
        bool wasActive = false;
        auto mutation = beginTxStateMutation();
        if (_lock) IOLockLock(_lock);
        tore = !initiator && tid == _baTid;
        wasActive = _txBAState.active();
        if (tore) {
            _txBAState.clear();
            _txBaPending = false;
            _baRecovery.onTornDown(rtw88JoinNowUS());
        }
        if (_lock) IOLockUnlock(_lock);
        mutation.finish();
        if (initiator)
            rxBaTeardown(tid);
        IOLog("rtw88: RX DELBA tid=%u initiator=%d reason=%u uplink_was_active=%d%s\n",
              tid, initiator, reason, wasActive, tore ? " — will re-negotiate" : "");
        break;
    }
    default:
        break;
    }
}

bool RTW88IEEE80211::txNullFunc(
    bool powerSave, RTW88TxStateGate::TransmitLease *existingLease)
{
    RTW88TxStateGate::TransmitLease localLease;
    if (!existingLease) {
        localLease = _txStateGate.tryEnterTransmit();
        if (!localLease)
            return false;
    } else if (!*existingLease) {
        return false;
    }
    if (!_powered || !_hw || !_hw->ops || !_hw->ops->tx || !_vif || !_sta)
        return false;

    static const uint16_t IEEE80211_STYPE_NULLFUNC = 0x0040;
    struct sk_buff *skb = alloc_skb(24 + 128, GFP_ATOMIC);
    if (!skb) return false;
    skb_reserve(skb, 128);

    struct ieee80211_hdr_3addr *h =
        (struct ieee80211_hdr_3addr *)skb_put(skb, 24);
    uint16_t fc = IEEE80211_FTYPE_DATA | IEEE80211_STYPE_NULLFUNC |
                  IEEE80211_FCTL_TODS;
    if (powerSave)
        fc |= IEEE80211_FCTL_PM;
    h->frame_control = cpu_to_le16(fc);
    h->duration_id   = 0;
    memcpy(h->addr1, _targetBSS.bssid, 6);
    memcpy(h->addr2, _macAddr, 6);
    memcpy(h->addr3, _targetBSS.bssid, 6);
    h->seq_ctrl = cpu_to_le16((uint16_t)(nextTxSequence() & 0xFFF) << 4);

    skb_set_queue_mapping(skb, IEEE80211_AC_BE);
    skb->priority = 0;

    struct ieee80211_tx_info *info = IEEE80211_SKB_CB(skb);
    memset(info, 0, sizeof(*info));
    info->flags = IEEE80211_TX_CTL_FIRST_FRAGMENT;
    info->band  = (_targetBSS.channel > 14) ? NL80211_BAND_5GHZ
                                            : NL80211_BAND_2GHZ;
    info->control.vif = _vif;
    info->control.sta = _sta;

    struct ieee80211_tx_control ctrl = { .sta = _sta };
    _hw->ops->tx(_hw, &ctrl, skb);
    return true;
}

bool RTW88IEEE80211::txProbeRequest()
{
    auto txLease = _txStateGate.tryEnterTransmit();
    if (!txLease || !__atomic_load_n(&_powered, __ATOMIC_ACQUIRE) ||
        !_hw || !_hw->ops || !_hw->ops->tx)
        return false;

    uint8_t frame[128] = {};
    struct ieee80211_hdr_3addr *hdr =
        (struct ieee80211_hdr_3addr *)frame;
    hdr->frame_control =
        cpu_to_le16(IEEE80211_FTYPE_MGMT | IEEE80211_STYPE_PROBE_REQ);
    memset(hdr->addr1, 0xff, 6);
    memcpy(hdr->addr2, _macAddr, 6);
    memset(hdr->addr3, 0xff, 6);
    hdr->seq_ctrl = cpu_to_le16((uint16_t)(nextTxSequence() & 0xFFF) << 4);

    uint8_t *body = frame + sizeof(*hdr);
    body[0] = WLAN_EID_SSID;
    body[1] = 0;
    body += 2;

    static const uint8_t rates_2g[] = {
        0x82, 0x84, 0x8b, 0x96, 0x0c, 0x12, 0x18, 0x24
    };
    static const uint8_t rates_5g[] = {
        0x8c, 0x12, 0x98, 0x24, 0x30, 0x48, 0x60, 0x6c
    };
    bool is5g = _hw->conf.chandef.chan &&
                _hw->conf.chandef.chan->band == NL80211_BAND_5GHZ;
    const uint8_t *rates = is5g ? rates_5g : rates_2g;
    uint8_t ratesLen = is5g ? sizeof(rates_5g) : sizeof(rates_2g);

    body[0] = WLAN_EID_SUPP_RATES;
    body[1] = ratesLen;
    memcpy(body + 2, rates, ratesLen);
    body += 2 + ratesLen;

    return txMgmtFrame(frame, (uint32_t)(body - frame), &txLease);
}

/* AWDL uses a direct 802.11 data frame, not the infrastructure ToDS path.
 * The payload format is:
 *   802.11(24) | SNAP(00:17:f2, PID 0x0800) | AWDL data(8) | L3 payload
 * The Realtek tx core explicitly supports data frames with sta == nullptr,
 * selecting the vif MAC-ID and conservative 6 Mbps/20 MHz defaults. */
bool RTW88IEEE80211::txAWDLDataFrame(mbuf_t m)
{
    auto txLease = _txStateGate.tryEnterTransmit();
    if (!txLease) { if (m) mbuf_freem(m); return false; }
    if (!m || !_powered || !_awdlReceiveMode ||
        (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_IDLE && __atomic_load_n(&_state, __ATOMIC_ACQUIRE) != RTW88_STATE_CONNECTED) ||
        !_hw || !_hw->ops || !_hw->ops->tx || !_vif ||
        !_hw->conf.chandef.chan || !_awdlChannel ||
        _hw->conf.chandef.chan->hw_value != _awdlChannel) {
        if (m) mbuf_freem(m);
        return false;
    }

    size_t total = mbuf_pkthdr_len(m);
    if (total < 14 || total > 4096) {
        mbuf_freem(m);
        return false;
    }

    uint8_t eh[14] = {};
    if (mbuf_copydata(m, 0, sizeof(eh), eh) != 0) {
        mbuf_freem(m);
        return false;
    }
    const uint16_t ethertype = (uint16_t)((eh[12] << 8) | eh[13]);
    const uint32_t paylen = (uint32_t)total - 14;

    /* 24-byte 802.11 header + 8-byte AWDL SNAP + 8-byte AWDL data header. */
    const uint32_t framelen = 24 + 8 + 8 + paylen;
    struct sk_buff *skb = alloc_skb(framelen + 128, GFP_ATOMIC);
    if (!skb) {
        mbuf_freem(m);
        return false;
    }
    skb_reserve(skb, 128);

    struct ieee80211_hdr_3addr *h =
        (struct ieee80211_hdr_3addr *)skb_put(skb, 24);
    bzero(h, sizeof(*h));
    h->frame_control = cpu_to_le16(IEEE80211_FTYPE_DATA);
    memcpy(h->addr1, eh, 6);       /* peer / multicast destination */
    memcpy(h->addr2, _awdlAddress, 6); /* Same virtual identity as action frames. */
    static const uint8_t awdlBssid[6] = {0x00,0x25,0x00,0xff,0x94,0x73};
    memcpy(h->addr3, awdlBssid, sizeof(awdlBssid));
    h->seq_ctrl = cpu_to_le16((uint16_t)(nextTxSequence() & 0x0fff) << 4);

    /* LLC/SNAP with Apple's AWDL OUI and AWDL protocol ID 0x0800. */
    uint8_t *snap = skb_put(skb, 8);
    snap[0] = 0xaa; snap[1] = 0xaa; snap[2] = 0x03;
    snap[3] = 0x00; snap[4] = 0x17; snap[5] = 0xf2;
    snap[6] = 0x08; snap[7] = 0x00;

    /* AWDL data header: LE magic 0x0403, LE sequence, zero pad, BE EtherType. */
    uint8_t *aw = skb_put(skb, 8);
    aw[0] = 0x03; aw[1] = 0x04;
    uint16_t seq = __atomic_fetch_add(&_awdlDataSeq, 1, __ATOMIC_RELAXED);
    aw[2] = (uint8_t)(seq & 0xff); aw[3] = (uint8_t)(seq >> 8);
    aw[4] = 0; aw[5] = 0;
    aw[6] = (uint8_t)(ethertype >> 8); aw[7] = (uint8_t)ethertype;

    if (paylen) {
        uint8_t *payload = skb_put(skb, paylen);
        if (mbuf_copydata(m, 14, paylen, payload) != 0) {
            kfree_skb(skb);
            mbuf_freem(m);
            return false;
        }
    }

    skb_set_queue_mapping(skb, IEEE80211_AC_BE);
    skb->priority = 0;
    skb->protocol = cpu_to_be16(ethertype);

    struct ieee80211_tx_info *info = IEEE80211_SKB_CB(skb);
    memset(info, 0, sizeof(*info));
    info->flags = IEEE80211_TX_CTL_FIRST_FRAGMENT;
    if (eh[0] & 1) info->flags |= IEEE80211_TX_CTL_NO_ACK;
    info->band = (_hw->conf.chandef.chan &&
                  _hw->conf.chandef.chan->band == NL80211_BAND_5GHZ)
                   ? NL80211_BAND_5GHZ : NL80211_BAND_2GHZ;
    info->control.vif = _vif;
    info->control.sta = nullptr;

    struct ieee80211_tx_control ctrl = { .sta = nullptr };
    _hw->ops->tx(_hw, &ctrl, skb);
    mbuf_freem(m);
    return true;
}

/* Detect the AWDL data envelope before applying infrastructure association
 * rules. Returns true when ownership of skb was consumed. */
bool RTW88IEEE80211::tryDeliverAWDLDataFrame(struct sk_buff *skb)
{
    if (!_awdlReceiveMode || !skb || skb->len < 24 + 8 + 8)
        return false;

    struct ieee80211_hdr *hdr = (struct ieee80211_hdr *)skb->data;
    uint16_t fc = le16_to_cpu(hdr->frame_control);
    if ((fc & (IEEE80211_FCTL_TODS | IEEE80211_FCTL_FROMDS)) != 0)
        return false;

    static const uint8_t awdlBssid[6] = {0x00,0x25,0x00,0xff,0x94,0x73};
    if (memcmp(hdr->addr3, awdlBssid, sizeof(awdlBssid)) != 0)
        return false;

    uint16_t hdrlen = ieee80211_get_hdrlen_from_skb(skb);
    if (hdrlen < 24 || skb->len < (uint32_t)hdrlen + 16)
        return false;

    const uint8_t *p = skb->data + hdrlen;
    // QoS A-MSDU starts with a subframe Ethernet header, not LLC/SNAP.
    // Reject encrypted/fragmented envelopes: this path has no reassembly or
    // decryption contract. Consume recognized AWDL aggregates on all paths.
    if (fc & (0x4000 | 0x0400) || (le16_to_cpu(hdr->seq_ctrl) & 15)) {
        kfree_skb(skb);
        return true;
    }
    if ((fc & 0x0080) && (skb->data[24] & 0x80)) {
        if (!(hdr->addr1[0] & 1) && memcmp(hdr->addr1, _awdlAddress, 6)) {
            kfree_skb(skb);
            return true;
        }
        RTW88AWDL::receiveAggregate(p, skb->len - hdrlen, _awdlAddress,
            [&](const uint8_t *da, const uint8_t *sa, uint16_t type,
                const uint8_t *payload, size_t length) {
                deliverAWDLEthernet(da, sa, type, payload, (uint32_t)length);
            });
        kfree_skb(skb);
        return true;
    }
    /* SNAP AA AA 03 00 17 F2 08 00 */
    if (p[0] != 0xaa || p[1] != 0xaa || p[2] != 0x03 ||
        p[3] != 0x00 || p[4] != 0x17 || p[5] != 0xf2 ||
        p[6] != 0x08 || p[7] != 0x00)
        return false;
    p += 8;

    if (p[0] != 0x03 || p[1] != 0x04) /* LE 0x0403 */
        return false;
    uint16_t ethertype = (uint16_t)((p[6] << 8) | p[7]);
    p += 8;
    uint32_t paylen = (uint32_t)(skb->data + skb->len - p);

    // Promiscuous reception also hears other AWDL peers' unicast traffic.
    // Consume that envelope without injecting it into this host's awdl0.
    if ((hdr->addr1[0] & 1) || memcmp(hdr->addr1, _awdlAddress, 6) == 0)
        deliverAWDLEthernet(hdr->addr1, hdr->addr2, ethertype, p, paylen);
    kfree_skb(skb);
    return true;
}

void RTW88IEEE80211::deliverAWDLEthernet(const uint8_t *da, const uint8_t *sa,
                                         uint16_t ethertype,
                                         const uint8_t *payload, uint32_t paylen)
{
    if (!_parent || !da || !sa || (!payload && paylen))
        return;
    mbuf_t m = _parent->allocateInputPacket(14 + paylen);
    if (!m)
        return;

    uint8_t eh[14];
    memcpy(eh, da, 6);
    memcpy(eh + 6, sa, 6);
    eh[12] = (uint8_t)(ethertype >> 8);
    eh[13] = (uint8_t)ethertype;
    if (mbuf_copyback(m, 0, sizeof(eh), eh, MBUF_WAITOK) != 0 ||
        (paylen && mbuf_copyback(m, 14, paylen, payload, MBUF_WAITOK) != 0)) {
        mbuf_freem(m);
        return;
    }
    _parent->injectRxAWDLFrame(m);
}

uint16_t RTW88IEEE80211::nextTxSequence()
{
    return _txSequenceNumbers.nextNonQoS();
}

uint16_t RTW88IEEE80211::nextDataSequence(uint8_t tid)
{
    return _txSequenceNumbers.nextQoS(tid);
}

uint16_t RTW88IEEE80211::currentDataSequence(uint8_t tid) const
{
    return _txSequenceNumbers.currentQoS(tid);
}

bool RTW88IEEE80211::txDataFrame(mbuf_t m,
                                  RTW88TxCompletionCallback callback,
                                  void *completionContext,
                                  void *completionCookie,
                                  uint8_t accessCategory,
                                  uint8_t tid,
                                  bool protectEapol,
                                  bool allowHandshakeEapol,
                                  RTW88TxStateGate::TransmitLease *existingLease)
{
    RTW88TxStateGate::TransmitLease localLease;
    if (!existingLease) {
        localLease = _txStateGate.tryEnterTransmit();
        if (!localLease) {
            if (m) mbuf_freem(m);
            return false;
        }
    } else if (!*existingLease) {
        if (m) mbuf_freem(m);
        return false;
    }

    if (!m || !_powered || !_hw || !_hw->ops || !_hw->ops->tx ||
        !_vif || !_sta || !associatedVisible() ||
        accessCategory >= IEEE80211_NUM_ACS || tid > 7) {
        if (m) mbuf_freem(m);
        return false;
    }

    size_t total = mbuf_pkthdr_len(m);
    if (total < 14 || total > 2048) { mbuf_freem(m); return false; }
    uint32_t paylen = (uint32_t)total - 14;

    uint8_t eh[14];
    if (mbuf_copydata(m, 0, 14, eh) != 0) { mbuf_freem(m); return false; }
    uint16_t ethertype = (uint16_t)((eh[12] << 8) | eh[13]);
    const bool eapol = ethertype == ETH_P_PAE;
    const bool dataBlocked = __atomic_load_n(&_dataTxBlocked, __ATOMIC_ACQUIRE);
    const bool externalEapolAllowed =
        _externalSupplicant && _wpa2 && !externalKeysReady();
    if (dataBlocked && !(eapol && (allowHandshakeEapol || externalEapolAllowed))) {
        mbuf_freem(m);
        return false;
    }

    if (eapol) {
        IOLog("rtw88: EAPOL TX external=%d state=%d ptk=%p len=%u\n",
              _externalSupplicant, __atomic_load_n(&_state, __ATOMIC_ACQUIRE), _ptkConf, paylen);
    }

    const bool protected_frame = RTW88ShouldProtectTxFrame(
        _wpa2, _ptkConf != nullptr, ethertype, ETH_P_PAE, protectEapol);

    bool qos = htAllowed();
    uint32_t framelen = (qos ? 26 : 24) + (protected_frame ? 8 : 0) + 8 + paylen;
    struct sk_buff *skb = alloc_skb(framelen + 128, GFP_ATOMIC);
    if (!skb) { mbuf_freem(m); return false; }
    skb_reserve(skb, 128);

    struct ieee80211_hdr_3addr *h =
        (struct ieee80211_hdr_3addr *)skb_put(skb, 24);
    uint16_t fc = IEEE80211_FTYPE_DATA | IEEE80211_FCTL_TODS;
    if (qos) fc |= IEEE80211_STYPE_QOS_DATA;
    if (protected_frame) fc |= IEEE80211_FCTL_PROTECTED;
    h->frame_control = cpu_to_le16(fc);
    h->duration_id   = 0;
    memcpy(h->addr1, _targetBSS.bssid, 6);
    memcpy(h->addr2, _macAddr, 6);
    memcpy(h->addr3, eh, 6);
    h->seq_ctrl = cpu_to_le16((uint16_t)((qos ? nextDataSequence(tid) : nextTxSequence()) & 0xFFF) << 4);

    if (qos) {
        uint8_t *qosc = skb_put(skb, 2);
        qosc[0] = (uint8_t)(tid & IEEE80211_QOS_CTL_TID_MASK);
        qosc[1] = 0;
    }

    if (protected_frame) {
        uint64_t packetNumber = 0;
        if (!_txSequenceNumbers.nextCCMP(&packetNumber)) {
            kfree_skb(skb);
            mbuf_freem(m);
            IOLog("rtw88: CCMP TX packet number exhausted; dropping frame\n");
            return false;
        }

        uint8_t *ccmp = skb_put(skb, 8);
        ccmp[0] = static_cast<uint8_t>(packetNumber);
        ccmp[1] = static_cast<uint8_t>(packetNumber >> 8);
        ccmp[2] = 0x00;
        ccmp[3] = (uint8_t)(0x20 | (((uint8_t)_ptkConf->keyidx & 0x3) << 6));
        ccmp[4] = static_cast<uint8_t>(packetNumber >> 16);
        ccmp[5] = static_cast<uint8_t>(packetNumber >> 24);
        ccmp[6] = static_cast<uint8_t>(packetNumber >> 32);
        ccmp[7] = static_cast<uint8_t>(packetNumber >> 40);
    }

    uint8_t *snap = skb_put(skb, 8);
    snap[0] = 0xAA; snap[1] = 0xAA; snap[2] = 0x03;
    snap[3] = 0x00; snap[4] = 0x00; snap[5] = 0x00;
    snap[6] = (uint8_t)(ethertype >> 8);
    snap[7] = (uint8_t)(ethertype & 0xff);

    if (paylen) {
        uint8_t *pay = (uint8_t *)skb_put(skb, paylen);
        if (mbuf_copydata(m, 14, paylen, pay) != 0) {
            kfree_skb(skb);
            mbuf_freem(m);
            return false;
        }
    }

    skb_set_queue_mapping(skb, accessCategory);
    skb->priority = tid;
    skb->protocol = cpu_to_be16(ethertype);

    struct ieee80211_tx_info *info = IEEE80211_SKB_CB(skb);
    memset(info, 0, sizeof(*info));
    info->flags = IEEE80211_TX_CTL_FIRST_FRAGMENT;
    const uint32_t baState = _txBAState.snapshot();
    if (qos && accessCategory == IEEE80211_AC_BE &&
        (baState & RTW88TxBAState::kActiveBit) &&
        tid == (baState & RTW88TxBAState::kTidMask) && !eapol)
        info->flags |= IEEE80211_TX_CTL_AMPDU;
    info->band  = (_targetBSS.channel > 14) ? NL80211_BAND_5GHZ
                                            : NL80211_BAND_2GHZ;
    info->control.vif = _vif;
    info->control.sta = _sta;
    if (eapol)
        info->flags |= IEEE80211_TX_CTL_REQ_TX_STATUS;
    if (protected_frame)
        info->control.hw_key = _ptkConf;

    if (callback) {
        struct rtw88_skb_tx_completion_token *token =
            (struct rtw88_skb_tx_completion_token *)kzalloc(
                sizeof(*token), GFP_ATOMIC);
        if (!token) {
            kfree_skb(skb);
            mbuf_freem(m);
            return false;
        }
        token->callback = callback;
        token->release = rtw88_release_skb_tx_completion_token;
        token->context = completionContext;
        token->cookie = completionCookie;
        if (!rtw88_skb_tx_completion_bind(&skb->tx_completion, token)) {
            kfree(token);
            kfree_skb(skb);
            mbuf_freem(m);
            return false;
        }
    }

    struct ieee80211_tx_control ctrl = { .sta = _sta };
    _hw->ops->tx(_hw, &ctrl, skb);
    mbuf_freem(m);
    return true;
}

/*  mbuf ↔ sk_buff conversion                                           */
/* ------------------------------------------------------------------ */

/*
 * Allocate a packet-header mbuf and copy `len` bytes from `src` into it.
 *
 * IMPORTANT: mbuf_allocpacket() may return a *chain* of mbufs (multiple
 * ~2 KB clusters) for packets larger than one cluster — e.g. A-MSDU
 * aggregated 802.11 data frames, which can be several KB.  In that case
 * mbuf_data(m) points only at the FIRST segment, and writing the whole
 * packet there overflows into adjacent kernel/mbuf-zone memory, corrupting
 * the heap (later manifesting as a GP fault in an unrelated mbuf walk such
 * as sbconcat_mbufs).
 *
 * mbuf_copyback() correctly distributes the data across every segment of
 * the chain and never overflows, so we use it instead of a raw memcpy.
 * mbuf_allocpacket() already sets each segment's length and pkthdr.len, so
 * we must NOT call mbuf_setlen() (which would wrongly set the first
 * segment's length to the whole-packet length).
 */
static mbuf_t rtw88_make_packet_mbuf(const void *src, uint32_t len)
{
    mbuf_t m = nullptr;
    if (mbuf_allocpacket(MBUF_WAITOK, len, nullptr, &m) != 0)
        return nullptr;
    if (mbuf_copyback(m, 0, len, src, MBUF_WAITOK) != 0) {
        mbuf_freem(m);
        return nullptr;
    }
    /* mbuf_allocpacket does not reliably set pkthdr.len, and depending on the
     * kernel, mbuf_copyback may not either.  Set it explicitly — otherwise
     * ether_input() strips the 14-byte header from a pkthdr.len of 0 and
     * panics with "Failed mbuf validity check: len -14". */
    mbuf_pkthdr_setlen(m, len);
    return m;
}

struct sk_buff *RTW88IEEE80211::mbufToSkb(mbuf_t m)
{
    size_t total = mbuf_pkthdr_len(m);
    struct sk_buff *skb = alloc_skb((uint32_t)(total + 64), GFP_ATOMIC);
    if (!skb) return nullptr;
    skb_reserve(skb, 128); /* headroom for TX descriptor (48 B) + pkt_offset padding */

    /* Copy contiguous mbuf chain data */
    mbuf_t cur = m;
    while (cur) {
        size_t chunk = mbuf_len(cur);
        if (chunk > 0) {
            memcpy(skb_put(skb, (uint32_t)chunk), mbuf_data(cur), chunk);
        }
        cur = mbuf_next(cur);
    }
    return skb;
}

mbuf_t RTW88IEEE80211::skbToMbuf(struct sk_buff *skb)
{
    return rtw88_make_packet_mbuf(skb->data, skb->len);
}

/* ------------------------------------------------------------------ */
/*  Timer (state machine timeout)                                       */
/* ------------------------------------------------------------------ */

void RTW88IEEE80211::timerFired(OSObject *owner, IOTimerEventSource *timer)
{
    RTW88IEEE80211 *self = OSDynamicCast(RTW88IEEE80211, owner);
    if (self) self->onTimer();
}

void RTW88IEEE80211::onTimer()
{
    switch (__atomic_load_n(&_state, __ATOMIC_ACQUIRE)) {
    case RTW88_STATE_SCANNING:
        IOLog("rtw88: scan timeout\n");
        if (__atomic_load_n(&_manualScanChannelCount, __ATOMIC_ACQUIRE)) {
            _manualScanAbort = true;
            break;
        } else if (_hw && _hw->ops && _hw->ops->cancel_hw_scan) {
            _hw->ops->cancel_hw_scan(_hw, _vif);
        }
        // Use the same completion path as firmware: notify SCAN_DONE and
        // resume an accepted deferred ASSOCIATE even if cancel has no callback.
        scanDone(true);
        break;

    case RTW88_STATE_AUTHENTICATING:
        IOLog("rtw88: auth timeout, retrying\n");
        if (!authenticationCancelled() && _connectTC) thread_call_enter(_connectTC);
        break;

    case RTW88_STATE_ASSOCIATING:
        joinAttemptFailed("assoc-timeout");
        break;

    case RTW88_STATE_HANDSHAKING:
        IOLog("rtw88: 4-way handshake timeout\n");
        doDisconnect();
        break;

    default:
        break;
    }
}

/* ------------------------------------------------------------------ */
/*  Status queries                                                       */
/* ------------------------------------------------------------------ */

IOReturn RTW88IEEE80211::cmdGetState(struct RTW88StateResult *result)
{
    if (!result) return kIOReturnBadArgument;

    /* Expose the persistent infrastructure RUN state, not a transient rtw88
     * implementation state.  CoreWiFi immediately asks SSID/BSSID/CHANNEL
     * after ASSOC_DONE; returning anything except RUN there makes it abort a
     * link that may already have installed an RSN key. */
    RTW88State reportedState = associatedVisible() ? RTW88_STATE_CONNECTED : __atomic_load_n(&_state, __ATOMIC_ACQUIRE);
    result->state = reportedState;
    result->rssi = _rssi;
    memcpy(result->ssid, _targetBSS.ssid, sizeof(result->ssid));
    memcpy(result->bssid, _targetBSS.bssid, sizeof(result->bssid));
    result->channel = _targetBSS.channel;
    
    memcpy(result->mac_addr, _macAddr, 6);

    rtw88_get_fw_version(_rtwdev, &result->fw_version, &result->fw_sub_version);
    rtw88_get_chip_name(_rtwdev, result->chip_name, sizeof(result->chip_name));
    rtw88_get_stats(_rtwdev, &result->tx_byte_count, &result->rx_byte_count);
    result->scan_offload_supported =
        (_hw && _hw->ops && _hw->ops->hw_scan &&
         rtw88_hw_scan_supported(_hw)) ? 1 : 0;
    result->powered = _powered ? 1 : 0;

    return kIOReturnSuccess;
}

IOReturn RTW88IEEE80211::cmdGetRSSI(int *rssi)
{
    if (!rssi) return kIOReturnBadArgument;
    *rssi = _rssi;
    return kIOReturnSuccess;
}

uint8_t RTW88IEEE80211::txNSS() const
{
    return rtw88_get_tx_nss(_rtwdev);
}

IOReturn RTW88IEEE80211::cmdGetBSSList(uint8_t *buf, uint32_t *len)
{
    if (!buf || !len) return kIOReturnBadArgument;

    uint32_t max     = *len;
    if (max > 4095) max = 4095;

    if (max < 4) {
        *len = 0;
        return kIOReturnSuccess;
    }
    
    uint32_t written = 4; // reserve first 4 bytes for total length

    IOLockLock(_bssLock);
    for (RTW88BSS *b = _bssList; b; b = b->next) {
        /* Each entry: ssid_len(1), ssid(ssid_len), bssid(6), rssi(2),
         *             channel(1), cipher(4) */
        uint32_t entry_sz = 1 + b->ssid_len + 6 + 2 + 1 + 4;
        if (written + entry_sz > max) {
            IOLog("rtw88: BSS entry skipped (buffer full: written=%u max=%u)\n", written, max);
            break;
        }

        buf[written++] = b->ssid_len;
        memcpy(buf + written, b->ssid, b->ssid_len); written += b->ssid_len;
        memcpy(buf + written, b->bssid, 6);           written += 6;
        buf[written++] = (uint8_t)((b->rssi >> 8) & 0xff);
        buf[written++] = (uint8_t)(b->rssi & 0xff);
        buf[written++] = b->channel;
        memcpy(buf + written, &b->cipher, 4);          written += 4;
    }
    IOLockUnlock(_bssLock);

    /* Write total written bytes into the first 4 bytes */
    uint32_t total = written;
    memcpy(buf, &total, sizeof(total));

    *len = written;
    return kIOReturnSuccess;
}

IOReturn RTW88IEEE80211::setRegulatoryCountry(const char alpha2[2])
{
    if (!_rtwdev || !alpha2) return kIOReturnNotReady;
    const int ret = rtw_regd_set_country(_rtwdev, alpha2);
    if (ret) {
        IOLog("rtw88: failed to apply host regulatory country %.2s ret=%d\n", alpha2, ret);
        return kIOReturnError;
    }
    IOLog("rtw88: applied host regulatory country %.2s to Realtek power domain\n", alpha2);
    return kIOReturnSuccess;
}

void RTW88IEEE80211::getMACAddress(uint8_t *mac)
{
    if (mac) memcpy(mac, _macAddr, 6);
}

void RTW88IEEE80211::getPermanentMACAddress(uint8_t *mac)
{
    if (mac) memcpy(mac, _permanentMacAddr, 6);
}

IOReturn RTW88IEEE80211::setMACAddress(const uint8_t *mac)
{
    if (!mac)
        return kIOReturnBadArgument;

    const bool allZero = !(mac[0] | mac[1] | mac[2] | mac[3] | mac[4] | mac[5]);
    if (allZero || (mac[0] & 0x01))
        return kIOReturnBadArgument;

    /* The VIF/backend pointers are not sampled until TX admission is closed. */
    auto mutation = beginTxStateMutation();
    if (!_rtwdev || !_hw || !_vif) {
        mutation.finish();
        return kIOReturnNotReady;
    }
    if (__atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_CONNECTED || __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_ASSOCIATING ||
        __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_AUTHENTICATING || __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_HANDSHAKING ||
        __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == RTW88_STATE_DISCONNECTING) {
        mutation.finish();
        return kIOReturnBusy;
    }

    if (rtw88_set_station_mac(_hw, _vif, mac) != 0) {
        mutation.finish();
        return kIOReturnError;
    }
    memcpy(_macAddr, mac, ETH_ALEN);
    mutation.finish();

    IOLog("rtw88: STA MAC programmed (locally-administered=%u)\n",
          (mac[0] & 0x02U) ? 1U : 0U);
    return kIOReturnSuccess;
}

IOReturn RTW88IEEE80211::copyScanBSS(uint32_t index, RTW88BSS *out)
{
    if (!out || !_bssLock) return kIOReturnBadArgument;
    IOLockLock(_bssLock);
    RTW88BSS *b = _bssList;
    while (b && index--) b = b->next;
    if (b) { *out = *b; out->next = nullptr; }
    IOLockUnlock(_bssLock);
    return b ? kIOReturnSuccess : kIOReturnNotFound;
}

IOReturn RTW88IEEE80211::copyCurrentBSS(RTW88BSS *out)
{
    if (!out) return kIOReturnBadArgument;

    /* v52: use the same persistent RUN latch as cmdGetState().  A connected
     * background scan has __atomic_load_n(&_state, __ATOMIC_ACQUIRE) == SCANNING by design, but it is still the
     * current infrastructure network from CoreWiFi's point of view.  Returning
     * NotReady here made APPLE80211_IOC_CURRENT_NETWORK fail with -3903 while
     * the menu still showed an associated link (issue #3). */
    if (!_powered || !associatedVisible())
        return kIOReturnNotReady;

    /* CURRENT_NETWORK is queried aggressively by CoreWiFi/locationd.
     * _targetBSS remains the association target, but some association paths
     * preserve the SSID bytes without preserving ssid_len. Prefer the scan
     * cache entry matching the currently-associated BSSID because it contains
     * the complete channel/capability/IE record; fall back to _targetBSS. */
    bool found = false;
    if (_bssLock) {
        IOLockLock(_bssLock);
        for (RTW88BSS *b = _bssList; b; b = b->next) {
            if (memcmp(b->bssid, _targetBSS.bssid, 6) == 0) {
                *out = *b;
                found = true;
                break;
            }
        }
        IOLockUnlock(_bssLock);
    }

    if (!found)
        *out = _targetBSS;

    out->next = nullptr;
    out->rssi = (int16_t)_rssi;

    /* Ventura's selector 103 payload is exactly apple80211_scan_result
     * (1164 bytes in the pinned SDK). Do not fail merely because the backend
     * forgot the cached SSID length when the NUL-terminated SSID is present. */
    if (out->ssid_len == 0 && out->ssid[0] != '\0')
        out->ssid_len = (uint8_t)strnlen(out->ssid, 32);

    if (out->ssid_len == 0 || out->channel == 0)
        return kIOReturnNotReady;

    return kIOReturnSuccess;
}

IOReturn RTW88IEEE80211::copyChannels(RTW88Channel *out, uint32_t capacity, uint32_t *count)
{
    if (!out || !count) return kIOReturnBadArgument;
    *count = 0;
    if (!_hw || !_hw->wiphy) return kIOReturnNotReady;
    for (unsigned band = 0; band < NL80211_NUM_BANDS; band++) {
        auto *supported = _hw->wiphy->bands[band];
        if (!supported) continue;
        for (int i = 0; i < supported->n_channels; i++) {
            auto *channel = &supported->channels[i];
            if (channel->flags & IEEE80211_CHAN_DISABLED) continue;
            if (*count == capacity) return kIOReturnNoSpace;
            int f = channel->center_freq;
            int number = f == 2484 ? 14 : f < 2500 ? (f - 2407) / 5 : (f - 5000) / 5;
            if (number <= 0 || number > 196) continue;
            out[*count].number = static_cast<uint16_t>(number);
            out[*count].passive = (channel->flags & IEEE80211_CHAN_NO_IR) != 0;
            out[*count].radar = (channel->flags & IEEE80211_CHAN_RADAR) != 0;
            (*count)++;
        }
    }
    return kIOReturnSuccess;
}
