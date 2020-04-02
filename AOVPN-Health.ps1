<#
This Script assumes a few things,
1. There is only 1 AllUserConnection Vpn Profile on the Device
2. The first DomainNameInformation element (or NRPT element as it gets encoded into Windows), 
    and first DnsServers element address allows tcp DNS traffic
    a. This tcp connect is required to complete within 2 seconds (configurable) to be deemed a 'Up' tunnel
3. There is enough uniqueness in the tunnel name that it would not share an interfacealias attribute with another adapter

This script "can" easily be adapted to keep tunnels up on non Enterprise sku editions of Windows

Changing System Notice:
Because the RasMan service cannot be shutdown with service control manager, this script will change the default SharedProcess model of this service
on first encounter of a service issue to be in its own process. This limits the further potential for breaking issues with the Stop-Process of the 
svchost. My observation has been that nothing on a system runs in RasMan's svchost with it anyway, but regardless this ensures future runs where 
service restarts are required, there is no impact outside its specific service.

Code Descriptions:
0 = Connection is alive, no action taken
    This code net means tunnel is up
100 = No AllUserConnection profile found
    This code net means tunnel is down
(DISABLED CODE PATH) 110 = Unable to resolve dns of Vpn endpoint
    This code net means tunnel is down
200 = Post net connection change, tunnel needed to be forced down so auto up logic brings it up properly (when used with proper scheduled task event trigger)
    This code net means tunnel is up
300 = Even after tunnel force down, connection did not come up, research yielded this is a RasMan service issue so service is restarted to force always on logic to reset and connect
    This code net means tunnel is up
400 = Another net adapter is DomainAuthenticated in its NetConnectionProfile, not running logic
    This code net means tunnel is left alone as is
999 = All attempts to bring tunnel up have failed, no more logic left to run
    This code net means tunnel is down

To Do:
Could easily force tunnel down to hopefully have RasMan reevaluate trusted net configuration when DomainAuthenticated
#>


function Test-TcpConnection ($IpAddress,$Port) {
    $Socket=New-Object System.Net.Sockets.TcpClient
    $SocketState=$false
    try {
        $Result=$Socket.BeginConnect($IpAddress, $Port, $null, $null)
        if (!$Result.AsyncWaitHandle.WaitOne(2000, $false)) {
            throw [System.Exception]::new('Connection Timeout')
        }
        $Socket.EndConnect($Result) | Out-Null
        if ($Socket.Connected -eq $true) {$SocketState=$true}
    } `
    catch {} `
    finally {
        $Socket.Close()
    }

    $SocketRoute=Find-NetRoute -RemoteIPAddress $IpAddress

    [PSCustomObject]@{
        TcpTestSucceeded = $SocketState
        SourceAddress = $(try {$SocketRoute[0].IPAddress} catch {})
        InterfaceAlias = $(try {$SocketRoute[1].InterfaceAlias} catch {})
    }
}

$VpnConnection=Get-VpnConnection -AllUserConnection | Select-Object -First 1

if (!$VpnConnection) {
    exit 100
}

if (Get-NetConnectionProfile -NetworkCategory DomainAuthenticated | Where-Object {$_.InterfaceAlias -ne $VpnConnection.Name}) {
    exit 400
}

$TestServerAddress=(
    $VpnConnection.VpnConfigurationXml.VpnProfile.VpnConfiguration | `
        Select-Xml -XPath '//NrptRuleList' | `
            ForEach-Object {$_.Node}
).DnsServer[0]

if ($VpnConnection.ConnectionStatus -eq 'Connected') {
    $LinkStatus=Test-TcpConnection -Port 53 -IpAddress $TestServerAddress
    if ($LinkStatus.TcpTestSucceeded -eq $true -and $LinkStatus.InterfaceAlias -eq $VpnConnection.Name) {
        exit 0
    }
    rasdial.exe "$($VpnConnection.Name)" /DISCONNECT
    Start-Sleep -Seconds 4
}

$LinkStatus=Test-TcpConnection -Port 53 -IpAddress $TestServerAddress
if ($LinkStatus.TcpTestSucceeded -eq $true -and $LinkStatus.InterfaceAlias -eq $VpnConnection.Name) {
    Start-Sleep -Seconds 15
    exit 200
}

# try {
#     Resolve-DnsName $VpnConnection.ServerAddress -ErrorAction Stop
# } `
# catch {
#     exit 110
# }

$ServiceName='RasMan'
$Service=Get-Service $ServiceName
if ($Service.ServiceType -ne 'Win32OwnProcess') {
    sc.exe config $ServiceName type=own
}

$CimService=Get-CimInstance Win32_Service -Filter "Name = '$ServiceName'"
if ($CimService.ProcessId -ne 0) {
    Stop-Process -Force -Id $CimService.ProcessId
}

Start-Service $ServiceName
Start-Sleep -Seconds 4

$LinkStatus=Test-TcpConnection -Port 53 -IpAddress $TestServerAddress
if ($LinkStatus.TcpTestSucceeded -eq $true -and $LinkStatus.InterfaceAlias -eq $VpnConnection.Name) {
    Start-Sleep -Seconds 15
    exit 300
}
exit 999
