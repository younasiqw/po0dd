#!/usr/bin/env bash
# =========================================================
# 一键 DD 网络重装系统脚本 (Enhanced Version)
# 支持: Debian 12 / Debian 13 / Ubuntu 22.04 / Ubuntu 24.04
# 源: 腾讯云镜像源 (自动适配 x86/ARM)
# =========================================================

set -o pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
SKYBLUE='\033[0;36m'
PLAIN='\033[0m'
BOLD='\033[1m'

TIMEZONE="Asia/Shanghai"

# 1. 基础环境校验
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误]${PLAIN} 此脚本必须以 root 用户权限运行！"
        exit 1
    fi
}

check_virt() {
    local virt_type
    virt_type=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    if [[ "$virt_type" == "openvz" || "$virt_type" == "lxc" ]]; then
        echo -e "${RED}[致命错误]${PLAIN} 检测到当前环境为容器虚拟化 (${virt_type})，无法通过 DD 方式替换内核重装！"
        exit 1
    fi
}

get_system_info() {
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            ARCH_TYPE="amd64"
            ;;
        aarch64|arm64)
            ARCH_TYPE="arm64"
            ;;
        *)
            echo -e "${RED}[错误]${PLAIN} 暂不支持当前 CPU 架构: ${ARCH}"
            exit 1
            ;;
    esac

    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    IPV4_ADDR=$(curl -s4m 5 icanhazip.com || curl -s4m 5 ip.sb || echo "获取失败")
}

# 2. 依赖检查与低内存 Swap 防护
prepare_env() {
    echo -e "${SKYBLUE}>>> 检查并安装必要依赖...${PLAIN}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget ca-certificates gawk >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget ca-certificates gawk >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl wget ca-certificates gawk
    fi

    # 针对小于 1024MB 内存的主机添加临时 Swap，防止 Ubuntu 22.04/24.04 在 initramfs 解包时 OOM
    if [[ "$TOTAL_RAM" -lt 1024 ]]; then
        echo -e "${YELLOW}[警告] 机器物理内存 (${TOTAL_RAM}MB) 较低，正在创建 1GB 临时 Swap 避免重装中途崩溃...${PLAIN}"
        if [[ ! -f /tmp_swapfile ]]; then
            dd if=/dev/zero of=/tmp_swapfile bs=1M count=1024 status=none
            chmod 600 /tmp_swapfile
            mkswap /tmp_swapfile >/dev/null 2>&1
            swapon /tmp_swapfile >/dev/null 2>&1
        fi
    fi
}

# 3. 随机密码生成工具
generate_password() {
    tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c 16
}

