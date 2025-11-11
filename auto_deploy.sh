#!/usr/bin/env bash
#
# 自動部署 Redis-stack 與 Redis-sentinel 的冪等性腳本
# 適用 Ubuntu 22.04 + Docker
#
# 特性：
# 1. 若目錄或檔案已建立，不再重複建立
# 2. 若容器已在執行，不再重啟 (除非選擇移除舊容器)
# 3. 若 logrotate 與 crontab 排程已設定，不重複追加
# 4. 適用於系統重啟後再次執行，可使服務恢復運行
#

# ------------------ 使用者自訂區 ------------------
# Linux User
USER_NAME="redisuser"
# 資料夾所在地
BASE_DIR="$(pwd)"
REDIS_STACK_IMAGE="redis/redis-stack:7.4.0-v1"
SENTINEL_IMAGE="bitnamilegacy/redis-sentinel:7.4.0"
LOGROTATE_CONF="/etc/logrotate.d/redis"

# 若要保證每次執行都「重新部署容器」，可將此設定為 "true" (會先移除容器再啟動)
REMOVE_OLD_CONTAINERS="false"

# ------------------ 函數：顯示訊息 ------------------
info()    { echo -e "\033[1;34m[Info]  $*\033[0m"; }
warn()    { echo -e "\033[1;33m[警告] $*\033[0m"; }
error()   { echo -e "\033[1;31m[錯誤] $*\033[0m"; }
success() { echo -e "\033[1;32m[成功] $*\033[0m"; }

# ------------------ Step 0: 環境檢查 ------------------
info "=== 0. 檢查 Docker 是否安裝、啟動 ==="
if ! command -v docker &> /dev/null; then
  error "Docker 未安裝或未加入 PATH，請先安裝 Docker。"
  exit 1
fi

# 進一步檢查 docker daemon 是否在執行
if ! sudo systemctl is-active --quiet docker; then
  error "Docker 服務未啟動，嘗試以 systemctl start docker 或重啟系統後再執行本腳本。"
  exit 1
fi

# ------------------ Step 1: 建立資料夾 ------------------
info "=== 1. 建立資料夾結構 (若尚未建立) ==="

# redis-stack 部分
if [ ! -d "${BASE_DIR}/redis/logs" ]; then
  mkdir -p "${BASE_DIR}/redis/logs"
  success "建立資料夾: ${BASE_DIR}/redis/logs"
else
  info "資料夾已存在: ${BASE_DIR}/redis/logs (略過)"
fi

if [ ! -d "${BASE_DIR}/redis/pid" ]; then
  mkdir -p "${BASE_DIR}/redis/pid"
  success "建立資料夾: ${BASE_DIR}/redis/pid"
else
  info "資料夾已存在: ${BASE_DIR}/redis/pid (略過)"
fi

# redis-sentinel 部分
if [ ! -d "${BASE_DIR}/sentinel/redis-sentinel/conf" ]; then
  mkdir -p "${BASE_DIR}/sentinel/redis-sentinel/conf"
  success "建立資料夾: ${BASE_DIR}/sentinel/redis-sentinel/conf"
else
  info "資料夾已存在: ${BASE_DIR}/sentinel/redis-sentinel/conf (略過)"
fi

if [ ! -d "${BASE_DIR}/sentinel/redis-sentinel/logs" ]; then
  mkdir -p "${BASE_DIR}/sentinel/redis-sentinel/logs"
  success "建立資料夾: ${BASE_DIR}/sentinel/redis-sentinel/logs"
else
  info "資料夾已存在: ${BASE_DIR}/sentinel/redis-sentinel/logs (略過)"
fi

# config 資料夾
if [ ! -d "${BASE_DIR}/config" ]; then
  mkdir -p "${BASE_DIR}/config"
  success "建立資料夾: ${BASE_DIR}/config"
else
  info "資料夾已存在: ${BASE_DIR}/config (略過)"
fi

