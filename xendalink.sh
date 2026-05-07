#!/bin/bash

# =================================================================
# OpenClaw API 一键导入 & 自动化配置脚本 (严格校验适配版)
# =================================================================

echo "🚀 开始执行 OpenClaw 自动化配置闭环流程..."

# 0. 环境检查
if ! command -v jq &> /dev/null; then
    echo "❌ 错误: 系统未安装 jq。请执行: apt install jq"
    exit 1
fi

# 1. 查找与备份文件
echo "🔍 正在查找 openclaw.json..."
CONFIG_FILE=$(find . ~/.openclaw /opt/openclaw /etc/openclaw -name "openclaw.json" 2>/dev/null | head -n 1)
if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE=$(find / -name "openclaw.json" -type f 2>/dev/null | head -n 1)
fi

if [ -z "$CONFIG_FILE" ]; then
    echo "❌ 错误: 未能找到配置文件，请确保 OpenClaw 已安装。"
    exit 1
fi

BACKUP_FILE="${CONFIG_FILE}.bak_$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG_FILE" "$BACKUP_FILE"
echo "✅ 找到配置: $CONFIG_FILE"
echo "📦 已创建备份: $BACKUP_FILE"

# 2. 用户输入基本信息
echo "------------------------------------------------"
read -p "👉 请输入自定义供应商名称 (例如 xendalink): " PROVIDER_NAME
PROVIDER_NAME=${PROVIDER_NAME:-"xendalink"}

read -p "👉 请输入 BaseURL (默认: https://api.xendalink.com/v1): " BASE_URL
BASE_URL=${BASE_URL:-"https://api.xendalink.com/v1"}

read -p "👉 请输入 API Key (无需验证请直接回车): " API_KEY
echo "------------------------------------------------"

# 3. 读取并筛选模型
echo "📡 正在拉取模型列表..."
MODELS_ENDPOINT="${BASE_URL%/}/models"
API_RESPONSE=$(curl -s -m 8 -H "Authorization: Bearer $API_KEY" "$MODELS_ENDPOINT")

ALL_MODEL_IDS=($(echo "$API_RESPONSE" | jq -r '.data[]?.id' 2>/dev/null))

