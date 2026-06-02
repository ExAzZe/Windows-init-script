Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$script:NeedReboot   = $false
$script:DomainJoined = $null
$script:LogFile      = "$env:SystemDrive\vm-setup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

$os          = Get-CimInstance Win32_OperatingSystem
$productType = $os.ProductType
$isServer    = ($productType -ge 2)
$isDC        = (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4

function Write-Banner {
    param([string]$Title)
    $sep = "=" * 58
    Write-Host ""
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host ("    " + $Title.ToUpper()) -ForegroundColor Cyan
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Step { param([string]$M) Write-Host "  [>] $M" -ForegroundColor Yellow }
function Write-OK   { param([string]$M) Write-Host "  [v] $M" -ForegroundColor Green  }
function Write-Warn { param([string]$M) Write-Host "  [!] $M" -ForegroundColor Red    }
function Write-Info { param([string]$M) Write-Host "  [-] $M" -ForegroundColor Gray   }

function Confirm-Action {
    param([string]$Question)
    do {
        $r = (Read-Host "  $Question [O/N]").Trim().ToUpper()
    } while ($r -ne "O" -and $r -ne "N")
    return ($r -eq "O")
}

function Write-Log {
    param([string]$Msg)
    "$(Get-Date -Format 'HH:mm:ss') | $Msg" | Add-Content -Path $script:LogFile
}

function Show-Menu {
    Clear-Host
    $sep = "=" * 58
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host "    Windows-init-script v2.0" -ForegroundColor Yellow
    Write-Host "    $($os.Caption)" -ForegroundColor White
    Write-Host "    Machine : $env:COMPUTERNAME" -ForegroundColor White
    Write-Host "    github.com/ExAzZe" -ForegroundColor Yellow
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  [1] Pilotes VirtIO"         -ForegroundColor White
    Write-Host "  [2] Configuration reseau"   -ForegroundColor White
    Write-Host "  [3] ICMP / Pare-feu"        -ForegroundColor White
    Write-Host "  [4] Identite machine"       -ForegroundColor White
    if ($isServer) {
        Write-Host "  [5] Roles Windows Server"                        -ForegroundColor White
        Write-Host "  [6] Promotion DC (ADDS)"                         -ForegroundColor White
        Write-Host "  [7] DNS - Zones inversees"                       -ForegroundColor White
        Write-Host "  [8] Structure AD  (OUs / Groupes / Utilisateurs)" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  [0] Tout executer"  -ForegroundColor DarkYellow
    Write-Host "  [Q] Quitter"        -ForegroundColor DarkGray
    Write-Host ""
}

function Invoke-VirtIO {
    Write-Banner "Pilotes VirtIO"

    $virtioExe = $null
    foreach ($disk in (Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 5 })) {
        $candidate = "$($disk.DeviceID)\virtio-win-guest-tools.exe"
        if (Test-Path $candidate) { $virtioExe = $candidate; break }
    }

    if (-not $virtioExe) {
        Write-Info "Aucun disque VirtIO monte"
        return
    }

    Write-Info "Trouve : $virtioExe"

    $installed = Get-ChildItem `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" `
        -ErrorAction SilentlyContinue |
        Get-ItemProperty -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like "*VirtIO*" } |
        Select-Object -First 1

    if ($installed) {
        Write-OK "Deja installe : $($installed.DisplayName) v$($installed.DisplayVersion)"
        Write-Log "VirtIO: deja installe v$($installed.DisplayVersion)"
        return
    }

    if (Confirm-Action "Installer les pilotes VirtIO (mode silencieux) ?") {
        Write-Step "Installation en cours (/S)..."
        $proc = Start-Process -FilePath $virtioExe -ArgumentList "/S" -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-OK "Pilotes installes avec succes"
            Write-Log "VirtIO: installe"
        } else {
            Write-Warn "Code de sortie $($proc.ExitCode) - verifier manuellement"
            Write-Log  "VirtIO: echec code=$($proc.ExitCode)"
        }
    }
}

