#!/usr/bin/env bash
#===============================================================================
# Description: 腾讯云纯内网/专线 一键DD重装系统脚本 (Debian 12/13, Ubuntu 22.04/24.04)
# Source: 100% 腾讯云镜像源 (mirrors.cloud.tencent.com / mirrors.tencentyun.com)
# Timezone: Asia/Shanghai (上海时区)
#===============================================================================

set -e

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 1. 权限检查
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[错误]${PLAIN} 必须使用 root 用户执行此脚本！"
    exit 1
fi

# 2. 腾讯云内网镜像源自适应判定
detect_tencent_mirror() {
    # 优先测试纯内网 mirrors.tencentyun.com，不可达则回退到 mirrors.cloud.tencent.com
    if curl -s --connect-timeout 2 http://mirrors.tencentyun.com >/dev/null 2>&1; then
        MIRROR_HOST="mirrors.tencentyun.com"
    else
        MIRROR_HOST="mirrors.cloud.tencent.com"
    fi
    echo -e "${GREEN}[信息]${PLAIN} 采用镜像源: ${MIRROR_HOST}"
}

# 3. 基础依赖检查与补齐
ensure_dependencies() {
    local NEED_INSTALL=0
    for cmd in wget cpio gzip openssl awk grep sed; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            NEED_INSTALL=1
            break
        fi
    done

    if [[ $NEED_INSTALL -eq 1 ]]; then
        echo -e "${YELLOW}[提示]${PLAIN} 正在从当前系统软件源安装必要工具..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y wget cpio gzip openssl ca-certificates
        elif command -v yum >/dev/null 2>&1; then
            yum install -y wget cpio gzip openssl
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y wget cpio gzip openssl
        fi
    fi
}

# 4. 架构与硬件检测
detect_environment() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            DEB_ARCH="amd64"
            UBUNTU_ARCH="amd64"
            ;;
        aarch64|arm64)
            DEB_ARCH="arm64"
            UBUNTU_ARCH="arm64"
            ;;
        *)
            echo -e "${RED}[错误]${PLAIN} 不支持的系统架构: $ARCH"
            exit 1
            ;;
    esac

    # 检测主硬盘
    TARGET_DISK=$(lsblk -dpno NAME | grep -E '/dev/(vd[a-z]|sd[a-z]|nvme[0-9]+n[0-9]+)' | head -n 1)
    if [[ -z "$TARGET_DISK" ]]; then
        TARGET_DISK="/dev/vda"
    fi

    # 获取当前活动网络配置
    NET_DEV=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$NET_DEV" ]] && NET_DEV=$(ip -4 route show default | awk '{print $5; exit}')
    IP_ADDR=$(ip -4 addr show dev "$NET_DEV" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n 1)
    GATEWAY=$(ip -4 route show default dev "$NET_DEV" | awk '{print $3}' | head -n 1)
    NETMASK=$(ip -4 addr show dev "$NET_DEV" | awk '/inet /{print $2}' | cut -d/ -f2 | head -n 1)
}

