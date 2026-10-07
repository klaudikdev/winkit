# Network tools: cloud region latency, DNS benchmark and DNS switching.

function Measure-WKTcpLatency {
    <#
        Measures TCP handshake time to an already resolved address. The best
        of several samples is the closest estimate of network round-trip time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Net.IPAddress]$Address,
        [int]$Port = 443,
        [int]$Samples = 3,
        [int]$TimeoutMs = 2000
    )

    $best = $null
    for ($i = 0; $i -lt $Samples; $i++) {
        $client = New-Object System.Net.Sockets.TcpClient($Address.AddressFamily)
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $task = $client.ConnectAsync($Address, $Port)
            $done = $task.Wait($TimeoutMs)
            $sw.Stop()
            if ($done -and $client.Connected) {
                $ms = $sw.Elapsed.TotalMilliseconds
                if ($null -eq $best -or $ms -lt $best) { $best = $ms }
            }
        }
        catch { }
        finally { $client.Dispose() }
    }
    if ($null -eq $best) { return $null }
    return [math]::Round($best)
}

function Test-WKCloudLatency {
    <# Background entry point. #>
    [CmdletBinding()]
    param()

    $targets = @($WK.Config.Network.latencyTargets)
    Write-WKLog "Measuring latency to $($targets.Count) cloud regions" -Level Step
    $results = foreach ($t in $targets) {
        $ms = $null
        try {
            $address = [System.Net.Dns]::GetHostAddresses($t.host) |
                       Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            if ($address) { $ms = Measure-WKTcpLatency -Address $address -Port $t.port }
        }
        catch { }
        $text = if ($null -ne $ms) { "$ms ms" } else { 'unreachable' }
        Write-WKLog ("  {0,-13} {1,-15} {2}" -f $t.provider, $t.location, $text)
        [pscustomobject]@{
            Provider = $t.provider
            Region   = $t.region
            Location = $t.location
            Host     = $t.host
            Ms       = $ms
        }
    }
    $best = $results | Where-Object { $null -ne $_.Ms } | Sort-Object Ms | Select-Object -First 1
    if ($best) { Write-WKLog "Closest region: $($best.Provider) $($best.Location) ($($best.Ms) ms)" -Level Success }
    else { Write-WKLog 'No region could be reached. Check your internet connection.' -Level Warning }
    return @($results)
}

#region DNS

function Get-WKActiveAdapters {
    <#
        Connected adapters that carry IP traffic: physical ones, plus the
        Hyper-V virtual adapter that takes over a physical NIC's IP settings
        when an external switch is used. VPN and other virtual adapters are
        left alone.
    #>
    [CmdletBinding()]
    param()
    $connected = @(Get-NetIPInterface -AddressFamily IPv4 -ConnectionState Connected -ErrorAction SilentlyContinue | ForEach-Object { $_.ifIndex })
    @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.Status -eq 'Up' -and $connected -contains $_.ifIndex -and
        ($_.HardwareInterface -or "$($_.InterfaceDescription)".StartsWith('Hyper-V Virtual Ethernet Adapter', [StringComparison]::OrdinalIgnoreCase))
    })
}

function Get-WKPrimaryInterfaceIndex {
    [CmdletBinding()]
    param()
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
             Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
    if ($route) { return $route.InterfaceIndex }
    return $null
}

function Get-WKDnsSetting {
    <#
        Reads the configured (not the effective) DNS servers of an adapter.
        An empty list means "obtain automatically".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InterfaceGuid)

    $v4 = Get-WKRegistryValue -Path "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$InterfaceGuid" -Name 'NameServer'
    $v6 = Get-WKRegistryValue -Path "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$InterfaceGuid" -Name 'NameServer'
    $split = { param($r) if ($r.Exists -and "$($r.Value)".Trim()) { @("$($r.Value)" -split '[,\s]+' | Where-Object { $_ }) } else { @() } }
    [pscustomobject]@{
        v4 = @(& $split $v4)
        v6 = @(& $split $v6)
    }
}

function Format-WKDnsSetting {
    [CmdletBinding()]
    param($Setting)
    if (-not $Setting) { return 'unknown' }
    $all = @($Setting.v4) + @($Setting.v6) | Where-Object { $_ }
    if (-not $all) { return 'Automatic (DHCP)' }
    return ($all -join ', ')
}

