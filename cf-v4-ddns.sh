#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# 检查系统版本并安装 jq
install_jq() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case $ID in
      centos|rhel|fedora)
        echo "Detected CentOS/RHEL/Fedora"
        sudo yum update -y
        sudo yum install -y jq
        ;;
      ubuntu|debian)
        echo "Detected Ubuntu/Debian"
        sudo apt update
        sudo apt install -y jq
        ;;
      alpine)
        echo "Detected Alpine"
        sudo apk update
        sudo apk add jq
        ;;
      *)
        echo "Unsupported system: $ID"
        exit 1
        ;;
    esac
  else
    echo "Cannot determine OS type."
    exit 1
  fi
}

# 生成用户自定义的 cf-my.sh 脚本，按照用户提供的格式
generate_script() {
  cat <<EOF >cf-my.sh
#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

CFKEY="$CFKEY"
CFUSER="$CFUSER"
CFZONE_NAME="$CFZONE_NAME"
CFRECORD_NAME="$CFRECORD_NAME"
CFRECORD_TYPE=A
CFTTL=120
FORCE=false
WANIPSITE="http://ipv4.icanhazip.com"

if [ "\$CFRECORD_TYPE" = "A" ]; then
  :
elif [ "\$CFRECORD_TYPE" = "AAAA" ]; then
  WANIPSITE="http://ipv6.icanhazip.com"
else
  echo "\$CFRECORD_TYPE specified is invalid, CFRECORD_TYPE can only be A(for IPv4)|AAAA(for IPv6)"
  exit 2
fi

while getopts k:u:h:z:t:f: opts; do
  case \${opts} in
    k) CFKEY=\${OPTARG} ;;
    u) CFUSER=\${OPTARG} ;;
    h) CFRECORD_NAME=\${OPTARG} ;;
    z) CFZONE_NAME=\${OPTARG} ;;
    t) CFRECORD_TYPE=\${OPTARG} ;;
    f) FORCE=\${OPTARG} ;;
  esac
done

if [ "\$CFKEY" = "" ]; then
  echo "Missing api-key, get at: https://www.cloudflare.com/a/account/my-account"
  exit 2
fi
if [ "\$CFUSER" = "" ]; then
  echo "Missing username, probably your email-address"
  exit 2
fi
if [ "\$CFRECORD_NAME" = "" ]; then 
  echo "Missing hostname, what host do you want to update?"
  exit 2
fi

if [ "\$CFRECORD_NAME" != "\$CFZONE_NAME" ] && ! [ -z "\${CFRECORD_NAME##*\$CFZONE_NAME}" ]; then
  CFRECORD_NAME="\$CFRECORD_NAME.\$CFZONE_NAME"
  echo " => Hostname is not a FQDN, assuming \$CFRECORD_NAME"
fi

WAN_IP=\`curl -s \${WANIPSITE}\`
WAN_IP_FILE=\$HOME/.cf-wan_ip_\$CFRECORD_NAME.txt
if [ -f \$WAN_IP_FILE ]; then
  OLD_WAN_IP=\`cat \$WAN_IP_FILE\`
else
  echo "No file, need IP"
  OLD_WAN_IP=""
fi

if [ "\$WAN_IP" = "\$OLD_WAN_IP" ] && [ "\$FORCE" = false ]; then
  echo "WAN IP Unchanged, to update anyway use flag -f true"
  exit 0
fi

ID_FILE=\$HOME/.cf-id_\$CFRECORD_NAME.txt
if [ -f \$ID_FILE ] && [ \$(wc -l \$ID_FILE | cut -d " " -f 1) == 4 ] \
  && [ "\$(sed -n '3,1p' "\$ID_FILE")" == "\$CFZONE_NAME" ] \
  && [ "\$(sed -n '4,1p' "\$ID_FILE")" == "\$CFRECORD_NAME" ]; then
    CFZONE_ID=\$(sed -n '1,1p' "\$ID_FILE")
    CFRECORD_ID=\$(sed -n '2,1p' "\$ID_FILE")
else
    echo "Updating zone_identifier & record_identifier"
    CFZONE_ID=\$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=\$CFZONE_NAME" -H "X-Auth-Email: \$CFUSER" -H "X-Auth-Key: \$CFKEY" -H "Content-Type: application/json" | jq -r '.result[0].id')
    CFRECORD_ID=\$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/\$CFZONE_ID/dns_records?name=\$CFRECORD_NAME" -H "X-Auth-Email: \$CFUSER" -H "X-Auth-Key: \$CFKEY" -H "Content-Type: application/json" | jq -r '.result[0].id')
    echo "\$CFZONE_ID" > \$ID_FILE
    echo "\$CFRECORD_ID" >> \$ID_FILE
    echo "\$CFZONE_NAME" >> \$ID_FILE
    echo "\$CFRECORD_NAME" >> \$ID_FILE
fi

echo "Updating DNS to \$WAN_IP"

RESPONSE=\$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/\$CFZONE_ID/dns_records/\$CFRECORD_ID" \
  -H "X-Auth-Email: \$CFUSER" \
  -H "X-Auth-Key: \$CFKEY" \
  -H "Content-Type: application/json" \
  --data "{\"id\":\"\$CFZONE_ID\",\"type\":\"\$CFRECORD_TYPE\",\"name\":\"\$CFRECORD_NAME\",\"content\":\"\$WAN_IP\", \"ttl\":\$CFTTL}")

if [ "\$RESPONSE" != "\${RESPONSE%success*}" ] && [ "\$(echo \$RESPONSE | grep "\"success\":true")" != "" ]; then
  echo "Updated successfully!"
  echo \$WAN_IP > \$WAN_IP_FILE
  exit
else
  echo 'Something went wrong :('
  echo "Response: \$RESPONSE"
  exit 1
fi
EOF

  chmod +x cf-my.sh
  echo "DDNS更新脚本已生成: cf-my.sh"
}

# DDNS更新逻辑
run_ddns() {
  read -p "请输入 Cloudflare API Key (CFKEY): " CFKEY
  read -p "请输入 Cloudflare 用户邮箱 (CFUSER): " CFUSER
  read -p "请输入 Cloudflare 区域名称 (CFZONE_NAME): " CFZONE_NAME
  read -p "请输入 Cloudflare 记录名称 (CFRECORD_NAME): " CFRECORD_NAME

  generate_script
  enable_cron
}

# 启用定时任务，指向 cf-my.sh
enable_cron() {
  SCRIPT_PATH=$(realpath "$HOME/cf-my.sh")
  CRON_JOB="*/2 * * * * $SCRIPT_PATH"

  if crontab -l | grep -q "$SCRIPT_PATH"; then
    echo "定时任务已经存在。"
  else
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "定时任务已开启，每2分钟运行一次 cf-my.sh。"
  fi
}

# 禁用定时任务
disable_cron() {
  SCRIPT_PATH=$(realpath "$HOME/cf-my.sh")

  # 移除定时任务
  crontab -l | grep -v "$SCRIPT_PATH" | crontab -
  echo "定时任务已关闭。"
}

# 菜单页面
menu() {
  echo ""
  echo "欢迎使用 DDNS 更新脚本"
  echo "1. 启动DDNS"
  echo "2. 开启定时任务"
  echo "3. 关闭定时任务"
  echo "4. 退出"

  read -p "请选择操作 [1-4]: " option
  case $option in
    1)
      install_jq
      run_ddns
      ;;
    2)
      enable_cron
      ;;
    3)
      disable_cron
      ;;
    4)
      exit 0
      ;;
    *)
      echo "无效选项，请重新选择。"
      menu
      ;;
  esac
}

# 显示菜单
menu
