#Requires -Module Pester

<#
.SYNOPSIS
    Testes Pester para M365-Remediation.ps1
.DESCRIPTION
    Testa a lógica do script de remediação M365 usando mocks para todos os cmdlets
    do Exchange Online, Security & Compliance e Microsoft Graph.
    Compatível com Pester 4.x.
#>

$ScriptPath = Join-Path $PSScriptRoot "M365-Remediation.ps1"

# ============================================
# Stub functions for M365 cmdlets
# These must exist before Pester can mock them
# ============================================
function Search-UnifiedAuditLog { param($StartDate, $EndDate, $ResultSize, $ErrorAction) }
function Set-AdminAuditLogConfig { param($UnifiedAuditLogIngestionEnabled, $ErrorAction) }
function Get-OrganizationConfig { param($ErrorAction) }
function Set-OrganizationConfig { param($AuditDisabled) }
function Get-RetentionCompliancePolicy { param($ErrorAction) }
function New-RetentionCompliancePolicy { param($Name, $Comment, $TeamsChannelLocation, $TeamsChatLocation, $ExchangeLocation, $SharePointLocation, $OneDriveLocation, $Enabled, $ErrorAction) }
function New-RetentionComplianceRule { param($Name, $Policy, $RetentionDuration, $RetentionComplianceAction, $RetentionDurationDisplayHint, $ErrorAction) }
function Get-DlpCompliancePolicy { param($ErrorAction) }
function New-DlpCompliancePolicy { param($Name, $Comment, $ExchangeLocation, $SharePointLocation, $OneDriveLocation, $TeamsLocation, $Mode, $ErrorAction) }
function New-DlpComplianceRule { param($Name, $Policy, $ContentContainsSensitiveInformation, $BlockAccess, $NotifyUser, $NotifyPolicyTipCustomText, $GenerateIncidentReport, $ReportSeverityLevel, $ErrorAction) }
function Get-OwaMailboxPolicy { param($Identity, $ErrorAction) }
function Set-OwaMailboxPolicy { param($Identity, $WacExternalServicesEnabled) }
function Get-ProtectionAlert { param($Identity, $ErrorAction) }
function New-ProtectionAlert { param($Name, $Category, $ThreatType, $Operation, $Description, $AggregationType, $Severity, $NotificationEnabled, $ErrorAction) }
function Connect-ExchangeOnline { param($ShowBanner, $ErrorAction) }
function Connect-IPPSSession { param($ShowBanner, $ErrorAction) }
function Get-Label { param($ResultSize, $ErrorAction) }
function Get-LabelPolicy { param($ErrorAction) }
function Get-SafeLinksPolicy { param($ErrorAction) }
function Get-SafeAttachmentPolicy { param($ErrorAction) }
function Get-AntiPhishPolicy { param($ErrorAction) }
function Get-TransportRule { param($ErrorAction) }
function Get-DkimSigningConfig { param($ErrorAction) }
function Get-MgContext { param($ErrorAction) }
function Get-MgIdentityConditionalAccessPolicy { param($All, $ErrorAction) }

# ============================================
# Load all functions from the script using AST
# ============================================
$scriptContent = Get-Content $ScriptPath -Raw
$ast = [System.Management.Automation.Language.Parser]::ParseInput($scriptContent, [ref]$null, [ref]$null)
$functionDefs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

foreach ($funcDef in $functionDefs) {
    $funcName = $funcDef.Name
    # Skip the main entry point - it calls Clear-Host and all other functions
    if ($funcName -eq 'Start-M365Remediation') { continue }
    try {
        Invoke-Expression $funcDef.Extent.Text
    } catch {
        Write-Warning "Failed to load function ${funcName}: $_"
    }
}

# Load Start-M365Remediation separately for integration tests
$startFunc = $functionDefs | Where-Object { $_.Name -eq 'Start-M365Remediation' }
if ($startFunc) {
    Invoke-Expression $startFunc.Extent.Text
}

# ============================================
# TESTS
# ============================================

