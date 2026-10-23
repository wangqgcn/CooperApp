#!/bin/zsh
# 不依赖 Xcode / SwiftPM，直接用 swiftc 编译并运行 s3probe，用真实存储桶验证 S3Kit。
# 连接参数从环境变量读取：S3_ENDPOINT、S3_BUCKET、S3_ACCESS_KEY_ID、S3_SECRET_ACCESS_KEY。
#
#   scripts/s3probe.sh ls [PREFIX]
#   scripts/s3probe.sh put LOCAL_FILE KEY
#   scripts/s3probe.sh get KEY LOCAL_FILE
set -euo pipefail

ROOT=${0:A:h:h}
SRC=$ROOT/Packages/S3Kit/Sources
OUT=$ROOT/.build/s3probe
SDK=$(xcrun --show-sdk-path)
TARGET=$(uname -m)-apple-macos14.0

if [[ ! -x $OUT/s3probe || -n $(find $SRC -name '*.swift' -newer $OUT/s3probe) ]]; then
  mkdir -p $OUT
  swiftc -O -emit-library -static -emit-module -module-name S3Kit -parse-as-library -swift-version 6 \
    -target $TARGET -sdk $SDK $SRC/S3Kit/*.swift \
    -emit-module-path $OUT/S3Kit.swiftmodule -o $OUT/libS3Kit.a
  swiftc -O -swift-version 6 -target $TARGET -sdk $SDK -I $OUT -L $OUT -lS3Kit \
    $SRC/s3probe/main.swift -o $OUT/s3probe
fi

exec $OUT/s3probe "$@"
