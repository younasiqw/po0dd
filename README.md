# po0dd.sh 一键 DD Debian 12（腾讯源）

`po0dd.sh` 是一个基于 **腾讯云 Debian 镜像源** 的无人值守 DD 脚本，可将当前 VPS 一键重装为 **Debian 12 (bookworm)**。

> ⚠️ **极其重要：本脚本会整盘重装系统盘（`/dev/vda` → `/dev/sda` → `/dev/nvme0n1`），所有数据都会被清空！请务必提前备份。**

---

## 功能特性

- 使用腾讯云镜像源：`mirrors.tencent.com`
- 自动识别系统盘（优先顺序：`/dev/vda` → `/dev/sda` → `/dev/nvme0n1`）
- 支持参数：
  - `-passwd <密码>`：指定 root 密码
  - `-port <端口>`：指定 SSH 端口（默认 `22`）
- 未指定 `-passwd` 时自动生成 **20 位随机密码**
- 安装完成后自动：
  - 启用 **root 密码登录 + 密码认证**
  - 使用你指定的 SSH 端口
  - 将 root 初始密码写入 `/root/initial_root_password.txt`
- 无人值守安装：自动分区、安装系统、配置 SSH，无需交互

---

## 使用环境要求

- 支持 KVM / Xen 等完整虚拟化，能够重写 GRUB 并重装系统盘
- 当前系统能访问腾讯源：
  - `http://mirrors.tencent.com/debian/...`
- 必须使用 `root` 用户运行脚本（`whoami` 为 `root`）

---

## 一、常规情况：VPS 能访问 GitHub

如果你的 VPS **可以直接访问 GitHub**，可以用下面的方式下载脚本：

    curl -o po0dd.sh https://raw.githubusercontent.com/vpsbuy/po0/refs/heads/main/po0dd.sh
    chmod +x po0dd.sh

或者：

    wget -O po0dd.sh https://raw.githubusercontent.com/vpsbuy/po0/refs/heads/main/po0dd.sh
    chmod +x po0dd.sh

然后参考下文 **「三、执行 DD 安装」** 即可。

---

## 二、VPS 不能访问 GitHub 时的安装方法（简明版）

如果 **VPS 本身打不开 GitHub**，可以用下面两种方式把脚本弄上去：

> 核心思路：在能访问 GitHub 的地方拿到 `po0dd.sh`，再“搬运”到 VPS。

### 方法一：本地下载，再上传到 VPS（推荐）

1. **在你自己的电脑上**（能访问 GitHub）运行：

       curl -o po0dd.sh https://raw.githubusercontent.com/vpsbuy/po0/refs/heads/main/po0dd.sh
       # 或者：
       wget -O po0dd.sh https://raw.githubusercontent.com/vpsbuy/po0/refs/heads/main/po0dd.sh

2. 确认本地已有文件：

       ls po0dd.sh

3. 使用任意一种方式把 `po0dd.sh` 传到 VPS，例如：

   - `scp`（Linux / macOS / WSL）：

         scp po0dd.sh root@你的VPSIP:/root/

   - WinSCP / 宝塔面板 / Xshell / FinalShell 等工具自带的 **SFTP 文件上传** 功能，把文件拖到 VPS `/root` 目录。

4. 登录 VPS，给脚本加执行权限：

       chmod +x /root/po0dd.sh

5. 然后参考 **「三、执行 DD 安装」**。

---

### 方法二：浏览器打开脚本 → 手动复制粘贴

适合暂时没有 SFTP/SSH 文件传输的场景。

1. 在 **本地电脑浏览器** 打开：

   - `https://raw.githubusercontent.com/vpsbuy/po0/refs/heads/main/po0dd.sh`

2. 在浏览器页面中：

   - `Ctrl + A` 全选  
   - `Ctrl + C` 复制全部脚本内容

3. 登录 VPS（SSH / 面板 Web 终端），创建脚本文件：

       nano po0dd.sh

4. 在编辑器中 **粘贴刚才复制的全部内容**（右键粘贴 / `Ctrl + Shift + V` 等）。

5. 保存并退出（以 nano 为例）：

   - `Ctrl + O` → 回车（保存）  
   - `Ctrl + X`（退出）

