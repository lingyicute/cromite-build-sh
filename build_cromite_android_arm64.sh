#!/bin/bash

# ====================================================
# Cromite Android arm64 自动构建脚本
# 此脚本会自动构建Android arm64版本的Cromite浏览器，不使用Docker容器
# 假设补丁合并过程不会出现冲突
# ====================================================

set -e  # 任何命令失败立即退出
set -o pipefail  # 管道中任何命令失败都会导致管道失败

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # 无颜色

# 参数设置
SKIP_DEPS=false        # 跳过安装依赖
SKIP_CHECKOUT=false    # 跳过下载源码
CLEAN_BUILD=false      # 是否清理之前的构建
DISK_SAVER=true        # 启用磁盘节约模式
MAX_JOBS=""            # 构建时的并行任务数，默认根据CPU核心数自动设置

# 解析命令行参数
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-deps)
        SKIP_DEPS=true
        shift
        ;;
      --skip-checkout)
        SKIP_CHECKOUT=true
        shift
        ;;
      --clean)
        CLEAN_BUILD=true
        shift
        ;;
      --no-disk-saver)
        DISK_SAVER=false
        shift
        ;;
      --jobs=*)
        MAX_JOBS="${1#*=}"
        shift
        ;;
      --help)
        echo "用法: $0 [选项]"
        echo "选项:"
        echo "  --skip-deps      跳过安装依赖"
        echo "  --skip-checkout  跳过下载源码"
        echo "  --clean          清理之前的构建"
        echo "  --no-disk-saver  不使用磁盘节约模式"
        echo "  --jobs=N         设置构建时的并行任务数"
        echo "  --help           显示此帮助信息"
        exit 0
        ;;
      *)
        warn "未知参数: $1"
        shift
        ;;
    esac
  done
}

# 日志功能
log() {
  echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

info() {
  echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
  echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] 警告: $1${NC}"
}

error() {
  echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] 错误: $1${NC}"
  exit 1
}

# 记录开始时间
start_time=$(date +%s)

# 显示时间估计
show_time() {
  local end_time=$(date +%s)
  local elapsed=$((end_time - start_time))
  local hours=$((elapsed / 3600))
  local minutes=$(( (elapsed % 3600) / 60 ))
  local seconds=$((elapsed % 60))
  
  log "已用时间: ${hours}时 ${minutes}分 ${seconds}秒"
}

# 检查系统要求
check_requirements() {
  log "检查系统要求..."
  
  # 检查操作系统版本
  if [[ "$(lsb_release -rs)" != "20.04" ]]; then
    warn "推荐使用 Ubuntu 20.04，其他版本可能导致问题。"
  fi
  
  # 检查内存
  total_memory=$(free -g | awk '/^Mem:/{print $2}')
  if [[ "$total_memory" -lt 16 ]]; then
    warn "内存少于16GB (${total_memory}GB)，构建过程可能会失败或非常慢。"
  fi
  
  # 检查磁盘空间
  free_space=$(df -BG "$HOME" | awk 'NR==2 {print $4}' | sed 's/G//')
  if [[ "$free_space" -lt 100 ]]; then
    warn "可用磁盘空间少于100GB (${free_space}GB)，可能不足以完成构建。"
    if [[ "$free_space" -lt 50 ]]; then
      error "可用磁盘空间不足50GB，无法继续构建。请清理磁盘空间后重试。"
    fi
  fi

  # 设置并行任务数
  if [[ -z "$MAX_JOBS" ]]; then
    # 如果内存少于24GB，使用CPU核心数的一半，否则使用全部核心
    if [[ "$total_memory" -lt 24 ]]; then
      MAX_JOBS=$(($(nproc) / 2))
      if [[ "$MAX_JOBS" -lt 1 ]]; then MAX_JOBS=1; fi
      warn "内存较少，将并行任务数限制为 $MAX_JOBS"
    else
      MAX_JOBS=$(nproc)
    fi
  fi
  
  log "将使用 $MAX_JOBS 个并行任务进行构建"
}