function Invoke-NetworkConfig {
    Write-Banner "Configuration reseau"

    Write-Step "Passage de tous les profils reseau en Prive..."
    Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
    Write-OK "Profils reseau -> Prive"
    Write-Log "Reseau: profils -> Private"

    Write-Info "Interfaces disponibles :"
    Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, MacAddress -AutoSize

    while (Confirm-Action "Configurer l'adresse IP d'une interface ?") {
        Write-Host ""
        Get-NetAdapter | Format-Table Name, Status -AutoSize

        $alias   = (Read-Host "  Nom de l'interface (ex: Ethernet0)").Trim()
        $adapter = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
        if (-not $adapter) { Write-Warn "Interface '$alias' introuvable"; continue }

        $ip     = (Read-Host "  Adresse IP").Trim()
        $prefix = (Read-Host "  Longueur de prefixe (ex: 24)").Trim()
        $gw     = (Read-Host "  Passerelle par defaut").Trim()
        $dns1   = (Read-Host "  DNS primaire").Trim()
        $dns2   = (Read-Host "  DNS secondaire  (Entree pour ignorer)").Trim()

        Write-Step "Application de la configuration sur '$alias'..."

        Remove-NetIPAddress -InterfaceAlias $alias -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute     -InterfaceAlias $alias -DestinationPrefix "0.0.0.0/0" -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress    -InterfaceAlias $alias -IPAddress $ip -PrefixLength ([int]$prefix) -DefaultGateway $gw | Out-Null

        $dnsServers = if ($dns2) { @($dns1, $dns2) } else { @($dns1) }
        Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $dnsServers

        Write-OK "$alias : $ip/$prefix  GW=$gw  DNS=$($dnsServers -join ', ')"
        Write-Log "IP: alias=$alias ip=$ip/$prefix gw=$gw dns=$($dnsServers -join ',')"
    }
}

function Invoke-ICMPConfig {
    Write-Banner "Pare-feu / ICMP"

    $rule    = Get-NetFirewallRule -Name "FPS-ICMP4-ERQ-In" -ErrorAction SilentlyContinue
    $current = if ($rule) { $rule.Enabled } else { "Introuvable" }
    Write-Info "Etat actuel regle ICMP v4 : $current"

    if (Confirm-Action "Autoriser le ping entrant (ICMP v4) ?") {
        Set-NetFirewallRule -Name "FPS-ICMP4-ERQ-In" -Enabled True
        Write-OK "Regle pare-feu ICMP v4 activee"
        Write-Log "ICMP v4: active"
    }
}

function Invoke-MachineIdentity {
    Write-Banner "Identite machine"

    Write-Info "Nom actuel : $env:COMPUTERNAME"

    $newComputerName = $null
    if (Confirm-Action "Renommer cette machine ?") {
        $newComputerName = (Read-Host "  Nouveau nom").Trim()
    }

    if (Confirm-Action "Joindre un domaine Active Directory ?") {
        $script:DomainJoined = (Read-Host "  Nom du domaine (ex: TSSR110-ML.LCL)").Trim()
        Write-Step "Saisir les credentials du domaine..."
        $domainCred = Get-Credential

        $addParams = @{ DomainName = $script:DomainJoined; Credential = $domainCred; Force = $true }
        if ($newComputerName) { $addParams["NewName"] = $newComputerName }

        Add-Computer @addParams
        Write-OK "Machine ajoutee au domaine '$($script:DomainJoined)'"
        if ($newComputerName) { Write-OK "Sera renommee '$newComputerName' apres redemarrage" }
        Write-Log "Domaine: $($script:DomainJoined) | NouveauNom=$newComputerName"

        $newComputerName   = $null
        $script:NeedReboot = $true
    }

    if ($newComputerName) {
        Rename-Computer -NewName $newComputerName -Force
        Write-OK "Renommage '$newComputerName' programme pour le prochain redemarrage"
        Write-Log "Renommage: $env:COMPUTERNAME -> $newComputerName"
        $script:NeedReboot = $true
    }
}

