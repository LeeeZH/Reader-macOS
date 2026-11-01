#ifndef READER_ZIPINFLATE_H
#define READER_ZIPINFLATE_H

#include <stddef.h>
#include <stdint.h>

/// 解压 ZIP 条目里的 **raw DEFLATE** 数据（RFC 1951，没有 zlib 头）。
///
/// ZIP 的压缩方式 8（deflate）存的是裸 DEFLATE 流，不是 `zlib` 格式，
/// 所以这里用 `inflateInit2(-15)`（-15 = 不要 zlib 头/尾）。走系统 zlib，
/// 不引入任何第三方库。
///
/// - Returns: 0 = 成功；负数 = 失败（-2 解出来大小不符，-3 数据不完整，
///   其它是 zlib 错误码）。
int32_t reader_inflate_raw(const uint8_t *src, size_t src_len,
                           uint8_t *dst, size_t dst_len);

#endif
