#!/usr/bin/env bash
set -ex

working_dir="$(pwd)"
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Ensure apt-get is current, because otherwise bootstrapping might fail
sudo apt-get update -y

# Ensure the Rust version matches that used by Gecko, and can compile to WASI
rustup update 1.57.0
rustup default 1.57.0
rustup target add wasm32-wasi

if [[ ! -a gecko-dev ]]
then

  # Clone Gecko repository at the required revision
  mkdir gecko-dev
  cd gecko-dev

  git init
  git remote add --no-tags -t wasi-embedding origin $(cat $script_dir/gecko-repository)
  cd ..
fi

cd gecko-dev
git fetch --depth 1 origin $(cat $script_dir/gecko-revision)
git checkout FETCH_HEAD

# Use Gecko's build system bootstrapping to ensure all dependencies are installed
./mach bootstrap --application-choice=js

# ... except, that doesn't install the wasi-sysroot, which we need, so we do that manually.
cd ~/.mozbuild
python3 \
  ${working_dir}/gecko-dev/mach \
  artifact \
  toolchain \
  --bootstrap \
  --from-build \
  sysroot-wasm32-wasi

cd ${working_dir}

flags="--optimize --no-debug --build-only"
rust_lib_dir="release"
if [[ $1 == 'debug' ]]
then
  flags="--optimize --debug"
  rust_lib_dir="debug"
fi

echo $flags $rust_lib_dir

# Build SpiderMonkey for WASI
MOZ_FETCHES_DIR=~/.mozbuild CC=~/.mozbuild/clang/bin/clang gecko-dev/js/src/devtools/automation/autospider.py --objdir=obj $flags wasi

# Copy header, object, and static lib files
rm -rf lib include
mkdir lib

cd obj
cp -Lr dist/include ..
cp $(cat $script_dir/object-files.list) ../lib
cp js/src/build/libjs_static.a wasm32-wasi/${rust_lib_dir}/libjsrust.a ../lib