function Test-WKDnsSettingEqual {
    [CmdletBinding()]
    param($A, $B)
    return ((@($A.v4) -join ',') -eq (@($B.v4) -join ',')) -and ((@($A.v6) -join ',') -eq (@($B.v6) -join ','))
}

function Resolve-WKInterfaceIndex {
    [CmdletBinding()]
    param([string]$InterfaceGuid, [int]$InterfaceIndex)
    # Only by GUID: interface numbers are reused, so a stale number from
    # History could point at a different adapter, such as a VPN.
    if ($InterfaceGuid) {
        $adapter = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq $InterfaceGuid } | Select-Object -First 1
        if ($adapter) { return $adapter.ifIndex }
    }
    throw 'The network adapter is no longer present (unplugged or removed).'
}

function Set-WKDnsSetting {
    [CmdletBinding()]
    param(
        [int]$InterfaceIndex,
        [string]$InterfaceGuid,
        [Parameter(Mandatory)]$Setting
    )

    $index = Resolve-WKInterfaceIndex -InterfaceGuid $InterfaceGuid -InterfaceIndex $InterfaceIndex
    # Reset first so a family that should be automatic really goes back to DHCP.
    Set-DnsClientServerAddress -InterfaceIndex $index -ResetServerAddresses -ErrorAction Stop
    $servers = @(@($Setting.v4) + @($Setting.v6) | Where-Object { $_ })
    if ($servers.Count) {
        Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $servers -ErrorAction Stop
    }
}

function Get-WKDnsOverview {
    <# Background entry point: DNS configuration of every connected adapter. #>
    [CmdletBinding()]
    param()

    $providers = @($WK.Config.Network.dnsProviders)
    foreach ($a in Get-WKActiveAdapters) {
        $setting = Get-WKDnsSetting -InterfaceGuid $a.InterfaceGuid
        $match = $providers | Where-Object { (@($_.ipv4) -join ',') -eq (@($setting.v4) -join ',') } | Select-Object -First 1
        $effective = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                       ForEach-Object ServerAddresses)
        [pscustomobject]@{
            Alias      = $a.Name
            Index      = $a.ifIndex
            Guid       = $a.InterfaceGuid
            Setting    = $setting
            Provider   = if (-not @($setting.v4).Count) { 'Automatic' } elseif ($match) { $match.name } else { 'Custom' }
            Effective  = $effective
        }
    }
}

function Set-WKDnsProvider {
    <# Background entry point. $ProviderId 'automatic' returns every adapter to DHCP. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProviderId,
        [switch]$Preview
    )

    if ($ProviderId -eq 'automatic') {
        $name = 'Automatic (DHCP)'
        $target = [pscustomobject]@{ v4 = @(); v6 = @() }
    }
    else {
        $provider = @($WK.Config.Network.dnsProviders) | Where-Object { $_.id -eq $ProviderId } | Select-Object -First 1
        if (-not $provider) { throw "Unknown DNS provider '$ProviderId'." }
        $name = $provider.name
        $target = [pscustomobject]@{ v4 = @($provider.ipv4); v6 = @($provider.ipv6) }
    }

    $result = [pscustomobject]@{ Changed = 0; Failed = 0; Skipped = 0 }
    Write-WKLog "Switching DNS to $name" -Level Step
    if ($ProviderId -ne 'automatic' -and (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).PartOfDomain) {
        # Company networks resolve their own names through their own DNS servers.
        Write-WKLog 'This PC is joined to a domain. A public DNS server cannot resolve your organization''s names, so DNS was not changed.' -Level Error
        $result.Failed = 1
        return $result
    }
    $adapters = @(Get-WKActiveAdapters)
    if (-not $adapters.Count) { Write-WKLog 'No connected network adapter was found' -Level Warning; return $result }

    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($a in $adapters) {
        $before = Get-WKDnsSetting -InterfaceGuid $a.InterfaceGuid
        $ip4 = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ProviderId -eq 'automatic' -and $ip4 -and "$($ip4.Dhcp)" -eq 'Disabled' -and @($before.v4).Count) {
            # Without DHCP there is nobody to hand out DNS servers.
            Write-WKLog "  $($a.Name) uses a fixed IP address, so its DNS servers were left as they are"
            $result.Skipped++
            continue
        }
        # IPv6 servers only where IPv6 is turned on.
        $hasV6 = [bool](Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue)
        $adapterTarget = [pscustomobject]@{ v4 = @($target.v4); v6 = if ($hasV6) { @($target.v6) } else { @($before.v6) } }
        if (Test-WKDnsSettingEqual $before $adapterTarget) { Write-WKLog "  $($a.Name) already uses $name"; continue }
        $change = [pscustomobject]@{
            type           = 'dns'
            interfaceIndex = $a.ifIndex
            interfaceGuid  = $a.InterfaceGuid
            alias          = $a.Name
            before         = $before
            after          = $adapterTarget
        }
        if ($Preview) { Write-WKLog "  [Preview] $(Format-WKChange $change)"; continue }
        try {
            Set-WKDnsSetting -InterfaceGuid $a.InterfaceGuid -InterfaceIndex $a.ifIndex -Setting $adapterTarget
            $changes.Add($change)
            $result.Changed++
            Write-WKLog "  $(Format-WKChange $change)"
        }
        catch {
            $result.Failed++
            Write-WKLog "  $($a.Name): $($_.Exception.Message)" -Level Error
            # The reset may have gone through before the failure; put the
            # previous servers back, and keep a history entry if that fails too.
            try {
                Set-WKDnsSetting -InterfaceGuid $a.InterfaceGuid -InterfaceIndex $a.ifIndex -Setting $before
                Write-WKLog "  $($a.Name): previous DNS servers restored"
            }
            catch {
                $changes.Add($change)
                Write-WKLog "  $($a.Name): could not restore the previous DNS servers. Use History to retry." -Level Error
            }
        }
    }

    if ($changes.Count) {
        Add-WKHistoryEntry -Kind dns -RefId 'dns' -Title "DNS: $name" -Changes $changes.ToArray() | Out-Null
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    }
    if ($result.Changed -and -not $result.Failed) { Write-WKLog "DNS is now $name" -Level Success }
    elseif ($result.Failed) { Write-WKLog "DNS could not be changed on $(Format-WKCount $result.Failed 'adapter')" -Level Warning }
    return $result
}

