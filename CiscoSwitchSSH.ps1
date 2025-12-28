
function Get-UserInput {
    param (
        [string]$Prompt,
        [string]$Default = ''
    )
    $input = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
    return $input
}

function Invoke-CiscoCommand {
    param (
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [string]$Command = '',
        [int]$DelayMs = 2000
    )
    
    if ($Command) {
        $Stream.WriteLine($Command)
        $Stream.Flush()
    }
    
    Start-Sleep -Milliseconds $DelayMs
    
    $response = ''
    $start = Get-Date
    $maxSeconds = 40
    
    while (((Get-Date) - $start).TotalSeconds -lt $maxSeconds) {
        while ($Stream.DataAvailable) {
            $chunk = $Stream.Read()
            $response += $chunk
        }
        
    }
    
    return $response
}

function Manage-CiscoSwitch {
    Write-Host "`n=== Cisco Switch Management ===" -ForegroundColor Cyan

    $ip = Get-UserInput -Prompt 'Switch IP address' -Default '192.168.88.3'
    if (-not $ip) { Write-Host 'No IP provided. Exiting.' -ForegroundColor Red; return }

    $username = Get-UserInput -Prompt 'Username' -Default 'cisco'
    $password = Read-Host 'Password' -AsSecureString
    $credential = New-Object System.Management.Automation.PSCredential($username, $password)

    Write-Host "`nConnecting to $ip ..." -ForegroundColor Yellow

    $session = $null
    $stream = $null

    try {
        $session = New-SSHSession -ComputerName $ip -Credential $credential -AcceptKey -ConnectionTimeout 90000 -Verbose
        if (-not $session -or -not $session.Connected) {
            Write-Host 'Connection failed.' -ForegroundColor Red
            return
        }

        $stream = $session.Session.CreateShellStream('CiscoCLI', 80, 24, 0, 0, 10000)

        
        $initial = $stream.Read()

        # Enable mode
        $null = Invoke-CiscoCommand -Stream $stream -Command 'enable'
        $enableResp = Invoke-CiscoCommand -Stream $stream -Command ''
        if ($enableResp -match '(?i)password') {
            $plainPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
            $null = Invoke-CiscoCommand -Stream $stream -Command $plainPass
        }

        $null = Invoke-CiscoCommand -Stream $stream -Command 'terminal length 0'
        Write-Host 'Connected and in privileged mode.' -ForegroundColor Green

        while ($true) {
            Write-Host "`nMain Menu:" -ForegroundColor Cyan
            Write-Host '  1  - Check port status (show interfaces status)'
            Write-Host '  2  - Configure single port (enable/disable/description)'
            Write-Host '  3  - Export ports to CSV'
            Write-Host '  4  - Show VLAN overview (show vlan brief)'
            Write-Host '  5  - Show PoE status (show power inline)'
            Write-Host '  6  - Enable/Disable PoE on a port'
            Write-Host '  7  - Show IP interfaces brief'
            Write-Host '  8  - Bulk configure ports (list)'
            Write-Host '  exit - Quit'

            $choice = (Read-Host 'Select').Trim().ToLower()

            if ($choice -eq 'exit') { break }

            switch ($choice) {
                '1' {
                    Write-Host "`nPort status:" -ForegroundColor Cyan
                    $output = Invoke-CiscoCommand -Stream $stream -Command 'show interfaces status' -DelayMs 5000
                    Write-Host $output -ForegroundColor White
                }

                '2' {
                    $intf = Get-UserInput -Prompt 'Interface (e.g. Gi1/0/5) or back'
                    if ($intf.ToLower() -eq 'back') { continue }
                    if (-not $intf) { continue }

                    Write-Host '1=Enable  2=Disable  3=Description' -ForegroundColor Cyan
                    $action = Read-Host 'Action'

                    $null = Invoke-CiscoCommand -Stream $stream -Command 'conf t'
                    $null = Invoke-CiscoCommand -Stream $stream -Command "interface $intf"

                    switch ($action) {
                        '1' { $null = Invoke-CiscoCommand -Stream $stream -Command 'no shutdown' }
                        '2' { $null = Invoke-CiscoCommand -Stream $stream -Command 'shutdown' }
                        '3' {
                            $desc = Read-Host 'Description'
                            if ($desc) { $null = Invoke-CiscoCommand -Stream $stream -Command "description $desc" }
                        }
                    }

                    $null = Invoke-CiscoCommand -Stream $stream -Command 'end'
                    $null = Invoke-CiscoCommand -Stream $stream -Command 'write memory'
                    Write-Host 'Port updated.' -ForegroundColor Green
                }

                '3' {
                    $path = Read-Host 'CSV path (e.g. C:\ports.csv)'
                    if (-not $path) { continue }

                    $raw = Invoke-CiscoCommand -Stream $stream -Command 'show interfaces status' -DelayMs 6000

                    $ports = @()
                    $lines = $raw -split "`n"
                    $inTable = $false

                    foreach ($line in $lines) {
                        if ($line -match '^Port\s+Name\s+Status') { $inTable = $true; continue }
                        if ($inTable -and $line.Trim() -and $line -notmatch '^-+$') {
                            $fields = $line -split '\s{2,}'
                            if ($fields.Count -ge 7) {
                                $ports += New-Object PSObject -Property @{
                                    Port   = $fields[0]
                                    Name   = if ($fields.Count -gt 1) { $fields[1] } else { '' }
                                    Status = if ($fields.Count -gt 2) { $fields[2] } else { '' }
                                    Vlan   = if ($fields.Count -gt 3) { $fields[3] } else { '' }
                                    Duplex = if ($fields.Count -gt 4) { $fields[4] } else { '' }
                                    Speed  = if ($fields.Count -gt 5) { $fields[5] } else { '' }
                                    Type   = if ($fields.Count -gt 6) { $fields[6] } else { '' }
                                }
                            }
                        }
                    }

                    $ports | Export-Csv -Path $path -NoTypeInformation -Encoding UTF8
                    Write-Host "Exported $($ports.Count) ports to $path" -ForegroundColor Green
                }

                '4' {
                    Write-Host "`nVLAN overview:" -ForegroundColor Cyan
                    $vlan = Invoke-CiscoCommand -Stream $stream -Command 'show vlan brief' -DelayMs 3000
                    Write-Host $vlan -ForegroundColor White
                }

                '5' {
                    Write-Host "`nPoE status (show power inline):" -ForegroundColor Cyan
                    $poe = Invoke-CiscoCommand -Stream $stream -Command 'show power inline' -DelayMs 4000
                    Write-Host $poe -ForegroundColor White
                }

                '6' {
                    $intf = Get-UserInput -Prompt 'PoE interface (e.g. Gi1/0/5) or back'
                    if ($intf.ToLower() -eq 'back') { continue }
                    if (-not $intf) { continue }

                    Write-Host '1 = Enable PoE   2 = Disable PoE' -ForegroundColor Cyan
                    $poeAction = Read-Host 'Action'

                    $null = Invoke-CiscoCommand -Stream $stream -Command 'conf t'
                    $null = Invoke-CiscoCommand -Stream $stream -Command "interface $intf"

                    if ($poeAction -eq '1') {
                        $null = Invoke-CiscoCommand -Stream $stream -Command 'power inline auto'
                        Write-Host 'PoE enabled on port.' -ForegroundColor Green
                    } elseif ($poeAction -eq '2') {
                        $null = Invoke-CiscoCommand -Stream $stream -Command 'power inline never'
                        Write-Host 'PoE disabled on port.' -ForegroundColor Green
                    }

                    $null = Invoke-CiscoCommand -Stream $stream -Command 'end'
                    $null = Invoke-CiscoCommand -Stream $stream -Command 'write memory'
                }

                '7' {
                    Write-Host "`nIP interfaces brief:" -ForegroundColor Cyan
                    $ipBrief = Invoke-CiscoCommand -Stream $stream -Command 'show ip interface brief' -DelayMs 3000
                    Write-Host $ipBrief -ForegroundColor White
                }

                '8' {
                    Write-Host "`nBulk port config (enter interfaces separated by comma or back)" -ForegroundColor Cyan
                    $list = Get-UserInput -Prompt 'Interfaces (e.g. Gi1/0/1,Gi1/0/2)'
                    if ($list.ToLower() -eq 'back') { continue }

                    $interfaces = $list -split ','
                    Write-Host '1 = Enable all   2 = Disable all   3 = Set same description' -ForegroundColor Cyan
                    $bulkAction = Read-Host 'Action'

                    $null = Invoke-CiscoCommand -Stream $stream -Command 'conf t'

                    foreach ($intf in $interfaces) {
                        $intf = $intf.Trim()
                        if (-not $intf) { continue }
                        $null = Invoke-CiscoCommand -Stream $stream -Command "interface $intf"
                        switch ($bulkAction) {
                            '1' { $null = Invoke-CiscoCommand -Stream $stream -Command 'no shutdown' }
                            '2' { $null = Invoke-CiscoCommand -Stream $stream -Command 'shutdown' }
                            '3' {
                                $desc = Read-Host 'Description for all'
                                if ($desc) { $null = Invoke-CiscoCommand -Stream $stream -Command "description $desc" }
                            }
                        }
                    }

                    $null = Invoke-CiscoCommand -Stream $stream -Command 'end'
                    $null = Invoke-CiscoCommand -Stream $stream -Command 'write memory'
                    Write-Host 'Bulk config applied.' -ForegroundColor Green
                }

                default {
                    Write-Host 'Invalid option' -ForegroundColor Yellow
                }
            }
        }
    }
    catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($stream) { $stream.Close() }
        if ($session -and $session.Connected) { Remove-SSHSession -SessionId $session.SessionId }
        Write-Host 'Disconnected.' -ForegroundColor DarkGray
    }
}

Manage-CiscoSwitch