
Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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

$script:LogFile = "$env:SystemDrive\vm-setup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
function Write-Log {
    param([string]$Msg)
    "$(Get-Date -Format 'HH:mm:ss') | $Msg" | Add-Content -Path $script:LogFile
}

$script:NeedReboot   = $false
$script:DomainJoined = $null

Write-Banner "Détection du système"

$os          = Get-CimInstance Win32_OperatingSystem
$productType = $os.ProductType
$isServer    = ($productType -ge 2)
$osCaption   = $os.Caption

Write-Info "Système  : $osCaption"
Write-Info "Build    : $($os.BuildNumber)"
Write-Info "Type     : $(if ($isServer) { 'Windows Server' } else { 'Windows Client' })"
Write-Log  "OS=$osCaption | isServer=$isServer"

Write-Banner "Pilotes VirtIO"

$virtioExe = $null
foreach ($disk in (Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 5 })) {
    $candidate = "$($disk.DeviceID)\virtio-win-guest-tools.exe"
    if (Test-Path $candidate) {
        $virtioExe = $candidate
        break
    }
}

if ($virtioExe) {
    Write-Info "Exécutable détecté : $virtioExe"

    $installed = Get-ChildItem `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" `
        -ErrorAction SilentlyContinue |
        Get-ItemProperty -ErrorAction SilentlyContinue |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like "*VirtIO*" } |
        Select-Object -First 1

    if ($installed) {
        Write-OK "Déjà installé : $($installed.DisplayName) v$($installed.DisplayVersion)"
        Write-Log "VirtIO: déjà installé v$($installed.DisplayVersion)"
    }
    elseif (Confirm-Action "Installer les pilotes VirtIO (mode silencieux) ?") {
        Write-Step "Installation en cours (/S)..."
        $proc = Start-Process -FilePath $virtioExe -ArgumentList "/S" -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-OK "Pilotes installés avec succès"
            Write-Log "VirtIO: installé"
        }
        else {
            Write-Warn "Code de sortie $($proc.ExitCode) - vérifier manuellement"
            Write-Log  "VirtIO: échec code=$($proc.ExitCode)"
        }
    }
}
else {
    Write-Info "Aucun disque VirtIO monté (lecteur CD/DVD avec virtio-win-guest-tools.exe)"
}

Write-Banner "Configuration réseau"

Write-Step "Passage de tous les profils réseau en Privé..."
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
Write-OK "Profils réseau -> Privé"
Write-Log "Réseau: profils -> Private"

Write-Info "Interfaces disponibles :"
Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, MacAddress -AutoSize

while (Confirm-Action "Configurer l'adresse IP d'une interface ?") {
    Write-Host ""
    Get-NetAdapter | Format-Table Name, Status -AutoSize

    $alias = (Read-Host "  Nom de l'interface (ex: Ethernet0)").Trim()

    $adapter = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Write-Warn "Interface '$alias' introuvable, annulé"
        continue
    }

    $ip     = (Read-Host "  Adresse IP").Trim()
    $prefix = (Read-Host "  Longueur de préfixe (ex: 24)").Trim()
    $gw     = (Read-Host "  Passerelle par défaut").Trim()
    $dns1   = (Read-Host "  DNS primaire").Trim()
    $dns2   = (Read-Host "  DNS secondaire  (Entrée pour ignorer)").Trim()

    Write-Step "Application de la configuration sur '$alias'..."

    Remove-NetIPAddress -InterfaceAlias $alias -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute     -InterfaceAlias $alias -DestinationPrefix "0.0.0.0/0" `
                        -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceAlias $alias -IPAddress $ip `
                     -PrefixLength ([int]$prefix) -DefaultGateway $gw | Out-Null

    $dnsServers = if ($dns2) { @($dns1, $dns2) } else { @($dns1) }
    Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $dnsServers

    Write-OK "$alias : $ip/$prefix  GW=$gw  DNS=$($dnsServers -join ', ')"
    Write-Log "IP: alias=$alias ip=$ip/$prefix gw=$gw dns=$($dnsServers -join ',')"
}

