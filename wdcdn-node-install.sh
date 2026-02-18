#!/bin/bash
###
### wdCDN Node 全Linux系统兼容安装脚本
### 官方文档：http://www.wdcdn.com
###

# 错误处理函数
function err {
    echo 
    echo 
    echo "==================== 系统信息 ===================="
    uname -a
    [ -f /etc/os-release ] && cat /etc/os-release
    echo "=================================================="
    echo -e "\033[31m---- Install Error: $1 -----------\033[0m"
    echo
    echo -e "\033[0m"
    echo
    exit 1
}

# 安装完成提示函数
function finsh {
    echo
    echo
	echo
	echo -e "      \033[32mCongratulations! wdCDN Node install is complete\033[0m"
	echo -e "      More information please visit http://www.wdcdn.com\033[0m"
	echo
}

# 检测系统发行版与包管理器
function detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        export OS=$ID
        export VERSION_ID=$VERSION_ID
    else
        err "无法识别的Linux系统，仅支持主流systemd发行版"
    fi

    # 确定包管理器
    if command -v dnf &> /dev/null; then
        export PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        export PKG_MANAGER="yum"
    elif command -v apt &> /dev/null; then
        export PKG_MANAGER="apt"
    elif command -v pacman &> /dev/null; then
        export PKG_MANAGER="pacman"
    elif command -v zypper &> /dev/null; then
        export PKG_MANAGER="zypper"
    else
        err "无法识别的包管理器，仅支持 dnf/yum/apt/pacman/zypper"
    fi
    echo "检测到系统：$OS，包管理器：$PKG_MANAGER"
}

# 通用包安装函数
function pkg_install() {
    case $PKG_MANAGER in
        dnf|yum)
            $PKG_MANAGER install -y "$@"
            ;;
        apt)
            $PKG_MANAGER update -y
            $PKG_MANAGER install -y "$@"
            ;;
        pacman)
            $PKG_MANAGER -Syu --noconfirm "$@"
            ;;
        zypper)
            $PKG_MANAGER install -y --no-recommends "$@"
            ;;
    esac
    return $?
}

# 基础依赖包安装与适配
function install_base_deps() {
    echo "正在安装系统基础依赖..."
    case $OS in
        centos|rhel|rocky|alma|ol|fedora)
            BASE_DEPS=(
                epel-release wget tar net-tools make autoconf
                gcc gcc-c++ pcre-devel openssl-devel zlib-devel
                readline-devel python3-setuptools python3-pip
            )
            ;;
        debian|ubuntu|linuxmint|popos)
            BASE_DEPS=(
                wget tar net-tools build-essential autoconf
                libpcre3-dev libssl-dev zlib1g-dev libreadline-dev
                python3-setuptools python3-pip
            )
            ;;
        arch|manjaro|endeavouros)
            BASE_DEPS=(
                wget tar net-tools base-devel autoconf
                pcre openssl zlib readline
                python-setuptools python-pip
            )
            ;;
        opensuse*|sles)
            BASE_DEPS=(
                wget tar net-tools gcc gcc-c++ make autoconf
                pcre-devel libopenssl-devel zlib-devel readline-devel
                python3-setuptools python3-pip
            )
            ;;
        *)
            err "不支持的系统发行版：$OS"
            ;;
    esac

    pkg_install "${BASE_DEPS[@]}" || err "基础依赖安装失败，请检查网络或软件源配置"

    # 兼容python软链接，适配旧版python调用
    if ! command -v python &> /dev/null; then
        ln -sf /usr/bin/python3 /usr/bin/python
        echo "已创建python软链接至python3"
    fi
}

