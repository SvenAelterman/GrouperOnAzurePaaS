FROM i2incommon/grouper:4.12.0

# Probably not necessary for v4, but v5 defaults to -1
ENV GROUPER_TOMCAT_HTTP_PORT=8080

# Add SSH configuration for Azure App Service
# https://learn.microsoft.com/en-us/azure/app-service/configure-custom-container?tabs=debian&pivots=container-linux#enable-ssh

# Install and configure SSH
RUN yum update -y \
    && yum install -y openssh-server \
    # Required user and password for Azure App Service SSH connection
    && echo "root:Docker!" | chpasswd \
    && ssh-keygen -A

COPY sshd_config /etc/ssh/

# TODO: Instead of copying, append contents for sshd instead
COPY supervisord-sshd.conf /opt/tier-support/supervisord-base.conf

EXPOSE 80 2222