# 5. 交互式菜单
show_menu() {
    clear
    echo "=========================================================="
    echo "       腾讯云内网专用一键 DD 系统脚本 (高兼容版)"
    echo "=========================================================="
    echo "  镜像源: 全程使用腾讯源 (无外网依赖)"
    echo "  时区:   Asia/Shanghai (自动配置)"
    echo "----------------------------------------------------------"
    echo "  1) Debian 12 (Bookworm) [推荐]"
    echo "  2) Debian 13 (Trixie) [开发版]"
    echo "  3) Ubuntu 22.04 LTS (Jammy)"
    echo "  4) Ubuntu 24.04 LTS (Noble)"
    echo "----------------------------------------------------------"
    read -rp "请选择要重装的系统 [1-4]: " OS_CHOICE

    case "$OS_CHOICE" in
        1) OS_TYPE="debian"; OS_VER="bookworm";;
        2) OS_TYPE="debian"; OS_VER="trixie";;
        3) OS_TYPE="ubuntu"; OS_VER="jammy";;
        4) OS_TYPE="ubuntu"; OS_VER="noble";;
        *) echo -e "${RED}[错误]${PLAIN} 无效选择！"; exit 1;;
    esac

    # 自定义密码
    read -rp "请输入新系统 Root 密码 (直接回车默认: Tencent@2026): " INPUT_PASS
    ROOT_PASS=${INPUT_PASS:-"Tencent@2026"}

    # 自定义 SSH 端口
    read -rp "请输入新系统 SSH 端口 (直接回车默认: 22): " INPUT_PORT
    SSH_PORT=${INPUT_PORT:-"22"}

    # 验证端口数字
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        echo -e "${RED}[错误]${PLAIN} SSH 端口必须在 1-65535 之间！"
        exit 1
    fi

    echo "----------------------------------------------------------"
    echo -e "目标系统:     ${GREEN}${OS_TYPE^} (${OS_VER})${PLAIN}"
    echo -e "目标硬盘:     ${GREEN}${TARGET_DISK}${PLAIN}"
    echo -e "SSH 端口:     ${GREEN}${SSH_PORT}${PLAIN}"
    echo -e "Root 密码:    ${GREEN}${ROOT_PASS}${PLAIN}"
    echo -e "系统时区:     ${GREEN}Asia/Shanghai${PLAIN}"
    echo -e "内网源地址:   ${GREEN}http://${MIRROR_HOST}${PLAIN}"
    echo "----------------------------------------------------------"
    read -rp "确认开始下载并配置重装吗？(y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo -e "${YELLOW}[提示]${PLAIN} 已取消操作。"
        exit 0
    fi
}

# 6. 配置 Debian (12 / 13) 预配置文件与 Initrd
setup_debian() {
    echo -e "${GREEN}[1/4]${PLAIN} 下载 Debian 网络引导文件..."
    NETBOOT_URL="http://${MIRROR_HOST}/debian/dists/${OS_VER}/main/installer-${DEB_ARCH}/current/images/netboot/debian-installer/${DEB_ARCH}"
    
    mkdir -p /boot/netboot
    wget -qO /boot/netboot/vmlinuz "${NETBOOT_URL}/linux" || {
        echo -e "${RED}[错误]${PLAIN} 内网下载内核失败，请检查镜像源连通性！"
        exit 1
    }
    wget -qO /boot/netboot/initrd.gz "${NETBOOT_URL}/initrd.gz"

    echo -e "${GREEN}[2/4]${PLAIN} 生成 Preseed 自动化无人值守配置..."
    mkdir -p /tmp/preseed_dir
    cat << EOF > /tmp/preseed_dir/preseed.cfg
d-i debian-installer/locale string en_US.UTF-8
d-i console-keymaps-at/keymap select us
d-i keyboard-configuration/xkb-keymap select us

d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string debian
d-i netcfg/get_domain string local

d-i mirror/country string manual
d-i mirror/http/hostname string ${MIRROR_HOST}
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

d-i clock-setup/utc boolean true
d-i time/zone string Asia/Shanghai
d-i clock-setup/ntp boolean true
d-i clock-setup/ntp-server string ntp.tencent.com

d-i partman-auto/disk string ${TARGET_DISK}
d-i partman-auto/method string regular
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i passwd/root-password password ${ROOT_PASS}
d-i passwd/root-password-again password ${ROOT_PASS}

tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string curl wget ca-certificates openssh-server
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false

d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string ${TARGET_DISK}
d-i finish-install/reboot_in_progress note

d-i preseed/late_command string in-target sh -c '\
sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config; \
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" /etc/ssh/sshd_config; \
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config; \
mkdir -p /etc/ssh/sshd_config.d; \
echo "Port ${SSH_PORT}" > /etc/ssh/sshd_config.d/00-custom.conf; \
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config.d/00-custom.conf; \
echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/00-custom.conf; \
echo "deb http://${MIRROR_HOST}/debian/ ${OS_VER} main contrib non-free non-free-firmware" > /etc/apt/sources.list; \
echo "deb http://${MIRROR_HOST}/debian/ ${OS_VER}-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
echo "deb http://${MIRROR_HOST}/debian-security ${OS_VER}-security main contrib non-free non-free-firmware" >> /etc/apt/sources.list; \
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime; \
echo "Asia/Shanghai" > /etc/timezone; \
sync'
EOF

    cd /tmp/preseed_dir
    find . | cpio -H newc -o | gzip -9 > /boot/netboot/preseed.cpio.gz
    cd /
    cat /boot/netboot/preseed.cpio.gz >> /boot/netboot/initrd.gz
    rm -rf /tmp/preseed_dir /boot/netboot/preseed.cpio.gz
}

