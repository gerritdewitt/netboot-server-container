#!/bin/bash

#  build-script.sh
#  NetBoot Server Container
#  Script for for creating an installable package root "container"
#  for hosting Apple NetBoot services.

# Written by Gerrit DeWitt (gdewitt@gsu.edu)
# gdewitt@gsu.edu, 2016-07-06, 2016-08-11, 2016-10-25.
# Copyright Georgia State University.
# This script uses publicly-documented methods known to those skilled in the art.
# References: See top level Read Me.

# MARK: VARIABLES

# Variables for package:
declare -x THIS_DIR=$(dirname "$0")
declare -x PACKAGE_ROOT_DIR="$THIS_DIR/netboot-server-container"
declare -x PACKAGE_TARBALL=""
declare -x STAGING_DIR="$THIS_DIR/staging"
declare -x PACKAGE_VERSION=""

# Paths:
# scripts and logs:
declare -x INIT_SCRIPT_TEMPLATE_PATH="$THIS_DIR/init-script-template.sh"
declare -x INIT_SCRIPT_PATH="$PACKAGE_ROOT_DIR/init-script.sh"
declare -x BUILD_LOG_PATH="$PACKAGE_ROOT_DIR/build.log"
# pypy:
declare -x PYPY_STAGING_DIR="$STAGING_DIR/src-pypy"
declare -x PYPY_VENV_BIN="$PYPY_STAGING_DIR/bin/virtualenv-pypy"
# nginx:
declare -x NGINX_STAGING_DIR="$STAGING_DIR/expanded-nginx-rpm"
declare -x NGINX_INSTALLED_DIR="$PACKAGE_ROOT_DIR/nginx"
declare -x NGINX_SITE_CONF_FILE_TEMPLATE_SRC_PATH="$THIS_DIR/nginx-site-default.template"
declare -x NGINX_SITE_CONF_FILE_TEMPLATE_DEST_PATH="$NGINX_INSTALLED_DIR/etc/nginx/conf.d/nginx-site-default.template"
# bsdpy:
declare -x BSDPY_STAGING_DIR="$STAGING_DIR/src-bsdpy"
declare -x BSDPY_VENV_DIR="$PACKAGE_ROOT_DIR/bsdpy_virtualenv"
declare -x BSDPY_CODE_DIR="$BSDPY_VENV_DIR/bsdpy"
declare -x BSDPY_PATCHES_PATH="$THIS_DIR/bsdpy_patches.patch"
# ptftpd:
declare -x PTFTPD_STAGING_DIR="$STAGING_DIR/src-ptftpd"
declare -x PTFTPD_VENV_DIR="$PACKAGE_ROOT_DIR/ptftpd_virtualenv"
declare -x PTFTPD_CODE_DIR="$PTFTPD_VENV_DIR/ptftpd"

# URLs:
declare -x PYPY_PAGE_URL="https://github.com/squeaky-pl/portable-pypy#portable-pypy-distribution-for-linux"
declare -x PYPY_HREF_LABEL="PyPy\s\d*.*\sx86_64" # Example: PyPy 5.3.3 x86_64
declare -x BSDPY_GIT_URL="https://github.com/bruienne/bsdpy.git"
declare -x PTFTPD_GIT_URL="https://github.com/mpetazzoni/ptftpd.git"
declare -x NGINX_WEB_DIR_URL="http://nginx.org/packages/rhel/6/x86_64/RPMS/"

# Dependencies:
declare -a BSDPY_DEPENDENCIES=("docopt" "pydhcplib")
declare -a PTFTPD_DEPENDENCIES=("netifaces")

# MARK: pre_cleanup()
# Sets up environment.
function pre_cleanup(){
    if [ -d "$STAGING_DIR" ]; then
        rm -fr "$STAGING_DIR" && echo "Removed $STAGING_DIR."
    fi
    if [ -d "$PACKAGE_ROOT_DIR" ]; then
        rm -fr "$PACKAGE_ROOT_DIR" && echo "Removed $PACKAGE_ROOT_DIR."
    fi
    mkdir -p "$STAGING_DIR" && echo "Created $STAGING_DIR."
    mkdir -p "$PACKAGE_ROOT_DIR" && echo "Created $PACKAGE_ROOT_DIR."
    touch "$BUILD_LOG_PATH"
    log_and_print "Build started: $(date)"
    log_and_print "Build version: $PACKAGE_VERSION"
}