function Invoke-ServerRoles {
    Write-Banner "Roles Windows Server"

    $roles = [ordered]@{
        "1" = @{ Label = "AD DS     - Active Directory Domain Services"; Feats = @("AD-Domain-Services") }
        "2" = @{ Label = "DNS       - Serveur DNS";                      Feats = @("DNS") }
        "3" = @{ Label = "DHCP      - Serveur DHCP";                     Feats = @("DHCP") }
        "4" = @{ Label = "ADCS      - Autorite de certification (PKI)";  Feats = @("AD-Certificate","ADCS-Cert-Authority") }
        "5" = @{ Label = "IIS       - Serveur Web";                      Feats = @("Web-Server","Web-Common-Http","Web-Mgmt-Console") }
        "6" = @{ Label = "FS + DFS  - Serveur de fichiers + DFS";        Feats = @("FS-FileServer","FS-DFS-Namespace","FS-DFS-Replication") }
        "7" = @{ Label = "Print     - Serveur d'impression";            Feats = @("Print-Server") }
        "8" = @{ Label = "RDSH      - Hote de session Bureau a distance";Feats = @("RDS-RD-Server") }
        "9" = @{ Label = "Hyper-V   - Hyperviseur";                      Feats = @("Hyper-V") }
    }

    Write-Host "  Roles disponibles :`n"
    foreach ($k in $roles.Keys) { Write-Host ("    [{0}]  {1}" -f $k, $roles[$k].Label) }
    Write-Host ""

    $sel = (Read-Host "  Numeros a installer (ex: 1,2,3) ou N pour ignorer").Trim()

    if ($sel -notmatch '^[Nn]$') {
        foreach ($k in ($sel -split "," | ForEach-Object { $_.Trim() })) {
            if (-not $roles.Contains($k)) { Write-Warn "Numero '$k' invalide, ignore"; continue }

            $label = $roles[$k].Label
            $feats = $roles[$k].Feats

            Write-Step "Installation : $label"
            Install-WindowsFeature -Name $feats -IncludeManagementTools -IncludeAllSubFeature | Out-Null
            Write-OK "$label installe"
            Write-Log "Role: $label"

            if ($k -eq "3") {
                $dhcpFqdn = if ($script:DomainJoined) { "$env:COMPUTERNAME.$($script:DomainJoined)" } else { $env:COMPUTERNAME }
                Write-Info "Pour autoriser le serveur DHCP dans AD :"
                Write-Info "  Add-DhcpServerInDC -DnsName '$dhcpFqdn'"
                if ($script:DomainJoined -and (Confirm-Action "Autoriser ce serveur DHCP dans AD maintenant ?")) {
                    $cred3 = Get-Credential "Compte admin du domaine"
                    Add-DhcpServerInDC -DnsName $dhcpFqdn -Credential $cred3 -ErrorAction SilentlyContinue
                    Write-OK "Serveur DHCP autorise dans AD"
                    Write-Log "DHCP: autorise dans AD"
                }
            }
        }
    }
}

