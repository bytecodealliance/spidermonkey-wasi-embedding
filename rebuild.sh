#!/usr/bin/env bash

export REBUILD_ENGINE=1
exec $(dirname $0)/build-engine.sh "$@"
