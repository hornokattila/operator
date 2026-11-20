FROM ubuntu:24.04

ENV container=docker

RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y \
        bash-completion \
        curl \
        dbus \
        docker-buildx \
        docker-compose-v2 \
        htop \
        openssh-server \
        openssl \
        python3 \
        stunnel4 \
        systemd \
        systemd-sysv \
        tmux \
        unzip \
        vim \
    && rm -rf /var/lib/apt/lists/*

RUN userdel -r ubuntu \
    && printf 'PasswordAuthentication no\nStrictModes no\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf

COPY stunnel.conf /etc/stunnel/
COPY knock.service stunnel.service /etc/systemd/system/
RUN systemctl mask containerd.service docker.service docker.socket \
    && { systemctl disable stunnel4.service 2>/dev/null || true; } \
    && systemctl enable knock.service ssh.service stunnel.service

COPY .bash_aliases knock.py /root/
COPY --chmod=755 ini.sh /root/
COPY --chmod=600 authorized_keys /root/.ssh/
RUN chmod 700 /root/.ssh

EXPOSE 444
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
