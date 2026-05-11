#!/usr/bin/env bash
set -euo pipefail

otp_version="${PYRLANG_OTP_VERSION:-28.5}"
prefix="/usr/local"

if command -v erl >/dev/null 2>&1; then
    erl -noshell -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt(0).'
    exit 0
fi

if command -v dnf >/dev/null 2>&1; then
    dnf -y install \
        curl \
        findutils \
        gcc \
        gcc-c++ \
        gzip \
        make \
        ncurses-devel \
        openssl-devel \
        perl \
        tar \
        which
elif command -v yum >/dev/null 2>&1; then
    yum -y install \
        curl \
        findutils \
        gcc \
        gcc-c++ \
        gzip \
        make \
        ncurses-devel \
        openssl-devel \
        perl \
        tar \
        which
elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache \
        bash \
        build-base \
        curl \
        linux-headers \
        ncurses-dev \
        openssl-dev \
        perl \
        tar
else
    echo "unsupported Linux package manager; expected dnf, yum, or apk" >&2
    exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

curl -fsSL \
    "https://github.com/erlang/otp/releases/download/OTP-${otp_version}/otp_src_${otp_version}.tar.gz" \
    -o "$workdir/otp.tar.gz"
mkdir "$workdir/otp"
tar -xzf "$workdir/otp.tar.gz" -C "$workdir/otp" --strip-components=1

cd "$workdir/otp"
./configure \
    --prefix="$prefix" \
    --without-debugger \
    --without-et \
    --without-javac \
    --without-megaco \
    --without-observer \
    --without-odbc \
    --without-ssh \
    --without-wx

jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
make -j"$jobs"
make install

erl -noshell -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt(0).'
