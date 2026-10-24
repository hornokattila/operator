#!/bin/bash

for net in edge outsideworx; do
  docker network connect "$net" operator
done

apt update && apt upgrade -y && apt install -y \
  git \
  htop \
  maven \
  npm \
  openjdk-25-jdk \
  vim

unminimize
