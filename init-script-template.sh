#!/bin/bash

# BSDPY-Server-Container Init Script.
# gdewitt@gsu.edu, 2015-06-15, 2015-06-15, 2016-03-04, 2016-03-14, 2016-04-25, 2016-07-06, 2016-08-02, 2016-08-09.
# to do: modify this script to work on distros besides RHEL

# References: See top level Read Me.
# chkconfig: 345 95 05

# Globals:
declare -x APP_NAME="NetBootServerContainer"
declare -x APP_DISPLAY_NAME="NetBoot Server for macOS and OS X"
# System paths:
declare -x INIT_SCRIPTS_DIR="/etc/init.d"
declare -x SETSEBOOL="/usr/sbin/setsebool"

# Container:
declare -x THIS_SCRIPT=$(readlink -f "$0")
declare -x CONTAINER_DIR=$(dirname "$THIS_SCRIPT")
declare -x CONTAINER_CONFIG_FILE="$CONTAINER_DIR/container.conf"
declare -x INIT_SCRIPT_SYMLINK="$INIT_SCRIPTS_DIR/$APP_NAME"

declare -x SERVER_NET_IFACE=""
declare -x NETBOOT_SP=""
declare -x SERVER_HOSTNAME=""
declare -i CAN_START=0

# BSDPy:
declare -x PYTHON_FILE_BSDPY=""
declare -a CMD_BSDPY=()
declare -x PIDFILE_BSDPY=""
# pTFTPd:
declare -x PYTHON_FILE_PTFTPD=""
declare -a CMD_PTFTPD=()
declare -x PIDFILE_PTFTPD=""
# nginx:
declare -x NGINX_BIN=""
declare -x NGINX_MAIN_CONF_FILE=""
declare -x NGINX_SITE_CONF_FILE=""
declare -a CMD_NGINX_START=()
declare -a CMD_NGINX_STOP=()
# Arrays:
declare -a APP_FILES_ARRAY=()
declare -a APP_CMDS_ARRAY=()
declare -a APP_PIDFILES_ARRAY=()

# MARK: write_config()
function write_config() {
    # Gathers config data interactively and writes it to the container conf.
    echo "Enter path to the directory containing .NBI folders:"
    read NETBOOT_SP
    echo "What network interface will be used for bsdp and tftp?"
    read SERVER_NET_IFACE
    echo "
netboot_sp=$NETBOOT_SP
net_iface=$SERVER_NET_IFACE
" > "$CONTAINER_CONFIG_FILE"
}

