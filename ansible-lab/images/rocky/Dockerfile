# Managed node (RedHat family): sshd + python3 + an 'ansible' sudo user
FROM rockylinux:9
RUN dnf install -y openssh-server python3 sudo && dnf clean all && ssh-keygen -A \
 && useradd -m -s /bin/bash ansible && echo "ansible ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ansible
COPY --chmod=755 start.sh /start.sh
CMD ["/start.sh"]
