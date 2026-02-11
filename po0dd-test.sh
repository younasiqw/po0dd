#!/bin/bash
# =========================================
#  po0dd_v3.sh
#  Auto Install Debian / Ubuntu (Legacy) via Tencent Mirror
#
#  特性：
#    - 支持指定系统: Debian (11, 12), Ubuntu (18.04, 20.04)
#    - 移除 CentOS 支持
#    - 自动识别系统盘
#    - 支持自定义密码 (-passwd) 和端口 (-port)
#
#  说明：
#    Ubuntu 22.04/24.04 官方已弃用 Netboot 安装方式，
#    本脚本仅支持 Legacy Installer 兼容的版本 (Max Ubuntu 20.04)。
#
#  用法：
#    bash po0dd.sh                                      # 交互式菜单
#    bash po0dd.sh -d debian -v 12                      # 安装 Debian 12
#    bash po0dd.sh -d ubuntu -v 20.04 -passwd MyPwd     # 安装 Ubuntu 20.04
# =========================================

set -e

# ======== 默认配置 ========
TARGET_DISTRO="debian"          # 默认发行版
TARGET_VERSION="12"             # 默认版本
HOSTNAME="localhost"
TIMEZONE="Asia/Shanghai"
MIRROR_HOST="mirrors.tencent.com"

ROOT_PASSWORD=""                # 留空随机
SSH_PORT="22"                   
DISABLE_IPV6=true

# 颜色
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
RED="\033[0;31m"
NC="\033[0m"

usage() {
  cat <<EOF
用法:
  bash po0dd.sh [-d debian|ubuntu] [-v version] [-passwd 密码] [-port 端口]

参数:
  -d, --distro   发行版 (debian / ubuntu)
  -v, --version  版本号 (Debian: 11/12, Ubuntu: 18.04/20.04)
  -passwd        root 密码 (默认随机)
  -port          SSH 端口 (默认 22)

注意: Ubuntu 22.04+ 不支持此类 Netboot 安装，请勿尝试。
EOF
}

# ------- 参数解析 -------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--distro) TARGET_DISTRO="$2"; shift 2 ;;
    -v|--version) TARGET_VERSION="$2"; shift 2 ;;
    -passwd|--passwd) ROOT_PASSWORD="$2"; shift 2 ;;
    -port|--port) SSH_PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo -e "${YELLOW}[!] 未知参数: $1${NC}"; usage; exit 1 ;;
  esac
done

# ------- 版本检查与代号映射 -------
get_distro_info() {
  local dist=$(echo "$TARGET_DISTRO" | tr '[:upper:]' '[:lower:]')
  
  case "$dist" in
    debian)
      MIRROR_DIR="/debian"
      case "$TARGET_VERSION" in
        12) CODENAME="bookworm" ;;
        11) CODENAME="bullseye" ;;
        *)  echo -e "${RED}[!] 仅支持 Debian 11 或 12${NC}"; exit 1 ;;
      esac
      ;;
    ubuntu)
      MIRROR_DIR="/ubuntu"
      case "$TARGET_VERSION" in
        20.04) CODENAME="focal" ;;
        18.04) CODENAME="bionic" ;;
        22.04|24.04)
          echo -e "${RED}[!] 错误: Ubuntu 22.04/24.04 已废弃 Netboot 安装器。${NC}"
          echo -e "${YELLOW}提示: 请安装 Debian 12，或 Ubuntu 20.04。此脚本无法原生安装 22.04+。${NC}"
          exit 1
          ;;
        *) echo -e "${RED}[!] 不支持的 Ubuntu 版本: $TARGET_VERSION${NC}"; exit 1 ;;
      esac
      ;;
    centos|redhat|alma)
      echo -e "${RED}[!] CentOS/RedHat 已不再支持。${NC}"; exit 1 ;;
    *)
      echo -e "${RED}[!] 未知发行版: $TARGET_DISTRO${NC}"; exit 1 ;;
  esac
  
  FINAL_DISTRO="$dist"
  FINAL_CODENAME="$CODENAME"
  FINAL_MIRROR_DIR="$MIRROR_DIR"
}