# 系统时间同步与时区配置
function time_sync() {
    echo "正在配置系统时区与时间同步..."
    # 设置上海时区
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    hwclock -w &> /dev/null

    # 适配不同时间同步方案
    if command -v chronyc &> /dev/null; then
        # 优先使用chrony（主流系统默认）
        systemctl enable --now chronyd &> /dev/null
        chronyc makestep &> /dev/null
        echo "已启用chrony时间同步"
    elif command -v ntpdate &> /dev/null; then
        # 兼容ntpdate
        /usr/sbin/ntpdate -u pool.ntp.org
        # 添加定时同步任务
        CRON_SERVICE="crond"
        if ! systemctl is-active --quiet crond &> /dev/null; then
            CRON_SERVICE="cron"
        fi
        if ! grep -q "ntpdate" /var/spool/cron/root 2>/dev/null; then
            echo '*/30 * * * * /usr/sbin/ntpdate -u pool.ntp.org' >> /var/spool/cron/root
            systemctl restart $CRON_SERVICE &> /dev/null
        fi
        echo "已配置ntpdate时间同步"
    elif command -v timedatectl &> /dev/null; then
        # 使用systemd-timesyncd
        timedatectl set-ntp true &> /dev/null
        echo "已启用systemd-timesyncd时间同步"
    fi
}

# Redis安装函数（优先包管理器，失败则编译安装）
function redis_ins {
    echo "正在安装Redis服务..."
    # 适配不同系统的Redis包名
    case $OS in
        centos|rhel|rocky|alma|ol|fedora)
            REDIS_PKG="redis redis-server"
            ;;
        debian|ubuntu|linuxmint|popos)
            REDIS_PKG="redis-server"
            ;;
        arch|manjaro|endeavouros|opensuse*|sles)
            REDIS_PKG="redis"
            ;;
    esac

    # 优先包管理器安装
    if pkg_install $REDIS_PKG; then
        echo "Redis 包管理器安装成功"
    else
        echo "包管理器安装失败，开始源码编译安装Redis..."
        cd $cud
        wget -c http://dl.wdlinux.cn/files/redis/redis-5.0.9.tar.gz || err "Redis 源码下载失败"
        tar zxvf redis-5.0.9.tar.gz || err "Redis 源码解压失败"
        cd redis-5.0.9
        # 编译依赖组件
        cd deps
        cd jemalloc/
        ./configure || err "jemalloc 配置失败"
        make -j$(nproc) || err "jemalloc 编译失败"
        make install || err "jemalloc 安装失败"
        ldconfig
        cd ..
        cd hiredis/
        make -j$(nproc) || err "hiredis 编译失败"
        make install || err "hiredis 安装失败"
        cd ..
        cd lua/
        make linux -j$(nproc) || err "lua 编译失败"
        make install || err "lua 安装失败"
        cd ../..
        # 编译Redis主程序
        make -j$(nproc) || err "Redis 主程序编译失败"
        make install || err "Redis 主程序安装失败"
        echo y | ./utils/install_server.sh || err "Redis 服务配置失败"
        cd $cud
    fi

    # 启动Redis并设置开机自启
    systemctl daemon-reload
    systemctl enable --now redis || systemctl enable --now redis-server || err "Redis 服务启动失败"
}