# ------------------ Step 2: 複製配置檔 ------------------
info "=== 2. 複製設定檔 (若不存在才複製) ==="

# redis.conf
if [ -f "${BASE_DIR}/redis.conf" ] && [ ! -f "${BASE_DIR}/config/redis.conf" ]; then
  cp "${BASE_DIR}/redis.conf" "${BASE_DIR}/config/redis.conf"
  success "已複製 redis.conf -> config/redis.conf"
elif [ -f "${BASE_DIR}/config/redis.conf" ]; then
  info "config/redis.conf 已存在 (略過)"
else
  warn "未找到 redis.conf，無法複製，請確認檔案位置。"
fi

# sentinel.conf
if [ -f "${BASE_DIR}/sentinel.conf" ] && [ ! -f "${BASE_DIR}/sentinel/redis-sentinel/conf/sentinel.conf" ]; then
  cp "${BASE_DIR}/sentinel.conf" "${BASE_DIR}/sentinel/redis-sentinel/conf/sentinel.conf"
  success "已複製 sentinel.conf -> sentinel/redis-sentinel/conf/sentinel.conf"
elif [ -f "${BASE_DIR}/sentinel/redis-sentinel/conf/sentinel.conf" ]; then
  info "sentinel/redis-sentinel/conf/sentinel.conf 已存在 (略過)"
else
  warn "未找到 sentinel.conf，無法複製，請確認檔案位置。"
fi

# ------------------ Step 3: 檢查並(選擇性)移除舊容器 ------------------
info "=== 3. 檢查容器狀態 (redis-stack, redis-sentinel) ==="

# redis-stack
EXIST_STACK=$(docker ps -a --format '{{.Names}}' | grep "^redis-stack$")
if [ -n "$EXIST_STACK" ]; then
  # 容器已經存在
  if [ "$REMOVE_OLD_CONTAINERS" = "true" ]; then
    info "偵測到 redis-stack 容器存在，REMOVE_OLD_CONTAINERS=true，將移除舊容器..."
    docker rm -f redis-stack &>/dev/null
    success "舊的 redis-stack 容器已移除。"
  else
    info "redis-stack 容器已存在，且 REMOVE_OLD_CONTAINERS=false，不執行移除。"
  fi
else
  info "尚未建立 redis-stack 容器 (稍後將新建)。"
fi

# redis-sentinel
EXIST_SENTINEL=$(docker ps -a --format '{{.Names}}' | grep "^redis-sentinel$")
if [ -n "$EXIST_SENTINEL" ]; then
  if [ "$REMOVE_OLD_CONTAINERS" = "true" ]; then
    info "偵測到 redis-sentinel 容器存在，REMOVE_OLD_CONTAINERS=true，將移除舊容器..."
    docker rm -f redis-sentinel &>/dev/null
    success "舊的 redis-sentinel 容器已移除。"
  else
    info "redis-sentinel 容器已存在，且 REMOVE_OLD_CONTAINERS=false，不執行移除。"
  fi
else
  info "尚未建立 redis-sentinel 容器 (稍後將新建)。"
fi

# ------------------ Step 4: 進入 BASE_DIR 啟動容器 ------------------
info "=== 4. 啟動容器 (若尚未在執行中) ==="
cd "${BASE_DIR}" || exit 1

# redis-stack 部分
RUNNING_STACK=$(docker ps --format '{{.Names}}' | grep "^redis-stack$")
if [ -z "$RUNNING_STACK" ]; then
  # 容器未在執行，才需要啟動
  info "準備啟動 redis-stack 容器..."
  docker run -v ${PWD}/redis/logs/:/logs \
             -v ${PWD}/redis/pid/:/pid \
             -v ${PWD}/config/redis.conf:/redis-stack.conf \
             --name redis-stack \
             -p 6379:6379 \
             -p 8001:8001 \
             -d ${REDIS_STACK_IMAGE}
  if [ $? -eq 0 ]; then
    success "redis-stack 容器啟動成功。"
  else
    error "redis-stack 容器啟動失敗，請檢查錯誤訊息。"
    exit 1
  fi
