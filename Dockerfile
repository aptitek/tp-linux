FROM ubuntu:26.04 AS runtime

ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN rm -f /etc/dpkg/dpkg.cfg.d/excludes \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        at \
        bash-completion \
        bat \
        bind9-dnsutils \
        btop \
        build-essential \
        bzip2 \
        ca-certificates \
        command-not-found \
        cron \
        curl \
        dmidecode \
        eza \
        fastfetch \
        fd-find \
        fdisk \
        file \
        fish \
        fzf \
        git \
        gzip \
        htop \
        info \
        iproute2 \
        iptables \
        iputils-ping \
        jq \
        less \
        locales \
        lshw \
        lsof \
        man-db \
        manpages \
        manpages-dev \
        micro \
        mtr-tiny \
        nano \
        ncdu \
        net-tools \
        netcat-openbsd \
        openssh-client \
        p7zip-full \
        parted \
        pciutils \
        plocate \
        procps \
        psmisc \
        ripgrep \
        rsync \
        strace \
        "sudo" \
        tar \
        tmux \
        traceroute \
        tree \
        tzdata \
        ufw \
        unzip \
        usbutils \
        util-linux \
        vim \
        wget \
        whois \
        xdg-user-dirs \
        xz-utils \
        zip \
        zstd \
    && locale-gen en_US.UTF-8 fr_FR.UTF-8 \
    && update-locale LANG=fr_FR.UTF-8 \
    && ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && ln -sf /usr/bin/eza /usr/local/bin/exa \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && rm -rf /var/lib/apt/lists/*

RUN if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi \
    && if getent group ubuntu >/dev/null 2>&1; then groupdel ubuntu; fi \
    && groupadd -g 1000 student \
    && useradd -m -u 1000 -g 1000 -G adm,cdrom,sudo,dip,plugdev -s /usr/bin/fish student \
    && printf '%s\n' 'student ALL=(ALL:ALL) NOPASSWD:ALL' > /etc/sudoers.d/student \
    && chmod 0440 /etc/sudoers.d/student

USER student
WORKDIR /home/student

ENV HOME="/home/student" \
    USER="student" \
    SHELL="/usr/bin/fish" \
    LANG="fr_FR.UTF-8" \
    LC_ALL="fr_FR.UTF-8" \
    TZ="Europe/Paris" \
    TERM="xterm-256color" \
    COLORTERM="truecolor" \
    EDITOR="micro" \
    VISUAL="micro" \
    MISE_DATA_DIR="/home/student/.local/share/mise" \
    MISE_CONFIG_DIR="/home/student/.config/mise" \
    MISE_CACHE_DIR="/home/student/.cache/mise" \
    MISE_TRUSTED_CONFIG_PATHS="/home/student:/home/student/workspace" \
    PATH="/home/student/.local/share/mise/shims:/home/student/.local/bin:${PATH}"

RUN curl -fsSL https://mise.run -o /tmp/mise-install.sh \
    && sh /tmp/mise-install.sh \
    && rm -f /tmp/mise-install.sh \
    && mise use --global python@3.13 uv@0.6 \
    && mise exec -- pip install --no-cache-dir \
        bash_kernel \
        ipykernel \
        jupyterlab \
        notebook \
    && mise exec -- python -m bash_kernel.install --user \
    && mise reshim \
    && rm -rf /home/student/.cache/mise

RUN xdg-user-dirs-update \
    && mkdir -p /home/student/.config/fish /home/student/workspace \
    && touch /home/student/.sudo_as_admin_successful \
    && printf '%s\n' \
        'mise activate fish | source' \
        'if status is-interactive' \
        '    set -g fish_greeting ""' \
        '    set -gx EDITOR micro' \
        '    set -gx VISUAL micro' \
        '    function ls --wraps=eza --description "Remplace ls par eza (exa)"' \
        '        eza --icons=auto --group-directories-first $argv' \
        '    end' \
        '    function ll --wraps=eza --description "Liste détaillée avec eza"' \
        '        eza -la --icons=auto --group-directories-first --git $argv' \
        '    end' \
        '    function cat --wraps=bat --description "Remplace cat par bat"' \
        '        bat --paging=never $argv' \
        '    end' \
        '    fastfetch' \
        'end' \
        > /home/student/.config/fish/config.fish \
    && printf '\n%s\n' \
        'export PATH="/home/student/.local/share/mise/shims:/home/student/.local/bin:${PATH}"' \
        'alias ls="eza --icons=auto --group-directories-first"' \
        'alias ll="eza -la --icons=auto --group-directories-first --git"' \
        'alias cat="bat --paging=never"' \
        >> /home/student/.bashrc

EXPOSE 8888

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8888/api')"]

CMD ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", "--no-browser", "--notebook-dir=/home/student", "--IdentityProvider.token=", "--ServerApp.password=", "--ServerApp.allow_origin=*"]