# 安装依赖
install_dependencies() {
  if [[ "$SKIP_DEPS" == "true" ]]; then
    log "跳过依赖安装..."
    return 0
  fi

  log "安装构建依赖..."
  
  # 设置非交互式安装
  export DEBIAN_FRONTEND=noninteractive
  
  # 添加i386架构支持
  sudo dpkg --add-architecture i386 || error "无法添加i386架构"
  
  # 更新软件源
  sudo apt-get update || error "无法更新软件源"
  
  # 安装基础依赖
  sudo apt-get -y install sudo lsb-release bash wget apt-utils python3 python3-pip sed tzdata \
    build-essential lib32gcc-9-dev g++-multilib dos2unix wiggle git curl lsof \
    libgoogle-glog-dev libprotobuf17 libgrpc++1 parallel golang-go nano unzip \
    ccache || error "安装依赖失败"
    
  # 设置ccache
  if ! grep -q "CCACHE_DIR" ~/.bashrc; then
    echo 'export CCACHE_DIR=$HOME/.ccache' >> ~/.bashrc
    echo 'export USE_CCACHE=1' >> ~/.bashrc
  fi
  export CCACHE_DIR=$HOME/.ccache
  export USE_CCACHE=1
  mkdir -p $CCACHE_DIR
  ccache -M 20G  # 设置ccache最大缓存为20GB
  
  log "基础依赖安装完成。已配置ccache加速重复构建。"
}

# 准备工作目录
prepare_workspace() {
  log "准备工作目录..."
  
  # 创建工作目录
  mkdir -p ~/cromite_build
  cd ~/cromite_build || error "无法进入工作目录"
  
  # 创建用于存放编译输出的目录
  mkdir -p chromium/src/out/arm64
  
  # 设置环境变量
  export WORKSPACE=$HOME/cromite_build
  export PATH=$PATH:$WORKSPACE/depot_tools
  
  # 创建构建日志目录
  mkdir -p "$WORKSPACE/logs"
  
  log "工作目录准备完成: $WORKSPACE"
}

# 安装depot_tools
install_depot_tools() {
  log "安装depot_tools..."
  
  cd "$WORKSPACE" || error "无法进入工作目录"
  
  if [ ! -d depot_tools ]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git || error "无法克隆depot_tools"
  else
    log "depot_tools已存在，跳过下载。"
  fi
  
  # 设置环境变量
  export PATH=$PATH:$WORKSPACE/depot_tools
  export DEPOT_TOOLS_UPDATE=0
  
  log "depot_tools安装完成。"
}

# 获取Cromite仓库
get_cromite() {
  log "获取Cromite仓库..."
  
  cd "$WORKSPACE" || error "无法进入工作目录"
  
  if [ ! -d cromite ]; then
    # 使用--depth=1节省空间
    git clone --depth=1 https://github.com/uazo/cromite.git || error "无法克隆Cromite仓库"
  else
    log "Cromite仓库已存在，更新到最新版本..."
    cd cromite
    git fetch --depth=1
    git reset --hard origin/master
    cd ..
  fi
  
  export VERSION=$(cat cromite/build/RELEASE)
  log "Cromite版本: $VERSION"
  
  cd cromite || error "无法进入Cromite目录"
  export CROMITE_SHA=$(git rev-parse HEAD)
  log "Cromite SHA: $CROMITE_SHA"
  cd ..
}

