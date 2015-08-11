#!/bin/bash


set -e


DIR_NAME="rally_home"

docker stop rally-MOS-benchmarking
docker rm rally-MOS-benchmarking

rm -rf ~/${DIR_NAME}