if [ ${#ALL_MODEL_IDS[@]} -eq 0 ]; then
    echo "⚠️ 无法拉取在线列表，启用应急模式。请输入要添加的模型ID (多个空格隔开):"
    read -a ALL_MODEL_IDS
fi

# 4. 引导选择要导入的模型 (回车全选)
SELECTED_MODELS_IDS=()
while true; do
    echo "📋 发现以下 ${#ALL_MODEL_IDS[@]} 个可用模型:"
    for i in "${!ALL_MODEL_IDS[@]}"; do
        echo "  $((i+1))) ${ALL_MODEL_IDS[$i]}"
    done
    
    echo -e "\n👉 请输入要导入的模型序号。直接回车或输入 'all' 将【全选】:"
    read -p "> " -a CHOICES
    
    TEMP_SELECTED=()
    if [ ${#CHOICES[@]} -eq 0 ] || [ "${CHOICES[0]}" == "all" ] || [ "${CHOICES[0]}" == "ALL" ]; then
        echo "💡 触发全选模式！将导入所有 ${#ALL_MODEL_IDS[@]} 个模型。"
        TEMP_SELECTED=("${ALL_MODEL_IDS[@]}")
    else
        for CHOICE in "${CHOICES[@]}"; do
            if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#ALL_MODEL_IDS[@]}" ]; then
                MODEL_ID="${ALL_MODEL_IDS[$((CHOICE-1))]}"
                if [[ ! " ${TEMP_SELECTED[@]} " =~ " ${MODEL_ID} " ]]; then
                    TEMP_SELECTED+=("$MODEL_ID")
                else
                    echo "⚠️ 警示: 模型 $MODEL_ID 已忽略重复。"
                fi
            else
                echo "❌ 无效序号: $CHOICE，已跳过。"
            fi
        done
    fi

    if [ ${#TEMP_SELECTED[@]} -eq 0 ]; then
        echo "❌ 你没有选择任何有效的模型。"
        continue
    fi

    echo "✅ 计划导入: ${#TEMP_SELECTED[@]} 个模型。"
    read -p "是否确认导入? (y/n/r) [默认 y]: " CONFIRM
    CONFIRM=${CONFIRM:-y}
    
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        SELECTED_MODELS_IDS=("${TEMP_SELECTED[@]}")
        break
    elif [[ "$CONFIRM" =~ ^[Rr]$ ]]; then
        continue
    else
        echo "⏹️ 取消导入。"
        exit 0
    fi
done

# 5. 引导选择默认模型 (回车默认选第1个)
echo -e "\n------------------------------------------------"
echo "🎯 请从已选导入的模型中，指定一个作为【全局默认】:"
for i in "${!SELECTED_MODELS_IDS[@]}"; do
    echo "  $((i+1))) ${SELECTED_MODELS_IDS[$i]}"
done

while true; do
    read -p "请输入默认模型序号 [1-${#SELECTED_MODELS_IDS[@]}] (直接回车默认选 1): " DEF_CHOICE
    DEF_CHOICE=${DEF_CHOICE:-1} 
    
    if [[ "$DEF_CHOICE" =~ ^[0-9]+$ ]] && [ "$DEF_CHOICE" -ge 1 ] && [ "$DEF_CHOICE" -le "${#SELECTED_MODELS_IDS[@]}" ]; then
        DEFAULT_MODEL_ID="${SELECTED_MODELS_IDS[$((DEF_CHOICE-1))]}"
        break
    else
        echo "❌ 输入无效，请重新选择。"
    fi
done

# 6. 生成并注入 JSON (重点修复：去除被禁用的字段，补齐 name 字段)
echo "⚙️ 正在修改配置文件..."
# 修复: OpenClaw 严格要求包含 name，且不能有 capabilities 和 config
MODEL_JSON_ARRAY=$(printf '%s\n' "${SELECTED_MODELS_IDS[@]}" | jq -R . | jq -s '[.[] | {id: ., name: .}]')

PROVIDER_CONTENT=$(jq -n \
  --arg bu "$BASE_URL" \
  --arg ak "$API_KEY" \
  --argjson mods "$MODEL_JSON_ARRAY" \
  '{baseUrl: $bu, apiKey: $ak, api: "openai-completions", models: $mods}')

jq --arg name "$PROVIDER_NAME" \
   --argjson content "$PROVIDER_CONTENT" \
   --arg default_mod "${PROVIDER_NAME}/${DEFAULT_MODEL_ID}" \
   '.models.providers[$name] = $content | .agents.defaults.model.primary = $default_mod' \
   "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"

if [ $? -ne 0 ]; then
    echo "❌ 致命错误: 配置文件写入失败！"
    mv "$BACKUP_FILE" "$CONFIG_FILE"
    rm -f "${CONFIG_FILE}.tmp"
    exit 1
fi
mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

# 7. 自动探测重启方法与强校验回滚
echo "🔄 正在探测部署环境并尝试重启..."

DEPLOY_METHOD="unknown"
if command -v openclaw &> /dev/null; then
    DEPLOY_METHOD="cli" # 优先捕获原生命令
elif command -v docker &> /dev/null && docker ps --format '{{.Names}}' | grep -qi "openclaw"; then
    DEPLOY_METHOD="docker"; SERVICE_NAME=$(docker ps --format '{{.Names}}' | grep -i "openclaw" | head -n 1)
elif systemctl is-active --quiet openclaw 2>/dev/null; then
    DEPLOY_METHOD="systemd"
elif command -v pm2 &> /dev/null && pm2 list | grep -qi "openclaw"; then
    DEPLOY_METHOD="pm2"
fi

RESTART_SUCCESS=false

case $DEPLOY_METHOD in
    cli)
        echo "⚡ 检测到原生 OpenClaw 环境，正在重启 Gateway..."
        # 捕获日志，如果出现 invalid 等报错，立即拦截
        START_LOG=$(openclaw gateway restart 2>&1)
        if [ $? -ne 0 ] || echo "$START_LOG" | grep -qi "invalid\|aborted\|error"; then
            echo -e "\n🚨 OpenClaw 拒绝接受新配置，引擎报错如下:"
            echo -e "\033[31m$START_LOG\033[0m"
            RESTART_SUCCESS=false
        else
            RESTART_SUCCESS=true
        fi
        ;;
    docker)
        docker restart "$SERVICE_NAME" >/dev/null
        sleep 3
        if docker ps -f name="$SERVICE_NAME" -f status=running | grep -qi "$SERVICE_NAME"; then RESTART_SUCCESS=true; fi
        ;;
    systemd)
        sudo systemctl restart openclaw
        sleep 3
        if systemctl is-active --quiet openclaw; then RESTART_SUCCESS=true; fi
        ;;
    pm2)
        pm2 restart openclaw >/dev/null
        sleep 3
        if pm2 info openclaw | grep -qi "status.*online"; then RESTART_SUCCESS=true; fi
        ;;
    *)
        echo "⚠️ 无法确定运行环境，请手动执行 openclaw gateway restart。"
        RESTART_SUCCESS="unknown"
        ;;
esac

# 8. 终极判断与反馈
if [ "$RESTART_SUCCESS" = true ]; then
    echo -e "\n------------------------------------------------"
    echo "导入成功"
    echo "导入模型：${#SELECTED_MODELS_IDS[@]}个"
    echo "默认模型已修改为：${PROVIDER_NAME}/${DEFAULT_MODEL_ID}"
    echo "------------------------------------------------"
elif [ "$RESTART_SUCCESS" = false ]; then
    echo -e "\n🔄 正在触发自动回滚..."
    mv "$BACKUP_FILE" "$CONFIG_FILE"
    
    # 尝试恢复重启
    if [ "$DEPLOY_METHOD" = "cli" ]; then
        openclaw gateway restart >/dev/null 2>&1
    fi
    
    echo "导入失败，已恢复原配置文件，请检查配置或报错日志后重新运行导入。"
else
    # 状态 unknown 时，JSON 已修改，用户需手动验证
    echo -e "\n导入成功 (需手动重启生效)"
    echo "导入模型：${#SELECTED_MODELS_IDS[@]}个"
    echo "默认模型已修改为：${PROVIDER_NAME}/${DEFAULT_MODEL_ID}"
fi

exit 0