# MARK: gather_info()
function gather_info(){
    echo "Enter a version number for this build (for example YYYY.MM like 2016.07):"
    read PACKAGE_VERSION
    PACKAGE_TARBALL="$THIS_DIR/netboot-server-container-$PACKAGE_VERSION.tgz"
}

# MARK: write_init_script()
function write_init_script(){
    BSDPY_VENV_DIR_BASENAME="$(basename "$BSDPY_VENV_DIR")"
    PTFTPD_VENV_DIR_BASENAME="$(basename "$PTFTPD_VENV_DIR")"
    NGINX_INSTALLED_DIR_BASENAME="$(basename "$NGINX_INSTALLED_DIR")"
    init_script_template_contents="$(cat $INIT_SCRIPT_TEMPLATE_PATH)"
    init_script_contents="$(echo "$init_script_template_contents" | sed "s|__%BSDPY_VENV_DIR_BASENAME%__|$BSDPY_VENV_DIR_BASENAME|g" | sed "s|__%PTFTPD_VENV_DIR_BASENAME%__|$PTFTPD_VENV_DIR_BASENAME|g" | sed "s|__%NGINX_INSTALLED_DIR_BASENAME%__|$NGINX_INSTALLED_DIR_BASENAME|")"
    echo "$init_script_contents" > "$INIT_SCRIPT_PATH"
    log_and_print "Created init script ($INIT_SCRIPT_PATH) from template."
    chmod 0755 "$INIT_SCRIPT_PATH"
    log_and_print "Set permissions on init script."
}

# MARK: get_value_at_position()
function get_value_at_position(){
    IFS='.' eval 'version_array=($2)'
    if [ "${version_array[$1]}" == "" ]; then
        echo 0
    else
        echo "${version_array[$1]}"
    fi
}

# MARK: download_and_extract_nginx()
function download_and_extract_nginx(){
    html_response="$(curl "$NGINX_WEB_DIR_URL")"
    filtered_html="$(echo "$html_response" | grep "a href" | grep "nginx-1")"
    download_url_basenames_text="$(echo "$filtered_html" | sed "s|<a href=\"||g" | sed "s|</*[\s*A-Za-z\s*]*>||g" | awk -F'\"' '{print $1}')"
    # array of download URLs:
    IFS='
' eval 'download_url_basenames=($download_url_basenames_text)'
    # array of version strings with index parity to array of download URLs:
    i=0
    declare -a nginx_versions
    for url in "${download_url_basenames[@]}"; do
        version_str="$(echo "$url" | awk -F'-' '{print $2}')"
        nginx_versions[$i]=$version_str
        let i++
    done
    echo "debug: nginx versions available: ${nginx_versions[@]}"
    # determine the greatest version:
    declare -a greatest_version=()
    i=0
    while true; do
        len_nginx_versions="${#nginx_versions[@]}"
        # break when narrowed down to one version (and url):
        if [ "$len_nginx_versions" == "1" ]; then
            break
        fi
        if [ "${greatest_version[$i]}" == "" ]; then
            greatest_version[$i]=0
        fi
        # find greatest value for given place value:
        for version_str in "${nginx_versions[@]}"; do
            place_value_of_version="$(get_value_at_position $i $version_str)"
            if [ "$place_value_of_version" -gt "${greatest_version[$i]}" ]; then
                greatest_version[$i]=$place_value_of_version
            fi
        done
        # pop version strings that are less than the place value being considered:
        ii=0
        while [ "$ii" -lt "$len_nginx_versions" ]; do
            echo "debug: inspecting nginx version str at index $ii"
            version_str="${nginx_versions[$ii]}"
            echo "debug: nginx version str is $version_str"
            place_value_of_version="$(get_value_at_position $i $version_str)"
            echo "debug: considering place value in str at index $i; value is $place_value_of_version"
            if [ "$place_value_of_version" -lt "${greatest_version[$i]}" ]; then
                unset 'nginx_versions[$ii]'
                unset 'download_url_basenames[$ii]'
            fi
            let ii++
        done
        # increment place value:
        let i++
    done
    # have version and url, report:
    file_basename=${download_url_basenames[@]}
    download_url="$NGINX_WEB_DIR_URL/$file_basename"
    log_and_print "Current version URL appears to be: ${nginx_versions[@]}"
    log_and_print "Download URL appears to be: $download_url"
    log_and_print "Downloading to staging dir as: $file_basename"
    # download:
    curl -L "$download_url" > "$STAGING_DIR/$file_basename"
    if [ ! -f "$STAGING_DIR/$file_basename" ]; then
        log_and_print "ERROR: Failed to download nginx rpm!"
        exit 1
    fi
    log_and_print "Done with download."
    # extract:
    log_and_print "Extracting: $file_basename"
    mkdir -p "$NGINX_STAGING_DIR"
    old_pwd="$(pwd)"
    cd "$NGINX_STAGING_DIR"
    rpm2cpio "../$file_basename" | cpio -imdv
    if [ "$?" != "0" ]; then
        log_and_print "ERROR: Failed extract nginx!"
        exit 1
    fi
    cd "$old_pwd"
    mv "$NGINX_STAGING_DIR" "$NGINX_INSTALLED_DIR"
    log_and_print "Extracted nginx to: $NGINX_INSTALLED_DIR"
    cp "$NGINX_SITE_CONF_FILE_TEMPLATE_SRC_PATH" "$NGINX_SITE_CONF_FILE_TEMPLATE_DEST_PATH" && log_and_print "Copied nginx conf template to: $NGINX_SITE_CONF_FILE_TEMPLATE_DEST_PATH"
}