# ------- 交互式菜单 -------
if [[ $# -eq 0 && -z "$ROOT_PASSWORD" ]]; then
  echo -e "${BLUE}=== po0dd 系统重装 (Tencent Mirror) ===${NC}"
  echo "1) Debian 12 (Bookworm) [推荐]"
  echo "2) Debian 11 (Bullseye)"
  echo "3) Ubuntu 20.04 LTS (Focal) [Legacy]"
  echo "4) Ubuntu 18.04 LTS (Bionic)"
  echo -e "${YELLOW}注：Ubuntu 22.04/24.04 无法通过镜像源原生 DD${NC}"
  echo
  read -rp "请选择 [1-4]: " CHOICE
  case "$CHOICE" in
    1|"") TARGET_DISTRO="debian"; TARGET_VERSION="12" ;;
    2)    TARGET_DISTRO="debian"; TARGET_VERSION="11" ;;
    3)    TARGET_DISTRO="ubuntu"; TARGET_VERSION="20.04" ;;
    4)    TARGET_DISTRO="ubuntu"; TARGET_VERSION="18.04" ;;
    *)    echo -e "${RED}无效选择${NC}"; exit 1 ;;
  esac
  
  read -rp "SSH 端口 [22]: " INPUT_PORT
  [[ -n "$INPUT_PORT" ]] && SSH_PORT="$INPUT_PORT"
  
  read -rp "Root 密码 [随机]: " INPUT_PWD
  [[ -n "$INPUT_PWD" ]] && ROOT_PASSWORD="$INPUT_PWD"
fi

get_distro_info

# ------- 检测硬盘 -------
detect_disk() {
  if [[ -b /dev/vda ]]; then echo "/dev/vda"
  elif [[ -b /dev/sda ]]; then echo "/dev/sda"
  elif [[ -b /dev/nvme0n1 ]]; then echo "/dev/nvme0n1"
  else echo ""; fi
}
DISK="$(detect_disk)"
[[ -z "$DISK" ]] && { echo -e "${RED}[!] 未找到系统盘${NC}"; exit 1; }

# ------- 密码生成 -------
gen_random_password() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20; }
if [[ -z "$ROOT_PASSWORD" || "$ROOT_PASSWORD" == "RANDOM" ]]; then
  ROOT_PASSWORD="$(gen_random_password)"
  RANDOM_PW=1
else
  RANDOM_PW=0
fi

# ------- 确认 -------
echo -e "${BLUE}[*] 准备安装: ${FINAL_DISTRO} ${TARGET_VERSION} (${FINAL_CODENAME})${NC}"
echo -e "    系统盘: $DISK | 端口: $SSH_PORT"
if [[ $RANDOM_PW -eq 1 ]]; then
  echo -e "${GREEN}    随机密码: ${ROOT_PASSWORD}${NC} (请保存!)"
else
  echo -e "    Root密码: ${ROOT_PASSWORD}"
fi
echo
read -rp "输入 YES (大写) 确认重装: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && exit 1

# ------- 安装工具 -------
ensure_tools() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1; apt-get install -y cpio gzip wget
  elif command -v yum >/dev/null 2>&1; then
    yum install -y cpio gzip wget
  elif command -v apk >/dev/null 2>&1; then
    apk add cpio gzip wget
  fi
}
ensure_tools

# ------- 下载内核 -------
WORK_DIR="/boot/debian-autoinstall"
rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR"; cd "$WORK_DIR"

echo -e "${BLUE}[*] 下载安装内核...${NC}"

# 腾讯源路径构建
# Debian: .../main/installer-amd64/current/images/netboot/debian-installer/amd64/
# Ubuntu 20.04: .../main/installer-amd64/current/legacy-images/netboot/ubuntu-installer/amd64/
BASE_URL="http://${MIRROR_HOST}${FINAL_MIRROR_DIR}/dists/${FINAL_CODENAME}/main/installer-amd64/current"

if [[ "$FINAL_DISTRO" == "ubuntu" ]]; then
  # Ubuntu 路径特殊
  NETBOOT_PATH="legacy-images/netboot/ubuntu-installer/amd64"
else
  NETBOOT_PATH="images/netboot/debian-installer/amd64"
fi

KERNEL_URL="${BASE_URL}/${NETBOOT_PATH}/linux"
INITRD_URL="${BASE_URL}/${NETBOOT_PATH}/initrd.gz"

wget --no-check-certificate -O linux "$KERNEL_URL"
wget --no-check-certificate -O initrd.gz "$INITRD_URL"

if [[ ! -s linux || ! -s initrd.gz ]]; then
  echo -e "${RED}[!] 下载失败。${NC}"
  echo -e "${YELLOW}可能原因: 腾讯源暂时未同步该版本，或该版本(如Ubuntu 22.04+)不支持Netboot。${NC}"
  echo "尝试地址: $KERNEL_URL"
  exit 1
fi

