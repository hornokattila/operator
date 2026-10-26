FROM ubuntu:24.04
ENV container=docker

RUN apt update && apt upgrade -y && apt install -y \
    curl \
    dbus \
    docker-buildx
    docker-compose-v2 \
    htop \
    openssh-server \
    systemd \
    systemd-sysv \
    vim

RUN systemctl mask \
    containerd.service \
    docker.service \
    docker.socket

RUN userdel -r ubuntu
RUN printf 'PasswordAuthentication no\nStrictModes no\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf

COPY conf.sh /root/conf.sh
RUN chmod +x /root/conf.sh

EXPOSE 51821
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
