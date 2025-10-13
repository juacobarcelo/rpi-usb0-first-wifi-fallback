<#  
  setup-ics-rndis.ps1
  -------------------
  Purpose:
    Enable Internet Connection Sharing (ICS) from the Internet-facing adapter
    to the Raspberry Pi RNDIS adapter, ensuring DHCP/NAT on 192.168.137.0/24.

  Requirements:
    - Run PowerShell AS ADMINISTRATOR.
    - Windows Firewall enabled (ICS depends on it).
    - RNDIS driver installed (adapter visible in Get-NetAdapter).
      If missing, install a "Remote NDIS Compatible Device" driver.
      Example driver source used successfully:
      https://github.com/dukelec/mbrush/tree/master/doc/win_driver

  Usage:
    PS> Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
    PS> .\scripts\setup-ics-rndis.ps1

  Adjust:
    - $Public  : name of the adapter that has Internet (e.g., "Ethernet", or your Wi‑Fi name)
    - $Private : name of the RNDIS adapter (e.g., "RNDIS-rpi")

  What it does:
    1) Ensures MpsSvc (Firewall) and SharedAccess (ICS) are running; enables firewall profiles.
    2) Clears any previous ICS bindings and binds ICS Public-> $Public  and Home-> $Private.
    3) Sets $Private network profile to Private.
    4) Verifies that $Private has IP 192.168.137.1 and that UDP/67 (DHCP) listener is active.
#>

param(
  [string]$Public  = "Ethernet",
  [string]$Private = "RNDIS-rpi"
)

Write-Host "==> Ensuring required services..." -ForegroundColor Cyan
Get-Service MpsSvc, SharedAccess | ForEach-Object {
  if ($_.Status -ne 'Running') { Start-Service $_.Name }
}
Set-NetFirewallProfile -All -Enabled True | Out-Null

Write-Host "==> Validating adapter names..." -ForegroundColor Cyan
$adapters = Get-NetAdapter | Select-Object -ExpandProperty Name
if ($adapters -notcontains $Public)  { throw "Adapter '$Public' not found." }
if ($adapters -notcontains $Private) { throw "Adapter '$Private' not found." }

Write-Host "==> Forcing ICS via HNetCfg.HNetShare..." -ForegroundColor Cyan
$share = New-Object -ComObject HNetCfg.HNetShare
function Get-Conn($name){ $share.EnumEveryConnection() | Where-Object { $share.NetConnectionProps($_).Name -eq $name } }
function Disable-All-Sharing {
  $share.EnumEveryConnection() | ForEach-Object {
    $cfg = $share.INetSharingConfigurationForINetConnection($_)
    if ($cfg.SharingEnabled) { $cfg.DisableSharing() | Out-Null }
  }
}

Stop-Service SharedAccess -ErrorAction SilentlyContinue
Disable-All-Sharing

$pub  = Get-Conn $Public   ; if (-not $pub)  { throw "Cannot resolve '$Public'." }
$priv = Get-Conn $Private  ; if (-not $priv) { throw "Cannot resolve '$Private'." }

# 0 = Public/NAT, 1 = Private/Home
$share.INetSharingConfigurationForINetConnection($pub ).EnableSharing(0)  | Out-Null
$share.INetSharingConfigurationForINetConnection($priv).EnableSharing(1) | Out-Null
Start-Service SharedAccess | Out-Null

Set-NetConnectionProfile -InterfaceAlias $Private -NetworkCategory Private | Out-Null

Write-Host "==> Checking RNDIS IP (expect 192.168.137.1)..." -ForegroundColor Cyan
Start-Sleep -Seconds 2
$ipInfo = Get-NetIPConfiguration -InterfaceAlias $Private
$ipInfo | Select-Object InterfaceAlias, IPv4Address, IPv4DefaultGateway, DnsServer | Format-List

if ($ipInfo.IPv4Address.IPAddress -ne '192.168.137.1') {
  Write-Warning "RNDIS not yet 192.168.137.1. Restarting adapter '$Private'..."
  Disable-NetAdapter -Name $Private -Confirm:$false
  Start-Sleep -Seconds 2
  Enable-NetAdapter  -Name $Private
  Start-Sleep -Seconds 2
  $ipInfo = Get-NetIPConfiguration -InterfaceAlias $Private
  $ipInfo | Select-Object InterfaceAlias, IPv4Address, IPv4DefaultGateway, DnsServer | Format-List
}

Write-Host "==> DHCP listener (UDP/67) status:" -ForegroundColor Cyan
Get-NetUDPEndpoint -LocalPort 67 | Format-Table LocalAddress,LocalPort,OwningProcess

Write-Host "✅ ICS ready. Windows will provide DHCP/NAT to the Pi via RNDIS." -ForegroundColor Green