# 7. 配置 Ubuntu (22.04 / 24.04) 官方 Cloud-Image 内网直写
setup_ubuntu() {
    echo -e "${GREEN}[1/4]${PLAIN} 下载引导载体环境..."
    # 使用 Debian 12 Installer 作为内存引导底座
    NETBOOT_URL="http://${MIRROR_HOST}/debian/dists/bookworm/main/installer-${DEB_ARCH}/current/images/netboot/debian-installer/${DEB_ARCH}"
    
    mkdir -p /boot/netboot
    wget -qO /boot/netboot/vmlinuz "${NETBOOT_URL}/linux"
    wget -qO /boot/netboot/initrd.gz "${NETBOOT_URL}/initrd.gz"

    echo -e "${GREEN}[2/4]${PLAIN} 构建全自动内网安装逻辑..."
    RAW_IMAGE_URL="http://${MIRROR_HOST}/ubuntu-cloud-images/${OS_VER}/current/${OS_VER}-server-cloudimg-${UBUNTU_ARCH}.raw.tar.gz"

    PASS_HASH=$(openssl passwd -6 "${ROOT_PASS}")

    mkdir -p /tmp/preseed_dir
    cat << EOF > /tmp/preseed_dir/preseed.cfg
d-i debian-installer/locale string en_US.UTF-8
d-i console-keymaps-at/keymap select us
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string ubuntu
d-i netcfg/get_domain string local

# 显式锁定腾讯内网源与版本，彻底杜绝 Bad archive mirror 报错
d-i mirror/country string manual
d-i mirror/http/hostname string ${MIRROR_HOST}
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
d-i mirror/codename string bookworm
d-i mirror/suite string bookworm

# 在磁盘分区前执行流式解压写入与系统定制
d-i partman/early_command string /bin/sh -c '\
wget -O- "${RAW_IMAGE_URL}" | tar -xzO | dd of=${TARGET_DISK} bs=4M; \
sync; \
sleep 3; \
TARGET_PART=\$(ls ${TARGET_DISK}* | grep -E "${TARGET_DISK}[p]?[1-9]" | sort -V | tail -n 1); \
mkdir -p /mnt/target; \
mount -o rw \${TARGET_PART} /mnt/target || mount -o rw /dev/disk/by-label/cloudimg-rootfs /mnt/target; \
sed -i "s|^root:[^:]*:|root:${PASS_HASH}:|" /mnt/target/etc/shadow; \
sed -i "s/disable_root: true/disable_root: false/g" /mnt/target/etc/cloud/cloud.cfg 2>/dev/null; \
mkdir -p /mnt/target/etc/cloud/cloud.cfg.d; \
echo "ssh_pwauth: true" > /mnt/target/etc/cloud/cloud.cfg.d/99-custom.cfg; \
echo "disable_root: false" >> /mnt/target/etc/cloud/cloud.cfg.d/99-custom.cfg; \
sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /mnt/target/etc/ssh/sshd_config; \
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" /mnt/target/etc/ssh/sshd_config; \
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /mnt/target/etc/ssh/sshd_config; \
mkdir -p /mnt/target/etc/ssh/sshd_config.d; \
echo "Port ${SSH_PORT}" > /mnt/target/etc/ssh/sshd_config.d/00-custom.conf; \
echo "PermitRootLogin yes" >> /mnt/target/etc/ssh/sshd_config.d/00-custom.conf; \
echo "PasswordAuthentication yes" >> /mnt/target/etc/ssh/sshd_config.d/00-custom.conf; \
ln -sf /usr/share/zoneinfo/Asia/Shanghai /mnt/target/etc/localtime; \
echo "Asia/Shanghai" > /mnt/target/etc/timezone; \
echo "deb http://${MIRROR_HOST}/ubuntu/ ${OS_VER} main restricted universe multiverse" > /mnt/target/etc/apt/sources.list; \
echo "deb http://${MIRROR_HOST}/ubuntu/ ${OS_VER}-updates main restricted universe multiverse" >> /mnt/target/etc/apt/sources.list; \
echo "deb http://${MIRROR_HOST}/ubuntu/ ${OS_VER}-security main restricted universe multiverse" >> /mnt/target/etc/apt/sources.list; \
if [ -f /mnt/target/etc/apt/sources.list.d/ubuntu.sources ]; then \
    sed -i "s|http://archive.ubuntu.com/ubuntu|http://${MIRROR_HOST}/ubuntu|g" /mnt/target/etc/apt/sources.list.d/ubuntu.sources; \
    sed -i "s|http://security.ubuntu.com/ubuntu|http://${MIRROR_HOST}/ubuntu|g" /mnt/target/etc/apt/sources.list.d/ubuntu.sources; \
fi; \
umount -l /mnt/target; \
reboot -f'
EOF

    cd /tmp/preseed_dir
    find . | cpio -H newc -o | gzip -9 > /boot/netboot/preseed.cpio.gz
    cd /
    cat /boot/netboot/preseed.cpio.gz >> /boot/netboot/initrd.gz
    rm -rf /tmp/preseed_dir /boot/netboot/preseed.cpio.gz
}