# MARK: read_config()
function read_config() {
    # Reads values from container conf, sets variables, performs some tests.
    # Assume can start unless something is wrong:
    CAN_START=1
    # Source container config:
    source "$CONTAINER_CONFIG_FILE"
    read_container_config="$?"
    if [ "$read_container_config" != "0" ]; then
        CAN_START=0
        echo "--> Read config: ERROR: Could not source config from $CONTAINER_CONFIG_FILE."
    fi
    # Tests for NetBoot sharepoint:
    NETBOOT_SP="$netboot_sp"
    if [ "$NETBOOT_SP" ]; then
        echo "--> Read config: NetBoot sharepoint is $NETBOOT_SP"
    else
        CAN_START=0
        echo "--> Read config: ERROR: netboot_sp parameter empty!"
    fi
    if [ ! -d "$NETBOOT_SP" ]; then
        CAN_START=0
        echo "--> Read config: ERROR: Path not present: $$NETBOOT_SP"
    fi
    # Tests for network interface:
    SERVER_NET_IFACE="$net_iface"
    if [ "$SERVER_NET_IFACE" ]; then
        echo "--> Read config: BSDP interface is $SERVER_NET_IFACE"
    else
        CAN_START=0
        echo "--> Read config: ERROR: net_iface parameter empty!"
    fi
    # Hostname:
    SERVER_HOSTNAME=$(hostname) && echo "--> Read config: hostname is $SERVER_HOSTNAME"

    # BSDPy:
    PYTHON_FILE_BSDPY="$CONTAINER_DIR/__%BSDPY_VENV_DIR_BASENAME%__/bsdpy/bsdpserver.py"
    CMD_BSDPY=("$CONTAINER_DIR/__%BSDPY_VENV_DIR_BASENAME%__/bin/pypy" "$PYTHON_FILE_BSDPY" "-p" "$NETBOOT_SP" "-r" "http" "-i" "$SERVER_NET_IFACE") # core command
    PIDFILE_BSDPY="/var/run/$APP_NAME-bsdpy.pid"
    # pTFTPd:
    PYTHON_FILE_PTFTPD="$CONTAINER_DIR/__%PTFTPD_VENV_DIR_BASENAME%__/ptftpd/bin/ptftpd"
    CMD_PTFTPD=("$CONTAINER_DIR/__%PTFTPD_VENV_DIR_BASENAME%__/bin/pypy" "$PYTHON_FILE_PTFTPD" "-p" "69" "$SERVER_NET_IFACE" "$NETBOOT_SP") # core command
    PIDFILE_PTFTPD="/var/run/$APP_NAME-ptftpd.pid"
    # nginx:
    NGINX_BIN="$CONTAINER_DIR/__%NGINX_INSTALLED_DIR_BASENAME%__/usr/sbin/nginx"
    NGINX_MAIN_CONF_FILE="$CONTAINER_DIR/__%NGINX_INSTALLED_DIR_BASENAME%__/etc/nginx/nginx.conf"
    NGINX_SITE_CONF_FILE="$CONTAINER_DIR/__%NGINX_INSTALLED_DIR_BASENAME%__/etc/nginx/conf.d/default.conf"
    CMD_NGINX_START=("$NGINX_BIN" "-c" "$NGINX_MAIN_CONF_FILE") # start command
    CMD_NGINX_STOP=("$NGINX_BIN" "-s" "stop") # stop command
    # Arrays:
    APP_FILES_ARRAY=("$PYTHON_FILE_BSDPY" "$PYTHON_FILE_PTFTPD" "$NGINX_BIN" "$NGINX_MAIN_CONF_FILE" "$NGINX_SITE_CONF_FILE")
    APP_CMDS_ARRAY=("CMD_BSDPY" "CMD_PTFTPD" "CMD_NGINX_START")
    APP_PIDFILES_ARRAY=("$PIDFILE_BSDPY" "$PIDFILE_PTFTPD")

    # Check for APP_FILES_ARRAY:
    files_missing=0
    files_missing_str=""
    for file in ${APP_FILES_ARRAY[@]}; do
        if [ ! -f "$file" ];then
            files_missing_str+="
            $file missing."
            files_missing=1
        fi
    done
    if [ "$files_missing" == "1" ];then
        CAN_START=0
        echo "--> Read config: ERROR: Missing these files: $files_missing_str"
    fi

    # Check for pidfiles:
    pidfiles_present=0
    pidfiles_str=""
    for pidfile in ${APP_PIDFILES_ARRAY[@]}; do
        if [ -f "$pidfile" ];then
            pidfiles_str+="
            $pidfile exists."
            pidfiles_present=1
        fi
    done
    if [ "$pidfiles_present" == "1" ];then
        CAN_START=0
        echo "--> Read config: One or more pidfiles exist: $pidfiles_str"
    fi
}

# MARK: start()
function start() {
    echo "Reading config..."
    read_config
    if [ "$CAN_START" == "0" ]; then
        echo "Cannot start.  Refer to previous messages.
To reconfigure, run: $0 install"
        exit 1
    fi
    echo "Starting $APP_DISPLAY_NAME..."
    # Start bsdpy:
    echo "   Starting bsdpy..."
    "${CMD_BSDPY[@]}" &
    if [ "$?" == "0" ]; then
        echo $! > "$PIDFILE_BSDPY"
        echo "   Started: ${CMD_BSDPY[@]}"
    else
        echo "   ERROR: This failed to start: ${CMD_BSDPY[@]}"
    fi
    # Start pTFTPd:
    echo "   Starting pTFTPd..."
    "${CMD_PTFTPD[@]}" &
    if [ "$?" == "0" ]; then
        echo $! > "$PIDFILE_PTFTPD"
        echo "   Started: ${CMD_PTFTPD[@]}"
    else
        echo "   ERROR: This failed to start: ${CMD_PTFTPD[@]}"
    fi
    # Start nginx:
    echo "   Starting nginx..."
    "${CMD_NGINX_START[@]}" &
    if [ "$?" == "0" ]; then
        echo "   Started: ${CMD_NGINX_START[@]}"
    else
        echo "   ERROR: This failed to start: ${CMD_NGINX_START[@]}"
    fi
}