# Supervisor安装函数（优先包管理器，失败则编译安装）
function supervisor_ins {
    echo "正在安装Supervisor进程管理服务..."
    SUPERVISOR_PKG="supervisor"

    # 优先包管理器安装
    if pkg_install $SUPERVISOR_PKG; then
        echo "Supervisor 包管理器安装成功"
        # 适配不同系统的配置路径
        if [ -d /etc/supervisor/conf.d ]; then
            # Debian/Ubuntu 系列默认路径
            export SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"
            export SUPERVISOR_CONF_FILE="/etc/supervisor/supervisord.conf"
        elif [ -d /etc/supervisord.d ]; then
            # RHEL/CentOS 系列默认路径
            export SUPERVISOR_CONF_DIR="/etc/supervisord.d"
            export SUPERVISOR_CONF_FILE="/etc/supervisord.conf"
        else
            # 兜底创建标准配置
            export SUPERVISOR_CONF_DIR="/etc/supervisord.conf.d"
            export SUPERVISOR_CONF_FILE="/etc/supervisord.conf"
            echo_supervisord_conf > $SUPERVISOR_CONF_FILE
            mkdir -p $SUPERVISOR_CONF_DIR
            if ! grep -q "\[include\]" $SUPERVISOR_CONF_FILE; then
                echo '[include]' >> $SUPERVISOR_CONF_FILE
                echo "files=${SUPERVISOR_CONF_DIR}/*.conf" >> $SUPERVISOR_CONF_FILE
            fi
        fi
    else
        echo "包管理器安装失败，开始源码编译安装Supervisor..."
        cd $cud
        wget -c http://dl.wdlinux.cn/files/other/supervisor-4.2.2.tar.gz || err "Supervisor 源码下载失败"
        tar zxvf supervisor-4.2.2.tar.gz || err "Supervisor 源码解压失败"
        cd supervisor-4.2.2
        python setup.py install || err "Supervisor 安装失败"
        # 创建标准配置
        export SUPERVISOR_CONF_FILE="/etc/supervisord.conf"
        export SUPERVISOR_CONF_DIR="/etc/supervisord.conf.d"
        echo_supervisord_conf > $SUPERVISOR_CONF_FILE
        mkdir -p $SUPERVISOR_CONF_DIR
        if ! grep -q "\[include\]" $SUPERVISOR_CONF_FILE; then
            echo '[include]' >> $SUPERVISOR_CONF_FILE
            echo "files=${SUPERVISOR_CONF_DIR}/*.conf" >> $SUPERVISOR_CONF_FILE
        fi
        cd $cud
    fi

    # 配置systemd服务（若不存在）
    if [ ! -f /usr/lib/systemd/system/supervisord.service ]; then
        wget -O /usr/lib/systemd/system/supervisord.service http://dl.wdlinux.cn/files/wddns/centos-systemd-etcs || err "Supervisor 服务文件下载失败"
    fi

    # 启动Supervisor并设置开机自启
    systemctl daemon-reload
    supervisord -c $SUPERVISOR_CONF_FILE &> /dev/null
    systemctl enable --now supervisord || err "Supervisor 服务启动失败"
}

# libmaxminddb 安装函数
function libmaxminddb_ins {
    echo "正在安装libmaxminddb..."
    cd $cud
    wget http://dl.wdlinux.cn/files/wdcdn/libmaxminddb-1.6.0.tar.gz -c || err "libmaxminddb 源码下载失败"
    tar zxvf libmaxminddb-1.6.0.tar.gz || err "libmaxminddb 源码解压失败"
    cd libmaxminddb-1.6.0
    ./configure --prefix=/usr/local/libmaxminddb || err "libmaxminddb 配置失败"
    make -j$(nproc) || err "libmaxminddb 编译失败"
    make install || err "libmaxminddb 安装失败"
    # 配置动态链接库
    echo "/usr/local/libmaxminddb/lib/" > /etc/ld.so.conf.d/libmaxminddb.conf
    ldconfig
    cd $cud
}

# GeoIP 数据库安装函数
function geoip_ins() {
    echo "正在安装GeoIP2国家数据库..."
    [ ! -d /usr/share/GeoIP ] && mkdir -p /usr/share/GeoIP
    cd /usr/share/GeoIP
    wget http://dl.wdlinux.cn/files/wdcdn/GeoLite2-Country.mmdb.tar.gz -c || err "GeoIP2 数据库下载失败"
    tar zxvf GeoLite2-Country.mmdb.tar.gz || err "GeoIP2 数据库解压失败"
    rm -f GeoLite2-Country.mmdb.tar.gz
    cd $cud
}

