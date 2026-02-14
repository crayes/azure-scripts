# 📋 Guia: Purview Compliance Manager - Aumentar Score

## Problema Comum

Você implementou políticas de segurança (Conditional Access, MFA, DLP, etc.) mas o **Purview Compliance Manager Score não sobe**. Isso acontece porque o Purview **não detecta automaticamente** — você precisa **documentar manualmente** o que já foi implementado.

## Solução: Workflow de 3 Passos

### Passo 1: Auditar o que já está implementado

```powershell
# Executar auditoria completa
pwsh ./Audit-ImplementedPolicies.ps1 -TenantName "MeuCliente"

# Se já estiver conectado
pwsh ./Audit-ImplementedPolicies.ps1 -TenantName "MeuCliente" -SkipConnection
```

O script gera um CSV com todas as políticas ativas e evidências prontas.

### Passo 2: Documentar no Purview

1. Abra: https://compliance.microsoft.com/compliancemanager
2. Clique em **Assessments** → Selecione a avaliação
3. Para cada ação do CSV:
   - Clique na ação → **Update Status**
   - **Implementation Status:** Implemented
   - **Implementation Date:** (data do CSV)
   - **Implementation Notes:** (copiar as Notes do CSV)
   - **Save**

### Passo 3: Score sobe automaticamente

Após marcar as ações, o Purview recalcula o score em minutos.

## Quick Wins (ações que mais impactam o score)

| Ação | Impacto | Geralmente já implementada? |
|------|---------|:--------------------------:|
| Block Legacy Authentication | Alto | ✅ Sim |
| MFA para todos | Alto | ✅ Sim |
| MFA para admins | Alto | ✅ Sim |
| DLP Policies | Alto | ✅ Sim |
| Sensitivity Labels | Médio | ✅ Sim |
| Audit Log habilitado | Médio | ✅ Sim |
| Safe Links | Médio | Depende da licença |
| Anti-Phishing | Médio | ✅ Sim |
| Retention Policies | Médio | Parcial |
| DKIM | Baixo | ✅ Sim |

## Uso Multi-tenant

```powershell
# Executar para cada cliente
$clientes = @("RFAA", "ClienteB", "ClienteC")

foreach ($cliente in $clientes) {
    Write-Host "Auditando: $cliente" -ForegroundColor Cyan
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    
    ./Audit-ImplementedPolicies.ps1 -TenantName $cliente
}
```

## Resultado Esperado

Em tenants típicos com políticas já configuradas:

- **Antes:** Score 0-10% (nada documentado)
- **Depois:** Score 40-60% (políticas existentes documentadas)
- **Tempo:** 1-2 horas por tenant (marcação manual no portal)

## Referências

- [Purview Compliance Manager](https://compliance.microsoft.com/compliancemanager)
- [Microsoft Docs - Compliance Manager](https://learn.microsoft.com/en-us/purview/compliance-manager)
