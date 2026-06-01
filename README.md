# Windows-init-script

PowerShell script to automate the initial configuration of Windows virtual machines (Server & Client) running on KVM/QEMU with VirtIO.

## Requirements

- Windows Server 2016/2019/2022 or Windows 10/11
- Run as Administrator
- Both files in the same folder

## Usage

Run `StartScript.bat` — it launches `ScriptVM.ps1` with execution policy bypass.

## What it does

1. **Detects the OS** — adapts behavior for Windows Server vs Client
2. **VirtIO drivers** — detects the mounted ISO, checks if already installed, installs silently (`/S`)
3. **Network** — sets all profiles to Private, configure IP/prefix/gateway/DNS on one or multiple interfaces
4. **Firewall** — optionally allows inbound ICMPv4 (ping)
5. **Identity** — rename the machine and/or join an Active Directory domain
6. **Server roles** *(Server only)* — interactive menu to install roles:

   | # | Role |
   |---|------|
   | 1 | AD DS |
   | 2 | DNS |
   | 3 | DHCP |
   | 4 | ADCS (PKI) |
   | 5 | IIS |
   | 6 | File Server + DFS |
   | 7 | Print Server |
   | 8 | RDS (RDSH) |
   | 9 | Hyper-V |

   After installing AD DS, the script offers to promote the server to a Domain Controller (new forest, additional DC, or child domain).

7. **Reboot** — prompts to restart when required

A timestamped log is saved to `C:\vm-setup-YYYYMMDD-HHmmss.log`.

## Notes

- If a rename is pending, DC promotion is blocked until after reboot
- VirtIO silent flag is `/S` (NSIS installer) — tested with `virtio-win-0.1.285`
- Rename + domain join are combined into a single `Add-Computer` call to avoid two reboots