# OpenResty 安装函数
function openresty_ins {
    echo "正在安装OpenResty服务..."
    cd $cud
    # 下载geoip2模块
    wget http://dl.wdlinux.cn/files/wdcdn/ngx_http_geoip2_module-3.3.tar.gz -c || err "ngx_http_geoip2 模块下载失败"
    tar zxvf ngx_http_geoip2_module-3.3.tar.gz || err "ngx_http_geoip2 模块解压失败"
    # 下载OpenResty源码
    wget http://dl.wdlinux.cn/files/wdcdn/openresty-1.19.9.1.tar.gz -c || err "OpenResty 源码下载失败"
    tar zxvf openresty-1.19.9.1.tar.gz || err "OpenResty 源码解压失败"
    # 编译安装
    cd openresty-1.19.9.1
    ./configure --prefix=/usr/local/openresty \
     --with-cc-opt='-I/usr/local/libmaxminddb/include' \
     --with-ld-opt='-Wl,-rpath,/usr/local/openresty/luajit/lib -L/usr/local/libmaxminddb/lib/' \
     --with-pcre-jit --with-http_stub_status_module \
     --with-http_realip_module --with-http_gzip_static_module --with-http_gunzip_module \
     --with-http_sub_module --with-threads --with-http_v2_module --with-pcre --with-stream=dynamic \
     --add-module=../ngx_http_geoip2_module-3.3 --with-http_slice_module || err "OpenResty 配置失败"
    # 兼容gmake/make
    gmake -j$(nproc) || make -j$(nproc) || err "OpenResty 编译失败"
    gmake install || make install || err "OpenResty 安装失败"
    # 创建必要目录与默认页面
    mkdir -p /data/cache
    mkdir -p /usr/local/openresty/nginx/conf/vhost
    mkdir -p /usr/local/openresty/nginx/conf/stream
    mkdir -p /usr/local/openresty/nginx/conf/cert
    mkdir -p /usr/local/openresty/nginx/conf/html
    echo '<html><head><meta http-equiv="content-type" content="text/html;charset=utf-8"></head><body>请使用域名地址访问</body></html>' > /usr/local/openresty/nginx/html/index.html
    cd $cud
}

# Filebeat 安装函数
function filebeat_ins {
    echo "正在安装Filebeat日志采集服务..."
    # 优先包管理器安装
    if pkg_install filebeat; then
        echo "Filebeat 包管理器安装成功"
    else
        echo "包管理器安装失败，开始手动安装Filebeat..."
        cd $cud
        # 适配RPM系列系统
        if command -v rpm &> /dev/null; then
            wget http://dl.wdlinux.cn/files/app/filebeat-7.15.2-x86_64.rpm -c || err "Filebeat RPM包下载失败"
            rpm -ivh filebeat-7.15.2-x86_64.rpm || err "Filebeat RPM安装失败"
        # 适配DEB系列系统
        elif command -v dpkg &> /dev/null; then
            wget https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-7.15.2-amd64.deb -c || err "Filebeat DEB包下载失败"
            dpkg -i filebeat-7.15.2-amd64.deb || err "Filebeat DEB安装失败"
        else
            echo "警告：不支持的包格式，跳过Filebeat安装"
        fi
    fi
    cd $cud
}

# 防火墙规则配置函数
function firewall_config {
    echo "正在配置防火墙端口规则..."
    # 放行端口：8003(节点管理)、80(HTTP)、443(HTTPS)
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        # UFW 防火墙（Debian/Ubuntu 系列默认）
        ufw allow 8003/tcp
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw reload
        echo "UFW 防火墙规则配置完成"
    elif command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        # Firewalld 防火墙（RHEL/CentOS 系列默认）
        firewall-cmd --permanent --zone=public --add-port=8003/tcp
        firewall-cmd --permanent --zone=public --add-port=80/tcp
        firewall-cmd --permanent --zone=public --add-port=443/tcp
        firewall-cmd --reload
        echo "Firewalld 防火墙规则配置完成"
    elif command -v iptables &> /dev/null; then
        # Iptables 兜底方案
        iptables -I INPUT -p tcp --dport 8003 -j ACCEPT
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT
        # 保存规则
        if command -v iptables-save &> /dev/null; then
            iptables-save > /etc/iptables.rules
            # 开机自动加载规则
            echo 'pre-up iptables-restore < /etc/iptables.rules' >> /etc/network/interfaces 2>/dev/null
        fi
        echo "Iptables 防火墙规则配置完成"
    else
        echo "警告：未识别到可用的防火墙，需手动放行8003、80、443端口"
    fi
}