else
  info "redis-stack 容器已在執行中 (略過啟動)。"
fi

# redis-sentinel 部分
RUNNING_SENTINEL=$(docker ps --format '{{.Names}}' | grep "^redis-sentinel$")
if [ -z "$RUNNING_SENTINEL" ]; then
  info "準備啟動 redis-sentinel 容器..."
  docker run -v ${PWD}/sentinel:/bitnami \
             --name redis-sentinel \
             --net host \
             -d ${SENTINEL_IMAGE}
  if [ $? -eq 0 ]; then
    success "redis-sentinel 容器啟動成功。"
  else
    error "redis-sentinel 容器啟動失敗，請檢查錯誤訊息。"
    exit 1
  fi
else
  info "redis-sentinel 容器已在執行中 (略過啟動)。"
fi

# ------------------ Step 5: 設定 logrotate (若尚未設定) ------------------
info "=== 5. 設定 logrotate ==="

if [ -f "${LOGROTATE_CONF}" ]; then
  # 這裡可檢查檔案內容是否含有關鍵字
  if grep -q "${BASE_DIR}/redis/logs/log_redis-server_master.log" "${LOGROTATE_CONF}"; then
    info "logrotate 配置檔已存在且含有 redis logs (略過)。"
  else
    warn "偵測到 /etc/logrotate.d/redis 存在，但不含預期設定，請自行檢查或手動更新。"
  fi
else
  info "建立 /etc/logrotate.d/redis 配置..."
  sudo bash -c "cat <<EOF > ${LOGROTATE_CONF}
/home/${USER_NAME}/redis_server/redis/logs/log_redis-server_master.log {
    su root root
    rotate 10
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0777 ${USER_NAME} ${USER_NAME}
}

/home/${USER_NAME}/redis_server/sentinel/redis-sentinel/logs/log_sentinel.log {
    su root root
    rotate 10
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0777 ${USER_NAME} ${USER_NAME}
}
EOF
"
  success "已寫入 ${LOGROTATE_CONF}"
fi

# ------------------ Step 6: 測試 logrotate (選擇性) ------------------
info "=== 6. 強制測試 logrotate (可略過) ==="
sudo logrotate -f "${LOGROTATE_CONF}"
if [ $? -eq 0 ]; then
  success "logrotate 強制測試成功 (若檔案為空，可能顯示略過)。"
else
  error "logrotate 測試失敗，請檢查 /var/log/syslog 或 logrotate 配置。"
fi

# ------------------ Step 7: 加入 crontab (若未加入) ------------------
info "=== 7. 加入 crontab 排程 (若尚未加入) ==="
CRON_JOB="0 3 * * * /usr/sbin/logrotate -f /etc/logrotate.d/redis"

# 以 root 身分編輯 crontab
EXIST_CRON=$(sudo crontab -l 2>/dev/null | grep -F "${CRON_JOB}")
if [ -z "${EXIST_CRON}" ]; then
  info "crontab 尚未包含 logrotate 相關排程，將自動加入..."
  sudo bash -c "( crontab -l 2>/dev/null | grep -v '/usr/sbin/logrotate -f /etc/logrotate.d/redis'; echo '${CRON_JOB}' ) | crontab -"
  success "已將 logrotate 排程新增至 root crontab (每天凌晨3點執行)。"
else
  info "root crontab 已包含 logrotate 排程 (略過)。"
fi

# ------------------ 最後: 結束 ------------------
success "全部步驟完成！\n
=== 最終檢查清單 ===
1. 請使用 'docker ps' 確認 redis-stack 與 redis-sentinel 兩個容器都在執行。
2. 若要檢查 logrotate ，可觀察 /var/log/syslog 或手動執行 'sudo logrotate -f ${LOGROTATE_CONF}'。
3. 若要重新部署，將 REMOVE_OLD_CONTAINERS 設為 'true' 後再執行本腳本。
"
