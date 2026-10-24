#!/bin/bash

for net in edge outsideworx; do
  docker network connect "$net" operator
done

unminimize
