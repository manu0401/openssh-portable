﻿If ($PSVersiontable.PSVersion.Major -le 2) {$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path}
Import-Module $PSScriptRoot\CommonUtils.psm1 -Force
$tC = 1
$tI = 0
$suite = "sshdConfig"
Describe "Tests of sshd_config" -Tags "CI" {
    BeforeAll {
        if($OpenSSHTestInfo -eq $null)
        {
            Throw "`$OpenSSHTestInfo is null. Please run Set-OpenSSHTestEnvironment to set test environments."
        }
        
        $testDir = "$($OpenSSHTestInfo["TestDataPath"])\$suite"
        if( -not (Test-path $testDir -PathType Container))
        {
            $null = New-Item $testDir -ItemType directory -Force -ErrorAction SilentlyContinue
        }        

        $sshLogName = "test.txt"
        $sshdLogName = "sshdlog.txt"
        $server = $OpenSSHTestInfo["Target"]
        $opensshbinpath = $OpenSSHTestInfo['OpenSSHBinPath']
        $port = 47003
        $sshdDelay = $OpenSSHTestInfo["DelayTime"]        
        Remove-Item -Path (Join-Path $testDir "*$sshLogName") -Force -ErrorAction SilentlyContinue

        Add-Type -AssemblyName System.DirectoryServices.AccountManagement
        $ContextName = $env:COMPUTERNAME
        $ContextType = [System.DirectoryServices.AccountManagement.ContextType]::Machine
        $PrincipalContext = new-object -TypeName System.DirectoryServices.AccountManagement.PrincipalContext -ArgumentList @($ContextType, $ContextName)
        $IdentityType = [System.DirectoryServices.AccountManagement.IdentityType]::SamAccountName     
        
        #prepare custom sshd_config
        $sshdconfig_ori = Join-Path $Global:OpenSSHTestInfo["ServiceConfigDir"] sshd_config
        $sshdconfig_custom = Join-Path $Global:OpenSSHTestInfo["ServiceConfigDir"] sshd_config_custom
        if (Test-Path $sshdconfig_custom) {
            Remove-Item $sshdconfig_custom -Force
        }
        Copy-Item $sshdconfig_ori $sshdconfig_custom
        get-acl $sshdconfig_ori | set-acl $sshdconfig_custom
        
        Add-Content $sshdconfig_custom @"

DenyUsers denyuser1 deny*2 denyuse?3, 
AllowUsers allowuser1 allowu*r2 allow?se?3 allowuser4 localuser1 localu*r2 loc?lu?er3 localadmin matchuser
DenyGroups denygroup1 denygr*p2 deny?rou?3
AllowGroups allowgroup1 allowg*2 allowg?ou?3 Adm*

Match User matchuser
	ForceCommand cmd.exe /c "whoami & set SSH_ORIGINAL_COMMAND"

"@

        function Add-LocalUser
        {
            param([string] $UserName, [string] $Password)
            $user = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($PrincipalContext, $IdentityType, $UserName)
            if($user -eq $null)
            {
                try {
                    $user = new-object -TypeName System.DirectoryServices.AccountManagement.UserPrincipal -ArgumentList @($PrincipalContext,$UserName,$Password, $true)
                    $user.Save()
                }
                finally {
                    $user.Dispose()
                }
            }
        }

        function Add-LocalGroup
        {
            param([string] $groupName)
            $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($PrincipalContext, $IdentityType, $GroupName)
            if($group -eq $null)
            {
                try {
                    $group = new-object -TypeName System.DirectoryServices.AccountManagement.GroupPrincipal -ArgumentList @($PrincipalContext,$groupName)
                    $group.Save()
                }
                finally {
                    $group.Dispose()
                }
            }
        }

        function Add-UserToLocalGroup
        {
            param([string]$UserName, [string]$Password, [string]$GroupName)
            Add-LocalGroup -groupName $GroupName
            Add-LocalUser -UserName $UserName -Password $Password
            $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($PrincipalContext, $IdentityType, $GroupName)    
            $user = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($PrincipalContext, $IdentityType, $UserName)
    
            if(-not $group.Members.Contains($user))
            {
                try {
                    $group.Members.Add($user)
                    $group.save()
                }
                finally {
                    $group.Dispose()
                }
            }
        }

        function Remove-UserFromLocalGroup
        {        
            param([string]$UserName, [string]$GroupName)
            $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($PrincipalContext, $IdentityType, $GroupName)
            $user = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($PrincipalContext, $IdentityType, $UserName)
            if($group.Members.Contains($user))
            {
                try {
                    $group.Members.Remove($user)
                    $group.save()
                }
                finally {
                    $group.Dispose()
                }
            }
        }

        function Clenaup-LocalGroup
        {
            param([string]$GroupName)
            $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($PrincipalContext, $IdentityType, $GroupName)
            if($group -ne $null)
            {
                try {
                    $group.Delete()
                }
                finally {
                    $group.Dispose()
                }
            }
        }
        
        #skip when the task schedular (*-ScheduledTask) cmdlets does not exist
        $ts = (get-command get-ScheduledTask -ErrorAction SilentlyContinue)
        $skip = $ts -eq $null
        if(-not $skip)
        {
            Stop-SSHDTestDaemon   -Port $port
        }
        if($IsWindows -and ([Environment]::OSVersion.Version.Major -le 6))
        {
            #suppress the firewall blocking dialogue on win7
            netsh advfirewall firewall add rule name="sshd" program="$($OpenSSHTestInfo['OpenSSHBinPath'])\sshd.exe" protocol=any action=allow dir=in
        }
    }

    AfterEach { $tI++ }
    
    AfterAll {        
        $PrincipalContext.Dispose()
        if($IsWindows -and ($psversiontable.BuildVersion.Major -le 6))
        {            
            netsh advfirewall firewall delete rule name="sshd" program="$($OpenSSHTestInfo['OpenSSHBinPath'])\sshd.exe" protocol=any dir=in
        }    
    }

<#
    Settings in the sshd_config:

    DenyUsers denyuser1 denyu*2 denyuse?3, 
    AllowUsers allowuser1 allowu*r2 allow?se?3 allowuser4 localuser1 localu*r2 loc?lu?er3 localadmin
    DenyGroups denygroup1 denygr*p2 deny?rou?3
    AllowGroups allowgroup1 allowg*2 allowg?ou?3 Adm*
#>
     Context "Tests of AllowGroups, AllowUsers, DenyUsers, DenyGroups" {
        BeforeAll {            
            $password = "Bull_dog123456"

            $allowUser1 = "allowuser1"
            $allowUser2 = "allowuser2"
            $allowUser3 = "allowuser3"
            $allowUser4 = "allowuser4"

            $denyUser1 = "denyuser1"
            $denyUser2 = "denyuser2"
            $denyUser3 = "denyuser3"

            $localuser1 = "localuser1"
            $localuser2 = "localuser2"
            $localuser3 = "localuser3"

            $allowGroup1 = "allowgroup1"
            $allowGroup2 = "allowgroup2"
            $allowGroup3 = "allowgroup3"

            $denyGroup1 = "denygroup1"
            $denyGroup2 = "denygroup2"
            $denyGroup3 = "denygroup3"
            $sshdConfigPath = $sshdconfig_custom
            #add wrong password so ssh does not prompt password if failed with authorized keys
            Add-PasswordSetting -Pass $password            
            $tI=1
        }
        
        BeforeEach {
            $sshlog = Join-Path $testDir "$tC.$tI.$sshLogName"            
            $sshdlog = Join-Path $testDir "$tC.$tI.$sshdLogName"
            if(-not $skip)
            {
                Stop-SSHDTestDaemon   -Port $port
            }
        }

        AfterAll {            
            Remove-PasswordSetting
            $tC++
        }

        It "$tC.$tI-User with full name in the list of AllowUsers"  -skip:$skip {
           #Run
           Start-SSHDTestDaemon -WorkDir $opensshbinpath -Arguments "-d -f $sshdConfigPath -E $sshdlog" -Port $port

           Add-UserToLocalGroup -UserName $allowUser1 -Password $password -GroupName $allowGroup1

           $o = ssh  -p $port $allowUser1@$server echo 1234
           Stop-SSHDTestDaemon   -Port $port
           sleep $sshdDelay
           $o | Should Be "1234"
           Remove-UserFromLocalGroup -UserName $allowUser1 -GroupName $allowGroup1

        }

        It "$tC.$tI-User with * wildcard"  -skip:$skip {
           #Run
           Start-SSHDTestDaemon -WorkDir $opensshbinpath -Arguments "-d -f $sshdConfigPath -E $sshdlog" -Port $port 

           Add-UserToLocalGroup -UserName $allowUser2 -Password $password -GroupName $allowGroup1
           
           $o = ssh  -p $port $allowUser2@$server echo 1234
           Stop-SSHDTestDaemon   -Port $port
           sleep $sshdDelay
           $o | Should Be "1234"
           Remove-UserFromLocalGroup -UserName $allowUser2 -GroupName $allowGroup1

        }

        It "$tC.$tI-User with ? wildcard"  -skip:$skip {
           #Run
           Start-SSHDTestDaemon -WorkDir $opensshbinpath -Arguments "-d -f $sshdConfigPath -E $sshdlog" -Port $port 
           Add-UserToLocalGroup -UserName $allowUser3 -Password $password -GroupName $allowGroup1
           
           $o = ssh  -p $port $allowUser3@$server echo 1234
           Stop-SSHDTestDaemon   -Port $port
           sleep $sshdDelay
           $o | Should Be "1234"
           Remove-UserFromLocalGroup -UserName $allowUser3 -GroupName $allowGroup1

        }

        It "$tC.$tI-User with full name in the list of DenyUsers"  -skip:$skip {
           #Run
           Start-SSHDTestDaemon -WorkDir $opensshbinpath -Arguments "-d -f $sshdConfigPath -E $sshdlog" -Port $port 

           Add-UserToLocalGroup -UserName $denyUser1 -Password $password -GroupName $allowGroup1

           ssh -p $port -E $sshlog $denyUser1@$server echo 1234
           $LASTEXITCODE | Should Not Be 0
           Stop-SSHDTestDaemon   -Port $port
           sleep $sshdDelay
           $sshdlog | Should Contain "not allowed because listed in DenyUsers"

           Remove-UserFromLocalGroup -UserName $denyUser1 -GroupName $allowGroup1

        }

        It "$tC.$tI-User with * wildcard in the list of DenyUsers"  -skip:$skip {
           #Run
           Start-SSHDTestDaemon -WorkDir $opensshbinpath -Arguments "-d -f $sshdConfigPath -E $sshdlog" -Port $port 

           Add-UserToLocalGroup -UserName $denyUser2 -Password $password -GroupName $allowGroup1

           ssh -p $port -E $sshlog $denyUser2@$server echo 1234
           $LASTEXITCODE | Should Not Be 0
           Stop-SSHDTestDaemon   -Port $port
           sleep $sshdDelay
           $sshdlog | Should Contain "not allowed because listed in DenyUsers"

           Remove-UserFromLocalGroup -UserName $denyUser2 -GroupName $allowGroup1

        }

        It "$tC.$tI-User with ? wildcard in the list of DenyUsers"  -skip:$skip {
           #Run
           Start-SSHDTestDaemon -WorkDir $opensshbinpath -Arguments "-d -f $sshdConfigPath -E $sshdlog" -Port $port 

           Add-UserToLocalGroup -UserName $denyUser3 -Password $password -GroupName $allowGroup1

           ssh -p $port -E $sshlog $denyUser3@$server echo 1234
           $LASTEXITCODE | Should Not Be 0
           Stop-SSHDTestDaemon   -Port $port
           sleep $sshdDelay
           $sshdlog | Should Contain "not allowed because not listed in AllowUsers"
           
           Remove-UserFromLocalGroup -UserName $denyUser3 -GroupName $allowGroup1

        }

        It "$tC.$tI-User is listed in the list of AllowUsers but also in a full name DenyGroups and AllowGroups"  -skip:$skip {
           #Run
           Start-SSHDTestDaemon -WorkDir $opensshbinpath -Arguments "-d -f $sshdConfigPath -E $sshdlog" -Port $port 

           Add-UserToLocalGroup -UserName $localuser1 -Password $password -GroupName $allowGroup1
           Add-UserToLocalGroup -UserName $localuser1 -Password $password -GroupName $denyGroup1
           
           ssh -p $port -E $sshlog $localuser1@$server echo 1234
           $LASTEXITCODE | Should Not Be 0
           Stop-SSHDTestDaemon   -Port $port
           sleep $sshdDelay
           $sshdlog | Should Contain "not allowed because a group is listed in DenyGroups"

           Remove-UserFromLocalGroup -UserName $localuser1 -GroupName $allowGroup1
           Remove-UserFromLocalGroup -UserName $localuser1 -GroupName $denyGroup1

        }

        It "$tC.$tI-User is listed in the list of AllowUsers but also in a wildcard * DenyGroups"  -skip:$skip {
           #Run
           Start-SSHDTestDaemon -WorkDir $opensshbinpath -Arguments "-d -f $sshdConfigPath -E $sshdlog" -Port $port 

           Add-UserToLocalGroup -UserName $localuser2 -Password $password -GroupName $denyGroup2
           
           ssh -p $port -E $sshlog $localuser2@$server echo 1234
           $LASTEXITCODE | Should Not Be 0
           Stop-SSHDTestDaemon   -Port $port
           sleep $sshdDelay
           $sshdlog | Should Contain "not allowed because a group is listed in DenyGroups"
           
           Remove-UserFromLocalGroup -UserName $localuser2 -GroupName $denyGroup2

        }

        It "$tC.$tI-User is listed in the list of AllowUsers but also in a wildcard ? DenyGroups"  -skip:$skip {
           #Run
           Start-SSHDTestDaemon -WorkDir $opensshbinpath -Arguments "-d -f $sshdConfigPath -E $sshdlog" -Port $port 

           Add-UserToLocalGroup -UserName $localuser3 -Password $password -GroupName $denyGroup3
           
           ssh -p $port -E $sshlog $localuser3@$server echo 1234
           $LASTEXITCODE | Should Not Be 0
           Stop-SSHDTestDaemon   -Port $port
           sleep $sshdDelay
           $sshdlog | Should Contain "not allowed because a group is listed in DenyGroups"
           
           Remove-UserFromLocalGroup -UserName $localuser3 -GroupName $denyGroup3

        }

        It "$tC.$tI - Match User block with ForceCommand" -skip:$skip  {
            Start-SSHDTestDaemon -WorkDir $opensshbinpath -Arguments "-d -f $sshdConfigPath -E $sshdlog" -Port $port 
            $matchuser = "matchuser"
            Add-UserToLocalGroup -UserName $matchuser -Password $password -GroupName $allowGroup1

            $o = ssh  -p $port -T $matchuser@$server randomcommand
            # Match block's ForceCommand returns output of "whoami & set SSH_ORIGINAL_COMMAND"
            $o[0].Contains($matchuser) | Should Be $true
            $o[1].Contains("randomcommand") | Should Be $true
            
            Stop-SSHDTestDaemon   -Port $port
            sleep $sshdDelay
            Remove-UserFromLocalGroup -UserName $matchuser -GroupName $allowGroup1
        }
    }
}
