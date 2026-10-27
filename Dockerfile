FROM ubuntu:24.04
ENV container=docker

RUN apt update && apt upgrade -y && apt install -y \
    curl \
    dbus \
    docker-buildx \
    docker-compose-v2 \
    htop \
    openssh-server \
    systemd \
    systemd-sysv \
    unzip \
    vim

RUN systemctl mask \
    containerd.service \
    docker.service \
    docker.socket

RUN userdel -r ubuntu
RUN printf 'PasswordAuthentication no\nStrictModes no\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf

COPY ini.sh /root/ini.sh
RUN chmod +x /root/ini.sh

# Seeds the root volume on first creation only; later image changes under
# /root are hidden by the existing volume.
RUN install -d -m 700 /root/.ssh
COPY authorized_keys /root/.ssh/authorized_keys
RUN chmod 600 /root/.ssh/authorized_keys

EXPOSE 51821
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