6. 给脚本加执行权限：

       chmod +x po0dd.sh

7. 然后参考 **「三、执行 DD 安装」**。

---

## 三、执行 DD 安装

> ⚠️ **再次提醒：执行后会整盘重装系统盘，数据无法恢复，请先备份重要数据。**

脚本通用用法：

    ./po0dd.sh [可选参数]

### 1. 最简单用法：随机密码 + 默认 22 端口

    ./po0dd.sh

脚本会自动：

- 检测系统盘（`/dev/vda` → `/dev/sda` → `/dev/nvme0n1`）
- 生成一个随机 root 密码，并在终端输出
- 下载 debian-installer 内核和 initrd（走腾讯源）
- 注入无人值守配置
- 写入 GRUB 启动项，准备自动安装

按提示输入大写 `YES` 进行确认。

---

### 2. 指定 root 密码

    ./po0dd.sh -passwd MyStrongPwd123

- root 密码将被设置为 `MyStrongPwd123`  
- SSH 端口保持默认 `22`

---

### 3. 指定 SSH 端口（例如 60022）

    ./po0dd.sh -port 60022

- root 密码随机生成  
- SSH 只监听 `60022` 端口

---

### 4. 同时指定密码和端口

    ./po0dd.sh -passwd Mjj2025 -port 60022

---

## 四、重启并等待安装完成

脚本最后会提示是否立刻重启：

    是否立刻重启？(y/N):

- 输入 `y` 或 `Y`：立即执行 `reboot`  
- 或者你稍后手动执行：

       reboot

重启后，系统会自动从 GRUB 中类似以下条目启动：

    *** po0 Auto Install Debian 12 (DD ALL /dev/XXX) via Tencent ***

随后自动完成 Debian 12 安装，安装结束后会再次自动重启进入新系统。

---

## 五、安装完成后的登录方式

安装完成并自动重启后：

1. 若未指定 `-port`（默认 22）：

       ssh root@你的IP

2. 若指定了端口，例如 `-port 60022`：

       ssh -p 60022 root@你的IP

3. 密码来源：

   - 如果使用了 `-passwd MyStrongPwd`：密码就是你传入的这个值；  
   - 如果没有传 `-passwd`（随机密码）：
     - 脚本执行时会在终端打印随机密码；  
     - 新系统内也会写入到：

           cat /root/initial_root_password.txt

如暂时 SSH 不通，可先通过商家面板 VNC 登录后查看此文件获取密码。

---

## 六、常见问题简表

### 1. SSH 连不通

- 确认使用的是 **正确端口**（默认 22，或你指定的 `-port`）
- 检查商家面板的：
  - 防火墙 / 安全组是否开放对应 TCP 端口
  - 是否存在 NAT 端口映射限制

在 VNC 中可以执行：

    ss -lnpt | grep ssh
    systemctl status ssh

若本机监听正常但外部连不通，多半是商家侧防火墙或网络策略问题。

---

### 2. 提示找不到系统盘

脚本默认自动识别以下设备：

- `/dev/vda`
- `/dev/sda`
- `/dev/nvme0n1`

如果你的环境使用其他设备名称（例如 `/dev/vdb` 等），需要自行编辑 `po0dd.sh` 中的 `detect_disk()` 函数，加入对应设备。

---

## 七、风险提示

- 本脚本会清空系统盘上所有数据（包括所有分区）
- 使用前请确认：
  - 已备份重要数据  
  - 有商家控制台 / VNC 应急登录方式  
  - 清楚当前宿主机的网络和端口限制情况（如 22 端口是否被封）

---

## 八、参数速查

- `-passwd <密码>`：指定 root 密码；不指定则随机生成 20 位密码  
- `-port <端口>`：指定 SSH 端口，默认 `22`

示例：

    # 随机密码 + 22 端口
    ./po0dd.sh

    # 自定义密码 + 22 端口
    ./po0dd.sh -passwd MyStrongPwd

    # 随机密码 + 60022 端口
    ./po0dd.sh -port 60022

    # 自定义密码 + 自定义端口
    ./po0dd.sh -passwd MyPwd123 -port 60022
