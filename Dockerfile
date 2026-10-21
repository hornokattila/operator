FROM ubuntu:24.04
ENV container=docker

RUN apt update && apt install -y \
    curl \
    dbus \
    docker-compose-v2 \
    git \
    maven \
    npm \
    openjdk-25-jdk \
    openssh-server \
    systemd \
    systemd-sysv

RUN echo 'y' | unminimize

RUN userdel -r ubuntu

RUN printf 'PasswordAuthentication no\nStrictModes no\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf

RUN systemctl mask \
    containerd.service \
    docker.service \
    docker.socket

EXPOSE 51821
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]