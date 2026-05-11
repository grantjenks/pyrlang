#!/usr/bin/env bash
set -euo pipefail

otp_version="${PYRLANG_OTP_VERSION:-28.5}"
openssl_version="${PYRLANG_OPENSSL_VERSION:-3.6.2}"
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
prefix="${PYRLANG_OTP_PREFIX:-$PWD/.otp-macos}"
openssl_prefix="${PYRLANG_OPENSSL_PREFIX:-$PWD/.openssl-macos}"
build_openssl="${PYRLANG_BUILD_OPENSSL:-false}"

if [ -x "$prefix/bin/erl" ]; then
    "$prefix/bin/erl" -noshell -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt(0).'
    exit 0
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

export MACOSX_DEPLOYMENT_TARGET="$deployment_target"
export CFLAGS="${CFLAGS:--O2 -g} -mmacosx-version-min=${deployment_target}"
export CXXFLAGS="${CXXFLAGS:--O2 -g} -mmacosx-version-min=${deployment_target}"
export LDFLAGS="${LDFLAGS:-} -mmacosx-version-min=${deployment_target}"

if [ "$build_openssl" = true ] && [ ! -f "$openssl_prefix/lib/libcrypto.3.dylib" ]; then
    openssl_target=
    case "$(uname -m)" in
        arm64)
            openssl_target=darwin64-arm64-cc
            ;;
        x86_64)
            openssl_target=darwin64-x86_64-cc
            ;;
        *)
            echo "unsupported macOS architecture: $(uname -m)" >&2
            exit 1
            ;;
    esac

    curl -fsSL "https://www.openssl.org/source/openssl-${openssl_version}.tar.gz" \
        -o "$workdir/openssl.tar.gz"
    mkdir "$workdir/openssl"
    tar -xzf "$workdir/openssl.tar.gz" -C "$workdir/openssl" --strip-components=1

    (
        cd "$workdir/openssl"
        ./Configure \
            "$openssl_target" \
            --prefix="$openssl_prefix" \
            --openssldir="$openssl_prefix/ssl" \
            shared \
            no-tests
        jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
        make -j"$jobs"
        make install_sw
    )
fi

if [ "$build_openssl" != true ]; then
    openssl_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
    if [ -z "$openssl_prefix" ]; then
        brew install openssl@3
        openssl_prefix="$(brew --prefix openssl@3)"
    fi
fi

curl -fsSL \
    "https://github.com/erlang/otp/releases/download/OTP-${otp_version}/otp_src_${otp_version}.tar.gz" \
    -o "$workdir/otp.tar.gz"
mkdir "$workdir/otp"
tar -xzf "$workdir/otp.tar.gz" -C "$workdir/otp" --strip-components=1

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
