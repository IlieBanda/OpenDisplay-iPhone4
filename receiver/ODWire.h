#ifndef OD_WIRE_H
#define OD_WIRE_H
#include <stddef.h>
#include <stdint.h>
#define OD_MAX_FRAME (2u * 1024u * 1024u)
typedef void (*ODFrameCallback)(void *, const uint8_t *, size_t);
typedef struct {
    uint8_t header[4];
    size_t headerUsed, length, used;
    uint8_t *payload;
} ODFramer;
void od_framer_reset(ODFramer *f);
int od_framer_feed(ODFramer *f, const uint8_t *p, size_t n, ODFrameCallback cb, void *ctx);
int od_is_control(const uint8_t *p, size_t n);
int od_json_depth_safe(const uint8_t *p, size_t n);
typedef struct { const uint8_t *data; size_t size; unsigned type; } ODNalu;
/* cursor starts at 0; skips the optional telemetry before the first NAL. */
int od_nalu_next(const uint8_t *p, size_t n, size_t *cursor, ODNalu *nal);
typedef struct { unsigned width, height, profile, level; } ODSPS;
int od_sps_parse(const uint8_t *p, size_t n, ODSPS *sps);
#endif