function Invoke-ADDSPromotion {
    Write-Banner "Promotion controleur de domaine"

    if (-not (Get-WindowsFeature -Name "AD-Domain-Services").Installed) {
        Write-Warn "Le role AD DS n'est pas installe. Lancez d'abord le bloc [5]."
        return
    }

    if ($script:NeedReboot) {
        Write-Warn "Un redemarrage est en attente. Effectuez la promotion apres le redemarrage."
        return
    }

    $dcMode = (Read-Host "  [1] Nouvelle foret  [2] DC additionnel  [3] Domaine enfant").Trim()
    $dsrm   = Read-Host "  Mot de passe DSRM (mode restauration)" -AsSecureString

    switch ($dcMode) {
        "1" {
            $forest = (Read-Host "  Nom de la foret (ex: MONDOMAINE.LCL)").Trim()
            Install-ADDSForest `
                -CreateDnsDelegation:$false `
                -DatabasePath "C:\Windows\NTDS" `
                -DomainMode "WinThreshold" `
                -DomainName $forest `
                -DomainNetbiosName ($forest.Split('.')[0].ToUpper()) `
                -ForestMode "WinThreshold" `
                -InstallDns:$true `
                -LogPath "C:\Windows\NTDS" `
                -SysvolPath "C:\Windows\SYSVOL" `
                -SafeModeAdministratorPassword $dsrm `
                -Force
            Write-Log "ADDS: nouvelle foret=$forest"
        }
        "2" {
            $existDom = if ($script:DomainJoined) { $script:DomainJoined } else { (Read-Host "  Nom du domaine existant").Trim() }
            $cred2 = Get-Credential
            Install-ADDSDomainController `
                -DomainName $existDom `
                -DatabasePath "C:\Windows\NTDS" `
                -LogPath "C:\Windows\NTDS" `
                -SysvolPath "C:\Windows\SYSVOL" `
                -InstallDns:$true `
                -SafeModeAdministratorPassword $dsrm `
                -Credential $cred2 `
                -Force
            Write-Log "ADDS: DC additionnel domaine=$existDom"
        }
        "3" {
            $parent    = (Read-Host "  Domaine parent").Trim()
            $childName = (Read-Host "  Nom du domaine enfant (label seul, ex: CHILD)").Trim()
            $cred2     = Get-Credential
            Install-ADDSDomain `
                -ParentDomainName $parent `
                -NewDomainName $childName `
                -DatabasePath "C:\Windows\NTDS" `
                -LogPath "C:\Windows\NTDS" `
                -SysvolPath "C:\Windows\SYSVOL" `
                -InstallDns:$true `
                -SafeModeAdministratorPassword $dsrm `
                -Credential $cred2 `
                -Force
            Write-Log "ADDS: domaine enfant=$childName parent=$parent"
        }
        default { Write-Warn "Choix invalide - promotion ignoree" }
    }
    $script:NeedReboot = $true
}

function Invoke-DNSReverseZones {
    Write-Banner "DNS - Zones inversees"

    if (-not (Get-WindowsFeature -Name "DNS").Installed) {
        Write-Warn "Le role DNS n'est pas installe."
        return
    }

    do {
        $network = (Read-Host "  Reseau (ex: 192.168.1.0)").Trim()
        $prefix  = [int](Read-Host "  Longueur de prefixe (8 / 16 / 24)").Trim()

        if ($prefix -notin @(8, 16, 24)) {
            Write-Warn "Prefixe $prefix non supporte - utiliser 8, 16 ou 24"
            continue
        }

        $octets   = $network.Split('.')
        $n        = $prefix / 8
        $reversed = $octets[0..($n - 1)][-1..-$n] -join '.'
        $zoneName = "$reversed.in-addr.arpa"

        try {
            Add-DnsServerPrimaryZone -Name $zoneName -ZoneFile "$zoneName.dns" -ErrorAction Stop
            Write-OK "Zone inversee creee : $zoneName"
            Write-Log "DNS: zone inversee $zoneName"
        } catch {
            Write-Warn "Erreur creation zone $zoneName : $_"
        }

    } while (Confirm-Action "Ajouter une autre zone inversee ?")
}