Describe "M365-Remediation.ps1 - Validação de Estrutura" {

    It "O arquivo do script existe" {
        Test-Path $ScriptPath | Should -Be $true
    }

    It "O script tem sintaxe PowerShell válida" {
        $errors = $null
        [System.Management.Automation.PSParser]::Tokenize(
            (Get-Content $ScriptPath -Raw), [ref]$errors
        )
        $errors.Count | Should -Be 0
    }

    It "O script declara CmdletBinding" {
        $content = Get-Content $ScriptPath -Raw
        $content | Should -Match '\[CmdletBinding\(\)\]'
    }

    It "O script define todos os parâmetros esperados" {
        $content = Get-Content $ScriptPath -Raw
        $expectedParams = @(
            'SkipConnection', 'SkipCapabilityCheck', 'OnlyRetention',
            'OnlyDLP', 'OnlyAlerts', 'DLPAuditOnly', 'SkipForwardingAlert',
            'SkipOWABlock', 'SkipPurviewEvidence', 'TenantName', 'DryRun'
        )
        foreach ($param in $expectedParams) {
            $content | Should -Match "\`$$param"
        }
    }

    It "O script define todas as funções principais" {
        $content = Get-Content $ScriptPath -Raw
        $expectedFunctions = @(
            'Write-Banner', 'Write-Section', 'Write-Status',
            'Save-Backup', 'Add-Change', 'Add-Skipped', 'Set-SectionStatus',
            'Initialize-TenantCapabilities', 'Test-CapabilityAvailable',
            'Connect-ToServices', 'Repair-UnifiedAuditLog',
            'Repair-RetentionPolicies', 'Repair-DLPPolicies',
            'Repair-OWAExternal', 'Repair-AlertPolicies',
            'Export-PurviewEvidence', 'Show-Summary', 'New-HTMLReport',
            'Show-RollbackInstructions', 'Start-M365Remediation'
        )
        foreach ($func in $expectedFunctions) {
            $content | Should -Match "function\s+$func"
        }
    }
}

Describe "M365-Remediation.ps1 - Funções de Interface" {

    BeforeEach {
        $Script:Backup = @{}
        $Script:Changes = @()
        $Script:SkippedItems = @()
        $Script:SectionStatus = [ordered]@{}
        $Script:TenantCaps = $null
        $script:BackupPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-backup-$([guid]::NewGuid().ToString('N')).json")
    }

    AfterEach {
        Remove-Item $script:BackupPath -ErrorAction SilentlyContinue
    }

    Context "Write-Status" {
        It "Aceita tipo Info sem erro" {
            { Write-Status -Message "Test" -Type "Info" } | Should -Not -Throw
        }

        It "Aceita tipo Success sem erro" {
            { Write-Status -Message "Test" -Type "Success" } | Should -Not -Throw
        }

        It "Aceita tipo Warning sem erro" {
            { Write-Status -Message "Test" -Type "Warning" } | Should -Not -Throw
        }

        It "Aceita tipo Error sem erro" {
            { Write-Status -Message "Test" -Type "Error" } | Should -Not -Throw
        }

        It "Aceita tipo Action sem erro" {
            { Write-Status -Message "Test" -Type "Action" } | Should -Not -Throw
        }

        It "Aceita tipo Skip sem erro" {
            { Write-Status -Message "Test" -Type "Skip" } | Should -Not -Throw
        }

        It "Aceita tipo Detail sem erro" {
            { Write-Status -Message "Test" -Type "Detail" } | Should -Not -Throw
        }
    }

    Context "Save-Backup" {
        It "Salva valores no backup" {
            Save-Backup -Key "TestKey" -Value "TestValue"
            $Script:Backup["TestKey"] | Should -Be "TestValue"
        }

        It "Cria arquivo de backup no disco" {
            Save-Backup -Key "FileTest" -Value "FileValue"
            Test-Path $script:BackupPath | Should -Be $true
        }
    }

    Context "Add-Change" {
        It "Registra alteração no log" {
            Add-Change -Category "Test" -Action "TestAction" -Details "TestDetails"
            $Script:Changes.Count | Should -Be 1
            $Script:Changes[0].Category | Should -Be "Test"
            $Script:Changes[0].Action | Should -Be "TestAction"
            $Script:Changes[0].Details | Should -Be "TestDetails"
        }

        It "Inclui timestamp na alteração" {
            Add-Change -Category "Test" -Action "Act" -Details "Det"
            $Script:Changes[0].Timestamp | Should -Not -BeNullOrEmpty
        }
    }

    Context "Add-Skipped" {
        It "Registra item pulado" {
            Add-Skipped -Category "TestCat" -Reason "TestReason"
            $Script:SkippedItems.Count | Should -Be 1
            $Script:SkippedItems[0].Category | Should -Be "TestCat"
            $Script:SkippedItems[0].Reason | Should -Be "TestReason"
        }
    }

    Context "Set-SectionStatus" {
        It "Define o status de uma seção" {
            Set-SectionStatus -Category "AuditLog" -Status "OK" -Details "test"
            $Script:SectionStatus["AuditLog"].Status | Should -Be "OK"
            $Script:SectionStatus["AuditLog"].Details | Should -Be "test"
        }

        It "Sobrescreve o status de uma seção existente" {
            Set-SectionStatus -Category "AuditLog" -Status "OK" -Details "first"
            Set-SectionStatus -Category "AuditLog" -Status "Error" -Details "second"
            $Script:SectionStatus["AuditLog"].Status | Should -Be "Error"
        }
    }
}