# 安装Chromium构建依赖
install_chromium_deps() {
  if [[ "$SKIP_DEPS" == "true" ]]; then
    log "跳过Chromium依赖安装..."
    return 0
  fi

  log "安装Chromium构建依赖..."
  
  cd "$WORKSPACE" || error "无法进入工作目录"
  
  # 下载Chromium构建脚本
  if [[ ! -f install-build-deps.sh ]]; then
    wget https://raw.githubusercontent.com/chromium/chromium/$VERSION/build/install-build-deps.sh || error "无法下载install-build-deps.sh"
    wget https://raw.githubusercontent.com/chromium/chromium/$VERSION/build/install-build-deps.py || error "无法下载install-build-deps.py"
  
    # 修改安装脚本
    sed -i 's/snapcraft/wget/' install-build-deps.sh
    chmod +x ./install-build-deps.sh
    chmod +x ./install-build-deps.py
  fi
  
  # 安装Chromium基础依赖
  sudo DEBIAN_FRONTEND=noninteractive ./install-build-deps.sh --no-prompt --lib32 --no-chromeos-fonts || error "安装Chromium基础依赖失败"
  
  # 安装Android特定依赖
  sudo DEBIAN_FRONTEND=noninteractive ./install-build-deps.sh --android --no-prompt --no-chromeos-fonts || error "安装Android依赖失败"
  
  log "Chromium构建依赖安装完成。"
}

# 下载并设置Chromium源码
setup_chromium() {
  if [[ "$SKIP_CHECKOUT" == "true" && -d "$WORKSPACE/chromium/src/.git" ]]; then
    log "跳过Chromium源码检出..."
    return 0
  fi

  log "设置Chromium源码..."
  
  cd "$WORKSPACE" || error "无法进入工作目录"
  
  # 如果目录不存在，创建Chromium目录
  if [ ! -d chromium/src/.git ]; then
    log "Chromium源码目录不存在，创建并初始化..."
    mkdir -p ./chromium/src
    cd ./chromium/src
    
    # 设置Git仓库
    git init
    git remote add origin https://github.com/chromium/chromium.git
    
    # 获取指定版本，使用更小的深度节省空间
    log "下载Chromium版本 $VERSION，这可能需要一些时间..."
    git fetch --depth 1 origin +refs/tags/$VERSION:chromium_$VERSION || error "无法下载Chromium源码"
    git checkout $VERSION || error "无法切换到指定版本"
    VERSION_SHA=$(git rev-parse HEAD)
    log "Chromium SHA: $VERSION_SHA"
    
    # 创建.gclient配置文件
    cat >../.gclient <<EOF
solutions = [
  { "name"        : 'src',
    "url"         : 'https://github.com/chromium/chromium.git@$VERSION_SHA',
    "deps_file"   : 'DEPS',
    "managed"     : False,
    "custom_deps" : {
        "src/third_party/apache-windows-arm64": None,
        "src/third_party/updater/chrome_win_x86": None,
        "src/third_party/updater/chrome_win_x86_64": None,
        "src/third_party/updater/chromium_win_x86": None,
        "src/third_party/updater/chromium_win_x86_64": None,
        "src/third_party/gperf": None,
        "src/third_party/lighttpd": None,
        "src/third_party/lzma_sdk/bin/host_platform": None,
        "src/third_party/lzma_sdk/bin/win64": None,
        "src/third_party/perl": None,
        "src/tools/skia_goldctl/win": None,
        "src/third_party/screen-ai/windows_amd64": None,
        "src/third_party/screen-ai/windows_386": None,
        "src/third_party/cronet_android_mainline_clang/linux-amd64": None,
        "src/testing/libfuzzer/fuzzers/wasm_corpus": None,
    },
    "custom_hooks" : [
        { 'name': 'ciopfs_linux', 'pattern': '.', 'action': ['echo', 'ciopfs_linux hook override'] },
        { 'name': 'win_toolchain', 'pattern': '.', 'action': ['echo', 'win_toolchain hook override'] },
        { 'name': 'rc_win', 'pattern': '.', 'action': ['echo', 'rc_win hook override'] },
        { 'name': 'rc_linux', 'pattern': '.', 'action': ['echo', 'rc_linux hook override'] },
        { 'name': 'apache_win32', 'pattern': '.', 'action': ['echo', 'apache_win32 hook override'] },
    ],
    "custom_vars": {
       "checkout_android_prebuilts_build_tools": True,
       "checkout_telemetry_dependencies": False,
       "codesearch": 'Debug',
    },
  },
]
target_os=['android']
EOF
    
    # 配置git
    git submodule foreach git config -f ./.git/config submodule.\$name.ignore all
    git config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
    git config user.email "you@example.com"
    git config user.name "Your Name"
    
    # 同步代码 - 使用更少的历史记录和并行下载来节省空间和时间
    log "同步Chromium依赖，这可能需要一些时间..."
    if [ "$DISK_SAVER" = true ]; then
      # 使用最小化策略
      gclient sync -D --no-history --nohooks --shallow --with_branch_heads=false --with_tags=false || error "无法同步Chromium依赖"
    else
      gclient sync -D --no-history --nohooks || error "无法同步Chromium依赖"
    fi
    
    # 运行钩子
    log "运行钩子..."
    gclient runhooks || error "无法运行钩子"
    
    # 下载objdump
    log "下载objdump..."
    tools/clang/scripts/update.py --package=objdump || warn "下载objdump失败，但可能不影响构建"
    
    # 移除不必要的大文件
    log "移除不必要的大文件以节省空间..."
    rm -rf third_party/angle/third_party/VK-GL-CTS/
    
    cd "$WORKSPACE" || error "无法进入工作目录"
  else
    log "Chromium源码目录已存在，跳过下载。"
  fi
}