function Invoke-ADStructure {
    Write-Banner "Structure Active Directory"

    if ((Get-CimInstance Win32_ComputerSystem).DomainRole -lt 4) {
        Write-Warn "Ce serveur n'est pas un controleur de domaine actif."
        Write-Warn "Effectuez la promotion (bloc [6]) et redemarrez d'abord."
        return
    }

    $domain = Get-ADDomain
    $DN     = $domain.DistinguishedName

    $ouCsv   = "$PSScriptRoot\AD-OUs.csv"
    $grpCsv  = "$PSScriptRoot\AD-Groups.csv"
    $userCsv = "$PSScriptRoot\AD-Users.csv"

    if (Test-Path $ouCsv) {
        Write-Step "Creation des OUs depuis AD-OUs.csv..."
        $ous      = Import-Csv $ouCsv
        $rootOUs  = $ous | Where-Object { -not $_.ParentOU }
        $childOUs = $ous | Where-Object { $_.ParentOU }

        foreach ($ou in $rootOUs) {
            if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$($ou.Name)'" -SearchBase $DN -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name $ou.Name -Path $DN -Description $ou.Description -ProtectedFromAccidentalDeletion $false
                Write-OK "OU creee : $($ou.Name)"
            } else {
                Write-Info "OU existante : $($ou.Name)"
            }
        }

        foreach ($ou in $childOUs) {
            $parentDN = (Get-ADOrganizationalUnit -Filter "Name -eq '$($ou.ParentOU)'" -SearchBase $DN -SearchScope Subtree -ErrorAction SilentlyContinue).DistinguishedName
            if (-not $parentDN) { Write-Warn "Parent '$($ou.ParentOU)' introuvable pour '$($ou.Name)'"; continue }

            if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$($ou.Name)'" -SearchBase $parentDN -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name $ou.Name -Path $parentDN -Description $ou.Description -ProtectedFromAccidentalDeletion $false
                Write-OK "OU creee : $($ou.Name) dans $($ou.ParentOU)"
            } else {
                Write-Info "OU existante : $($ou.Name)"
            }
        }
        Write-Log "AD: OUs creees depuis CSV"
    } else {
        Write-Warn "AD-OUs.csv introuvable dans $PSScriptRoot"
    }

    if (Test-Path $grpCsv) {
        Write-Step "Creation des groupes depuis AD-Groups.csv..."
        $groups = Import-Csv $grpCsv

        foreach ($grp in $groups) {
            $scope    = if ($grp.GroupScope)    { $grp.GroupScope }    else { "Global" }
            $category = if ($grp.GroupCategory) { $grp.GroupCategory } else { "Security" }
            $ouDN     = (Get-ADOrganizationalUnit -Filter "Name -eq '$($grp.OU)'" -SearchBase $DN -SearchScope Subtree -ErrorAction SilentlyContinue).DistinguishedName

            if (-not $ouDN) { Write-Warn "OU '$($grp.OU)' introuvable pour le groupe '$($grp.Groupe)'"; continue }

            if (-not (Get-ADGroup -Filter "Name -eq '$($grp.Groupe)'" -ErrorAction SilentlyContinue)) {
                New-ADGroup -Name $grp.Groupe -GroupScope $scope -GroupCategory $category -Path $ouDN -Description $grp.Description
                Write-OK "Groupe cree : $($grp.Groupe)"
            } else {
                Write-Info "Groupe existant : $($grp.Groupe)"
            }
        }

        foreach ($grp in ($groups | Where-Object { $_.ParentGroup })) {
            try {
                Add-ADGroupMember -Identity $grp.ParentGroup -Members $grp.Groupe -ErrorAction Stop
                Write-OK "$($grp.Groupe) ajoute dans $($grp.ParentGroup)"
            } catch {
                Write-Info "$($grp.Groupe) deja membre de $($grp.ParentGroup)"
            }
        }
        Write-Log "AD: groupes crees depuis CSV"
    } else {
        Write-Warn "AD-Groups.csv introuvable dans $PSScriptRoot"
    }

    if (Test-Path $userCsv) {
        Write-Step "Creation des utilisateurs depuis AD-Users.csv..."
        $users = Import-Csv $userCsv

        $hasPasswordCol = ($users | Select-Object -First 1).PSObject.Properties['Password']
        $defaultSecPwd  = $null

        if (-not $hasPasswordCol) {
            Write-Warn "Aucune colonne Password dans le CSV"
            $defaultSecPwd = Read-Host "  Mot de passe a appliquer a tous les utilisateurs" -AsSecureString
        }

        foreach ($u in $users) {
            if (Get-ADUser -Filter "SamAccountName -eq '$($u.Login)'" -ErrorAction SilentlyContinue) {
                Write-Info "Utilisateur existant : $($u.Login)"
                continue
            }

            $ouDN = (Get-ADOrganizationalUnit -Filter "Name -eq '$($u.OU)'" -SearchBase $DN -SearchScope Subtree -ErrorAction SilentlyContinue).DistinguishedName

            if ($hasPasswordCol -and $u.Password) {
                $secPwd = ConvertTo-SecureString $u.Password -AsPlainText -Force
            } else {
                $secPwd = $defaultSecPwd
            }

            $params = @{
                Name                  = "$($u.Prenom) $($u.Nom)"
                SamAccountName        = $u.Login
                GivenName             = $u.Prenom
                Surname               = $u.Nom
                DisplayName           = "$($u.Prenom) $($u.Nom)"
                UserPrincipalName     = "$($u.Login)@$($domain.DNSRoot)"
                EmailAddress          = "$($u.Login)@$($domain.DNSRoot)"
                Title                 = $u.Job
                Department            = $u.Service
                Path                  = $ouDN
                AccountPassword       = $secPwd
                Enabled               = $true
                ChangePasswordAtLogon = $false
            }

            if ($u.PSObject.Properties['TelephoneNumber'] -and $u.TelephoneNumber) { $params["OfficePhone"]  = $u.TelephoneNumber }
            if ($u.PSObject.Properties['Description']     -and $u.Description)     { $params["Description"] = $u.Description }
            if ($u.PSObject.Properties['Manager']         -and $u.Manager) {
                $managerDN = (Get-ADUser -Filter "SamAccountName -eq '$($u.Manager)'" -ErrorAction SilentlyContinue).DistinguishedName
                if ($managerDN) { $params["Manager"] = $managerDN }
            }

            try {
                New-ADUser @params
                Write-OK "Utilisateur cree : $($u.Login)"

                $groupName = "GG-$($u.Service)"
                if (Get-ADGroup -Filter "Name -eq '$groupName'" -ErrorAction SilentlyContinue) {
                    Add-ADGroupMember -Identity $groupName -Members $u.Login -ErrorAction SilentlyContinue
                    Write-Info "  -> ajoute au groupe $groupName"
                }
                Write-Log "AD: utilisateur $($u.Login) cree"
            } catch {
                Write-Warn "Erreur creation $($u.Login) : $_"
            }
        }
    } else {
        Write-Warn "AD-Users.csv introuvable dans $PSScriptRoot"
    }
}