# 8. 写入 GRUB 优先启动项
setup_grub() {
    echo -e "${GREEN}[3/4]${PLAIN} 配置 GRUB 引导入口..."
    cd /

    cat << 'EOF' > /etc/grub.d/05_netboot
#!/bin/sh
exec tail -n +3 $0
menuentry "Tencent Netboot Installer" {
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    insmod xfs
    if search --no-floppy --file --set=root /boot/netboot/vmlinuz; then
        linux /boot/netboot/vmlinuz auto=true priority=critical
        initrd /boot/netboot/initrd.gz
    else
        search --no-floppy --file --set=root /netboot/vmlinuz
        linux /netboot/vmlinuz auto=true priority=critical
        initrd /netboot/initrd.gz
    fi
}
EOF
    chmod +x /etc/grub.d/05_netboot

    # 强制将默认引导项设为网络安装器，防止云厂商环境拦截
    if [ -f /etc/default/grub ]; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="Tencent Netboot Installer"/' /etc/default/grub
        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
    fi

    # 更新 GRUB 配置文件
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        GRUB_CFG=$(find /boot -name "grub.cfg" 2>/dev/null | head -n 1)
        [[ -z "$GRUB_CFG" ]] && GRUB_CFG="/boot/grub2/grub.cfg"
        grub2-mkconfig -o "$GRUB_CFG"
    fi

    echo -e "${GREEN}[4/4]${PLAIN} 引导写入完成！"
}

# 主程序入口
main() {
    detect_tencent_mirror
    ensure_dependencies
    detect_environment
    show_menu

    if [[ "$OS_TYPE" == "debian" ]]; then
        setup_debian
    else
        setup_ubuntu
    fi

    setup_grub

    echo "=========================================================="
    echo -e "${GREEN}[成功] 系统安装引导已就绪！${PLAIN}"
    echo "=========================================================="
    echo -e "服务器将在 5 秒后自动重启并执行静默安装。"
    echo -e "安装预计耗时: 3 ~ 8 分钟 (内网千兆下载通常极快)。"
    echo -e "重启后请使用以下信息连接:"
    echo -e "  SSH 端口:   ${YELLOW}${SSH_PORT}${PLAIN}"
    echo -e "  用户名称:   ${YELLOW}root${PLAIN}"
    echo -e "  Root 密码:  ${YELLOW}${ROOT_PASS}${PLAIN}"
    echo "=========================================================="
    sleep 5
    reboot
}

main "$@"