# 清理磁盘空间
clean_disk_space() {
  if [ "$DISK_SAVER" = true ]; then
    log "正在清理临时文件以节省磁盘空间..."
    
    cd "$WORKSPACE" || error "无法进入工作目录"
    
    # 清理构建过程中产生的临时文件
    find . -name "*.pyc" -delete
    find . -name "*.pyo" -delete
    find . -name "*.o" -delete
    
    # 清理git仓库
    cd "$WORKSPACE/chromium/src" || return 0
    git gc --aggressive --prune=all
    
    # 清理不需要的目录
    log "移除测试文件，测试资源和示例..."
    find . -path "*/test/*" -type d | xargs rm -rf || true
    find . -path "*/tests/*" -type d | xargs rm -rf || true
    find . -path "*/examples/*" -type d | xargs rm -rf || true
    find . -path "*/samples/*" -type d | xargs rm -rf || true
    
    cd "$WORKSPACE"
    log "清理完成。"
  fi
}

# 应用Cromite补丁
apply_cromite_patches() {
  log "应用Cromite补丁到Chromium源码..."
  
  cd "$WORKSPACE/chromium/src" || error "无法进入Chromium源码目录"
  
  log "移除子仓库的git信息..."
  
  # 移除v8子仓库的git信息
  if [ -d v8/.git ]; then
    rm -rf v8/.git 
    cp -r v8 v8bis
    git rm -rf v8 || true
    git submodule deinit -f v8 || true
    mv v8bis v8
    git add -f v8 >/dev/null
    git commit -m ":NOEXPORT: v8 repo" >/dev/null
  fi
  
  # 移除devtools-frontend子仓库的git信息
  if [ -d third_party/devtools-frontend/src/.git ]; then
    rm -rf third_party/devtools-frontend/src/.git 
    cp -r third_party/devtools-frontend third_party/devtools-frontend-bis
    git rm -rf third_party/devtools-frontend || true
    git submodule deinit -f third_party/devtools-frontend || true
    rm -rf third_party/devtools-frontend
    mv third_party/devtools-frontend-bis third_party/devtools-frontend
    git add -f third_party/devtools-frontend >/dev/null
    git commit -m ":NOEXPORT: third_party/devtools-frontend repo" >/dev/null
  fi
  
  # 移除skia子仓库的git信息
  if [ -d third_party/skia/.git ]; then
    rm -rf third_party/skia/.git 
    cp -r third_party/skia third_party/skia-bis
    git rm -rf third_party/skia || true
    git submodule deinit -f third_party/skia || true
    rm -rf third_party/skia
    mv third_party/skia-bis third_party/skia
    git add -f third_party/skia >/dev/null
    git commit -m ":NOEXPORT: third_party/skia repo" >/dev/null
  fi
  
  git prune
  
  log "开始应用补丁列表..."

  # 创建已应用补丁的标记文件
  PATCHES_APPLIED_MARKER="$WORKSPACE/.patches_applied"
  
  # 检查是否已经应用过补丁
  if [ -f "$PATCHES_APPLIED_MARKER" ]; then
    log "补丁似乎已经应用过，跳过应用步骤。"
    log "如果需要重新应用补丁，请删除 $PATCHES_APPLIED_MARKER 文件。"
    return 0
  fi
  
  # 应用Cromite补丁
  for file in $(cat "$WORKSPACE/cromite/build/cromite_patches_list.txt"); do
    if [[ "$file" == *".patch" ]]; then
      log "应用补丁: $file"
      REPL="0,/^---/s//FILE:"$(basename "$file")"\n---/"
      cat "$WORKSPACE/cromite/build/patches/$file" | sed "$REPL" | git am
      if [ $? -ne 0 ]; then
        error "应用补丁失败: $WORKSPACE/cromite/build/patches/${file}"
      fi
    fi
  done
  
  # 创建标记文件表示补丁已应用
  touch "$PATCHES_APPLIED_MARKER"
  
  log "所有补丁已成功应用。"
  
  # 再次清理以减少磁盘使用
  if [ "$DISK_SAVER" = true ]; then
    log "压缩仓库大小..."
    git gc --aggressive --prune=all
  fi
}

