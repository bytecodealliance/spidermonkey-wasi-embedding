#!/usr/bin/env bash

set -euo pipefail
set -x

working_dir="$(pwd)"
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

mode="${1:-release}"
mozconfig="${working_dir}/mozconfig-${mode}"
objdir="obj-$mode"
outdir="$mode"

cat << EOF > "$mozconfig"
ac_add_options --enable-project=js
ac_add_options --enable-application=js
ac_add_options --target=wasm32-unknown-wasi
ac_add_options --without-system-zlib
ac_add_options --without-intl-api
ac_add_options --disable-jit
ac_add_options --disable-shared-js
ac_add_options --disable-shared-memory
ac_add_options --disable-tests
ac_add_options --disable-clang-plugin
ac_add_options --enable-jitspew
ac_add_options --enable-optimize=-O3
ac_add_options --enable-js-streams
ac_add_options --disable-shared-memory
ac_add_options --wasm-no-experimental
ac_add_options --disable-wasm-extended-const
ac_add_options --disable-js-shell
ac_add_options --enable-portable-baseline-interp
ac_add_options --disable-cargo-incremental
ac_add_options --prefix=${working_dir}/${objdir}/dist
mk_add_options MOZ_OBJDIR=${working_dir}/${objdir}
mk_add_options AUTOCLOBBER=1

EOF

if [[ "$mode" == "release" ]]; then
cat << EOF >> "$mozconfig"
ac_add_options --enable-strip
ac_add_options --disable-debug
EOF
else
cat << EOF >> "$mozconfig"
ac_add_options --enable-debug
EOF
fi

cat << EOF >> "$mozconfig"
export RUSTFLAGS="-C relocation-model=pic"
export CARGOFLAGS="-Z build-std=panic_abort,std"
export CFLAGS="-fPIC"
export CXXFLAGS="-fPIC"

EOF

# Note: the var name is chosen to not conflict with the one used by the toolchain
OS_NAME="$(uname | tr '[:upper:]' '[:lower:]')"
export OS_NAME

case "$OS_NAME" in
  linux)
    echo "ac_add_options --disable-stdcxx-compat" >> "$mozconfig"
    ;;

  darwin)
    echo "ac_add_options --host=aarch64-apple-darwin" >> "$mozconfig"
    OS_NAME="macos"
    ;;

  *)
    echo "Can't build on OS $OS_NAME"
    exit 1
    ;;
esac


# Ensure the Rust version matches that used by Gecko, and can compile to WASI
rustup target add wasm32-wasi
rustup component add rust-src

# Ensure that the expected WASI-SDK is installed
if [[ -z "${WASI_SDK_PREFIX:-}" ]]; then
  sdk_url="$(sed "s/\$OS_NAME/$OS_NAME/g" "$script_dir/wasi-sdk-url")"
  echo "WASI_SDK_PREFIX not set, downloading SDK from ${sdk_url} ..."
  mkdir -p wasi-sdk
  cd wasi-sdk
  curl -LO "$sdk_url"
  sdk_file="$(basename "$sdk_url")"
  tar -xf "$sdk_file"
  rm "$sdk_file"
  WASI_SDK_PREFIX=$PWD/$(ls . | head -n 1)
  export WASI_SDK_PREFIX
  cd ..
  echo "Downloaded and extracted. Using compiler and sysroot at ${WASI_SDK_PREFIX} for target compilation"
else
  if [[ ! -d "${WASI_SDK_PREFIX}" ]]; then
    echo "WASI_SDK_PREFIX set, but directory does not exist: ${WASI_SDK_PREFIX}"
    exit 1
  fi
  echo "WASI_SDK_PREFIX set, using compiler and sysroot at ${WASI_SDK_PREFIX} for target compilation"
fi

# If the Gecko repository hasn't been cloned yet, do so now.
# Otherwise, assume it's in the right state already.
if [[ ! -a gecko-dev ]]; then

  # Clone Gecko repository at the required revision
  mkdir gecko-dev

  git -C gecko-dev init
  git -C gecko-dev remote add --no-tags -t wasi-embedding \
    origin "$(cat "$script_dir/gecko-repository")"

  target_rev="$(cat "$script_dir/gecko-revision")"
  if [[ "$(git -C gecko-dev rev-parse HEAD)" != "$target_rev" ]]; then
    git -C gecko-dev fetch --depth 1 origin "$target_rev"
    git -C gecko-dev checkout FETCH_HEAD
  fi
fi

## Use Gecko's build system bootstrapping to ensure all dependencies are
## installed
cd gecko-dev
./mach --no-interactive bootstrap --application-choice=js --no-system-changes

cd "$working_dir"

export CC=${WASI_SDK_PREFIX}/bin/clang
export CXX=${WASI_SDK_PREFIX}/bin/clang++
export AR=${WASI_SDK_PREFIX}/bin/llvm-ar
export HOST_CC=~/.mozbuild/clang/bin/clang
export HOST_CXX=~/.mozbuild/clang/bin/clang++
export HOST_AR=~/.mozbuild/clang/bin/llvm-ar

# Build SpiderMonkey for WASI
MOZCONFIG="${mozconfig}" \
MOZ_FETCHES_DIR=~/.mozbuild \
  python3 "${working_dir}/gecko-dev/mach" \
  --no-interactive \
    configure

# Always use our own WASI sysroot, not the one mozbuild might have downloaded.
rm -rf ~/.mozbuild/sysroot-wasm32-wasi
ln -s "${WASI_SDK_PREFIX}/share/wasi-sysroot" ~/.mozbuild/sysroot-wasm32-wasi

MOZCONFIG="${mozconfig}" \
MOZ_FETCHES_DIR=~/.mozbuild \
  python3 "${working_dir}/gecko-dev/mach" \
  --no-interactive \
    configure

cd "$objdir"
# Before actually building, we need to overwrite the .cargo/config file that mozbuild created,
# because otherwise we can't build the Rust stdlib with -fPIC.
# That file is created during the `pre-export` build step, so we run that now, then overwrite
# the file, then build.
make pre-export

if [[ -f .cargo/config ]]; then
  echo "" > .cargo/config
fi

make -j$(nproc) -s

# Copy header, object, and static lib files
cd ..
rm -rf "$outdir"
mkdir -p "$outdir/lib"

cd "$objdir"
cp -Lr dist/include "../$outdir"

while read -r file; do
  cp "$file" "../$outdir/lib"
done < "$script_dir/object-files.list"

cp js/src/build/libjs_static.a "../$outdir/lib"

if [[ -f "wasm32-wasi/${mode}/libjsrust.a" ]]; then
cp "wasm32-wasi/${mode}/libjsrust.a" "../$outdir/lib"
fi
