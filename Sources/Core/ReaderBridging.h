#ifndef READER_BRIDGING_H
#define READER_BRIDGING_H

/// Swift 侧能看到的最小 C 接口集合。
/// 只暴露系统库调用（zlib），不放业务逻辑；零第三方依赖。
#include "ZipInflate.h"

#endif