function Measure-WKDnsServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string[]]$Domains
    )

    $times = New-Object System.Collections.Generic.List[double]
    $failures = 0
    foreach ($d in $Domains) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $null = Resolve-DnsName -Name $d -Server $Server -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
            $sw.Stop()
            $times.Add($sw.Elapsed.TotalMilliseconds)
        }
        catch { $failures++ }
    }
    if (-not $times.Count) { return [pscustomobject]@{ Ms = $null; Failures = $failures } }
    $sorted = @($times | Sort-Object)
    $median = $sorted[[math]::Floor(($sorted.Count - 1) / 2)]
    return [pscustomobject]@{ Ms = [math]::Round($median); Failures = $failures }
}

function Test-WKDnsBenchmark {
    <# Background entry point. #>
    [CmdletBinding()]
    param()

    $domains = @($WK.Config.Network.dnsBenchmarkDomains)
    $candidates = New-Object System.Collections.Generic.List[object]

    $primary = Get-WKPrimaryInterfaceIndex
    if ($primary) {
        $current = Get-DnsClientServerAddress -InterfaceIndex $primary -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   ForEach-Object ServerAddresses | Select-Object -First 1
        if ($current) { $candidates.Add([pscustomobject]@{ Id = 'current'; Name = "Current ($current)"; Server = $current }) }
    }
    foreach ($p in @($WK.Config.Network.dnsProviders)) {
        $candidates.Add([pscustomobject]@{ Id = $p.id; Name = $p.name; Server = @($p.ipv4)[0] })
    }

    Write-WKLog "Benchmarking $($candidates.Count) DNS resolvers" -Level Step
    $results = foreach ($c in $candidates) {
        $m = Measure-WKDnsServer -Server $c.Server -Domains $domains
        $text = if ($null -ne $m.Ms) { "$($m.Ms) ms" } else { 'no response' }
        Write-WKLog ("  {0,-24} {1}" -f $c.Name, $text)
        [pscustomobject]@{ Id = $c.Id; Name = $c.Name; Server = $c.Server; Ms = $m.Ms; Failures = $m.Failures }
    }
    $best = $results | Where-Object { $null -ne $_.Ms -and $_.Id -ne 'current' } | Sort-Object Ms | Select-Object -First 1
    if ($best) { Write-WKLog "Fastest public resolver: $($best.Name) ($($best.Ms) ms)" -Level Success }
    return @($results)
}

function Clear-WKDnsCache {
    [CmdletBinding()]
    param()
    Clear-DnsClientCache -ErrorAction Stop
    Write-WKLog 'DNS cache flushed' -Level Success
}

#endregion
