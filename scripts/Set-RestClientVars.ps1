<#
    .SYNOPSIS
        เขียนตัวแปรร่วมของชุดเทสต์ลง .vscode/settings.json ให้ VS Code REST Client อ่านได้

    .DESCRIPTION
        REST Client (humao.rest-client) ไม่อ่านไฟล์ http-client.env หรือไฟล์ env
        อื่นใด ๆ ตัวแปรที่มันรู้จักมีสามทางเท่านั้น
          1. บรรทัด "@name = value" ที่ประกาศไว้ในไฟล์ .http ที่เปิดอยู่
          2. system variable เช่น {{$dotenv x}} / {{$processEnv x}}
          3. setting "rest-client.environmentVariables" ใน .vscode/settings.json
        ถ้าไม่มีทางใด ตัวแปรจะถูกทิ้งไว้เป็นข้อความ {{name}} ตรง ๆ ในบรรทัดคำขอ
        URL จึงไม่มี host/port และทุกคำขอจะล้มด้วย ECONNREFUSED

        ฟังก์ชันนี้เขียนตัวแปรทั้งหมดไว้ใต้ "$shared" ซึ่ง REST Client อ่านได้แม้ไม่ต้อง
        เลือก environment ใด ๆ (เลือก "No Environment") จึงไม่ต้องแก้ไฟล์ .http
        แม้แต่ไฟล์เดียว และเขียนทับเฉพาะคีย์นี้ คีย์อื่นในไฟล์เดิมยังอยู่ครบ

    .PARAMETER Root
        รากโปรเจกต์ ค่าเริ่มต้นคือโฟลเดอร์ที่ครอบ scripts/

    .PARAMETER Vars
        ตารางคีย์/ค่าของตัวแปร คีย์ที่รู้จักคือ baseUrl, session, securityLevel,
        bwappUser, bwappPass, beeHash, authCookie

    .EXAMPLE
        . .\scripts\Set-RestClientVars.ps1
        Set-RestClientVars -Vars @{ baseUrl = 'http://127.0.0.1:8443'; authCookie = 'PHPSESSID=abc; security_level=0' }
#>

# ConvertTo-Json ของ PowerShell 5.1 จัดวางเยื้องยะแบบเหลื่อมกับ JSON ที่อ่านยาก
# ฟังก์ชันนี้เขียน JSON เอง ได้การเยื้อง 4 ช่องต่อระดับแบบเบี้ยบเบียน
function ConvertTo-JsonText {
    param($Value, [int]$Indent = 0)

    $pad = ' ' * $Indent
    $padInner = ' ' * ($Indent + 4)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (ConvertTo-Json -InputObject $Value -Compress) }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return "$Value" }

    $items = @()
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $name = ConvertTo-Json -InputObject ([string]$key) -Compress
            $items += "$padInner$name : $(ConvertTo-JsonText $Value[$key] ($Indent + 4))"
        }
        if ($items.Count -eq 0) { return '{}' }
        return "{`n" + ($items -join ",`n") + "`n$pad}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($item in $Value) { $items += "$padInner$(ConvertTo-JsonText $item ($Indent + 4))" }
        if ($items.Count -eq 0) { return '[]' }
        return "[`n" + ($items -join ",`n") + "`n$pad]"
    }
    foreach ($prop in $Value.PSObject.Properties) {
        $name = ConvertTo-Json -InputObject $prop.Name -Compress
        $items += "$padInner$name : $(ConvertTo-JsonText $prop.Value ($Indent + 4))"
    }
    if ($items.Count -eq 0) { return '{}' }
    return "{`n" + ($items -join ",`n") + "`n$pad}"
}

function Set-RestClientVars {
    [CmdletBinding()]
    param(
        [string]$Root,
        [hashtable]$Vars
    )

    if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
    $dir = Join-Path $Root '.vscode'
    $file = Join-Path $dir 'settings.json'

    # อ่านคีย์เดิมที่มีอยู่ก่อน เพื่อไม่ไปทับการตั้งค่าอื่นของผู้ใช้
    $settings = [ordered]@{}
    if (Test-Path $file) {
        try {
            $existing = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $existing.PSObject.Properties) { $settings[$prop.Name] = $prop.Value }
        } catch {
            Write-Warning "อ่าน $file ไม่ได้ จะเขียนทับเป็นไฟล์ใหม่"
        }
    }

    $shared = [ordered]@{}
    foreach ($key in @('baseUrl', 'session', 'securityLevel', 'bwappUser', 'bwappPass', 'beeHash', 'authCookie')) {
        if ($Vars -and $Vars.ContainsKey($key)) { $shared[$key] = [string]$Vars[$key] }
    }
    $settings['rest-client.environmentVariables'] = [ordered]@{ '$shared' = $shared }

    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($file, ((ConvertTo-JsonText $settings) + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    return $file
}