# 准备构建环境
prepare_build_env() {
  log "准备构建环境..."
  
  cd "$WORKSPACE" || error "无法进入工作目录"
  
  # 下载bromite mtool
  if [ ! -d mtool ]; then
    log "下载并构建bromite mtool..."
    git clone --depth 1 https://github.com/bromite/mtool
    cd mtool
    make
    cd ..
  fi
  
  # 下载ninjatracing
  if [ ! -d ninjatracing ]; then
    log "下载ninjatracing..."
    git clone --depth 1 https://github.com/nico/ninjatracing
  fi
  
  # 下载并配置PGO配置文件
  # 在磁盘节约模式下，跳过下载一些优化配置文件
  if [ "$DISK_SAVER" = false ]; then
    log "下载PGO配置文件..."
    cd "$WORKSPACE/chromium/src"
    python3 tools/update_pgo_profiles.py --target=android-arm64 update --gs-url-base=chromium-optimization-profiles/pgo_profiles || warn "下载arm64 PGO配置文件失败，但可能不影响构建"
    python3 v8/tools/builtins-pgo/download_profiles.py download --depot-tools "$WORKSPACE/depot_tools" --check-v8-revision || warn "下载V8 PGO配置文件失败，但可能不影响构建"
    python3 tools/download_optimization_profile.py --newest_state=chrome/android/profiles/newest.txt \
      --local_state=chrome/android/profiles/local.txt \
      --output_name=chrome/android/profiles/afdo.prof \
      --gs_url_base=chromeos-prebuilt/afdo-job/llvm || warn "下载优化配置文件失败，但可能不影响构建"
  else
    log "磁盘节约模式：跳过下载PGO配置文件，可能会影响性能优化。"
  fi
  
  log "构建环境准备完成。"
}