# 4. 交互式菜单与配置收集
collect_input() {
    clear
    echo -e "${BOLD}${SKYBLUE}========================================================${PLAIN}"
    echo -e "${BOLD}       Linux 一键 DD 系统重装脚本 (腾讯云源增强版)       ${PLAIN}"
    echo -e "${BOLD}${SKYBLUE}========================================================${PLAIN}"
    echo -e "架构类型   : ${GREEN}${ARCH} (${ARCH_TYPE})${PLAIN}"
    echo -e "物理内存   : ${GREEN}${TOTAL_RAM} MB${PLAIN}"
    echo -e "公网 IPv4  : ${GREEN}${IPV4_ADDR}${PLAIN}"
    echo -e "默认时区   : ${GREEN}${TIMEZONE}${PLAIN}"
    echo -e "${SKYBLUE}--------------------------------------------------------${PLAIN}"
    echo -e "请选择需要安装的系统版本:"
    echo -e "  ${GREEN}1)${PLAIN} Debian 12 (Bookworm) [默认/推荐]"
    echo -e "  ${GREEN}2)${PLAIN} Debian 13 (Trixie)"
    echo -e "  ${GREEN}3)${PLAIN} Ubuntu 22.04 LTS (Jammy)"
    echo -e "  ${GREEN}4)${PLAIN} Ubuntu 24.04 LTS (Noble)"
    echo -e "${SKYBLUE}--------------------------------------------------------${PLAIN}"
    read -erp "请输入选项 [1-4, 默认 1]: " OS_CHOICE
    OS_CHOICE=${OS_CHOICE:-1}

    case "$OS_CHOICE" in
        1)
            TARGET_OS="debian"
            TARGET_VER="12"
            MIRROR_URL="https://mirrors.cloud.tencent.com/debian/"
            ;;
        2)
            TARGET_OS="debian"
            TARGET_VER="13"
            MIRROR_URL="https://mirrors.cloud.tencent.com/debian/"
            ;;
        3)
            TARGET_OS="ubuntu"
            TARGET_VER="22.04"
            if [[ "$ARCH_TYPE" == "arm64" ]]; then
                MIRROR_URL="https://mirrors.cloud.tencent.com/ubuntu-ports/"
            else
                MIRROR_URL="https://mirrors.cloud.tencent.com/ubuntu/"
            fi
            ;;
        4)
            TARGET_OS="ubuntu"
            TARGET_VER="24.04"
            if [[ "$ARCH_TYPE" == "arm64" ]]; then
                MIRROR_URL="https://mirrors.cloud.tencent.com/ubuntu-ports/"
            else
                MIRROR_URL="https://mirrors.cloud.tencent.com/ubuntu/"
            fi
            ;;
        *)
            echo -e "${RED}[错误]${PLAIN} 输入无效，已取消操作。"
            exit 1
            ;;
    esac

    # 自定义密码
    echo ""
    local default_pass
    default_pass=$(generate_password)
    read -erp "请输入 Root 密码 (直接回车生成随机密码: ${default_pass}): " USER_PASS
    USER_PASS=${USER_PASS:-$default_pass}

    # 自定义 SSH 端口
    echo ""
    while true; do
        read -erp "请输入 SSH 端口 [1-65535, 默认 22]: " USER_PORT
        USER_PORT=${USER_PORT:-22}
        if [[ "$USER_PORT" =~ ^[0-9]+$ ]] && [ "$USER_PORT" -ge 1 ] && [ "$USER_PORT" -le 65535 ]; then
            break
        else
            echo -e "${RED}端口格式不正确，请输入 1 到 65535 之间的数字！${PLAIN}"
        fi
    done

    # 确认参数面板
    clear
    echo -e "${BOLD}${YELLOW}=================== 请确认安装配置信息 ===================${PLAIN}"
    echo -e "目标系统     : ${GREEN}${TARGET_OS^} ${TARGET_VER}${PLAIN}"
    echo -e "软件源 (Mirror): ${GREEN}${MIRROR_URL}${PLAIN}"
    echo -e "SSH 登录端口 : ${GREEN}${USER_PORT}${PLAIN}"
    echo -e "Root 登录密码: ${RED}${USER_PASS}${PLAIN}"
    echo -e "系统时区     : ${GREEN}${TIMEZONE}${PLAIN}"
    echo -e "${BOLD}${YELLOW}========================================================${PLAIN}"
    echo -e "${RED}[警告] DD 重装将彻底格式化硬盘，所有数据均会丢失！${PLAIN}"
    read -erp "确认无误并开始执行重装? (y/n) [默认 y]: " CONFIRM
    CONFIRM=${CONFIRM:-y}

    if [[ "$CONFIRM" != [yY] && "$CONFIRM" != [yY][eE][sS] ]]; then
        echo -e "${YELLOW}用户取消，操作终止。${PLAIN}"
        exit 0
    fi
}

# 5. 执行底层重装调用
execute_dd() {
    echo -e "${SKYBLUE}>>> 准备底层启动引导并下发网络配置...${PLAIN}"

    # 采用成熟的 Linux netboot 通用安装引导器
    local reinstall_script="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"
    
    echo -e "${SKYBLUE}>>> 下载核心重装工具...${PLAIN}"
    if ! curl -sSL -O "$reinstall_script"; then
        wget -q "$reinstall_script" -O reinstall.sh || {
            echo -e "${RED}[错误] 无法拉取重装核心工具，请检查服务器 DNS 或网络连通性！${PLAIN}"
            exit 1
        }
    fi
    chmod +x reinstall.sh

    echo -e "${GREEN}>>> 正在构建 Grub/Kernel 安装链条，准备就绪后将立即重启...${PLAIN}"
    sleep 2

    # 构建调用参数
    ./reinstall.sh "${TARGET_OS}" "${TARGET_VER}" \
        --mirror "${MIRROR_URL}" \
        --password "${USER_PASS}" \
        --port "${USER_PORT}" \
        --timezone "${TIMEZONE}"

    # 触发重启生效
    echo -e "${YELLOW}>>> 配置文件注入完成，系统正在重启进行无交互静默重装...${PLAIN}"
    echo -e "${YELLOW}>>> 请在 10-15 分钟后使用新密码及端口连接：ssh -p ${USER_PORT} root@${IPV4_ADDR}${PLAIN}"
    sleep 3
    reboot
}

main() {
    check_root
    check_virt
    get_system_info
    prepare_env
    collect_input
    execute_dd
}

main "$@"
