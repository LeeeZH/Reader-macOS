#include "ZipInflate.h"

#include <string.h>
#include <zlib.h>

int32_t reader_inflate_raw(const uint8_t *src, size_t src_len,
                           uint8_t *dst, size_t dst_len)
{
    z_stream stream;
    memset(&stream, 0, sizeof(stream));

    stream.next_in = (Bytef *)src;
    stream.avail_in = (uInt)src_len;
    stream.next_out = (Bytef *)dst;
    stream.avail_out = (uInt)dst_len;

    // -15：raw DEFLATE（ZIP 的压缩方式 8 没有 zlib 头）
    int rc = inflateInit2(&stream, -15);
    if (rc != Z_OK) {
        return (int32_t)rc;
    }

    rc = inflate(&stream, Z_FINISH);
    int32_t result = 0;
    if (rc == Z_STREAM_END) {
        result = (stream.total_out == dst_len) ? 0 : -2;
    } else {
        result = (rc == Z_OK || rc == Z_BUF_ERROR) ? -3 : (int32_t)rc;
    }
    inflateEnd(&stream);
    return result;
}
