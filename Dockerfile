FROM ubuntu:26.04 AS runtime

ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN rm -f /etc/dpkg/dpkg.cfg.d/excludes \
    && apt_cmd="apt-get" \
    && "${apt_cmd}" update \
    && "${apt_cmd}" install -y --no-install-recommends \
        at \
        bash \
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
    && printf '%s\n' '#!/usr/bin/env bash' 'exec /usr/bin/eza -la --icons=auto --group-directories-first --git "$@"' > /usr/local/bin/ll \
    && chmod 0755 /usr/local/bin/ll \
    && rm -rf /var/lib/apt/lists/*

RUN if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu; fi \
    && if getent group ubuntu >/dev/null 2>&1; then groupdel ubuntu; fi \
    && groupadd -g 1000 student \
    && useradd -m -u 1000 -g 1000 -G adm,cdrom,sudo,dip,plugdev -s /usr/bin/fish student \
    && printf '%s\n' 'student ALL=(ALL:ALL) NOPASSWD:ALL' > /etc/sudoers.d/student \
    && chmod 0440 /etc/sudoers.d/student \
    && ln -sf /home/student/.local/bin/mise /usr/local/bin/mise \
    && for bin_name in python python3 pip uv jupyter jupyter-lab jupyter-notebook jupyter-kernelspec; do \
         ln -sf "/home/student/.local/share/mise/shims/${bin_name}" "/usr/local/bin/${bin_name}"; \
       done

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
    && mise exec -- uv pip install --system --no-cache-dir \
        bash_kernel \
        ipykernel \
        jupyterlab \
        notebook \
    && mise exec -- python -m bash_kernel.install --user \
    && mise exec -- python -c 'import pathlib, site; d = chr(36); sp = pathlib.Path(site.getsitepackages()[0]); (sp / "fish_kernel.py").write_text(f"from ipykernel.kernelbase import Kernel\nfrom ipykernel.kernelapp import IPKernelApp\nimport os, pathlib, subprocess\n\nclass FishKernel(Kernel):\n    implementation = \"fish_kernel\"\n    implementation_version = \"1.0\"\n    language = \"fish\"\n    language_version = \"3.7\"\n    language_info = {{\"name\": \"fish\", \"mimetype\": \"text/x-fish\", \"file_extension\": \".fish\", \"codemirror_mode\": \"shell\"}}\n    banner = \"Fish Shell Kernel (TP Linux)\"\n\n    def __init__(self, **kwargs):\n        super().__init__(**kwargs)\n        self.cwd = os.getcwd()\n\n    def do_execute(self, code, silent, store_history=True, user_expressions=None, allow_stdin=False):\n        if not code.strip():\n            return {{\"status\": \"ok\", \"execution_count\": self.execution_count, \"payload\": [], \"user_expressions\": {{}}}}\n        cwd_file = f\"/tmp/.fish_cwd_{{os.getpid()}}\"\n        wrapped = f\"{{code}}\\nset -l __tp_rc {d}status\\npwd > {{cwd_file}}\\nexit {d}__tp_rc\"\n        proc = subprocess.run([\"/usr/bin/fish\", \"-c\", wrapped], cwd=self.cwd, capture_output=True, text=True)\n        if os.path.exists(cwd_file):\n            new_cwd = pathlib.Path(cwd_file).read_text().strip()\n            if os.path.isdir(new_cwd):\n                self.cwd = new_cwd\n        if not silent:\n            if proc.stdout:\n                self.send_response(self.iopub_socket, \"stream\", {{\"name\": \"stdout\", \"text\": proc.stdout}})\n            if proc.stderr:\n                self.send_response(self.iopub_socket, \"stream\", {{\"name\": \"stderr\", \"text\": proc.stderr}})\n        if proc.returncode != 0:\n            return {{\"status\": \"error\", \"execution_count\": self.execution_count, \"ename\": \"FishError\", \"evalue\": str(proc.returncode), \"traceback\": []}}\n        return {{\"status\": \"ok\", \"execution_count\": self.execution_count, \"payload\": [], \"user_expressions\": {{}}}}\n\nif __name__ == \"__main__\":\n    IPKernelApp.launch_instance(kernel_class=FishKernel)\n", encoding="utf-8")' \
    && mkdir -p \
        /home/student/.local/share/jupyter/kernels/bash \
        /home/student/.local/share/jupyter/kernels/fish \
        /home/student/.local/share/jupyter/kernels/python3 \
    && printf '%s\n' \
        '{' \
        '  "argv": ["/home/student/.local/share/mise/shims/python", "-m", "bash_kernel", "-f", "{connection_file}"],' \
        '  "display_name": "Bash (TP Linux)",' \
        '  "language": "bash",' \
        '  "codemirror_mode": "shell",' \
        '  "env": {' \
        '    "PATH": "/home/student/.local/share/mise/shims:/home/student/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",' \
        '    "SHELL": "/usr/bin/bash",' \
        '    "BASH": "/usr/bin/bash",' \
        '    "TERM": "xterm-256color",' \
        '    "COLORTERM": "truecolor",' \
        '    "LANG": "fr_FR.UTF-8",' \
        '    "LC_ALL": "fr_FR.UTF-8"' \
        '  }' \
        '}' > /home/student/.local/share/jupyter/kernels/bash/kernel.json \
    && printf '%s\n' \
        '{' \
        '  "argv": ["/home/student/.local/share/mise/shims/python", "-m", "fish_kernel", "-f", "{connection_file}"],' \
        '  "display_name": "Fish (TP Linux)",' \
        '  "language": "fish",' \
        '  "codemirror_mode": "shell",' \
        '  "env": {' \
        '    "PATH": "/home/student/.local/share/mise/shims:/home/student/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",' \
        '    "SHELL": "/usr/bin/fish",' \
        '    "TERM": "xterm-256color",' \
        '    "COLORTERM": "truecolor",' \
        '    "LANG": "fr_FR.UTF-8",' \
        '    "LC_ALL": "fr_FR.UTF-8"' \
        '  }' \
        '}' > /home/student/.local/share/jupyter/kernels/fish/kernel.json \
    && printf '%s\n' \
        '{' \
        '  "argv": ["/home/student/.local/share/mise/shims/python", "-m", "ipykernel_launcher", "-f", "{connection_file}"],' \
        '  "display_name": "Python 3.13 (TP Linux)",' \
        '  "language": "python",' \
        '  "env": {' \
        '    "PATH": "/home/student/.local/share/mise/shims:/home/student/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",' \
        '    "SHELL": "/usr/bin/fish",' \
        '    "TERM": "xterm-256color",' \
        '    "COLORTERM": "truecolor",' \
        '    "LANG": "fr_FR.UTF-8",' \
        '    "LC_ALL": "fr_FR.UTF-8"' \
        '  }' \
        '}' > /home/student/.local/share/jupyter/kernels/python3/kernel.json \
    && mise reshim \
    && rm -rf /home/student/.cache/mise /home/student/.cache/uv

RUN xdg-user-dirs-update \
    && mkdir -p /home/student/.config/fish /home/student/.config/fastfetch /home/student/workspace \
    && touch /home/student/.sudo_as_admin_successful \
    && python -c 'import json, pathlib; d = chr(36); cfg = {f"{d}schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json", "logo": None, "display": {"separator": "  ", "color": "white", "constants": ["\u001b[37m", "\u001b[38;2;211;54;130m", "\u001b[38;2;38;139;210m", "\u001b[38;2;133;153;0m"]}, "modules": ["break", {"type": "custom", "key": "╭───────────────────────────────────╮"}, {"type": "kernel", "key": f"│ {{{d}2}}{{{d}1}}  kernel", "format": f"{{{d}2}}{{release>22}}{{{d}1}} │"}, {"type": "command", "key": "│   uptime", "text": "uptime -p | cut -d \x27 \x27 -f 2-", "format": "{>22} │"}, {"type": "shell", "key": f"│ {{{d}2}}{{{d}1}}  shell ", "format": f"{{{d}2}}{{pretty-name>22}}{{{d}1}} │"}, {"type": "command", "key": f"│ {{{d}3}}{{{d}1}}  mem   ", "text": f"LC_ALL=C free -m | awk \x27NR==2{{printf \"%.2f GiB / %.2f GiB\",{d}3/1024,{d}2/1024}}\x27", "format": f"{{{d}3}}{{>22}}{{{d}1}} │"}, {"type": "packages", "key": "│   pkgs  ", "format": "{all>22} │"}, {"type": "command", "key": f"│ {{{d}2}}{{{d}1}}  user  ", "text": "whoami", "format": f"{{{d}2}}{{>22}}{{{d}1}} │"}, {"type": "command", "key": "│   hname ", "text": "hostnamectl hostname 2>/dev/null || uname -n", "format": "{>22} │"}, {"type": "os", "key": f"│ {{{d}4}}󰻀{{{d}1}}  distro", "format": f"{{{d}4}}{{pretty-name>22}}{{{d}1}} │"}, {"type": "custom", "key": "╰───────────────────────────────────╯"}, "break"]}; pathlib.Path("/home/student/.config/fastfetch/config.jsonc").write_text(json.dumps(cfg, ensure_ascii=False, indent=4) + "\n", encoding="utf-8"); fish_cfg = "\n".join(["fish_add_path -g /home/student/.local/share/mise/shims /home/student/.local/bin", "if command -q mise", "    mise activate fish | source", "end", "if status is-interactive", "    set -g fish_greeting \"\"", "    set -gx EDITOR micro", "    set -gx VISUAL micro", "    function ls --wraps=eza --description \"Remplace ls par eza (exa)\"", f"        eza --icons=auto --group-directories-first {d}argv", "    end", "    function ll --wraps=eza --description \"Liste détaillée avec eza\"", f"        eza -la --icons=auto --group-directories-first --git {d}argv", "    end", "    function cat --wraps=bat --description \"Remplace cat par bat\"", f"        bat --paging=never {d}argv", "    end", "    if command -q fastfetch", "        fastfetch; or true", "    end", "end", ""]); pathlib.Path("/home/student/.config/fish/config.fish").write_text(fish_cfg, encoding="utf-8"); p_line = f"export PATH=\"/home/student/.local/share/mise/shims:/home/student/.local/bin:{d}{{PATH}}\"\n"; brc = pathlib.Path("/home/student/.bashrc"); brc.write_text(p_line + brc.read_text(encoding="utf-8") + "\n" + p_line + "alias ls=\"eza --icons=auto --group-directories-first\"\nalias ll=\"eza -la --icons=auto --group-directories-first --git\"\nalias cat=\"bat --paging=never\"\n", encoding="utf-8"); prof = pathlib.Path("/home/student/.profile"); prof.write_text(prof.read_text(encoding="utf-8") + "\n" + p_line, encoding="utf-8")'

EXPOSE 8888

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8888/api')"]

CMD ["jupyter", "lab", "--ip=0.0.0.0", "--port=8888", "--no-browser", "--notebook-dir=/home/student", "--IdentityProvider.token=", "--ServerApp.password=", "--ServerApp.allow_origin=*"]