Describe "M365-Remediation.ps1 - Test-CapabilityAvailable" {

    Context "Sem detecção de capacidades (TenantCaps = null)" {
        It "Retorna true para qualquer capability quando TenantCaps é null" {
            $Script:TenantCaps = $null
            Test-CapabilityAvailable -Capability "DLP" | Should -Be $true
            Test-CapabilityAvailable -Capability "Retention" | Should -Be $true
            Test-CapabilityAvailable -Capability "AlertPolicies" | Should -Be $true
            Test-CapabilityAvailable -Capability "AdvancedAlerts" | Should -Be $true
            Test-CapabilityAvailable -Capability "AuditLog" | Should -Be $true
            Test-CapabilityAvailable -Capability "UnknownCapability" | Should -Be $true
        }
    }

    Context "Com detecção de capacidades (TenantCaps presente)" {
        BeforeEach {
            $Script:TenantCaps = [PSCustomObject]@{
                Capabilities = [PSCustomObject]@{
                    DLP = [PSCustomObject]@{ CanCreate = $true }
                    Retention = [PSCustomObject]@{ CanCreate = $false }
                    AlertPolicies = [PSCustomObject]@{
                        BasicAlerts = $true
                        AdvancedAlerts = $false
                    }
                    AuditLog = [PSCustomObject]@{ Available = $true }
                    ExternalSharing = [PSCustomObject]@{ Available = $true }
                }
            }
        }

        It "Retorna true para DLP quando CanCreate é true" {
            Test-CapabilityAvailable -Capability "DLP" | Should -Be $true
        }

        It "Retorna false para Retention quando CanCreate é false" {
            Test-CapabilityAvailable -Capability "Retention" | Should -Be $false
        }

        It "Retorna true para AlertPolicies (Basic)" {
            Test-CapabilityAvailable -Capability "AlertPolicies" | Should -Be $true
        }

        It "Retorna false para AdvancedAlerts quando não disponível" {
            Test-CapabilityAvailable -Capability "AdvancedAlerts" | Should -Be $false
        }

        It "Retorna true para AuditLog quando disponível" {
            Test-CapabilityAvailable -Capability "AuditLog" | Should -Be $true
        }

        It "Retorna true para capability desconhecida (default)" {
            Test-CapabilityAvailable -Capability "SomethingNew" | Should -Be $true
        }
    }
}

Describe "M365-Remediation.ps1 - Repair-UnifiedAuditLog" {

    BeforeEach {
        $Script:Backup = @{}
        $Script:Changes = @()
        $Script:SkippedItems = @()
        $Script:SectionStatus = [ordered]@{}
        $Script:TenantCaps = $null
        $script:DryRun = $false
        $script:BackupPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-backup-$([guid]::NewGuid().ToString('N')).json")
    }

    AfterEach {
        Remove-Item $script:BackupPath -ErrorAction SilentlyContinue
    }

    Context "Quando Audit Log está ativo" {
        It "Não faz alterações quando o Audit Log já está ativo" {
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Search-UnifiedAuditLog' }
            Mock Search-UnifiedAuditLog { return @{ ResultCount = 1 } }
            Mock Get-OrganizationConfig { return [PSCustomObject]@{ AuditDisabled = $false } }

            Repair-UnifiedAuditLog

            $Script:Changes.Count | Should -Be 0
            $Script:SectionStatus["AuditLog"].Status | Should -Be "OK"
        }
    }

    Context "Quando cmdlet não está disponível" {
        It "Pula quando Search-UnifiedAuditLog não está disponível" {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'Search-UnifiedAuditLog' }

            Repair-UnifiedAuditLog

            $Script:SkippedItems.Count | Should -Be 1
            $Script:SkippedItems[0].Category | Should -Be "AuditLog"
            $Script:SectionStatus["AuditLog"].Status | Should -Be "Skip"
        }
    }

    Context "Quando Audit Log está desabilitado e DryRun" {
        It "Não faz alterações em modo DryRun" {
            $script:DryRun = $true
            Mock Get-Command { return $true }
            Mock Search-UnifiedAuditLog { throw "UnifiedAuditLogIngestionEnabled not enabled" }
            Mock Set-AdminAuditLogConfig {}
            Mock Get-OrganizationConfig { return [PSCustomObject]@{ AuditDisabled = $true } }
            Mock Set-OrganizationConfig {}

            Repair-UnifiedAuditLog

            Assert-MockCalled Set-AdminAuditLogConfig -Times 0
            Assert-MockCalled Set-OrganizationConfig -Times 0
        }
    }

    Context "Quando Audit Log está desabilitado" {
        It "Ativa o Audit Log e Mailbox Audit" {
            $script:DryRun = $false
            Mock Get-Command { return $true }
            Mock Search-UnifiedAuditLog { throw "UnifiedAuditLogIngestionEnabled not enabled" }
            Mock Set-AdminAuditLogConfig {}
            Mock Get-OrganizationConfig { return [PSCustomObject]@{ AuditDisabled = $true } }
            Mock Set-OrganizationConfig {}

            Repair-UnifiedAuditLog

            Assert-MockCalled Set-AdminAuditLogConfig -Times 1
            Assert-MockCalled Set-OrganizationConfig -Times 1
            $Script:Changes.Count | Should -BeGreaterThan 0
        }
    }
}

