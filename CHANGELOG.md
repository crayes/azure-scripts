# Changelog

Todas as mudanças relevantes do projeto serão documentadas aqui.

## [4.1] - 2026-02-14

### Added
- `Audit-ImplementedPolicies.ps1` - Audita políticas já implementadas e gera evidências CSV/JSON/MD para o Purview Compliance Manager
- `Purview-Audit-PA-PS7.ps1` - Auditoria Purview + Power Platform DLP (compatível macOS/Linux via PAC CLI)
- `PURVIEW-COMPLIANCE-GUIDE.md` - Guia completo para aumentar o Compliance Score do Purview
- README atualizado com todos os novos scripts e documentação

### Changed
- Todos os scripts agora multi-tenant (sem branding hardcoded)
- Purview-Audit-PS7.ps1 v4.0 corrigido: reutiliza autenticação EXO para S&C (sem segundo login)
- README completamente reestruturado com novos cenários de uso

## [4.0] - 2026-01-29

### Added
- Relatório HTML para M365-Remediation.
- Status por seção no relatório (OK/Skip/Warning/Error).
- Bypass automático com motivo quando cmdlets/módulos não estão disponíveis.
- Get-TenantCapabilities.ps1 - Detecção automática de licenças

### Changed
- M365-Remediation: melhoria de mensagens e skips para ambientes com licença limitada.
- Documentação atualizada sobre bypass e relatório HTML.