# MARK: download_and_extract_pypy()
function download_and_extract_pypy(){
    download_page_html="$(curl "$PYPY_PAGE_URL")"
    filtered_html="$(echo "$download_page_html" | grep "a href" | grep "$PYPY_HREF_LABEL")"
    download_url="$(echo "$filtered_html" | sed "s|<a href=\"||g" | sed "s|</*[\s*A-Za-z\s*]*>||g" | awk -F'\"' '{print $1}')"
    log_and_print "Download URL appears to be: $download_url"
    file_basename="$(echo "$download_url" | awk -F'/' '{print $NF}')"
    log_and_print "Downloading to staging dir as: $file_basename"
    curl -L "$download_url" > "$STAGING_DIR/$file_basename"
    if [ ! -f "$STAGING_DIR/$file_basename" ]; then
        log_and_print "ERROR: Failed to download pypy!"
        exit 1
    fi
    log_and_print "Done with download."
    log_and_print "Extracting: $file_basename"
    mkdir -p "$PYPY_STAGING_DIR"
    tar -xv -C "$PYPY_STAGING_DIR" -f "$STAGING_DIR/$file_basename"
    if [ "$?" != "0" ]; then
        log_and_print "ERROR: Failed extract pypy!"
        exit 1
    fi
    mv "$PYPY_STAGING_DIR"/*/* "$PYPY_STAGING_DIR"
    log_and_print "Extracted pypy material to: $PYPY_STAGING_DIR"
}

# MARK: git_clone()
function git_clone(){
    item_name="$1"
    git_url="$2"
    staging_dir_path="$3"
    log_and_print "Given git repo for $item_name: $git_url"
    log_and_print "Cloning to: $staging_dir_path"
    git clone "$git_url" "$staging_dir_path"
    if [ ! -d "$staging_dir_path" ]; then
        log_and_print "ERROR: Failed to clone $item_name!"
        exit 1
    fi
    log_and_print "Done with clone."
}

# MARK: create_venv()
function create_venv(){
    item_name="$1"
    venv_tmp_dir_path="$STAGING_DIR/tmp-venv"
    venv_dir_path="$2"
    staging_dir_path="$3"
    code_dir_path="$4"
    declare -a dependencies_array=("${!5}")
    log_and_print "Creating Python venv for $item_name: $venv_dir_path"
    "$PYPY_VENV_BIN" --system-site-packages --always-copy "$venv_dir_path"
    if [ "$?" != "0" ]; then
        log_and_print "ERROR: Failed to create Python venv for $item_name!"
        exit 1
    fi
    # Get rid of symlinks in venvs; yes, despite --always-copy:
    mv "$venv_dir_path" "$venv_tmp_dir_path"
    rsync -urL "$venv_tmp_dir_path"/ "$venv_dir_path"
    rm -fr "$venv_tmp_dir_path"
    # Copy libraries that venv omitted.  Crudely:
    rm -fr "$venv_dir_path/lib_pypy"
    cp -R "$PYPY_STAGING_DIR/lib_pypy" "$venv_dir_path/lib_pypy"
    rm -fr "$venv_dir_path/lib-python"
    cp -R "$PYPY_STAGING_DIR/lib-python" "$venv_dir_path/lib-python"
    log_and_print "Python venv for $item_name created.  Activating..."
    source "$venv_dir_path"/bin/activate && log_and_print "Python venv for $item_name activated."
    log_and_print "Installing dependencies..."
    for d in "${dependencies_array[@]}"; do
        log_and_print "Installing $d..."
        "$venv_dir_path"/bin/pip install "$d"
        if [ "$?" != "0" ]; then
            log_and_print "ERROR: Failed to install $d!"
            exit 1
        fi
        log_and_print "Installed $d."
    done
    deactivate && log_and_print "Deactivated venv." # exit venv
    log_and_print "Created Python venv for $item_name with dependencies."
    log_and_print "Moving $item_name code from $staging_dir_path to venv..."
    mv "$staging_dir_path" "$code_dir_path"
    log_and_print "Done with venv for $item_name."
}

# MARK: patch_file()
function patch_file(){
    item_path="$1"
    patches_path="$2"
    patch "$item_path" "$patches_path"
    if [ "$?" != "0" ]; then
        log_and_print "ERROR: Failed to patch $item_path!"
        exit 1
    fi
    log_and_print "Patched $item_path."
}

# MARK: create_tarball()
function create_tarball(){
    tar -cvf "$PACKAGE_TARBALL" "$PACKAGE_ROOT_DIR"
    if [ "$?" != "0" ]; then
        log_and_print "ERROR: Failed to generate tarball: $PACKAGE_TARBALL"
        exit 1
    fi
    log_and_print "Created deployable tarball: $PACKAGE_TARBALL."
}

# MARK: log_and_print()
function log_and_print(){
    echo "    $1"
    if [ -f "$BUILD_LOG_PATH" ]; then
        echo "    $1" >> "$BUILD_LOG_PATH"
    fi
}

# MARK: log_and_print_header()
function log_and_print_header(){
    echo "===$1==="
    if [ -f "$BUILD_LOG_PATH" ]; then
        echo "===$1===" >> "$BUILD_LOG_PATH"
    fi
}

# MARK: main()
gather_info
pre_cleanup
log_and_print_header "CREATING INIT SCRIPT"
write_init_script
log_and_print_header "DOWNLOADING PYPY"
download_and_extract_pypy
log_and_print_header "DOWNLOADING NGINX"
download_and_extract_nginx
log_and_print_header "DOWNLOADING BSDPY"
git_clone "bsdpy" "$BSDPY_GIT_URL" "$BSDPY_STAGING_DIR"
log_and_print_header "DOWNLOADING PTFTPD"
git_clone "ptftpd" "$PTFTPD_GIT_URL" "$PTFTPD_STAGING_DIR"
log_and_print_header "CREATING VENV FOR BSDPY"
create_venv "bsdpy" "$BSDPY_VENV_DIR" "$BSDPY_STAGING_DIR" "$BSDPY_CODE_DIR" BSDPY_DEPENDENCIES[@]
log_and_print_header "PATCHING BSDPY"
patch_file "$BSDPY_VENV_DIR/bsdpy/bsdpserver.py" "$BSDPY_PATCHES_PATH"
log_and_print_header "CREATING VENV FOR PTFTPD"
create_venv "ptftpd" "$PTFTPD_VENV_DIR" "$PTFTPD_STAGING_DIR" "$PTFTPD_CODE_DIR" PTFTPD_DEPENDENCIES[@]
log_and_print_header "VENV PATH FIXES FOR PTFTPD"
cp -R "$PTFTPD_CODE_DIR/ptftplib" "$PTFTPD_VENV_DIR/site-packages/ptftplib"
log_and_print_header "GENERATING ARCHIVE"
create_tarball