Describe "M365-Remediation.ps1 - Repair-RetentionPolicies" {

    BeforeEach {
        $Script:Backup = @{}
        $Script:Changes = @()
        $Script:SkippedItems = @()
        $Script:SectionStatus = [ordered]@{}
        $Script:TenantCaps = $null
        $script:DryRun = $false
        $script:BackupPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-backup-$([guid]::NewGuid().ToString('N')).json")
    }

    AfterEach {
        Remove-Item $script:BackupPath -ErrorAction SilentlyContinue
    }

    Context "Quando cmdlet não está disponível" {
        It "Pula quando New-RetentionCompliancePolicy não está disponível" {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'New-RetentionCompliancePolicy' }

            Repair-RetentionPolicies

            $Script:SkippedItems.Count | Should -Be 1
            $Script:SectionStatus["Retention"].Status | Should -Be "Skip"
        }
    }

    Context "Quando Retention não está disponível por licença" {
        It "Pula quando capability Retention não está disponível" {
            $Script:TenantCaps = [PSCustomObject]@{
                Capabilities = [PSCustomObject]@{
                    Retention = [PSCustomObject]@{ CanCreate = $false }
                }
            }
            Mock Get-Command { return $true }

            Repair-RetentionPolicies

            $Script:SkippedItems.Count | Should -Be 1
            $Script:SkippedItems[0].Reason | Should -Match "Licen"
            $Script:SectionStatus["Retention"].Status | Should -Be "Skip"
        }
    }

    Context "Quando políticas já existem" {
        It "Não cria políticas duplicadas" {
            Mock Get-Command { return $true }
            Mock Get-RetentionCompliancePolicy {
                return @(
                    [PSCustomObject]@{ Name = "Retencao Teams - Mensagens 1 Ano" },
                    [PSCustomObject]@{ Name = "Retencao Dados Sensiveis - 7 Anos" },
                    [PSCustomObject]@{ Name = "Retencao Documentos - 3 Anos" }
                )
            }
            Mock New-RetentionCompliancePolicy {}
            Mock New-RetentionComplianceRule {}

            Repair-RetentionPolicies

            Assert-MockCalled New-RetentionCompliancePolicy -Times 0
            Assert-MockCalled New-RetentionComplianceRule -Times 0
            $Script:Changes.Count | Should -Be 0
        }
    }

    Context "Quando nenhuma política existe" {
        It "Cria 3 políticas de retenção" {
            Mock Get-Command { return $true }
            Mock Get-RetentionCompliancePolicy { return @() }
            Mock New-RetentionCompliancePolicy {}
            Mock New-RetentionComplianceRule {}

            Repair-RetentionPolicies

            Assert-MockCalled New-RetentionCompliancePolicy -Times 3
            Assert-MockCalled New-RetentionComplianceRule -Times 3
            $Script:Changes.Count | Should -Be 3
        }

        It "Em DryRun não cria políticas" {
            $script:DryRun = $true
            Mock Get-Command { return $true }
            Mock Get-RetentionCompliancePolicy { return @() }
            Mock New-RetentionCompliancePolicy {}
            Mock New-RetentionComplianceRule {}

            Repair-RetentionPolicies

            Assert-MockCalled New-RetentionCompliancePolicy -Times 0 -Scope It
            Assert-MockCalled New-RetentionComplianceRule -Times 0 -Scope It
            $Script:Changes.Count | Should -Be 0
        }
    }

    Context "Quando apenas uma política existe" {
        It "Cria somente as políticas faltantes" {
            Mock Get-Command { return $true }
            Mock Get-RetentionCompliancePolicy {
                return @(
                    [PSCustomObject]@{ Name = "Retencao Teams - Mensagens 1 Ano" }
                )
            }
            Mock New-RetentionCompliancePolicy {}
            Mock New-RetentionComplianceRule {}

            Repair-RetentionPolicies

            Assert-MockCalled New-RetentionCompliancePolicy -Times 2
            $Script:Changes.Count | Should -Be 2
        }
    }
}

