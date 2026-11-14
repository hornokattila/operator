#!/bin/bash

read -p "Start? (y/n) " ans
[[ $ans =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

docker stack rm services
docker stack rm sites

echo "Sleep, to make sure everything stopped."
sleep 30

docker secret ls -q | xargs -r docker secret rm
docker rmi -f "$(docker images -qa)"
docker system prune -af

apt update
apt upgrade -y
htop