if (Confirm-Action "Autoriser le ping entrant (ICMP v4) ?") {
    Set-NetFirewallRule -Name "FPS-ICMP4-ERQ-In" -Enabled True
    Write-OK "Règle pare-feu ICMP v4 activée"
    Write-Log "ICMP v4: activé"
}

Write-Banner "Identité machine"

Write-Info "Nom actuel : $env:COMPUTERNAME"

$newComputerName = $null
if (Confirm-Action "Renommer cette machine ?") {
    $newComputerName = (Read-Host "  Nouveau nom").Trim()
}

if (Confirm-Action "Joindre un domaine Active Directory ?") {
    $script:DomainJoined = (Read-Host "  Nom du domaine (ex: TSSR110-ML.LCL)").Trim()
    Write-Step "Saisir les credentials d'un compte autorisé à joindre le domaine..."
    $domainCred = Get-Credential

    $addParams = @{
        DomainName = $script:DomainJoined
        Credential = $domainCred
        Force      = $true
    }
    if ($newComputerName) { $addParams["NewName"] = $newComputerName }

    Add-Computer @addParams
    Write-OK "Machine ajoutée au domaine '$($script:DomainJoined)'"
    if ($newComputerName) { Write-OK "Sera renommée '$newComputerName' après redémarrage" }
    Write-Log "Domaine: $($script:DomainJoined) | NouveauNom=$newComputerName"

    $newComputerName    = $null
    $script:NeedReboot  = $true
}

if ($newComputerName) {
    Rename-Computer -NewName $newComputerName -Force
    Write-OK "Renommage '$newComputerName' programmé pour le prochain redémarrage"
    Write-Log "Renommage: $env:COMPUTERNAME -> $newComputerName"
    $script:NeedReboot = $true
}