Describe "M365-Remediation.ps1 - Repair-DLPPolicies" {

    BeforeEach {
        $Script:Backup = @{}
        $Script:Changes = @()
        $Script:SkippedItems = @()
        $Script:SectionStatus = [ordered]@{}
        $Script:TenantCaps = $null
        $script:DryRun = $false
        $script:DLPAuditOnly = $false
        $script:BackupPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-backup-$([guid]::NewGuid().ToString('N')).json")
    }

    AfterEach {
        Remove-Item $script:BackupPath -ErrorAction SilentlyContinue
    }

    Context "Quando cmdlet não está disponível" {
        It "Pula quando New-DlpCompliancePolicy não está disponível" {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'New-DlpCompliancePolicy' }

            Repair-DLPPolicies

            $Script:SkippedItems.Count | Should -Be 1
            $Script:SectionStatus["DLP"].Status | Should -Be "Skip"
        }
    }

    Context "Quando DLP não está disponível por licença" {
        It "Pula quando capability DLP não está disponível" {
            $Script:TenantCaps = [PSCustomObject]@{
                Capabilities = [PSCustomObject]@{
                    DLP = [PSCustomObject]@{ CanCreate = $false }
                }
            }
            Mock Get-Command { return $true }

            Repair-DLPPolicies

            $Script:SkippedItems.Count | Should -Be 1
            $Script:SectionStatus["DLP"].Status | Should -Be "Skip"
        }
    }

    Context "Quando nenhuma política DLP existe" {
        It "Cria 3 políticas DLP (CPF, CNPJ, Cartão de Crédito)" {
            Mock Get-Command { return $true }
            Mock Get-DlpCompliancePolicy { return @() }
            Mock New-DlpCompliancePolicy {}
            Mock New-DlpComplianceRule {}

            Repair-DLPPolicies

            Assert-MockCalled New-DlpCompliancePolicy -Times 3
            Assert-MockCalled New-DlpComplianceRule -Times 3
            $Script:Changes.Count | Should -Be 3
        }

        It "Em DryRun não cria políticas DLP" {
            $script:DryRun = $true
            Mock Get-Command { return $true }
            Mock Get-DlpCompliancePolicy { return @() }
            Mock New-DlpCompliancePolicy {}
            Mock New-DlpComplianceRule {}

            Repair-DLPPolicies

            Assert-MockCalled New-DlpCompliancePolicy -Times 0 -Scope It
            $Script:Changes.Count | Should -Be 0
        }
    }

    Context "Quando políticas DLP já existem" {
        It "Não cria políticas duplicadas" {
            Mock Get-Command { return $true }
            Mock Get-DlpCompliancePolicy {
                return @(
                    [PSCustomObject]@{ Name = "DLP - Protecao CPF Brasileiro"; Mode = "Enable" },
                    [PSCustomObject]@{ Name = "DLP - Protecao CNPJ"; Mode = "Enable" },
                    [PSCustomObject]@{ Name = "DLP - Protecao Cartao de Credito"; Mode = "Enable" }
                )
            }
            Mock New-DlpCompliancePolicy {}
            Mock New-DlpComplianceRule {}

            Repair-DLPPolicies

            Assert-MockCalled New-DlpCompliancePolicy -Times 0
            $Script:Changes.Count | Should -Be 0
        }
    }

    Context "Modo DLPAuditOnly" {
        It "Usa modo TestWithNotifications quando DLPAuditOnly é true" {
            $script:DLPAuditOnly = $true
            Mock Get-Command { return $true }
            Mock Get-DlpCompliancePolicy { return @() }
            Mock New-DlpCompliancePolicy {}
            Mock New-DlpComplianceRule {}

            Repair-DLPPolicies

            Assert-MockCalled New-DlpCompliancePolicy -Times 3 -ParameterFilter { $Mode -eq "TestWithNotifications" }
        }

        It "Usa modo Enable quando DLPAuditOnly é false" {
            $script:DLPAuditOnly = $false
            Mock Get-Command { return $true }
            Mock Get-DlpCompliancePolicy { return @() }
            Mock New-DlpCompliancePolicy {}
            Mock New-DlpComplianceRule {}

            Repair-DLPPolicies

            Assert-MockCalled New-DlpCompliancePolicy -Times 3 -ParameterFilter { $Mode -eq "Enable" }
        }
    }
}