# MARK: stop()
function stop() {
    echo "Stopping $APP_DISPLAY_NAME..."
    echo "Reading config..."
    read_config
    # Loop through PID files:
    echo "   Killing processes by PID..."
    for pidfile in ${APP_PIDFILES_ARRAY[@]}; do
        if [ -f "$pidfile" ];then
            pid=$(cat "$pidfile")
            kill "$pid" && echo "   Killed process $pid."
            rm "$pidfile" && echo "   Removed $pidfile."
        fi
    done
    # Stop nginx:
    echo "   Stopping nginx..."
    "${CMD_NGINX_STOP[@]}"
    if [ "$?" == "0" ]; then
        echo "   Sent stop signal to nginx."
    else
        echo "   NOTICE: nginx doesn't appear to be running from $NGINX_BIN."
    fi
    echo "$APP_DISPLAY_NAME stopped."
}

# MARK: reload()
function reload() {
    echo "Reloading $APP_DISPLAY_NAME..."
    stop
    sleep 5
    start
    echo "$APP_DISPLAY_NAME reloaded."
}

# MARK: install()
function install() {
    echo "Installing $APP_DISPLAY_NAME..."
    if [ "$EUID" != "0" ]; then
        echo "ERROR: Must be root to install $APP_DISPLAY_NAME."
        exit 2
    fi

    # Write new config; request values interactively:
    write_config
    # Read config:
    read_config

    echo "   App display name: $APP_DISPLAY_NAME"
    echo "   Init script will be copied to: $INIT_SCRIPTS_DIR/$APP_NAME"
    echo "   Container path: $CONTAINER_DIR"

    # Make sure everything is stopped. Installs should be idempotent.
    echo "Calling stop()..."
    stop
    # Set permissions:
    echo "Copying and setting permissions..."
    chown -R root:root "$CONTAINER_DIR" && echo "   Set ownership for $CONTAINER_DIR."
    chmod -R 0770 "$CONTAINER_DIR" && echo "   Set permissions for $CONTAINER_DIR."
    # Create init script symlink:
    if [ -e "$INIT_SCRIPT_SYMLINK" ]; then
        rm "$INIT_SCRIPT_SYMLINK"
    fi
    ln -s "$THIS_SCRIPT" "$INIT_SCRIPT_SYMLINK" && echo "   Created symlink: $INIT_SCRIPT_SYMLINK."
    chown root:root "$INIT_SCRIPT_SYMLINK" && echo "   Set ownership for $INIT_SCRIPT_SYMLINK."
    # Set SELinux booleans for http:
    if [ -f "$SETSEBOOL" ]; then
        echo "Applying SELinux settings for http..."
        "$SETSEBOOL" -P httpd_can_network_connect true && echo "   httpd_can_network_connect is true"
        "$SETSEBOOL" -P httpd_use_nfs true && echo "   httpd_use_nfs is true"
    fi
    # Update nginx config with web root and hostname:
    echo "Updating nginx config ($NGINX_SITE_CONF_FILE):"
    echo "  - server name: $SERVER_HOSTNAME"
    echo "  - web root: $NETBOOT_SP"
    conf_contents="$(cat $NGINX_SITE_CONF_FILE)"
    new_conf_contents="$(echo "$conf_contents" | sed "s|__%PLACEHOLDER_NETBOOT_SP%__|$NETBOOT_SP|g" | sed "s|__%PLACEHOLDER_SERVER_HOSTNAME%__|$SERVER_HOSTNAME|g")"
    echo "$new_conf_contents" > "$NGINX_SITE_CONF_FILE"
    # Start:
    echo "Calling start()..."
    start
    # Set startup:
    echo "Running chkconfig..."
    /sbin/chkconfig --level 345 "$APP_NAME" on && echo "  App will run on system boot."

    echo "Finished installation."
}

# MARK: uninstall()
function uninstall() {
    echo "Removing $APP_DISPLAY_NAME..."
    if [ "$EUID" != "0" ]; then
        echo "ERROR: Must be root to remove $APP_DISPLAY_NAME."
        exit 2
    fi

    # Make sure everything is stopped.
    echo "Calling stop()..."
    stop

    # chkconfig:
    echo "Running chkconfig..."
    /sbin/chkconfig --level 345 "$APP_NAME" off && echo "  App will NOT run on system boot."

    # Delete init script symlink:
    if [ -e "$INIT_SCRIPT_SYMLINK" ]; then
        rm "$INIT_SCRIPT_SYMLINK" && echo "   Removed symlink: $INIT_SCRIPT_SYMLINK"
    fi

    echo "Uninstall complete."
}

# MARK: help()
function help() {
    echo "Usage: $0 [start|stop|reload|install|uninstall]"
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    reload)
        reload
        ;;
    restart)
        reload
        ;;
    install)
        install
        ;;
    uninstall)
        uninstall
        ;;
    *)
        help
        ;;
esac
exit 0