function Invoke-All {
    Invoke-VirtIO
    Invoke-NetworkConfig
    Invoke-ICMPConfig
    Invoke-MachineIdentity
    if ($isServer) {
        Invoke-ServerRoles
        Invoke-ADDSPromotion
        Write-Warn "Si une promotion DC a ete effectuee, redemarrez puis relancez le script pour les blocs [7] et [8]."
    }
}

function Invoke-Reboot {
    Write-Host ""
    Write-Info "Journal : $($script:LogFile)"
    if ($script:NeedReboot) {
        Write-Host ""
        Write-Warn "Un redemarrage est necessaire pour appliquer tous les changements"
    }
    if (Confirm-Action "Redemarrer maintenant ?") {
        Write-Step "Redemarrage dans 5 secondes..."
        Start-Sleep 5
        Restart-Computer -Force
    }
}

do {
    Show-Menu
    $choice = (Read-Host "  Votre choix").Trim().ToUpper()

    switch ($choice) {
        "1" { Invoke-VirtIO }
        "2" { Invoke-NetworkConfig }
        "3" { Invoke-ICMPConfig }
        "4" { Invoke-MachineIdentity }
        "5" { if ($isServer) { Invoke-ServerRoles }      else { Write-Warn "Option reservee aux serveurs" } }
        "6" { if ($isServer) { Invoke-ADDSPromotion }    else { Write-Warn "Option reservee aux serveurs" } }
        "7" { if ($isServer) { Invoke-DNSReverseZones }  else { Write-Warn "Option reservee aux serveurs" } }
        "8" { if ($isServer) { Invoke-ADStructure }      else { Write-Warn "Option reservee aux serveurs" } }
        "0" { Invoke-All }
        "Q" { }
        default { Write-Warn "Choix invalide" }
    }

    if ($choice -ne "Q") {
        Write-Host ""
        Read-Host "  Appuyez sur Entree pour revenir au menu"
    }

} while ($choice -ne "Q")

Invoke-Reboot

Write-Host ""
Write-Host "  github.com/ExAzZe" -ForegroundColor Yellow
Write-Host ""
