#!/usr/bin/env bash
set -euo pipefail

otp_version="${PYRLANG_OTP_VERSION:-28.5}"
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
prefix="${PYRLANG_OTP_PREFIX:-$PWD/.otp-macos}"

if [ -x "$prefix/bin/erl" ]; then
    "$prefix/bin/erl" -noshell -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt(0).'
    exit 0
fi

openssl_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
if [ -z "$openssl_prefix" ]; then
    brew install openssl@3
    openssl_prefix="$(brew --prefix openssl@3)"
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

curl -fsSL \
    "https://github.com/erlang/otp/releases/download/OTP-${otp_version}/otp_src_${otp_version}.tar.gz" \
    -o "$workdir/otp.tar.gz"
mkdir "$workdir/otp"
tar -xzf "$workdir/otp.tar.gz" -C "$workdir/otp" --strip-components=1

export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
export CFLAGS="${CFLAGS:-} -mmacosx-version-min=${deployment_target}"
export CXXFLAGS="${CXXFLAGS:-} -mmacosx-version-min=${deployment_target}"
export LDFLAGS="${LDFLAGS:-} -mmacosx-version-min=${deployment_target}"

cd "$workdir/otp"
./configure \
    --prefix="$prefix" \
    --with-ssl="$openssl_prefix" \
    --without-debugger \
    --without-et \
    --without-javac \
    --without-megaco \
    --without-observer \
    --without-odbc \
    --without-ssh \
    --without-wx

jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
make -j"$jobs"
make install

"$prefix/bin/erl" -noshell -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt(0).'