Describe "M365-Remediation.ps1 - Repair-OWAExternal" {

    BeforeEach {
        $Script:Backup = @{}
        $Script:Changes = @()
        $Script:SkippedItems = @()
        $Script:SectionStatus = [ordered]@{}
        $Script:TenantCaps = $null
        $script:DryRun = $false
        $script:SkipOWABlock = $false
        $script:BackupPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-backup-$([guid]::NewGuid().ToString('N')).json")
    }

    AfterEach {
        Remove-Item $script:BackupPath -ErrorAction SilentlyContinue
    }

    Context "Quando cmdlet não está disponível" {
        It "Pula quando Get-OwaMailboxPolicy não está disponível" {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'Get-OwaMailboxPolicy' }

            Repair-OWAExternal

            $Script:SkippedItems.Count | Should -Be 1
            $Script:SectionStatus["OWA"].Status | Should -Be "Skip"
        }
    }

    Context "Quando SkipOWABlock está ativo" {
        It "Pula bloqueio OWA" {
            $script:SkipOWABlock = $true
            Mock Get-Command { return $true }

            Repair-OWAExternal

            $Script:SectionStatus["OWA"].Status | Should -Be "Skip"
            $Script:SectionStatus["OWA"].Details | Should -Match "SkipOWABlock"
        }
    }

    Context "Quando provedores externos estão habilitados" {
        It "Desabilita provedores externos" {
            Mock Get-Command { return $true }
            Mock Get-OwaMailboxPolicy { return [PSCustomObject]@{ WacExternalServicesEnabled = $true } }
            Mock Set-OwaMailboxPolicy {}

            Repair-OWAExternal

            Assert-MockCalled Set-OwaMailboxPolicy -Times 1
            $Script:Changes.Count | Should -Be 1
        }

        It "Em DryRun não desabilita provedores" {
            $script:DryRun = $true
            Mock Get-Command { return $true }
            Mock Get-OwaMailboxPolicy { return [PSCustomObject]@{ WacExternalServicesEnabled = $true } }
            Mock Set-OwaMailboxPolicy {}

            Repair-OWAExternal

            Assert-MockCalled Set-OwaMailboxPolicy -Times 0 -Scope It
            $Script:Changes.Count | Should -Be 0
        }
    }

    Context "Quando provedores externos já estão desabilitados" {
        It "Não faz alterações" {
            Mock Get-Command { return $true }
            Mock Get-OwaMailboxPolicy { return [PSCustomObject]@{ WacExternalServicesEnabled = $false } }
            Mock Set-OwaMailboxPolicy {}

            Repair-OWAExternal

            Assert-MockCalled Set-OwaMailboxPolicy -Times 0
            $Script:Changes.Count | Should -Be 0
        }
    }
}

Describe "M365-Remediation.ps1 - Repair-AlertPolicies" {

    BeforeEach {
        $Script:Backup = @{}
        $Script:Changes = @()
        $Script:SkippedItems = @()
        $Script:SectionStatus = [ordered]@{}
        $Script:TenantCaps = $null
        $script:DryRun = $false
        $script:SkipForwardingAlert = $false
        $script:BackupPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-backup-$([guid]::NewGuid().ToString('N')).json")
    }

    AfterEach {
        Remove-Item $script:BackupPath -ErrorAction SilentlyContinue
    }

    Context "Quando cmdlet não está disponível" {
        It "Pula quando New-ProtectionAlert não está disponível" {
            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'New-ProtectionAlert' }

            Repair-AlertPolicies

            $Script:SkippedItems.Count | Should -Be 1
            $Script:SectionStatus["AlertPolicies"].Status | Should -Be "Skip"
        }
    }

    Context "Quando capability AlertPolicies não está disponível" {
        It "Pula criação de alertas" {
            $Script:TenantCaps = [PSCustomObject]@{
                Capabilities = [PSCustomObject]@{
                    AlertPolicies = [PSCustomObject]@{
                        BasicAlerts = $false
                        AdvancedAlerts = $false
                    }
                }
            }
            Mock Get-Command { return $true }

            Repair-AlertPolicies

            $Script:SkippedItems.Count | Should -Be 1
            $Script:SectionStatus["AlertPolicies"].Status | Should -Be "Skip"
        }
    }

    Context "Quando nenhum alerta existe" {
        It "Cria 6 alertas de segurança" {
            Mock Get-Command { return $true }
            Mock Get-ProtectionAlert { return $null }
            Mock New-ProtectionAlert {}

            Repair-AlertPolicies

            Assert-MockCalled New-ProtectionAlert -Times 6
            $Script:Changes.Count | Should -Be 6
        }

        It "Cria 5 alertas quando SkipForwardingAlert é true" {
            $script:SkipForwardingAlert = $true
            Mock Get-Command { return $true }
            Mock Get-ProtectionAlert { return $null }
            Mock New-ProtectionAlert {}

            Repair-AlertPolicies

            Assert-MockCalled New-ProtectionAlert -Times 5
            $Script:Changes.Count | Should -Be 5
        }

        It "Em DryRun não cria alertas" {
            $script:DryRun = $true
            Mock Get-Command { return $true }
            Mock Get-ProtectionAlert { return $null }
            Mock New-ProtectionAlert {}

            Repair-AlertPolicies

            Assert-MockCalled New-ProtectionAlert -Times 0 -Scope It
            $Script:Changes.Count | Should -Be 0
        }
    }

    Context "Quando alertas já existem" {
        It "Não cria alertas duplicados" {
            Mock Get-Command { return $true }
            Mock Get-ProtectionAlert { return [PSCustomObject]@{ Name = "existing" } }
            Mock New-ProtectionAlert {}

            Repair-AlertPolicies

            Assert-MockCalled New-ProtectionAlert -Times 0
            $Script:Changes.Count | Should -Be 0
        }
    }

    Context "Tipo de agregação baseado em licença" {
        It "Usa SimpleAggregation para alertas avançados (E5)" {
            $Script:TenantCaps = [PSCustomObject]@{
                Capabilities = [PSCustomObject]@{
                    AlertPolicies = [PSCustomObject]@{
                        BasicAlerts = $true
                        AdvancedAlerts = $true
                    }
                }
            }
            Mock Get-Command { return $true }
            Mock Get-ProtectionAlert { return $null }
            Mock New-ProtectionAlert {}

            Repair-AlertPolicies

            Assert-MockCalled New-ProtectionAlert -Times 6 -ParameterFilter { $AggregationType -eq "SimpleAggregation" }
        }

        It "Usa None para alertas básicos" {
            $Script:TenantCaps = [PSCustomObject]@{
                Capabilities = [PSCustomObject]@{
                    AlertPolicies = [PSCustomObject]@{
                        BasicAlerts = $true
                        AdvancedAlerts = $false
                    }
                }
            }
            Mock Get-Command { return $true }
            Mock Get-ProtectionAlert { return $null }
            Mock New-ProtectionAlert {}

            Repair-AlertPolicies

            Assert-MockCalled New-ProtectionAlert -Times 6 -ParameterFilter { $AggregationType -eq "None" }
        }
    }
}