# 创建签名密钥库
create_keystore() {
  log "创建签名密钥库..."
  
  # 检查密钥库是否已存在
  if [ ! -f "$WORKSPACE/cromite.keystore" ]; then
    log "创建新的密钥库..."
    
    # 生成随机密码
    KEYSTORE_PASSWORD=$(openssl rand -base64 12)
    echo "密钥库密码 (请保存): $KEYSTORE_PASSWORD"
    
    # 创建密钥库配置文件
    cat > "$WORKSPACE/keystore_info.txt" << EOF
CN=Cromite Build
OU=Cromite
O=Cromite
L=Unknown
ST=Unknown
C=US
EOF
    
    # 生成密钥库
    keytool -genkey -v -keystore "$WORKSPACE/cromite.keystore" -alias cromite \
      -keyalg RSA -keysize 2048 -validity 10000 \
      -storepass "$KEYSTORE_PASSWORD" -keypass "$KEYSTORE_PASSWORD" \
      -dname "CN=Cromite Build, OU=Cromite, O=Cromite, L=Unknown, ST=Unknown, C=US"
      
    # 保存密码到环境变量
    export KEYSTORE_PASSWORD="$KEYSTORE_PASSWORD"
    echo "export KEYSTORE_PASSWORD=\"$KEYSTORE_PASSWORD\"" > "$WORKSPACE/keystore_env.sh"
  else
    log "密钥库已存在，请提供密码..."
    
    if [ -f "$WORKSPACE/keystore_env.sh" ]; then
      source "$WORKSPACE/keystore_env.sh"
      log "已加载密钥库密码。"
    else
      read -sp "请输入密钥库密码: " KEYSTORE_PASSWORD
      echo
      export KEYSTORE_PASSWORD="$KEYSTORE_PASSWORD"
      echo "export KEYSTORE_PASSWORD=\"$KEYSTORE_PASSWORD\"" > "$WORKSPACE/keystore_env.sh"
    fi
  fi
}

# 构建Android arm64版本
build_arm64() {
  log "开始构建Android arm64版本..."
  
  cd "$WORKSPACE/chromium/src" || error "无法进入Chromium源码目录"
  
  # 设置PATH
  export PATH="$WORKSPACE/chromium/src/third_party/llvm-build/Release+Asserts/bin:$WORKSPACE/depot_tools:$PATH"
  
  # 启用密钥库
  export USE_KEYSTORE=true
  
  # 启用ccache
  export CCACHE_DIR=$HOME/.ccache
  export USE_CCACHE=1
  
  # 清理之前的构建
  if [ "$CLEAN_BUILD" = true ]; then
    log "清理之前的构建..."
    rm -rf out/arm64
    mkdir -p out/arm64
  fi
  
  log "生成构建文件..."
  # 生成构建文件
  gn gen --args="target_os=\"android\" $(cat ../../cromite/build/cromite.gn_args) target_cpu=\"arm64\" use_ccache=true" out/arm64 || error "生成构建文件失败"
  
  log "生成构建配置信息..."
  # 查看构建配置
  gn args out/arm64/ --list --short
  gn args out/arm64/ --list > out/arm64/gn_list
  
  log "开始编译 chrome_public_bundle..."
  # 构建bundle，使用并行任务数来加速
  time ninja -C out/arm64 -j$MAX_JOBS chrome_public_bundle 2>&1 | tee "$WORKSPACE/logs/build_bundle_$(date +%Y%m%d_%H%M%S).log" || error "构建chrome_public_bundle失败"
  
  log "开始编译 chrome_public_apk..."
  # 构建apk
  time ninja -C out/arm64 -j$MAX_JOBS chrome_public_apk 2>&1 | tee "$WORKSPACE/logs/build_apk_$(date +%Y%m%d_%H%M%S).log" || error "构建chrome_public_apk失败"
  
  # 复制版本信息到输出目录
  cp "$WORKSPACE/cromite/build/RELEASE" out/arm64/
  
  log "开始生成breakpad符号文件..."
  # 生成breakpad符号文件
  ninja -C out/arm64 -j$MAX_JOBS minidump_stackwalk dump_syms || warn "生成minidump_stackwalk和dump_syms失败，但不影响APK可用性"
  
  # 只有在非磁盘节约模式下才生成完整符号
  if [ "$DISK_SAVER" = false ]; then
    components/crash/content/tools/generate_breakpad_symbols.py --build-dir=out/arm64 \
      --symbols-dir=out/arm64/symbols/ --binary=out/arm64/lib.unstripped/libchrome.so \
      --platform=android --clear --verbose || warn "生成breakpad符号文件失败，但不影响APK可用性"
      
    # 复制符号文件
    mkdir -p out/arm64/symbols/
    cp out/arm64/lib.unstripped/libchrome.so out/arm64/symbols/libchrome.lib.so || warn "复制libchrome.so失败"
    cp out/arm64/minidump_stackwalk out/arm64/symbols || warn "复制minidump_stackwalk失败"
    cp out/arm64/dump_syms out/arm64/symbols || warn "复制dump_syms失败"
  else
    log "磁盘节约模式：跳过生成完整符号文件。"
  fi
  
  log "构建完成！"
  log "APK文件位置: $WORKSPACE/chromium/src/out/arm64/apks/ChromePublic.apk"
  
  # 清理构建时生成的临时文件以节省空间
  if [ "$DISK_SAVER" = true ]; then
    log "清理构建时生成的中间文件以节省空间..."
    cd "$WORKSPACE/chromium/src/out/arm64"
    rm -rf obj gen
    find . -name "*.o" -delete
    find . -name "*.d" -delete
    find . -name "*.stamp" -delete
  fi
}