if ($isServer) {
    Write-Banner "Rôles Windows Server"

    $roles = [ordered]@{
        "1" = @{
            Label = "AD DS     - Active Directory Domain Services"
            Feats = @("AD-Domain-Services")
        }
        "2" = @{
            Label = "DNS       - Serveur DNS"
            Feats = @("DNS")
        }
        "3" = @{
            Label = "DHCP      - Serveur DHCP"
            Feats = @("DHCP")
        }
        "4" = @{
            Label = "ADCS      - Autorité de certification (PKI)"
            Feats = @("AD-Certificate","ADCS-Cert-Authority")
        }
        "5" = @{
            Label = "IIS       - Serveur Web (+ console de gestion)"
            Feats = @("Web-Server","Web-Common-Http","Web-Mgmt-Console")
        }
        "6" = @{
            Label = "FS + DFS  - Serveur de fichiers + espaces de noms DFS"
            Feats = @("FS-FileServer","FS-DFS-Namespace","FS-DFS-Replication")
        }
        "7" = @{
            Label = "Print     - Serveur d'impression"
            Feats = @("Print-Server")
        }
        "8" = @{
            Label = "RDSH      - Hôte de session Bureau à distance"
            Feats = @("RDS-RD-Server")
        }
        "9" = @{
            Label = "Hyper-V   - Hyperviseur"
            Feats = @("Hyper-V")
        }
    }

    Write-Host "  Rôles disponibles :`n"
    foreach ($k in $roles.Keys) {
        Write-Host ("    [{0}]  {1}" -f $k, $roles[$k].Label)
    }
    Write-Host ""

    $sel = (Read-Host "  Numéros à installer (ex: 1,2,3) ou N pour ignorer").Trim()

    if ($sel -notmatch '^[Nn]$') {
        foreach ($k in ($sel -split "," | ForEach-Object { $_.Trim() })) {

            if (-not $roles.Contains($k)) {
                Write-Warn "Numéro '$k' invalide, ignoré"
                continue
            }

            $label = $roles[$k].Label
            $feats = $roles[$k].Feats

            Write-Step "Installation : $label"
            Install-WindowsFeature -Name $feats -IncludeManagementTools `
                                   -IncludeAllSubFeature | Out-Null
            Write-OK "$label installé"
            Write-Log "Rôle: $label"

            if ($k -eq "1" -and (Confirm-Action "Promouvoir ce serveur en contrôleur de domaine ?")) {
                if ($script:NeedReboot) {
                    Write-Warn "Un redémarrage est en attente (renommage ou jonction). La promotion doit être effectuée après le redémarrage."
                    Write-Warn "Relancez le script après le redémarrage et choisissez uniquement la promotion DC."
                } else {
                $dcMode = (Read-Host "  [1] Nouvelle forêt  [2] DC additionnel  [3] Domaine enfant").Trim()
                $dsrm   = Read-Host "  Mot de passe DSRM (mode restauration)" -AsSecureString

                switch ($dcMode) {
                    "1" {
                        $forest = (Read-Host "  Nom de la forêt (ex: MONDOMAINE.LCL)").Trim()
                        Install-ADDSForest `
                            -DomainName $forest `
                            -SafeModeAdministratorPassword $dsrm `
                            -InstallDns:$true -Force
                        Write-Log "ADDS: nouvelle forêt=$forest"
                    }
                    "2" {
                        $existDom = if ($script:DomainJoined) { $script:DomainJoined }
                                    else { (Read-Host "  Nom du domaine existant").Trim() }
                        $cred2 = Get-Credential
                        Install-ADDSDomainController `
                            -DomainName $existDom `
                            -SafeModeAdministratorPassword $dsrm `
                            -Credential $cred2 -Force
                        Write-Log "ADDS: DC additionnel domaine=$existDom"
                    }
                    "3" {
                        $parent    = (Read-Host "  Domaine parent").Trim()
                        $childName = (Read-Host "  Nom du domaine enfant (label seul, ex: CHILD)").Trim()
                        $cred2     = Get-Credential
                        Install-ADDSDomain `
                            -ParentDomainName $parent `
                            -NewDomainName $childName `
                            -SafeModeAdministratorPassword $dsrm `
                            -Credential $cred2 -Force
                        Write-Log "ADDS: domaine enfant=$childName parent=$parent"
                    }
                    default { Write-Warn "Choix invalide - promotion ignorée" }
                }
                $script:NeedReboot = $true
                } 
            }

            if ($k -eq "3") {
                $dhcpFqdn = if ($script:DomainJoined) {
                    "$env:COMPUTERNAME.$($script:DomainJoined)"
                }
                else { $env:COMPUTERNAME }

                Write-Info "Pour autoriser le serveur DHCP dans AD :"
                Write-Info "  Add-DhcpServerInDC -DnsName '$dhcpFqdn'"
                Write-Info "  Penser à créer une étendue : Add-DhcpServerv4Scope ..."

                if ($script:DomainJoined -and (Confirm-Action "Autoriser ce serveur DHCP dans AD maintenant ?")) {
                    $cred3 = Get-Credential "Compte admin du domaine"
                    Add-DhcpServerInDC -DnsName $dhcpFqdn -Credential $cred3 -ErrorAction SilentlyContinue
                    Write-OK "Serveur DHCP autorisé dans AD"
                    Write-Log "DHCP: autorisé dans AD"
                }
            }
        }
    }
}

Write-Banner "Configuration terminée"

Write-Info "Journal sauvegardé : $($script:LogFile)"
Write-Host ""

if ($script:NeedReboot) {
    Write-Warn "Un redémarrage est nécessaire pour appliquer tous les changements"
}

if (Confirm-Action "Redémarrer maintenant ?") {
    Write-Step "Redémarrage dans 5 secondes..."
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}
else {
    Write-OK "Prêt. Redémarrez manuellement quand vous êtes prêt."
}
