#include "ODWire.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>

void od_framer_reset(ODFramer *f) { free(f->payload); memset(f, 0, sizeof(*f)); }
int od_framer_feed(ODFramer *f, const uint8_t *p, size_t n, ODFrameCallback cb, void *ctx) {
    while (n) {
        if (f->headerUsed < 4) {
            size_t take = 4 - f->headerUsed; if (take > n) take = n;
            memcpy(f->header + f->headerUsed, p, take);
            f->headerUsed += take; p += take; n -= take;
            if (f->headerUsed != 4) continue;
            f->length = ((uint32_t)f->header[0] << 24) | ((uint32_t)f->header[1] << 16) |
                        ((uint32_t)f->header[2] << 8) | f->header[3];
            if (!f->length || f->length > OD_MAX_FRAME) { od_framer_reset(f); return 0; }
            f->payload = malloc(f->length);
            if (!f->payload) { od_framer_reset(f); return 0; }
        }
        size_t take = f->length - f->used; if (take > n) take = n;
        memcpy(f->payload + f->used, p, take); f->used += take; p += take; n -= take;
        if (f->used == f->length) { cb(ctx, f->payload, f->length); od_framer_reset(f); }
    }
    return 1;
}
int od_is_control(const uint8_t *p, size_t n) {
    return n && n < 32768 && p[0] == '{' && !memchr(p, 0, n);
}
int od_json_depth_safe(const uint8_t *p, size_t n) {
    int depth = 0, string = 0, escape = 0;
    for (size_t i = 0; i < n; ++i) {
        uint8_t c = p[i];
        if (string) { if (escape) escape = 0; else if (c == '\\') escape = 1; else if (c == '"') string = 0; }
        else if (c == '"') string = 1;
        else if (c == '{' || c == '[') { if (++depth > 24) return 0; }
        else if (c == '}' || c == ']') { if (--depth < 0) return 0; }
    }
    return depth == 0 && !string;
}
static size_t start_code(const uint8_t *p, size_t n, size_t from) {
    for (size_t i = from; i + 4 <= n; ++i)
        if (!p[i] && !p[i+1] && !p[i+2] && p[i+3] == 1) return i;
    return n;
}
int od_nalu_next(const uint8_t *p, size_t n, size_t *cursor, ODNalu *nal) {
    size_t start = start_code(p, n, *cursor);
    if (start == n || start + 4 >= n) { *cursor = n; return 0; }
    size_t end = start_code(p, n, start + 4);
    nal->data = p + start + 4; nal->size = end - start - 4;
    nal->type = nal->data[0] & 31; *cursor = end;
    return 1;
}

typedef struct { uint8_t data[4096]; size_t size, bit; int bad; } Bits;
static uint32_t bits(Bits *b, unsigned n) {
    if (n > 32 || b->bit + n > b->size * 8) { b->bad = 1; return 0; }
    uint32_t v = 0;
    for (unsigned i = 0; i < n; ++i, ++b->bit) v = (v << 1) | ((b->data[b->bit/8] >> (7-b->bit%8)) & 1);
    return v;
}
static uint32_t ue(Bits *b) {
    unsigned zeros = 0;
    while (!b->bad && !bits(b, 1)) { if (++zeros > 30) { b->bad = 1; return 0; } }
    return ((1u << zeros) - 1) + bits(b, zeros);
}
static int32_t se(Bits *b) { uint32_t u = ue(b); return (u & 1) ? (int32_t)((u+1)/2) : -(int32_t)(u/2); }
static void scaling(Bits *b, unsigned n) {
    int last = 8, next = 8;
    for (unsigned j = 0; j < n && !b->bad; ++j) {
        if (next) next = (last + (se(b) % 256) + 256) % 256;
        if (next) last = next;
    }
}
int od_sps_parse(const uint8_t *p, size_t n, ODSPS *s) {
    if (n < 5 || n > 4096 || (p[0] & 31) != 7) return 0;
    Bits b = {0}; unsigned zeros = 0;
    for (size_t i = 1; i < n; ++i) {
        if (zeros >= 2 && p[i] == 3) { zeros = 0; continue; }
        b.data[b.size++] = p[i]; zeros = p[i] == 0 ? zeros+1 : 0;
    }
    unsigned profile = bits(&b, 8); bits(&b, 8); unsigned level = bits(&b, 8); ue(&b);
    unsigned chroma = 1, separate = 0;
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244 || profile == 44 ||
        profile == 83 || profile == 86 || profile == 118 || profile == 128 || profile == 138 || profile == 144) {
        chroma = ue(&b); if (chroma > 3) return 0;
        if (chroma == 3) separate = bits(&b, 1);
        if (ue(&b) > 6 || ue(&b) > 6) return 0;
        bits(&b, 1);
        if (bits(&b, 1)) for (unsigned i = 0; i < (chroma == 3 ? 12u : 8u); ++i)
            if (bits(&b, 1)) scaling(&b, i < 6 ? 16 : 64);
    }
    if (ue(&b) > 12) return 0;
    unsigned poc = ue(&b);
    if (poc == 0) { if (ue(&b) > 12) return 0; }
    else if (poc == 1) {
        bits(&b, 1); se(&b); se(&b); unsigned count = ue(&b); if (count > 255) return 0;
        for (unsigned i = 0; i < count; ++i) se(&b);
    } else if (poc != 2) return 0;
    ue(&b); bits(&b, 1);
    unsigned w = ue(&b), h = ue(&b);
    if (w > 255 || h > 255) return 0;
    unsigned frame = bits(&b, 1); if (!frame) bits(&b, 1); bits(&b, 1);
    unsigned left = 0, right = 0, top = 0, bottom = 0;
    if (bits(&b, 1)) { left = ue(&b); right = ue(&b); top = ue(&b); bottom = ue(&b); }
    unsigned array = separate ? 0 : chroma;
    unsigned cropX = array == 1 || array == 2 ? 2 : 1;
    unsigned cropY = (array == 1 ? 2 : 1) * (2-frame);
    uint64_t cw = ((uint64_t)left + right) * cropX, ch = ((uint64_t)top + bottom) * cropY;
    unsigned width = (w+1)*16, height = (h+1)*16*(2-frame);
    if (b.bad || cw >= width || ch >= height) return 0;
    s->width = width-(unsigned)cw; s->height = height-(unsigned)ch; s->profile = profile; s->level = level;
    return 1;
}
