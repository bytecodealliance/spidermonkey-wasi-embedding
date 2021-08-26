#!/usr/bin/env bash
set -ex

if [[ ! -a gecko-dev ]]
then
  # Ensure apt-get is current, because otherwise bootstrapping might fail
  sudo apt-get update -y

  # Ensure the Rust version matches that used by Gecko, and can compile to WASI
  rustup update 1.54.0
  rustup default 1.54.0
  rustup target add wasm32-wasi

  # Clone Gecko repository at the required revision
  mkdir gecko-dev
  cd gecko-dev

  git init
  git remote add origin $(cat ../gecko-repository)
  git fetch --depth 1 origin $(cat ../gecko-revision)
  git checkout FETCH_HEAD

  # Use Gecko's build system bootstrapping to ensure all dependencies are installed
  ./mach bootstrap --application-choice=js

  cd ..
fi

flags="--optimize --no-debug --build-only"
rust_lib_dir="release"
if [[ $1 == 'debug' ]]
then
  flags="--optimize --debug"
  rust_lib_dir="debug"
fi

echo $flags $rust_lib_dir

# Build SpiderMonkey for WASI
MOZ_FETCHES_DIR=~/.mozbuild gecko-dev/js/src/devtools/automation/autospider.py --objdir=obj $flags wasi

# Copy header, object, and static lib files
mkdir lib

cd obj
cp -Lr dist/include ..
cp $(cat ../object-files.list) ../lib
cp js/src/build/libjs_static.a wasm32-wasi/${rust_lib_dir}/libjsrust.a ../lib
