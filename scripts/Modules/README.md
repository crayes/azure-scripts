# 🔍 M365 Tenant Capabilities Module

**Módulo PowerShell para detecção automática de licenças e capacidades em tenants Microsoft 365.**

[![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Version](https://img.shields.io/badge/Version-4.0-green.svg)](https://github.com/crayes/azure-scripts)

---

## 📋 Índice

- [Visão Geral](#-visão-geral)
- [Arquivos](#-arquivos)
- [Instalação](#-instalação)
- [Uso](#-uso)
- [Estrutura do Retorno](#-estrutura-do-retorno)
- [Integração](#-integração)
- [Exemplos](#-exemplos)

---

## 🎯 Visão Geral

Este módulo detecta automaticamente as capacidades disponíveis em um tenant Microsoft 365, permitindo que scripts de auditoria e remediação adaptem seu comportamento conforme a licença do cliente.

### Problemas que Resolve

| Problema | Solução |
|----------|---------|
| Erros ao auditar DLP em tenant sem E5 | Detecta se DLP está disponível antes de tentar |
| Score de compliance incorreto | Calcula apenas com recursos licenciados |
| Scripts que falham em tenants menores | Pula automaticamente recursos não disponíveis |
| Alertas avançados em tenant básico | Usa alertas básicos ou avançados conforme licença |

### Recursos Detectados

- **DLP** (Data Loss Prevention)
- **Sensitivity Labels** (Labels de Sensibilidade)
- **Retention Policies** (Políticas de Retenção)
- **Alert Policies** (Básicos e Avançados)
- **Insider Risk Management**
- **Communication Compliance**
- **eDiscovery** (Standard e Premium)
- **Audit Log** (Unified Audit)
- **Information Barriers**

---

## 📁 Arquivos

| Arquivo | Descrição |
|---------|-----------|
| `Get-TenantCapabilities.ps1` | Script standalone - executa diretamente |
| `M365-TenantCapabilities.psm1` | Módulo importável - para uso em outros scripts |

---

## 💾 Instalação

### Opção 1: Uso Direto (Standalone)

```powershell
# Executar diretamente
./Get-TenantCapabilities.ps1
```

### Opção 2: Importar como Módulo

```powershell
# Importar o módulo
Import-Module ./M365-TenantCapabilities.psm1

# Usar a função
$Capabilities = Get-TenantCapabilities
```

### Opção 3: Importar de Caminho Relativo

```powershell
# Em outro script (ex: Purview-Audit-PS7.ps1)
$ModulePath = Join-Path $PSScriptRoot "..\Modules\M365-TenantCapabilities.psm1"
Import-Module $ModulePath -Force
```

---

## 🚀 Uso

### Uso Básico (Visual)

```powershell
# Exibe output colorido no terminal
./Get-TenantCapabilities.ps1
```

**Output:**
```
╔══════════════════════════════════════════════════════════════════╗
║  🔍 DETECTANDO CAPACIDADES DO TENANT                             ║
╚══════════════════════════════════════════════════════════════════╝

  Tenant: Rayes Fagundes Advogados Associados
  Domínio: rfaa.onmicrosoft.com
  Licença: Microsoft 365 E5 ou equivalente (Confiança: Alta)

  ┌────────────────────────────────┬────────────┬─────────────────────┐
  │ Recurso                        │ Status     │ Detalhes            │
  ├────────────────────────────────┼────────────┼─────────────────────┤
  │ DLP                            │ ✅ Disponível│ 3 políticas        │
  │ Sensitivity Labels             │ ✅ Disponível│ 5 labels           │
  │ Retention Policies             │ ✅ Disponível│ 2 políticas        │
  │ Alert Policies (Advanced)      │ ✅ Disponível│                    │
  │ Insider Risk                   │ ✅ Disponível│ 0 políticas        │
  │ Communication Compliance       │ ✅ Disponível│                    │
  │ eDiscovery Premium             │ ✅ Disponível│                    │
  └────────────────────────────────┴────────────┴─────────────────────┘

  📋 PODE AUDITAR: DLP, SensitivityLabels, Retention, AlertPolicies, InsiderRisk
  🔧 PODE REMEDIAR: DLP, Retention, AlertPolicies, AuditLog
```

### Uso Silencioso (Programático)

```powershell
# Retorna objeto sem output visual
$Caps = ./Get-TenantCapabilities.ps1 -Silent

# Verificar licença
$Caps.License.Probable      # "Microsoft 365 E5 ou equivalente"
$Caps.License.Confidence    # "Alta"

# Verificar recurso específico
if ($Caps.Capabilities.DLP.Available) {
    Write-Host "DLP disponível - pode criar políticas!"
}

# Listar o que pode auditar
$Caps.CanAudit              # @("DLP", "SensitivityLabels", "Retention", ...)

# Listar o que pode remediar
$Caps.CanRemediate          # @("DLP", "Retention", "AlertPolicies", ...)
```

### Parâmetros

| Parâmetro | Tipo | Descrição |
|-----------|------|-----------|
| `-Silent` | Switch | Suprime output visual, retorna apenas objeto |
| `-SkipConnection` | Switch | Assume que já está conectado ao Security & Compliance |

---

## 📊 Estrutura do Retorno

O script retorna um objeto `PSCustomObject` com a seguinte estrutura:

```powershell
@{
    # Informações do Tenant
    Tenant = @{
        Name = "Rayes Fagundes Advogados Associados"
        Domain = "rfaa.onmicrosoft.com"
    }
    
    # Detecção de Licença
    License = @{
        Probable = "Microsoft 365 E5 ou equivalente"
        Confidence = "Alta"  # Alta, Média, Baixa
        Tier = "E5"          # E5, E3, BusinessPremium, Basic
    }
    
    # Capacidades Individuais
    Capabilities = @{
        DLP = @{
            Available = $true
            Count = 3
            Details = "3 políticas ativas"
        }
        SensitivityLabels = @{
            Available = $true
            Count = 5
            Details = "5 labels publicados"
        }
        Retention = @{
            Available = $true
            Count = 2
        }
        AlertPolicies = @{
            Available = $true
            AdvancedAvailable = $true  # Agregação, correlação
        }
        InsiderRisk = @{
            Available = $true
            Count = 0
        }
        CommunicationCompliance = @{
            Available = $true
        }
        eDiscovery = @{
            StandardAvailable = $true
            PremiumAvailable = $true
        }
        AuditLog = @{
            Available = $true
            Enabled = $true
        }
        InformationBarriers = @{
            Available = $false
        }
    }
    
    # Listas de Conveniência
    CanAudit = @("DLP", "SensitivityLabels", "Retention", "AlertPolicies", "InsiderRisk")
    CanRemediate = @("DLP", "Retention", "AlertPolicies", "AuditLog")
    
    # Timestamp
    DetectedAt = "2026-01-25T19:00:00Z"
}
```

---

## 🔗 Integração

### Com Purview-Audit-PS7.ps1

```powershell
# O script v4.0 já usa internamente
./Purview-Audit-PS7.ps1 -SkipConnection

# Internamente faz:
# $Caps = Get-TenantCapabilities -Silent
# if (-not $Caps.Capabilities.DLP.Available) {
#     Write-Host "⏭️ DLP não disponível - pulando seção"
# }
```

### Com M365-Remediation.ps1

```powershell
# O script v4.0 já usa internamente
./M365-Remediation.ps1 -SkipConnection

# Internamente faz:
# $Caps = Get-TenantCapabilities -Silent
# if ($Caps.Capabilities.AlertPolicies.AdvancedAvailable) {
#     # Usa AggregationType = "SimpleAggregation"
# } else {
#     # Usa AggregationType = "None" (básico)
# }
```

> **Nota:** Se o módulo/cmdlet não estiver disponível na sessão (ex.: Business Basic ou módulo não carregado),
> a remediação faz **bypass** da seção e registra o motivo no relatório. O script também gera relatório HTML
> consolidado ao final (`M365-Remediation-Report_<timestamp>.html`).

### Em Script Customizado

```powershell
# Importar módulo
Import-Module ./M365-TenantCapabilities.psm1

# Conectar
Connect-IPPSSession

# Detectar capacidades
$Caps = Get-TenantCapabilities -Silent

# Usar conforme necessário
if ($Caps.License.Tier -eq "E5") {
    Write-Host "Tenant E5 - todas as features disponíveis!"
    # Executar auditorias completas
} elseif ($Caps.License.Tier -eq "E3") {
    Write-Host "Tenant E3 - features básicas"
    # Pular DLP, Insider Risk, etc.
} else {
    Write-Host "Tenant básico - apenas essenciais"
    # Apenas Audit Log e alertas básicos
}
```

---

## 💡 Exemplos

### Exemplo 1: Verificar Antes de Criar DLP

```powershell
$Caps = ./Get-TenantCapabilities.ps1 -Silent

if ($Caps.Capabilities.DLP.Available) {
    Write-Host "Criando política DLP..."
    New-DlpCompliancePolicy -Name "Proteção CPF" -ExchangeLocation All
} else {
    Write-Host "⚠️ DLP não disponível neste tenant (licença: $($Caps.License.Probable))"
    Write-Host "   Considere upgrade para Microsoft 365 E5"
}
```

### Exemplo 2: Escolher Tipo de Alerta

```powershell
$Caps = ./Get-TenantCapabilities.ps1 -Silent

$AlertParams = @{
    Name = "Alerta de Forwarding Externo"
    Category = "ThreatManagement"
    NotifyUser = "admin@contoso.com"
    ThreatType = "Activity"
    Operation = "Set-Mailbox"
}

if ($Caps.Capabilities.AlertPolicies.AdvancedAvailable) {
    # E5: Pode usar agregação
    $AlertParams.AggregationType = "SimpleAggregation"
    $AlertParams.Threshold = 10
    $AlertParams.TimeWindow = 60
} else {
    # E3/Business: Alertas básicos apenas
    $AlertParams.AggregationType = "None"
}

New-ProtectionAlert @AlertParams
```

### Exemplo 3: Gerar Relatório de Capacidades

```powershell
$Caps = ./Get-TenantCapabilities.ps1 -Silent

# Exportar para JSON
$Caps | ConvertTo-Json -Depth 5 | Out-File "tenant-capabilities.json"

# Gerar CSV resumido
$Caps.Capabilities.GetEnumerator() | ForEach-Object {
    [PSCustomObject]@{
        Recurso = $_.Key
        Disponivel = $_.Value.Available
        Detalhes = $_.Value.Details
    }
} | Export-Csv "capabilities-summary.csv" -NoTypeInformation
```

### Exemplo 4: Comparar Múltiplos Tenants

```powershell
$Tenants = @("rfaa.onmicrosoft.com", "atsi.onmicrosoft.com", "cliente3.onmicrosoft.com")
$Results = @()

foreach ($Tenant in $Tenants) {
    Connect-IPPSSession -UserPrincipalName "admin@$Tenant"
    $Caps = ./Get-TenantCapabilities.ps1 -Silent
    
    $Results += [PSCustomObject]@{
        Tenant = $Tenant
        Licenca = $Caps.License.Probable
        DLP = $Caps.Capabilities.DLP.Available
        InsiderRisk = $Caps.Capabilities.InsiderRisk.Available
        eDiscoveryPremium = $Caps.Capabilities.eDiscovery.PremiumAvailable
    }
    
    Disconnect-ExchangeOnline -Confirm:$false
}

$Results | Format-Table -AutoSize
```

---

## 📜 Licenças Detectadas

| Licença | Tier | Recursos Típicos |
|---------|------|------------------|
| Microsoft 365 E5 | `E5` | Todos os recursos |
| Microsoft 365 E3 | `E3` | Retention, Labels, eDiscovery Standard |
| Business Premium | `BusinessPremium` | Retention, Labels básicos |
| Business Basic | `Basic` | Apenas Audit Log e alertas básicos |

---

## ⚠️ Limitações

- Requer conexão prévia ao Security & Compliance Center (`Connect-IPPSSession`)
- A detecção é baseada em testes de funcionalidade (não consulta licenças diretamente)
- Alguns recursos podem estar disponíveis mas não configurados (ex: Insider Risk com 0 políticas)
- A confiança da detecção varia conforme os recursos encontrados

---

## 🔧 Troubleshooting

### Erro: "Not connected to Security & Compliance"

```powershell
# Conectar primeiro
Connect-IPPSSession
./Get-TenantCapabilities.ps1
```

### Detecção incorreta de licença

```powershell
# Verificar manualmente no Admin Center:
# https://admin.microsoft.com > Billing > Licenses

# O script detecta por funcionalidade, não por SKU
# Se DLP existe mas está vazio, ainda conta como "disponível"
```

### Output muito longo no terminal

```powershell
# Usar modo silencioso
$Caps = ./Get-TenantCapabilities.ps1 -Silent
$Caps.License.Probable  # Ver apenas licença
```

---

## 📝 Changelog

### v4.0 - Janeiro 2026
- ✨ Versão inicial do módulo
- 🔍 Detecção de 9 categorias de recursos
- 📊 Classificação de licença (E5/E3/Business/Basic)
- 🎨 Output visual colorido
- 📦 Versão standalone (.ps1) e módulo (.psm1)

---

## 📄 Licença

MIT License - Veja [LICENSE](../../LICENSE) para detalhes.

---

## 👨‍💻 Autor

**Celso N Rayes** // **Atsi Informatica**

Desenvolvido para administração de múltiplos tenants Microsoft 365.