Describe "M365-Remediation.ps1 - New-HTMLReport" {

    BeforeEach {
        $Script:Backup = @{}
        $Script:Changes = @()
        $Script:SkippedItems = @()
        $Script:SectionStatus = [ordered]@{}
        $Script:TenantCaps = $null
        $script:BackupPath = "test-backup.json"
        $script:ReportPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-report-$([guid]::NewGuid().ToString('N')).html")
    }

    AfterEach {
        Remove-Item $script:ReportPath -ErrorAction SilentlyContinue
    }

    It "Gera um arquivo HTML válido" {
        $Script:SectionStatus["AuditLog"] = [PSCustomObject]@{ Category = "AuditLog"; Status = "OK"; Details = "test" }
        $Script:Changes += [PSCustomObject]@{ Category = "Test"; Action = "TestAction"; Details = "TestDetails"; Timestamp = "12:00:00" }

        New-HTMLReport

        Test-Path $script:ReportPath | Should -Be $true
        $html = Get-Content $script:ReportPath -Raw
        $html | Should -Match "<!DOCTYPE html>"
        $html | Should -Match "Remedia"
        $html | Should -Match "AuditLog"
    }

    It "Inclui seções no relatório" {
        Set-SectionStatus -Category "DLP" -Status "OK" -Details "3 políticas"
        Set-SectionStatus -Category "Retention" -Status "Warning" -Details "Falhas parciais"

        New-HTMLReport

        $html = Get-Content $script:ReportPath -Raw
        $html | Should -Match "DLP"
        $html | Should -Match "Retention"
    }

    It "Inclui itens pulados no relatório" {
        Add-Skipped -Category "AdvancedAlerts" -Reason "Licença E3"

        New-HTMLReport

        $html = Get-Content $script:ReportPath -Raw
        $html | Should -Match "AdvancedAlerts"
    }

    It "Escapa HTML corretamente para prevenir XSS" {
        $Script:Changes += [PSCustomObject]@{
            Category = "<script>alert('xss')</script>"
            Action = "Test"
            Details = "Test"
            Timestamp = "12:00:00"
        }

        New-HTMLReport

        $html = Get-Content $script:ReportPath -Raw
        $html | Should -Not -Match "<script>alert"
        $html | Should -Match "&lt;script&gt;"
    }
}

