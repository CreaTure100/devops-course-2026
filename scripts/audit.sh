#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  [OK]   $desc"; ((PASS++))
  else
    echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
  fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён" "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"
# DONE 1: порт отличен от 22
PORT="$(sudo sshd -T | awk '/^port/{print $2; exit}')"
if [[ "$PORT" != "22" ]]; then PORT_OK="yes"; else PORT_OK="no"; fi
check "Порт SSH отличен от 22 (сейчас: $PORT)" "yes" "$PORT_OK"
# DONE 2: MaxAuthTries равен 3
check "MaxAuthTries равен 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"
# DONE 3: политика по умолчанию для входящего трафика = deny
check "Политика входящего трафика: deny" "deny" "$(sudo ufw status verbose | awk '/^Default:/{print $2}')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "  %s (uid=%s)\n",$1,$3}' /etc/passwd


echo "[4] Веб-сервер"
CERT_FILE="/etc/ssl/certs/devops.crt"
KEY_FILE="/etc/ssl/private/devops.key"
WEB_DIR="/var/www/devops-site"
CERT_CHECK_SEC="${CERT_CHECK_SEC:-2592000}"   # 30 суток в секундах
check "Служба nginx активна" "active" "$(systemctl is-active nginx)"
check "Конфигурация nginx корректна (nginx -t)" "0" "$(sudo nginx -t >/dev/null 2>&1; echo $?)"
check "Сертификат действителен ещё не менее ${CERT_CHECK_SEC} с" "0" "$(openssl x509 -checkend "$CERT_CHECK_SEC" -noout -in "$CERT_FILE" >/dev/null 2>&1; echo $?)"
check "Нет файлов с записью для всех, права ключа 600" "0:600" "$(find "$WEB_DIR" -perm -o+w | wc -l):$(sudo stat -c '%a' "$KEY_FILE")"

echo "[5] Контейнеризация"
DB_CONTAINER="${DB_CONTAINER:-app-db-1}"
ENV_FILE="${ENV_FILE:-$HOME/app/.env}"
check "Служба docker активна" "active" "$(systemctl is-active docker)"
check "Контейнер СУБД в состоянии healthy" "healthy" "$(docker inspect -f '{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null)"
check "Порты 5000 и 5432 не слушаются вне 127.0.0.1" "0" "$(ss -tln | awk 'NR>1{print $4}' | grep -E ':(5000|5432)$' | grep -vc '^127\.0\.0\.1:')"
check "Права файла .env равны 600" "600" "$(stat -c '%a' "$ENV_FILE" 2>/dev/null)"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