##############################
# 主安装流程
##############################

# 1. 检查root权限
if [ $(id -u) != 0 ]; then
    err "请使用root用户执行此安装脚本，可通过 sudo -i 切换至root"
fi

# 2. 检查是否已安装，避免重复安装
if [ -d /opt/node ];then
	err "wdCDN Node 已安装，请勿重复执行"
fi
if [ -d /opt/cdns ];then
	err "wdCDN 主控端与节点端不能安装在同一台服务器"
fi
if [ -d /opt/wddns ];then
    err "wdCDN 与 wdDNS 不能安装在同一台服务器"
fi

# 3. 初始化全局变量
export cud=$(pwd)
export dl_url="http://dl.wdlinux.cn/"

# 4. 系统检测与基础环境配置
detect_os
install_base_deps
time_sync

# 5. 核心组件安装
redis_ins
supervisor_ins

# 6. 关闭systemd-resolved（避免53端口冲突）
ps ax | grep -v "grep" | grep -q "systemd-resolved" && systemctl stop systemd-resolved && systemctl disable systemd-resolved &> /dev/null

# 7. 反向代理与安全组件安装
libmaxminddb_ins
geoip_ins
openresty_ins
filebeat_ins

# 8. 下载并安装wdCDN Node主程序
echo "正在下载wdCDN Node主程序..."
cd /opt
# 检测系统位数与架构
export bit=`getconf LONG_BIT`
export ARCH=$(uname -m)
if [[ $ARCH != "x86_64" && $ARCH != "i386" && $ARCH != "i686" ]]; then
    err "wdCDN Node 仅支持x86/x86_64架构，当前架构：$ARCH"
fi
filename=node_linux_${bit}.tar.gz
wget -c ${dl_url}files/wdcdn/${filename} || err "wdCDN Node 主程序下载失败，请检查网络连接"
tar zxvf ${filename} || err "wdCDN Node 主程序解压失败"
rm -f ${filename}
mkdir -p /opt/node/logs

# 9. 配置节点服务
echo "正在配置wdCDN Node服务..."
# 配置Supervisor节点服务
if [ -n "$SUPERVISOR_CONF_DIR" ]; then
    mv node/etc/node_supervisor.conf ${SUPERVISOR_CONF_DIR}/node.conf
else
    # 兜底处理
    if [ -d /etc/supervisord.conf.d ];then
        mv node/etc/node_supervisor.conf /etc/supervisord.conf.d/node.conf
    elif [ -d /etc/supervisor/conf.d ];then
        mv node/etc/node_supervisor.conf /etc/supervisor/conf.d/node.conf
    else
        mv node/etc/node_supervisor.conf /etc/supervisord.d/node.ini
    fi
fi

# 配置Nginx服务
mv node/etc/nginx.service /usr/lib/systemd/system/
chmod 755 /opt/node/node_linux_amd64

# 适配32位系统
if [ $bit == "32" ];then
    if [ -f ${SUPERVISOR_CONF_DIR}/node.conf ];then
        sed -i 's/64/32/' ${SUPERVISOR_CONF_DIR}/node.conf
    else
        find /etc -name "node.conf" -o -name "node.ini" | xargs sed -i 's/64/32/' 2>/dev/null
    fi
fi

# 10. 重载服务并启动
echo "正在启动wdCDN Node相关服务..."
supervisorctl reload
systemctl daemon-reload
systemctl enable nginx.service
systemctl start nginx || err "Nginx 服务启动失败"

# 11. 防火墙配置
firewall_config

# 12. 安装完成与清理
clear
finsh
cd $cud
rm -f install_node.sh

exit 0
