# Changelog

Todas as mudanças relevantes do projeto serão documentadas aqui.

## [4.1.1] - 2026-02-14

### Fixed
- **M365-Remediation.ps1** - Renamed functions to PS approved verbs (Remediate-* → Repair-*, Generate-HTMLReport → New-HTMLReport)
- **M365-Remediation.ps1** - Replaced all `-WarningAction SilentlyContinue` with `3>$null` stream redirection (prevents ActionPreference crash when $WarningPreference is corrupted)
- **M365-Remediation.ps1** - Fixed unused `$test` variable → `$null` assignment
- Zero PSScriptAnalyzer warnings

### Changed
- **M365-Remediation.ps1** - Renamed `-WhatIf` to `-DryRun` to avoid PowerShell SupportsShouldProcess conflict

## [4.1] - 2026-02-14

### Added
- **M365-Remediation.ps1 v4.1** - Integrated `Export-PurviewEvidence` function: collects all implemented policies (DLP, Labels, Retention, Audit, ATP, Transport Rules, DKIM, Conditional Access) and generates CSV/JSON/Markdown evidence for Purview Compliance Manager
- New parameters: `-TenantName`, `-SkipPurviewEvidence`, `-DryRun`
- `Audit-ImplementedPolicies.ps1` - Standalone audit of implemented policies (generates Purview evidence)
- `Purview-Audit-PA-PS7.ps1` - Auditoria Purview + Power Platform DLP (compatível macOS/Linux via PAC CLI)
- `PURVIEW-COMPLIANCE-GUIDE.md` - Guia completo para aumentar o Compliance Score do Purview
- README atualizado com todos os novos scripts e documentação

### Changed
- Todos os scripts agora multi-tenant (sem branding hardcoded)
- Purview-Audit-PS7.ps1 v4.0 corrigido: reutiliza autenticação EXO para S&C (sem segundo login)
- README completamente reestruturado com novos cenários de uso

### Removed
- `Update-PurviewComplianceActions.ps1` - Deprecated; evidence generation now integrated into M365-Remediation.ps1 and Purview auto-testing enabled in Compliance Manager settings

## [4.0] - 2026-01-29

### Added
- Relatório HTML para M365-Remediation.
- Status por seção no relatório (OK/Skip/Warning/Error).
- Bypass automático com motivo quando cmdlets/módulos não estão disponíveis.
- Get-TenantCapabilities.ps1 - Detecção automática de licenças

### Changed
- M365-Remediation: melhoria de mensagens e skips para ambientes com licença limitada.
- Documentação atualizada sobre bypass e relatório HTML.
