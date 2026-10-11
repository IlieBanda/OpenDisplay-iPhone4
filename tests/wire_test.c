#include "ODWire.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static size_t count;
static void frame(void *ctx,const uint8_t *p,size_t n) {
    (void)ctx; assert(n == 3 && !memcmp(p,"abc",3)); ++count;
}
int main(int argc,char **argv) {
    assert(argc == 2); ODFramer f = {0};
    const uint8_t data[] = {0,0,0,3,'a','b','c',0,0,0,3,'a','b','c'};
    for (size_t split = 0; split <= sizeof(data); ++split) {
        count = 0;
        assert(od_framer_feed(&f,data,split,frame,NULL));
        assert(od_framer_feed(&f,data+split,sizeof(data)-split,frame,NULL));
        assert(count == 2); od_framer_reset(&f);
    }
    count = 0;
    for (size_t i = 0; i < sizeof(data); ++i) assert(od_framer_feed(&f,data+i,1,frame,NULL));
    assert(count == 2); od_framer_reset(&f);
    const uint8_t zero[] = {0,0,0,0}, huge[] = {0xff,0xff,0xff,0xff};
    assert(!od_framer_feed(&f,zero,4,frame,NULL)); assert(!od_framer_feed(&f,huge,4,frame,NULL));
    assert(od_is_control((const uint8_t *)"{}",2));
    assert(!od_is_control((const uint8_t *)"{\0}",3));
    const char *safe = "{\"value\":\"{\\\"}\"}";
    assert(od_json_depth_safe((const uint8_t *)safe,strlen(safe)));
    uint8_t nested[60]; memset(nested,'[',30); memset(nested+30,']',30);
    assert(!od_json_depth_safe(nested,60));
    FILE *input = fopen(argv[1],"rb"); assert(input); fseek(input,0,SEEK_END); long size = ftell(input); rewind(input);
    uint8_t *clip = malloc((size_t)size); assert(fread(clip,1,(size_t)size,input) == (size_t)size); fclose(input);
    size_t cursor = 0; ODNalu nal; unsigned pictures = 0, sets = 0;
    while (od_nalu_next(clip,(size_t)size,&cursor,&nal)) {
        if (nal.type == 7) {
            ODSPS s; assert(od_sps_parse(nal.data,nal.size,&s));
            assert(s.width == 480 && s.height == 320 && s.profile == 77 && s.level == 31); ++sets;
        }
        if (nal.type == 9) ++pictures;
    }
    assert(pictures == 90 && sets == 3); free(clip);
    const uint8_t telemetry[] = {'{','}',0,0,0,1,0x65,0xaa,0,0,0,1,0x41};
    cursor = 0; assert(od_nalu_next(telemetry,sizeof(telemetry),&cursor,&nal) && nal.type == 5 && nal.size == 2);
    assert(od_nalu_next(telemetry,sizeof(telemetry),&cursor,&nal) && nal.type == 1 && nal.size == 1);
    assert(!od_nalu_next(telemetry,sizeof(telemetry),&cursor,&nal));
    /* Malformed SPS and short NALs must not overrun bit-reader storage. */
    uint8_t random[4096]; unsigned seed = 7;
    for (int i = 0; i < 20000; ++i) {
        size_t len = (unsigned)i % sizeof(random);
        for (size_t j = 0; j < len; ++j) { seed = seed*1664525u+1013904223u; random[j] = (uint8_t)(seed >> 24); }
        random[0] = 0x67; ODSPS s; od_sps_parse(random,len,&s);
    }
    puts("PASS: fragmented/coalesced frames, limits, demux, Annex B, Main SPS and malformed SPS");
}