Describe "M365-Remediation.ps1 - Fluxo Principal (Start-M365Remediation)" {

    BeforeAll {
        # Load the main function
        $content = Get-Content $ScriptPath -Raw
        $mainFuncMatch = [regex]::Match($content, '(?ms)^function\s+Start-M365Remediation\s*\{.*?^\}', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if ($mainFuncMatch.Success) {
            Invoke-Expression $mainFuncMatch.Value
        }
    }

    BeforeEach {
        $Script:Backup = @{}
        $Script:Changes = @()
        $Script:SkippedItems = @()
        $Script:SectionStatus = [ordered]@{}
        $Script:TenantCaps = $null
        $script:DryRun = $true
        $script:SkipConnection = $true
        $script:SkipCapabilityCheck = $true
        $script:SkipPurviewEvidence = $true
        $script:SkipOWABlock = $false
        $script:SkipForwardingAlert = $false
        $script:OnlyRetention = $false
        $script:OnlyDLP = $false
        $script:OnlyAlerts = $false
        $script:DLPAuditOnly = $false
        $script:TenantName = ""
        $script:BackupPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-backup-$([guid]::NewGuid().ToString('N')).json")
        $script:ReportPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-report-$([guid]::NewGuid().ToString('N')).html")
        $script:PurviewEvidencePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-purview-$([guid]::NewGuid().ToString('N'))")
    }

    AfterEach {
        Remove-Item $script:BackupPath -ErrorAction SilentlyContinue
        Remove-Item $script:ReportPath -ErrorAction SilentlyContinue
        Remove-Item $script:PurviewEvidencePath -Recurse -ErrorAction SilentlyContinue
    }

    Context "Modo OnlyRetention" {
        It "Executa apenas Repair-RetentionPolicies" {
            $script:OnlyRetention = $true
            Mock Clear-Host {}
            Mock Get-Command { return $true }
            Mock Get-RetentionCompliancePolicy { return @() }
            Mock New-RetentionCompliancePolicy {}
            Mock New-RetentionComplianceRule {}
            Mock Get-DlpCompliancePolicy { return @() }
            Mock New-DlpCompliancePolicy {}
            Mock Get-OwaMailboxPolicy { return [PSCustomObject]@{ WacExternalServicesEnabled = $false } }
            Mock Search-UnifiedAuditLog { return $null }
            Mock Get-OrganizationConfig { return [PSCustomObject]@{ AuditDisabled = $false } }
            Mock Get-ProtectionAlert { return $null }
            Mock New-ProtectionAlert {}

            Start-M365Remediation

            # DLP and Alerts should NOT be called in OnlyRetention mode
            Assert-MockCalled New-DlpCompliancePolicy -Times 0
            Assert-MockCalled New-ProtectionAlert -Times 0
        }
    }

    Context "Modo OnlyDLP" {
        It "Executa apenas Repair-DLPPolicies" {
            $script:OnlyDLP = $true
            Mock Clear-Host {}
            Mock Get-Command { return $true }
            Mock Get-RetentionCompliancePolicy { return @() }
            Mock New-RetentionCompliancePolicy {}
            Mock New-RetentionComplianceRule {}
            Mock Get-DlpCompliancePolicy { return @() }
            Mock New-DlpCompliancePolicy {}
            Mock New-DlpComplianceRule {}
            Mock Search-UnifiedAuditLog { return $null }
            Mock Get-OrganizationConfig { return [PSCustomObject]@{ AuditDisabled = $false } }
            Mock Get-OwaMailboxPolicy { return [PSCustomObject]@{ WacExternalServicesEnabled = $false } }
            Mock Get-ProtectionAlert { return $null }
            Mock New-ProtectionAlert {}

            Start-M365Remediation

            Assert-MockCalled New-RetentionCompliancePolicy -Times 0
            Assert-MockCalled New-ProtectionAlert -Times 0
        }
    }

    Context "Modo OnlyAlerts" {
        It "Executa apenas Repair-AlertPolicies" {
            $script:OnlyAlerts = $true
            Mock Clear-Host {}
            Mock Get-Command { return $true }
            Mock Get-RetentionCompliancePolicy { return @() }
            Mock New-RetentionCompliancePolicy {}
            Mock New-RetentionComplianceRule {}
            Mock Get-DlpCompliancePolicy { return @() }
            Mock New-DlpCompliancePolicy {}
            Mock Search-UnifiedAuditLog { return $null }
            Mock Get-OrganizationConfig { return [PSCustomObject]@{ AuditDisabled = $false } }
            Mock Get-OwaMailboxPolicy { return [PSCustomObject]@{ WacExternalServicesEnabled = $false } }
            Mock Get-ProtectionAlert { return $null }
            Mock New-ProtectionAlert {}

            Start-M365Remediation

            Assert-MockCalled New-RetentionCompliancePolicy -Times 0
            Assert-MockCalled New-DlpCompliancePolicy -Times 0
        }
    }
}

Describe "M365-Remediation.ps1 - Segurança" {

    BeforeAll {
        $content = Get-Content $ScriptPath -Raw
    }

    It "Não contém credenciais hardcoded (password)" {
        $content | Should -Not -Match 'password\s*=\s*[''"]'
    }

    It "Não contém credenciais hardcoded (secret)" {
        $content | Should -Not -Match 'secret\s*=\s*[''"]'
    }

    It "Não contém credenciais hardcoded (apikey)" {
        $content | Should -Not -Match 'apikey\s*=\s*[''"]'
    }

    It "Usa ErrorAction Stop em conexões" {
        $content | Should -Match "Connect-ExchangeOnline.*-ErrorAction Stop"
        $content | Should -Match "Connect-IPPSSession.*-ErrorAction Stop"
    }

    It "Usa HTML encoding na geração de relatórios" {
        $content | Should -Match "\[System\.Net\.WebUtility\]::HtmlEncode"
    }

    It "Define ErrorActionPreference como Continue" {
        $content | Should -Match '\$ErrorActionPreference\s*=\s*"Continue"'
    }

    It "Cria backup antes de alterações" {
        $content | Should -Match "Save-Backup"
        $content | Should -Match '\$BackupPath\s*='
    }
}