# ------- 注入 Preseed -------
echo -e "${BLUE}[*] 配置 Preseed...${NC}"
mkdir initrd-dir; cd initrd-dir
gzip -d -c ../initrd.gz | cpio -idmv >/dev/null 2>&1

cat > preseed.cfg <<EOF
# Generated by po0dd_v3.sh

d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/disable_dhcp boolean false
d-i netcfg/get_hostname string ${HOSTNAME}

d-i clock-setup/utc boolean true
d-i time/zone string ${TIMEZONE}
d-i clock-setup/ntp boolean true

d-i mirror/country string manual
d-i mirror/http/hostname string ${MIRROR_HOST}
d-i mirror/http/directory string ${FINAL_MIRROR_DIR}
d-i mirror/http/proxy string
d-i mirror/suite string ${FINAL_CODENAME}
d-i mirror/udeb/suite string ${FINAL_CODENAME}

d-i apt-setup/use_mirror boolean true
d-i apt-setup/security_host string ${MIRROR_HOST}
d-i apt-setup/security_path string ${FINAL_MIRROR_DIR}-security

# Debian 特有源
$(if [[ "$FINAL_DISTRO" == "debian" ]]; then echo "d-i apt-setup/non-free boolean true"; fi)
$(if [[ "$FINAL_DISTRO" == "debian" ]]; then echo "d-i apt-setup/contrib boolean true"; fi)

# 分区 (自动整盘)
d-i partman-auto/method string regular
d-i partman-auto/disk string ${DISK}
d-i partman-auto/choose_recipe select atomic
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

# 用户
d-i passwd/root-login boolean true
d-i passwd/root-password password ${ROOT_PASSWORD}
d-i passwd/root-password-again password ${ROOT_PASSWORD}
d-i user-setup/allow-password-weak boolean true
d-i passwd/make-user boolean false

# 软件
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string curl wget vim openssh-server

# GRUB
d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string ${DISK}

d-i finish-install/reboot_in_progress note

# 后处理：修正 SSH 配置
d-i preseed/late_command string in-target sh -c ' \
  apt-get install -y openssh-server || true; \
  sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin yes/g" /etc/ssh/sshd_config; \
  sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g" /etc/ssh/sshd_config; \
  sed -i "/^Port /d" /etc/ssh/sshd_config; \
  echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config; \
  echo "${ROOT_PASSWORD}" > /root/initial_root_password.txt; \
  chmod 600 /root/initial_root_password.txt; \
  systemctl enable ssh; \
  systemctl restart ssh;'
EOF

find . | cpio -H newc -o | gzip -9 > ../initrd-preseed.gz
cd ..
mv initrd-preseed.gz initrd.gz
rm -rf initrd-dir

# ------- GRUB 设置 -------
echo -e "${BLUE}[*] 写入 GRUB...${NC}"
GRUB_SCRIPT="/etc/grub.d/05_po0_autoinstall"

cat > "$GRUB_SCRIPT" <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry '*** Install ${FINAL_DISTRO} ${FINAL_CODENAME} (DD Mode) ***' {
    insmod gzio
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    search --no-floppy --file /boot/debian-autoinstall/linux --set=root
    linux /boot/debian-autoinstall/linux auto=true priority=critical preseed/file=/preseed.cfg debian-installer/locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us netcfg/choose_interface=auto netcfg/disable_dhcp=false mirror/country=manual mirror/http/hostname=${MIRROR_HOST} mirror/http/directory=${FINAL_MIRROR_DIR} mirror/http/proxy= mirror/suite=${FINAL_CODENAME} hostname=${HOSTNAME} ${DISABLE_IPV6:+ipv6.disable=1}
    initrd /boot/debian-autoinstall/initrd.gz
}
EOF
chmod +x "$GRUB_SCRIPT"

if command -v update-grub >/dev/null 2>&1; then
  update-grub
elif command -v grub-mkconfig >/dev/null 2>&1; then
  [[ -f /boot/grub/grub.cfg ]] && grub-mkconfig -o /boot/grub/grub.cfg
  [[ -f /boot/grub2/grub.cfg ]] && grub-mkconfig -o /boot/grub2/grub.cfg
else
  echo -e "${YELLOW}[!] 请手动更新 GRUB!${NC}"
fi

echo
echo -e "${GREEN}完成！请 reboot 重启，系统将自动进入安装流程。${NC}"
echo -e "${GREEN}SSH 端口: ${SSH_PORT} | Root 密码: ${ROOT_PASSWORD}${NC}"
echo
read -rp "立刻重启? (y/N): " RB
if [[ "$RB" =~ ^[Yy]$ ]]; then reboot; fi