# 显示完成信息
show_completion() {
  log "========================================================"
  log "Cromite Android arm64构建已完成!"
  log "APK文件位置: $WORKSPACE/chromium/src/out/arm64/apks/ChromePublic.apk"
  log "构建配置文件: $WORKSPACE/chromium/src/out/arm64/gn_list"
  
  if [ "$DISK_SAVER" = false ]; then
    log "符号文件: $WORKSPACE/chromium/src/out/arm64/symbols/"
  fi
  
  log "========================================================"
  
  # 计算APK大小
  APK_SIZE=$(du -h "$WORKSPACE/chromium/src/out/arm64/apks/ChromePublic.apk" | awk '{print $1}')
  log "APK大小: $APK_SIZE"
  
  # 显示已用时间
  show_time
  
  # 显示磁盘使用情况
  free_space_after=$(df -BG "$HOME" | awk 'NR==2 {print $4}' | sed 's/G//')
  log "当前可用磁盘空间: ${free_space_after}GB"
  
  # 安装提示
  log "要在设备上安装APK，请连接设备并运行:"
  log "adb install -r $WORKSPACE/chromium/src/out/arm64/apks/ChromePublic.apk"
}

# 清理临时构建文件
clean_build_files() {
  if [ "$DISK_SAVER" = true ]; then
    log "清理临时构建文件..."
    
    cd "$WORKSPACE" || return 0
    
    # 压缩日志
    if [ -d "$WORKSPACE/logs" ]; then
      find "$WORKSPACE/logs" -type f -name "*.log" -exec gzip {} \;
    fi
    
    log "清理完成。可以手动删除以下目录以节省更多空间："
    log "  $WORKSPACE/chromium/src/out/arm64/obj"
    log "  $WORKSPACE/chromium/src/out/arm64/gen"
  fi
}

# 主函数
main() {
  # 解析命令行参数
  parse_args "$@"
  
  log "开始Cromite Android arm64构建流程..."
  
  # 记录开始时间
  start_time=$(date +%s)
  
  check_requirements
  install_dependencies
  prepare_workspace
  install_depot_tools
  get_cromite
  install_chromium_deps
  setup_chromium
  clean_disk_space
  apply_cromite_patches
  prepare_build_env
  create_keystore
  build_arm64
  clean_build_files
  show_completion
  
  log "构建流程成功完成。"
}

# 运行主函数并传递所有命令行参数
main "$@" 